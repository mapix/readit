import SwiftUI
import PDFKit

/// MarginNote-style floating UI over the document:
///  - selection bar: appears right above a text selection — colour dots (tap = excerpt with that colour), copy, translate
///  - note popover: appears next to an excerpt right after creating it or when tapping an existing highlight
enum ReaderPopup: Equatable {
    case none
    case selection
    case card(UUID)
}

struct ReaderOverlay: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                switch rc.popup {
                case .selection:
                    if let a = rc.anchor {
                        SelectionBar(store: store, rc: rc)
                            .fixedSize()
                            .modifier(Anchored(anchor: a, container: geo.size, preferAbove: true))
                    }
                case .card(let id):
                    if let a = rc.anchor, store.card(id) != nil {
                        NotePopover(store: store, rc: rc, cardId: id)
                            .frame(width: 340)
                            .modifier(Anchored(anchor: a, container: geo.size, preferAbove: false))
                    }
                case .none:
                    EmptyView()
                }
            }
        }
    }
}

/// Places a popup next to an anchor rect (top-left based coordinates), keeping it inside the container.
struct Anchored: ViewModifier {
    let anchor: CGRect
    let container: CGSize
    let preferAbove: Bool
    @State private var size: CGSize = .zero
    func body(content: Content) -> some View {
        let w = size.width, h = size.height, gap: CGFloat = 8
        var x = anchor.midX - w / 2
        x = max(8, min(container.width - w - 8, x))
        var y: CGFloat
        if preferAbove {
            y = anchor.minY - h - gap
            if y < 8 { y = anchor.maxY + gap }
        } else {
            y = anchor.maxY + gap
            if y + h > container.height - 8 { y = anchor.minY - h - gap }
            if y < 8 { y = max(8, container.height - h - 8) }
        }
        x = x.finiteOr(8); y = y.finiteOr(8)
        return content
            .transition(.opacity)
            .background(GeometryReader { g in Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, v in size = v } })
            .offset(x: x, y: y)
            .opacity(size == .zero ? 0 : 1)
    }
}

// MARK: - selection bar

struct SelectionBar: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    @State private var showTr = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<highlightColors.count, id: \.self) { i in
                    Button { rc.makeCard(color: i) } label: {
                        Circle().fill(Color(nsColor: highlightColors[i]))
                            .frame(width: 19, height: 19)
                            .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                            .overlay(i == rc.lastColor ? Circle().stroke(Color.white, lineWidth: 2).padding(3) : nil)
                    }
                    .buttonStyle(.plain)
                    .help(LF("摘录为%@色卡片", L(highlightNames[i])))
                }
                Divider().frame(height: 20)
                BarButton(icon: "doc.on.doc", label: L("复制")) { rc.copySelection() }
                BarButton(icon: "sparkles", label: L("问 AI")) {
                    let q = rc.selectionString
                    UserDefaults.standard.set(true, forKey: "showCopilot")
                    let target = rc.docId
                    rc.closePopup()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NotificationCenter.default.post(name: .copilotAsk, object: target, userInfo: ["quote": q]) }
                }
                BarButton(icon: "character.book.closed", label: L("翻译")) {
                    showTr.toggle()
                    if showTr, let s = rc.view.currentSelection?.string { rc.translateSelection(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            if showTr || !store.selectionTranslation.isEmpty && store.selectionText == rc.selectionString {
                Divider()
                Group {
                    if store.selectionBusy { HStack { ProgressView().controlSize(.small); Text(L("翻译中…")).foregroundStyle(.secondary) } }
                    else { Text(store.selectionTranslation).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                .font(.system(size: 13))
                .frame(width: 300, alignment: .leading)
                .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .onChange(of: rc.selectionString) { _, _ in showTr = false }
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    var tint: Color = .primary
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 9))
            }
            .foregroundStyle(tint)
            .frame(minWidth: 30)
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - note popover (MarginNote "card" popup)

struct NotePopover: View {
    @ObservedObject var store: Store
    @ObservedObject var rc: ReaderController
    let cardId: UUID
    @State private var newComment = ""
    @State private var addingComment = false
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var linking = false
    @State private var query = ""
    @FocusState private var commentFocus: Bool

    var card: Card? { store.card(cardId) }

    var body: some View {
        if let c = card {
            let tint = Color(nsColor: highlightColors[c.color % highlightColors.count])
            VStack(alignment: .leading, spacing: 0) {
                // header strip in excerpt colour
                HStack(spacing: 6) {
                    ForEach(0..<highlightColors.count, id: \.self) { i in
                        Circle().fill(Color(nsColor: highlightColors[i])).frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.black.opacity(c.color == i ? 0.55 : 0.12), lineWidth: c.color == i ? 1.6 : 0.5))
                            .onTapGesture { store.updateCard(c.id) { $0.color = i }; rc.lastColor = i }
                    }
                    Spacer()
                    Button { rc.closePopup() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(tint.opacity(0.35))

                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        // title (MarginNote cards have an optional title above the excerpt)
                        if editingTitle {
                            TextField(L("标题"), text: $titleDraft, onCommit: { commitTitle(c) })
                                .textFieldStyle(.roundedBorder).font(.system(size: 13, weight: .semibold))
                        } else if let n = store.currentNotebook?.root.nodeFor(card: c.id), !n.title.isEmpty {
                            Text(n.title).font(.system(size: 14, weight: .semibold)).onTapGesture(count: 2) { startTitle(c) }
                        }
                        Text(c.text).font(.system(size: 13)).foregroundStyle(Color(white: 0.12)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let t = c.translation, !t.isEmpty {
                            Text(t).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.38)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(c.comments.enumerated()), id: \.offset) { i, cm in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "text.bubble.fill").font(.system(size: 10)).foregroundStyle(.orange).padding(.top, 3)
                                Text(cm).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button { store.registerUndo(L("删除评论")); store.updateCard(c.id) { $0.comments.remove(at: i) } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("删除评论"))
                            }
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
                        }
                        if addingComment {
                            TextField(L("输入评论，回车保存"), text: $newComment, axis: .vertical)
                                .textFieldStyle(.roundedBorder).font(.system(size: 13))
                                .lineLimit(1...6)
                                .focused($commentFocus)
                                .onSubmit { commitComment(c) }
                                .onAppear { commentFocus = true }
                        }
                        let links = store.linkedCards(c.id)
                        if !links.isEmpty {
                            ForEach(links) { l in
                                HStack(spacing: 6) {
                                    Image(systemName: "link").foregroundStyle(.purple).font(.system(size: 11))
                                    Text(l.text).lineLimit(1).font(.system(size: 12))
                                    Spacer()
                                    Text("\(store.doc(l.docId)?.title ?? "") p.\(l.page + 1)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { rc.closePopup(); store.jump(to: l) }
                            }
                        }
                        if linking { linkPicker(c) }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)

                Divider()
                HStack(spacing: 2) {
                    BarButton(icon: "text.bubble", label: L("评论")) { addingComment = true }
                    BarButton(icon: "textformat", label: L("标题")) { startTitle(c) }
                    BarButton(icon: "link", label: L("链接")) { linking.toggle(); query = "" }
                    BarButton(icon: "point.3.connected.trianglepath.dotted", label: L("脑图")) { store.focusInMap(c.id) }
                    BarButton(icon: "doc.on.doc", label: L("复制")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(([c.text, c.translation ?? ""] + c.comments).filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
                    }
                    Spacer()
                    BarButton(icon: "trash", label: L("删除"), tint: .red) { rc.closePopup(); store.deleteCard(c.id) }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.9), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .onChange(of: cardId) { _, _ in addingComment = false; linking = false; editingTitle = false; newComment = "" }
        }
    }

    func commitComment(_ c: Card) {
        let t = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { store.updateCard(c.id) { $0.comments.append(t) } }
        newComment = ""
        addingComment = false
    }
    func startTitle(_ c: Card) {
        titleDraft = store.currentNotebook?.root.nodeFor(card: c.id)?.title ?? ""
        editingTitle = true
    }
    func commitTitle(_ c: Card) {
        if let n = store.currentNotebook?.root.nodeFor(card: c.id) { store.renameNode(n.id, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
        editingTitle = false
    }

    @ViewBuilder func linkPicker(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("搜索所有文档的卡片…"), text: $query).textFieldStyle(.roundedBorder).font(.system(size: 12))
            let linked = Set(store.linkedCards(c.id).map { $0.id })
            let cands = store.lib.cards.filter { $0.id != c.id && !linked.contains($0.id) && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) || ($0.translation ?? "").localizedCaseInsensitiveContains(query) || $0.commentText.localizedCaseInsensitiveContains(query)) }.prefix(12)
            if cands.isEmpty { Text(L("没有可链接的卡片")).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(cands)) { o in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: highlightColors[o.color % highlightColors.count])).frame(width: 3, height: 14)
                    Text(o.text).lineLimit(1).font(.system(size: 12))
                    Spacer()
                    Text("\(store.doc(o.docId)?.title ?? "") p.\(o.page + 1)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { store.link(c.id, o.id); linking = false }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.purple.opacity(0.06)))
    }
}
