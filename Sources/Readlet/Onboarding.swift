#if os(macOS)
import SwiftUI
import AppKit

/// First-launch 3-step configuration wizard (also reachable anytime via toolbar / Help → Welcome & Setup Guide…).
struct OnboardingView: View {
    enum Choice: String { case chatgpt, gateway, local, skip }
    @ObservedObject var gpt = ChatGPTAuth.shared
    @ObservedObject var lc = LangCenter.shared
    @ObservedObject var tc = ThemeCenter.shared

    @State private var step = 0
    @State private var choice: Choice = AppInfo.chatGPTAvailable ? .chatgpt : .gateway
    @State private var targetLang = Settings.targetLang
    @State private var base = Settings.baseURL
    @State private var key = Settings.apiKey
    @State private var style: APIStyle = ModelConfig.style("chat") == .chatgpt ? .anthropic : ModelConfig.style("chat")
    @State private var model = ModelConfig.chatModel
    @State private var localBase = "http://localhost:11434"
    @State private var localModels: [String] = []
    @State private var narrStyle = Settings.narrationStyle
    @State private var ttsProvider = Narrator.shared.provider
    @State private var sysVoice = Narrator.shared.systemVoice
    @State private var testing = false
    @State private var previewingVoice = false
    @State private var status = ""
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 12) {
                if let img = NSApp.applicationIconImage {
                    Image(nsImage: img).resizable().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("欢迎使用 Readlet")).font(.title2.weight(.bold))
                    Text(L("一步步完成语言、AI 模型与语音讲解配置（随时可在设置中修改）"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Step indicator bar
            HStack(spacing: 8) {
                stepPill(0, icon: "globe", title: L("1. 语言与外观"))
                stepPill(1, icon: "sparkles", title: L("2. AI 模型配置"))
                stepPill(2, icon: "waveform", title: L("3. 语音讲解与开始"))
            }
            .padding(.vertical, 2)

            Divider()

            // Step content
            Group {
                if step == 0 {
                    stepLanguageAndTheme
                } else if step == 1 {
                    stepAIModel
                } else {
                    stepVoiceAndQuickStart
                }
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(status.hasPrefix("❌") ? .red : .secondary).lineLimit(2)
            }

            Divider()

            // Footer navigation
            HStack {
                Button(L("以后再说")) {
                    UserDefaults.standard.set(true, forKey: "onboarded")
                    UserDefaults.standard.set(true, forKey: "onboardedV2")
                    close()
                }
                if step > 0 {
                    Button(L("上一步")) { withAnimation(.easeInOut(duration: 0.18)) { step -= 1; status = "" } }
                }
                Spacer()
                if step < 2 {
                    if step == 1 && (choice == .gateway || choice == .local) {
                        Button(testing ? L("测试中…") : L("测试连接")) {
                            testCurrentAI()
                        }.disabled(testing || (choice == .gateway && key.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                    Button(L("下一步")) {
                        saveStep(step)
                        withAnimation(.easeInOut(duration: 0.18)) { step += 1; status = "" }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(testing ? L("测试中…") : L("保存并开始")) {
                        applyAllAndFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testing)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 590)
        .id(lc.lang)
    }

    private func stepPill(_ idx: Int, icon: String, title: String) -> some View {
        let active = step == idx
        let done = step > idx
        return Button {
            saveStep(step)
            withAnimation(.easeInOut(duration: 0.18)) { step = idx; status = "" }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(active ? .white : (done ? .green : .secondary))
                Text(title).font(.system(size: 12.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? .white : .primary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 0: Language & Appearance

    private var stepLanguageAndTheme: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("界面语言") + " / Interface Language", systemImage: "globe")
                    .font(.callout.weight(.semibold))
                Picker(L("界面语言"), selection: Binding(get: { lc.lang }, set: { lc.set($0) })) {
                    ForEach(UILang.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(L("翻译目标语言"), systemImage: "character.book.closed")
                    .font(.callout.weight(.semibold))
                Text(L("切换到「双语」视图或划词翻译时，原文会翻译为该语言："))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(L("翻译目标语言"), selection: $targetLang) {
                    ForEach(["简体中文", "繁體中文", "English", "日本語", "한국어"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: targetLang) { _, v in Settings.targetLang = v }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(L("阅读主题"), systemImage: "paintpalette")
                    .font(.callout.weight(.semibold))
                HStack(spacing: 12) {
                    ForEach(AppTheme.allCases) { t in
                        Button {
                            tc.set(t)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(themeColor(t))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                                Text(t.name).font(.callout.weight(tc.theme == t ? .semibold : .regular))
                                Spacer()
                                if tc.theme == t {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(tc.theme == t ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .frame(height: 64)
                .overlay(
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill").font(.title3).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("书架标签与阅读进度")).font(.callout.weight(.semibold))
                            Text(L("书架支持 TODO / DOING / DONE 状态标签、自定义分类过滤与比例统计，并实时显示每篇文档的阅读百分比。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                )
        }
    }

    private func themeColor(_ t: AppTheme) -> Color {
        switch t {
        case .light: return .white
        case .sepia: return Color(nsColor: NSColor(srgbRed: 0.95, green: 0.89, blue: 0.76, alpha: 1))
        case .dark: return Color(nsColor: NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1))
        }
    }

    // MARK: - Step 1: AI Model Setup

    private var stepAIModel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("双语对照、AI 讲解、摘录脑图。先选一下 AI 从哪里来（随时可以在设置里改）："))
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 6) {
                if AppInfo.chatGPTAvailable {
                    option(.chatgpt, icon: "person.crop.circle.badge.checkmark", title: L("用 ChatGPT 账号"), sub: L("Plus / Pro 套餐额度，不需要 API Key"))
                }
                option(.gateway, icon: "key.fill", title: L("用自己的模型网关"), sub: L("Anthropic、OpenAI、DeepSeek 或兼容接口，填地址和 Key"))
                option(.local, icon: "desktopcomputer", title: L("用本机模型"), sub: L("Ollama、LM Studio 等，完全离线"))
                option(.skip, icon: "book.fill", title: L("先不用 AI"), sub: L("只用阅读、摘录、PDF 编辑和脑图；以后再配置"))
            }

            detail

            if choice != .skip {
                Text(L("使用 AI 功能时，相关页面的文字和截图会发送给你选择的 AI 服务；Readlet 本身不收集任何数据。继续即表示同意。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    func option(_ c: Choice, icon: String, title: String, sub: String) -> some View {
        Button { choice = c; status = "" } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 16)).frame(width: 24).foregroundStyle(choice == c ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: choice == c ? "checkmark.circle.fill" : "circle").foregroundStyle(choice == c ? Color.accentColor : .secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(choice == c ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    @ViewBuilder var detail: some View {
        switch choice {
        case .chatgpt:
            HStack {
                if gpt.connected {
                    Label(LF("已连接：%@", gpt.accountLabel), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button { gpt.signIn() } label: { Label(gpt.phase == .signingIn ? L("等待浏览器授权…") : "Continue with ChatGPT", systemImage: "person.crop.circle") }
                        .buttonStyle(.borderedProminent).tint(.black).disabled(gpt.phase == .signingIn)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            if !gpt.message.isEmpty { Text(gpt.message).font(.caption).foregroundStyle(.secondary) }
        case .gateway:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(L("常用预设：")).font(.caption).foregroundStyle(.secondary)
                    presetBtn("Anthropic", url: "https://api.anthropic.com", proto: .anthropic, defaultModel: "claude-sonnet-4-5-20250929")
                    presetBtn("OpenAI", url: "https://api.openai.com", proto: .chat, defaultModel: "gpt-4o-mini")
                    presetBtn("DeepSeek", url: "https://api.deepseek.com", proto: .chat, defaultModel: "deepseek-chat")
                    presetBtn("OpenRouter", url: "https://openrouter.ai/api", proto: .chat, defaultModel: "google/gemini-2.5-flash")
                }
                VStack(spacing: 0) {
                    formRow("Base URL") {
                        TextField("https://api.anthropic.com", text: $base)
                            .textFieldStyle(.roundedBorder)
                    }
                    Divider().padding(.horizontal, 12)
                    formRow("API Key") {
                        SecureField("sk-...", text: $key)
                            .textFieldStyle(.roundedBorder)
                    }
                    Divider().padding(.horizontal, 12)
                    formRow(L("接口协议")) {
                        Picker("", selection: $style) {
                            ForEach(APIStyle.available.filter { $0 != .chatgpt }) { Text($0.name).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                    }
                    Divider().padding(.horizontal, 12)
                    formRow(L("模型")) {
                        TextField("claude-sonnet-4-5-20250929", text: $model)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
        case .local:
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    formRow(L("服务")) {
                        Picker("", selection: $localBase) {
                            Text("Ollama · localhost:11434").tag("http://localhost:11434")
                            Text("LM Studio · localhost:1234").tag("http://localhost:1234")
                        }
                        .labelsHidden()
                    }
                    Divider().padding(.horizontal, 12)
                    formRow(L("模型")) {
                        HStack(spacing: 8) {
                            if localModels.isEmpty {
                                TextField("qwen3:8b", text: $model)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                Picker("", selection: $model) {
                                    ForEach(localModels, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                            }
                            Button(L("刷新")) { Task { await loadLocal() } }
                                .controlSize(.small)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))

                Text(L("AI 解读需要能看图的模型（如 qwen2.5-vl、llava、gemma3）。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task { await loadLocal() }
        case .skip:
            Text(L("所有阅读、双语（需要模型时会提示）、摘录、PDF 截断编辑、标签与脑图功能都可以直接使用。"))
                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(width: 110, alignment: .leading)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func presetBtn(_ name: String, url: String, proto: APIStyle, defaultModel: String) -> some View {
        Button(name) {
            base = url
            style = proto
            model = defaultModel
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Step 2: Voice Narration & Quick Start

    private var stepVoiceAndQuickStart: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("AI 逐页语音解读"), systemImage: "waveform.circle.fill")
                    .font(.callout.weight(.semibold))

                VStack(spacing: 0) {
                    formRow(L("讲解风格")) {
                        Picker("", selection: $narrStyle) {
                            ForEach(NarrationStyle.allCases) { st in
                                Text(L(st.title) + " — " + L(st.subtitle)).tag(st)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: narrStyle) { _, v in Settings.narrationStyle = v }
                    }
                    Divider().padding(.horizontal, 12)
                    formRow(L("语音引擎")) {
                        Picker("", selection: $ttsProvider) {
                            ForEach(TTSProvider.allCases) { Text(L($0.title)).tag($0) }
                        }
                        .labelsHidden()
                        .onChange(of: ttsProvider) { _, v in Narrator.shared.provider = v }
                    }
                    if ttsProvider == .system {
                        Divider().padding(.horizontal, 12)
                        formRow(L("音色")) {
                            HStack(spacing: 8) {
                                Picker("", selection: $sysVoice) {
                                    Text(L("自动（按目标语言）")).tag("")
                                    ForEach(SystemTTS.options(for: targetLang)) { Text($0.label).tag($0.id) }
                                }
                                .labelsHidden()
                                .onChange(of: sysVoice) { _, v in Narrator.shared.systemVoice = v }

                                Button(previewingVoice ? L("合成中…") : L("试听")) {
                                    previewingVoice = true
                                    Task {
                                        do {
                                            try await Narrator.shared.previewVoice()
                                            status = "✅ " + L("语音试听成功")
                                        } catch {
                                            status = "❌ " + error.localizedDescription
                                        }
                                        previewingVoice = false
                                    }
                                }
                                .controlSize(.small)
                                .disabled(previewingVoice)
                            }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(L("核心功能速览"), systemImage: "lightbulb.fill").font(.callout.weight(.semibold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 5) {
                    tipRow("doc.viewfinder", L("双语对照与 AI 讲解：按 ⌘2 切换原版排版双语视图，按 ⌘⇧L 开启逐页语音解读。"))
                    tipRow("scissors", L("PDF 截断与编辑：导入网页或文档后，在页面任意位置右键即可「从此处开始截断后面」或擦除多余内容。"))
                    tipRow("tag", L("标签分类与进度：支持 TODO / DOING / DONE 标签过滤、比例统计条，书架实时展示每本书的阅读百分比。"))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        }
    }

    private func tipRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.accentColor).frame(width: 16, height: 16)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    func loadLocal() async {
        Settings.baseURL = localBase
        if Settings.apiKey.isEmpty { Settings.apiKey = "local" }
        let m = await LLMClient.listModels()
        localModels = m
        if let f = m.first, !m.contains(model) { model = f }
        status = m.isEmpty ? L("没有连上本机模型服务，请确认它已经启动。") : LF("找到 %d 个本机模型", m.count)
    }

    func saveStep(_ s: Int) {
        Settings.targetLang = targetLang
        Settings.narrationStyle = narrStyle
        Narrator.shared.provider = ttsProvider
        Narrator.shared.systemVoice = sysVoice
        if s == 1 {
            saveAIConfig()
        }
    }

    func saveAIConfig() {
        switch choice {
        case .chatgpt:
            ModelConfig.setStyle("translate", .chatgpt); ModelConfig.setStyle("chat", .chatgpt)
            if let first = gpt.models.first?.slug { ModelConfig.setModel("translate", first); ModelConfig.setModel("chat", first) }
        case .gateway:
            AIConsent.grant()
            Settings.baseURL = base.isEmpty ? "https://api.anthropic.com" : base
            Settings.apiKey = key
            ModelConfig.setStyle("translate", style); ModelConfig.setStyle("chat", style)
            if !model.isEmpty { ModelConfig.setModel("translate", model); ModelConfig.setModel("chat", model) }
        case .local:
            AIConsent.grant()
            Settings.baseURL = localBase
            if Settings.apiKey.isEmpty { Settings.apiKey = "local" }
            ModelConfig.setStyle("translate", .chat); ModelConfig.setStyle("chat", .chat)
            if !model.isEmpty { ModelConfig.setModel("translate", model); ModelConfig.setModel("chat", model) }
        case .skip:
            break
        }
    }

    func testCurrentAI() {
        saveAIConfig()
        testing = true
        status = L("测试中…")
        Task {
            do {
                _ = try await LLMClient.complete(role: "chat", system: "Reply with one word.", input: LLMInput(text: "ping"), maxTokens: 20)
                testing = false
                status = "✅ " + L("连接成功！")
            } catch {
                testing = false
                status = "❌ " + error.localizedDescription
            }
        }
    }

    func applyAllAndFinish() {
        saveStep(0)
        saveAIConfig()
        finish()
    }

    func finish() {
        if choice != .skip { AIConsent.grant() }
        UserDefaults.standard.set(true, forKey: "onboarded")
        UserDefaults.standard.set(true, forKey: "onboardedV2")
        close()
    }
}

@MainActor
enum OnboardingPanel {
    private static var panel: NSPanel?
    /// first launch configuration guide
    static func showIfNeeded() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        guard env["BIREADER_SCRIPT"] == nil, env["READLET_SKIP_ONBOARDING"] == nil else { return }
        guard !d.bool(forKey: "onboardedV2") else { return }
        show()
    }
    static func show() {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 590, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: OnboardingView(close: { close() }))
        p.center(); p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
    static func close() { panel?.close(); panel = nil }
}

// MARK: - keyboard shortcuts (⌘/)

struct ShortcutsView: View {
    static let groups: [(String, [(String, String)])] = [
        ("文档", [("⌘O", "导入 PDF 或文档…"), ("⇧⌘O", "从网页导入…"), ("⇧⌘N", "新建笔记本"), ("⇧⌘E", "导出双语 PDF…"), ("⌘F", "在文档中查找…"), ("⌘G / ⇧⌘G", "查找下一个 / 上一个"), ("⌘Z / ⇧⌘Z", "撤销 / 重做")]),
        ("阅读", [("⌘1 / ⌘2", "原文 / 双语"), ("⌘D", "摘录选中内容为卡片"), ("⌘T", "翻译选中文本"), ("⌘= / ⌘- / ⌘0", "放大 / 缩小 / 适合宽度")]),
        ("AI", [("⌘J", "AI 助手"), ("⇧⌘L", "AI 解读"), ("⇧⌘K", "学习闪卡"), ("⇧⌘M", "收到桌面小组件"), ("空格", "播放 / 暂停讲解"), ("⌃空格（按住）", "语音提问")]),
        ("脑图", [("Tab", "添加子主题"), ("Return", "添加同级主题"), ("空格", "编辑标题"), ("⌘↑ ⌘↓", "调整顺序"), ("⌘← ⌘→", "调整层级"), ("Delete", "删除主题")]),
    ]
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("键盘快捷键")).font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 28) {
                ForEach(0..<2, id: \.self) { col in
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(ShortcutsView.groups.enumerated()).filter { $0.offset % 2 == col }, id: \.offset) { _, g in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L(g.0)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(Array(g.1.enumerated()), id: \.offset) { _, kv in
                                    HStack {
                                        Text(kv.0).font(.system(size: 12, design: .monospaced)).frame(width: 118, alignment: .leading)
                                        Text(L(kv.1)).font(.system(size: 12.5))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack { Spacer(); Button(L("好")) { close() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 600)
    }
}

@MainActor
enum ShortcutsPanel {
    private static var panel: NSPanel?
    static func show() {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ShortcutsView(close: { panel?.close(); panel = nil }))
        p.center(); p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
#endif
