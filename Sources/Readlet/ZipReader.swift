import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal in-process ZIP extractor (stored + deflate), used for EPUB import. Spawning `ditto`/`unzip`
/// isn't available inside the App Store sandbox, and EPUBs are ordinary ZIP files.
enum ZipReader {
    struct Entry { var name: String; var method: UInt16; var compressedSize: Int; var size: Int; var localHeaderOffset: Int }

    enum ZipError: LocalizedError {
        case notZip, unsupported(String), corrupt(String)
        var errorDescription: String? {
            switch self {
            case .notZip: return "not a ZIP archive"
            case .unsupported(let s): return "unsupported ZIP feature: " + s
            case .corrupt(let s): return "corrupt ZIP: " + s
            }
        }
    }

    static func entries(_ d: Data) throws -> [Entry] {
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 : 0 }
        // end of central directory: last 22…65557 bytes
        guard b.count >= 22 else { throw ZipError.notZip }
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 65_557)
        while i >= stop { if u32(i) == 0x06054b50 { eocd = i; break }; i -= 1 }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [Entry] = []
        for _ in 0..<count {
            guard u32(p) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let flags = u16(p + 8)
            if flags & 0x1 != 0 { throw ZipError.unsupported("encryption") }
            let method = UInt16(u16(p + 10))
            let csize = u32(p + 20), size = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32)
            let local = u32(p + 42)
            guard p + 46 + nlen <= b.count else { throw ZipError.corrupt("name") }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            out.append(Entry(name: name, method: method, compressedSize: csize, size: size, localHeaderOffset: local))
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    static func data(of e: Entry, in d: Data) throws -> Data {
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        let lh = e.localHeaderOffset
        guard lh + 30 <= b.count, b[lh] == 0x50, b[lh + 1] == 0x4b, b[lh + 2] == 0x03, b[lh + 3] == 0x04 else { throw ZipError.corrupt("local header") }
        let start = lh + 30 + u16(lh + 26) + u16(lh + 28)
        guard start + e.compressedSize <= b.count else { throw ZipError.corrupt("data range") }
        let raw = Data(b[start..<(start + e.compressedSize)])
        switch e.method {
        case 0: return raw
        case 8: return try inflate(raw, size: e.size)
        default: throw ZipError.unsupported("method \(e.method)")
        }
    }

    static func inflate(_ src: Data, size: Int) throws -> Data {
        #if canImport(Compression)
        guard size > 0 else { return Data() }
        var dst = Data(count: size)
        let n = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                guard let db = d.bindMemory(to: UInt8.self).baseAddress, let sb = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(db, size, sb, src.count, nil, COMPRESSION_ZLIB)   // raw DEFLATE
            }
        }
        guard n == size else { throw ZipError.corrupt("deflate") }
        return dst
        #else
        throw ZipError.unsupported("deflate on this platform")
        #endif
    }

    /// extract everything below `dest` (rejects paths escaping it)
    static func extract(_ zip: URL, to dest: URL) throws {
        let d = try Data(contentsOf: zip)
        let fm = FileManager.default
        let root = dest.standardizedFileURL.path
        for e in try entries(d) {
            if e.name.hasSuffix("/") { continue }
            let target = dest.appendingPathComponent(e.name).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { throw ZipError.corrupt("path outside archive: " + e.name) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data(of: e, in: d).write(to: target)
        }
    }
}
