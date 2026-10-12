import Foundation
import AVFoundation

/// Where narration audio comes from.
/// - system: macOS AVSpeechSynthesizer — free, offline, no model needed (default for new installs)
/// - gateway: OpenAI-compatible `POST /v1/audio/speech` on the configured gateway
enum TTSProvider: String, CaseIterable, Identifiable {
    case system, gateway
    var id: String { rawValue }
    init?(configName s: String) {
        switch s.lowercased() {
        case "system", "macos", "apple", "avspeech", "local": self = .system
        case "gateway", "openai", "api", "remote": self = .gateway
        default: return nil
        }
    }
}

struct VoiceOption: Hashable, Identifiable {
    let id: String
    let label: String
}

/// macOS system speech, rendered to a WAV so caching, speed control, buffering and MP4 export work unchanged.
enum SystemTTS {
    /// BCP-47 code for the narration language (scripts are written in the translation target language)
    static func languageCode(_ target: String) -> String {
        switch target {
        case "简体中文": return "zh-CN"
        case "繁體中文": return "zh-TW"
        case "日本語": return "ja-JP"
        case "한국어": return "ko-KR"
        case "English": return "en-US"
        default:
            let t = target.lowercased()
            if t.contains("中文") || t.hasPrefix("zh") { return "zh-CN" }
            if t.hasPrefix("en") { return "en-US" }
            return Locale.preferredLanguages.first ?? "en-US"
        }
    }

    private static func rank(_ v: AVSpeechSynthesisVoice) -> Int {
        switch v.quality {
        case .premium: return 3
        case .enhanced: return 2
        default: return 1
        }
    }

    /// installed voices for the language, best quality first (novelty and Personal Voice excluded).
    /// Cached for a minute: listing voices is not free and the UI asks often.
    nonisolated(unsafe) private static var voiceCache: [String: (at: Date, list: [AVSpeechSynthesisVoice])] = [:]
    private static let cacheLock = NSLock()
    static func voices(for target: String) -> [AVSpeechSynthesisVoice] {
        cacheLock.lock()
        if let c = voiceCache[target], Date().timeIntervalSince(c.at) < 60 { cacheLock.unlock(); return c.list }
        cacheLock.unlock()
        let list = loadVoices(for: target)
        cacheLock.lock(); voiceCache[target] = (Date(), list); cacheLock.unlock()
        return list
    }
    private static func loadVoices(for target: String) -> [AVSpeechSynthesisVoice] {
        let code = languageCode(target)
        let prefix = String(code.prefix { $0 != "-" })
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let exact = all.filter { $0.language == code }
        let list = exact.isEmpty ? all.filter { $0.language.hasPrefix(prefix) } : exact
        return list.sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality {
        case .premium: q = " · " + L("高级")
        case .enhanced: q = " · " + L("增强")
        default: q = ""
        }
        return "\(v.name)\(q) (\(v.language))"
    }

    static func options(for target: String) -> [VoiceOption] {
        voices(for: target).map { VoiceOption(id: $0.identifier, label: label($0)) }
    }

    /// chosen voice, or the best installed voice for the language when `id` is empty / not installed
    static func resolve(_ id: String, target: String) -> AVSpeechSynthesisVoice? {
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices(for: target).first ?? AVSpeechSynthesisVoice(language: languageCode(target))
    }

    /// stable, filename-safe tag used in the audio cache
    static func cacheTag(_ id: String, target: String) -> String {
        let raw = resolve(id, target: target)?.identifier ?? languageCode(target)
        return "sys-" + String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" }).suffix(60)
    }

    /// synthesize at the natural rate (playback speed is applied by the player, like gateway audio)
    @MainActor
    static func synthesize(_ text: String, voiceId: String, target: String) async throws -> Data {
        let u = AVSpeechUtterance(string: text)
        u.voice = resolve(voiceId, target: target)
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        return try await withCheckedThrowingContinuation { c in
            SystemTTSJob().run(u, continuation: c)
        }
    }

    /// 16-bit mono PCM → WAV
    static func wav(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

/// One utterance written to buffers. Keeps itself alive until finished; resumes the continuation exactly once.
private final class SystemTTSJob: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let q = DispatchQueue(label: "readit.system-tts")
    private var samples: [Int16] = []
    private var rate = 22050
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var keepAlive: SystemTTSJob?

    func run(_ u: AVSpeechUtterance, continuation c: CheckedContinuation<Data, Error>) {
        continuation = c
        keepAlive = self
        synth.delegate = self
        synth.write(u) { [weak self] buf in self?.receive(buf) }
        q.asyncAfter(deadline: .now() + 120) { [weak self] in self?.finish() }   // safety net
    }

    private func receive(_ buf: AVAudioBuffer) {
        guard let pcm = buf as? AVAudioPCMBuffer else { return }
        let n = Int(pcm.frameLength)
        if n == 0 { q.async { self.finish() }; return }
        // copy synchronously: the buffer may be reused once the callback returns
        var chunk = [Int16](repeating: 0, count: n)
        if let f = pcm.floatChannelData {
            let p = f[0]
            for i in 0..<n { chunk[i] = Int16(max(-1, min(1, p[i])) * 32767) }
        } else if let s = pcm.int16ChannelData {
            let p = s[0]
            for i in 0..<n { chunk[i] = p[i] }
        } else if let s = pcm.int32ChannelData {
            let p = s[0]
            for i in 0..<n { chunk[i] = Int16(truncatingIfNeeded: p[i] >> 16) }
        } else { return }
        let r = Int(pcm.format.sampleRate)
        q.sync {
            rate = r > 0 ? r : rate
            samples.append(contentsOf: chunk)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        q.asyncAfter(deadline: .now() + 0.3) { self.finish() }    // let trailing buffers land first
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        q.async { self.finish() }
    }

    /// runs on `q`
    private func finish() {
        guard !finished else { return }
        finished = true
        let c = continuation; continuation = nil
        if samples.count > 1000 {
            c?.resume(returning: SystemTTS.wav(samples, rate: rate))
        } else {
            c?.resume(throwing: TranslateError.bad(L("系统语音合成失败：请在「系统设置 → 辅助功能 → 朗读内容」中确认已安装该语言的声音")))
        }
        DispatchQueue.main.async { self.keepAlive = nil }
    }
}
