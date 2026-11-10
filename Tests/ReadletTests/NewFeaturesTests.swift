import XCTest
import PDFKit
import WebKit
@testable import Readlet

@MainActor
final class NewFeaturesTests: XCTestCase {

    // MARK: - 1. Document Tags & Reading Progress Tests

    func testDocStatusTagAndCustomTags() {
        var doc = Doc(
            id: UUID(),
            title: "Test Paper",
            added: Date(),
            tags: ["TODO", "AI", "Agents"],
            pageCount: 10,
            readPage: 0
        )
        XCTAssertEqual(doc.statusTag, DocStatusTag.todo)
        XCTAssertEqual(doc.customTags, ["AI", "Agents"])
        XCTAssertEqual(doc.progressPercent, 10) // page 0 of 10 -> 1/10 = 10%

        // Update readPage to 4 (page 5 of 10 -> 50%)
        doc.readPage = 4
        XCTAssertEqual(doc.progressPercent, 50)
        XCTAssertEqual(doc.progressFraction, 0.5, accuracy: 0.001)

        // Update readPage to last page (page 10 of 10 -> 100%)
        doc.readPage = 9
        XCTAssertEqual(doc.progressPercent, 100)
        XCTAssertEqual(doc.progressFraction, 1.0, accuracy: 0.001)
    }

    func testDocBackwardCompatibleDecoding() throws {
        // Simulate legacy JSON without tags, pageCount, or readPage
        let legacyJSON = """
        {
            "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
            "title": "Legacy Document",
            "added": 0
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Doc.self, from: legacyJSON)
        XCTAssertEqual(decoded.title, "Legacy Document")
        XCTAssertEqual(decoded.tags, [])
        XCTAssertNil(decoded.pageCount)
        XCTAssertNil(decoded.readPage)
        XCTAssertNil(decoded.statusTag)
        XCTAssertEqual(decoded.progressPercent, 0)
    }

    func testStoreTagOperationsAndProgressAutoStatus() {
        let store = Store.shared
        let docId = UUID()
        let initialDoc = Doc(
            id: docId,
            title: "Tag Test Doc",
            added: Date(),
            tags: [],
            pageCount: 5,
            readPage: nil
        )
        store.lib.docs.append(initialDoc)
        defer {
            store.lib.docs.removeAll { $0.id == docId }
            store.saveNow()
        }

        // Set status tag to TODO
        store.setStatusTag(docId, .todo)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.todo)

        // Add custom tags
        store.addTag(docId, "LLM")
        store.addTag(docId, "Paper")
        XCTAssertEqual(store.doc(docId)?.customTags, ["LLM", "Paper"])

        // Reading middle page automatically transitions TODO -> DOING
        store.updateReadingProgress(docId: docId, page: 2, pageCount: 5)
        XCTAssertEqual(store.doc(docId)?.readPage, 2)
        XCTAssertEqual(store.doc(docId)?.progressPercent, 60)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.doing)

        // Cycle status tag: DOING -> DONE -> TODO -> DOING
        store.cycleStatusTag(docId)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.done)
        XCTAssertEqual(store.doc(docId)?.progressPercent, 100)

        store.cycleStatusTag(docId)
        XCTAssertEqual(store.doc(docId)?.statusTag, DocStatusTag.todo)

        // Toggle tag removes status tag when matching
        store.toggleTag(docId, "TODO")
        XCTAssertNil(store.doc(docId)?.statusTag)
    }

    // MARK: - 2. PDFEditor Tests (Truncate, Erase, Delete, Backup & Restore)

    private func makeSamplePDF(pageCount: Int, pageSize: CGSize = CGSize(width: 400, height: 600)) -> PDFDocument {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            fatalError("Failed to create PDF context")
        }
        for i in 0..<pageCount {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(mediaBox)
            let str = "Page \(i + 1) Top Content\n\nMiddle Content\n\nBottom Footer Noise" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(in: CGRect(x: 40, y: 100, width: 320, height: 440), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: pdfData as Data)!
    }

    func testPDFEditorTruncateEraseDeleteAndRestore() throws {
        let docId = UUID()
        let dir = Paths.docDir(docId)
        defer {
            try? FileManager.default.removeItem(at: dir)
            Store.shared.lib.docs.removeAll { $0.id == docId }
            Store.shared.lib.cards.removeAll { $0.docId == docId }
            Store.shared.saveNow()
        }

        let pdf = makeSamplePDF(pageCount: 4, pageSize: CGSize(width: 400, height: 600))
        XCTAssertTrue(pdf.write(to: Paths.pdf(docId)))

        let docModel = Doc(id: docId, title: "Editable PDF", added: Date(), pageCount: 4)
        Store.shared.lib.docs.append(docModel)
        guard let session = DocSession(doc: docModel) else {
            XCTFail("Failed to create DocSession")
            return
        }

        XCTAssertEqual(session.original.pageCount, 4)
        XCTAssertFalse(PDFEditor.hasBackup(docId))

        // 1. Erase a rectangular region on page 1
        let erased = PDFEditor.eraseRegion(session: session, pageIndex: 0, origRect: CGRect(x: 30, y: 80, width: 200, height: 60))
        XCTAssertTrue(erased)
        XCTAssertTrue(PDFEditor.hasBackup(docId))
        XCTAssertEqual(session.original.pageCount, 4)

        // 2. Truncate above y=450 on page 1 (keeps [0, 450] -> height becomes 450pt)
        let truncAbove = PDFEditor.truncateAboveHere(session: session, pageIndex: 0, origY: 450)
        XCTAssertTrue(truncAbove)
        let p0BoundsAfterAbove = session.original.page(at: 0)!.bounds(for: PDFDisplayBox.cropBox)
        XCTAssertEqual(p0BoundsAfterAbove.height, 450, accuracy: 1.0)

        // 3. Truncate from y=200 on page 2 (index 1) to the end of the document
        // Page count should drop from 4 to 2, and page 2 height should become 600 - 200 = 400pt
        let truncToEnd = PDFEditor.truncateFromHereToEnd(session: session, pageIndex: 1, origY: 200)
        XCTAssertTrue(truncToEnd)
        XCTAssertEqual(session.original.pageCount, 2)
        let p1Bounds = session.original.page(at: 1)!.bounds(for: PDFDisplayBox.cropBox)
        XCTAssertEqual(p1Bounds.height, 400, accuracy: 1.0)
        XCTAssertEqual(Store.shared.doc(docId)?.pageCount, 2)

        // 4. Delete page 0 -> leaves 1 page
        let deleted = PDFEditor.deletePage(session: session, pageIndex: 0)
        XCTAssertTrue(deleted)
        XCTAssertEqual(session.original.pageCount, 1)

        // 5. Restore original untouched PDF from backup
        let restored = PDFEditor.restoreOriginal(session: session)
        XCTAssertTrue(restored)
        XCTAssertFalse(PDFEditor.hasBackup(docId))
        XCTAssertEqual(session.original.pageCount, 4)
        XCTAssertEqual(session.original.page(at: 0)!.bounds(for: PDFDisplayBox.cropBox).height, 600, accuracy: 1.0)
        XCTAssertEqual(Store.shared.doc(docId)?.pageCount, 4)
    }

    // MARK: - 3. UpdateChecker Tests

    func testUpdateCheckerVersionComparisonAndDecoding() throws {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))

        let json = """
        {"version":"1.0.1","file":"Readlet-1.0.1.zip","size":"3.2 MB","sha256":"abc12345","notes":"Bug fixes"}
        """.data(using: .utf8)!
        let rel = try JSONDecoder().decode(UpdateChecker.Release.self, from: json)
        XCTAssertEqual(rel.version, "1.0.1")
        XCTAssertEqual(rel.file, "Readlet-1.0.1.zip")
        XCTAssertEqual(rel.size, "3.2 MB")
    }

    // MARK: - 4. iCloud Multi-Device Sync (Mac <-> iPhone) Merge Tests

    func testCloudSyncMergeLibrariesAndTombstones() {
        let docId1 = UUID()
        let docId2 = UUID()
        let deletedDocId = UUID()
        let now = Date()

        // Mac library: doc1 at page 2 (TODO, tag "AI"), plus deletedDocId still present locally
        let macDoc1 = Doc(
            id: docId1,
            title: "Attention Is All You Need",
            added: now.addingTimeInterval(-3600),
            tags: ["TODO", "AI"],
            pageCount: 15,
            readPage: 2,
            updatedAt: now.addingTimeInterval(-600)
        )
        let macDeletedDoc = Doc(
            id: deletedDocId,
            title: "Old Draft",
            added: now.addingTimeInterval(-7200),
            pageCount: 5
        )

        var macCard = Card(
            docId: docId1,
            page: 2,
            variant: .original,
            rects: [CGRect(x: 10, y: 10, width: 100, height: 20)],
            text: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
            color: 0
        )
        macCard.comments = ["Mac note"]
        macCard.updatedAt = now.addingTimeInterval(-500)

        let nbId = UUID()
        let rootId = UUID()
        let macChild = MindNode(title: "Mac Topic")
        let macNotebook = Notebook(id: nbId, name: "Transformers", docIds: [docId1], root: MindNode(id: rootId, title: "Root", children: [macChild]))

        let macLib = Library(docs: [macDoc1, macDeletedDoc], notebooks: [macNotebook], cards: [macCard], links: [])

        // iPhone library: user read doc1 up to page 9, changed status to DOING, added tag "DeepLearning", translated card, and imported doc2
        let iphoneDoc1 = Doc(
            id: docId1,
            title: "Attention Is All You Need",
            added: now.addingTimeInterval(-3600),
            tags: ["DOING", "DeepLearning"],
            pageCount: 15,
            readPage: 9,
            updatedAt: now
        )
        let iphoneDoc2 = Doc(
            id: docId2,
            title: "DeepSeek-R1 Technical Report",
            added: now.addingTimeInterval(-100),
            tags: ["TODO"],
            pageCount: 22
        )
        var iphoneCard = macCard
        iphoneCard.translation = "主流序列转导模型基于复杂的循环或卷积神经网络。"
        iphoneCard.comments = ["iPhone note"]
        iphoneCard.color = 2
        iphoneCard.updatedAt = now

        let iphoneChild = MindNode(title: "iPhone Topic")
        let iphoneNotebook = Notebook(id: nbId, name: "Transformers", docIds: [docId1, docId2], root: MindNode(id: rootId, title: "Root", children: [iphoneChild]))

        let iphoneLib = Library(docs: [iphoneDoc1, iphoneDoc2], notebooks: [iphoneNotebook], cards: [iphoneCard], links: [])

        // Merge with tombstone for deletedDocId
        let (merged, localChanged, remoteChanged) = CloudSync.mergeLibraries(local: macLib, remote: iphoneLib, deleted: [deletedDocId])
        XCTAssertTrue(localChanged)
        XCTAssertTrue(remoteChanged)

        // 1. Deleted doc is filtered out, both doc1 and doc2 are present
        XCTAssertEqual(merged.docs.count, 2)
        XCTAssertNil(merged.docs.first(where: { $0.id == deletedDocId }))

        // 2. doc1 took the newer iPhone readPage (9), DOING status, and merged custom tags ("AI" + "DeepLearning")
        let mDoc1 = merged.docs.first(where: { $0.id == docId1 })!
        XCTAssertEqual(mDoc1.readPage, 9)
        XCTAssertEqual(mDoc1.statusTag, DocStatusTag.doing)
        XCTAssertTrue(mDoc1.customTags.contains("AI"))
        XCTAssertTrue(mDoc1.customTags.contains("DeepLearning"))

        // 3. Card kept translation from iPhone and combined comments from Mac + iPhone
        XCTAssertEqual(merged.cards.count, 1)
        let mCard = merged.cards[0]
        XCTAssertEqual(mCard.translation, "主流序列转导模型基于复杂的循环或卷积神经网络。")
        XCTAssertTrue(mCard.comments.contains("Mac note"))
        XCTAssertTrue(mCard.comments.contains("iPhone note"))

        // 4. Mind map root merged children from both Mac and iPhone
        let mNb = merged.notebooks.first(where: { $0.id == nbId })!
        XCTAssertEqual(mNb.root.children.count, 2)
        XCTAssertEqual(Set(mNb.docIds), Set([docId1, docId2]))
    }

    func testCrossDeviceProgressConflictAndHistoryMerge() {
        let docId = UUID()
        let now = Date()

        let localDoc = Doc(
            id: docId,
            title: "Distributed Systems Paper",
            pageCount: 30,
            readPage: 18,
            readUpdatedAt: now.addingTimeInterval(-60),
            lastReadDevice: "MacBook Pro",
            lastReadDeviceId: "dev-mac",
            deviceProgressHistory: [
                DeviceProgressSnapshot(deviceId: "dev-mac", deviceName: "MacBook Pro", readPage: 18, narrationPage: 4, narrationSeg: 2, updatedAt: now.addingTimeInterval(-60))
            ],
            dailyReadingLog: ["2026-10-25": 10, "2026-10-26": 18],
            updatedAt: now.addingTimeInterval(-60)
        )

        let remoteDoc = Doc(
            id: docId,
            title: "Distributed Systems Paper",
            pageCount: 30,
            readPage: 6,
            readUpdatedAt: now,
            lastReadDevice: "iPhone 14",
            lastReadDeviceId: "dev-iphone",
            deviceProgressHistory: [
                DeviceProgressSnapshot(deviceId: "dev-iphone", deviceName: "iPhone 14", readPage: 6, narrationPage: 6, narrationSeg: 1, updatedAt: now)
            ],
            dailyReadingLog: ["2026-10-24": 3, "2026-10-26": 6],
            updatedAt: now
        )

        let (merged, localChanged, _) = CloudSync.mergeLibraries(
            local: Library(docs: [localDoc]),
            remote: Library(docs: [remoteDoc]),
            deleted: []
        )
        XCTAssertTrue(localChanged)
        let mDoc = merged.docs[0]
        // Conflict detected because remote device is on a much earlier page (6 vs 18) despite newer timestamp:
        // local higher page (18) is preserved until user chooses in conflict banner!
        XCTAssertEqual(mDoc.readPage, 18)
        XCTAssertNotNil(mDoc.pendingConflict)
        XCTAssertEqual(mDoc.pendingConflict?.localPage, 18)
        XCTAssertEqual(mDoc.pendingConflict?.remotePage, 6)
        XCTAssertEqual(mDoc.deviceProgressHistory.count, 2)
        XCTAssertEqual(mDoc.dailyReadingLog["2026-10-26"], 18)
        XCTAssertEqual(mDoc.dailyReadingLog["2026-10-24"], 3)
    }

    func testPerDocAudioVideoSpaceResetAndCloudAudioMigration() throws {
        let fm = FileManager.default
        let docId = UUID()
        let narrDir = Paths.docDir(docId).appendingPathComponent("narration", isDirectory: true)
        defer { try? fm.removeItem(at: Paths.docDir(docId)) }
        try fm.createDirectory(at: narrDir, withIntermediateDirectories: true)

        // Create local audio clip + narration script + video file
        let audioClip = narrDir.appendingPathComponent("p0-s0.m4a")
        let scriptFile = narrDir.appendingPathComponent("p0.json")
        let docVideo = Paths.docDir(docId).appendingPathComponent("export.mp4")
        try Data(repeating: 0xAA, count: 4096).write(to: audioClip)
        try Data("{\"segments\":[]}".utf8).write(to: scriptFile)
        try Data(repeating: 0xBB, count: 8192).write(to: docVideo)

        let usageBefore = StorageManager.docMediaUsage(docId, title: "TestPaper")
        XCTAssertEqual(usageBefore.audioCount, 1)
        XCTAssertEqual(usageBefore.videoCount, 1)
        XCTAssertEqual(usageBefore.scriptCount, 1)
        XCTAssertGreaterThanOrEqual(usageBefore.audioBytes, 4096)
        XCTAssertGreaterThanOrEqual(usageBefore.videoBytes, 8192)

        // Reset audio & video only (keep scripts)
        let freed = StorageManager.resetDocMedia(docId, title: "TestPaper", includeScripts: false, includeBilingual: false)
        XCTAssertGreaterThanOrEqual(freed, 4096 + 8192)
        XCTAssertFalse(fm.fileExists(atPath: audioClip.path))
        XCTAssertFalse(fm.fileExists(atPath: docVideo.path))
        XCTAssertTrue(fm.fileExists(atPath: scriptFile.path))

        // Test upgrade migration: audio in cloudDir is migrated to localDir before being purged from cloudDir
        let tmpCloudNarr = fm.temporaryDirectory.appendingPathComponent("cloud-narr-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmpCloudNarr) }
        try fm.createDirectory(at: tmpCloudNarr, withIntermediateDirectories: true)
        let cloudClip = tmpCloudNarr.appendingPathComponent("p1-s0.m4a")
        try Data(repeating: 0xCC, count: 2048).write(to: cloudClip)

        CloudSync.purgeAudioClipsFromCloud(cloudDir: tmpCloudNarr, migrateToLocalDir: narrDir)
        XCTAssertFalse(fm.fileExists(atPath: cloudClip.path), "Cloud audio clip should be removed from iCloud")
        XCTAssertTrue(fm.fileExists(atPath: narrDir.appendingPathComponent("p1-s0.m4a").path), "Cloud audio clip should be migrated to local storage on upgrade")
    }

    // MARK: - 5. Interactive Web Import, Live DOM Decluttering & Cross-Device/Window Coordination Tests

    func testWebURLResolverHuggingFaceSpacesUnwrapAndCleanMode() {
        let raw = "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1"

        // When cleanMode == true (default), Hugging Face Spaces wrapper URLs unwrap directly to the embedded .hf.space host while preserving #s-1
        let cleanURL = WebURLResolver.resolvedLoadURL(originalURL: raw, cleanMode: true)
        XCTAssertEqual(cleanURL?.absoluteString, "https://huggingface-moe-blogpost.hf.space/#s-1")

        // When cleanMode == false (disabled for this article), original outer URL is preserved
        let rawLoadURL = WebURLResolver.resolvedLoadURL(originalURL: raw, cleanMode: false)
        XCTAssertEqual(rawLoadURL?.absoluteString, "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1")

        // Repository tree/settings URLs are not unwrapped
        let treeURL = WebURLResolver.resolvedLoadURL(originalURL: "https://huggingface.co/spaces/huggingface/moe-blogpost/tree/main", cleanMode: true)
        XCTAssertEqual(treeURL?.absoluteString, "https://huggingface.co/spaces/huggingface/moe-blogpost/tree/main")

        // Canonical identity ignores fragment (#s-1 vs #s-2-0) and trailing slash for library deduplication
        XCTAssertEqual(
            WebURLResolver.canonicalIdentity("https://huggingface.co/spaces/huggingface/moe-blogpost#s-1"),
            WebURLResolver.canonicalIdentity("https://huggingface.co/spaces/huggingface/moe-blogpost/#s-2-0")
        )
    }

    func testStoreImportWebURLLightweightStorageProgressAndCleanMode() {
        let store = Store.shared
        let url1 = "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1"
        guard let importedId = store.importWebURL(url1, title: "A Visual Guide to Mixture of Experts", cleanMode: true),
              let imported = store.doc(importedId) else {
            XCTFail("Failed to import interactive web URL")
            return
        }
        defer {
            store.deleteDoc(importedId)
            store.saveNow()
        }

        // 1. Lightweight URL-only storage: kind == .web, no original.pdf written on disk
        XCTAssertEqual(imported.kind, .web)
        XCTAssertTrue(imported.isWeb)
        XCTAssertEqual(imported.webCleanMode, true)
        XCTAssertEqual(imported.statusTag, .todo)
        XCTAssertEqual(imported.progressPercent, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Paths.pdf(importedId).path), "Interactive web doc must not store a static PDF copy")

        // 2. Re-importing same article with different section hash deduplicates to existing Doc
        let dupId = store.importWebURL("https://huggingface.co/spaces/huggingface/moe-blogpost#s-2-0")
        XCTAssertEqual(dupId, importedId)

        // 3. Per-article cleanMode toggle & custom click-to-hide selectors
        store.setWebCleanMode(importedId, false)
        XCTAssertEqual(store.doc(importedId)?.webCleanMode, false)
        store.setWebCleanMode(importedId, true)
        XCTAssertEqual(store.doc(importedId)?.webCleanMode, true)

        store.addWebHiddenSelector(importedId, "aside.newsletter-popup")
        XCTAssertEqual(store.doc(importedId)?.webHiddenSelectors, ["aside.newsletter-popup"])
        store.clearWebHiddenSelectors(importedId)
        XCTAssertEqual(store.doc(importedId)?.webHiddenSelectors, [])

        // 4. Page-less continuous reading progress & automatic TODO -> DOING -> DONE transitions
        let midAnchor = WebReadingAnchor(
            anchorId: "s-2-1::p-2",
            intraOffset: 0.35,
            scrollFraction: 0.42,
            sectionTitle: "2.1 Routing Collapse",
            sectionIndex: 3
        )
        store.updateWebReadingProgress(docId: importedId, anchor: midAnchor, sectionCount: 8)
        let afterMid = store.doc(importedId)!
        XCTAssertEqual(afterMid.progressPercent, 42)
        XCTAssertEqual(afterMid.webAnchor?.anchorId, "s-2-1::p-2")
        XCTAssertEqual(afterMid.webAnchor?.sectionTitle, "2.1 Routing Collapse")
        XCTAssertEqual(afterMid.statusTag, .doing)

        let endAnchor = WebReadingAnchor(
            anchorId: "s-5::p-4",
            intraOffset: 0.9,
            scrollFraction: 0.97,
            sectionTitle: "5. Conclusion",
            sectionIndex: 7
        )
        store.updateWebReadingProgress(docId: importedId, anchor: endAnchor, sectionCount: 8)
        let afterEnd = store.doc(importedId)!
        XCTAssertEqual(afterEnd.webAnchor?.progressPercent, 97)
        XCTAssertEqual(afterEnd.statusTag, .done)
        XCTAssertEqual(afterEnd.progressPercent, 100)
    }

    func testWebCrossDeviceSyncAnchorMergeAndConflictResolution() {
        let docId = UUID()
        let now = Date()

        let macAnchor = WebReadingAnchor(
            anchorId: "s-3-2::p-1",
            intraOffset: 0.25,
            scrollFraction: 0.74,
            sectionTitle: "3.2 Load Balancing Loss",
            sectionIndex: 5
        )
        let iphoneAnchor = WebReadingAnchor(
            anchorId: "s-1::p-2",
            intraOffset: 0.10,
            scrollFraction: 0.15,
            sectionTitle: "1. Introduction to MoE",
            sectionIndex: 1
        )

        let macDoc = Doc(
            id: docId,
            title: "Mixture of Experts Blog",
            added: now.addingTimeInterval(-3600),
            kind: .web,
            source: "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1",
            webCleanMode: true,
            webHiddenSelectors: [".cookie-banner"],
            webAnchor: macAnchor,
            tags: ["DOING"],
            pageCount: 8,
            readPage: 5,
            readUpdatedAt: now.addingTimeInterval(-120),
            lastReadDevice: "MacBook Pro",
            lastReadDeviceId: "dev-mac",
            updatedAt: now.addingTimeInterval(-120)
        )

        let iphoneDoc = Doc(
            id: docId,
            title: "Mixture of Experts Blog",
            added: now.addingTimeInterval(-3600),
            kind: .web,
            source: "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1",
            webCleanMode: true,
            webHiddenSelectors: [".floating-share"],
            webAnchor: iphoneAnchor,
            tags: ["DOING"],
            pageCount: 8,
            readPage: 1,
            readUpdatedAt: now,
            lastReadDevice: "iPhone 16 Pro",
            lastReadDeviceId: "dev-iphone",
            updatedAt: now
        )

        let webCard = Card(
            docId: docId,
            page: 5,
            variant: .original,
            rects: [],
            text: "Auxiliary load balancing loss encourages balanced expert utilization.",
            color: 1,
            webAnchor: WebCardAnchor(
                sectionId: "s-3-2",
                sectionTitle: "3.2 Load Balancing Loss",
                blockId: "s-3-2::p-1",
                exact: "Auxiliary load balancing loss encourages balanced expert utilization.",
                prefix: "In sparse MoE layers, ",
                suffix: " Without it, routing collapse occurs.",
                progressPermille: 740
            )
        )

        let (merged, localChanged, _) = CloudSync.mergeLibraries(
            local: Library(docs: [macDoc], cards: [webCard]),
            remote: Library(docs: [iphoneDoc], cards: []),
            deleted: []
        )
        XCTAssertTrue(localChanged)
        let mDoc = merged.docs[0]
        XCTAssertEqual(mDoc.kind, .web)
        // Custom hidden selectors from both devices are merged
        XCTAssertEqual(Set(mDoc.webHiddenSelectors), Set([".cookie-banner", ".floating-share"]))
        // Conflict detected because newer iPhone reading position (15%) went backwards significantly from Mac (74%)
        XCTAssertNotNil(mDoc.pendingConflict)
        XCTAssertEqual(mDoc.pendingConflict?.localWebAnchor?.scrollFraction ?? 0, 0.74, accuracy: 0.001)
        XCTAssertEqual(mDoc.pendingConflict?.remoteWebAnchor?.scrollFraction ?? 0, 0.15, accuracy: 0.001)
        // Higher reading anchor (74% on Mac) is preserved until user resolves conflict
        XCTAssertEqual(mDoc.webAnchor?.scrollFraction ?? 0, 0.74, accuracy: 0.001)
        XCTAssertEqual(merged.cards.first?.webAnchor?.exact, "Auxiliary load balancing loss encourages balanced expert utilization.")
    }

    private func evalString(_ webView: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { res, _ in
                if let s = res as? String {
                    cont.resume(returning: s)
                } else if let b = res as? Bool {
                    cont.resume(returning: b ? "true" : "false")
                } else if let n = res as? NSNumber {
                    cont.resume(returning: n.stringValue)
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    func testWebDocLiveRuntimeDOMDeclutteringInteractiveVizAndResizeAnchor() async throws {
        let docId = UUID()
        let doc = Doc(
            id: docId,
            title: "MoE Interactive Benchmark",
            kind: .web,
            source: "https://huggingface-moe-blogpost.hf.space/#s-1",
            webCleanMode: true
        )
        Store.shared.lib.docs.append(doc)
        defer {
            Store.shared.deleteDoc(docId)
            Store.shared.saveNow()
        }

        let controller = WebDocController(docId: docId)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let sampleHTML = """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <title>A Visual Guide to Mixture of Experts (MoE)</title>
            <style>
                body { margin: 0; font-family: sans-serif; }
                header.site-header { height: 80px; background: #eee; }
                aside.toc-sidebar { width: 240px; float: left; }
                main.article { max-width: 820px; margin: 0 auto; padding: 24px; }
                p { line-height: 1.7; margin: 24px 0; }
                figure.viz { margin: 32px 0; }
                .viz-box { width: 1120px; height: 420px; background: #f5f7ff; position: relative; }
                footer.site-footer { height: 120px; background: #ddd; }
            </style>
        </head>
        <body>
            <header class="site-header"><nav>Hugging Face Top Navigation Bar</nav></header>
            <aside class="toc-sidebar">Table of Contents Sidebar</aside>
            <main class="article">
                <h1 id="s-0">A Visual Guide to Mixture of Experts</h1>
                <p id="intro-p">Mixture of Experts (MoE) enables models to scale parameter counts dramatically while keeping compute per token constant.</p>
                <h2 id="s-1">1. Sparse MoE Layer Architecture</h2>
                <p id="s1-p1">In a dense transformer, every token passes through the exact same feed-forward network parameters.</p>
                <figure class="viz">
                    <div class="viz-box" id="interactive-viz-box">
                        <iframe id="moe-iframe" src="about:blank" width="1120" height="400"></iframe>
                    </div>
                    <figcaption>Interactive Diagram 1: Token routing across 8 experts.</figcaption>
                </figure>
                <h2 id="s-2-0">2. Router &amp; Load Balancing</h2>
                <p id="s2-p1">Auxiliary load balancing loss prevents routing collapse by encouraging uniform expert assignment across a batch.</p>
                <p style="height: 1800px;">Extended interactive article space for scroll and anchor verification.</p>
            </main>
            <footer class="site-footer">Peripheral Footer Links &amp; Social Share</footer>
        </body>
        </html>
        """

        controller.webView.loadHTMLString(sampleHTML, baseURL: URL(string: "https://huggingface-moe-blogpost.hf.space/#s-1"))

        // Wait for WKWebView navigation and readlet-live.js initialization
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !controller.isLoading && !controller.sections.isEmpty { break }
        }

        // 1. Verify section extraction (TOC headings)
        XCTAssertGreaterThanOrEqual(controller.sections.count, 3)
        XCTAssertTrue(controller.sections.contains(where: { $0.id == "s-1" && $0.title.contains("1. Sparse MoE Layer Architecture") }))
        XCTAssertTrue(controller.sections.contains(where: { $0.id == "s-2-0" }))

        // 2. Verify non-destructive peripheral content decluttering (cleanMode == true hides header/sidebar/footer, keeps main + iframe alive)
        struct CleanDOMState: Decodable {
            var cleanAttr: String?
            var headerDisplay: String?
            var footerDisplay: String?
            var mainDisplay: String?
            var iframeAlive: Bool?
        }
        let cleanStateJSON = await evalString(controller.webView, """
        JSON.stringify({
            cleanAttr: document.documentElement.getAttribute('data-readlet-clean'),
            headerDisplay: window.getComputedStyle(document.querySelector('header.site-header')).display,
            footerDisplay: window.getComputedStyle(document.querySelector('footer.site-footer')).display,
            mainDisplay: window.getComputedStyle(document.querySelector('main.article')).display,
            iframeAlive: !!document.getElementById('moe-iframe')
        })
        """)
        let cleanState = try JSONDecoder().decode(CleanDOMState.self, from: Data((cleanStateJSON.isEmpty ? "{}" : cleanStateJSON).utf8))
        XCTAssertEqual(cleanState.cleanAttr, "on")
        XCTAssertEqual(cleanState.headerDisplay, "none")
        XCTAssertEqual(cleanState.footerDisplay, "none")
        XCTAssertNotEqual(cleanState.mainDisplay, "none")
        XCTAssertEqual(cleanState.iframeAlive, true)

        // 3. Toggle cleanMode OFF for this article -> header & footer immediately reappear without destroying DOM
        controller.setCleanMode(false)
        try await Task.sleep(nanoseconds: 100_000_000)
        let restoredHeaderDisplay = await evalString(controller.webView, """
        window.getComputedStyle(document.querySelector('header.site-header')).display
        """)
        XCTAssertNotEqual(restoredHeaderDisplay, "none")

        // Turn cleanMode back ON
        controller.setCleanMode(true)
        try await Task.sleep(nanoseconds: 100_000_000)

        // 4. Verify in-place Bilingual DOM injection skips <figure class="viz"> and injects below paragraphs
        let blocksJSON = await evalString(controller.webView, "JSON.stringify(window.__readletLive.getTranslatableBlocks(1))")
        let blocks = try JSONDecoder().decode([[String: String]].self, from: Data((blocksJSON.isEmpty ? "[]" : blocksJSON).utf8))
        XCTAssertFalse(blocks.isEmpty)
        if let firstBlockId = blocks.first?["id"] {
            _ = await evalString(controller.webView, "window.__readletLive.setVariant('bilingual'); 'ok'")
            let sampleMap = [firstBlockId: "在稠密 Transformer 中，每个词元都会经过完全相同的前馈网络参数。"]
            let mapJSON = String(data: try JSONEncoder().encode(sampleMap), encoding: .utf8)!
            _ = await evalString(controller.webView, "window.__readletLive.applyTranslations(\(mapJSON)); 'ok'")
            let bilingualDisplay = await evalString(controller.webView, """
            (function() {
                var el = document.querySelector('.readlet-bi-trans');
                return el ? window.getComputedStyle(el).display + ':' + el.textContent : 'missing';
            })()
            """)
            XCTAssertTrue(bilingualDisplay.hasPrefix("block:在稠密 Transformer 中"))
        }

        // 5. Verify W3C TextQuoteSelector highlight anchoring across viewport sizes
        let quoteText = "every token passes through the exact same feed-forward network"
        let card = Card(
            docId: docId,
            page: 1,
            variant: .original,
            rects: [],
            text: quoteText,
            color: 0,
            webAnchor: WebCardAnchor(sectionId: "s-1", exact: quoteText)
        )
        Store.shared.lib.cards.append(card)
        controller.refreshAnnotations()
        try await Task.sleep(nanoseconds: 100_000_000)
        let markText = await evalString(controller.webView, """
        (document.querySelector('mark.readlet-card-hl') || {}).textContent || ''
        """)
        XCTAssertEqual(markText, quoteText)

        // 6. Verify scrolling down does not snap back when SwiftUI triggers loadIfNeeded()
        _ = await evalString(controller.webView, "window.scrollTo({ top: 420, behavior: 'instant' }); 'ok'")
        try await Task.sleep(nanoseconds: 200_000_000)
        controller.loadIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let scrollYAfterUpdate = Double(await evalString(controller.webView, "String(Math.round(window.scrollY))")) ?? 0
        XCTAssertGreaterThanOrEqual(scrollYAfterUpdate, 380, "Scrolling down must not snap back to the top when SwiftUI updates the view")

        // 7. Verify cross-window / narrow split-pane responsive scaling of wide 1120px .viz-box
        controller.webView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await evalString(controller.webView, "window.__readletLive.fitWideVisualizations(); 'ok'")
        let transformStr = await evalString(controller.webView, """
        document.getElementById('moe-iframe').style.transform || ''
        """)
        XCTAssertTrue(transformStr.contains("scale("), "Wide 1120px interactive visualization should scale down responsively inside a 420px split pane")
    }

    func testLiveHuggingFaceMoEBlogpostBenchmark() async throws {
        let benchmarkURL = "https://huggingface.co/spaces/huggingface/moe-blogpost#s-1"
        guard let importedId = Store.shared.importWebURL(benchmarkURL, cleanMode: true) else {
            XCTFail("Failed to import benchmark URL")
            return
        }
        defer {
            Store.shared.deleteDoc(importedId)
            Store.shared.saveNow()
        }

        let controller = WebDocController(docId: importedId)
        controller.webView.frame = CGRect(x: 0, y: 0, width: 520, height: 820)
        controller.loadIfNeeded()

        // Wait up to 12 seconds for live page load & section indexing
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if !controller.isLoading && !controller.sections.isEmpty { break }
        }

        // If offline/unreachable in a restricted test runner, skip live assertions cleanly
        guard !controller.sections.isEmpty else { return }

        XCTAssertEqual(controller.currentURLString, "https://huggingface-moe-blogpost.hf.space/#s-1")
        XCTAssertGreaterThanOrEqual(controller.sections.count, 5, "Should extract all major sections from MoE blogpost")
        XCTAssertTrue(controller.sections.contains(where: { $0.id == "s-1" }))

        let vizCountStr = await evalString(controller.webView, "String(document.querySelectorAll('figure.viz .viz-box, .viz-box').length)")
        let vizCount = Int(vizCountStr) ?? 0
        XCTAssertGreaterThan(vizCount, 0, "Interactive .viz-box visualizations on MoE blogpost must remain intact in live DOM")
    }

    func testWebExtractPreservesMediaColumnFiguresNextImageCoverAndTypography() async throws {
        let readabilityURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web/Readability.js")
        let extractURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web/readit-extract.js")
        let readabilityJS = try String(contentsOf: readabilityURL, encoding: .utf8)
        let extractJS = try String(contentsOf: extractURL, encoding: .utf8)

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>The components of agent memory \\ Anthropic</title>
        <meta property="og:site_name" content="Anthropic">
        <meta name="twitter:creator" content="@AnthropicAI">
        <style>
        @font-face {
            font-family: anthropicSerif;
            src: url("/fonts/anthropic-serif.woff2") format("woff2");
            font-weight: 300 800;
            font-style: normal;
        }
        @font-face {
            font-family: anthropicSans;
            src: url("/fonts/anthropic-sans.woff2") format("woff2");
            font-weight: 300 800;
            font-style: normal;
        }
        @font-face {
            font-family: jetBrainsMono;
            src: url("/fonts/jetbrains-mono.woff2") format("woff2");
            font-weight: 400;
            font-style: normal;
        }
        body {
            font-family: anthropicSerif, "anthropicSerif Fallback", Georgia, serif;
            font-size: 17px;
            line-height: 1.6;
        }
        h1, h2, h3, figcaption {
            font-family: anthropicSans, "anthropicSans Fallback", sans-serif;
        }
        h1 { font-size: 36px; font-weight: 700; line-height: 1.15; }
        h2 { font-size: 22px; font-weight: 700; line-height: 1.25; }
        p { font-size: 17px; line-height: 27.2px; margin-bottom: 20px; }
        code { font-family: jetBrainsMono, "jetBrainsMono Fallback", monospace; font-size: 14.5px; }
        figcaption { font-size: 13px; line-height: 1.45; }
        </style>
        </head>
        <body>
        <main>
        <article class="research-article">
            <header class="VYxBBq_Header" style="visibility:hidden">
                <h1 class="title">The components of agent memory</h1>
                <div class="meta"><span>Apr 22, 2026</span></div>
                <div class="VYxBBq_CoverImage">
                    <img alt="Cover illustration" src="/_next/image?url=https%3A%2F%2Fwww-cdn.anthropic.com%2Fimages%2Fcover-hero.svg&amp;w=1920&amp;q=75" width="1000" height="1000">
                </div>
            </header>
            <div class="PA4F1q_body">
                <p>Modern language model agents operate over long horizons and require structured memory architectures to manage context effectively across multi-step reasoning tasks. Without explicit memory compression and retrieval mechanisms, long-running coding and research agents rapidly saturate their context window with raw tool outputs and intermediate search results.</p>
                <p>In this post, we benchmark how different memory components interact across realistic software engineering and document synthesis tasks using <code>SubagentMemory</code> and <code>ContextCompactor</code>. We evaluate both episodic memory stores and semantic workspace summaries across hundreds of multi-hour sessions.</p>
                <h2>Memory retrieval mechanisms</h2>
                <p>When an agent queries past trajectories, it can rely on lexical search, vector embeddings, or hierarchical summaries maintained by background tasks across long sessions. Each retrieval mechanism offers distinct trade-offs in latency, precision, and token efficiency when scaling to large codebases.</p>
                <div class="PA4F1q_media-column" data-type="image" data-width="full-width">
                    <figure class="figure-wrap">
                        <div class="img-wrap">
                            <img alt="Architecture diagram" width="2650" height="1484" src="/_next/image?url=https%3A%2F%2Fwww-cdn.anthropic.com%2Fimages%2Ffig1.png&amp;w=640&amp;q=75" srcset="/_next/image?url=https%3A%2F%2Fwww-cdn.anthropic.com%2Fimages%2Ffig1.png&amp;w=640&amp;q=75 640w, /_next/image?url=https%3A%2F%2Fwww-cdn.anthropic.com%2Fimages%2Ffig1.png&amp;w=3840&amp;q=75 3840w">
                        </div>
                        <figcaption style="--figure-label:&quot;Figure 1&quot;">Overview of the memory hierarchy and context window management.</figcaption>
                    </figure>
                </div>
                <p>Across our evaluations, structured file-backed memory consistently outperformed unindexed transcript replay while keeping token overhead bounded across extended agent runs.</p>
            </div>
            <section class="UxquqW_Section">
                <div class="UxquqW_Content" style="visibility:hidden">
                    <h3>Authors &amp; acknowledgements</h3>
                    <p>Written by Lance Martin, with contributions from the Anthropic Research team.</p>
                </div>
            </section>
        </article>
        </main>
        </body>
        </html>
        """

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        wv.loadHTMLString(html, baseURL: URL(string: "https://www.anthropic.com/research/components-of-agent-memory"))
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let loaded = await evalString(wv, "document.querySelector('article.research-article') ? 'yes' : 'no'")
            if loaded == "yes" { break }
        }

        let payloadJSON = try await wv.evaluateJavaScript(readabilityJS + "\n;\n" + extractJS + "\nwindow.__readitExtract();") as? String ?? "{}"
        let extracted = try JSONDecoder().decode(WebImporter.Extracted.self, from: Data(payloadJSON.utf8))

        XCTAssertTrue(extracted.ok)
        // Must preserve both the cover image AND the in-body figure inside div.PA4F1q_media-column
        XCTAssertEqual(extracted.imageURLs.count, 2)
        // Must unwrap Next.js /_next/image?url=... proxy to the underlying CDN URLs
        XCTAssertEqual(extracted.imageURLs.first, "https://www-cdn.anthropic.com/images/cover-hero.svg")
        XCTAssertEqual(extracted.imageURLs.last, "https://www-cdn.anthropic.com/images/fig1.png")
        // Must preserve Figure 1 label from --figure-label CSS custom property
        XCTAssertTrue(extracted.html.contains("class=\"readit-fig-label\">Figure 1</span>"))
        // Must preserve trailing Authors & acknowledgements section even when style="visibility:hidden"
        XCTAssertTrue(extracted.html.contains("Authors &amp; acknowledgements") || extracted.html.contains("Authors & acknowledgements"))
        XCTAssertTrue(extracted.html.contains("Written by Lance Martin"))
        // Must not duplicate @AnthropicAI Twitter handle as author when site is Anthropic
        XCTAssertFalse(extracted.html.contains("@AnthropicAI"))
        // Must capture @font-face URLs and computed typography without Next.js "* Fallback" override
        XCTAssertEqual(extracted.fontURLs.count, 3)
        XCTAssertTrue(extracted.html.contains("anthropicSerif"))
        XCTAssertFalse(extracted.html.contains("anthropicSerif Fallback"))
        XCTAssertTrue(extracted.html.contains("jetBrainsMono"))
    }

    func testCloudSyncBackwardsPageTurnToPageOneAndNewNotebookPreserved() {
        let docId = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(30) // User turned back from Page 10 (index 9) to Page 1 (index 0)

        var remoteDoc = Doc(id: docId, title: "Sync Regression Test", pageCount: 20, updatedAt: t0)
        remoteDoc.readPage = 9
        remoteDoc.readUpdatedAt = t0
        remoteDoc.lastReadDevice = "Mac"
        remoteDoc.lastReadDeviceId = "mac-1"

        var localDoc = remoteDoc
        localDoc.readPage = 0
        localDoc.readUpdatedAt = t1
        localDoc.lastReadDevice = "Mac"
        localDoc.lastReadDeviceId = "mac-1"

        let defaultNb = Notebook(name: "我的笔记本", docIds: [docId], root: MindNode(title: "我的笔记本"), updatedAt: t0)
        let newlyCreatedNb = Notebook(name: "新建笔记本", docIds: [], root: MindNode(title: "新建笔记本"), updatedAt: t1)

        let remoteLib = Library(
            docs: [remoteDoc],
            notebooks: [defaultNb],
            cards: [],
            links: []
        )
        let localLib = Library(
            docs: [localDoc],
            notebooks: [defaultNb, newlyCreatedNb],
            cards: [],
            links: []
        )

        // 1. Local has turned back to Page 1 (index 0) at t1 > t0 and created a new notebook
        let (merged1, _, remoteChanged1) = CloudSync.mergeLibraries(
            local: localLib,
            remote: remoteLib,
            deleted: []
        )
        XCTAssertEqual(merged1.docs.first?.readPage, 0, "Turning back from Page 10 to Page 1 must NOT snap back to Page 10")
        XCTAssertEqual(merged1.docs.first?.readUpdatedAt, t1)
        XCTAssertNil(merged1.docs.first?.pendingConflict, "Same-device backwards page turn must not create a conflict")
        XCTAssertEqual(merged1.notebooks.count, 2, "Newly created notebook must be preserved during sync merge")
        XCTAssertTrue(merged1.notebooks.contains(where: { $0.id == newlyCreatedNb.id && $0.name == "新建笔记本" }))
        XCTAssertTrue(remoteChanged1)

        // 2. Even if localLib is passed as `remote` (e.g. re-merging live Store.shared.lib with background sync result)
        let (merged2, _, _) = CloudSync.mergeLibraries(
            local: remoteLib,
            remote: localLib,
            deleted: []
        )
        XCTAssertEqual(merged2.docs.first?.readPage, 0, "Newer Page 1 timestamp must win regardless of merge direction")
        XCTAssertEqual(merged2.notebooks.count, 2, "Newly created notebook must be preserved regardless of merge direction")
    }
}


