#if os(macOS)
import SwiftUI
import AppKit

/// Desktop widget: hides every BiReader window and leaves a floating, always-on-top player on the desktop
/// (draggable). Two sizes — compact (music-player style) and transcript (segment list) — and ⤢ restores the
/// real PDF window.
@MainActor
final class MiniWidget: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MiniWidget()
    @Published var active = false
    @Published var showTranscript = UserDefaults.standard.bool(forKey: "widgetTranscript") {
        didSet { UserDefaults.standard.set(showTranscript, forKey: "widgetTranscript"); resize(animated: true) }
    }
    private var panel: NSPanel?
    private var hidden: [NSWindow] = []
    /// document shown in the widget (the window that was frontmost when collapsing)
    @Published var docId: UUID?

    static let compactSize = NSSize(width: 356, height: 162)
    static let transcriptSize = NSSize(width: 356, height: 450)

    /// windows that were in native fullscreen when collapsing (re-entered on expand)
    private var wasFullScreen: Set<ObjectIdentifier> = []

    func collapse() {
        guard !active else { return }
        active = true
        docId = DocWindows.shared.activeDocId ?? Narrator.shared.docId
        let candidates = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        let fs = candidates.filter { $0.styleMask.contains(.fullScreen) }
        wasFullScreen = Set(fs.map { ObjectIdentifier($0) })
        guard !fs.isEmpty else { finishCollapse(); return }
        // A fullscreen window lives on its own Space; hiding it there leaves the widget on an empty black
        // fullscreen Space. Leave fullscreen first, then hide once every window is back on the desktop.
        var pending = fs.count
        var observers: [NSObjectProtocol] = []
        var done = false
        let finish = { [weak self] in
            guard !done else { return }
            done = true
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            // let the Space-switch animation settle before ordering the panel in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.finishCollapse() }
        }
        for w in fs {
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { _ in
                pending -= 1
                if pending <= 0 { MainActor.assumeIsolated { finish() } }
            })
            w.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }   // safety net
    }

    private func finishCollapse() {
        guard active else { return }
        let p = panel ?? makePanel()
        panel = p
        resize(animated: false)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        if let s = UserDefaults.standard.string(forKey: "widgetOrigin") {
            p.setFrameOrigin(NSPointFromString(s))
        } else if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 24, y: vf.maxY - p.frame.height - 24))
        }
        // hide all app windows (library + every PDF window), keep only the widget on the desktop
        hidden = NSApp.windows.filter { $0.isVisible && $0 !== p && !($0 is NSPanel) }
        for w in hidden { NSAnimationContext.runAnimationGroup { c in c.duration = 0.16; w.animator().alphaValue = 0 } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard self.active else { return }
            for w in self.hidden { w.orderOut(nil); w.alphaValue = 1 }
            p.alphaValue = 0
            p.orderFrontRegardless()     // canJoinAllSpaces: appears on the Space the user is looking at
            NSAnimationContext.runAnimationGroup { c in c.duration = 0.18; p.animator().alphaValue = 1 }
        }
    }

    /// restore: bring back the document window (and whatever else was open)
    func expand() {
        guard active else { return }
        active = false
        panel?.orderOut(nil)
        // the panel is non-activating, so the app is usually inactive here: activate before ordering windows
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateAllWindows]) }
        let restore = hidden
        hidden = []
        let fsIds = wasFullScreen
        wasFullScreen = []
        for w in restore {
            w.alphaValue = 1
            w.orderFront(nil)
        }
        // focus the widget's document (re-creates the window if it was closed meanwhile)
        let docWin: NSWindow?
        if let id = docId, Store.shared.doc(id) != nil {
            DocWindows.shared.open(id)
            docWin = DocWindows.shared.entries[id]?.window
        } else {
            docWin = restore.first(where: { $0.canBecomeKey })
        }
        docWin?.makeKeyAndOrderFront(nil)
        for w in restore where fsIds.contains(ObjectIdentifier(w)) && !w.styleMask.contains(.fullScreen) && w.isVisible {
            w.toggleFullScreen(nil)
        }
        // activation can land a beat late when coming from a non-activating panel; re-assert focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !NSApp.isActive { NSRunningApplication.current.activate(options: [.activateAllWindows]) }
            if let w = docWin, w.isVisible, !w.isKeyWindow { w.makeKeyAndOrderFront(nil) }
        }
    }

    private func resize(animated: Bool) {
        guard let p = panel else { return }
        let s = showTranscript ? MiniWidget.transcriptSize : MiniWidget.compactSize
        var f = p.frame
        f.origin.y += f.height - s.height      // grow downward from the top edge
        f.size = s
        p.setFrame(f, display: true, animate: animated)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: MiniWidget.compactSize),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.delegate = self
        let host = NSHostingView(rootView: WidgetView().environment(\.colorScheme, .light))
        host.sizingOptions = []
        host.frame = p.contentView?.bounds ?? NSRect(origin: .zero, size: MiniWidget.compactSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    func windowDidMove(_ n: Notification) {
        guard let p = panel else { return }
        // remember the top-left corner so both sizes stay anchored where the user put it
        let topLeft = NSPoint(x: p.frame.minX, y: p.frame.maxY - (showTranscript ? MiniWidget.transcriptSize.height : MiniWidget.compactSize.height))
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: "widgetOrigin")
    }
}

struct WidgetView: View {
    @ObservedObject var lang = LangCenter.shared
    @ObservedObject var store = Store.shared
    @ObservedObject var n = Narrator.shared
    @ObservedObject var w = MiniWidget.shared
    @ObservedObject var wins = DocWindows.shared
    @State private var hover = false

    var docId: UUID? { w.docId }
    var reader: ReaderController? { docId.flatMap { wins.entries[$0]?.reader } }
    var narrating: Bool { n.state != .idle && n.docId == docId }

    var body: some View {
        VStack(spacing: 0) {
            nowPlaying
            if w.showTranscript { Divider().opacity(0.5); transcript }
        }
        .background(
            ZStack {
                VisualEffect()
                LinearGradient(colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 0.8))
        .onHover { hover = $0 }
    }

    // MARK: compact "now playing"
    var nowPlaying: some View {
        VStack(spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if let id = docId { Thumb(docId: id).frame(width: 44, height: 58).clipShape(RoundedRectangle(cornerRadius: 6)) }
                    else { RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2)).frame(width: 44, height: 58) }
                    if narrating {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(3).background(Circle().fill(Color.purple)).offset(x: 4, y: 4)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(docId.flatMap { store.doc($0)?.title } ?? "Readlet")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    if narrating, n.segIndex < n.segments.count, !w.showTranscript {
                        Text(n.segments[n.segIndex].text).font(.system(size: 10.5)).foregroundStyle(Color(white: 0.3)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                VStack(spacing: 10) {
                    Button { w.expand() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).help(L("展开 PDF 窗口"))
                    Button { w.showTranscript.toggle() } label: { Image(systemName: w.showTranscript ? "chevron.up" : "text.alignleft").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).help(w.showTranscript ? L("收起讲稿") : L("显示每段讲稿"))
                }
                .foregroundStyle(.secondary)
            }
            // progress
            VStack(spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.08))
                        Capsule().fill(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * progress))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(narrating ? LF("第 %d/%d 段", n.segIndex + 1, max(1, n.segments.count)) : LF("第 %d 页", currentPage + 1)).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let eta = narrating ? (n.remainingSeconds().map { Narrator.formatRemaining($0) + " · " } ?? "") : ""
                        Text(eta + "\(Int(progress * 100))%").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            // transport: centered prev / play / next, with mic button aligned right
            ZStack {
                HStack(spacing: 28) {
                    Button { narrating ? n.previous() : reader?.goToPage(currentPage - 1) } label: {
                        Image(systemName: "backward.fill").font(.system(size: 15))
                    }
                    Button { togglePlay() } label: {
                        Image(systemName: narrating && n.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                    }
                    .disabled(n.state == .preparing && narrating)
                    Button { narrating ? n.next() : reader?.goToPage(currentPage + 1) } label: {
                        Image(systemName: "forward.fill").font(.system(size: 15))
                    }
                }
                if narrating {
                    HStack {
                        Spacer()
                        MicButton().scaleEffect(0.84).frame(width: 28, height: 28)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(white: 0.2))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(height: MiniWidget.compactSize.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { w.expand() }
    }

    // MARK: transcript (each segment, current highlighted)
    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if !narrating {
                        Text(L("开始 AI 解读后，这里会逐段显示讲稿。")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                    }
                    if let qa = n.lastQA, narrating {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("「\(qa.q)」").font(.system(size: 11.5, weight: .medium))
                            Text(qa.a).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(4)
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))
                    }
                    ForEach(Array(n.segments.enumerated()), id: \.offset) { i, s in
                        let cur = i == n.segIndex
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                .foregroundStyle(cur ? .white : .secondary)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(cur ? Color.purple : Color.black.opacity(0.06)))
                            Text(s.text).font(.system(size: 12, weight: cur ? .medium : .regular)).lineSpacing(2.5)
                                .foregroundStyle(cur ? Color(white: 0.08) : (i < n.segIndex ? Color(white: 0.55) : Color(white: 0.32)))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, cur ? 6 : 0).padding(.horizontal, cur ? 6 : 0)
                        .background(RoundedRectangle(cornerRadius: 8).fill(cur ? Color.white.opacity(0.7) : .clear))
                        .id(i)
                        .contentShape(Rectangle())
                        .onTapGesture { n.jumpToSegment(i) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .onChange(of: n.segIndex) { _, i in withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(i, anchor: .center) } }
            .onAppear { proxy.scrollTo(n.segIndex, anchor: .center) }
        }
    }

    var currentPage: Int { narrating ? n.page : (reader?.currentPageIndex ?? 0) }
    var progress: Double {
        if narrating { return n.progress }
        let c = docId.flatMap { store.sessions[$0]?.pageCount } ?? 1
        return Double(currentPage + 1) / Double(max(1, c))
    }
    var subtitle: String {
        let total = docId.flatMap { store.sessions[$0]?.pageCount } ?? 0
        if narrating {
            switch n.state {
            case .preparing: return LF("AI 解读 · 第 %d/%d 页 · 准备中…", n.page + 1, total)
            case .paused: return LF("AI 解读 · 第 %d/%d 页 · 已暂停", n.page + 1, total)
            default: return LF("AI 解读 · 第 %d/%d 页", n.page + 1, total)
            }
        }
        return LF("第 %d / %d 页", currentPage + 1, total) + " · " + (reader?.variant == .bilingual ? L("双语") : L("原文"))
    }

    func togglePlay() {
        if narrating { n.togglePause(); return }
        guard let id = docId, let s = store.session(id) else { return }
        n.start(docId: id, doc: s.document(reader?.variant ?? .original), title: s.doc.title, from: reader?.currentPageIndex ?? 0)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
#endif
