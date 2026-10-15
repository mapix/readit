import Foundation
import AVFoundation

/// Audio plumbing for narration: every engine's output becomes a clean 16-bit mono WAV in memory (what the
/// player, time-stretch and MP4 export expect); clips are cached on disk as AAC (.m4a, ~1/8 of WAV).
enum AudioCodec {
    /// raw little-endian 16-bit mono PCM → WAV
    static func wav(pcm16 d: Data, rate: Int) -> Data {
        var out = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; out.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; out.append(Data(bytes: &x, count: 2)) }
        let body = d.count % 2 == 0 ? d : d.dropLast()
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + body.count); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        out.append(contentsOf: Array("data".utf8)); u32(body.count); out.append(body)
        return out
    }

    static func isWAV(_ d: Data) -> Bool {
        d.count > 12 && Data(d.prefix(4)) == Data("RIFF".utf8) && Data(d.dropFirst(8).prefix(4)) == Data("WAVE".utf8)
    }

    /// any container AVFoundation can read (WAV, MP3, AAC/M4A, FLAC, AIFF…) → clean 16-bit mono WAV
    static func toWAV(_ d: Data, hint: String = "") -> Data? {
        if isWAV(d) {
            let c = Narrator.cleanWAV(d)
            if PCM(wav: c) != nil { return c }          // 16-bit PCM WAV: done
        }
        let ext = hint.isEmpty ? sniffExtension(d) : hint
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("readlet-audio-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try d.write(to: tmp) } catch { return nil }
        return decodeFile(tmp)
    }

    /// decode an audio file to 16-bit mono WAV (keeps its sample rate)
    static func decodeFile(_ url: URL) -> Data? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let src = f.processingFormat
        let rate = src.sampleRate > 0 ? src.sampleRate : 24000
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: src, to: mono) else { return nil }
        let frames = AVAudioFrameCount(max(1, f.length))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else { return nil }
        do { try f.read(into: inBuf) } catch { return nil }
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames + 4096) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, let ch = outBuf.floatChannelData else { return nil }
        let n = Int(outBuf.frameLength)
        var pcm = Data(count: n * 2)
        pcm.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { p[i] = Int16(max(-1, min(1, ch[0][i])) * 32767).littleEndian }
        }
        return wav(pcm16: pcm, rate: Int(rate))
    }

    /// WAV → AAC .m4a (mono, 64 kbps — transparent for speech). Returns false if encoding is unavailable.
    @discardableResult
    static func writeAAC(wav: Data, to url: URL, bitRate: Int = 64_000) -> Bool {
        guard let pcm = PCM(wav: wav), !pcm.samples.isEmpty,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(pcm.rate), channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.samples.count)),
              let ch = buf.floatChannelData else { return false }
        buf.frameLength = AVAudioFrameCount(pcm.samples.count)
        for (i, s) in pcm.samples.enumerated() { ch[0][i] = Float(s) / 32768 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(pcm.rate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).m4a")
        do {
            // scoped so the file is closed (finalized) before moving it into place
            do {
                let f = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try f.write(from: buf)
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    static func sniffExtension(_ d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.count >= 3, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 { return "mp3" }          // ID3
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 { return "mp3" }              // MPEG frame
        if b.count >= 8, String(bytes: b[4..<8], encoding: .ascii) == "ftyp" { return "m4a" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "fLaC" { return "flac" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "OggS" { return "ogg" }
        if b.count >= 4, String(bytes: b[0..<4], encoding: .ascii) == "FORM" { return "aiff" }
        return "mp3"
    }
}
