import Foundation

/// Resolved settings. Order: config file (`ConfigFile`) → legacy preferences (UserDefaults) → environment → default.
/// Setters always update the legacy preferences (so older builds keep working) and, if the config file
/// exists, write the value into it as well.
enum Settings {
    static var d: UserDefaults { .standard }
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var apiKey: String {
        get {
            if ConfigFile.keySource != .none, let k = ConfigFile.apiKey() { return k }
            return nonEmpty(d.string(forKey: "apiKey")) ?? nonEmpty(env["ANTHROPIC_AUTH_TOKEN"]) ?? nonEmpty(env["ANTHROPIC_API_KEY"]) ?? ""
        }
        set {
            d.set(newValue, forKey: "apiKey")
            // only touch the file if it already stores the key in plain text
            if ConfigFile.keySource == .file { ConfigFile.set(["gateway.api_key": .str(newValue)]) }
        }
    }
    /// the key is provided by the config file (env var / command) and cannot be edited in the Settings window
    static var apiKeyManagedByFile: Bool {
        switch ConfigFile.keySource { case .env, .command: return true; default: return false }
    }
    static var baseURL: String {
        get { ConfigFile.string("gateway.base_url") ?? nonEmpty(d.string(forKey: "baseURL")) ?? nonEmpty(env["ANTHROPIC_BASE_URL"]) ?? "https://api.anthropic.com" }
        set { d.set(newValue, forKey: "baseURL"); ConfigFile.set(["gateway.base_url": .str(newValue)]) }
    }
    static var model: String {
        get { d.string(forKey: "model") ?? "claude-haiku-5-5" }
        set { d.set(newValue, forKey: "model") }
    }
    static var targetLang: String {
        get { ConfigFile.string("translate.target_language") ?? d.string(forKey: "targetLang") ?? "简体中文" }
        set { d.set(newValue, forKey: "targetLang"); ConfigFile.set(["translate.target_language": .str(newValue)]) }
    }
    /// pages translated ahead of the current one
    static var lookahead: Int {
        get { max(0, ConfigFile.int("translate.lookahead_pages") ?? d.object(forKey: "lookahead") as? Int ?? 2) }
        set { d.set(newValue, forKey: "lookahead"); ConfigFile.set(["translate.lookahead_pages": .int(newValue)]) }
    }
    static var ttsVoice: String {
        get { ConfigFile.string("tts.voice") ?? d.string(forKey: "narrVoice") ?? "Zephyr" }
        set { d.set(newValue, forKey: "narrVoice"); ConfigFile.set(["tts.voice": .str(newValue)]) }
    }
    static var ttsSpeed: Float {
        get { ConfigFile.double("tts.speed").map { Float($0) } ?? d.object(forKey: "narrRate2") as? Float ?? 1.5 }
        set { d.set(newValue, forKey: "narrRate2"); ConfigFile.set(["tts.speed": .num(Double(newValue))]) }
    }

    /// snapshot used to create the config file from the current state (no API key)
    static var snapshot: [String: ConfigFile.Value] {
        [
            "gateway.base_url": .str(baseURL),
            "translate.model": .str(ModelConfig.translateModel),
            "translate.protocol": .str(ModelConfig.style("translate").configName),
            "translate.target_language": .str(targetLang),
            "translate.lookahead_pages": .int(lookahead),
            "assistant.model": .str(ModelConfig.chatModel),
            "assistant.protocol": .str(ModelConfig.style("chat").configName),
            "tts.model": .str(ModelConfig.ttsModel),
            "tts.voice": .str(ttsVoice),
            "tts.speed": .num(Double(ttsSpeed)),
        ]
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}

enum TranslateError: LocalizedError {
    case noKey, http(Int, String), bad(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "未设置 API Key（设置 → 翻译）"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .bad(let m): return m
        }
    }
}

actor TranslationCache {
    static let shared = TranslationCache()
    private var map: [String: String] = [:]
    private var dirty = false
    private let url = Paths.base.appendingPathComponent("translations.json")
    init() {
        if let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) { map = m }
    }
    func get(_ k: String) -> String? { map[k] }
    func set(_ k: String, _ v: String) {
        map[k] = v
        if !dirty { dirty = true; Task { try? await Task.sleep(nanoseconds: 400_000_000); self.flush() } }
    }
    func flush() {
        dirty = false
        if let d = try? JSONEncoder().encode(map) { try? d.write(to: url, options: .atomic) }
    }
    nonisolated func flushSync() {
        let sem = DispatchSemaphore(value: 0)
        Task { await self.flush(); sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
    }
}

enum Translator {
    static func key(_ text: String) -> String { ModelConfig.translateModel + "|" + Settings.targetLang + "|" + text }

    static func needsTranslation(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let cjk = s.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        return letters >= 2 && Double(cjk) < Double(max(1, letters)) * 0.3
    }

    static func translateOne(_ text: String) async throws -> String {
        try await translate([text])[0]
    }

    /// translates a batch, using cache; preserves order
    static func translate(_ texts: [String]) async throws -> [String] {
        var out = [String?](repeating: nil, count: texts.count)
        var todo: [Int] = []
        for (i, t) in texts.enumerated() {
            if let c = await TranslationCache.shared.get(key(t)), !c.isEmpty { out[i] = c } else { todo.append(i) }
        }
        if !todo.isEmpty {
            let res = try await request(todo.map { texts[$0] })
            for (k, i) in todo.enumerated() {
                out[i] = res[k]
                await TranslationCache.shared.set(key(texts[i]), res[k])
            }
        }
        return out.map { $0 ?? "" }
    }

    nonisolated(unsafe) static var requestCount = 0
    private static func request(_ texts: [String]) async throws -> [String] {
        requestCount += 1
        let lang = Settings.targetLang
        let sys = """
        You are a professional academic translator. Translate every item of the JSON array the user sends into \(lang).
        Rules: precise, fluent, idiomatic \(lang); keep math, formulas, variable names, citations like [12], URLs, code, person names, emails, affiliations and proper nouns (model names, datasets) unchanged; PDF extraction may break words or include stray symbols, fix them silently; never add explanations.
        Output ONLY a JSON array of strings with exactly the same length and order as the input.
        """
        let input = String(data: try JSONSerialization.data(withJSONObject: texts), encoding: .utf8)!
        var txt = try await LLMClient.complete(role: "translate", system: sys, input: LLMInput(text: input), maxTokens: 16000)
        txt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
        if txt.hasPrefix("```") {
            txt = txt.replacingOccurrences(of: "^```(?:json)?\\s*", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s*```$", with: "", options: .regularExpression)
        }
        if let arr = parseArray(txt), arr.count == texts.count { return arr }
        if texts.count == 1 { return [txt] }
        let mid = texts.count / 2
        async let x = request(Array(texts[..<mid]))
        async let y = request(Array(texts[mid...]))
        return try await x + y
    }

    private static func parseArray(_ s: String) -> [String]? {
        func p(_ x: String) -> [String]? {
            guard let d = x.data(using: .utf8), let a = try? JSONSerialization.jsonObject(with: d) as? [Any] else { return nil }
            return a.map { "\($0)" }
        }
        if let a = p(s) { return a }
        if let r = s.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression) { return p(String(s[r])) }
        return nil
    }
}
