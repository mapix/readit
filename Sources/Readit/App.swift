import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@main
struct BiReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared
    @ObservedObject var lang = LangCenter.shared

    var body: some Scene {
        Window("Readit", id: "library") {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("导入 PDF…")) { importPanel() }.keyboardShortcut("o")
                Button(L("新建笔记本")) { store.newNotebook() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(L("导出双语 PDF…")) { exportBilingual() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button(L("导出脑图为 Markdown…")) { exportMarkdown() }
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
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in for u in urls where u.pathExtension.lowercased() == "pdf" { _ = Store.shared.importPDF(u, open: true) } }
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
        if let d = try? JSONEncoder().encode(Store.shared.lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
    }
}

@MainActor func importPanel() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.pdf]
    p.allowsMultipleSelection = true
    if p.runModal() == .OK { for u in p.urls { _ = Store.shared.importPDF(u, open: true) } }
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

struct SettingsView: View {
    @State var key = Settings.apiKey
    @State var base = Settings.baseURL
    @State var lang = Settings.targetLang
    @State var models: [String] = []
    @State var loading = false
    @State var status = ""
    @State var tModel = ModelConfig.translateModel
    @State var tStyle = ModelConfig.style("translate")
    @State var cModel = ModelConfig.chatModel
    @State var cStyle = ModelConfig.style("chat")
    @State var ttsModel = ModelConfig.ttsModel
    @State var voice = Narrator.shared.voice
    @State var lookahead = Settings.lookahead
    @State var configExists = ConfigFile.exists
    @State var keyManaged = Settings.apiKeyManagedByFile
    @State var theme = AppTheme.current
    @ObservedObject var lc = LangCenter.shared

    @State private var settingsWindow: NSWindow?

    var body: some View {
        TabView {
            Form {
                Section(L("界面语言") + " / Interface Language") {
                    Picker(L("界面语言"), selection: Binding(get: { lc.lang }, set: { lc.set($0) })) { ForEach(UILang.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
                }
                Section(L("配置文件")) {
                    HStack {
                        Text(ConfigFile.displayPath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        if configExists {
                            Button(L("打开")) { NSWorkspace.shared.open(ConfigFile.url) }
                            Button(L("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([ConfigFile.url]) }
                        } else {
                            Button(L("创建配置文件")) {
                                save()
                                do { try ConfigFile.create(from: Settings.snapshot); configExists = true; status = L("✅ 已创建配置文件") }
                                catch { status = "❌ " + error.localizedDescription }
                            }
                        }
                    }
                    Text(configExists ? L("配置文件中的值优先于这里的设置；在这里保存会同步写回配置文件。API Key 不会写入文件。")
                                      : L("可选：用一个文本文件管理网关、模型和语音配置。未创建时使用这里的设置。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(L("网关")) {
                    if keyManaged {
                        LabeledContent("API Key", value: L("由配置文件提供"))
                    } else {
                        SecureField("API Key", text: $key)
                    }
                    TextField("Base URL", text: $base)
                    HStack {
                        Button(loading ? L("加载中…") : L("刷新可用模型")) { Task { await reload() } }.disabled(loading)
                        Text(models.isEmpty ? "" : LF("共 %d 个模型", models.count)).foregroundStyle(.secondary)
                    }
                }
                Section(L("翻译")) {
                    modelRow(L("模型"), $tModel, filter: { !$0.contains("tts") && !$0.contains("image") && !$0.contains("embedding") })
                    Picker(L("接口协议"), selection: $tStyle) { ForEach(APIStyle.allCases) { Text($0.name).tag($0) } }
                    Picker(L("翻译目标语言"), selection: $lang) { ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어"], id: \.self) { Text($0) } }
                    Stepper(LF("提前翻译 %d 页", lookahead), value: $lookahead, in: 0...10)
                }
                Section(L("AI 助手 / 解读 / 闪卡")) {
                    modelRow(L("模型"), $cModel, filter: { !$0.contains("tts") && !$0.contains("image") && !$0.contains("embedding") })
                    Picker(L("接口协议"), selection: $cStyle) { ForEach(APIStyle.allCases) { Text($0.name).tag($0) } }
                    Text(L("AI 解读会把页面截图发给模型，请选择支持图片输入的模型。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("语音（TTS）")) {
                    modelRow(L("TTS 模型"), $ttsModel, filter: { $0.contains("tts") })
                    Picker(L("音色"), selection: $voice) { ForEach(Narrator.voices, id: \.self) { Text(Narrator.voiceNames[$0] ?? $0).tag($0) } }
                }
                Section(L("PDF 打开方式")) {
                    HStack {
                        Text(isDefaultPDF ? L("Readit 已是默认 PDF 阅读器") : L("当前默认：") + defaultPDFAppName)
                        Spacer()
                        Button(isDefaultPDF ? L("已设为默认") : L("设为默认 PDF 工具")) { setDefaultPDF() }.disabled(isDefaultPDF)
                    }
                    Text(L("也可以在访达中右键任意 PDF →「打开方式」选择 Readit。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("外观")) {
                    Picker(L("主题"), selection: $theme) { ForEach(AppTheme.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
                }
                HStack {
                    Button(L("保存")) {
                        save(); status = L("✅ 已保存")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            settingsWindow?.close()
                        }
                    }.keyboardShortcut(.defaultAction)
                    Button(L("测试连接")) {
                        save(); status = L("测试中…")
                        Task {
                            do {
                                let t = try await Translator.translateOne("Attention is all you need. (test \(Int.random(in: 0...9999)))")
                                let c = try await LLMClient.complete(role: "chat", system: "Reply in one short sentence.", input: LLMInput(text: "Say hello in Chinese."), maxTokens: 60)
                                status = "✅ " + L("翻译：") + "\(t)  ✅ " + L("助手：") + "\(c.prefix(40))"
                            } catch { status = "❌ " + error.localizedDescription }
                        }
                    }
                    Text(status).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label(L("通用"), systemImage: "gearshape") }
        }
        .frame(width: 600, height: 640)
        .task { if models.isEmpty { await reload() } }
        .background(WindowFinder { settingsWindow = $0 })
    }

    @ViewBuilder func modelRow(_ label: String, _ v: Binding<String>, filter: @escaping (String) -> Bool) -> some View {
        let list = models.filter(filter)
        HStack {
            if list.isEmpty {
                TextField(label, text: v)
            } else {
                Picker(label, selection: v) {
                    if !list.contains(v.wrappedValue) { Text(v.wrappedValue).tag(v.wrappedValue) }
                    ForEach(list, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    @State var pdfStateTick = 0
    var defaultPDFURL: URL? { _ = pdfStateTick; return NSWorkspace.shared.urlForApplication(toOpen: .pdf) }
    var isDefaultPDF: Bool { defaultPDFURL?.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path }
    var defaultPDFAppName: String { defaultPDFURL.map { FileManager.default.displayName(atPath: $0.path) } ?? L("无") }
    func setDefaultPDF() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .pdf) { err in
            DispatchQueue.main.async { pdfStateTick += 1; status = err == nil ? L("✅ 已将 Readit 设为默认 PDF 工具") : "❌ " + (err?.localizedDescription ?? "") }
        }
    }

    func reload() async {
        if !keyManaged { Settings.apiKey = key }
        Settings.baseURL = base
        loading = true
        models = await LLMClient.listModels()
        loading = false
    }

    func save() {
        if !keyManaged { Settings.apiKey = key }
        Settings.baseURL = base; Settings.targetLang = lang
        ModelConfig.setModel("translate", tModel); ModelConfig.setStyle("translate", tStyle)
        ModelConfig.setModel("chat", cModel); ModelConfig.setStyle("chat", cStyle)
        ModelConfig.setModel("tts", ttsModel)
        Narrator.shared.voice = voice
        Settings.lookahead = lookahead
        ThemeCenter.shared.set(theme)
    }
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
