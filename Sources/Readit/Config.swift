import Foundation

/// Plain-text configuration file: `~/.config/readit/config.toml` (override with `READIT_CONFIG`).
///
/// Precedence for every setting: config file → legacy preferences (UserDefaults, set by the Settings window
/// or `defaults write local.bireader.app …`) → environment variables → built-in default.
/// When the file exists, the Settings window writes changes back into it (comments and layout are kept).
/// The API key is never written into the file by the app: it stays in preferences unless the file itself
/// defines `api_key`, `api_key_env` or `api_key_command`.
enum ConfigFile {
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["READIT_CONFIG"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/readit/config.toml")
    }
    static var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
    static var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: cached read (re-parsed only when the file's mtime changes)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMTime: Date?
    nonisolated(unsafe) private static var cachedValues: [String: String] = [:]
    nonisolated(unsafe) private static var cachedCommandKey: (cmd: String, mtime: Date?, key: String)?

    private static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// all values as "section.key" → unquoted string
    static var values: [String: String] {
        lock.lock(); defer { lock.unlock() }
        let m = mtime()
        if m != cachedMTime {
            cachedMTime = m
            cachedValues = m == nil ? [:] : TOML.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
        return cachedValues
    }

    static func string(_ key: String) -> String? {
        guard let v = values[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        return v
    }
    static func int(_ key: String) -> Int? { string(key).flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    static func double(_ key: String) -> Double? { string(key).flatMap { Double($0) } }

    // MARK: API key

    enum KeySource: Equatable { case file, env(String), command, none }

    /// where the config file says the key comes from (`.none` → fall back to preferences / environment)
    static var keySource: KeySource {
        if string("gateway.api_key") != nil { return .file }
        if let c = string("gateway.api_key_command"), !c.isEmpty { return .command }
        if let e = string("gateway.api_key_env") { return .env(e) }
        return .none
    }

    static func apiKey() -> String? {
        switch keySource {
        case .file: return string("gateway.api_key")
        case .env(let name):
            let v = ProcessInfo.processInfo.environment[name] ?? ""
            return v.isEmpty ? nil : v
        case .command:
            guard let cmd = string("gateway.api_key_command") else { return nil }
            lock.lock()
            if let c = cachedCommandKey, c.cmd == cmd, c.mtime == cachedMTime { lock.unlock(); return c.key.isEmpty ? nil : c.key }
            lock.unlock()
            let key = runCommand(cmd)
            lock.lock(); cachedCommandKey = (cmd, cachedMTime, key); lock.unlock()
            return key.isEmpty ? nil : key
        case .none: return nil
        }
    }

    /// e.g. `security find-generic-password -s readit -w` (Keychain). Runs once per config change, 5 s timeout.
    private static func runCommand(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: write-back

    enum Value { case str(String), int(Int), num(Double) }

    /// Update keys in place (keeps comments and ordering); missing keys/sections are appended. No-op without a file.
    static func set(_ updates: [String: Value]) {
        guard exists, !updates.isEmpty else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let out = TOML.update(text, updates.mapValues(render))
        guard out != text else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        try? out.write(to: url, atomically: true, encoding: .utf8)
        if let perm = attrs?[.posixPermissions] { try? FileManager.default.setAttributes([.posixPermissions: perm], ofItemAtPath: url.path) }
    }

    static func render(_ v: Value) -> String {
        switch v {
        case .str(let s): return TOML.quote(s)
        case .int(let i): return String(i)
        case .num(let d): return d == d.rounded() && abs(d) < 1e9 ? String(format: "%.1f", d) : String(d)
        }
    }

    /// Create the file from the current settings. The API key is NOT written; it keeps coming from preferences.
    @discardableResult
    static func create(from s: [String: Value]) throws -> URL {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func v(_ k: String, _ d: String) -> String { s[k].map(render) ?? d }
        let text = """
        # Readit configuration — https://github.com/mapix/readit#configuration
        # Values here override the Settings window and legacy `defaults write` preferences.

        [gateway]
        base_url = \(v("gateway.base_url", "\"https://api.anthropic.com\""))
        # API key — pick ONE (if none is set, the key saved in the Settings window is used):
        # api_key_command = "security find-generic-password -s readit -w"   # macOS Keychain (recommended)
        # api_key_env = "READIT_API_KEY"                                     # only when launched from a shell
        # api_key = "…"                                                      # plain text; keep this file chmod 600

        [translate]
        model = \(v("translate.model", "\"claude-haiku-5-5\""))
        protocol = \(v("translate.protocol", "\"anthropic\""))   # anthropic | chat | responses
        target_language = \(v("translate.target_language", "\"简体中文\""))
        lookahead_pages = \(v("translate.lookahead_pages", "2"))

        [assistant]   # AI Assistant / Narration / Flashcards (needs image input)
        model = \(v("assistant.model", "\"claude-haiku-5-5\""))
        protocol = \(v("assistant.protocol", "\"anthropic\""))

        [tts]
        model = \(v("tts.model", "\"gemini-3.8-flash-tts\""))
        voice = \(v("tts.voice", "\"Zephyr\""))   # Zephyr Leda Aoede Kore Puck Charon Fenrir Orus
        speed = \(v("tts.speed", "1.5"))

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}

/// Minimal TOML subset: `[section]`, `key = "string" | 'literal' | number | bool`, `#` comments.
enum TOML {
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                if let end = line.firstIndex(of: "]") {
                    section = String(line[line.index(after: line.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") { key = String(key.dropFirst().dropLast()) }
            let rest = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            out[section.isEmpty ? key : section + "." + key] = value(rest)
        }
        return out
    }

    /// parse the right-hand side of `key = …`, dropping a trailing comment
    static func value(_ s: String) -> String {
        guard let f = s.first else { return "" }
        if f == "\"" {
            var r = "", esc = false
            for c in s.dropFirst() {
                if esc {
                    switch c { case "n": r.append("\n"); case "t": r.append("\t"); case "r": r.append("\r"); default: r.append(c) }
                    esc = false
                } else if c == "\\" { esc = true }
                else if c == "\"" { return r }
                else { r.append(c) }
            }
            return r
        }
        if f == "'" {
            let body = s.dropFirst()
            return String(body.prefix { $0 != "'" })
        }
        let bare = s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        return bare.trimmingCharacters(in: .whitespaces)
    }

    static func quote(_ s: String) -> String {
        var r = "\""
        for c in s {
            switch c {
            case "\\": r += "\\\\"
            case "\"": r += "\\\""
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            default: r.append(c)
            }
        }
        return r + "\""
    }

    /// rewrite `section.key` lines with already-rendered values; append what is missing
    static func update(_ text: String, _ updates: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        var pending = updates
        var section = ""
        var lastLineOfSection: [String: Int] = [:]
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
                section = String(line[line.index(after: line.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
                lastLineOfSection[section] = i
                continue
            }
            if !line.isEmpty { lastLineOfSection[section] = i }
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let full = section.isEmpty ? key : section + "." + key
            guard let v = pending.removeValue(forKey: full) else { continue }
            let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
            lines[i] = indent + key + " = " + v + trailingComment(raw)
        }
        guard !pending.isEmpty else { return lines.joined(separator: "\n") }
        // insert into existing sections (bottom-up so indices stay valid), then append new sections
        var bySection: [String: [(String, String)]] = [:]
        for (full, v) in pending.sorted(by: { $0.key < $1.key }) {
            let parts = full.split(separator: ".", maxSplits: 1).map(String.init)
            let (sec, key) = parts.count == 2 ? (parts[0], parts[1]) : ("", parts[0])
            bySection[sec, default: []].append((key, v))
        }
        for (sec, idx) in lastLineOfSection.sorted(by: { $0.value > $1.value }) {
            guard let kv = bySection.removeValue(forKey: sec) else { continue }
            lines.insert(contentsOf: kv.map { "\($0.0) = \($0.1)" }, at: idx + 1)
        }
        while lines.last == "" { lines.removeLast() }
        for (sec, kv) in bySection.sorted(by: { $0.key < $1.key }) {
            if sec.isEmpty { lines.insert(contentsOf: kv.map { "\($0.0) = \($0.1)" }, at: 0); continue }
            lines.append("")
            lines.append("[\(sec)]")
            lines.append(contentsOf: kv.map { "\($0.0) = \($0.1)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// keep a `# comment` that follows the value (outside quotes)
    private static func trailingComment(_ raw: String) -> String {
        guard let eq = raw.firstIndex(of: "=") else { return "" }
        var inStr: Character? = nil, esc = false
        var idx = raw.index(after: eq)
        var lastNonSpace = idx
        while idx < raw.endIndex {
            let c = raw[idx]
            if let q = inStr {
                if esc { esc = false } else if c == "\\" && q == "\"" { esc = true } else if c == q { inStr = nil }
            } else if c == "\"" || c == "'" { inStr = c }
            else if c == "#" {
                let gap = raw[lastNonSpace..<idx].allSatisfy { $0 == " " || $0 == "\t" } ? String(raw[lastNonSpace..<idx]) : "   "
                return (gap.isEmpty ? " " : gap) + String(raw[idx...])
            }
            if c != " " && c != "\t" { lastNonSpace = raw.index(after: idx) }
            idx = raw.index(after: idx)
        }
        return ""
    }
}
