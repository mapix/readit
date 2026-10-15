import Foundation

/// Turns the model's narration-script reply into (text, focus) segments.
///
/// The model is asked for `[{"text": …, "focus": …}]`, but replies are sometimes not valid JSON: ASCII quotes
/// inside the Chinese text, a code fence, prose around the array, or a reply cut off by the token limit.
/// Strict decoding is tried first, then a tolerant scanner that pulls out every `"text"` / `"focus"` value.
/// Raw JSON must never end up being read aloud.
enum ScriptParser {
    struct Item: Equatable { var text: String; var focus: String? }

    /// nil when the reply looks like JSON but nothing usable could be recovered (caller may retry)
    static func parse(_ raw: String) -> [Item]? {
        let s = stripFences(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if let a = strict(s), !a.isEmpty { return a }
        let l = lenient(s)
        if !l.isEmpty { return l }
        if looksLikeJSON(s) { return nil }
        return prose(s)
    }

    /// last resort: never returns JSON syntax
    static func salvage(_ raw: String) -> [Item] {
        if let p = parse(raw), !p.isEmpty { return p }
        let cleaned = raw
            .replacingOccurrences(of: "\"(text|focus)\"\\s*:", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "[\\[\\]{}\"]", with: " ", options: .regularExpression)
        return prose(cleaned)
    }

    /// a cached script produced by the old fallback: the JSON itself became a segment
    static func looksBroken(_ texts: [String]) -> Bool {
        texts.contains { t in
            let x = t.trimmingCharacters(in: .whitespaces)
            return x.contains("\"text\"") && (x.hasPrefix("[") || x.hasPrefix("{") || x.contains("\"focus\""))
        }
    }

    static func looksLikeJSON(_ s: String) -> Bool { s.contains("\"text\"") }

    // MARK: steps

    static func stripFences(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        return s.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*```\\s*$", with: "", options: .regularExpression)
    }

    static func strict(_ s: String) -> [Item]? {
        guard let start = s.firstIndex(of: "["), let end = s.lastIndex(of: "]"), start < end else { return nil }
        let body = String(s[start...end])
        guard let d = body.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        let items = arr.compactMap { o -> Item? in
            guard let t = (o["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            let f = (o["focus"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Item(text: t, focus: f)
        }
        return items
    }

    /// scan for `"text": "…"` values; a quote only closes a value when followed by `,` `}` `]` or the end,
    /// so unescaped quotes inside the sentence survive. An unterminated final value (cut-off reply) is kept
    /// if it is long enough to be worth reading.
    static func lenient(_ s: String) -> [Item] {
        let chars = Array(s)
        var items: [Item] = []
        var i = 0
        while let k = find("\"text\"", in: chars, from: i) {
            guard let v = value(in: chars, afterKey: k + 6) else { i = k + 6; continue }
            let (text, after, closed) = v
            // focus belongs to this object: look between here and the next "text"
            let next = find("\"text\"", in: chars, from: after) ?? chars.count
            var focus: String?
            if let f = find("\"focus\"", in: chars, from: after), f < next, let fv = value(in: chars, afterKey: f + 7) {
                focus = fv.0.isEmpty ? nil : fv.0
            }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && (closed || t.count >= 20) { items.append(Item(text: t, focus: focus)) }
            i = max(after, k + 6)
        }
        return items
    }

    /// plain prose reply: paragraphs become segments
    static func prose(_ s: String) -> [Item] {
        s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 8 }
            .map { Item(text: $0, focus: nil) }
    }

    // MARK: helpers

    private static func find(_ needle: String, in h: [Character], from: Int) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty, h.count >= n.count, from <= h.count - n.count else { return nil }
        var i = max(0, from)
        while i <= h.count - n.count {
            if h[i] == n[0] {
                var ok = true
                for j in 1..<n.count where h[i + j] != n[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    /// parse `: "value"` starting right after a key; returns (value, index after it, properly closed)
    private static func value(in c: [Character], afterKey k: Int) -> (String, Int, Bool)? {
        var i = k
        while i < c.count, c[i].isWhitespace { i += 1 }
        guard i < c.count, c[i] == ":" else { return nil }
        i += 1
        while i < c.count, c[i].isWhitespace { i += 1 }
        guard i < c.count, c[i] == "\"" else { return nil }
        i += 1
        var out = ""
        while i < c.count {
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {
                let e = c[i + 1]
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": break
                case "u":
                    if i + 5 < c.count, let v = UInt32(String(c[(i + 2)...(i + 5)]), radix: 16), let u = Unicode.Scalar(v) {
                        out.unicodeScalars.append(u); i += 6; continue
                    }
                    out.append(e)
                default: out.append(e)
                }
                i += 2
                continue
            }
            if ch == "\"" {
                var j = i + 1
                while j < c.count, c[j].isWhitespace { j += 1 }
                if j >= c.count || c[j] == "," || c[j] == "}" || c[j] == "]" { return (out, i + 1, true) }
                out.append(ch)          // stray quote inside the sentence
                i += 1
                continue
            }
            out.append(ch)
            i += 1
        }
        return (out, c.count, false)
    }
}
