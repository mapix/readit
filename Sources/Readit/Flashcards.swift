import SwiftUI
import PDFKit

struct Flashcard: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String          // 概念 / 理解 / 应用 / 数据
    var question: String
    var answer: String
    var explanation: String?
    var page: Int?            // 1-based page reference
    var status: Int = 0       // 0 new, 1 again, 2 known
}

struct FlashDeck: Codable {
    var title: String
    var scope: String         // "全文" / "第 3–5 页"
    var created = Date()
    var cards: [Flashcard]
}

@MainActor
final class FlashStore: ObservableObject {
    static let shared = FlashStore()
    @Published var decks: [UUID: [FlashDeck]] = [:]
    @Published var generating = false
    @Published var genError: String?

    private func url(_ docId: UUID) -> URL { Paths.docDir(docId).appendingPathComponent("flashcards.json") }

    func decks(_ docId: UUID) -> [FlashDeck] {
        if let d = decks[docId] { return d }
        let d = (try? Data(contentsOf: url(docId))).flatMap { try? JSONDecoder().decode([FlashDeck].self, from: $0) } ?? []
        decks[docId] = d
        return d
    }

    func save(_ docId: UUID, _ d: [FlashDeck]) {
        decks[docId] = d
        if let data = try? JSONEncoder().encode(d) { try? data.write(to: url(docId), options: .atomic) }
    }

    func setStatus(_ docId: UUID, deck: Int, card: UUID, status: Int) {
        var d = decks(docId)
        guard deck < d.count, let i = d[deck].cards.firstIndex(where: { $0.id == card }) else { return }
        d[deck].cards[i].status = status
        save(docId, d)
    }

    func deleteDeck(_ docId: UUID, _ i: Int) { var d = decks(docId); if i < d.count { d.remove(at: i); save(docId, d) } }

    func generate(docId: UUID, doc: PDFDocument, title: String, pages: ClosedRange<Int>?, count: Int) {
        generating = true; genError = nil
        guard doc.pageCount > 0 else { generating = false; return }
        let range = pages ?? 0...(doc.pageCount - 1)
        var text = ""
        for i in range {
            let t = (doc.safePage(i)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
            if text.count + t.count > 110_000 { break }
            text += "\n\n=== 第 \(i + 1) 页 ===\n" + t
        }
        let scope = pages == nil ? "全文" : (range.count == 1 ? "第 \(range.lowerBound + 1) 页" : "第 \(range.lowerBound + 1)–\(range.upperBound + 1) 页")
        let lang = Settings.targetLang
        Task {
            do {
                let sys = """
                你是一位出题专家，为学习者制作高质量的复习闪卡（类似 NotebookLM 的学习卡片）。用\(lang)。
                要求：覆盖最核心的概念、方法原理、关键结论与数据、易混淆点；问题具体、可回答，答案简洁准确（1–3 句），需要时给出一句解释；标注出处页码。
                题型 kind 取值：概念 / 理解 / 应用 / 数据。
                只输出 JSON：{"title":"卡组标题（≤16字）","cards":[{"kind":"概念","question":"…","answer":"…","explanation":"…","page":3}]}
                """
                let out = try await LLMClient.complete(role: "chat", system: sys, input: LLMInput(text: "文档《\(title)》（\(scope)），请生成 \(count) 张闪卡。\n\(text)"), maxTokens: 8000)
                var t = out
                if let r = t.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) { t = String(t[r]) }
                struct R: Decodable { var title: String?; var cards: [C] }
                struct C: Decodable { var kind: String?; var question: String; var answer: String; var explanation: String?; var page: Int? }
                guard let d = t.data(using: .utf8), let r = try? JSONDecoder().decode(R.self, from: d), !r.cards.isEmpty else { throw TranslateError.bad("闪卡生成结果无法解析，请重试") }
                let deck = FlashDeck(title: r.title ?? "\(title) · \(scope)", scope: scope,
                                     cards: r.cards.map { Flashcard(kind: $0.kind ?? "理解", question: $0.question, answer: $0.answer, explanation: $0.explanation, page: $0.page) })
                var all = decks(docId); all.insert(deck, at: 0); save(docId, all)
            } catch { genError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            generating = false
        }
    }
}

// MARK: - UI

struct FlashcardsView: View {
    @ObservedObject var store: Store
    @ObservedObject var fs = FlashStore.shared
    @ObservedObject var rc: ReaderController
    @Binding var open: Bool
    @State private var deckIndex: Int? = nil
    @State private var count = 12
    @State private var scope = 0     // 0 全文, 1 当前页附近

    var docId: UUID? { rc.docId }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { open = false }
            VStack(spacing: 0) {
                HStack {
                    if deckIndex != nil {
                        Button { withAnimation(.easeInOut(duration: 0.2)) { deckIndex = nil } } label: { Label(L("全部卡组"), systemImage: "chevron.left") }.buttonStyle(.borderless)
                    } else {
                        Label(L("学习闪卡"), systemImage: "rectangle.on.rectangle.angled").font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Button { open = false } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.tertiary) }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20).frame(height: 50)
                Divider()
                if let id = docId {
                    let ds = fs.decks(id)
                    if let di = deckIndex, di < ds.count { StudySession(docId: id, deckIndex: di, deck: ds[di]) }
                    else { deckList(id, ds) }
                }
            }
            .frame(width: 720, height: 560)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: NSColor(srgbRed: 0.975, green: 0.975, blue: 0.97, alpha: 1))))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        }
    }

    func deckList(_ id: UUID, _ ds: [FlashDeck]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // generator
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("生成新卡组")).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 14) {
                        Picker(L("范围"), selection: $scope) { Text(L("全文")).tag(0); Text(L("当前页 ±2 页")).tag(1) }.pickerStyle(.segmented).frame(width: 220)
                        Stepper(LF("数量 %d", count), value: $count, in: 5...30, step: 1).frame(width: 130)
                        Spacer()
                        Button {
                            guard let s = store.session(id) else { return }
                            let lo = max(0, min(rc.currentPageIndex - 2, s.pageCount - 1)), hi = max(lo, min(s.pageCount - 1, rc.currentPageIndex + 2))
                            let r: ClosedRange<Int>? = scope == 0 ? nil : lo...hi
                            fs.generate(docId: id, doc: s.original, title: s.doc.title, pages: r, count: count)
                        } label: {
                            HStack(spacing: 6) {
                                if fs.generating { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                                Text(fs.generating ? L("生成中…") : L("生成闪卡"))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain).disabled(fs.generating)
                    }
                    if let e = fs.genError { Text("⚠️ " + e).font(.caption).foregroundStyle(.red) }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.06)))

                if ds.isEmpty && !fs.generating {
                    Text(L("还没有卡组。生成后可以像翻卡片一样自测，标记「记住了 / 再看看」，进度会保存。"))
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 20).frame(maxWidth: .infinity)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(Array(ds.enumerated()), id: \.offset) { i, d in
                        let known = d.cards.filter { $0.status == 2 }.count
                        Button { withAnimation(.easeInOut(duration: 0.2)) { deckIndex = i } } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "rectangle.stack.fill").foregroundStyle(LinearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                                    Text(d.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                }
                                Text("\(L(d.scope)) · " + LF("%d 张", d.cards.count) + " · \(d.created.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
                                ProgressView(value: Double(known), total: Double(max(1, d.cards.count))).tint(.green)
                                Text(LF("已掌握 %d/%d", known, d.cards.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button(L("删除卡组"), role: .destructive) { fs.deleteDeck(id, i) } }
                    }
                }
            }
            .padding(20)
        }
    }
}

struct StudySession: View {
    let docId: UUID
    let deckIndex: Int
    let deck: FlashDeck
    @ObservedObject var fs = FlashStore.shared
    @State private var order: [UUID] = []
    @State private var pos = 0
    @State private var flipped = false
    @State private var onlyReview = false

    var cards: [Flashcard] { order.compactMap { id in deck.cards.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(deck.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(L("只看未掌握"), isOn: $onlyReview).toggleStyle(.switch).controlSize(.small).onChange(of: onlyReview) { _, _ in reset() }
                Button { order.shuffle(); pos = 0; flipped = false } label: { Image(systemName: "shuffle") }.buttonStyle(.borderless).help(L("打乱"))
            }
            if cards.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(.green)
                    Text(L("全部掌握了！")).font(.title3.weight(.semibold))
                    Button(L("重新学习全部")) { onlyReview = false; reset() }
                }
                Spacer()
            } else if pos >= cards.count {
                Spacer()
                let known = deck.cards.filter { $0.status == 2 }.count
                VStack(spacing: 12) {
                    Image(systemName: "flag.checkered").font(.system(size: 40)).foregroundStyle(.purple)
                    Text(L("本轮完成")).font(.title3.weight(.semibold))
                    Text(LF("已掌握 %d/%d", known, deck.cards.count)).foregroundStyle(.secondary)
                    HStack {
                        Button(L("复习未掌握")) { onlyReview = true; reset() }.buttonStyle(.borderedProminent).tint(.purple)
                        Button(L("再来一遍")) { reset() }
                    }
                }
                Spacer()
            } else {
                let c = cards[pos]
                HStack {
                    Text("\(pos + 1) / \(cards.count)").monospacedDigit().font(.system(size: 12)).foregroundStyle(.secondary)
                    ProgressView(value: Double(pos), total: Double(cards.count)).tint(.purple)
                }
                CardFace(card: c, flipped: flipped)
                    .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { flipped.toggle() } }
                    .id(c.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                HStack(spacing: 14) {
                    Button { go(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }.buttonStyle(.bordered).disabled(pos == 0).keyboardShortcut(.leftArrow, modifiers: [])
                    if flipped {
                        Button { mark(c, 1) } label: { Label(L("再看看"), systemImage: "arrow.counterclockwise").frame(width: 120) }
                            .buttonStyle(.bordered).tint(.orange).keyboardShortcut("1", modifiers: [])
                        Button { mark(c, 2) } label: { Label(L("记住了"), systemImage: "checkmark").frame(width: 120) }
                            .buttonStyle(.borderedProminent).tint(.green).keyboardShortcut("2", modifiers: [])
                    } else {
                        Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { flipped = true } } label: { Text(L("显示答案（空格）")).frame(width: 254) }
                            .buttonStyle(.borderedProminent).tint(.purple).keyboardShortcut(.space, modifiers: [])
                    }
                    Button { go(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }.buttonStyle(.bordered).keyboardShortcut(.rightArrow, modifiers: [])
                }
            }
        }
        .padding(24)
        .onAppear { reset() }
    }

    func reset() {
        order = deck.cards.filter { !onlyReview || $0.status != 2 }.map { $0.id }
        pos = 0; flipped = false
    }
    func go(_ d: Int) { withAnimation(.easeInOut(duration: 0.25)) { pos = max(0, min(cards.count, pos + d)); flipped = false } }
    func mark(_ c: Flashcard, _ s: Int) { fs.setStatus(docId, deck: deckIndex, card: c.id, status: s); go(1) }
}

struct CardFace: View {
    let card: Flashcard
    let flipped: Bool

    var kindColor: Color {
        switch card.kind { case "概念": return .blue; case "应用": return .orange; case "数据": return .teal; default: return .purple }
    }

    var body: some View {
        ZStack {
            face(front: true).opacity(flipped ? 0 : 1)
            face(front: false).opacity(flipped ? 1 : 0).rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func face(front: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(card.kind).font(.system(size: 11, weight: .semibold)).foregroundStyle(kindColor)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(kindColor.opacity(0.12)))
                if card.status == 2 { Label(L("已掌握"), systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green) }
                Spacer()
                if let p = card.page {
                    Button { DocWindows.shared.active?.reader.goToPage(p - 1) } label: { Label(LF("第 %d 页", p), systemImage: "doc.text") }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            Spacer()
            if front {
                Text(card.question).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center).frame(maxWidth: .infinity).lineSpacing(4)
                Spacer()
                Text(L("点击卡片翻面")).font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
            } else {
                Text(card.answer).font(.system(size: 18, weight: .medium)).multilineTextAlignment(.center).frame(maxWidth: .infinity).lineSpacing(4)
                if let e = card.explanation, !e.isEmpty {
                    Text(e).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).lineSpacing(3)
                }
                Spacer()
            }
        }
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 18).fill(front ? AnyShapeStyle(Color.white) : AnyShapeStyle(LinearGradient(colors: [Color.purple.opacity(0.06), Color.blue.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(kindColor.opacity(0.25), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

// MARK: - auto-generated document mind map

@MainActor
final class MapGenerator: ObservableObject {
    static let shared = MapGenerator()
    @Published var running: UUID?
    @Published var error: String?

    /// AI reads the document and builds a structured mind map under the notebook root.
    /// Key points become cards anchored to their page (with a highlight in the PDF), so they jump back like excerpts.
    func generate(docId: UUID) {
        let store = Store.shared
        guard running == nil, let s = store.session(docId) else { return }
        running = docId; error = nil
        let doc = s.original, title = s.doc.title
        var text = ""
        for i in 0..<doc.pageCount {
            let t = (doc.safePage(i)?.string ?? "").replacingOccurrences(of: "\n", with: " ")
            if text.count + t.count > 120_000 { text += "\n[…后续省略…]"; break }
            text += "\n\n=== 第 \(i + 1) 页 ===\n" + t
        }
        let lang = Settings.targetLang
        Task {
            do {
                let sys = """
                你是知识结构化专家。为文档生成一张层级清晰的思维导图（用\(lang)）。
                结构：根下 4–8 个一级主题（按文档的逻辑：问题/方法/实验/结论…），每个一级主题下 2–6 个要点，要点可再有 0–4 个子要点。
                每个节点 title 简短（≤20字）；需要时给 note（一句话解释）；能定位到原文的节点给 page（页码）和 quote（原文中逐字出现的 6–15 个连续单词，用于定位高亮）。
                只输出 JSON：{"title":"…","children":[{"title":"…","note":"…","page":3,"quote":"…","children":[…]}]}
                """
                let out = try await LLMClient.complete(role: "chat", system: sys, input: LLMInput(text: "文档《\(title)》：\n\(text)"), maxTokens: 16000)
                try? out.write(to: Paths.docDir(docId).appendingPathComponent("mindmap-raw.txt"), atomically: true, encoding: .utf8)
                var t = out
                if let r = t.range(of: "\\{[\\s\\S]*\\}", options: .regularExpression) { t = String(t[r]) }
                var root: GenNode?
                t = MapGenerator.repairJSON(t)
                if let d = t.data(using: .utf8) {
                    do { root = try JSONDecoder().decode(GenNode.self, from: d) } catch { print("MAPERR", error) }
                }
                guard let root else { throw TranslateError.bad("脑图结果无法解析，请重试") }
                self.insert(root, docId: docId, session: s)
            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            self.running = nil
        }
    }

    /// LLMs sometimes close the root object too early ("…]}]},{…") — re-open it so the remaining
    /// siblings stay inside the root's children, and balance any unclosed brackets at the end.
    static func repairJSON(_ input: String) -> String {
        var out: [Character] = []
        var stack: [Character] = []
        var inStr = false, esc = false
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inStr {
                out.append(ch)
                if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }
                i += 1; continue
            }
            if ch == "\"" { inStr = true; out.append(ch); i += 1; continue }
            if ch == "{" || ch == "[" { stack.append(ch); out.append(ch); i += 1; continue }
            if ch == "}" || ch == "]" {
                // closing the root while more content follows: skip this close and the one before it
                if stack.count <= 2, let next = chars[(i + 1)...].first(where: { !$0.isWhitespace }), next == "," || next == "]" {
                    if stack.count == 1 {
                        // undo the previous "]" that closed root.children
                        if let k = out.lastIndex(where: { $0 == "]" }) { out.remove(at: k); stack.append("[") }
                        i += 1; continue
                    }
                }
                if !stack.isEmpty { stack.removeLast() }
                out.append(ch); i += 1; continue
            }
            out.append(ch); i += 1
        }
        while let last = stack.popLast() { out.append(last == "{" ? "}" : "]") }
        return String(out)
    }

    struct GenNode: Decodable {
        var title: String; var note: String?; var page: Int?; var quote: String?; var children: [GenNode]?
        enum K: String, CodingKey { case title, note, page, quote, children }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            note = try? c.decode(String.self, forKey: .note)
            quote = try? c.decode(String.self, forKey: .quote)
            if let i = try? c.decode(Int.self, forKey: .page) { page = i } else if let s = try? c.decode(String.self, forKey: .page) { page = Int(s.filter { $0.isNumber }) } else { page = nil }
            children = try? c.decode([GenNode].self, forKey: .children)
        }
    }

    private func insert(_ g: GenNode, docId: UUID, session s: DocSession) {
        let store = Store.shared
        if let nb = store.lib.notebooks.first(where: { $0.docIds.contains(docId) }) { store.currentNotebookId = nb.id }
        func build(_ n: GenNode) -> MindNode {
            var node = MindNode(title: n.title)
            if let p = n.page, p >= 1, p <= s.pageCount, let q = n.quote?.trimmingCharacters(in: .whitespaces), q.count >= 4,
               let page = s.original.safePage(p - 1),
               let sel = s.original.findString(q, withOptions: [.caseInsensitive]).first(where: { $0.pages.contains(page) }) ?? s.original.findString(String(q.prefix(12)), withOptions: [.caseInsensitive]).first(where: { $0.pages.contains(page) }) {
                if (sel.string ?? "").count < q.count { sel.extendForLineBoundaries() }
                let rects = sel.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 }
                var c = Card(docId: docId, page: p - 1, variant: .original, rects: rects, text: sel.string ?? q, color: 2)
                if let note = n.note { c.comments = [note] }
                store.lib.cards.append(c)
                s.refreshAnnotations(for: c)
                node.cardId = c.id
            } else if let note = n.note, !note.isEmpty, n.children?.isEmpty ?? true {
                node.title = n.title + "：" + note
            }
            node.children = (n.children ?? []).map(build)
            node.collapsed = false
            return node
        }
        var top = build(g)
        top.title = "🗺 " + (g.title.isEmpty ? (store.doc(docId)?.title ?? "文档") : g.title)
        store.updateNotebook { nb in nb.root.children.append(top) }
        store.selectedNodeId = top.id
        store.mapFocusRequest = top.id
        store.save()
    }
}
