import SwiftUI
import PDFKit

// MARK: - model

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var created = Date()
    /// short label shown above a user bubble: "第 3 页摘要", "选中内容" …
    var badge: String? = nil
    /// quoted selection the question is about
    var quote: String? = nil
    var page: Int? = nil
    var failed = false
}

struct ChatThread: Codable {
    var messages: [ChatMessage] = []
    var pageSummaries: [Int: String] = [:]
    var docSummary: String? = nil
}

/// Persistence per document: ~/Library/Application Support/BiReader/docs/<id>/copilot.json
@MainActor
final class CopilotStore: ObservableObject {
    static let shared = CopilotStore()
    @Published private(set) var threads: [UUID: ChatThread] = [:]
    @Published var streaming: UUID?            // message id currently being streamed
    @Published var busyDocSummary = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func thread(_ docId: UUID) -> ChatThread {
        if let t = threads[docId] { return t }
        let url = Paths.docDir(docId).appendingPathComponent("copilot.json")
        let t = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ChatThread.self, from: $0) } ?? ChatThread()
        threads[docId] = t
        return t
    }

    private func update(_ docId: UUID, _ f: (inout ChatThread) -> Void) {
        var t = thread(docId)
        f(&t)
        threads[docId] = t
        let url = Paths.docDir(docId).appendingPathComponent("copilot.json")
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: url, options: .atomic) }
    }

    func record(docId: UUID, question: String, answer: String, page: Int) {
        update(docId) { t in
            t.messages.append(ChatMessage(role: .user, text: question, badge: "语音提问 · 第 \(page + 1) 页", page: page))
            t.messages.append(ChatMessage(role: .assistant, text: answer, page: page))
        }
    }

    func clear(_ docId: UUID) {
        stop()
        update(docId) { $0.messages = [] }
    }

    func stop() {
        for (_, t) in tasks { t.cancel() }
        tasks = [:]
        streaming = nil
    }

    // MARK: context building

    private func pageText(_ doc: PDFDocument, _ i: Int) -> String {
        (doc.safePage(i)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }

    private func documentText(_ doc: PDFDocument, limit: Int = 150_000) -> String {
        var out = ""
        for i in 0..<doc.pageCount {
            let t = pageText(doc, i)
            if out.count + t.count > limit { out += "\n[…后续页面因长度省略…]"; break }
            out += "\n\n=== 第 \(i + 1) 页 ===\n" + t
        }
        return out
    }

    private var lang: String { Settings.targetLang }

    // MARK: actions

    func summarizePage(docId: UUID, doc: PDFDocument, title: String, page: Int) {
        let text = pageText(doc, page)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let sys = "你是一名学术阅读助手。用\(lang)回答，Markdown 格式，简洁、信息密度高。"
        let prompt = """
        请总结《\(title)》第 \(page + 1) 页的内容：
        - 先用一句话概括本页核心；
        - 再列出 3–6 个要点（关键概念、方法、数据、结论），术语保留英文原文并给出\(lang)解释；
        - 如有公式或图表，说明其含义。

        本页原文：
        \(text)
        """
        ask(docId: docId, display: "总结第 \(page + 1) 页", badge: "本页摘要", quote: nil, page: page, system: sys, prompt: prompt, history: false) { [weak self] result in
            self?.update(docId) { $0.pageSummaries[page] = result }
        }
    }

    func summarizeDocument(docId: UUID, doc: PDFDocument, title: String) {
        let sys = "你是一名学术阅读助手。用\(lang)回答，Markdown 格式，结构清晰。"
        let prompt = """
        请为文档《\(title)》（共 \(doc.pageCount) 页）写一份导读：
        ## 一句话总结
        ## 研究问题与动机
        ## 核心方法 / 主要内容（分点）
        ## 关键结果与数据
        ## 贡献与局限
        ## 建议重点阅读的章节（标注页码）

        全文：
        \(documentText(doc))
        """
        busyDocSummary = true
        ask(docId: docId, display: "总结全文", badge: "全文导读", quote: nil, page: nil, system: sys, prompt: prompt, history: false) { [weak self] result in
            self?.update(docId) { $0.docSummary = result }
            self?.busyDocSummary = false
        }
    }

    func askAboutSelection(docId: UUID, doc: PDFDocument, title: String, page: Int, selection: String, question: String) {
        let q = question.isEmpty ? "请解释这段内容：含义、背景、关键术语，以及它在上下文中的作用。" : question
        let sys = "你是一名学术阅读助手。用\(lang)回答，Markdown 格式。结合上下文准确回答，不确定时明确说明。"
        let prompt = """
        文档《\(title)》第 \(page + 1) 页的上下文：
        \(pageText(doc, page))

        用户选中的内容：
        「\(selection)」

        问题：\(q)
        """
        ask(docId: docId, display: question.isEmpty ? "解释选中内容" : question, badge: "选中提问 · 第 \(page + 1) 页", quote: selection, page: page, system: sys, prompt: prompt, history: true)
    }

    func askFree(docId: UUID, doc: PDFDocument, title: String, page: Int, question: String) {
        let sys = """
        你是一名学术阅读助手，正在帮助用户阅读文档《\(title)》。用\(lang)回答，Markdown 格式。
        回答时引用页码（如「见第 5 页」）。只依据文档内容回答；文档没有的信息要说明。
        用户当前在第 \(page + 1) 页。

        文档全文：
        \(documentText(doc, limit: 120_000))
        """
        ask(docId: docId, display: question, badge: nil, quote: nil, page: page, system: sys, prompt: question, history: true)
    }

    func retry(docId: UUID, doc: PDFDocument, title: String, page: Int) {
        let msgs = thread(docId).messages
        guard let lastUser = msgs.last(where: { $0.role == .user }) else { return }
        update(docId) { t in while let l = t.messages.last, l.role == .assistant { t.messages.removeLast() }; if t.messages.last?.id == lastUser.id { t.messages.removeLast() } }
        if let q = lastUser.quote { askAboutSelection(docId: docId, doc: doc, title: title, page: lastUser.page ?? page, selection: q, question: lastUser.badge?.hasPrefix("选中") == true && lastUser.text == "解释选中内容" ? "" : lastUser.text) }
        else if lastUser.badge == "本页摘要" { summarizePage(docId: docId, doc: doc, title: title, page: lastUser.page ?? page) }
        else if lastUser.badge == "全文导读" { summarizeDocument(docId: docId, doc: doc, title: title) }
        else { askFree(docId: docId, doc: doc, title: title, page: page, question: lastUser.text) }
    }

    // MARK: streaming core

    private func ask(docId: UUID, display: String, badge: String?, quote: String?, page: Int?, system: String, prompt: String, history: Bool, onDone: ((String) -> Void)? = nil) {
        let userMsg = ChatMessage(role: .user, text: display, badge: badge, quote: quote, page: page)
        var reply = ChatMessage(role: .assistant, text: "", page: page)
        // conversation history (last 10 turns) for follow-ups
        var hist: [LLMClient.Msg] = []
        if history {
            for m in thread(docId).messages.suffix(10) where !m.failed && !m.text.isEmpty {
                hist.append(LLMClient.Msg(role: m.role.rawValue, text: m.text))
            }
        }
        update(docId) { $0.messages.append(userMsg); $0.messages.append(reply) }
        streaming = reply.id
        let rid = reply.id
        tasks[rid] = Task { [weak self] in
            do {
                for try await chunk in LLMClient.stream(role: "chat", system: system, input: LLMInput(text: prompt), history: hist) {
                    guard let self, !Task.isCancelled else { break }
                    reply.text += chunk
                    self.update(docId) { t in if let i = t.messages.firstIndex(where: { $0.id == rid }) { t.messages[i].text = reply.text } }
                }
                onDone?(reply.text)
            } catch {
                guard let self else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.update(docId) { t in if let i = t.messages.firstIndex(where: { $0.id == rid }) { t.messages[i].text += (t.messages[i].text.isEmpty ? "" : "\n\n") + "⚠️ " + msg; t.messages[i].failed = true } }
                if badge == "全文导读" { self.busyDocSummary = false }
            }
            self?.streaming = nil
            self?.tasks[rid] = nil
        }
    }
}

// MARK: - UI

struct CopilotPanel: View {
    @ObservedObject var store: Store
    @ObservedObject var cp = CopilotStore.shared
    @ObservedObject var rc: ReaderController
    @State private var input = ""
    @State private var quote: String? = nil
    @FocusState private var inputFocus: Bool
    @Binding var open: Bool

    var docId: UUID? { rc.docId }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let id = docId {
                let t = cp.thread(id)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if t.messages.isEmpty { welcome }
                            ForEach(t.messages) { m in
                                MessageView(message: m, streaming: cp.streaming == m.id, onJump: { p in rc.goToPage(p) })
                                    .id(m.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: t.messages.last?.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: t.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                quickActions
                composer
            } else {
                Spacer()
                Text(L("打开一个文档后即可使用 AI 助手")).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .background(panelBackgroundColor)
        .onAppear {
            #if os(iOS)
            if quote == nil, !rc.selectionText.isEmpty {
                quote = rc.selectionText
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .copilotAsk)) { n in
            guard (n.object as? UUID) == rc.docId else { return }
            if let s = n.userInfo?["quote"] as? String { quote = s; inputFocus = true }
        }
    }

    private var panelBackgroundColor: Color {
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return MN.panel
        #endif
    }

    private var cardBackgroundColor: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return MN.t.isDark ? Color(white: 0.22) : Color.white
        #endif
    }

    private var strokeBorderColor: Color {
        #if os(iOS)
        return Color(uiColor: .separator).opacity(0.45)
        #else
        return MN.t.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.1)
        #endif
    }

    var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(MN.accent)
            Text(L("AI 助手")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.primary)
            Spacer()
            if cp.streaming != nil {
                Button { cp.stop() } label: { Label(L("停止"), systemImage: "stop.circle") }.buttonStyle(.borderless).font(.system(size: 11))
            }
            Menu {
                Button(L("清空对话"), role: .destructive) { if let id = docId { cp.clear(id) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            #if os(macOS)
            Button { withAnimation(.easeInOut(duration: 0.2)) { open = false } } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help(L("收起 AI 助手"))
            #endif
        }
        .padding(.horizontal, 12).frame(height: 36)
    }

    var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("我可以帮你读懂这份文档")).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.primary)
            Text(L("· 总结当前页或整份文档\n· 在 PDF 中选中文字，点「问 AI」针对它提问\n· 直接问任何关于文档的问题，回答会标注页码\n\n所有对话都会保存在本文档中。"))
                .font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(MN.accent.opacity(0.08)))
    }

    var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(icon: "doc.text.magnifyingglass", text: LF("总结本页 (p.%d)", rc.currentPageIndex + 1)) { run { cp.summarizePage(docId: $0, doc: $1, title: $2, page: rc.currentPageIndex) } }
                Chip(icon: "books.vertical", text: cp.busyDocSummary ? L("全文导读生成中…") : L("总结全文")) { run { cp.summarizeDocument(docId: $0, doc: $1, title: $2) } }
                Chip(icon: "lightbulb", text: L("本页关键概念")) { run { d, doc, t in cp.askFree(docId: d, doc: doc, title: t, page: rc.currentPageIndex, question: "列出第 \(rc.currentPageIndex + 1) 页出现的关键概念与术语，并逐一用通俗语言解释。") } }
                Chip(icon: "rectangle.on.rectangle.angled", text: L("学习闪卡")) { NotificationCenter.default.post(name: .openFlashcards, object: rc.docId) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .disabled(cp.streaming != nil)
    }

    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = quote {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(MN.accent.opacity(0.6)).frame(width: 2.5)
                    Text(q).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    Button { quote = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(MN.accent.opacity(0.08)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(quote == nil ? L("问任何关于这份文档的问题…") : L("针对选中内容提问（留空则直接解释）"), text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1...6)
                    .focused($inputFocus)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        .foregroundStyle(canSend ? AnyShapeStyle(MN.accent) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(cardBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(inputFocus ? MN.accent.opacity(0.6) : strokeBorderColor, lineWidth: inputFocus ? 1.5 : 1))
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    var canSend: Bool { cp.streaming == nil && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || quote != nil) }

    func run(_ f: (UUID, PDFDocument, String) -> Void) {
        guard let id = docId, let s = store.session(id) else { return }
        f(id, s.original, s.doc.title)
    }

    func send() {
        guard canSend else { return }
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let sel = quote
        input = ""; quote = nil
        run { d, doc, t in
            if let sel { cp.askAboutSelection(docId: d, doc: doc, title: t, page: rc.currentPageIndex, selection: sel, question: q) }
            else { cp.askFree(docId: d, doc: doc, title: t, page: rc.currentPageIndex, question: q) }
        }
    }
}

struct Chip: View {
    let icon: String
    let text: String
    let action: () -> Void
    @State private var hover = false

    private var fillBg: Color {
        if hover { return MN.accent.opacity(0.14) }
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return MN.t.isDark ? Color(white: 0.22) : Color.white
        #endif
    }

    private var strokeColor: Color {
        #if os(iOS)
        return Color(uiColor: .separator).opacity(0.45)
        #else
        return MN.t.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.1)
        #endif
    }

    var body: some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(fillBg))
                .overlay(Capsule().stroke(strokeColor))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MessageView: View {
    let message: ChatMessage
    let streaming: Bool
    let onJump: (Int) -> Void
    @State private var hover = false

    private var assistantTextColor: Color {
        if message.failed { return .red }
        #if os(iOS)
        return Color(uiColor: .label)
        #else
        return MN.ink
        #endif
    }

    private var assistantBubbleBg: Color {
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color.clear
        #endif
    }

    var body: some View {
        if message.role == .user {
            VStack(alignment: .trailing, spacing: 4) {
                if let b = message.badge {
                    Text(L(b)).font(.system(size: 10, weight: .medium)).foregroundStyle(MN.accent)
                }
                if let q = message.quote {
                    Text("「\(q)」").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(4)
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(MN.accent.opacity(0.08)))
                }
                Text(message.text).font(.system(size: 13)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(MN.accent))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(MN.accent)
                    if streaming && message.text.isEmpty { TypingDots() }
                }
                if !message.text.isEmpty {
                    MarkdownText(message.text, onJump: onJump)
                        .foregroundStyle(assistantTextColor)
                }
                if !streaming && !message.text.isEmpty {
                    HStack(spacing: 10) {
                        Button { PlatformClipboard.copy(message.text) } label: { Label(L("复制"), systemImage: "doc.on.doc") }
                    }
                    .buttonStyle(.borderless).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(height: 16)
                    #if os(macOS)
                    .opacity(hover ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: hover)
                    .allowsHitTesting(hover)
                    #endif
                }
            }
            #if os(iOS)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(assistantBubbleBg))
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hover = $0 }
        }
    }
}

struct TypingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { i in
                Circle().fill(MN.accent.opacity(0.6)).frame(width: 5, height: 5)
                    .opacity(0.3 + 0.7 * max(0, sin(phase + Double(i) * 0.9)))
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 } }
    }
}

/// Lightweight Markdown renderer: headings, bullets, numbered lists, code blocks, inline **bold**/`code`,
/// and clickable "第 N 页" page references.
struct MarkdownText: View {
    let text: String
    let onJump: (Int) -> Void
    init(_ t: String, onJump: @escaping (Int) -> Void) { text = t; self.onJump = onJump }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks().enumerated()), id: \.offset) { _, b in b }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "page", let n = Int(url.host ?? "") { onJump(n - 1); return .handled }
            return .systemAction
        })
    }

    func inline(_ s: String) -> AttributedString {
        // **bold** is handled manually: CommonMark flanking rules break next to CJK punctuation
        var out = AttributedString()
        let parts = s.components(separatedBy: "**")
        for (i, part) in parts.enumerated() {
            let linked = part.replacingOccurrences(of: "第\\s*(\\d+)\\s*页", with: "[第 $1 页](page://$1)", options: .regularExpression)
            var a = (try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttStringFallback(part)
            if i % 2 == 1 && parts.count > 2 { a.inlinePresentationIntent = .stronglyEmphasized }
            out += a
        }
        return out
    }

    private func AttStringFallback(_ s: String) -> AttributedString {
        AttributedString(s)
    }

    func blocks() -> [AnyView] {
        var out: [AnyView] = []
        var code: [String]? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { out.append(AnyView(Text(c.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))))); code = nil }
                else { code = [] }
                continue
            }
            if code != nil { code!.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("#") {
                let level = t.prefix(while: { $0 == "#" }).count
                let s = t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append(AnyView(Text(inline(s)).font(.system(size: level <= 2 ? 14.5 : 13.5, weight: .semibold)).padding(.top, 4).textSelection(.enabled)))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                let indent = CGFloat(line.prefix(while: { $0 == " " }).count / 2) * 12
                out.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(MN.accent)
                    Text(inline(String(t.dropFirst(2)))).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.leading, indent)))
            } else if let r = t.range(of: "^\\d+[.)、]\\s*", options: .regularExpression) {
                let num = t[r].trimmingCharacters(in: .whitespaces)
                out.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(num).foregroundStyle(MN.accent).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    Text(inline(String(t[r.upperBound...]))).font(.system(size: 13)).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }))
            } else if t.hasPrefix(">") {
                out.append(AnyView(HStack(spacing: 6) { Rectangle().fill(MN.accent.opacity(0.4)).frame(width: 2.5); Text(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))).font(.system(size: 12.5)).foregroundStyle(.secondary) }))
            } else {
                out.append(AnyView(Text(inline(t)).font(.system(size: 13)).lineSpacing(2.5).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)))
            }
        }
        if let c = code { out.append(AnyView(Text(c.joined(separator: "\n")).font(.system(size: 11.5, design: .monospaced)))) }
        return out
    }
}

extension Notification.Name {
    static let copilotAsk = Notification.Name("copilotAsk")
    static let openFlashcards = Notification.Name("openFlashcards")
}
