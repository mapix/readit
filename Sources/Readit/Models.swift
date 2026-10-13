import Foundation
import AppKit
import PDFKit

enum Variant: String, Codable, Hashable { case original, bilingual }

struct Doc: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var added = Date()
    /// web page the PDF was imported from (Readit's "从网页导入")
    var source: String? = nil
}

struct Card: Codable, Identifiable, Hashable {
    var id = UUID()
    var docId: UUID
    var page: Int
    var variant: Variant
    var rects: [CGRect]
    var text: String
    var note: String = ""          // legacy single comment (migrated into comments)
    var color: Int = 0
    var created = Date()
    var translation: String? = nil
    var comments: [String] = []
    var isImage = false

    init(docId: UUID, page: Int, variant: Variant, rects: [CGRect], text: String, color: Int = 0) {
        self.docId = docId; self.page = page; self.variant = variant; self.rects = rects; self.text = text; self.color = color
    }
    enum CodingKeys: String, CodingKey { case id, docId, page, variant, rects, text, note, color, created, translation, comments, isImage }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        docId = try c.decode(UUID.self, forKey: .docId)
        page = try c.decode(Int.self, forKey: .page)
        variant = try c.decode(Variant.self, forKey: .variant)
        rects = try c.decode([CGRect].self, forKey: .rects)
        text = try c.decode(String.self, forKey: .text)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        translation = try c.decodeIfPresent(String.self, forKey: .translation)
        comments = try c.decodeIfPresent([String].self, forKey: .comments) ?? []
        isImage = try c.decodeIfPresent(Bool.self, forKey: .isImage) ?? false
        let legacy = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        if !legacy.isEmpty && comments.isEmpty { comments = [legacy] }
    }
    /// all comments joined (for display in PDF annotations / exports)
    var commentText: String { comments.filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct MindNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var cardId: UUID? = nil
    var children: [MindNode] = []
    var collapsed = false
}

struct Notebook: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var docIds: [UUID] = []
    var root: MindNode
}

struct CardLink: Codable, Hashable {
    var a: UUID
    var b: UUID
}

struct Library: Codable {
    var docs: [Doc] = []
    var notebooks: [Notebook] = []
    var cards: [Card] = []
    var links: [CardLink] = []
}

let highlightColors: [NSColor] = [
    NSColor(srgbRed: 1.00, green: 0.89, blue: 0.36, alpha: 1),   // 黄
    NSColor(srgbRed: 0.55, green: 0.86, blue: 0.47, alpha: 1),   // 绿
    NSColor(srgbRed: 0.45, green: 0.72, blue: 1.00, alpha: 1),   // 蓝
    NSColor(srgbRed: 1.00, green: 0.55, blue: 0.55, alpha: 1),   // 红
    NSColor(srgbRed: 0.76, green: 0.60, blue: 0.97, alpha: 1),   // 紫
    NSColor(srgbRed: 1.00, green: 0.67, blue: 0.35, alpha: 1),   // 橙
    NSColor(srgbRed: 0.40, green: 0.85, blue: 0.85, alpha: 1),   // 青
    NSColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1),   // 灰
]
let highlightNames = ["黄", "绿", "蓝", "红", "紫", "橙", "青", "灰"]

/// pale card fill used in the mind map (MarginNote paints cards with a light tint of the excerpt colour)
func cardFill(_ i: Int) -> NSColor { highlightColors[i % highlightColors.count].blended(withFraction: 0.72, of: .white) ?? .white }

enum Paths {
    static let base: URL = {
        // BIREADER_DATA lets tests use a throwaway directory instead of the user's real library
        let u = ProcessInfo.processInfo.environment["BIREADER_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BiReader", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var libraryFile: URL { base.appendingPathComponent("library.json") }
    static func docDir(_ id: UUID) -> URL {
        let u = base.appendingPathComponent("docs/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func pdf(_ id: UUID) -> URL { docDir(id).appendingPathComponent("original.pdf") }
    static func cardImage(_ id: UUID) -> URL {
        let u = base.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent(id.uuidString + ".png")
    }
}

// MARK: - mind map tree helpers

extension MindNode {
    @discardableResult
    mutating func mutate(_ id: UUID, _ f: (inout MindNode) -> Void) -> Bool {
        if self.id == id { f(&self); return true }
        for i in children.indices { if children[i].mutate(id, f) { return true } }
        return false
    }
    func find(_ id: UUID) -> MindNode? {
        if self.id == id { return self }
        for c in children { if let n = c.find(id) { return n } }
        return nil
    }
    func parentOf(_ id: UUID) -> MindNode? {
        for c in children {
            if c.id == id { return self }
            if let p = c.parentOf(id) { return p }
        }
        return nil
    }
    mutating func remove(_ id: UUID) -> MindNode? {
        if let i = children.firstIndex(where: { $0.id == id }) { return children.remove(at: i) }
        for i in children.indices { if let n = children[i].remove(id) { return n } }
        return nil
    }
    func contains(_ id: UUID) -> Bool { find(id) != nil }
    func allCardIds() -> [UUID] { (cardId.map { [$0] } ?? []) + children.flatMap { $0.allCardIds() } }
    func nodeFor(card: UUID) -> MindNode? {
        if cardId == card { return self }
        for c in children { if let n = c.nodeFor(card: card) { return n } }
        return nil
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var lib = Library()
    @Published var currentNotebookId: UUID?
    @Published var currentDocId: UUID?
    @Published var variant: Variant = .original
    @Published var selectedCardId: UUID?
    @Published var selectedNodeId: UUID?
    @Published var pendingJump: Card?
    @Published var selectionText: String = ""
    @Published var selectionTranslation: String = ""
    @Published var selectionBusy = false
    @Published var editingNodeId: UUID?
    @Published var studying = UserDefaults.standard.bool(forKey: "studying") { didSet { UserDefaults.standard.set(studying, forKey: "studying") } }

    var sessions: [UUID: DocSession] = [:]
    private var saveWork: DispatchWorkItem?

    init() {
        if let d = try? Data(contentsOf: Paths.libraryFile), let l = try? JSONDecoder().decode(Library.self, from: d) { lib = l }
        if lib.notebooks.isEmpty {
            lib.notebooks.append(Notebook(name: L("我的笔记本"), root: MindNode(title: L("我的笔记本"))))
        }
        currentNotebookId = UserDefaults.standard.string(forKey: "lastNotebook").flatMap(UUID.init) ?? lib.notebooks.first?.id
        if !lib.notebooks.contains(where: { $0.id == currentNotebookId }) { currentNotebookId = lib.notebooks.first?.id }
        currentDocId = UserDefaults.standard.string(forKey: "lastDoc").flatMap(UUID.init)
        if let d = currentDocId, !lib.docs.contains(where: { $0.id == d }) { currentDocId = nil }
        if currentDocId == nil { currentDocId = currentNotebook?.docIds.first }
        variant = Variant(rawValue: UserDefaults.standard.string(forKey: "lastVariant") ?? "") ?? .original
    }

    /// write immediately (imports, deletes — never lose these to a quit within the debounce window)
    func saveNow() {
        saveWork?.cancel()
        if let d = try? JSONEncoder().encode(lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
        UserDefaults.standard.set(currentNotebookId?.uuidString, forKey: "lastNotebook")
    }

    func save() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let d = try? JSONEncoder().encode(self.lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
            UserDefaults.standard.set(self.currentNotebookId?.uuidString, forKey: "lastNotebook")
            UserDefaults.standard.set(self.currentDocId?.uuidString, forKey: "lastDoc")
            UserDefaults.standard.set(self.variant.rawValue, forKey: "lastVariant")
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    var currentNotebook: Notebook? { lib.notebooks.first { $0.id == currentNotebookId } }
    var currentDoc: Doc? { lib.docs.first { $0.id == currentDocId } }
    func doc(_ id: UUID) -> Doc? { lib.docs.first { $0.id == id } }
    func card(_ id: UUID?) -> Card? { guard let id else { return nil }; return lib.cards.first { $0.id == id } }

    func session(_ id: UUID) -> DocSession? {
        if let s = sessions[id] { return s }
        guard let d = doc(id), let s = DocSession(doc: d) else { return nil }
        sessions[id] = s
        return s
    }

    // MARK: notebooks & docs
    func updateNotebook(_ f: (inout Notebook) -> Void) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == currentNotebookId }) else { return }
        f(&lib.notebooks[i]); save()
    }

    func newNotebook(name: String = L("新笔记本")) {
        let nb = Notebook(name: name, root: MindNode(title: name))
        lib.notebooks.append(nb)
        currentNotebookId = nb.id
        currentDocId = nil
        save()
    }

    func renameNotebook(_ id: UUID, _ name: String) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == id }) else { return }
        lib.notebooks[i].name = name
        lib.notebooks[i].root.title = name
        save()
    }

    func deleteNotebook(_ id: UUID) {
        lib.notebooks.removeAll { $0.id == id }
        if lib.notebooks.isEmpty { lib.notebooks.append(Notebook(name: L("我的笔记本"), root: MindNode(title: L("我的笔记本")))) }
        if currentNotebookId == id { currentNotebookId = lib.notebooks.first?.id; currentDocId = currentNotebook?.docIds.first }
        save()
    }

    @discardableResult
    func importPDF(_ url: URL, open: Bool = false) -> UUID? {
        guard PDFDocument(url: url) != nil else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        // same file imported before? reuse
        if let existing = lib.docs.first(where: { $0.title == title }),
           let a = try? Data(contentsOf: Paths.pdf(existing.id)), let b = try? Data(contentsOf: url), a == b {
            addDocToNotebook(existing.id)
            if open { DocWindows.shared.open(existing.id) }
            return existing.id
        }
        let d = Doc(title: title)
        do { try FileManager.default.copyItem(at: url, to: Paths.pdf(d.id)) } catch { return nil }
        lib.docs.append(d)
        addDocToNotebook(d.id)
        saveNow()
        if open { DocWindows.shared.open(d.id) }
        return d.id
    }

    func setSource(_ docId: UUID, _ url: String) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        lib.docs[i].source = url
        saveNow()
    }

    func addDocToNotebook(_ docId: UUID, notebook: UUID? = nil) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == (notebook ?? currentNotebookId) }) else { return }
        if !lib.notebooks[i].docIds.contains(docId) { lib.notebooks[i].docIds.append(docId) }
        save()
    }

    func renameDoc(_ id: UUID, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = lib.docs.firstIndex(where: { $0.id == id }) else { return }
        lib.docs[i].title = t
        DocWindows.shared.entries[id]?.window.title = t
        saveNow()
    }

    func removeDocFromNotebook(_ docId: UUID) {
        updateNotebook { $0.docIds.removeAll { $0 == docId } }
        if currentDocId == docId { currentDocId = currentNotebook?.docIds.first }
    }

    func deleteDoc(_ docId: UUID) {
        lib.docs.removeAll { $0.id == docId }
        for i in lib.notebooks.indices { lib.notebooks[i].docIds.removeAll { $0 == docId } }
        let cardIds = Set(lib.cards.filter { $0.docId == docId }.map { $0.id })
        lib.cards.removeAll { cardIds.contains($0.id) }
        lib.links.removeAll { cardIds.contains($0.a) || cardIds.contains($0.b) }
        for i in lib.notebooks.indices { for c in cardIds { removeNodes(forCard: c, in: &lib.notebooks[i].root) } }
        sessions[docId] = nil
        try? FileManager.default.removeItem(at: Paths.docDir(docId))
        saveNow()
        if currentDocId == docId { currentDocId = currentNotebook?.docIds.first }
        save()
    }

    func openDoc(_ id: UUID) {
        currentDocId = id
        save()
    }

    func setVariant(_ v: Variant) {
        variant = v
        ReaderController.shared.setVariant(v)
        save()
    }

    // MARK: cards
    func addCard(_ card: Card) {
        lib.cards.append(card)
        addDocToNotebook(card.docId)
        updateNotebook { nb in
            let node = MindNode(title: "", cardId: card.id)
            let target = selectedNodeId.flatMap { nb.root.contains($0) ? $0 : nil } ?? nb.root.id
            nb.root.mutate(target) { $0.children.append(node); $0.collapsed = false }
        }
        selectedCardId = card.id
        if let n = currentNotebook?.root.nodeFor(card: card.id) { selectedNodeId = n.id }
        save()
        // translate the excerpt for the card
        if !card.text.isEmpty, Translator.needsTranslation(card.text) {
            Task {
                if let t = try? await Translator.translateOne(card.text) {
                    self.updateCard(card.id) { $0.translation = t }
                }
            }
        }
    }

    func updateCard(_ id: UUID, _ f: (inout Card) -> Void) {
        guard let i = lib.cards.firstIndex(where: { $0.id == id }) else { return }
        f(&lib.cards[i])
        let c = lib.cards[i]
        sessions[c.docId]?.refreshAnnotations(for: c)
        save()
    }

    func deleteCard(_ id: UUID) {
        guard let c = card(id) else { return }
        lib.cards.removeAll { $0.id == id }
        lib.links.removeAll { $0.a == id || $0.b == id }
        for i in lib.notebooks.indices { removeNodes(forCard: id, in: &lib.notebooks[i].root) }
        sessions[c.docId]?.removeAnnotations(cardId: id)
        if selectedCardId == id { selectedCardId = nil }
        save()
    }

    private func removeNodes(forCard id: UUID, in node: inout MindNode) {
        var newChildren: [MindNode] = []
        for var ch in node.children {
            removeNodes(forCard: id, in: &ch)
            if ch.cardId == id { newChildren.append(contentsOf: ch.children) } else { newChildren.append(ch) }
        }
        node.children = newChildren
    }

    @Published var mapFocusRequest: UUID?
    func focusInMap(_ cardId: UUID) {
        if let n = currentNotebook?.root.nodeFor(card: cardId) { selectedNodeId = n.id; mapFocusRequest = n.id }
    }

    func link(_ a: UUID, _ b: UUID) {
        guard a != b, !lib.links.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }) else { return }
        lib.links.append(CardLink(a: a, b: b)); save()
    }
    func unlink(_ a: UUID, _ b: UUID) {
        lib.links.removeAll { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }; save()
    }
    func linkedCards(_ id: UUID) -> [Card] {
        lib.links.compactMap { $0.a == id ? card($0.b) : ($0.b == id ? card($0.a) : nil) }
    }

    func jump(to card: Card) {
        selectedCardId = card.id
        if let e = DocWindows.shared.entries[card.docId] {
            e.window.makeKeyAndOrderFront(nil)
            if e.reader.variant != card.variant { e.reader.setVariant(card.variant) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (e.reader.variant == card.variant ? 0 : 0.3)) { e.reader.jump(to: card) }
        } else {
            UserDefaults.standard.set(card.variant.rawValue, forKey: "variant-" + card.docId.uuidString)
            DocWindows.shared.open(card.docId, jump: card)
        }
    }

    // MARK: mind map editing
    func addChild(to parent: UUID?, title: String = L("新主题")) {
        let n = MindNode(title: title)
        updateNotebook { nb in
            let p = parent.flatMap { nb.root.contains($0) ? $0 : nil } ?? nb.root.id
            nb.root.mutate(p) { $0.children.append(n); $0.collapsed = false }
        }
        selectedNodeId = n.id
        editingNodeId = n.id
    }

    func addSibling(of id: UUID) {
        guard let nb = currentNotebook, id != nb.root.id, let parent = nb.root.parentOf(id) else { addChild(to: id); return }
        let n = MindNode(title: L("新主题"))
        updateNotebook { nb in
            nb.root.mutate(parent.id) { p in
                let i = (p.children.firstIndex { $0.id == id } ?? p.children.count - 1) + 1
                p.children.insert(n, at: i)
            }
        }
        selectedNodeId = n.id
        editingNodeId = n.id
    }

    func renameNode(_ id: UUID, _ title: String) {
        updateNotebook { nb in nb.root.mutate(id) { $0.title = title } }
        if let nb = currentNotebook, nb.root.id == id { renameNotebook(nb.id, title) }
    }

    func deleteNode(_ id: UUID) {
        guard let nb = currentNotebook, id != nb.root.id else { return }
        let parent = nb.root.parentOf(id)
        updateNotebook { nb in _ = nb.root.remove(id) }
        selectedNodeId = parent?.id
    }

    func toggleCollapse(_ id: UUID) { updateNotebook { nb in nb.root.mutate(id) { $0.collapsed.toggle() } } }

    func moveNode(_ id: UUID, under newParent: UUID) {
        guard let nb = currentNotebook, id != nb.root.id, id != newParent,
              let node = nb.root.find(id), !node.contains(newParent) else { return }
        updateNotebook { nb in
            if let n = nb.root.remove(id) { nb.root.mutate(newParent) { $0.children.append(n); $0.collapsed = false } }
        }
    }

    func shift(_ id: UUID, by delta: Int) {
        guard let nb = currentNotebook, let parent = nb.root.parentOf(id) else { return }
        updateNotebook { nb in
            nb.root.mutate(parent.id) { p in
                guard let i = p.children.firstIndex(where: { $0.id == id }) else { return }
                let j = i + delta
                guard j >= 0, j < p.children.count else { return }
                p.children.swapAt(i, j)
            }
        }
    }

    func indent(_ id: UUID) {
        guard let nb = currentNotebook, let parent = nb.root.parentOf(id),
              let i = parent.children.firstIndex(where: { $0.id == id }), i > 0 else { return }
        moveNode(id, under: parent.children[i - 1].id)
    }

    func outdent(_ id: UUID) {
        guard let nb = currentNotebook, let parent = nb.root.parentOf(id), let grand = nb.root.parentOf(parent.id) else { return }
        updateNotebook { nb in
            guard let n = nb.root.remove(id) else { return }
            nb.root.mutate(grand.id) { g in
                let i = (g.children.firstIndex { $0.id == parent.id } ?? g.children.count - 1) + 1
                g.children.insert(n, at: i)
            }
        }
    }

    /// put an existing card into the mind map (e.g. dragged from the card list)
    func attachCard(_ cardId: UUID, under parent: UUID) {
        guard let nb = currentNotebook else { return }
        if let existing = nb.root.nodeFor(card: cardId) { moveNode(existing.id, under: parent); return }
        updateNotebook { nb in nb.root.mutate(parent) { $0.children.append(MindNode(title: "", cardId: cardId)); $0.collapsed = false } }
    }

    func nodeTitle(_ n: MindNode) -> String {
        if !n.title.isEmpty { return n.title }
        if let c = card(n.cardId) { return c.text.isEmpty ? (c.isImage ? "［图片摘录］" : "（空）") : c.text }
        return "（空）"
    }
}
