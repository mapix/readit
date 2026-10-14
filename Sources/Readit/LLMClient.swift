import Foundation

/// Which wire protocol to use for a model.
enum APIStyle: String, CaseIterable, Identifiable, Codable {
    case anthropic, chat, responses, chatgpt
    var id: String { rawValue }
    var name: String {
        switch self {
        case .anthropic: return "Anthropic Messages"
        case .chat: return "OpenAI Chat Completions"
        case .responses: return "OpenAI Responses"
        case .chatgpt: return L("ChatGPT 账号（Sign in with ChatGPT）")
        }
    }
    /// sensible guess from a model id
    static func guess(_ model: String) -> APIStyle {
        let m = model.lowercased()
        if m.hasPrefix("claude") || m.contains("-claude") { return .anthropic }
        if m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") || m.hasPrefix("o3") || m.hasPrefix("o4") { return .responses }
        return .chat
    }
    /// value used in config.toml (`protocol = "anthropic" | "chat" | "responses"`)
    var configName: String { rawValue }
    /// accepts the config names plus a few common aliases
    init?(configName s: String) {
        switch s.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "anthropic", "messages", "anthropic-messages": self = .anthropic
        case "chat", "openai", "openai-chat", "chat-completions", "openai-chat-completions": self = .chat
        case "responses", "openai-responses": self = .responses
        case "chatgpt", "siwc", "chatgpt-plan", "sign-in-with-chatgpt": self = .chatgpt
        default: return nil
        }
    }
}

/// Per-purpose model configuration (translation / chat / TTS).
/// Roles map to config.toml sections: translate → [translate], chat → [assistant], tts → [tts].
enum ModelConfig {
    static var d: UserDefaults { .standard }
    static func section(_ role: String) -> String { role == "chat" ? "assistant" : role }
    static func model(_ role: String, default def: String) -> String {
        ConfigFile.string(section(role) + ".model") ?? d.string(forKey: "model.\(role)") ?? def
    }
    static func setModel(_ role: String, _ v: String) {
        d.set(v, forKey: "model.\(role)")
        ConfigFile.set([section(role) + ".model": .str(v)])
    }
    static func style(_ role: String) -> APIStyle {
        if let s = ConfigFile.string(section(role) + ".protocol"), let v = APIStyle(configName: s) { return v }
        if let s = d.string(forKey: "style.\(role)"), let v = APIStyle(rawValue: s) { return v }
        return .guess(model(role, default: Settings.model))
    }
    static func setStyle(_ role: String, _ v: APIStyle) {
        d.set(v.rawValue, forKey: "style.\(role)")
        ConfigFile.set([section(role) + ".protocol": .str(v.configName)])
    }

    static var translateModel: String { model("translate", default: Settings.model) }
    static var chatModel: String { model("chat", default: Settings.model) }
    static var ttsModel: String { model("tts", default: "gemini-3.8-flash-tts") }
}

/// Content of a user turn: text and optional JPEG images (vision).
struct LLMInput {
    var text: String
    var images: [Data] = []
}

/// Unified client over Anthropic Messages, OpenAI Chat Completions and OpenAI Responses.
enum LLMClient {
    struct Msg { var role: String; var text: String }

    private static func request(_ path: String, _ body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        let key = Settings.apiKey
        guard !key.isEmpty else { throw TranslateError.noKey }
        let base = Settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw TranslateError.bad(L("网关地址无效：") + base) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private static func userContent(_ style: APIStyle, _ input: LLMInput) -> Any {
        if input.images.isEmpty { return input.text }
        switch style {
        case .anthropic:
            return input.images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] as [String: Any] } + [["type": "text", "text": input.text]]
        case .chat:
            return input.images.map { ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + $0.base64EncodedString()]] as [String: Any] } + [["type": "text", "text": input.text]]
        case .responses, .chatgpt:
            return input.images.map { ["type": "input_image", "image_url": "data:image/jpeg;base64," + $0.base64EncodedString()] as [String: Any] } + [["type": "input_text", "text": input.text]]
        }
    }

    private static func body(style: APIStyle, model: String, system: String, history: [Msg], input: LLMInput, maxTokens: Int, stream: Bool) -> (String, [String: Any]) {
        switch style {
        case .anthropic:
            var msgs: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
            msgs.append(["role": "user", "content": userContent(style, input)])
            var b: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": msgs]
            if stream { b["stream"] = true }
            return ("/v1/messages", b)
        case .chat:
            var msgs: [[String: Any]] = [["role": "system", "content": system]]
            msgs += history.map { ["role": $0.role, "content": $0.text] }
            msgs.append(["role": "user", "content": userContent(style, input)])
            var b: [String: Any] = ["model": model, "messages": msgs, "max_completion_tokens": maxTokens]
            if stream { b["stream"] = true }
            return ("/v1/chat/completions", b)
        case .responses:
            var items: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
            items.append(["role": "user", "content": userContent(style, input)])
            var b: [String: Any] = ["model": model, "instructions": system, "input": items, "max_output_tokens": maxTokens]
            if stream { b["stream"] = true }
            return ("/v1/responses", b)
        case .chatgpt:
            // ChatGPT plan usage: store=false + stream=true always; no max_output_tokens / temperature / metadata
            var items: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
            items.append(["role": "user", "content": userContent(style, input)])
            return ("/responses", ["model": model, "instructions": system, "input": items, "store": false, "stream": true])
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((j?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    /// ChatGPT plan requests go to api.openai.com with the signed-in account's OAuth token
    private static func chatGPTRequest(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> URLRequest {
        let token = try await ChatGPTAuth.shared.accessToken()
        guard let url = URL(string: ChatGPTAuth.resource + path) else { throw TranslateError.bad("ChatGPT URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// readable message for ChatGPT plan errors (codes from the Sign in with ChatGPT docs)
    static func chatGPTMessage(_ code: String, _ fallback: String) -> String {
        switch code {
        case "subscription_sharing_usage_limit_exceeded": return L("ChatGPT 套餐用量已达上限，可在 ChatGPT 设置 → 用量 中查看")
        case "subscription_sharing_user_not_eligible": return L("这个 ChatGPT 账号或工作区不能用于第三方应用（需要 Plus 或 Pro）")
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": return L("ChatGPT 用量服务暂时不可用，请稍后再试")
        case "subscription_sharing_unsupported_capability": return L("ChatGPT 套餐不支持这个模型或参数") + " (\(fallback))"
        case "subscription_sharing_invalid_user": return L("ChatGPT 登录已失效，请重新连接")
        default: return fallback.isEmpty ? code : fallback
        }
    }

    /// one-shot completion
    static func complete(role: String, system: String, input: LLMInput, history: [Msg] = [], maxTokens: Int = 4096, feature: String? = nil) async throws -> String {
        let style = ModelConfig.style(role), model = ModelConfig.model(role, default: Settings.model)
        if style == .chatgpt {
            // the ChatGPT plan route only streams: collect the deltas
            var out = ""
            for try await t in stream(role: role, system: system, input: input, history: history, maxTokens: maxTokens, feature: feature) { out += t }
            return out
        }
        let (path, b) = body(style: style, model: model, system: system, history: history, input: input, maxTokens: maxTokens, stream: false)
        let req = try request(path, b, timeout: 240)
        var last: Error = TranslateError.bad(L("请求失败"))
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code >= 500 { last = TranslateError.http(code, errorMessage(data)); try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1))); continue }
                if code >= 400 { throw TranslateError.http(code, errorMessage(data)) }
                let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let text = extractText(style, j)
                let u = usage(style, j)
                recordUsage(role: role, feature: feature, model: model, reported: u, system: system, input: input, history: history, output: text, style: style)
                return text
            } catch let e as TranslateError { throw e } catch { last = error; try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1))) }
        }
        throw last
    }

    /// (input, output) tokens reported by the API, if any
    static func usage(_ style: APIStyle, _ j: [String: Any]) -> (Int, Int)? {
        guard let u = j["usage"] as? [String: Any] else { return nil }
        func n(_ k: String) -> Int? { (u[k] as? NSNumber)?.intValue }
        switch style {
        case .anthropic: return n("input_tokens").map { ($0 + (n("cache_read_input_tokens") ?? 0) + (n("cache_creation_input_tokens") ?? 0), n("output_tokens") ?? 0) }
        case .chat: return n("prompt_tokens").map { ($0, n("completion_tokens") ?? 0) }
        case .responses, .chatgpt: return n("input_tokens").map { ($0, n("output_tokens") ?? 0) }
        }
    }

    static func recordUsage(role: String, feature f: String?, model: String, reported: (Int, Int)?, system: String, input: LLMInput, history: [Msg], output: String, style: APIStyle) {
        let feature = f ?? UsageContext.feature ?? (role == "translate" ? "translate" : "assistant")
        if let r = reported {
            UsageStore.shared.record(feature: feature, model: model, input: r.0, output: r.1, estimated: false, plan: style == .chatgpt)
        } else {
            let inTok = UsageStore.estimateTokens(system + input.text + history.map(\.text).joined(), images: input.images.count)
            UsageStore.shared.record(feature: feature, model: model, input: inTok, output: UsageStore.estimateTokens(output), estimated: true, plan: style == .chatgpt)
        }
    }

    static func extractText(_ style: APIStyle, _ j: [String: Any]) -> String {
        switch style {
        case .anthropic:
            return ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .chat:
            let c = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"]
            if let s = c as? String { return s }
            return ((c as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        case .responses, .chatgpt:
            if let t = j["output_text"] as? String { return t }
            var out = ""
            for item in (j["output"] as? [[String: Any]]) ?? [] where item["type"] as? String == "message" {
                for c in (item["content"] as? [[String: Any]]) ?? [] { if let t = c["text"] as? String { out += t } }
            }
            return out
        }
    }

    /// streaming completion (yields text deltas)
    static func stream(role: String, system: String, input: LLMInput, history: [Msg] = [], maxTokens: Int = 4096, feature: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let style = ModelConfig.style(role), model = ModelConfig.model(role, default: Settings.model)
                    let (path, b) = body(style: style, model: model, system: system, history: history, input: input, maxTokens: maxTokens, stream: true)
                    let req: URLRequest
                    if style == .chatgpt { req = try await chatGPTRequest(path, b, timeout: 300) } else { req = try request(path, b, timeout: 300) }
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code >= 400 {
                        var data = Data()
                        for try await x in bytes { data.append(x); if data.count > 4000 { break } }
                        if style == .chatgpt {
                            let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                            let e = j["error"] as? [String: Any]
                            let msg = chatGPTMessage(e?["code"] as? String ?? "", (e?["message"] as? String) ?? (j["detail"] as? String) ?? errorMessage(data))
                            throw TranslateError.http(code, msg)
                        }
                        throw TranslateError.http(code, errorMessage(data))
                    }
                    var completed = false
                    var reportedIn: Int?, reportedOut: Int?
                    var produced = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        switch style {
                        case .anthropic:
                            let type = j["type"] as? String
                            if type == "message_start", let u = (j["message"] as? [String: Any])?["usage"] as? [String: Any] {
                                reportedIn = ((u["input_tokens"] as? NSNumber)?.intValue ?? 0) + ((u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0) + ((u["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0)
                            }
                            if type == "message_delta", let o = ((j["usage"] as? [String: Any])?["output_tokens"] as? NSNumber)?.intValue { reportedOut = o }
                            if type == "content_block_delta", let delta = j["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String { produced += t; cont.yield(t) }
                            else if type == "error", let e = j["error"] as? [String: Any] { throw TranslateError.bad(e["message"] as? String ?? "stream error") }
                        case .chat:
                            if let u = usage(.chat, j) { reportedIn = u.0; reportedOut = u.1 }
                            if let ch = (j["choices"] as? [[String: Any]])?.first, let delta = ch["delta"] as? [String: Any], let t = delta["content"] as? String, !t.isEmpty { produced += t; cont.yield(t) }
                        case .responses, .chatgpt:
                            let type = j["type"] as? String
                            if type == "response.output_text.delta", let t = j["delta"] as? String { produced += t; cont.yield(t) }
                            else if type == "error" || type == "response.failed" || type == "response.incomplete" {
                                let e = (j["error"] as? [String: Any]) ?? ((j["response"] as? [String: Any])?["error"] as? [String: Any])
                                let msg = (e?["message"] as? String) ?? (type == "response.incomplete" ? L("回答不完整") : "stream error")
                                throw TranslateError.bad(style == .chatgpt ? chatGPTMessage(e?["code"] as? String ?? "", msg) : msg)
                            }
                            else if type == "response.completed" {
                                completed = true
                                if let r = j["response"] as? [String: Any], let u = usage(.responses, r) { reportedIn = u.0; reportedOut = u.1 }
                            }
                        }
                        if completed { break }
                    }
                    if style == .chatgpt && !completed && !Task.isCancelled { throw TranslateError.bad(L("ChatGPT 回答中断，请重试")) }
                    let rep: (Int, Int)? = reportedIn.map { ($0, reportedOut ?? UsageStore.estimateTokens(produced)) }
                    recordUsage(role: role, feature: feature, model: model, reported: rep, system: system, input: input, history: history, output: produced, style: style)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// model ids available on the configured gateway
    static func listModels() async -> [String] {
        let key = Settings.apiKey
        let base = Settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1/models") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = j["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }.sorted()
    }
}
