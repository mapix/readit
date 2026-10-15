import SwiftUI
import AppKit

/// First-run guide: pick where AI comes from (ChatGPT plan / own gateway / local model / skip), then a few tips.
struct OnboardingView: View {
    @ObservedObject var gpt = ChatGPTAuth.shared
    var close: () -> Void
    enum Choice: Hashable { case chatgpt, gateway, local, skip }
    @State private var choice: Choice = AppInfo.chatGPTAvailable ? .chatgpt : .gateway
    @State private var base = Settings.baseURL == "https://api.anthropic.com" ? "" : Settings.baseURL
    @State private var key = ""
    @State private var style: APIStyle = .anthropic
    @State private var model = ModelConfig.chatModel
    @State private var localBase = "http://localhost:11434"
    @State private var localModels: [String] = []
    @State private var status = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("欢迎使用 Readlet")).font(.title2.weight(.semibold))
                    Text(L("双语对照、AI 讲解、摘录脑图。先选一下 AI 从哪里来（随时可以在设置里改）：")).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                if AppInfo.chatGPTAvailable { option(.chatgpt, "person.crop.circle.badge.checkmark", L("用 ChatGPT 账号"), L("Plus / Pro 套餐额度，不需要 API Key")) }
                option(.gateway, "server.rack", L("用自己的模型网关"), L("Anthropic、OpenAI 或兼容接口，填地址和 Key"))
                option(.local, "desktopcomputer", L("用本机模型"), L("Ollama、LM Studio 等，完全离线"))
                option(.skip, "book", L("先不用 AI"), L("只用阅读、摘录和脑图；以后再配置"))
            }
            detail.frame(minHeight: 96, alignment: .top)
            VStack(alignment: .leading, spacing: 4) {
                Text(L("小贴士")).font(.callout.weight(.semibold))
                Text(L("⌘O 导入 PDF / EPUB / Markdown / Word · ⌘⇧O 从网页导入 · ⌘2 双语对照 · ⌘⇧L AI 讲解 · ⌘/ 全部快捷键"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("语音讲解默认使用 macOS 系统声音，不需要另外配置。")).font(.caption).foregroundStyle(.secondary)
                Text(L("使用 AI 功能时，相关页面的文字和截图会发送给你选择的 AI 服务；Readlet 本身不收集任何数据。继续即表示同意。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(L("以后再说")) { finish() }
                Button(choice == .skip ? L("开始使用") : L("保存并开始")) { apply() }
                    .keyboardShortcut(.defaultAction).disabled(testing || (choice == .chatgpt && !gpt.connected))
            }
        }
        .padding(22)
        .frame(width: 560)
    }

    func option(_ c: Choice, _ icon: String, _ title: String, _ sub: String) -> some View {
        Button { choice = c } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: choice == c ? "checkmark.circle.fill" : "circle").foregroundStyle(choice == c ? Color.accentColor : .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(choice == c ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06)))
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
            if !gpt.message.isEmpty { Text(gpt.message).font(.caption).foregroundStyle(.secondary) }
        case .gateway:
            Form {
                TextField("Base URL", text: $base, prompt: Text("https://api.anthropic.com"))
                SecureField("API Key", text: $key)
                Picker(L("接口协议"), selection: $style) { ForEach(APIStyle.available.filter { $0 != .chatgpt }) { Text($0.name).tag($0) } }
                TextField(L("模型"), text: $model)
            }.formStyle(.grouped).frame(height: 190)
        case .local:
            Form {
                Picker(L("服务"), selection: $localBase) {
                    Text("Ollama · localhost:11434").tag("http://localhost:11434")
                    Text("LM Studio · localhost:1234").tag("http://localhost:1234")
                }
                HStack {
                    if localModels.isEmpty { TextField(L("模型"), text: $model, prompt: Text("qwen3:8b")) }
                    else { Picker(L("模型"), selection: $model) { ForEach(localModels, id: \.self) { Text($0).tag($0) } } }
                    Button(L("刷新")) { Task { await loadLocal() } }
                }
                Text(L("AI 解读需要能看图的模型（如 qwen2.5-vl、llava、gemma3）。")).font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped).frame(height: 160)
            .task { await loadLocal() }
        case .skip:
            Text(L("所有阅读、双语（需要模型时会提示）、摘录、脑图功能都可以直接使用。")).font(.callout).foregroundStyle(.secondary)
        }
    }

    func loadLocal() async {
        Settings.baseURL = localBase
        if Settings.apiKey.isEmpty { Settings.apiKey = "local" }
        let m = await LLMClient.listModels()
        localModels = m
        if let f = m.first, !m.contains(model) { model = f }
        status = m.isEmpty ? L("没有连上本机模型服务，请确认它已经启动。") : LF("找到 %d 个本机模型", m.count)
    }

    func apply() {
        switch choice {
        case .chatgpt:
            ModelConfig.setStyle("translate", .chatgpt); ModelConfig.setStyle("chat", .chatgpt)
            if let first = gpt.models.first?.slug { ModelConfig.setModel("translate", first); ModelConfig.setModel("chat", first) }
            finish()
        case .gateway, .local:
            AIConsent.grant()          // the notice above was shown; don't ask again for the connection test
            if choice == .gateway {
                Settings.baseURL = base.isEmpty ? "https://api.anthropic.com" : base
                Settings.apiKey = key
                ModelConfig.setStyle("translate", style); ModelConfig.setStyle("chat", style)
            } else {
                Settings.baseURL = localBase
                if Settings.apiKey.isEmpty { Settings.apiKey = "local" }
                ModelConfig.setStyle("translate", .chat); ModelConfig.setStyle("chat", .chat)
            }
            if !model.isEmpty { ModelConfig.setModel("translate", model); ModelConfig.setModel("chat", model) }
            testing = true; status = L("测试中…")
            Task {
                do {
                    _ = try await LLMClient.complete(role: "chat", system: "Reply with one word.", input: LLMInput(text: "ping"), maxTokens: 20)
                    testing = false; finish()
                } catch {
                    testing = false
                    status = "❌ " + error.localizedDescription + " — " + L("可以先开始，稍后在设置里修改")
                }
            }
        case .skip:
            finish()
        }
    }

    func finish() {
        if choice != .skip { AIConsent.grant() }
        UserDefaults.standard.set(true, forKey: "onboarded")
        close()
    }
}

@MainActor
enum OnboardingPanel {
    private static var panel: NSPanel?
    /// first launch with nothing configured
    static func showIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "onboarded"), ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] == nil else { return }
        if !Settings.apiKey.isEmpty || ChatGPTAuth.shared.connected { d.set(true, forKey: "onboarded"); return }
        show()
    }
    static func show() {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
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
