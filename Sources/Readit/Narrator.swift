import Foundation
import AVFoundation
import PDFKit
import AppKit

/// "AI 解读" mode: for each page, Claude looks at the rendered page (text + figures) and writes a spoken-style
/// explanation split into short segments; each segment is synthesized with gemini-3.8-flash-tts and played,
/// then the reader auto-advances. Scripts and audio are cached per document so replays are instant and free.
@MainActor
final class Narrator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Narrator()

    struct Segment: Codable, Hashable { var text: String; var focus: String? }   // focus: short quote of what is being explained
    enum State: Equatable { case idle, preparing, playing, paused }

    @Published var state: State = .idle
    @Published var docId: UUID?
    @Published var page = 0
    @Published var segIndex = 0
    @Published var segments: [Segment] = []
    @Published var pageCount = 0
    @Published var error: String?
    /// raw WAV of the segment currently loaded (to rebuild the player when crossing the 2x limit)
    private var currentWav: Data?

    /// AVAudioPlayer tops out at 2x: above that, time-stretch the clip (pitch preserved) and play it at 2x
    func makePlayer(_ wav: Data) throws -> AVAudioPlayer {
        var data = wav
        if rate > 2, let pcm = PCM(wav: wav) {
            data = Narrator.wavData(VideoComposer.timeStretch(pcm.samples, rate: pcm.rate, speed: rate / 2), rate: pcm.rate)
        }
        let pl = try AVAudioPlayer(data: data)
        pl.enableRate = true
        pl.rate = min(rate, 2)
        return pl
    }

    private func applyRate(old: Float) {
        guard let pl = player else { return }
        if (old > 2) == (rate > 2) && rate <= 2 { pl.rate = rate; return }
        // crossing / within the stretched range: rebuild at the same relative position
        guard let wav = currentWav, let np = try? makePlayer(wav) else { pl.rate = min(rate, 2); return }
        let frac = pl.duration > 0 ? pl.currentTime / pl.duration : 0
        let wasPlaying = pl.isPlaying
        pl.delegate = nil; pl.stop()
        np.delegate = self
        np.currentTime = frac * np.duration
        player = np
        if wasPlaying { np.play() }
    }

    static func wavData(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples.count * 2); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(samples.count * 2)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    @Published var rate: Float = Settings.ttsSpeed {
        didSet { if rate != oldValue { Settings.ttsSpeed = rate }; applyRate(old: oldValue) }
    }
    /// gateway TTS voice
    @Published var voice: String = Settings.ttsVoice {
        didSet { if voice != oldValue { Settings.ttsVoice = voice } }
    }
    /// TTS engine and macOS voice (identifier; "" = automatic)
    @Published var provider: TTSProvider = Settings.ttsProvider {
        didSet { if provider != oldValue { Settings.ttsProvider = provider; fallbackToSystem = false; refreshBuffered() } }
    }
    @Published var systemVoice: String = Settings.systemVoice {
        didSet { if systemVoice != oldValue { Settings.systemVoice = systemVoice; refreshBuffered() } }
    }
    /// set for the current run when the gateway rejects TTS requests (no TTS model, bad key…)
    @Published var fallbackToSystem = false
    @Published var fallbackReason = ""
    var effectiveProvider: TTSProvider { fallbackToSystem ? .system : provider }
    /// part of the audio cache filename, so clips from different engines / voices never mix
    var voiceTag: String {
        effectiveProvider == .gateway ? voice : SystemTTS.cacheTag(systemVoice, target: Settings.targetLang)
    }
    /// entries for the voice menus
    var voiceOptions: [VoiceOption] {
        if effectiveProvider == .gateway { return Narrator.voices.map { VoiceOption(id: $0, label: Narrator.voiceNames[$0] ?? $0) } }
        return [VoiceOption(id: "", label: L("自动（按目标语言）"))] + SystemTTS.options(for: Settings.targetLang)
    }
    var currentVoiceID: String { effectiveProvider == .gateway ? voice : systemVoice }
    var currentVoiceName: String {
        if effectiveProvider == .gateway { return voice }
        return SystemTTS.resolve(systemVoice, target: Settings.targetLang)?.name ?? L("系统语音")
    }
    func selectVoice(_ id: String) { if effectiveProvider == .gateway { voice = id } else { systemVoice = id } }
    static let voices = ["Zephyr", "Leda", "Aoede", "Kore", "Puck", "Charon", "Fenrir", "Orus"]
    static let voiceNames = ["Leda": "Leda · 年轻轻松女声", "Aoede": "Aoede · 温柔女声", "Kore": "Kore · 沉稳女声", "Zephyr": "Zephyr · 明亮女声", "Puck": "Puck · 活泼男声", "Charon": "Charon · 知性男声", "Fenrir": "Fenrir · 激昂男声", "Orus": "Orus · 低沉男声"]
    nonisolated static let styleInstruction = "用年轻、轻松、亲切的语气朗读，像和朋友聊天一样自然，语调有起伏，不要播音腔。"
    /// reader of the window showing the narrated document
    static var reader: ReaderController { DocWindows.shared.entries[shared.docId ?? UUID()]?.reader ?? ReaderController.shared }
    static var ttsModel: String { ModelConfig.ttsModel }

    private var player: AVAudioPlayer?
    private var doc: PDFDocument?
    /// original (untranslated) document used to build scripts, regardless of the view mode
    private var sourceDoc: PDFDocument?
    private var title = ""
    /// document being narrated (original or bilingual variant) and its title — used by the MP4 export
    var narratedDoc: PDFDocument? { doc }
    var narratedTitle: String { title }

    /// "录制": off by default. While on, remember which (page, segment) were played. The export itself is always
    /// a clean full pass built from cached assets; this only reports coverage.
    @Published var recording = false { didSet { if recording && !oldValue { recorded = [] } } }
    @Published var recorded: Set<String> = []
    private var runToken = UUID()
    private var scriptTasks: [Int: Task<[Segment], Error>] = [:]
    private var audioTasks: [String: Task<Data, Error>] = [:]

    var progress: Double {
        guard pageCount > 0 else { return 0 }
        let inPage = segments.isEmpty ? 0 : Double(segIndex) / Double(segments.count)
        return (Double(page) + inPage) / Double(pageCount)
    }

    // MARK: remaining-time estimate

    /// script length (characters) per page, from the cached scripts; pages not scripted yet are estimated
    var pageChars: [Int: Int] = [:]
    var pageCharsMissing: Set<Int> = []

    private func chars(ofPage p: Int) -> Int? {
        if let c = pageChars[p] { return c }
        if pageCharsMissing.contains(p) { return nil }
        let u = cacheDir().appendingPathComponent("p\(p).json")
        if let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([Segment].self, from: d) {
            let c = s.reduce(0) { $0 + $1.text.count }
            pageChars[p] = c
            return c
        }
        pageCharsMissing.insert(p)
        return nil
    }

    /// seconds of audio per character at 1×, learned from synthesized clips (per target language)
    static var paceKey: String { "narrPace." + shared.effectiveProvider.rawValue + "." + Settings.targetLang }
    static var pace: Double {
        if let a = UserDefaults.standard.array(forKey: paceKey) as? [Double], a.count == 2, a[0] > 200, a[1] > 0 {
            return a[1] / a[0]
        }
        // defaults: CJK speech ≈ 4.5 chars/s, alphabetic ≈ 14 chars/s
        let l = Settings.targetLang
        return (l.contains("中文") || l.contains("日本") || l.contains("한국")) ? 0.22 : 0.072
    }
    private var paceSeen: Set<String> = []
    private func learnPace(key: String, text: String, wav: Data) {
        guard !paceSeen.contains(key), let secs = Narrator.wavSeconds(wav), secs > 0.3, text.count > 4 else { return }
        paceSeen.insert(key)
        var a = UserDefaults.standard.array(forKey: Narrator.paceKey) as? [Double] ?? [0, 0]
        if a.count != 2 { a = [0, 0] }
        a[0] += Double(text.count); a[1] += secs
        if a[1] > 3600 { a = a.map { $0 / 2 } }      // keep adapting to recent voices
        UserDefaults.standard.set(a, forKey: Narrator.paceKey)
    }
    static func wavSeconds(_ d: Data) -> Double? {
        guard d.count > 44 else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 }
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o+1]) << 8 }
        let byteRate = u32(28), ch = u16(22), bits = u16(34)
        guard byteRate > 0, ch > 0, bits > 0 else { return nil }
        return Double(d.count - 44) / Double(byteRate)
    }

    /// estimated real time (seconds, at the current speed) to finish the document from the current position
    func remainingSeconds() -> Double? {
        guard docId != nil, pageCount > 0, state != .idle else { return nil }
        let speed = Double(max(0.25, rate))
        let pace = Narrator.pace
        var seconds = 0.0
        var n = 0                       // characters still to be spoken on known scripts
        var unknownPages = 0
        if segments.isEmpty {
            if let c = chars(ofPage: page) { n += c } else { unknownPages += 1 }
        } else {
            if segIndex < segments.count {
                if let pl = player, state == .playing || state == .paused, pl.duration > 0 {
                    seconds += max(0, pl.duration - pl.currentTime) / Double(max(0.25, pl.rate))
                } else {
                    n += segments[segIndex].text.count
                }
            }
            if segIndex + 1 < segments.count {
                n += segments[(segIndex + 1)...].reduce(0) { $0 + $1.text.count }
            }
        }
        // following pages: cached scripts where available, the average scripted page otherwise
        if page + 1 < pageCount {
            for p in (page + 1)..<pageCount {
                if let c = chars(ofPage: p) { n += c } else { unknownPages += 1 }
            }
        }
        let scripted = pageChars.values
        let avg = scripted.isEmpty ? 420.0 : Double(scripted.reduce(0, +)) / Double(scripted.count)
        let totalChars = Double(n) + avg * Double(unknownPages)
        seconds += totalChars * pace / speed
        return seconds
    }

    /// "剩余约 1 小时 5 分" / "about 1 h 5 min left"
    static func formatRemaining(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if m < 1 { return L("剩余不到 1 分钟") }
        if m < 60 { return LF("剩余约 %d 分钟", m) }
        return LF("剩余约 %d 小时 %d 分", m / 60, m % 60)
    }
    /// short form for compact UIs: "≈12m" / "≈1h05m"
    static func formatRemainingShort(_ s: Double) -> String {
        let m = max(1, Int((s / 60).rounded()))
        return m < 60 ? "≈\(m)m" : String(format: "≈%dh%02dm", m / 60, m % 60)
    }

    // MARK: control

    /// start narrating; by default resumes from the position saved for this document (survives stop / quit / crash)
    func start(docId: UUID, doc: PDFDocument, title: String, from page: Int, resume: Bool = true) {
        stop()
        // pick up hand edits of config.toml since launch
        let v = Settings.ttsVoice, r = Settings.ttsSpeed, pr = Settings.ttsProvider, sv = Settings.systemVoice
        if voice != v { voice = v }
        if rate != r { rate = r }
        if provider != pr { provider = pr }
        if systemVoice != sv { systemVoice = sv }
        fallbackToSystem = false
        if self.docId != docId { pageChars = [:]; pageCharsMissing = [] }
        self.docId = docId; self.doc = doc; self.title = title
        sourceDoc = Store.shared.session(docId)?.original
        pageCount = doc.pageCount
        error = nil
        guard pageCount > 0 else { return }
        if resume, let s = Narrator.savedProgress(docId), s.page >= 0, s.page < pageCount {
            resumedFrom = s
            play(page: s.page, seg: max(0, s.seg))
        } else {
            resumedFrom = nil
            play(page: max(0, min(pageCount - 1, page)), seg: 0)
        }
    }

    /// ignore the saved position and start at the page currently shown in the reader
    func restartFromCurrentPage() {
        guard let id = docId, let d = doc else { return }
        Narrator.clearProgress(id)
        start(docId: id, doc: d, title: title, from: Narrator.reader.currentPageIndex, resume: false)
    }

    // MARK: persisted progress (per document, voice independent)
    struct Progress: Codable, Equatable { var page: Int; var seg: Int; var date: Date = Date() }
    /// set when the current run resumed from a saved position (shown in the bar)
    @Published var resumedFrom: Progress?
    static func progressURL(_ id: UUID) -> URL {
        let u = Paths.docDir(id).appendingPathComponent("narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("progress.json")
    }
    static func savedProgress(_ id: UUID) -> Progress? {
        guard let d = try? Data(contentsOf: progressURL(id)) else { return nil }
        return try? JSONDecoder().decode(Progress.self, from: d)
    }
    static func saveProgress(_ id: UUID, page: Int, seg: Int) {
        if let d = try? JSONEncoder().encode(Progress(page: page, seg: seg)) { try? d.write(to: progressURL(id), options: .atomic) }
    }
    static func clearProgress(_ id: UUID) { try? FileManager.default.removeItem(at: progressURL(id)) }

    func togglePause() {
        switch state {
        case .playing: player?.pause(); state = .paused
        case .paused:
            if let p = player { p.play(); state = .playing } else { play(page: page, seg: segIndex) }
        default: break
        }
    }

    func stop() {
        runToken = UUID()
        qaPlayer?.stop(); qaPlayer = nil
        if listening { listening = false; VoiceInput.shared.stop { _ in } }
        player?.stop(); player = nil
        state = .idle
        segments = []; segIndex = 0
    }

    func next() { guard state != .idle else { return }; advance() }
    func previous() {
        guard state != .idle else { return }
        if segIndex > 0 { play(page: page, seg: segIndex - 1) }
        else if page > 0 { play(page: page - 1, seg: -1) }
    }
    func jumpToSegment(_ i: Int) { guard docId != nil, i < segments.count else { return }; play(page: page, seg: i) }
    func jump(page p: Int) { guard docId != nil else { return }; play(page: max(0, min(pageCount - 1, p)), seg: 0) }
    /// "从这页开始讲": continue the narration from the page the reader is showing now
    func narrateFromReaderPage() {
        guard docId != nil, state != .idle else { return }
        resumedFrom = nil
        jump(page: Narrator.reader.currentPageIndex)
    }

    // MARK: voice Q&A (interrupt narration)
    @Published var listening = false
    @Published var heard = ""
    @Published var answering = false
    @Published var lastQA: (q: String, a: String)?
    private var resumeAfterQA = false
    private var qaPlayer: AVAudioPlayer?

    func beginQuestion() {
        guard !listening else { return }
        resumeAfterQA = state == .playing
        if state == .playing { player?.pause(); state = .paused }
        qaPlayer?.stop()
        heard = ""
        listening = true
        VoiceInput.shared.start { [weak self] partial in self?.heard = partial }
    }

    func endQuestion() {
        guard listening else { return }
        listening = false
        VoiceInput.shared.stop { [weak self] final in
            guard let self else { return }
            let q = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { if self.resumeAfterQA { self.togglePause() }; return }
            self.heard = q
            self.answer(q)
        }
    }

    func debugAsk(_ q: String) { resumeAfterQA = state == .playing; if state == .playing { player?.pause(); state = .paused }; heard = q; answer(q) }

    private func answer(_ q: String) {
        guard let doc = sourceDoc ?? doc, let pg = doc.safePage(page) else { return }
        answering = true
        let seg = segIndex < segments.count ? segments[segIndex].text : ""
        let sys = "你是正在给用户语音讲解《\(title)》的讲解员，用户在听讲过程中打断你提问。用\(Settings.targetLang)口语回答，简洁清楚（3–6 句话，适合朗读，不要用列表和符号），回答完自然地说一句「我们继续」。"
        let ctx = "当前第 \(page + 1) 页。你刚才讲到：\(seg)\n\n本页原文：\(pg.string ?? "")\n\n用户的问题：\(q)"
        let img = Narrator.jpeg(of: pg)
        Task {
            do {
                let a = try await LLMClient.complete(role: "chat", system: sys, input: LLMInput(text: ctx, images: [img]), maxTokens: 800)
                lastQA = (q, a)
                if let id = docId { CopilotStore.shared.record(docId: id, question: q, answer: a, page: page) }
                let wav = try await synth(a)
                answering = false
                let pl = try makePlayer(wav)
                pl.delegate = self
                qaPlayer = pl
                pl.play()
            } catch {
                answering = false
                self.error = error.localizedDescription
            }
        }
    }

    /// one-off synthesis (not cached per segment)
    private func synth(_ text: String) async throws -> Data {
        if effectiveProvider == .system { return try await systemSynth(text, urgent: true) }
        do { return try await Narrator.gatewaySpeech(text, voice: voice) }
        catch let e as TranslateError where Narrator.isConfigError(e) {
            fallbackToSystem = true; fallbackReason = e.errorDescription ?? ""
            return try await systemSynth(text, urgent: true)
        }
    }

    /// Settings → "试听": synthesize a short sample with the selected engine (no automatic fallback) and play it
    func previewVoice() async throws {
        let sample = Settings.targetLang.contains("English") ? "Hi, this is how narration will sound in Readit." : (Settings.targetLang.contains("日本") ? "こんにちは。Readit の解説はこの声で読み上げます。" : "你好，这是 Readit 讲解时会用到的声音。")
        let wav: Data
        if provider == .gateway { wav = try await Narrator.gatewaySpeech(sample, voice: voice) }
        else { wav = try await systemSynth(sample, urgent: true) }
        resumeAfterQA = false
        let pl = try makePlayer(wav)
        qaPlayer?.stop()
        pl.delegate = self
        qaPlayer = pl
        pl.play()
    }

    /// macOS voices: one utterance at a time; the clip playback is waiting for goes first
    private struct SystemRequest {
        let text: String, voice: String, lang: String
        let cont: CheckedContinuation<Data, Error>
    }
    private var systemQueue: [SystemRequest] = []
    private var systemBusy = false
    private func systemSynth(_ text: String, urgent: Bool = false) async throws -> Data {
        let vid = systemVoice, lang = Settings.targetLang
        return try await withCheckedThrowingContinuation { c in
            let r = SystemRequest(text: text, voice: vid, lang: lang, cont: c)
            if urgent { systemQueue.insert(r, at: 0) } else { systemQueue.append(r) }
            pumpSystem()
        }
    }
    private func promoteSystem(_ text: String) {
        guard let i = systemQueue.firstIndex(where: { $0.text == text }), i > 0 else { return }
        systemQueue.insert(systemQueue.remove(at: i), at: 0)
    }
    private func pumpSystem() {
        guard !systemBusy, !systemQueue.isEmpty else { return }
        systemBusy = true
        let r = systemQueue.removeFirst()
        Task { @MainActor in
            do {
                let d = try await SystemTTS.synthesize(r.text, voiceId: r.voice, target: r.lang)
                r.cont.resume(returning: d)
            } catch { r.cont.resume(throwing: error) }
            self.systemBusy = false
            self.pumpSystem()
        }
    }

    /// OpenAI-compatible POST {base}/v1/audio/speech → cleaned WAV
    nonisolated static func gatewaySpeech(_ text: String, voice v: String, attempts: Int = 1) async throws -> Data {
        let k = Settings.apiKey
        let base = Settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/v1/audio/speech") else { throw TranslateError.bad("Base URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": ModelConfig.ttsModel, "input": text, "voice": v, "instructions": Narrator.styleInstruction, "response_format": "wav"])
        var last: Error = TranslateError.bad("TTS 失败")
        for attempt in 0..<max(1, attempts) {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, data.count > 1000 { return Narrator.cleanWAV(data) }
                last = TranslateError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
                if (400..<500).contains(code) && code != 429 { throw last }      // config problem: don't retry
            } catch let e as TranslateError { throw e }
            catch { last = error }
            if attempt + 1 < attempts { try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1))) }
        }
        throw last
    }

    /// 4xx other than 429: missing TTS model, bad key, unsupported endpoint…
    nonisolated static func isConfigError(_ e: TranslateError) -> Bool {
        if case .http(let c, _) = e { return (400..<500).contains(c) && c != 429 }
        return false
    }

    // MARK: engine

    private func play(page p: Int, seg: Int) {
        let token = UUID(); runToken = token
        player?.stop(); player = nil
        page = p
        state = .preparing
        if Narrator.reader.currentPageIndex != p { Narrator.reader.goToPage(p) }
        // next pages' scripts start while this one loads (fresh token: never re-plans audio with stale segments)
        kickScripts(after: p, token: UUID())
        Task {
            do {
                let segs = try await script(for: p)
                guard token == runToken else { return }
                segments = segs
                if segs.isEmpty { advancePage(); return }
                let i = seg < 0 ? segs.count - 1 : min(seg, segs.count - 1)
                segIndex = i
                if let id = docId { Narrator.saveProgress(id, page: p, seg: i) }
                prefetch(page: p, from: i + 1)
                let wav = try await audio(page: p, seg: i, text: segs[i].text, urgent: true)
                guard token == runToken else { return }
                let pl = try makePlayer(wav)
                pl.delegate = self
                currentWav = wav
                player = pl
                state = .playing
                let t = segs[i].text
                Narrator.reader.segmentMentionsFigure = t.range(of: "(图|表|横轴|纵轴|曲线|柱状|折线|示意|figure|table)", options: [.regularExpression, .caseInsensitive]) != nil
                Narrator.reader.highlightNarration(page: p, quote: segs[i].focus)
                if recording { recorded.insert("\(p)-\(i)") }
                pl.play()
            } catch {
                guard token == runToken else { return }
                self.error = error.localizedDescription
                state = .paused
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === p { self.advance() }
            else if self.qaPlayer === p {
                self.qaPlayer = nil
                if self.resumeAfterQA, self.state == .paused { self.player?.play(); self.state = .playing }
            }
        }
    }

    private func advance() {
        if segIndex + 1 < segments.count { play(page: page, seg: segIndex + 1) } else { advancePage() }
    }

    private func advancePage() {
        if page + 1 < pageCount { play(page: page + 1, seg: 0) }
        else {
            if let id = docId { Narrator.clearProgress(id) }     // finished the document: next start begins fresh
            stop(); resumedFrom = nil; Narrator.reader.clearNarrationHighlight()
        }
    }

    // MARK: look-ahead
    //
    // Two independent pipelines so playback rarely waits:
    //  • scripts: the next `scriptPagesAhead` pages are written in parallel as soon as a page starts;
    //  • audio: everything already scripted is synthesized up to `bufferSeconds` of listening time
    //    (at the current speed; at least `minBufferSegments`, at most `maxBufferSegments`), with a sliding
    //    window of requests in flight. It never blocks on a script that is still being written — when that
    //    script lands, the audio plan is extended.

    /// listening time to keep synthesized ahead (seconds at the current speed); `tts.buffer_seconds`
    static var bufferSeconds: Double { Double(max(30, ConfigFile.int("tts.buffer_seconds") ?? UserDefaults.standard.object(forKey: "narrBufferSeconds") as? Int ?? 300)) }
    /// pages whose scripts are prepared ahead; `tts.script_pages_ahead`
    static var scriptPagesAhead: Int { max(1, min(10, ConfigFile.int("tts.script_pages_ahead") ?? UserDefaults.standard.object(forKey: "narrScriptPagesAhead") as? Int ?? 3)) }
    static let minBufferSegments = 12
    static let maxBufferSegments = 60
    /// kept for the UI counter
    static var bufferAhead: Int { maxBufferSegments }
    private var prefetchToken = UUID()

    private func cachedScript(_ p: Int) -> [Segment]? {
        guard let d = try? Data(contentsOf: cacheDir().appendingPathComponent("p\(p).json")) else { return nil }
        return try? JSONDecoder().decode([Segment].self, from: d)
    }
    private func audioURL(_ p: Int, _ i: Int, tag: String) -> URL { cacheDir().appendingPathComponent("p\(p)-s\(i)-\(tag)-v2.wav") }

    /// start writing scripts for the pages after `p` (parallel, deduplicated by `script(for:)`)
    private func kickScripts(after p: Int, token: UUID) {
        guard pageCount > 0 else { return }
        for k in 1...Narrator.scriptPagesAhead where p + k < pageCount {
            let pg = p + k
            if chars(ofPage: pg) != nil { continue }       // already written (in flight ones are joined below)
            Task {
                guard let segs = try? await self.script(for: pg), !segs.isEmpty else { return }
                // a new script widens what the audio pipeline can buffer
                if token == self.prefetchToken, self.page == p { self.prefetch(page: p, from: self.segIndex + 1) }
            }
        }
    }

    private func prefetch(page p: Int, from i: Int) {
        let token = UUID(); prefetchToken = token
        kickScripts(after: p, token: token)
        let first = segments, tag = voiceTag
        let pace = Narrator.pace, speed = Double(max(0.25, rate)), target = Narrator.bufferSeconds
        // plan: upcoming segments over pages that are already scripted, skipping cached audio
        var plan: [(Int, Int, String)] = []
        var ahead = 0.0, count = 0
        var pg = p, k = i, segs = first
        while count < Narrator.maxBufferSegments && (ahead < target || count < Narrator.minBufferSegments) {
            if k < segs.count {
                let t = segs[k].text
                if !FileManager.default.fileExists(atPath: audioURL(pg, k, tag: tag).path) { plan.append((pg, k, t)) }
                ahead += Double(t.count) * pace / speed; count += 1; k += 1
                continue
            }
            pg += 1; k = 0
            guard pg < pageCount, let next = cachedScript(pg) else { break }   // not written yet → kickScripts re-triggers
            segs = next
        }
        guard !plan.isEmpty else { refreshBuffered(); return }
        let width = effectiveProvider == .gateway ? 4 : 2
        Task {
            // sliding window: start the next request as soon as one finishes, in playback order
            await withTaskGroup(of: Void.self) { g in
                var it = plan.makeIterator()
                for _ in 0..<width {
                    guard let x = it.next() else { break }
                    g.addTask { _ = try? await self.audio(page: x.0, seg: x.1, text: x.2) }
                }
                while await g.next() != nil {
                    guard token == self.prefetchToken, let x = it.next() else { continue }
                    g.addTask { _ = try? await self.audio(page: x.0, seg: x.1, text: x.2) }
                }
            }
        }
    }

    /// segments buffered (audio ready) ahead of the current one — shown in the UI
    @Published var buffered = 0
    func refreshBuffered() {
        guard docId != nil else { buffered = 0; return }
        var n = 0, pg = page, k = segIndex + 1
        var segs = segments
        let tag = voiceTag
        while n < Narrator.maxBufferSegments {
            if k >= segs.count {
                pg += 1; k = 0
                let u = cacheDir().appendingPathComponent("p\(pg).json")
                guard pg < pageCount, let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([Segment].self, from: d) else { break }
                segs = s
                continue
            }
            if FileManager.default.fileExists(atPath: cacheDir().appendingPathComponent("p\(pg)-s\(k)-\(tag)-v2.wav").path) { n += 1; k += 1 } else { break }
        }
        if buffered != n { buffered = n }
    }

    // MARK: script (Claude, with the page image so figures/tables are explained)

    private func cacheDir() -> URL {
        let u = Paths.docDir(docId ?? UUID()).appendingPathComponent("narration", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func script(for p: Int) async throws -> [Segment] {
        let url = cacheDir().appendingPathComponent("p\(p).json")
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([Segment].self, from: d) { return s }
        if let t = scriptTasks[p] { return try await t.value }
        guard let doc = sourceDoc ?? doc, let pg = doc.safePage(p) else { return [] }
        let text = pg.string ?? ""
        let image = Narrator.jpeg(of: pg)
        let prevText = p > 0 ? String((doc.safePage(p - 1)?.string ?? "").suffix(600)) : ""
        let title = self.title, total = doc.pageCount, lang = Settings.targetLang
        let task = Task<[Segment], Error> {
            let sys = """
            你是一位擅长把学术论文讲给普通人听的讲解员，正在以播客口吻逐页讲解《\(title)》。用\(lang)口语讲解。
            要求：
            - 不要逐句翻译，而是用人能轻松听懂的方式解释本页在讲什么、为什么重要；术语第一次出现时用一句话解释。
            - 页面上的图表、表格、公式要专门讲：它展示了什么、怎么看、得出什么结论。
            - 分成 3–7 段，每段 2–4 句话（适合朗读，避免括号、符号、长串数字和网址；公式用口语表达）。
            - 自然衔接上一页，不要每页都重新打招呼；第一页可以简短开场。参考文献、附录这类页面一两句带过即可。
            只输出 JSON 数组：[{"text": "朗读内容", "focus": "本段讲解对应的页面原文片段：复制该段落开头的 6~15 个连续单词（必须逐字出自页面文字，不要只给一个词或数字）；讲图表时填图注开头，如 Figure 2"}]
            """
            let out = try await LLMClient.complete(role: "chat", system: sys, input: LLMInput(text: "这是第 \(p + 1)/\(total) 页。\n上一页结尾：\(prevText)\n\n本页文字：\n\(text)", images: [image]), maxTokens: 3000)
            var t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = t.range(of: "\\[[\\s\\S]*\\]", options: .regularExpression) { t = String(t[r]) }
            guard let d = t.data(using: .utf8), let segs = try? JSONDecoder().decode([Segment].self, from: d), !segs.isEmpty else {
                // fallback: plain paragraphs
                return out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 8 }.map { Segment(text: $0, focus: nil) }
            }
            return segs
        }
        scriptTasks[p] = task
        defer { scriptTasks[p] = nil }
        let segs = try await task.value
        if let d = try? JSONEncoder().encode(segs) { try? d.write(to: url) }
        pageChars[p] = segs.reduce(0) { $0 + $1.text.count }; pageCharsMissing.remove(p)
        return segs
    }

    // MARK: TTS (gemini-3.8-flash-tts via gateway, OpenAI-compatible /v1/audio/speech)

    func audio(page p: Int, seg i: Int, text: String, urgent: Bool = false) async throws -> Data {
        let url = cacheDir().appendingPathComponent("p\(p)-s\(i)-\(voiceTag)-v2.wav")
        if let d = try? Data(contentsOf: url), d.count > 1000 {
            let w = Narrator.cleanWAV(d); learnPace(key: url.lastPathComponent, text: text, wav: w); return w
        }
        let key = url.lastPathComponent
        if let t = audioTasks[key] {
            if urgent { promoteSystem(text) }                   // the clip we are waiting on jumps the queue
            return try await t.value
        }
        let useGateway = effectiveProvider == .gateway, v = voice
        let task = Task<Data, Error> { @MainActor in
            if !useGateway { return try await self.systemSynth(text, urgent: urgent) }
            return try await Narrator.gatewaySpeech(text, voice: v, attempts: 3)
        }
        audioTasks[key] = task
        defer { audioTasks[key] = nil }
        let d: Data
        do { d = try await task.value }
        catch let e as TranslateError where useGateway && Narrator.isConfigError(e) {
            // gateway has no usable TTS: switch this run to the macOS voice and tell the user why
            if !fallbackToSystem { fallbackToSystem = true; fallbackReason = e.errorDescription ?? "" }
            return try await audio(page: p, seg: i, text: text, urgent: urgent)
        }
        try? d.write(to: url, options: .atomic)
        learnPace(key: key, text: text, wav: d)
        refreshBuffered()
        return d
    }

    /// The gateway wraps the TTS WAV inside another WAV and appends C2PA/SynthID metadata after the PCM.
    /// Played as-is, that metadata is a burst of noise at the end of every clip. Extract the innermost PCM
    /// and rebuild a clean WAV with a short fade-out.
    nonisolated static func cleanWAV(_ d: Data) -> Data {
        func u32(_ o: Int) -> Int { o + 4 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 | Int(d[o+2]) << 16 | Int(d[o+3]) << 24 : 0 }
        func u16(_ o: Int) -> Int { o + 2 <= d.count ? Int(d[o]) | Int(d[o+1]) << 8 : 0 }
        func tag(_ o: Int) -> String { o + 4 <= d.count ? String(bytes: d[o..<o+4], encoding: .ascii) ?? "" : "" }
        // walk nested RIFF headers, keep the innermost fmt + data
        var pos = 0, fmtAt = -1, dataAt = -1, dataLen = 0
        var guardN = 0
        while pos + 12 <= d.count, tag(pos) == "RIFF", tag(pos + 8) == "WAVE", guardN < 4 {
            guardN += 1
            var c = pos + 12
            var nested = false
            while c + 8 <= d.count {
                let id = tag(c), sz = u32(c + 4)
                if id == "fmt " { fmtAt = c + 8 }
                if id == "data" {
                    dataAt = c + 8; dataLen = min(sz, d.count - dataAt)
                    if tag(dataAt) == "RIFF" { pos = dataAt; nested = true }
                    break
                }
                c += 8 + sz + (sz & 1)
            }
            if !nested { break }
        }
        guard fmtAt > 0, dataAt > 0, u16(fmtAt) == 1 else { return d }
        let ch = u16(fmtAt + 2), rate = u32(fmtAt + 4), bits = u16(fmtAt + 14)
        guard bits == 16, ch > 0 else { return d }
        var pcm = Data(d[dataAt..<(dataAt + dataLen - dataLen % (2 * ch))])
        // 15 ms fade-out to avoid a click at the very end
        let fadeSamples = min(pcm.count / 2 / ch, rate * 15 / 1000)
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            let n = p.count / ch
            for k in 0..<fadeSamples {
                let g = Double(k) / Double(max(1, fadeSamples))
                for c in 0..<ch { let idx = (n - 1 - k) * ch + c; p[idx] = Int16(Double(Int16(littleEndian: p[idx])) * g).littleEndian }
            }
        }
        var out = Data()
        func w32(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func w16(_ v: Int) { var x = UInt16(v).littleEndian; out.append(Data(bytes: &x, count: 2)) }
        out.append("RIFF".data(using: .ascii)!); w32(36 + pcm.count); out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!); w32(16); w16(1); w16(ch); w32(rate); w32(rate * ch * 2); w16(ch * 2); w16(16)
        out.append("data".data(using: .ascii)!); w32(pcm.count); out.append(pcm)
        return out
    }

    static func jpeg(of page: PDFPage) -> Data {
        let b = page.bounds(for: .cropBox)
        let scale = min(2.0, 1400 / max(b.width, b.height))
        let img = page.thumbnail(of: NSSize(width: b.width * scale, height: b.height * scale), for: .cropBox)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let j = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else { return Data() }
        return j
    }
}

