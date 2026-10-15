import Foundation
import PDFKit
import AppKit

/// PDFDocument whose pages draw with the theme tint
/// plain PDFDocument (theme tint is applied as a view overlay; subclassing PDFPage.draw caused
/// PDFKit lock re-entrancy crashes in its accessibility code)
typealias TintedDocument = PDFDocument

final class CardAnnotation: PDFAnnotation {
    var cardId: UUID?
    var signature = ""
}

/// Holds the original document and the progressively-built bilingual document for one Doc.
@MainActor
final class DocSession: ObservableObject {
    let doc: Doc
    let original: PDFDocument
    private(set) var bilingual: PDFDocument
    private var bilingualPageData: [Int: Data] = [:]
    @Published var translatedPages = Set<Int>()
    @Published var failedPages: [Int: String] = [:]
    @Published var running = Set<Int>()
    @Published var progressText = ""
    @Published var doneCount = 0
    @Published var pageProgress: [Int: (Int, Int)] = [:]   // page -> (translated paragraphs, total)
    var isComplete: Bool { translatedPages.count >= pageCount }
    private var paraCache: [Int: [Para]] = [:]
    /// per bilingual page: inserted translation blocks [(cut, height)] in top-down original coordinates
    var insertions: [Int: [[Double]]] = [:]
    private var queue: [Int] = []
    private var active = 0
    private let maxActive = 6
    private var started = false

    var pageCount: Int { original.pageCount }

    init?(doc: Doc) {
        guard let o = TintedDocument(url: Paths.pdf(doc.id)) else { return nil }
        self.doc = doc
        original = o
        // bilingual starts as a copy of the original; pages are replaced as they get translated
        // separate CGPDFDocument: sharing PDFPage copies between two documents makes PDFKit's
        // accessibility/annotation code re-enter the same page lock (os_unfair_lock recursion crash)
        bilingual = o          // placeholder until assembled below
        // load cached translated pages, then build ONE self-contained PDF for the bilingual view
        var pageData: [Int: Data] = [:]
        for i in 0..<o.pageCount {
            let url = pageCacheURL(i)
            if let d = try? Data(contentsOf: url), d.count > 100 {
                pageData[i] = d
                translatedPages.insert(i)
                if let j = try? Data(contentsOf: url.appendingPathExtension("json")), let ins = try? JSONDecoder().decode([[Double]].self, from: j) { insertions[i] = ins }
            }
        }
        bilingualPageData = pageData
        guard let b = DocSession.assemble(original: o, pages: pageData) else { return nil }
        bilingual = b
        applyAnnotations()
        updateProgress()
    }

    /// One PDF: translated pages from their rendered data, the rest from the original — all drawn into a
    /// single CGPDFContext, so PDFKit never sees pages that belong to other (released) documents.
    static func assemble(original o: PDFDocument, pages: [Int: Data]) -> PDFDocument? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else { return nil }
        for i in 0..<o.pageCount {
            var cg: CGPDFPage?
            var holder: CGPDFDocument?
            if let d = pages[i], let provider = CGDataProvider(data: d as CFData), let doc = CGPDFDocument(provider) { holder = doc; cg = doc.page(at: 1) }
            if cg == nil { cg = o.page(at: i)?.pageRef }
            guard let page = cg else { continue }
            var box = page.getBoxRect(.cropBox)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.drawPDFPage(page)
            ctx.endPDFPage()
            _ = holder
        }
        ctx.closePDF()
        return PDFDocument(data: out as Data)
    }

    func document(_ v: Variant) -> PDFDocument { v == .original ? original : bilingual }

    private func pageCacheURL(_ i: Int) -> URL {
        let dir = Paths.docDir(doc.id).appendingPathComponent("bi2-\(Settings.targetLang.hashValueStable)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(i).pdf")
    }

    func paragraphs(_ i: Int) -> [Para] {
        if let p = paraCache[i] { return p }
        guard let page = original.safePage(i) else { return [] }
        let p = Layout.paragraphs(page)
        paraCache[i] = p
        return p
    }

    // MARK: translation scheduling
    /// translate-ahead window: current page + N following (default 2). "全文翻译" sets fullDocument.
    var lookahead: Int { Settings.lookahead }
    @Published var fullDocument = false

    func startBilingual(from page: Int) {
        started = true
        prioritize(page)
    }

    func prioritize(_ page: Int) {
        started = true
        var want: [Int] = []
        let window = [page] + (1...max(1, lookahead)).map { page + $0 }.prefix(lookahead) + [page - 1]
        for p in window where p >= 0 && p < pageCount && !translatedPages.contains(p) && !running.contains(p) { want.append(p) }
        if fullDocument {
            queue.removeAll { want.contains($0) }
            queue.insert(contentsOf: want, at: 0)
        } else {
            queue = want      // forget pages we scrolled away from
        }
        pump()
    }

    func translateWholeDocument(from page: Int) {
        fullDocument = true
        let order = Array(page..<pageCount) + Array(0..<page)
        queue = order.filter { !translatedPages.contains($0) && !running.contains($0) }
        started = true
        pump()
    }

    func retranslate(_ page: Int) async {
        let texts = paragraphs(page).filter { $0.translatable }.map { $0.text }
        for t in texts { await TranslationCache.shared.set(Translator.key(t), "") }
        translatedPages.remove(page)
        try? FileManager.default.removeItem(at: pageCacheURL(page))
        queue.insert(page, at: 0)
        started = true
        pump()
    }

    private func pump() {
        while active < maxActive, !queue.isEmpty {
            let p = queue.removeFirst()
            if translatedPages.contains(p) || running.contains(p) { continue }
            active += 1
            running.insert(p)
            updateProgress()
            Task { await self.translatePage(p); self.active -= 1; self.running.remove(p); self.updateProgress(); self.pump() }
        }
    }

    private func updateProgress() {
        let done = translatedPages.count
        doneCount = done
        progressText = done >= pageCount ? L("全文已翻译") : LF("已翻译 %d/%d 页", done, pageCount)
    }

    private func translatePage(_ i: Int) async {
        let paras = paragraphs(i)
        let idx = paras.indices.filter { paras[$0].translatable }
        var trs = [String?](repeating: nil, count: paras.count)
        pageProgress[i] = (0, idx.count)
        defer { pageProgress[i] = nil }
        do {
            // batch by size
            var batches: [[Int]] = [], cur: [Int] = [], size = 0
            for k in idx {
                let n = paras[k].text.count
                if !cur.isEmpty && (size + n > 1800 || cur.count >= 10) { batches.append(cur); cur = []; size = 0 }
                cur.append(k); size += n
            }
            if !cur.isEmpty { batches.append(cur) }
            try await withThrowingTaskGroup(of: ([Int], [String]).self) { g in
                for b in batches {
                    let texts = b.map { paras[$0].text }
                    g.addTask { (b, try await Translator.translate(texts)) }
                }
                for try await (b, res) in g {
                    for (j, k) in b.enumerated() { trs[k] = res[j] }
                    let cur = pageProgress[i] ?? (0, idx.count)
                    pageProgress[i] = (cur.0 + b.count, cur.1)
                }
            }
        } catch {
            failedPages[i] = error.localizedDescription
            return
        }
        failedPages[i] = nil
        guard let page = original.safePage(i), let data = BilingualRenderer.render(page: page, paras: paras, translations: trs),
              let pd = TintedDocument(data: data), let np = pd.safePage(0) else { return }
        let ins = BilingualRenderer.lastInsertions
        try? data.write(to: pageCacheURL(i))
        try? JSONEncoder().encode(ins).write(to: pageCacheURL(i).appendingPathExtension("json"))
        _ = np
        bilingualPageData[i] = data
        let target = DocWindows.shared.entries[doc.id]?.reader
        let swap: (@escaping () -> Void) -> Void = { w in if let r = target { r.enqueueSwap(self, page: i, w) } else { w() } }
        swap { [weak self] in
            guard let self else { return }
            self.insertions[i] = ins
            self.rebuildBilingual()
        }
        translatedPages.insert(i)
        updateProgress()
        NotificationCenter.default.post(name: .bilingualPageReady, object: self, userInfo: ["page": i])
    }

    /// top-down y on the bilingual page (with `ins`) → y on the original page, and back
    static func toOriginal(_ y: CGFloat, _ ins: [[Double]]) -> CGFloat {
        var acc: CGFloat = 0
        guard y.isSane else { return 0 }
        for b in ins.filter({ $0.count >= 2 && $0[0].isFinite && $0[1].isFinite }).sorted(by: { $0[0] < $1[0] }) {
            let cut = CGFloat(b[0]), h = CGFloat(b[1])
            if y < cut + acc { break }
            if y < cut + acc + h { return cut }          // inside an inserted block: map to its cut
            acc += h
        }
        return y - acc
    }
    static func fromOriginal(_ y: CGFloat, _ ins: [[Double]]) -> CGFloat {
        var acc: CGFloat = 0
        guard y.isSane else { return 0 }
        for b in ins where b.count >= 2 && b[0].isFinite && b[1].isFinite && CGFloat(b[0]) <= y { acc += CGFloat(b[1]) }
        return y + acc
    }

    /// rebuild the bilingual PDF from all translated pages (pending swaps are batched by the reader)
    private var rebuildPending = false
    func rebuildBilingual() {
        guard let nb = DocSession.assemble(original: original, pages: bilingualPageData) else { return }
        bilingual = nb
        applyAnnotations(variant: .bilingual)
        DocWindows.shared.entries[doc.id]?.reader.documentReplaced(self)
    }

    private func replaceBilingualPage(_ i: Int, with p: PDFPage) {
        guard i < bilingual.pageCount else { return }
        bilingual.removePage(at: i)
        bilingual.insert(p, at: i)
    }

    // MARK: annotations (highlights for cards)
    func applyAnnotations(page: Int? = nil, variant: Variant? = nil) {
        let cards = Store.shared.lib.cards.filter { $0.docId == doc.id }
        for v in [Variant.original, .bilingual] where variant == nil || variant == v {
            let d = document(v)
            for c in cards where c.variant == v && (page == nil || c.page == page) {
                addAnnotations(c, to: d)
            }
        }
    }

    private func addAnnotations(_ c: Card, to d: PDFDocument) {
        guard let p = d.safePage(c.page) else { return }
        let old = p.annotations.filter { ($0 as? CardAnnotation)?.cardId == c.id }
        let sig = "\(c.color)|\(c.commentText)|\(c.rects.count)|\(c.isImage)"
        if !old.isEmpty, old.allSatisfy({ ($0 as? CardAnnotation)?.signature == sig }) { return }   // unchanged
        old.forEach { p.removeAnnotation($0) }
        let col = highlightColors[c.color % highlightColors.count]
        if c.isImage, let r = c.rects.first {
            let a = CardAnnotation(bounds: r, forType: .square, withProperties: nil)
            a.cardId = c.id; a.signature = sig
            a.color = col
            a.interiorColor = col.withAlphaComponent(0.10)
            let b = PDFBorder(); b.lineWidth = 1.5; a.border = b
            p.addAnnotation(a)
            return
        }
        // one highlight annotation per card; lines are merged so overlapping rects never stack colours
        let lines = mergedLines(c.rects)
        guard !lines.isEmpty else { return }
        let union = lines.reduce(CGRect.null) { $0.union($1) }
        let a = CardAnnotation(bounds: union, forType: .highlight, withProperties: nil)
        a.cardId = c.id; a.signature = sig
        a.color = col.withAlphaComponent(0.42)
        var quads: [NSValue] = []
        for r in lines {
            // quadPoints are relative to the annotation origin: TL, TR, BL, BR
            let x0 = r.minX - union.minX, x1 = r.maxX - union.minX, y0 = r.minY - union.minY, y1 = r.maxY - union.minY
            quads += [NSValue(point: NSPoint(x: x0, y: y1)), NSValue(point: NSPoint(x: x1, y: y1)), NSValue(point: NSPoint(x: x0, y: y0)), NSValue(point: NSPoint(x: x1, y: y0))]
        }
        a.quadrilateralPoints = quads
        if !c.commentText.isEmpty { a.contents = c.commentText }
        p.addAnnotation(a)
        if !c.commentText.isEmpty, let first = lines.first {
            let n = CardAnnotation(bounds: CGRect(x: max(0, first.minX - 13), y: first.maxY - 11, width: 11, height: 11), forType: .text, withProperties: nil)
            n.cardId = c.id; n.signature = sig
            n.contents = c.commentText
            n.color = col
            p.addAnnotation(n)
        }
    }

    /// line rects from a selection overlap vertically a little; trim them so every point is covered once
    private func mergedLines(_ rects: [CGRect]) -> [CGRect] {
        let rs = rects.filter { $0.width > 0.5 && $0.height > 0.5 }.sorted { $0.maxY > $1.maxY }
        var out: [CGRect] = []
        for var r in rs {
            if let i = out.firstIndex(where: { abs($0.midY - r.midY) < min($0.height, r.height) * 0.5 }) {
                out[i] = out[i].union(r)          // same line split into pieces
                continue
            }
            if let prev = out.last, r.maxY > prev.minY, r.minY < prev.minY {
                r = CGRect(x: r.minX, y: r.minY, width: r.width, height: prev.minY - r.minY)
            }
            out.append(r)
        }
        return out
    }

    func refreshAnnotations(for c: Card) { addAnnotations(c, to: document(c.variant)) }

    func removeAnnotations(cardId: UUID) {
        for d in [original, bilingual] {
            for i in 0..<d.pageCount {
                guard let p = d.safePage(i) else { continue }
                p.annotations.filter { ($0 as? CardAnnotation)?.cardId == cardId }.forEach { p.removeAnnotation($0) }
            }
        }
    }

    /// Writes the full bilingual PDF (with highlights) to a file.
    func exportBilingual(to url: URL) -> Bool { bilingual.write(to: url) }
}

extension Notification.Name {
    static let bilingualPageReady = Notification.Name("bilingualPageReady")
}

extension String {
    var hashValueStable: String {
        var h: UInt64 = 1469598103934665603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}
