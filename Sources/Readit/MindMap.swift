import SwiftUI
import UniformTypeIdentifiers

struct LaidNode: Identifiable {
    let id: UUID
    let node: MindNode
    let depth: Int
    var frame: CGRect
    let parent: UUID?
}

@MainActor enum MindLayout {
    static let hGap: CGFloat = 44, vGap: CGFloat = 12, maxW: CGFloat = 240

    static func textHeight(_ s: String, _ font: NSFont, _ w: CGFloat, maxH: CGFloat) -> CGFloat {
        min(maxH, ceil((s as NSString).boundingRect(with: CGSize(width: w, height: 2000), options: [.usesLineFragmentOrigin], attributes: [.font: font]).height))
    }

    static func size(_ n: MindNode, store: Store, depth: Int) -> CGSize {
        let card = store.card(n.cardId)
        let titleFont = NSFont.systemFont(ofSize: depth == 0 ? 15 : 13, weight: .semibold)
        let w = maxW - 20
        var h: CGFloat = 14
        var natural: CGFloat = 0
        if !n.title.isEmpty || card == nil {
            let t = store.nodeTitle(n)
            h += textHeight(t, titleFont, w, maxH: 70)
            natural = max(natural, (t as NSString).size(withAttributes: [.font: titleFont]).width)
        }
        if let c = card {
            if !n.title.isEmpty { h += 4 }
            if c.isImage, let img = NSImage(contentsOf: Paths.cardImage(c.id)) {
                let iw = min(w, img.size.width / 3)
                h += min(140, iw * img.size.height / max(1, img.size.width)) + 4
                natural = max(natural, iw)
            }
            if !c.text.isEmpty {
                let f = NSFont.systemFont(ofSize: 12.5)
                h += textHeight(String(c.text.prefix(260)), f, w, maxH: 92)
                natural = max(natural, (String(c.text.prefix(80)) as NSString).size(withAttributes: [.font: f]).width)
            }
            if let t = c.translation, !t.isEmpty {
                let f = NSFont.systemFont(ofSize: 11.5)
                h += 3 + textHeight(String(t.prefix(140)), f, w, maxH: 48)
                natural = max(natural, min(w, (String(t.prefix(60)) as NSString).size(withAttributes: [.font: f]).width))
            }
            for cm in c.comments.prefix(3) { h += 3 + textHeight(cm, NSFont.systemFont(ofSize: 11.5), w - 14, maxH: 34) }
        }
        return CGSize(width: min(maxW, max(90, ceil(natural) + 26)), height: h)
    }

    private static var cacheKey: Int = 0
    private static var cacheVal: [LaidNode] = []
    static func layout(_ root: MindNode, store: Store) -> [LaidNode] {
        var h = Hasher()
        h.combine(root)
        for id in root.allCardIds() { if let c = store.card(id) { h.combine(c.text); h.combine(c.translation); h.combine(c.comments); h.combine(c.color) } }
        let k = h.finalize()
        if k == cacheKey { return cacheVal }
        let v = layoutUncached(root, store: store)
        cacheKey = k; cacheVal = v
        return v
    }
    static func layoutUncached(_ root: MindNode, store: Store) -> [LaidNode] {
        var out: [LaidNode] = []
        var sizes: [UUID: CGSize] = [:]
        var subtreeH: [UUID: CGFloat] = [:]
        var colW: [Int: CGFloat] = [:]
        func measure(_ n: MindNode, _ d: Int) -> CGFloat {
            let s = size(n, store: store, depth: d)
            sizes[n.id] = s
            colW[d] = max(colW[d] ?? 0, s.width)
            var ch: CGFloat = 0
            if !n.collapsed && !n.children.isEmpty {
                ch = n.children.map { measure($0, d + 1) }.reduce(0, +) + vGap * CGFloat(n.children.count - 1)
            }
            let h = max(s.height, ch)
            subtreeH[n.id] = h
            return h
        }
        _ = measure(root, 0)
        func x(_ d: Int) -> CGFloat { (0..<d).reduce(CGFloat(30)) { $0 + (colW[$1] ?? 0) + hGap } }
        func place(_ n: MindNode, _ d: Int, _ top: CGFloat, _ parent: UUID?) {
            let s = sizes[n.id]!, h = subtreeH[n.id]!
            out.append(LaidNode(id: n.id, node: n, depth: d, frame: CGRect(x: x(d), y: top + (h - s.height) / 2, width: s.width, height: s.height), parent: parent))
            guard !n.collapsed else { return }
            let ch = n.children.map { subtreeH[$0.id]! }.reduce(0, +) + vGap * CGFloat(max(0, n.children.count - 1))
            var y = top + (h - ch) / 2
            for c in n.children { place(c, d + 1, y, n.id); y += subtreeH[c.id]! + vGap }
        }
        place(root, 0, 30, nil)
        return out
    }
}

struct MindMapView: View {
    @ObservedObject var store: Store
    @State private var scale: CGFloat = 1
    @State private var dropTarget: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        if let nb = store.currentNotebook {
            let laid = MindLayout.layout(nb.root, store: store)
            let byId = Dictionary(uniqueKeysWithValues: laid.map { ($0.id, $0) })
            let W = (laid.map { $0.frame.maxX }.max() ?? 300) + 80
            let H = (laid.map { $0.frame.maxY }.max() ?? 300) + 80
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { ctx, _ in
                            for n in laid {
                                guard let pid = n.parent, let p = byId[pid] else { continue }
                                let a = CGPoint(x: p.frame.maxX, y: p.frame.midY), b = CGPoint(x: n.frame.minX, y: n.frame.midY)
                                var path = Path(); path.move(to: a)
                                let mx = (a.x + b.x) / 2
                                path.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
                                ctx.stroke(path, with: .color(Color(white: 0.62)), lineWidth: 1.3)
                            }
                            for l in store.lib.links {
                                guard let na = laid.first(where: { $0.node.cardId == l.a }), let nb2 = laid.first(where: { $0.node.cardId == l.b }) else { continue }
                                var path = Path(); path.move(to: CGPoint(x: na.frame.midX, y: na.frame.maxY))
                                path.addQuadCurve(to: CGPoint(x: nb2.frame.midX, y: nb2.frame.minY), control: CGPoint(x: (na.frame.midX + nb2.frame.midX) / 2 + 50, y: (na.frame.maxY + nb2.frame.minY) / 2))
                                ctx.stroke(path, with: .color(Color.blue.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                            }
                        }
                        .frame(width: W, height: H)
                        ForEach(laid) { n in
                            NodeView(store: store, laid: n, isDrop: dropTarget == n.id)
                                .frame(width: n.frame.width, height: n.frame.height)
                                .position(x: n.frame.midX, y: n.frame.midY)
                                .id(n.id)
                                .onDrop(of: [.text], isTargeted: Binding(get: { dropTarget == n.id }, set: { dropTarget = $0 ? n.id : (dropTarget == n.id ? nil : dropTarget) })) { providers in
                                    handleDrop(providers, onto: n.id)
                                }
                        }
                    }
                    .frame(width: W, height: H)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: W * scale, height: H * scale, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectedNodeId = nil; store.editingNodeId = nil; focused = true }
                }
                .onChange(of: store.mapFocusRequest) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                    store.mapFocusRequest = nil
                }
            }
            .background(MN.mapBG)
            .overlay(alignment: .bottomTrailing) { controls(nb) }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in handleKey(press) }
        } else {
            Text(L("没有笔记本")).foregroundStyle(.secondary)
        }
    }

    func controls(_ nb: Notebook) -> some View {
        HStack(spacing: 10) {
            GenMapButton()
            Divider().frame(height: 12)
            Button { store.addChild(to: store.selectedNodeId ?? nb.root.id) } label: { Image(systemName: "plus.rectangle.on.rectangle") }.help(L("添加子主题 (Tab)")).accessibilityLabel(L("添加子主题 (Tab)"))
            Button { scale = max(0.4, scale / 1.15) } label: { Image(systemName: "minus") }
            Text("\(Int(scale * 100))%").monospacedDigit().font(.system(size: 11)).frame(width: 36).onTapGesture { scale = 1 }
            Button { scale = min(2.5, scale * 1.15) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.black.opacity(0.08)))
        .padding(12)
    }

    func handleDrop(_ providers: [NSItemProvider], onto target: UUID) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String else { return }
            DispatchQueue.main.async {
                if s.hasPrefix("node:"), let id = UUID(uuidString: String(s.dropFirst(5))) { store.moveNode(id, under: target) }
                else if s.hasPrefix("card:"), let id = UUID(uuidString: String(s.dropFirst(5))) { store.attachCard(id, under: target) }
                dropTarget = nil
            }
        }
        return true
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard store.editingNodeId == nil, let sel = store.selectedNodeId, let nb = store.currentNotebook else { return .ignored }
        switch press.key {
        case .tab: store.addChild(to: sel); return .handled
        case .return: if sel == nb.root.id { store.addChild(to: sel) } else { store.addSibling(of: sel) }; return .handled
        case .delete, .deleteForward: store.deleteNode(sel); return .handled
        case .space: store.editingNodeId = sel; return .handled
        case .upArrow:
            if press.modifiers.contains(.command) { store.shift(sel, by: -1) } else { moveSel(sel, nb, dy: -1) }
            return .handled
        case .downArrow:
            if press.modifiers.contains(.command) { store.shift(sel, by: 1) } else { moveSel(sel, nb, dy: 1) }
            return .handled
        case .leftArrow:
            if press.modifiers.contains(.command) { store.outdent(sel) } else if let p = nb.root.parentOf(sel) { store.selectedNodeId = p.id }
            return .handled
        case .rightArrow:
            if press.modifiers.contains(.command) { store.indent(sel) }
            else if let n = nb.root.find(sel), let f = n.children.first { if n.collapsed { store.toggleCollapse(sel) }; store.selectedNodeId = f.id }
            return .handled
        default: return .ignored
        }
    }

    func moveSel(_ sel: UUID, _ nb: Notebook, dy: Int) {
        guard let p = nb.root.parentOf(sel), let i = p.children.firstIndex(where: { $0.id == sel }) else { return }
        let j = i + dy
        if j >= 0 && j < p.children.count { store.selectedNodeId = p.children[j].id }
    }
}

struct NodeView: View {
    @ObservedObject var store: Store
    let laid: LaidNode
    let isDrop: Bool
    @State private var draft = ""
    @FocusState private var editing: Bool

    var node: MindNode { laid.node }
    var card: Card? { store.card(node.cardId) }
    var selected: Bool { store.selectedNodeId == node.id }

    var fill: Color {
        if let c = card { return Color(nsColor: cardFill(c.color)) }
        return laid.depth == 0 ? Color(nsColor: NSColor(srgbRed: 0.86, green: 0.90, blue: 0.97, alpha: 1)) : Color.white
    }

    var body: some View {
        let isEditing = store.editingNodeId == node.id
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(fill)
                .shadow(color: .black.opacity(selected ? 0.2 : 0.1), radius: selected ? 3 : 1.2, y: 1)
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDrop || selected ? MN.accent : Color.black.opacity(0.1), lineWidth: isDrop || selected ? 2 : 0.6)
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField(L("标题"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: laid.depth == 0 ? 15 : 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.1))
                        .focused($editing)
                        .onSubmit { commit() }
                        .onAppear { draft = node.title; editing = true }
                        .onChange(of: editing) { _, v in if !v { commit() } }
                } else if !node.title.isEmpty || card == nil {
                    Text(store.nodeTitle(node))
                        .font(.system(size: laid.depth == 0 ? 15 : 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.1))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let c = card {
                    if c.isImage, let img = NSImage(contentsOf: Paths.cardImage(c.id)) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 140, alignment: .leading)
                    }
                    if !c.text.isEmpty {
                        Text(c.text).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.12)).lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let t = c.translation, !t.isEmpty {
                        Text(t).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.4)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(c.comments.prefix(3).enumerated()), id: \.offset) { _, cm in
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "text.bubble.fill").font(.system(size: 8)).foregroundStyle(.orange).padding(.top, 3)
                            Text(cm).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.2)).lineLimit(2)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            if let c = card, !store.linkedCards(c.id).isEmpty {
                Image(systemName: "link").font(.system(size: 9, weight: .bold)).foregroundStyle(.blue)
                    .offset(x: laid.frame.width - 14, y: 4)
            }
            if !node.children.isEmpty {
                Button { store.toggleCollapse(node.id) } label: {
                    ZStack {
                        Circle().fill(Color.white).overlay(Circle().stroke(Color(white: 0.62), lineWidth: 1))
                        if node.collapsed { Text("\(node.children.count)").font(.system(size: 8, weight: .bold)).foregroundStyle(Color(white: 0.35)) }
                        else { Rectangle().fill(Color(white: 0.45)).frame(width: 6, height: 1.2) }
                    }
                    .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .offset(x: laid.frame.width - 7, y: laid.frame.height / 2 - 7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let c = card { store.jump(to: c) } else { store.editingNodeId = node.id }
        }
        .onTapGesture {
            store.selectedNodeId = node.id
            if let c = card { store.selectedCardId = c.id }
        }
        .onDrag { NSItemProvider(object: ("node:" + node.id.uuidString) as NSString) }
        .contextMenu {
            Button(L("添加子主题")) { store.addChild(to: node.id) }
            if laid.depth > 0 { Button(L("添加同级主题")) { store.addSibling(of: node.id) } }
            Button(card == nil ? L("编辑标题") : L("编辑卡片标题")) { store.editingNodeId = node.id }
            if let c = card {
                Button(L("定位到文档")) { store.jump(to: c) }
                Menu(L("颜色")) { ForEach(0..<highlightColors.count, id: \.self) { i in Button(L(highlightNames[i])) { store.updateCard(c.id) { $0.color = i } } } }
            }
            if laid.depth > 0 {
                Divider()
                Button(L("上移")) { store.shift(node.id, by: -1) }
                Button(L("下移")) { store.shift(node.id, by: 1) }
                Button(L("升级")) { store.outdent(node.id) }
                Button(L("降级")) { store.indent(node.id) }
                Divider()
                if let c = card { Button(L("删除卡片"), role: .destructive) { store.deleteCard(c.id) } }
                else { Button(L("删除主题"), role: .destructive) { store.deleteNode(node.id) } }
            }
        }
    }

    func commit() {
        guard store.editingNodeId == node.id else { return }
        store.renameNode(node.id, draft.trimmingCharacters(in: .whitespacesAndNewlines))
        store.editingNodeId = nil
    }
}


struct GenMapButton: View {
    @ObservedObject var g = MapGenerator.shared
    @ObservedObject var wins = DocWindows.shared
    var body: some View {
        Button {
            if let id = wins.activeDocId { g.generate(docId: id) }
        } label: {
            HStack(spacing: 4) {
                if g.running != nil { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                Text(g.running != nil ? L("生成中…") : L("AI 生成脑图")).font(.system(size: 11))
            }
        }
        .disabled(g.running != nil || wins.activeDocId == nil)
        .help(g.error ?? L("让 AI 阅读全文，自动生成结构化脑图（要点可点击跳回原文）"))
    }
}
