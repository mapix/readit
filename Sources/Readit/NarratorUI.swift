import SwiftUI

/// Where the floating narration player docks inside the reader.
enum NarratorDock: String, CaseIterable, Identifiable {
    case topLeft, topCenter, topRight, middleLeft, middleRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: return L("左上"); case .topCenter: return L("顶部居中"); case .topRight: return L("右上")
        case .middleLeft: return L("左侧居中"); case .middleRight: return L("右侧居中")
        case .bottomLeft: return L("左下"); case .bottomCenter: return L("底部居中"); case .bottomRight: return L("右下")
        }
    }
    var icon: String {
        switch self {
        case .topLeft: return "arrow.up.left"; case .topCenter: return "arrow.up"; case .topRight: return "arrow.up.right"
        case .middleLeft: return "arrow.left"; case .middleRight: return "arrow.right"
        case .bottomLeft: return "arrow.down.left"; case .bottomCenter: return "arrow.down"; case .bottomRight: return "arrow.down.right"
        }
    }
    var alignment: Alignment {
        switch self {
        case .topLeft: return .topLeading; case .topCenter: return .top; case .topRight: return .topTrailing
        case .middleLeft: return .leading; case .middleRight: return .trailing
        case .bottomLeft: return .bottomLeading; case .bottomCenter: return .bottom; case .bottomRight: return .bottomTrailing
        }
    }
    var isTop: Bool { [.topLeft, .topCenter, .topRight].contains(self) }
    var isBottom: Bool { [.bottomLeft, .bottomCenter, .bottomRight].contains(self) }
    var edge: Edge { isTop ? .top : (isBottom ? .bottom : (self == .middleLeft ? .leading : .trailing)) }
}

/// 3x3-grid menu to dock the player at one of 8 positions.
struct DockPicker: View {
    @AppStorage("narratorDock") private var dockRaw = NarratorDock.bottomCenter.rawValue
    var body: some View {
        let cur = NarratorDock(rawValue: dockRaw) ?? .bottomCenter
        Menu {
            ForEach(NarratorDock.allCases) { d in
                Button { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { dockRaw = d.rawValue } } label: {
                    if d == cur { Label(d.title, systemImage: "checkmark") } else { Label(d.title, systemImage: d.icon) }
                }
            }
        } label: { Image(systemName: "square.grid.3x3") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("位置"))
    }
}

/// Floating player shown over the reader while AI 解读 is active.
struct NarratorBar: View {
    @ObservedObject var n = Narrator.shared
    @ObservedObject var ex = NarrationExporter.shared
    @AppStorage("narrShowScript") private var showScript = true
    @AppStorage("narrMini") private var mini = false
    @AppStorage("narratorDock") private var dockRaw = NarratorDock.bottomCenter.rawValue

    var body: some View {
        Group { if mini { pill } else { full } }
            .background(GeometryReader { g in Color.clear
                .onAppear { setInsets(g.size.height) }
                .onChange(of: g.size.height) { _, h in setInsets(h) }
                .onChange(of: dockRaw) { _, _ in setInsets(g.size.height) }
                .onDisappear { Narrator.reader.bottomInset = 0; Narrator.reader.topInset = 0 } })
    }

    /// Tell the reader which vertical band the player covers so narration centring avoids it.
    private func setInsets(_ h: CGFloat) {
        let d = NarratorDock(rawValue: dockRaw) ?? .bottomCenter
        Narrator.reader.bottomInset = d.isBottom ? h + 30 : 0
        Narrator.reader.topInset = d.isTop ? h + 30 : 0
    }

    /// minimized: a compact pill with progress ring, play/pause and expand
    var pill: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.08), lineWidth: 2.5)
                Circle().trim(from: 0, to: n.progress).stroke(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "waveform").font(.system(size: 9, weight: .bold)).foregroundStyle(.purple)
            }
            .frame(width: 22, height: 22)
            if n.recording { RecDot(on: true).help(L("录制中")) }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let eta = n.remainingSeconds().map { " · " + Narrator.formatRemainingShort($0) } ?? ""
                Text("p.\(n.page + 1) · \(n.segIndex + 1)/\(max(1, n.segments.count))" + eta).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
            }
            .help(n.remainingSeconds().map { Narrator.formatRemaining($0) } ?? "")
            Button { n.togglePause() } label: { Image(systemName: n.state == .playing ? "pause.fill" : "play.fill") }.buttonStyle(.plain).disabled(n.state == .preparing)
            Button { n.next() } label: { Image(systemName: "forward.fill") }.buttonStyle(.plain)
            MicButton().scaleEffect(0.8)
            DockPicker()
            Button { withAnimation(.spring(response: 0.3)) { mini = false } } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help(L("展开"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.purple.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    var full: some View {
        VStack(spacing: 0) {
            if showScript, !n.segments.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(n.segments.enumerated()), id: \.offset) { i, s in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(i == n.segIndex ? .white : .secondary)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(i == n.segIndex ? Color.purple : Color.black.opacity(0.06)))
                                    Text(s.text).font(.system(size: 13)).lineSpacing(3)
                                        .foregroundStyle(i == n.segIndex ? Color(white: 0.08) : (i < n.segIndex ? Color(white: 0.55) : Color(white: 0.35)))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { jumpSeg(i) }
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 170)
                    .onChange(of: n.segIndex) { _, i in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(i, anchor: .center) } }
                }
                Divider()
            }
            if n.listening || n.answering || n.lastQA != nil {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: n.listening ? "mic.fill" : "bubble.left.and.text.bubble.right")
                        .foregroundStyle(n.listening ? .red : .purple)
                        .symbolEffect(.pulse, isActive: n.listening)
                    VStack(alignment: .leading, spacing: 3) {
                        if n.listening { Text(n.heard.isEmpty ? L("正在聆听…松开即提问") : n.heard).font(.system(size: 13, weight: .medium)) }
                        else if n.answering { Text("「\(n.heard)」").font(.system(size: 12.5, weight: .medium)); Text(L("思考中…")).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                        else if let qa = n.lastQA {
                            Text("「\(qa.q)」").font(.system(size: 12.5, weight: .medium))
                            Text(qa.a).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                        }
                    }
                    Spacer()
                    if !n.listening && !n.answering { Button { n.lastQA = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).foregroundStyle(.tertiary) }
                }
                .padding(12)
                .background(n.listening ? Color.red.opacity(0.06) : Color.purple.opacity(0.05))
                Divider()
            }
            if ex.phase != .idle { exportRow; Divider() }
            // row 1: status (left) · transport (centre) · close (right)
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.black.opacity(0.08), lineWidth: 3)
                    Circle().trim(from: 0, to: n.progress).stroke(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LF("AI 解读 · 第 %d / %d 页", n.page + 1, n.pageCount)).font(.system(size: 12, weight: .semibold)).monospacedDigit().lineLimit(1)
                    Group {
                        if let e = n.error { Text("⚠️ " + e).foregroundStyle(.red) }
                        else if n.state == .preparing { Text(n.segments.isEmpty ? L("正在阅读本页并组织讲解…") : L("正在生成语音…")) }
                        else {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                let eta = n.remainingSeconds().map { " · " + Narrator.formatRemaining($0) } ?? ""
                                Text(LF("第 %d/%d 段 · 全文 %d%%", n.segIndex + 1, max(1, n.segments.count), Int(n.progress * 100)) + eta + " · " + LF("已缓冲 %d 段", n.buffered))
                            }
                        }
                    }
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    Button { n.previous() } label: { Image(systemName: "backward.fill") }.help(L("上一段"))
                    Button { n.togglePause() } label: {
                        Image(systemName: n.state == .playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 30))
                            .foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                    }
                    .disabled(n.state == .preparing).help(L("播放 / 暂停（空格）"))
                    Button { n.next() } label: { Image(systemName: "forward.fill") }.help(L("下一段"))
                    MicButton()
                }
                .buttonStyle(.plain).font(.system(size: 14))
                .fixedSize()
                Spacer(minLength: 8)
                Button { n.stop(); Narrator.reader.clearNarrationHighlight() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.tertiary) }.buttonStyle(.plain).help(L("退出 AI 解读"))
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            // row 2: resume info + secondary controls
            HStack(spacing: 14) {
                if n.fallbackToSystem {
                    Label(L("网关 TTS 不可用，已改用系统语音"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).lineLimit(1).help(n.fallbackReason)
                }
                if let r = n.resumedFrom {
                    Button { n.restartFromCurrentPage() } label: {
                        Label("已从第 \(r.page + 1) 页第 \(r.seg + 1) 段继续 · 从当前页重新开始", systemImage: "arrow.counterclockwise")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(.purple).help(L("从当前页重新开始"))
                }
                Spacer(minLength: 6)
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0] as [Float], id: \.self) { r in
                        Button { n.rate = r } label: { if n.rate == r { Label(rateText(r), systemImage: "checkmark") } else { Text(rateText(r)) } }
                    }
                } label: { Label(rateText(n.rate), systemImage: "speedometer").monospacedDigit() }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("语速"))
                Menu {
                    ForEach(n.voiceOptions) { o in
                        Button { n.selectVoice(o.id) } label: { if n.currentVoiceID == o.id { Label(o.label, systemImage: "checkmark") } else { Text(o.label) } }
                    }
                    Divider()
                    Picker(L("语音引擎"), selection: Binding(get: { n.provider }, set: { n.provider = $0 })) {
                        Text(L("系统语音")).tag(TTSProvider.system)
                        Text(L("网关 TTS")).tag(TTSProvider.gateway)
                    }
                } label: { Label(n.currentVoiceName, systemImage: n.effectiveProvider == .system ? "person.wave.2" : "cloud") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("音色"))
                recordToggle
                Menu {
                    Button(L("导出 MP4（第 1 页到最后一页完整一遍）")) { ex.start() }.disabled(ex.running)
                    if ex.running { Button(L("取消导出")) { ex.cancel() } }
                    if let u = ex.outputURL { Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
                } label: { Label("MP4", systemImage: "film") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L("导出 MP4"))
                Divider().frame(height: 14)
                DockPicker()
                Button { showScript.toggle() } label: { Image(systemName: showScript ? "text.bubble.fill" : "text.bubble") }.buttonStyle(.plain).help(L("显示讲稿"))
                Button { withAnimation(.spring(response: 0.3)) { mini = true } } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }.buttonStyle(.plain).help(L("最小化"))
                Button { MiniWidget.shared.collapse() } label: { Image(systemName: "pip.enter") }.buttonStyle(.plain).help(L("收到桌面小组件（隐藏窗口）"))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Color(white: 0.3))
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    var recordToggle: some View {
        Button { n.recording.toggle() } label: {
            HStack(spacing: 3) {
                RecDot(on: n.recording)
                Text(n.recording ? "REC" : L("录制")).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(n.recording ? Color.red.opacity(0.12) : Color.clear))
            .overlay(Capsule().stroke(Color.red.opacity(n.recording ? 0.5 : 0.2)))
            .foregroundStyle(n.recording ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(n.recording ? LF("录制中（已播放 %d 段）。导出时会从第一页到最后一页完整合成一遍", n.recorded.count) : L("开启录制"))
    }

    var exportRow: some View {
        HStack(spacing: 8) {
            Image(systemName: ex.phase == .failed ? "exclamationmark.triangle" : (ex.phase == .done ? "checkmark.circle.fill" : "film"))
                .foregroundStyle(ex.phase == .failed ? .red : .purple)
            Text(ex.statusText).font(.system(size: 11.5)).monospacedDigit().lineLimit(1)
            if ex.running, ex.total > 0 { ProgressView(value: Double(ex.done), total: Double(ex.total)).frame(width: 120) }
            else if ex.running { ProgressView().controlSize(.small) }
            Spacer()
            if ex.running { Button(L("取消")) { ex.cancel() }.font(.system(size: 11)) }
            else {
                if let u = ex.outputURL, ex.phase == .done { Button(L("显示")) { NSWorkspace.shared.activateFileViewerSelecting([u]) }.font(.system(size: 11)) }
                Button { ex.phase = .idle } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.purple.opacity(0.05))
    }

    func rateText(_ r: Float) -> String { r == 1 ? "1×" : String(format: "%g×", r) }
    func jumpSeg(_ i: Int) { n.jumpToSegment(i) }
}


/// Hold to ask (push-to-talk). Also Ctrl+Space while narrating.
struct MicButton: View {
    @ObservedObject var n = Narrator.shared
    @State private var pressing = false
    var body: some View {
        Image(systemName: n.listening ? "mic.fill" : "mic")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(n.listening ? Color.white : Color.purple)
            .frame(width: 30, height: 30)
            .background(Circle().fill(n.listening ? Color.red : Color.purple.opacity(0.12)))
            .scaleEffect(n.listening ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: n.listening)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressing { pressing = true; n.beginQuestion() } }
                .onEnded { _ in pressing = false; n.endQuestion() })
            .help(L("按住提问（或按住 ⌃空格），松开发送；讲解会自动暂停，回答后继续"))
    }
}


/// red record dot; pulses while recording (implicit repeatForever animation, cheap)
struct RecDot: View {
    var on: Bool
    @State private var dim = false
    var body: some View {
        Circle().fill(on ? Color.red : Color.red.opacity(0.35))
            .frame(width: 8, height: 8)
            .opacity(on && dim ? 0.2 : 1)
            .shadow(color: on && !dim ? .red.opacity(0.7) : .clear, radius: 3)
            .onAppear { if on { startBlink() } }
            .onChange(of: on) { _, v in if v { startBlink() } else { withAnimation(.easeOut(duration: 0.15)) { dim = false } } }
    }
    private func startBlink() {
        dim = false
        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
    }
}
