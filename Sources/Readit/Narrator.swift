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

    @Published var rate: Float = UserDefaults.standard.object(forKey: "narrRate2") as? Float ?? 1.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "narrRate2"); applyRate(old: oldValue) }
    }
    @Published var voice: String = UserDefaults.standard.string(forKey: "narrVoice") ?? "Zephyr" {
        didSet { UserDefaults.standard.set(voice, forKey: "narrVoice") }
    }
    static let voices = ["Zephyr", "Leda", "Aoede", "Kore", "Puck", "Charon", "Fenrir", "Orus"]
    static let voiceNames = ["Leda": "Leda · 年轻轻松女声", "Aoede": "Aoede · 温柔女声", "Kore": "Kore · 沉稳女声", "Zephyr": "Zephyr · 明亮女声", "Puck": "Puck · 活泼男声", "Charon": "Charon · 知性男声", "Fenrir": "Fenrir · 激昂男声", "Orus": "Orus · 低沉男声"]
    static let styleInstruction = "用年轻、轻松、亲切的语气朗读，像和朋友聊天一样自然，语调有起伏，不要播音腔。"
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

    // MARK: control

    /// start narrating; by default resumes from the position saved for this document (survives stop / quit / crash)
    func start(docId: UUID, doc: PDFDocument, title: String, from page: Int, resume: Bool = true) {
        stop()
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
        let k = Settings.apiKey
        let base = Settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var req = URLRequest(url: URL(string: base + "/v1/audio/speech")!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": Narrator.ttsModel, "input": text, "voice": voice, "instructions": Narrator.styleInstruction, "response_format": "wav"])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { throw TranslateError.bad("语音合成失败") }
        return Narrator.cleanWAV(data)
    }

    // MARK: engine

    private func play(page p: Int, seg: Int) {
        let token = UUID(); runToken = token
        player?.stop(); player = nil
        page = p
        state = .preparing
        if Narrator.reader.currentPageIndex != p { Narrator.reader.goToPage(p) }
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
                let wav = try await audio(page: p, seg: i, text: segs[i].text)
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

    /// keep ~10 upcoming segments synthesized (spanning into following pages), 3 requests in flight
    static let bufferAhead = 10
    private var prefetchToken = UUID()

    private func prefetch(page p: Int, from i: Int) {
        let token = UUID(); prefetchToken = token
        let first = segments
        Task {
            // collect (page, seg, text) for the next N segments
            var plan: [(Int, Int, String)] = []
            var pg = p, k = i, segs = first
            while plan.count < Narrator.bufferAhead {
                if k < segs.count { plan.append((pg, k, segs[k].text)); k += 1; continue }
                pg += 1; k = 0
                guard pg < pageCount, token == prefetchToken, let next = try? await script(for: pg) else { break }
                segs = next
            }
            var idx = 0
            while idx < plan.count, token == prefetchToken {
                await withTaskGroup(of: Void.self) { g in
                    for (pp, ss, tt) in plan[idx..<min(plan.count, idx + 3)] { g.addTask { _ = try? await self.audio(page: pp, seg: ss, text: tt) } }
                }
                idx += 3
            }
        }
    }

    /// segments buffered (audio ready) ahead of the current one — shown in the UI
    @Published var buffered = 0
    func refreshBuffered() {
        guard docId != nil else { buffered = 0; return }
        var n = 0, pg = page, k = segIndex + 1
        var segs = segments
        while n < Narrator.bufferAhead {
            if k >= segs.count {
                pg += 1; k = 0
                let u = cacheDir().appendingPathComponent("p\(pg).json")
                guard pg < pageCount, let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode([Segment].self, from: d) else { break }
                segs = s
                continue
            }
            if FileManager.default.fileExists(atPath: cacheDir().appendingPathComponent("p\(pg)-s\(k)-\(voice)-v2.wav").path) { n += 1; k += 1 } else { break }
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
        return segs
    }

    // MARK: TTS (gemini-3.8-flash-tts via gateway, OpenAI-compatible /v1/audio/speech)

    func audio(page p: Int, seg i: Int, text: String) async throws -> Data {
        let url = cacheDir().appendingPathComponent("p\(p)-s\(i)-\(voice)-v2.wav")
        if let d = try? Data(contentsOf: url), d.count > 1000 { return Narrator.cleanWAV(d) }
        let key = url.lastPathComponent
        if let t = audioTasks[key] { return try await t.value }
        let v = voice
        let task = Task<Data, Error> {
            let k = Settings.apiKey
            let base = Settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var req = URLRequest(url: URL(string: base + "/v1/audio/speech")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 120
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer " + k, forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": Narrator.ttsModel, "input": text, "voice": v, "instructions": Narrator.styleInstruction, "response_format": "wav"])
            var last: Error = TranslateError.bad("TTS 失败")
            for attempt in 0..<3 {
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code == 200, data.count > 1000 { return Narrator.cleanWAV(data) }
                    last = TranslateError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
                } catch { last = error }
                try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
            }
            throw last
        }
        audioTasks[key] = task
        defer { audioTasks[key] = nil }
        let d = try await task.value
        try? d.write(to: url, options: .atomic)
        refreshBuffered()
        return d
    }

    /// The gateway wraps the TTS WAV inside another WAV and appends C2PA/SynthID metadata after the PCM.
    /// Played as-is, that metadata is a burst of noise at the end of every clip. Extract the innermost PCM
    /// and rebuild a clean WAV with a short fade-out.
    static func cleanWAV(_ d: Data) -> Data {
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

