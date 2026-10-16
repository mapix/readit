import Foundation
import PDFKit
import CoreText
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// One text paragraph on a page, in PDF page space (origin bottom-left of the crop box).
struct Para {
    var text: String
    var rect: CGRect
    var lineHeight: CGFloat
    var pitch: CGFloat = 0          // median baseline distance (0 for single-line)
    var lines: Int
    var translatable: Bool
}

enum Layout {
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    /// One text line (or column piece of a line) with robust typographic metrics.
    struct Line {
        var text: String
        var r: CGRect          // rect used for rendering (inflated formula bounds removed)
        var base: CGFloat      // baseline proxy: median minY of letter glyph boxes
        var fs: CGFloat        // font-size proxy: median letter glyph box height
        var x0: CGFloat, x1: CGFloat
        var bold: Bool
        var col = 0            // -1 = spans both columns, 0 = left/single, 1 = right
    }

    static func median(_ a: [CGFloat]) -> CGFloat { a.isEmpty ? 0 : a.sorted()[a.count / 2] }
    static func pct(_ a: [CGFloat], _ p: Double) -> CGFloat { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, max(0, Int(Double(a.count - 1) * p)))] }

    /// Builds text lines directly from the page's glyph boxes, in content order. PDFKit's
    /// `selectionsByLine()` bounds are unreliable (lines shifted onto their neighbour, formula-inflated
    /// boxes, several columns in one "line"), so geometry comes from `characterBounds` only.
    static func glyphLines(page: PDFPage) -> [Line] {
        let ns = (page.string ?? "") as NSString
        let attr = page.attributedString
        struct G { var b: CGRect; var letter: Bool; var bold: Bool; var pt: CGFloat; var foot: CGFloat? }
        var out: [Line] = []
        var text = ""
        var gl: [G] = []
        var band = CGRect.null
        var lastMaxX: CGFloat = 0
        var vertical = false     // rotated text (axis labels): glyphs stacked vertically
        func finish() {
            defer { text = ""; gl = []; band = .null; vertical = false }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !gl.isEmpty else { return }
            let lh = gl.filter { $0.letter }.map { $0.b.height }
            let boxH = median(lh.isEmpty ? gl.map { $0.b.height } : lh)
            let pts = gl.filter { $0.letter && $0.pt > 0 }.map { $0.pt }
            // font size from the text layer's font (robust against math-inflated boxes)
            var fs = pts.isEmpty ? boxH : median(pts)
            // sub/superscript-heavy math lines: the line's size is its largest well-represented size
            if !pts.isEmpty {
                var cnt: [CGFloat: Int] = [:]
                for p in pts { cnt[(p * 4).rounded() / 4, default: 0] += 1 }
                if let big = cnt.filter({ $0.value >= max(3, pts.count * 15 / 100) }).keys.max(), big > fs { fs = big }
            }

            // baseline proxy from the line's main-size letters only (sub/superscripts excluded)
            var mainYs = gl.filter { $0.letter && $0.pt > 0 && abs($0.pt - fs) < 0.06 * fs && $0.foot != nil }.map { $0.foot! }
            if mainYs.isEmpty { mainYs = gl.filter { $0.letter && $0.pt > 0 && abs($0.pt - fs) < 0.06 * fs }.map { $0.b.minY } }
            if mainYs.isEmpty { mainYs = gl.filter { $0.letter && abs($0.b.height - boxH) < 0.12 * boxH }.map { $0.b.minY } }
            let base = median(mainYs.isEmpty ? gl.map { $0.b.minY } : mainYs)
            // line box from glyphs, dropping tall formula glyphs (∑, fraction bars, radicals)
            var r = CGRect.null
            for g in gl where g.b.height <= 2.6 * fs && g.b.midY > base - 0.7 * fs && g.b.midY < base + 1.7 * fs { r = r.union(g.b) }
            if r.isNull { r = gl.reduce(CGRect.null) { $0.union($1.b) } }
            let x0 = gl.map { $0.b.minX }.min()!, x1 = gl.map { $0.b.maxX }.max()!
            r = CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height)
            let boldN = gl.filter { $0.letter && $0.bold }.count
            out.append(Line(text: t, r: r, base: base, fs: fs, x0: x0, x1: x1, bold: lh.count >= 2 && boldN * 10 >= lh.count * 7))
        }
        // PDFKit's characterBounds(at:) is not index-aligned with page.string on many PDFs (drifts by a
        // few characters per line); a one-character selection is, and is cheap.
        var off = 0   // drift between string index and characterBounds index
        let descenders = Set("gjpqyQ")
        for i in 0..<ns.length {
            let chs = ns.substring(with: NSRange(location: i, length: 1))
            guard let c = chs.unicodeScalars.first else { continue }
            if c == "\n" || c == "\r" { if !text.isEmpty && !text.hasSuffix(" ") { text += " " }; continue }
            if CharacterSet.whitespaces.contains(c) { if !text.isEmpty && !text.hasSuffix(" ") { text += " " }; continue }
            let b = page.selection(for: NSRange(location: i, length: 1))?.bounds(for: page) ?? .zero
            if b.width <= 0 || b.height <= 0 { text += chs; continue }
            let letter = CharacterSet.letters.contains(c)
            if !gl.isEmpty {
                let fsNow = max(2, median(gl.map { $0.b.height }))
                let vov = min(b.maxY, band.maxY) - max(b.minY, band.minY)
                let sameRow = vov > 0.5 * min(b.height, band.height)
                let gap = b.minX - lastMaxX
                let last = gl[gl.count - 1].b
                let xov = min(b.maxX, last.maxX) - max(b.minX, last.minX)
                let vgap = max(last.minY - b.maxY, b.minY - last.maxY)
                let stacked = (gl.count == 1 || vertical) && !sameRow && xov > 0.5 * min(b.width, last.width) && vgap < 0.6 * max(b.height, last.height)
                if stacked { vertical = true }
                else if vertical || !(sameRow && gap > -1.0 * fsNow && gap < max(1.5 * fsNow, 10)) { finish() }
                else if gap > 0.15 * fsNow && !text.hasSuffix(" ") { text += " " }
            }
            var bold = false
            var pt: CGFloat = 0
            if letter, let attr, i < attr.length, let f = attr.attribute(.font, at: i, effectiveRange: nil) as? NSFont {
                pt = f.pointSize
                let nm = f.fontName.lowercased()
                bold = nm.contains("bold") || nm.contains("cmbx") || nm.contains("black") || nm.contains("semibold") || nm.contains("heavy") || f.fontDescriptor.symbolicTraits.contains(.bold)
            }
            // tight glyph box (for the baseline): characterBounds, re-synchronised against the selection box
            var foot: CGFloat?
            if letter, let ch0 = chs.first, !descenders.contains(ch0) {
                for k in [off, off - 1, off + 1, off - 2, off + 2, off - 3, off + 3, off - 4, off + 4] {
                    let j = i + k
                    guard j >= 0, j < ns.length else { continue }
                    let cb = page.characterBounds(at: j)
                    if cb.width > 0, cb.midX > b.minX - 0.3, cb.midX < b.maxX + 0.3, cb.midY > b.minY, cb.midY < b.maxY,
                       abs(cb.width - b.width) < max(0.6, 0.25 * b.width) { off = k; foot = cb.minY; break }
                }
            }
            text += chs
            gl.append(G(b: b, letter: letter, bold: bold, pt: pt, foot: foot))
            // the row band follows the line's regular glyphs, not tall math symbols
            if band.isNull || b.height < 2.5 * max(2, median(gl.map { $0.b.height })) { band = band.isNull ? b : band.union(b) }
            lastMaxX = max(b.maxX, gl.count == 1 ? b.maxX : lastMaxX)
        }
        finish()
        return out
    }

    static let captionRe = try! NSRegularExpression(pattern: "^(Figure|Fig\\.|Table|Algorithm|Listing|Equation)\\s*[0-9A-Z]+[.:|]?", options: [])
    static let headingRe = try! NSRegularExpression(pattern: "^((\\d+(\\.\\d+)*\\.?)|([A-Z]\\.(\\d+\\.?)*)|([IVX]+\\.))\\s+\\S", options: [])
    static let listRe = try! NSRegularExpression(pattern: "^([•●▪◦∙·\\-–—*]|\\(?\\d{1,2}[.)]|\\(?[a-z][.)]|\\([ivx]+\\))\\s+\\S", options: [])
    static let footRe = try! NSRegularExpression(pattern: "^([∗†‡§¶]|\\d{1,2}(?=[A-Z][a-z]))", options: [])
    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }

    /// Splits a page into paragraphs from its text layer.
    static func paragraphs(_ page: PDFPage) -> [Para] {
        let box = page.bounds(for: .cropBox)
        _ = box
        var lines = glyphLines(page: page)
        guard !lines.isEmpty else { return [] }
        if ProcessInfo.processInfo.environment["DEBUG_LINES"] != nil { for l in lines { print(String(format: "L r=[%.1f,%.1f %.1fx%.1f] base=%.1f fs=%.1f x=%.1f-%.1f b=%d ", l.r.minX, l.r.minY, l.r.width, l.r.height, l.base, l.fs, l.x0, l.x1, l.bold ? 1 : 0) + String(l.text.prefix(40))) } }

        // ---- body font size and text area
        let wordy = lines.filter { $0.text.count >= 20 }
        let bodyFs = median((wordy.isEmpty ? lines : wordy).map { $0.fs })
        let body = lines.filter { abs($0.fs - bodyFs) <= 0.15 * bodyFs && $0.text.count >= 10 }
        let areaL = pct((body.isEmpty ? lines : body).map { $0.x0 }, 0.05)
        let areaR = pct((body.isEmpty ? lines : body).map { $0.x1 }, 0.95)
        let mid = (areaL + areaR) / 2, W = max(1, areaR - areaL)

        // ---- column detection
        let leftN = body.filter { $0.x1 < mid + 0.03 * W && $0.x1 - $0.x0 > 0.25 * W }.count
        let rightN = body.filter { $0.x0 > mid - 0.03 * W && $0.x1 - $0.x0 > 0.25 * W }.count
        let twoCol = leftN >= 5 && rightN >= 5 && Double(leftN + rightN) >= 0.5 * Double(max(1, body.count))
        if twoCol {
            for k in lines.indices {
                let l = lines[k]
                if l.x1 < mid + 0.03 * W { lines[k].col = 0 }
                else if l.x0 > mid - 0.03 * W { lines[k].col = 1 }
                else { lines[k].col = -1 }
            }
        }

        // margin material (line numbers, side notes) outside the text area forms its own columns
        for k in lines.indices {
            if lines[k].x1 < areaL - 2 { lines[k].col = 8 } else if lines[k].x0 > areaR + 2 { lines[k].col = 9 }
        }
        // ---- reading order: bands between full-width lines, each column top-down
        let fulls = lines.filter { $0.col == -1 }.map { $0.base }
        func band(_ l: Line) -> Int { fulls.filter { $0 > l.base + 0.3 * l.fs }.count }
        var keyed = lines.map { (band($0), $0) }
        keyed.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            let ca = a.1.col == -1 ? 2 : a.1.col, cb = b.1.col == -1 ? 2 : b.1.col
            if ca != cb { return ca < cb }
            let tol = 0.45 * min(a.1.fs, b.1.fs)
            if abs(a.1.base - b.1.base) > tol { return a.1.base > b.1.base }
            return a.1.x0 < b.1.x0
        }
        // ---- merge fragments on the same visual line (inline math, super/subscripts, PDFKit splits)
        var ordered: [(Int, Line)] = []
        for (bd, l) in keyed {
            if var (pb, p) = ordered.last, pb == bd, p.col == l.col {
                let vov = min(l.r.maxY, p.r.maxY) - max(l.r.minY, p.r.minY)
                let sameRow = vov > 0.5 * min(l.r.height, p.r.height) || abs(l.base - p.base) < 0.45 * max(l.fs, p.fs)
                let gap = l.x0 - p.x1
                if sameRow && gap > -0.5 * p.fs && gap < 1.5 * max(p.fs, l.fs) {
                    let main = l.fs > p.fs * 1.05 && l.text.count > p.text.count ? l : p
                    p.text += (gap > 0.15 * p.fs ? " " : "") + l.text
                    p.r = p.r.union(l.r)
                    p.base = main.base; p.fs = main.fs; p.bold = main.bold && p.bold || main.bold
                    p.x1 = max(p.x1, l.x1)
                    ordered[ordered.count - 1] = (pb, p)
                    continue
                }
            }
            ordered.append((bd, l))
        }

        // ---- page modal line pitch for body text
        var dys: [CGFloat] = []
        for k in 1..<max(1, ordered.count) {
            let (ba, a) = ordered[k - 1], (bb, b) = ordered[k]
            guard ba == bb, a.col == b.col, abs(a.fs - bodyFs) <= 0.15 * bodyFs, abs(b.fs - bodyFs) <= 0.15 * bodyFs else { continue }
            let dy = a.base - b.base
            if dy > 0.8 * bodyFs && dy < 2.6 * bodyFs { dys.append((dy * 4).rounded() / 4) }
        }
        var pagePitch = bodyFs * 1.3
        if !dys.isEmpty {
            var hist: [CGFloat: Int] = [:]
            for d in dys { hist[d, default: 0] += 1 }
            // mode, ties -> smaller pitch
            pagePitch = hist.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
        }
        func pitchFor(_ fs: CGFloat) -> CGFloat { abs(fs - bodyFs) <= 0.15 * bodyFs ? pagePitch : pagePitch * fs / max(1, bodyFs) }
        // right edge of each column (for "short line" tests)
        func colRight(_ c: Int) -> CGFloat {
            let xs = ordered.filter { $0.1.col == c && $0.1.text.count >= 20 }.map { $0.1.x1 }
            return xs.isEmpty ? areaR : pct(xs, 0.85)
        }
        let rights = [-1: colRight(-1), 0: colRight(0), 1: colRight(1)]

        func isHeading(_ l: Line, weak: Bool = true) -> Bool {
            let short = l.text.count < 90 && l.x1 < (rights[l.col] ?? areaR) - 4 * l.fs
            if l.fs > bodyFs * 1.12 && l.text.count < 140 { return true }
            if l.bold && short { return true }
            if weak && short && matches(headingRe, l.text) && l.text.split(separator: " ").count <= 12 && !l.text.hasSuffix(".") , let f = l.text.drop(while: { !$0.isLetter }).first, f.isUppercase { return true }
            return false
        }
        func startsBlock(_ l: Line) -> Bool { matches(captionRe, l.text) || matches(listRe, l.text) || (l.fs < bodyFs * 0.95 && matches(footRe, l.text)) }

        // ---- paragraph assembly
        struct Cur { var text: String; var r: CGRect; var lines: [Line]; var heading: Bool }
        var paras: [Para] = []
        var cur: Cur?
        func close() {
            guard let c = cur else { return }
            cur = nil
            let n = c.lines.count
            let words = c.text.split { !$0.isLetter }.filter { $0.count >= 2 }.count
            let cjk = c.text.filter { isCJK($0) }.count
            let vertical = c.r.height > c.r.width * 2.5 && n == 1
            let numbered = c.text.range(of: "^\\d{1,3}:", options: .regularExpression) != nil || c.text.components(separatedBy: CharacterSet.whitespaces).filter({ $0.range(of: "^\\d{1,3}:$", options: .regularExpression) != nil }).count >= 2
            let letters = c.text.filter { $0.isLetter }.count
            let symbolic = Double(letters) < Double(c.text.filter { !$0.isWhitespace }.count) * 0.6
            let realWords = c.text.split { !$0.isLetter }.filter { $0.count >= 3 && $0.dropFirst().allSatisfy { $0.isLowercase } }.count
            let formula = n <= 2 && (c.text.contains("=") || c.text.contains("(")) && realWords < 4
            let tableRow = c.text.components(separatedBy: CharacterSet.whitespaces).filter { $0.range(of: "^[O(Θ\\d.%±×,\\-–]+", options: .regularExpression) != nil }.count >= 4 && realWords < 6
            let translatable = !tableRow && !formula && !vertical && !numbered && !symbolic && words >= 2 && Double(cjk) < Double(c.text.count) * 0.3 && !(c.text.contains("@") && !c.text.contains(" "))
            var gaps: [CGFloat] = []
            for k in 1..<max(1, n) { let g = c.lines[k - 1].base - c.lines[k].base; if g > 2 { gaps.append(g) } }
            paras.append(Para(text: c.text, rect: c.r, lineHeight: median(c.lines.map { $0.r.height }), pitch: median(gaps), lines: n, translatable: translatable))
        }
        func start(_ l: Line) { cur = Cur(text: l.text, r: l.r, lines: [l], heading: isHeading(l)) }

        var lastBand = -1
        for (bd, l) in ordered {
            guard let c = cur, let p = c.lines.last else { start(l); lastBand = bd; continue }
            let em = max(pitchFor(p.fs) / 1.2, 1)
            let first = c.lines[0]
            let bodyLeft = c.lines.count > 1 ? c.lines[1...].map { $0.x0 }.min()! : first.x0
            let dy = p.base - l.base
            var ownPitch: CGFloat = 0
            if c.lines.count >= 2 { ownPitch = median(zip(c.lines, c.lines.dropFirst()).map { $0.base - $1.base }) }
            let ref = ownPitch > 0.8 * p.fs ? min(ownPitch, pitchFor(p.fs)) : pitchFor(p.fs)
            let ov = min(l.x1, c.r.maxX) - max(l.x0, c.r.minX)
            let lHead = isHeading(l, weak: false)
            // margin material (line numbers) stays one block per line so it never blocks band cuts
            var ok = (bd == lastBand || (l.col == -1 && p.col == -1)) && l.col == p.col && l.col < 8
                && (abs(l.fs - p.fs) <= 0.15 * max(l.fs, p.fs) || (min(l.text.filter { $0.isLetter }.count, 10) < 10 && l.fs < p.fs && !lHead))
                && dy > 0.5 * ref && dy < 1.38 * ref
                && ov > 0.3 * min(l.x1 - l.x0, c.r.width)
                && !startsBlock(l)
            if ok {
                // heading lines only merge with headings of the same style (multi-line titles)
                if (c.heading && !lHead) || (lHead && !isHeading(first, weak: false)) || (c.heading && p.bold != l.bold) { ok = false }
            }
            if ok && !c.heading {
                let ind = l.x0 - bodyLeft
                if c.lines.count == 1 {
                    let listItem = matches(listRe, first.text)
                    if ind > 0.8 * em && !(listItem && ind < 4 * em) { ok = false }        // l is indented: new paragraph
                    if ind < -3.2 * em { ok = false }                                     // first line indented more than ~3em
                } else {
                    if ind > 0.8 * em { ok = false }                                     // indented start of next paragraph
                    if ind < -0.8 * em && !matches(listRe, first.text) { ok = false }
                    if ind < -0.8 * em && matches(listRe, first.text) && l.x0 < first.x0 - 0.8 * em { ok = false }
                }
                // centered short lines (equations, labels) don't join body text
                if l.x0 > bodyLeft + 4 * em && p.x0 > bodyLeft + 4 * em { ok = abs(l.x0 - p.x0) < 0.8 * em }
            }
            if ok {
                var t = c.text
                if t.hasSuffix("-"), let f = l.text.first, f.isLowercase, let b = t.dropLast().last, b.isLetter { t.removeLast(); t += l.text }
                else if let a = t.last, let b = l.text.first, isCJK(a) || isCJK(b) { t += l.text }
                else { t += " " + l.text }
                cur = Cur(text: t, r: c.r.union(l.r), lines: c.lines + [l], heading: c.heading)
            } else {
                close(); start(l)
            }
            lastBand = bd
        }
        close()
        return paras
    }

    /// Line rect whose height is the typical glyph height (formulas with √ or fractions inflate selection bounds).
    static func robustLineRect(page: PDFPage, sel: PDFSelection, rect: CGRect) -> CGRect {
        let range = sel.range(at: 0, on: page)
        guard range.location != NSNotFound, range.length > 3 else { return rect }
        var hs: [CGFloat] = [], ys: [CGFloat] = []
        let ns = (page.string ?? "") as NSString
        let end = min(NSMaxRange(range), ns.length)
        var i = range.location
        while i < end {
            let b = page.characterBounds(at: i)
            if b.height > 0, b.width > 0, b.minX >= rect.minX - 1, b.maxX <= rect.maxX + 1,
               let c = ns.substring(with: NSRange(location: i, length: 1)).unicodeScalars.first, CharacterSet.letters.contains(c) {
                hs.append(b.height); ys.append(b.minY)
            }
            i += 1
        }
        guard hs.count >= 4 else { return rect }
        let h = hs.sorted()[hs.count / 2], y = ys.sorted()[ys.count / 2]
        // normal text: selection height ≈ 1.15–1.6 × glyph box height. Only fix clear outliers.
        let normal = h * 1.6
        if rect.height <= normal * 1.2 { return rect }
        let target = h * 1.35
        return CGRect(x: rect.minX, y: y - (target - h) * 0.45, width: rect.width, height: target)
    }

    /// Splits a line selection into horizontal pieces when there's a large gap between characters (multi-column layouts).
    static func splitColumns(page: PDFPage, sel: PDFSelection, text: String, rect: CGRect) -> [(String, CGRect)] {
        let range = sel.range(at: 0, on: page)
        guard rect.width > 200, range.location != NSNotFound, range.length > 4 else { return [(text, rect)] }
        let ns = (page.string ?? "") as NSString
        guard NSMaxRange(range) <= ns.length else { return [(text, rect)] }
        var pieces: [(String, CGRect)] = []
        var start = range.location
        var prev: CGRect = .null
        var curRect: CGRect = .null
        let h = rect.height
        for i in range.location..<NSMaxRange(range) {
            let b = page.characterBounds(at: i)
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty || b.width <= 0 { continue }
            if !prev.isNull, b.minX - prev.maxX > max(2.2 * h, CGFloat(18)) {
                let s = ns.substring(with: NSRange(location: start, length: i - start)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { pieces.append((s, curRect)) }
                start = i; curRect = .null
            }
            curRect = curRect.isNull ? b : curRect.union(b)
            prev = b
        }
        let s = ns.substring(with: NSRange(location: start, length: NSMaxRange(range) - start)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { pieces.append((s, curRect.isNull ? rect : curRect)) }
        if pieces.count <= 1 { return [(text, rect)] }
        // normalize vertical extent to the line's
        return pieces.map { ($0.0, CGRect(x: $0.1.minX, y: rect.minY, width: $0.1.width, height: rect.height)) }
    }
}

/// Renders a bilingual version of one page as a standalone single-page PDF: the original page's
/// vector content is kept and cut into bands at paragraph boundaries, translations are typeset under
/// their paragraph using the same column geometry.
enum BilingualRenderer {
    /// (cut position in original page, top-down; inserted height) of the last render
    nonisolated(unsafe) static var lastInsertions: [[Double]] = []
    static func median(_ a: [CGFloat]) -> CGFloat { a.isEmpty ? 10 : a.sorted()[a.count / 2] }
    /// approximate original font size of a paragraph
    static func em(_ p: Para) -> CGFloat { p.pitch > 0 && p.pitch < p.lineHeight * 2.2 ? max(p.lineHeight * 1.1, p.pitch / 1.15) : p.lineHeight * 1.1 }

    struct Item { var para: Para; var tr: String; var top: CGFloat; var bottom: CGFloat; var l: CGFloat; var r: CGFloat }
    struct Col { var l: CGFloat; var r: CGFloat; var items: [Item]; var height: CGFloat = 0; var frames: [(Item, CTFrame, CGFloat, CGFloat)] = [] }

    static func render(page: PDFPage, paras: [Para], translations: [String?]) -> Data? {
        let box = page.bounds(for: .cropBox)
        let W = box.width, H = box.height
        let rot = page.rotation
        if rot % 360 != 0 { return page.dataRepresentation } // rotated pages are kept as-is
        // top-down coordinates relative to crop box
        let all = paras.map { (p: $0, t: box.maxY - $0.rect.maxY, b: box.maxY - $0.rect.minY) }
        var items: [Item] = []
        for (i, p) in paras.enumerated() {
            guard p.translatable, let tr = translations[i], !tr.isEmpty else { continue }
            if norm(tr) == norm(p.text) { continue }
            items.append(Item(para: p, tr: tr, top: box.maxY - p.rect.maxY, bottom: box.maxY - p.rect.minY, l: p.rect.minX - box.minX, r: p.rect.maxX - box.minX))
        }
        if items.isEmpty { lastInsertions = []; return singlePageData(page) }
        func valid(_ y: CGFloat) -> Bool { !all.contains { $0.t < y - 0.8 && $0.b > y + 0.8 } }
        var cuts: [CGFloat: [Item]] = [:]
        // cut in the middle of the white gap below a paragraph, so neighbouring glyph ascenders/descenders aren't sliced
        let tops = all.map { $0.t }.sorted()
        func gapCut(after b: CGFloat) -> CGFloat {
            let next = tops.first { $0 > b + 0.5 } ?? H
            return min(H, b + max(1.5, min(6, (next - b) * 0.5)))
        }
        let candidates = all.map { gapCut(after: $0.b) }.sorted()
        for it in items {
            var c: CGFloat = H
            for y in candidates where y >= it.bottom + 1 { if valid(y) { c = min(H, y); break } }
            cuts[c, default: []].append(it)
        }
        var hs: [CGFloat] = []
        for it in items { for _ in 0..<min(6, it.para.lines) { hs.append(em(it.para)) } }
        let base = median(hs)

        // lay out blocks
        struct Block { var y: CGFloat; var cols: [Col]; var height: CGFloat }
        var blocks: [Block] = []
        for y in cuts.keys.sorted() {
            var cols: [Col] = []
            for it in cuts[y]!.sorted(by: { $0.top < $1.top }) {
                if let i = cols.firstIndex(where: { min($0.r, it.r) - max($0.l, it.l) > 0.3 * min($0.r - $0.l, it.r - it.l) }) {
                    cols[i].l = min(cols[i].l, it.l); cols[i].r = max(cols[i].r, it.r); cols[i].items.append(it)
                } else { cols.append(Col(l: it.l, r: it.r, items: [it])) }
            }
            var height: CGFloat = 0
            for ci in cols.indices {
                var cy: CGFloat = 2
                for it in cols[ci].items {
                    let heading = em(it.para) > base * 1.2 && it.para.lines <= 3
                    let size = max(heading ? 8 : min(8, base * 0.8), min(heading ? min(20, base * 1.5) : min(13.5, base * 0.9), em(it.para) * (heading ? 0.8 : 0.84)))
                    let pc = (it.l + it.r) / 2
                    let centered = it.para.lines <= 3 && abs(pc - W / 2) < W * 0.03 && (it.r - it.l) < W * 0.5
                    let indent: CGFloat = centered ? 0 : max(2.5, size * 0.5)
                    let width = max(30, cols[ci].r - cols[ci].l - indent)
                    let (frame, h) = typeset(it.tr, size: size, bold: heading, width: width, centered: centered)
                    cols[ci].frames.append((it, frame, cy, h))
                    _ = indent
                    cy += h + size * 0.45
                }
                cols[ci].height = cy + 1.5
                height = max(height, cols[ci].height)
            }
            guard y.isSane, height.isSane, height >= 0, height < 1e5 else { continue }
            blocks.append(Block(y: y, cols: cols, height: height))
        }
        lastInsertions = blocks.map { [Double($0.y), Double($0.height)] }
        let extra = blocks.reduce(0) { $0 + $1.height }
        let OH = H + extra
        let data = NSMutableData()
        var mb = CGRect(x: 0, y: 0, width: W, height: OH)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mb, nil),
              let cgPage = page.pageRef else { return nil }
        ctx.beginPDFPage(nil)
        var cur: CGFloat = 0
        var y0: CGFloat = 0
        func band(_ a: CGFloat, _ b: CGFloat) {
            guard b - a > 0.3 else { return }
            ctx.saveGState()
            // destination band in output (bottom-left origin)
            let destTop = OH - cur
            ctx.clip(to: CGRect(x: 0, y: destTop - (b - a), width: W, height: b - a))
            // map source band [a,b] (top-down) so that source y=box.maxY-a lands at destTop
            ctx.translateBy(x: -box.minX, y: destTop - (box.maxY - a))
            ctx.drawPDFPage(cgPage)
            ctx.restoreGState()
            cur += b - a
        }
        let accent = CGColor(red: 0.918, green: 0.298, blue: 0.537, alpha: 0.8)
        for blk in blocks {
            band(y0, blk.y); y0 = blk.y
            for col in blk.cols {
                for (it, frame, fy, fh) in col.frames {
                    let heading = em(it.para) > base * 1.2 && it.para.lines <= 3
                    let pc = (it.l + it.r) / 2
                    let centered = it.para.lines <= 3 && abs(pc - W / 2) < W * 0.03 && (it.r - it.l) < W * 0.5
                    let size = max(heading ? 8 : min(8, base * 0.8), min(heading ? min(20, base * 1.5) : min(13.5, base * 0.9), em(it.para) * (heading ? 0.8 : 0.84)))
                    let indent: CGFloat = centered ? 0 : max(2.5, size * 0.5)
                    let top = OH - cur - fy
                    if !centered && !heading {
                        ctx.setFillColor(accent)
                        ctx.fill(CGRect(x: col.l, y: top - fh + 0.5, width: 0.9, height: fh - 1))
                    }
                    ctx.saveGState()
                    ctx.translateBy(x: col.l + indent, y: top - fh)
                    CTFrameDraw(frame, ctx)
                    ctx.restoreGState()
                }
            }
            cur += blk.height
        }
        band(y0, H)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// standalone one-page PDF of `page`, drawn from its CGPDFPage (no PDFPage sharing across documents)
    static func singlePageData(_ page: PDFPage) -> Data? {
        guard let cg = page.pageRef else { return nil }
        let box = page.bounds(for: .cropBox)
        let data = NSMutableData()
        var mb = CGRect(origin: .zero, size: box.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: &mb, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(cg)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    static func typeset(_ text: String, size: CGFloat, bold: Bool, width: CGFloat, centered: Bool) -> (CTFrame, CGFloat) {
        let font = NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = size * (bold ? 0.2 : 0.38)
        ps.alignment = centered ? .center : .justified
        ps.lineBreakMode = .byWordWrapping
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.1, alpha: 1), .paragraphStyle: ps])
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let h = ceil(sz.height) + 1
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: h), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        return (frame, h)
    }
}
