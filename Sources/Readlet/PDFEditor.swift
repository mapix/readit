import Foundation
import PDFKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Non-destructive (backed-up) PDF editing for cleaning up web-imported or noisy PDFs:
/// - Truncate from a vertical position on the current page to the end of the document
/// - Truncate everything above a vertical position on the current page
/// - Erase / white-out a rectangular region on a page
/// - Delete current page, all pages before, or all pages after
/// - Restore the untouched original PDF from `original.backup.pdf`
@MainActor
enum PDFEditor {
    static func backupURL(_ docId: UUID) -> URL {
        Paths.docDir(docId).appendingPathComponent("original.backup.pdf")
    }

    static func hasBackup(_ docId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: backupURL(docId).path)
    }

    /// Ensures `original.backup.pdf` exists before the first edit so the user can always restore.
    private static func ensureBackup(_ docId: UUID) {
        let bak = backupURL(docId)
        guard !FileManager.default.fileExists(atPath: bak.path) else { return }
        try? FileManager.default.copyItem(at: Paths.pdf(docId), to: bak)
    }

    /// Maps a point `(pageIndex, pageY)` from whatever variant is currently displayed (`original` or `bilingual`)
    /// into the `original` page's bottom-up Y coordinate.
    static func mapYToOriginal(session: DocSession, variant: Variant, pageIndex: Int, pageY: CGFloat) -> CGFloat {
        guard let origPage = session.original.safePage(pageIndex) else { return pageY }
        let origBox = origPage.bounds(for: .cropBox)
        guard variant == .bilingual,
              let biPage = session.bilingual.safePage(pageIndex),
              let ins = session.insertions[pageIndex], !ins.isEmpty else {
            return min(max(pageY, origBox.minY), origBox.maxY)
        }
        let biH = biPage.bounds(for: .cropBox).maxY
        let origH = origBox.maxY
        let tdBi = biH - pageY
        let tdOrig = DocSession.toOriginal(tdBi, ins)
        return min(max(origH - tdOrig, origBox.minY), origBox.maxY)
    }

    /// Maps a rectangle from the displayed page (`original` or `bilingual`) to the `original` page coordinates.
    static func mapRectToOriginal(session: DocSession, variant: Variant, pageIndex: Int, rect: CGRect) -> CGRect {
        guard variant == .bilingual else { return rect }
        let maxY = mapYToOriginal(session: session, variant: variant, pageIndex: pageIndex, pageY: rect.maxY)
        let minY = mapYToOriginal(session: session, variant: variant, pageIndex: pageIndex, pageY: rect.minY)
        return CGRect(x: rect.minX, y: min(minY, maxY), width: rect.width, height: abs(maxY - minY))
    }

    // MARK: - Edit Operations

    /// Truncates the current page below `origY` (keeping only content above `origY`) AND deletes all pages after `pageIndex`.
    @discardableResult
    static func truncateFromHereToEnd(session: DocSession, pageIndex: Int, origY: CGFloat) -> Bool {
        let doc = session.original
        guard let page = doc.safePage(pageIndex) else { return false }
        let box = page.bounds(for: .cropBox)
        let cutY = min(max(origY, box.minY), box.maxY - 36)
        ensureBackup(session.doc.id)

        // 1. Replace `pageIndex` with a cropped page keeping `[cutY, box.maxY]`
        if cutY > box.minY + 4, let cropped = renderCroppedPage(page: page, keepMinY: cutY, keepMaxY: box.maxY) {
            doc.removePage(at: pageIndex)
            doc.insert(cropped, at: pageIndex)
        }

        // 2. Remove all pages after `pageIndex`
        while doc.pageCount > pageIndex + 1 {
            doc.removePage(at: doc.pageCount - 1)
        }

        // 3. Update cards on `pageIndex` (shift y by -(cutY - box.minY)) and remove cards on deleted pages
        let dy = cutY - box.minY
        let store = Store.shared
        store.lib.cards.removeAll { c in
            guard c.docId == session.doc.id else { return false }
            if c.page > pageIndex { return true }
            if c.page == pageIndex, let first = c.rects.first, first.maxY < cutY { return true }
            return false
        }
        if dy > 4 {
            for idx in store.lib.cards.indices where store.lib.cards[idx].docId == session.doc.id && store.lib.cards[idx].page == pageIndex {
                store.lib.cards[idx].rects = store.lib.cards[idx].rects.map {
                    CGRect(x: $0.minX, y: max(0, $0.minY - dy), width: $0.width, height: $0.height)
                }
            }
        }

        commitChanges(session: session, invalidateFromPage: pageIndex, targetPage: pageIndex)
        return true
    }

    /// Truncates the current page above `origY` (keeping only content below `origY` on `pageIndex`).
    @discardableResult
    static func truncateAboveHere(session: DocSession, pageIndex: Int, origY: CGFloat) -> Bool {
        let doc = session.original
        guard let page = doc.safePage(pageIndex) else { return false }
        let box = page.bounds(for: .cropBox)
        let cutY = max(min(origY, box.maxY), box.minY + 36)
        guard cutY < box.maxY - 4 else { return false }
        ensureBackup(session.doc.id)

        if let cropped = renderCroppedPage(page: page, keepMinY: box.minY, keepMaxY: cutY) {
            doc.removePage(at: pageIndex)
            doc.insert(cropped, at: pageIndex)
        }

        let store = Store.shared
        store.lib.cards.removeAll { c in
            c.docId == session.doc.id && c.page == pageIndex && (c.rects.first?.minY ?? 0) > cutY
        }

        commitChanges(session: session, invalidateFromPage: pageIndex, onlyPage: pageIndex, targetPage: pageIndex)
        return true
    }

    /// Whites out / erases a rectangular region `origRect` on `pageIndex`.
    @discardableResult
    static func eraseRegion(session: DocSession, pageIndex: Int, origRect: CGRect) -> Bool {
        let doc = session.original
        guard let page = doc.safePage(pageIndex) else { return false }
        let box = page.bounds(for: .cropBox)
        let clean = origRect.intersection(box)
        guard clean.width > 4, clean.height > 4 else { return false }
        ensureBackup(session.doc.id)

        guard let erased = renderErasedPage(page: page, eraseRect: clean) else { return false }
        doc.removePage(at: pageIndex)
        doc.insert(erased, at: pageIndex)

        commitChanges(session: session, invalidateFromPage: pageIndex, onlyPage: pageIndex, targetPage: pageIndex)
        return true
    }

    /// Deletes a single page at `pageIndex` (requires `pageCount > 1`).
    @discardableResult
    static func deletePage(session: DocSession, pageIndex: Int) -> Bool {
        let doc = session.original
        guard doc.pageCount > 1, pageIndex >= 0, pageIndex < doc.pageCount else { return false }
        ensureBackup(session.doc.id)
        doc.removePage(at: pageIndex)

        let store = Store.shared
        store.lib.cards.removeAll { $0.docId == session.doc.id && $0.page == pageIndex }
        for idx in store.lib.cards.indices where store.lib.cards[idx].docId == session.doc.id && store.lib.cards[idx].page > pageIndex {
            store.lib.cards[idx].page -= 1
        }

        let nextTarget = min(pageIndex, doc.pageCount - 1)
        commitChanges(session: session, invalidateFromPage: 0, targetPage: nextTarget)
        return true
    }

    /// Deletes all pages after `pageIndex` (`pageIndex + 1 ..< pageCount`).
    @discardableResult
    static func deletePagesAfter(session: DocSession, pageIndex: Int) -> Bool {
        let doc = session.original
        guard pageIndex >= 0, pageIndex + 1 < doc.pageCount else { return false }
        ensureBackup(session.doc.id)
        while doc.pageCount > pageIndex + 1 {
            doc.removePage(at: doc.pageCount - 1)
        }
        Store.shared.lib.cards.removeAll { $0.docId == session.doc.id && $0.page > pageIndex }
        commitChanges(session: session, invalidateFromPage: pageIndex + 1, targetPage: pageIndex)
        return true
    }

    /// Deletes all pages before `pageIndex` (`0 ..< pageIndex`).
    @discardableResult
    static func deletePagesBefore(session: DocSession, pageIndex: Int) -> Bool {
        let doc = session.original
        guard pageIndex > 0, pageIndex < doc.pageCount else { return false }
        ensureBackup(session.doc.id)
        for _ in 0..<pageIndex {
            doc.removePage(at: 0)
        }
        let store = Store.shared
        store.lib.cards.removeAll { $0.docId == session.doc.id && $0.page < pageIndex }
        for idx in store.lib.cards.indices where store.lib.cards[idx].docId == session.doc.id {
            store.lib.cards[idx].page -= pageIndex
        }
        commitChanges(session: session, invalidateFromPage: 0, targetPage: 0)
        return true
    }

    /// Restores `original.pdf` from `original.backup.pdf` and removes the backup file.
    @discardableResult
    static func restoreOriginal(session: DocSession) -> Bool {
        let docId = session.doc.id
        let bak = backupURL(docId)
        let dst = Paths.pdf(docId)
        guard FileManager.default.fileExists(atPath: bak.path) else { return false }
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: bak, to: dst)
            try? FileManager.default.removeItem(at: bak)
            if let reloaded = TintedDocument(url: dst) {
                session.replaceOriginalDocument(reloaded)
            }
            commitChanges(session: session, invalidateFromPage: 0, targetPage: 0, writeOriginal: false)
            return true
        } catch {
            return false
        }
    }

    // MARK: - CoreGraphics Vector Page Builders

    private static func renderCroppedPage(page: PDFPage, keepMinY: CGFloat, keepMaxY: CGFloat) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        let newH = max(36, keepMaxY - keepMinY)
        var media = CGRect(x: 0, y: 0, width: box.width, height: newH)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(media)
        ctx.saveGState()
        ctx.clip(to: media)
        ctx.translateBy(x: -box.minX, y: -keepMinY)
        if let cg = page.pageRef {
            ctx.drawPDFPage(cg)
        } else {
            page.draw(with: .cropBox, to: ctx)
        }
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = TintedDocument(data: out as Data) else { return nil }
        return doc.safePage(0)
    }

    private static func renderErasedPage(page: PDFPage, eraseRect: CGRect) -> PDFPage? {
        let box = page.bounds(for: .cropBox)
        var media = CGRect(x: 0, y: 0, width: box.width, height: box.height)
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(media)
        ctx.saveGState()
        ctx.translateBy(x: -box.minX, y: -box.minY)
        if let cg = page.pageRef {
            ctx.drawPDFPage(cg)
        } else {
            page.draw(with: .cropBox, to: ctx)
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(eraseRect.insetBy(dx: -1, dy: -1))
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = TintedDocument(data: out as Data) else { return nil }
        return doc.safePage(0)
    }

    // MARK: - Persistence & Session Sync

    private static func commitChanges(session: DocSession, invalidateFromPage: Int, onlyPage: Int? = nil, targetPage: Int, writeOriginal: Bool = true) {
        let docId = session.doc.id
        if writeOriginal {
            // Strip temporary highlight annotations before saving original.pdf to disk
            for i in 0..<session.original.pageCount {
                if let p = session.original.safePage(i) {
                    p.annotations.filter { $0 is CardAnnotation }.forEach { p.removeAnnotation($0) }
                }
            }
            session.original.write(to: Paths.pdf(docId))
            session.applyAnnotations(variant: .original)
        }

        // Regenerate cover thumbnail if page 0 changed
        if invalidateFromPage == 0 || onlyPage == 0 {
            let thumbURL = Paths.docDir(docId).appendingPathComponent("thumb.png")
            try? FileManager.default.removeItem(at: thumbURL)
            if let p0 = session.original.safePage(0),
               let png = PlatformPDF.thumbnailPNG(p0, size: CGSize(width: 280, height: 372)) {
                try? png.write(to: thumbURL)
            }
        }

        // Sync session caches & bilingual view
        session.handlePDFEdited(invalidateFromPage: invalidateFromPage, onlyPage: onlyPage, targetPage: targetPage)
        Store.shared.updateReadingProgress(docId: docId, page: targetPage, pageCount: session.original.pageCount)
        Store.shared.save()
        NotificationCenter.default.post(name: .pdfDidEdit, object: docId)
    }
}

extension Notification.Name {
    static let pdfDidEdit = Notification.Name("pdfDidEdit")
}
