import Foundation

/// Disk usage of Readlet's data directory and cache housekeeping.
/// Narration audio is the big one (regenerable): it is kept under a size cap, oldest documents first.
enum StorageManager {
    struct Usage: Equatable {
        var audio: Int64 = 0          // narration clips (.m4a / .wav)
        var bilingual: Int64 = 0      // rendered bilingual pages
        var pdfs: Int64 = 0           // imported originals
        var other: Int64 = 0          // library, notes, scripts, translations…
        var total: Int64 { audio + bilingual + pdfs + other }
    }

    static var docsDir: URL { Paths.base.appendingPathComponent("docs", isDirectory: true) }

    static func usage() -> Usage {
        var u = Usage()
        let fm = FileManager.default
        guard let e = fm.enumerator(at: Paths.base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return u }
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            let n = Int64(v.fileSize ?? 0)
            let path = f.path
            if path.contains("/narration/"), f.pathExtension == "m4a" || f.pathExtension == "wav" { u.audio += n }
            else if path.contains("/bi2-") { u.bilingual += n }
            else if f.lastPathComponent == "original.pdf" { u.pdfs += n }
            else { u.other += n }
        }
        return u
    }

    /// clips per document: (docId, bytes, newest modification)
    static func audioByDoc() -> [(id: UUID, bytes: Int64, newest: Date, files: [URL])] {
        let fm = FileManager.default
        var out: [(UUID, Int64, Date, [URL])] = []
        for d in (try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: d.lastPathComponent) else { continue }
            let nd = d.appendingPathComponent("narration", isDirectory: true)
            var bytes: Int64 = 0, newest = Date.distantPast, files: [URL] = []
            for f in (try? fm.contentsOfDirectory(at: nd, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            where f.pathExtension == "m4a" || f.pathExtension == "wav" {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                bytes += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, m > newest { newest = m }
                files.append(f)
            }
            if !files.isEmpty { out.append((id, bytes, newest, files)) }
        }
        return out.map { (id: $0.0, bytes: $0.1, newest: $0.2, files: $0.3) }
    }

    /// delete clips of the least recently narrated documents until the cache fits the limit
    static func enforceAudioLimit(keep: UUID?) {
        let limit = Int64(max(0.2, Settings.ttsCacheLimitGB) * 1_073_741_824)
        var docs = audioByDoc()
        var total = docs.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return }
        docs.sort { $0.newest < $1.newest }
        for d in docs where d.id != keep {
            for f in d.files { try? FileManager.default.removeItem(at: f) }
            total -= d.bytes
            if total <= limit { break }
        }
    }

    static func clearAudio(doc: UUID? = nil) {
        for d in audioByDoc() where doc == nil || d.id == doc {
            for f in d.files { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// rendered bilingual pages; skipped for documents that are open (their pages are in use)
    static func clearBilingual(doc: UUID? = nil, open: Set<UUID>) {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil)) ?? [] {
            guard let id = UUID(uuidString: d.lastPathComponent), doc == nil || id == doc, !open.contains(id) else { continue }
            for sub in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] where sub.lastPathComponent.hasPrefix("bi2-") {
                try? fm.removeItem(at: sub)
            }
        }
    }

    /// convert WAV clips written by older builds to AAC; returns bytes saved
    static func compressLegacyClips(progress: ((Int, Int) -> Void)? = nil) -> Int64 {
        let wavs = audioByDoc().flatMap { $0.files }.filter { $0.pathExtension == "wav" }
        var saved: Int64 = 0
        for (k, w) in wavs.enumerated() {
            progress?(k, wavs.count)
            guard let d = try? Data(contentsOf: w), d.count > 1000 else { continue }
            let m4a = w.deletingLastPathComponent().appendingPathComponent(
                w.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-v2", with: "-v3") + ".m4a")
            if AudioCodec.writeAAC(wav: Narrator.cleanWAV(d), to: m4a) {
                let after = (try? m4a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                saved += Int64(d.count - after)
                try? FileManager.default.removeItem(at: w)
            }
        }
        progress?(wavs.count, wavs.count)
        return saved
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
