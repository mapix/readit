import Foundation
import SwiftUI
import PDFKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformImage = UIImage
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage
typealias NSSize = CGSize
typealias NSPoint = CGPoint
typealias NSRect = CGRect

extension UIColor {
    convenience init(srgbRed: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: srgbRed, green: green, blue: blue, alpha: alpha)
    }

    convenience init(calibratedWhite: CGFloat, alpha: CGFloat) {
        self.init(white: calibratedWhite, alpha: alpha)
    }

    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor? {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              color.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        let f = min(max(fraction, 0), 1)
        return UIColor(
            red: r1 * (1 - f) + r2 * f,
            green: g1 * (1 - f) + g2 * f,
            blue: b1 * (1 - f) + b2 * f,
            alpha: a1 * (1 - f) + a2 * f
        )
    }
}

extension UIImage {
    convenience init?(contentsOf url: URL) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d)
    }
}

extension UIFontDescriptor.SymbolicTraits {
    static var bold: UIFontDescriptor.SymbolicTraits { .traitBold }
}

extension NSValue {
    convenience init(point: CGPoint) {
        self.init(cgPoint: point)
    }
    var pointValue: CGPoint { cgPointValue }
}

extension Color {
    init(nsColor: UIColor) {
        self.init(uiColor: nsColor)
    }
}

extension Image {
    init(nsImage: UIImage) {
        self.init(uiImage: nsImage)
    }
}
#endif

// MARK: - Cross-Platform Utilities

enum PlatformClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    static func string() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        return UIPasteboard.general.string
        #endif
    }
}

enum PlatformBrowser {
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}

enum PlatformPDF {
    static func thumbnailPNG(_ page: PDFPage, size: CGSize) -> Data? {
        let img = page.thumbnail(of: size, for: .cropBox)
        #if os(macOS)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
        #elseif os(iOS)
        return img.pngData()
        #endif
    }

    static func thumbnailJPEG(_ page: PDFPage, maxDimension: CGFloat = 1400, quality: CGFloat = 0.72) -> Data {
        let b = page.bounds(for: .cropBox)
        let scale = min(2.0, maxDimension / max(1, max(b.width, b.height)))
        let img = page.thumbnail(of: CGSize(width: b.width * scale, height: b.height * scale), for: .cropBox)
        #if os(macOS)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let j = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) else { return Data() }
        return j
        #elseif os(iOS)
        return img.jpegData(compressionQuality: quality) ?? Data()
        #endif
    }

    static func thumbnailCGImage(_ page: PDFPage, size: CGSize, for box: PDFDisplayBox = .cropBox) -> CGImage? {
        let img = page.thumbnail(of: size, for: box)
        #if os(macOS)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif os(iOS)
        return img.cgImage
        #endif
    }
}

// MARK: - Shared PDF & Geometry Extensions

extension PDFDocument {
    /// bounds-checked page lookup (stale indices after page swaps / doc changes must not raise)
    func safePage(_ i: Int) -> PDFPage? { i >= 0 && i < pageCount ? page(at: i) : nil }
}

extension CGFloat {
    var isSane: Bool { isFinite && !isNaN }
    func finiteOr(_ d: CGFloat) -> CGFloat { isSane ? self : d }
}

extension CGPoint {
    var isSane: Bool { x.isSane && y.isSane && abs(x) < 1e7 && abs(y) < 1e7 }
}

extension CGRect {
    var isSane: Bool {
        !isNull && !isInfinite && origin.isSane && size.width.isSane && size.height.isSane
            && width > 0 && height > 0 && width < 1e7 && height < 1e7
    }
    func sanitized(in b: CGRect) -> CGRect? {
        guard isSane, b.isSane else { return nil }
        let r = standardized.intersection(b)
        return r.isSane ? r : nil
    }
}

#if os(iOS)
// MARK: - iOS ReaderController & DocWindows Bridge

@MainActor
final class ReaderController: NSObject, ObservableObject {
    static let shared = ReaderController()

    let view = PDFView()
    @Published var docId: UUID?
    @Published var variant: Variant = .original
    @Published var currentPageIndex: Int = 0
    @Published var pageCount: Int = 0
    @Published var selectionText: String = ""
    @Published var selectionRects: [CGRect] = []
    @Published var selectionPage: Int = 0
    @Published var narrationQuote: String?
    var segmentMentionsFigure = false
    private var narrationAnnotations: [PDFAnnotation] = []

    override init() {
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged),
            name: .PDFViewSelectionChanged,
            object: view
        )
    }

    func bind(docId id: UUID) {
        guard let ses = Store.shared.session(id) else { return }
        if docId != id {
            docId = id
            let savedVar = Variant(rawValue: UserDefaults.standard.string(forKey: "variant-" + id.uuidString) ?? "") ?? Store.shared.variant
            variant = savedVar
        }
        let targetDoc = ses.document(variant)
        if view.document !== targetDoc {
            view.document = targetDoc
            view.autoScales = true
        }
        pageCount = ses.pageCount
        let savedPage = Store.shared.doc(id)?.resolvedReadPage ?? 0
        let clamped = min(max(0, savedPage), max(0, pageCount - 1))
        if currentPageIndex != clamped, let pg = targetDoc.safePage(clamped) {
            view.go(to: pg)
            currentPageIndex = clamped
        }
        if variant == .bilingual {
            ses.startBilingual(from: currentPageIndex)
        }
    }

    @objc private func pageChanged() {
        guard let doc = view.document, let cur = view.currentPage else { return }
        let idx = doc.index(for: cur)
        guard idx != NSNotFound, idx >= 0 else { return }
        if currentPageIndex != idx {
            currentPageIndex = idx
        }
        if let id = docId {
            UserDefaults.standard.set(idx, forKey: "page-" + id.uuidString)
            Store.shared.updateReadingProgress(docId: id, page: idx, pageCount: max(1, doc.pageCount))
            if variant == .bilingual, let ses = Store.shared.session(id) {
                ses.prioritize(idx)
            }
        }
    }

    @objc private func selectionChanged() {
        guard let sel = view.currentSelection,
              let raw = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let page = sel.pages.first,
              let doc = view.document else {
            selectionText = ""
            selectionRects = []
            return
        }
        let idx = doc.index(for: page)
        selectionPage = idx == NSNotFound ? currentPageIndex : idx
        selectionText = raw
        let lineSelections = sel.selectionsByLine()
        if lineSelections.isEmpty {
            selectionRects = [sel.bounds(for: page)]
        } else {
            selectionRects = lineSelections.map { $0.bounds(for: page) }
        }
    }

    func setVariant(_ v: Variant) {
        guard let id = docId, let ses = Store.shared.session(id) else {
            variant = v
            return
        }
        let curPage = currentPageIndex
        variant = v
        UserDefaults.standard.set(v.rawValue, forKey: "variant-" + id.uuidString)
        let targetDoc = ses.document(v)
        view.document = targetDoc
        view.autoScales = true
        if let pg = targetDoc.safePage(curPage) {
            view.go(to: pg)
        }
        if v == .bilingual {
            ses.startBilingual(from: curPage)
        }
    }

    func goToPage(_ i: Int) {
        guard let doc = view.document else { return }
        let clamped = min(max(0, i), max(0, doc.pageCount - 1))
        if let pg = doc.safePage(clamped) {
            view.go(to: pg)
            currentPageIndex = clamped
            if let id = docId {
                UserDefaults.standard.set(clamped, forKey: "page-" + id.uuidString)
                Store.shared.updateReadingProgress(docId: id, page: clamped, pageCount: doc.pageCount)
            }
        }
    }

    func jump(to card: Card) {
        if docId != card.docId {
            bind(docId: card.docId)
        }
        if variant != card.variant {
            setVariant(card.variant)
        }
        goToPage(card.page)
        if let pg = view.document?.safePage(card.page), let r = card.rects.first {
            view.go(to: r, on: pg)
        }
    }

    @discardableResult
    func excerptSelection(color: Int = 0) -> Card? {
        guard let id = docId, !selectionText.isEmpty, !selectionRects.isEmpty else { return nil }
        let c = Card(docId: id, page: selectionPage, variant: variant, rects: selectionRects, text: selectionText, color: color)
        Store.shared.addCard(c)
        Store.shared.session(id)?.refreshAnnotations(for: c)
        view.clearSelection()
        selectionText = ""
        selectionRects = []
        return c
    }

    func enqueueSwap(_ s: DocSession, page: Int, _ w: @escaping () -> Void) {
        w()
    }

    func documentReplaced(_ s: DocSession) {
        guard docId == s.doc.id, variant == .bilingual else { return }
        let curPage = currentPageIndex
        view.document = s.bilingual
        view.autoScales = true
        if let pg = s.bilingual.safePage(curPage) {
            view.go(to: pg)
        }
    }

    func reloadAfterPDFEdit(session: DocSession, targetPage: Int) {
        guard docId == session.doc.id else { return }
        let d = session.document(variant)
        view.document = d
        pageCount = session.pageCount
        goToPage(targetPage)
    }

    func highlightNarration(page: Int, quote: String?) {
        clearNarrationHighlight()
        narrationQuote = quote
        guard let q = quote?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty,
              let doc = view.document, let pg = doc.safePage(page) else { return }
        let selections = doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
        for sel in selections where sel.pages.contains(pg) {
            let b = sel.bounds(for: pg)
            guard b.isSane else { continue }
            let ann = PDFAnnotation(bounds: b.insetBy(dx: -2, dy: -1), forType: .highlight, withProperties: nil)
            ann.color = UIColor.systemOrange.withAlphaComponent(0.35)
            pg.addAnnotation(ann)
            narrationAnnotations.append(ann)
        }
    }

    func clearNarrationHighlight() {
        narrationQuote = nil
        for ann in narrationAnnotations {
            ann.page?.removeAnnotation(ann)
        }
        narrationAnnotations.removeAll()
    }
}

@MainActor
final class DocWindows: ObservableObject {
    static let shared = DocWindows()

    struct WindowStub {
        var title: String = ""
        func makeKeyAndOrderFront(_ sender: Any?) {}
    }

    final class Entry {
        let docId: UUID
        var window = WindowStub()
        let reader: ReaderController
        init(docId: UUID, reader: ReaderController) {
            self.docId = docId
            self.reader = reader
        }
    }

    @Published var entries: [UUID: Entry] = [:]
    @Published var activeDocId: UUID?
    var active: Entry? { activeDocId.flatMap { entries[$0] } }

    func open(_ docId: UUID, notebook: UUID? = nil, jump: Card? = nil) {
        if let nb = notebook {
            Store.shared.currentNotebookId = nb
        }
        Store.shared.openDoc(docId)
        let rc = ReaderController.shared
        rc.bind(docId: docId)
        let entry = Entry(docId: docId, reader: rc)
        entry.window.title = Store.shared.doc(docId)?.title ?? ""
        entries[docId] = entry
        activeDocId = docId
        if let jump {
            rc.jump(to: jump)
        }
    }

    func close(_ docId: UUID) {
        entries.removeValue(forKey: docId)
        if activeDocId == docId {
            activeDocId = nil
        }
    }
}
#endif
