import Foundation

/// Which wire protocol to use for a model.
enum APIStyle: String, CaseIterable, Identifiable, Codable {
    case anthropic, chat, responses
    var id: String { rawValue }
    var name: String {
        switch self {
        case .anthropic: return "Anthropic Messages"
        case .chat: return "OpenAI Chat Completions"
        case .responses: return "OpenAI Responses"
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
        var req = URLRequest(url: URL(string: base + path)!)
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
        case .responses:
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
        }
    }

    private static func errorMessage(_ data: Data) -> String {
        let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((j?["error"] as? [String: Any])?["message"] as? String) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    /// one-shot completion
    static func complete(role: String, system: String, input: LLMInput, history: [Msg] = [], maxTokens: Int = 4096) async throws -> String {
        let style = ModelConfig.style(role), model = ModelConfig.model(role, default: Settings.model)
        let (path, b) = body(style: style, model: model, system: system, history: history, input: input, maxTokens: maxTokens, stream: false)
        let req = try request(path, b, timeout: 240)
        var last: Error = TranslateError.bad("请求失败")
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 429 || code >= 500 { last = TranslateError.http(code, errorMessage(data)); try await Task.sleep(nanoseconds: UInt64(1_500_000_000 * (attempt + 1))); continue }
                if code >= 400 { throw TranslateError.http(code, errorMessage(data)) }
                let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                return extractText(style, j)
            } catch let e as TranslateError { throw e } catch { last = error; try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * (attempt + 1))) }
        }
        throw last
    }

    static func extractText(_ style: APIStyle, _ j: [String: Any]) -> String {
        switch style {
        case .anthropic:
            return ((j["content"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        case .chat:
            let c = ((j["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"]
            if let s = c as? String { return s }
            return ((c as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        case .responses:
            if let t = j["output_text"] as? String { return t }
            var out = ""
            for item in (j["output"] as? [[String: Any]]) ?? [] where item["type"] as? String == "message" {
                for c in (item["content"] as? [[String: Any]]) ?? [] { if let t = c["text"] as? String { out += t } }
            }
            return out
        }
    }

    /// streaming completion (yields text deltas)
    static func stream(role: String, system: String, input: LLMInput, history: [Msg] = [], maxTokens: Int = 4096) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let style = ModelConfig.style(role), model = ModelConfig.model(role, default: Settings.model)
                    let (path, b) = body(style: style, model: model, system: system, history: history, input: input, maxTokens: maxTokens, stream: true)
                    let req = try request(path, b, timeout: 300)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code >= 400 {
                        var data = Data()
                        for try await x in bytes { data.append(x); if data.count > 4000 { break } }
                        throw TranslateError.http(code, errorMessage(data))
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        switch style {
                        case .anthropic:
                            let type = j["type"] as? String
                            if type == "content_block_delta", let delta = j["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String { cont.yield(t) }
                            else if type == "error", let e = j["error"] as? [String: Any] { throw TranslateError.bad(e["message"] as? String ?? "stream error") }
                        case .chat:
                            if let ch = (j["choices"] as? [[String: Any]])?.first, let delta = ch["delta"] as? [String: Any], let t = delta["content"] as? String, !t.isEmpty { cont.yield(t) }
                        case .responses:
                            let type = j["type"] as? String
                            if type == "response.output_text.delta", let t = j["delta"] as? String { cont.yield(t) }
                            else if type == "error" || type == "response.failed" { throw TranslateError.bad(((j["error"] as? [String: Any])?["message"] as? String) ?? "stream error") }
                            else if type == "response.completed" { break }
                        }
                    }
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
