import SwiftUI
import PDFKit

extension Notification.Name {
    /// object: doc id (nil = frontmost document window)
    static let findInDocument = Notification.Name("readit.findInDocument")
    static let findNext = Notification.Name("readit.findNext")
    static let findPrevious = Notification.Name("readit.findPrevious")
}

// MARK: - ⌘F full-text search

/// Searches the document shown in a reader (original or bilingual — both languages are text in the PDF),
/// highlights every match and steps through them.
@MainActor
final class FindController: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [PDFSelection] = []
    @Published private(set) var index = -1
    @Published private(set) var searching = false
    weak var rc: ReaderController?
    private var observers: [NSObjectProtocol] = []
    private weak var doc: PDFDocument?
    private var pendingJump = false

    init(rc: ReaderController) { self.rc = rc }

    func search() {
        stop()
        guard let rc, let d = rc.view.document else { return }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; index = -1
        guard !q.isEmpty else { rc.view.highlightedSelections = nil; return }
        doc = d
        searching = true; pendingJump = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .PDFDocumentDidFindMatch, object: d, queue: .main) { [weak self] n in
            guard let sel = n.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            MainActor.assumeIsolated { self?.found(sel) }
        })
        observers.append(nc.addObserver(forName: .PDFDocumentDidEndFind, object: d, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        })
        d.beginFindString(q, withOptions: [.caseInsensitive, .diacriticInsensitive])
    }

    private func found(_ sel: PDFSelection) {
        sel.color = NSColor.systemYellow.withAlphaComponent(0.55)
        results.append(sel)
        if results.count % 25 == 1 { rc?.view.highlightedSelections = results }
        // jump to the first match at or after the page being read
        if pendingJump, let rc, let p = sel.pages.first, let d = rc.view.document, d.index(for: p) >= rc.currentPageIndex {
            pendingJump = false
            select(results.count - 1)
        }
    }

    private func finished() {
        searching = false
        rc?.view.highlightedSelections = results
        if pendingJump, !results.isEmpty { pendingJump = false; select(0) }
        removeObservers()
    }

    func next() { guard !results.isEmpty else { search(); return }; select((index + 1) % results.count) }
    func previous() { guard !results.isEmpty else { return }; select((index - 1 + results.count) % results.count) }

    private func select(_ i: Int) {
        guard let rc, i >= 0, i < results.count else { return }
        index = i
        let sel = results[i]
        rc.view.setCurrentSelection(sel, animate: true)
        rc.view.go(to: sel)
    }

    func stop() {
        doc?.cancelFindString()
        removeObservers()
        searching = false
    }

    func close() {
        stop()
        results = []; index = -1
        rc?.view.highlightedSelections = nil
        rc?.view.clearSelection()
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

struct FindBar: View {
    @StateObject var find: FindController
    var close: () -> Void
    @FocusState private var focused: Bool

    init(rc: ReaderController, close: @escaping () -> Void) {
        _find = StateObject(wrappedValue: FindController(rc: rc))
        self.close = close
    }

    var isActive: Bool { DocWindows.shared.activeDocId == find.rc?.docId }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("在文档中查找"), text: $find.query)
                .textFieldStyle(.plain).frame(width: 220)
                .focused($focused)
                .onSubmit { NSEvent.modifierFlags.contains(.shift) ? find.previous() : (find.results.isEmpty ? find.search() : find.next()) }
            if find.searching { ProgressView().controlSize(.small) }
            Text(find.results.isEmpty ? (find.query.isEmpty || find.searching ? "" : L("无结果")) : "\(find.index + 1)/\(find.results.count)")
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            Button { find.previous() } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(find.results.isEmpty)
                .help(L("上一个（⇧⌘G）")).accessibilityLabel(L("上一个"))
            Button { find.next() } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).disabled(find.query.isEmpty)
                .help(L("下一个（⌘G）")).accessibilityLabel(L("下一个"))
            Button { find.close(); close() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction).accessibilityLabel(L("关闭查找"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .onAppear { focused = true }
        .onChange(of: find.query) { _, _ in find.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .findNext)) { _ in if isActive { find.next() } }
        .onReceive(NotificationCenter.default.publisher(for: .findPrevious)) { _ in if isActive { find.previous() } }
        .onReceive(NotificationCenter.default.publisher(for: .findInDocument)) { _ in focused = true }
        .onDisappear { find.close() }
    }
}

// MARK: - PDF table of contents

struct TOCEntry: Identifiable { let id = UUID(); let title: String; let page: Int?; let depth: Int }

enum PDFOutlineReader {
    static func entries(_ d: PDFDocument?) -> [TOCEntry] {
        guard let d, let root = d.outlineRoot else { return [] }
        var out: [TOCEntry] = []
        func walk(_ o: PDFOutline, _ depth: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                let page = (c.destination?.page).map { d.index(for: $0) }
                out.append(TOCEntry(title: (c.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines), page: page, depth: depth))
                if out.count > 3000 { return }
                walk(c, depth + 1)
            }
        }
        walk(root, 0)
        return out.filter { !$0.title.isEmpty }
    }
}

struct TOCList: View {
    @ObservedObject var rc: ReaderController
    var query: String
    @State private var entries: [TOCEntry] = []

    var body: some View {
        Group {
            if entries.isEmpty {
                Text(L("这份 PDF 没有内置目录")).font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else {
                ForEach(entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { e in
                    let current = e.page != nil && e.page == currentChapterPage
                    HStack(spacing: 6) {
                        Text(e.title).font(.system(size: e.depth == 0 ? 12.5 : 12, weight: e.depth == 0 ? .semibold : .regular)).lineLimit(2)
                        Spacer(minLength: 4)
                        if let p = e.page { Text("\(p + 1)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) }
                    }
                    .padding(.leading, CGFloat(e.depth) * 14 + 10).padding(.vertical, 5).padding(.trailing, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(current ? MN.accent.opacity(0.15) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if let p = e.page { rc.goToPage(p) } }
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .task(id: rc.docId) {
            entries = PDFOutlineReader.entries(rc.docId.flatMap { Store.shared.session($0)?.original })
        }
    }

    /// page of the chapter containing the current page
    var currentChapterPage: Int? {
        let cur = rc.currentPageIndex
        return entries.compactMap { $0.page }.filter { $0 <= cur }.max()
    }
}
