import Foundation

/// Which feature a model request belongs to (set by callers with `UsageContext.$feature.withValue`).
enum UsageContext {
    @TaskLocal static var feature: String?
}

/// Token usage per day · feature · model, persisted in the data directory (usage.json).
/// Reported counts are used when the API returns them; otherwise a character-based estimate is stored.
final class UsageStore: @unchecked Sendable {
    static let shared = UsageStore()

    struct Row: Codable, Hashable {
        var day: String          // yyyy-MM-dd
        var feature: String      // translate | narration | assistant | flashcards | mindmap | tts | …
        var model: String
        var calls = 0
        var input = 0            // tokens (TTS: characters)
        var output = 0
        var estimated = 0        // calls whose counts are estimates
        var plan = false         // ran on a ChatGPT plan (no per-token cost)
    }

    private let lock = NSLock()
    private var rows: [Row] = []
    private var dirty = false
    private let url: URL

    init() {
        url = Paths.base.appendingPathComponent("usage.json")
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([Row].self, from: d) { rows = r }
    }

    static func today(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func record(feature: String, model: String, input: Int, output: Int, estimated: Bool, plan: Bool = false) {
        let day = UsageStore.today()
        lock.lock()
        if let i = rows.firstIndex(where: { $0.day == day && $0.feature == feature && $0.model == model && $0.plan == plan }) {
            rows[i].calls += 1; rows[i].input += input; rows[i].output += output; if estimated { rows[i].estimated += 1 }
        } else {
            rows.append(Row(day: day, feature: feature, model: model, calls: 1, input: input, output: output, estimated: estimated ? 1 : 0, plan: plan))
        }
        let schedule = !dirty
        dirty = true
        lock.unlock()
        if schedule { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { self.flush() } }
    }

    func flush() {
        lock.lock(); let snapshot = rows; dirty = false; lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
    }

    func reset() { lock.lock(); rows = []; lock.unlock(); flush() }

    /// rows of the last `days` days (1 = today)
    func rows(days: Int) -> [Row] {
        let cutoff = UsageStore.today(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        lock.lock(); defer { lock.unlock() }
        return rows.filter { $0.day >= cutoff }
    }

    struct Summary { var calls = 0, input = 0, output = 0, ttsChars = 0, estimated = 0; var cost = 0.0 }

    func summary(days: Int) -> Summary {
        var s = Summary()
        for r in rows(days: days) {
            if r.feature == "tts" { s.ttsChars += r.input; s.cost += Pricing.ttsCost(chars: r.input); continue }
            s.calls += r.calls; s.input += r.input; s.output += r.output; s.estimated += r.estimated
            if !r.plan { s.cost += Pricing.cost(model: r.model, input: r.input, output: r.output) }
        }
        return s
    }

    /// per feature for the period
    func byFeature(days: Int) -> [(feature: String, calls: Int, input: Int, output: Int)] {
        var m: [String: (Int, Int, Int)] = [:]
        for r in rows(days: days) {
            let v = m[r.feature] ?? (0, 0, 0)
            m[r.feature] = (v.0 + r.calls, v.1 + r.input, v.2 + r.output)
        }
        return m.map { (feature: $0.key, calls: $0.value.0, input: $0.value.1, output: $0.value.2) }.sorted { $0.input + $0.output > $1.input + $1.output }
    }

    /// average tokens per call of a feature (for estimates), nil when there is no history
    func average(feature: String) -> (input: Int, output: Int)? {
        lock.lock(); let rs = rows.filter { $0.feature == feature }; lock.unlock()
        let calls = rs.reduce(0) { $0 + $1.calls }
        guard calls >= 3 else { return nil }
        return (rs.reduce(0) { $0 + $1.input } / calls, rs.reduce(0) { $0 + $1.output } / calls)
    }

    /// rough token count when an API doesn't report usage: CJK ≈ 1 token/char, other text ≈ 4 chars/token
    static func estimateTokens(_ s: String, images: Int = 0) -> Int {
        var cjk = 0, other = 0
        for u in s.unicodeScalars {
            if (0x3040...0x30FF).contains(u.value) || (0x3400...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) { cjk += 1 } else { other += 1 }
        }
        return cjk + other / 4 + images * 1100
    }
}

/// Prices are the user's own (gateways differ). Per million tokens; 0 = don't show money.
enum Pricing {
    static var d: UserDefaults { .standard }
    static var inputPerMTok: Double {
        get { ConfigFile.double("pricing.input_per_mtok") ?? d.double(forKey: "pricing.input") }
        set { d.set(newValue, forKey: "pricing.input"); ConfigFile.set(["pricing.input_per_mtok": .num(newValue)]) }
    }
    static var outputPerMTok: Double {
        get { ConfigFile.double("pricing.output_per_mtok") ?? d.double(forKey: "pricing.output") }
        set { d.set(newValue, forKey: "pricing.output"); ConfigFile.set(["pricing.output_per_mtok": .num(newValue)]) }
    }
    /// remote TTS, per million characters
    static var ttsPerMChars: Double {
        get { ConfigFile.double("pricing.tts_per_mchars") ?? d.double(forKey: "pricing.tts") }
        set { d.set(newValue, forKey: "pricing.tts"); ConfigFile.set(["pricing.tts_per_mchars": .num(newValue)]) }
    }
    static var currency: String {
        get { ConfigFile.string("pricing.currency") ?? d.string(forKey: "pricing.currency") ?? "$" }
        set { d.set(newValue, forKey: "pricing.currency"); ConfigFile.set(["pricing.currency": .str(newValue)]) }
    }
    static var enabled: Bool { inputPerMTok > 0 || outputPerMTok > 0 || ttsPerMChars > 0 }

    static func cost(model: String, input: Int, output: Int) -> Double {
        Double(input) / 1e6 * inputPerMTok + Double(output) / 1e6 * outputPerMTok
    }
    static func ttsCost(chars: Int) -> Double { Double(chars) / 1e6 * ttsPerMChars }
    static func format(_ v: Double) -> String { currency + String(format: v < 1 ? "%.3f" : "%.2f", v) }
}

extension Int {
    /// 12.3万 / 12.3K style compact number
    var compact: String {
        let v = Double(self)
        if L10n.cache == .zh || L10n.cache == .ja {
            if v >= 1e8 { return String(format: "%.1f亿", v / 1e8) }
            if v >= 1e4 { return String(format: "%.1f万", v / 1e4) }
            return "\(self)"
        }
        if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.1fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.1fK", v / 1e3) }
        return "\(self)"
    }
}
