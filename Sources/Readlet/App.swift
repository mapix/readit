import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct ReadletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared
    @ObservedObject var lang = LangCenter.shared

    var body: some Scene {
        Window("Readlet", id: "library") {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(LF("关于 %@", AppInfo.name)) { showAboutPanel() }
                if AppInfo.selfUpdates { Button(L("检查更新…")) { Task { await UpdateChecker.shared.check(manual: true) } } }
            }
            CommandGroup(replacing: .help) {
                Button(L("键盘快捷键")) { ShortcutsPanel.show() }.keyboardShortcut("/")
                Button(L("欢迎与设置向导…")) { OnboardingPanel.show() }
                Divider()
                Button(L("Readlet 官网")) { NSWorkspace.shared.open(AppInfo.website) }
                Button(L("支持与常见问题")) { NSWorkspace.shared.open(AppInfo.supportURL) }
                Button(L("隐私政策")) { NSWorkspace.shared.open(AppInfo.privacyURL) }
                Button(L("反馈问题")) { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
            CommandGroup(replacing: .newItem) {
                Button(L("导入 PDF 或文档…")) { importPanel() }.keyboardShortcut("o")
                Button(L("从网页导入…")) { WebImportPanel.show() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button(L("新建笔记本")) { store.newNotebook() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(L("导出双语 PDF…")) { exportBilingual() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button(L("导出脑图为 Markdown…")) { exportMarkdown() }
                Button(L("导出摘录笔记为 Markdown…")) { exportNotesMarkdown() }
                Button(L("导出到 Anki…")) { exportAnki() }
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button(L("在文档中查找…")) { NotificationCenter.default.post(name: .findInDocument, object: DocWindows.shared.activeDocId) }.keyboardShortcut("f")
                Button(L("查找下一个")) { NotificationCenter.default.post(name: .findNext, object: nil) }.keyboardShortcut("g")
                Button(L("查找上一个")) { NotificationCenter.default.post(name: .findPrevious, object: nil) }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandMenu(L("阅读")) {
                Button(L("原文")) { ReaderController.shared.setVariant(.original) }.keyboardShortcut("1")
                Button(L("双语")) { ReaderController.shared.setVariant(.bilingual) }.keyboardShortcut("2")
                Divider()
                Button(L("摘录选中内容为卡片")) { ReaderController.shared.makeCard() }.keyboardShortcut("d")
                Button(L("翻译选中文本")) { ReaderController.shared.menuTranslate() }.keyboardShortcut("t")
                Divider()
                Button(L("放大")) { ReaderController.shared.zoom(1.15) }.keyboardShortcut("=")
                Button(L("缩小")) { ReaderController.shared.zoom(1 / 1.15) }.keyboardShortcut("-")
                Button(L("适合宽度")) { ReaderController.shared.fitWidth() }.keyboardShortcut("0")
                Divider()
                Button(L("导出 AI 解读为 MP4")) { NarrationExporter.shared.start() }
            }
        }
        SwiftUI.Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--render-test"), CommandLine.arguments.count > i + 2 {
            let src = URL(fileURLWithPath: CommandLine.arguments[i + 1]), dst = URL(fileURLWithPath: CommandLine.arguments[i + 2])
            Task { @MainActor in await renderTest(src, dst); exit(0) }
            return
        }
        Migration.run()
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: AppTheme.current.isDark ? .darkAqua : .aqua)
        if let script = ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] {
            // debug automation: ';'-separated steps, one every 4s
            var steps = script.split(separator: ";").map { String($0) }
            Timer.scheduledTimer(withTimeInterval: Double(ProcessInfo.processInfo.environment["STEP_SEC"] ?? "4") ?? 4, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard !steps.isEmpty else { t.invalidate(); return }
                    let s = steps.removeFirst()
                    let st = Store.shared, rc = ReaderController.shared
                    print("STEP", s)
                    if s.hasPrefix("open:") { _ = st.importPDF(URL(fileURLWithPath: String(s.dropFirst(5))), open: true) }
                    else if s == "library" { NSApp.windows.first { $0.identifier?.rawValue == "library" }?.makeKeyAndOrderFront(nil) }
                    else if s == "study" { if let d = st.lib.docs.first { DocWindows.shared.open(d.id) } }
                    else if s == "outline" { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showOutline"), forKey: "showOutline") }
                    else if s == "tapcard" { if let c = st.lib.cards.last { rc.openCard(c.id) } }
                    else if s.hasPrefix("comment:") { if let c = st.lib.cards.last { st.updateCard(c.id) { $0.comments.append(String(s.dropFirst(8))) } } }
                    else if s == "close" { rc.closePopup() }
                    else if s == "bi" { rc.setVariant(.bilingual) }
                    else if s == "orig" { rc.setVariant(.original) }
                    else if s.hasPrefix("page:") { rc.goToPage(Int(s.dropFirst(5)) ?? 0) }
                    else if s.hasPrefix("select:") {
                        let q = String(s.dropFirst(7))
                        if let sel = rc.view.document?.findString(q, withOptions: .caseInsensitive).first { rc.view.setCurrentSelection(sel, animate: false); rc.view.go(to: sel); rc.selectionChanged(); rc.simulateMouseUp() }
                    }
                    else if s == "card" { rc.makeCard(color: Int.random(in: 0..<5)) }
                    else if s.hasPrefix("scrollby:") { if let sv = rc.view.documentView?.enclosingScrollView { var o = sv.contentView.bounds.origin; o.y += CGFloat(Double(s.dropFirst(9)) ?? 0); sv.contentView.scroll(to: o); sv.reflectScrolledClipView(sv.contentView) } }
                    else if s == "ai" { UserDefaults.standard.set(true, forKey: "showCopilot") }
                    else if s == "aipage" { if let id = rc.docId, let ses = st.session(id) { CopilotStore.shared.summarizePage(docId: id, doc: ses.original, title: ses.doc.title, page: rc.currentPageIndex) } }
                    else if s.hasPrefix("aiask:") { if let id = rc.docId, let ses = st.session(id) { CopilotStore.shared.askFree(docId: id, doc: ses.original, title: ses.doc.title, page: rc.currentPageIndex, question: String(s.dropFirst(6))) } }
                    else if s == "aidump" { if let id = rc.docId { for m in CopilotStore.shared.thread(id).messages { print("MSG", m.role.rawValue, m.text.prefix(80).replacingOccurrences(of: "\n", with: " ")) } } }
                    else if s == "narrate" { if let id = rc.docId, let ses = st.session(id) { Narrator.shared.start(docId: id, doc: ses.document(rc.variant), title: ses.doc.title, from: rc.currentPageIndex) } }
                    else if s.hasPrefix("hlnarr:") { Narrator.reader.highlightNarration(page: Int(s.dropFirst(7)) ?? 0, quote: nil); print("HL ok") }
                    else if s == "nprog" { if let id = rc.docId ?? Narrator.shared.docId { let p = Narrator.savedProgress(id); print("NPROG", p.map { "page \($0.page) seg \($0.seg)" } ?? "none", "resumed", Narrator.shared.resumedFrom != nil) } }
                    else if s == "nfocus" { print("FOCUS", rc.debugFocus()) }
                    else if s == "export" { NarrationExporter.shared.start(limitPages: Int(ProcessInfo.processInfo.environment["EXPORT_PAGES"] ?? "")) }
                    else if s == "rec" { Narrator.shared.recording.toggle(); print("REC", Narrator.shared.recording) }
                    else if s == "nstat" { let n = Narrator.shared; print("NARR", n.state, "page", n.page, "seg", n.segIndex, "/", n.segments.count, n.error ?? "", n.segments.first?.text.prefix(50) ?? "") }
                    else if s.hasPrefix("vask:") { Narrator.shared.debugAsk(String(s.dropFirst(5))) }
                    else if s == "qa" { print("QA", Narrator.shared.state, Narrator.shared.answering, Narrator.shared.lastQA?.a.prefix(80) ?? "-") }
                    else if s == "mini" { MiniWidget.shared.collapse() }
                    else if s == "wsnap" { if let p = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }), let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/imtb/widget.png")) } }
                    else if s.hasPrefix("rview:") {
                        let which = String(s.dropFirst(6))
                        let v: AnyView
                        if which == "flash" { v = AnyView(FlashcardsView(store: st, rc: rc, open: .constant(true)).frame(width: 900, height: 700)) }
                        else if which == "study", let id = rc.docId, let d = FlashStore.shared.decks(id).first { v = AnyView(StudySession(docId: id, deckIndex: 0, deck: d).frame(width: 720, height: 510).background(Color.white)) }
                        else if which == "map", let nb = st.currentNotebook {
                            let laid = MindLayout.layout(nb.root, store: st)
                            let W = (laid.map { $0.frame.maxX }.max() ?? 300) + 40, H = (laid.map { $0.frame.maxY }.max() ?? 300) + 40
                            v = AnyView(ZStack(alignment: .topLeading) {
                                MN.mapBG
                                ForEach(laid) { n in NodeView(store: st, laid: n, isDrop: false).frame(width: n.frame.width, height: n.frame.height).position(x: n.frame.midX, y: n.frame.midY) }
                            }.frame(width: W, height: min(H, 2400)))
                        }
                        else if which == "lib" { v = AnyView(LibraryView(store: st).frame(width: 1100, height: 700)) }
                        else { v = AnyView(NarratorBar().padding(20).frame(width: 720, height: 320).background(Color.gray.opacity(0.2))) }
                        let r = ImageRenderer(content: v.environment(\.colorScheme, .light)); r.scale = 2
                        if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/imtb/rv-\(which).png")) }
                    }
                    else if s == "expand" { MiniWidget.shared.expand() }
                    else if s.hasPrefix("winw:") { if let w = DocWindows.shared.active?.window { var f = w.frame; f.size.width = CGFloat(Double(s.dropFirst(5)) ?? 900); w.setFrame(f, display: true) } }
                    else if s.hasPrefix("openn:") { let i = Int(s.dropFirst(6)) ?? 0; if i < st.lib.docs.count { DocWindows.shared.open(st.lib.docs[i].id) } }
                    else if s.hasPrefix("model:") { let parts = s.dropFirst(6).split(separator: ","); ModelConfig.setModel("chat", String(parts[0])); if parts.count > 1, let st = APIStyle(rawValue: String(parts[1])) { ModelConfig.setStyle("chat", st) } }
                    else if s == "genmap" { if let id = rc.docId { MapGenerator.shared.generate(docId: id) } }
                    else if s == "mapstat" { print("MAP", MapGenerator.shared.running != nil, MapGenerator.shared.error ?? "", st.currentNotebook.map { "\($0.root.children.count) top, \(st.lib.cards.count) cards" } ?? "") }
                    else if s.hasPrefix("uilang:") { LangCenter.shared.set(UILang(rawValue: String(s.dropFirst(7))) ?? .zh) }
                    else if s.hasPrefix("theme:") { ThemeCenter.shared.set(AppTheme(rawValue: String(s.dropFirst(6))) ?? .light) }
                    else if s == "wins" { print("WINS", NSApp.windows.filter { $0.isVisible }.map { "\(type(of: $0)) \($0.title.prefix(20)) \(Int($0.frame.width))x\(Int($0.frame.height))" }, "entries", DocWindows.shared.entries.count, "key", NSApp.keyWindow?.title ?? "nil", "active", NSApp.isActive) }
                    else if s == "flash" { NotificationCenter.default.post(name: .openFlashcards, object: nil) }
                    else if s == "flashgen" { if let id = rc.docId, let ses = st.session(id) { FlashStore.shared.generate(docId: id, doc: ses.original, title: ses.doc.title, pages: 0...4, count: 8) } }
                    else if s == "fstat" { if let id = rc.docId { print("FLASH", FlashStore.shared.generating, FlashStore.shared.decks(id).map { "\($0.title):\($0.cards.count)" }, FlashStore.shared.genError ?? "") } }
                    else if s == "reqs" { print("REQS", Translator.requestCount, ReaderController.shared.docId.flatMap { Store.shared.sessions[$0]?.translatedPages.count } ?? -1) }
                    else if s == "pos" { print("POS", rc.debugTopPosition()) }
                    else if s == "linklast" { let cs = st.lib.cards; if cs.count >= 2 { st.link(cs[cs.count - 1].id, cs[cs.count - 2].id) } }
                    else if s.hasPrefix("export:") { if let id = rc.docId, let ses = st.session(id) { print("export", ses.exportBilingual(to: URL(fileURLWithPath: String(s.dropFirst(7))))) } }
                    else if s == "addnode" { st.addChild(to: st.currentNotebook?.root.id, title: "跨文档主题") ; st.editingNodeId = nil }
                    else if s == "dump" { print("cards", st.lib.cards.count, "links", st.lib.links.count, "docs", st.lib.docs.count) }
                }
            }
        }
        if let snap = ProcessInfo.processInfo.environment["BIREADER_SNAP"] {
            // debug: periodically write a snapshot of the main window
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let w = (DocWindows.shared.active?.window).flatMap({ $0.isVisible ? $0 : nil }) ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }), let v = w.contentView?.superview ?? w.contentView else { return }
                    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    // PDFView content isn't captured by cacheDisplay; paint the visible page region on top
                    let pv = ReaderController.shared.view
                    if let page = pv.currentPage, pv.window != nil {
                        let r = pv.convert(pv.bounds, to: v)
                        let img = NSImage(size: pv.bounds.size)
                        img.lockFocus()
                        NSColor(calibratedWhite: 0.9, alpha: 1).setFill(); NSRect(origin: .zero, size: pv.bounds.size).fill()
                        if let ctx = NSGraphicsContext.current?.cgContext {
                            for p in pv.visiblePages {
                                let pr = pv.convert(p.bounds(for: pv.displayBox), from: p)
                                ctx.saveGState()
                                NSColor.white.setFill(); pr.fill()
                                ctx.translateBy(x: pr.minX, y: pr.minY)
                                ctx.scaleBy(x: pr.width / p.bounds(for: pv.displayBox).width, y: pr.height / p.bounds(for: pv.displayBox).height)
                                p.draw(with: pv.displayBox, to: ctx)
                                ctx.restoreGState()
                            }
                        }
                        _ = page
                        // narration focus frame
                        if let fl = pv.documentView?.layer?.sublayers?.compactMap({ $0 as? CAShapeLayer }).first, let path = fl.path, let ctx = NSGraphicsContext.current?.cgContext, let dv = pv.documentView {
                            let r = pv.convert(path.boundingBox, from: dv)
                            ctx.setStrokeColor(NSColor.systemPurple.cgColor); ctx.setLineWidth(2.5)
                            ctx.stroke(r)
                        }
                        img.unlockFocus()
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        let flipped = v.isFlipped
                        let dr = flipped ? NSRect(x: r.minX, y: v.bounds.height - r.maxY, width: r.width, height: r.height) : r
                        img.draw(in: dr)
                        // popups live in SwiftUI above the PDF; draw them on top again
                        if ReaderController.shared.popup != .none, let a = ReaderController.shared.anchor {
                            let host = NSHostingView(rootView: ReaderOverlay(store: Store.shared, rc: ReaderController.shared).frame(width: pv.bounds.width, height: pv.bounds.height))
                            host.frame = NSRect(origin: .zero, size: pv.bounds.size)
                            host.layoutSubtreeIfNeeded()
                            _ = a
                            if let r2 = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                                host.cacheDisplay(in: host.bounds, to: r2)
                                r2.draw(in: dr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                            }
                        }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snap))
                }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { DocWindows.shared.restore() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { MainActor.assumeIsolated { UpdateChecker.shared.checkOnLaunch() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainActor.assumeIsolated { OnboardingPanel.showIfNeeded() } }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in importFiles(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { !MiniWidget.shared.active }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { Task { @MainActor in MiniWidget.shared.expand() }; return true }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { DocWindows.shared.terminating = true }
        return .terminateNow
    }
    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { DocWindows.shared.terminating = true; Store.shared.saveNow() }
        TranslationCache.shared.flushSync()
        UsageStore.shared.flush()
        if let d = try? JSONEncoder().encode(Store.shared.lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
    }
}

/// file types Readlet can open: PDFs directly, other documents are converted to PDF
@MainActor var importableTypes: [UTType] {
    [.pdf] + DocConverter.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
}

/// standard About panel with edition, links and open-source acknowledgements
@MainActor func showAboutPanel() {
    let credits = NSMutableAttributedString()
    let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
    credits.append(NSAttributedString(string: (AppInfo.isAppStore ? L("Mac App Store 版") : L("直接下载版")) + "\n\n", attributes: small))
    for (title, url) in [(L("官网"), AppInfo.website), (L("支持与常见问题"), AppInfo.supportURL), (L("隐私政策"), AppInfo.privacyURL)] {
        credits.append(NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11), .link: url]))
        credits.append(NSAttributedString(string: "   ", attributes: small))
    }
    credits.append(NSAttributedString(string: "\n\n" + L("开源组件") + "\nMozilla Readability — Apache License 2.0\nmarked — MIT License\n", attributes: small))
    NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: AppInfo.name,
        .applicationVersion: AppInfo.version,
        .version: AppInfo.build,
        .credits: credits,
    ])
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor func importPanel(notebook: UUID? = nil) {
    let p = NSOpenPanel()
    p.allowedContentTypes = importableTypes
    p.allowsMultipleSelection = true
    p.message = L("PDF 直接导入；EPUB、Markdown、Word、RTF、HTML、TXT 会转换成 PDF")
    if p.runModal() == .OK { importFiles(p.urls, notebook: notebook) }
}

@MainActor func importFiles(_ urls: [URL], notebook: UUID? = nil, open: Bool = true) {
    for u in urls {
        let ext = u.pathExtension.lowercased()
        if ext == "pdf" {
            if let nb = notebook { Store.shared.currentNotebookId = nb }
            _ = Store.shared.importPDF(u, open: open)
        } else if DocConverter.supportedExtensions.contains(ext) {
            WebImportPanel.show(notebook: notebook, url: nil)
            WebImporter.shared.startFile(u, notebook: notebook)
        }
    }
}

@MainActor func exportBilingual() {
    let s = Store.shared
    guard let id = ReaderController.shared.docId, let ses = s.session(id) else { return }
    let p = NSSavePanel()
    p.allowedContentTypes = [.pdf]
    p.nameFieldStringValue = ses.doc.title + "（双语）.pdf"
    if p.runModal() == .OK, let u = p.url { _ = ses.exportBilingual(to: u) }
}

@MainActor func exportMarkdown() {
    let s = Store.shared
    guard let nb = s.currentNotebook else { return }
    var out = ""
    func walk(_ n: MindNode, _ d: Int) {
        let pad = String(repeating: "  ", count: max(0, d - 1))
        let title = s.nodeTitle(n).replacingOccurrences(of: "\n", with: " ")
        if d == 0 { out += "# \(title)\n\n" } else {
            out += "\(pad)- \(title)"
            if let c = s.card(n.cardId) {
                out += "  _(\(s.doc(c.docId)?.title ?? "") p.\(c.page + 1))_"
                if let t = c.translation, n.title.isEmpty { out += "\n\(pad)  > \(t)" }
                if !c.commentText.isEmpty { out += "\n\(pad)  💬 \(c.commentText)" }
            }
            out += "\n"
        }
        for c in n.children { walk(c, d + 1) }
    }
    walk(nb.root, 0)
    let p = NSSavePanel()
    p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    p.nameFieldStringValue = nb.name + ".md"
    if p.runModal() == .OK, let u = p.url { try? out.write(to: u, atomically: true, encoding: .utf8) }
}

/// Headless self-test: translate the first pages of a PDF and write the bilingual result.
@MainActor func renderTest(_ src: URL, _ dst: URL) async {
    guard let d = PDFDocument(url: src) else { print("cannot open"); return }
    let out = PDFDocument()
    let n = min(d.pageCount, Int(ProcessInfo.processInfo.environment["PAGES"] ?? "3") ?? 3)
    let from = Int(ProcessInfo.processInfo.environment["FROM"] ?? "0") ?? 0
    for i in from..<n {
        guard let page = d.safePage(i) else { continue }
        let paras = Layout.paragraphs(page)
        print("page \(i + 1): \(paras.count) paras")
        for p in paras.prefix(200) { print(String(format: "  [%.0f,%.0f %.0fx%.0f] h=%.1f n=%d %@ ", p.rect.minX, p.rect.minY, p.rect.width, p.rect.height, p.lineHeight, p.lines, p.translatable ? "T" : "-") + String(p.text.prefix(70))) }
        if ProcessInfo.processInfo.environment["PARAS_ONLY"] != nil { continue }
        let texts = paras.filter { $0.translatable }.map { $0.text }
        var trs = [String?](repeating: nil, count: paras.count)
        do {
            let r = try await Translator.translate(texts)
            var k = 0
            for (j, p) in paras.enumerated() where p.translatable { trs[j] = r[k]; k += 1 }
        } catch { print("translate error: \(error)") }
        if let data = BilingualRenderer.render(page: page, paras: paras, translations: trs), let pd = PDFDocument(data: data), let np = pd.safePage(0) {
            out.insert(np, at: out.pageCount)
        }
    }
    await TranslationCache.shared.flush()
    out.write(to: dst)
    print("wrote \(dst.path)")
}


/// captures the hosting NSWindow of a SwiftUI view
struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { found(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { found(v.window) } }
}
