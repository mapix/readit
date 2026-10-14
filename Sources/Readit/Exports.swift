import Foundation
import AppKit
import UniformTypeIdentifiers

/// Notes out of Readit: Markdown (Obsidian / Logseq friendly) and Anki.
enum Exports {
    /// excerpt cards of the current notebook grouped by document, page order
    @MainActor static func notesMarkdown(notebook nb: Notebook, store s: Store) -> String {
        var out = "# \(nb.name)\n\n"
        out += "> " + LF("由 Readit 导出 · %@", ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])) + "\n\n"
        for docId in nb.docIds {
            guard let doc = s.doc(docId) else { continue }
            let cards = s.lib.cards.filter { $0.docId == docId }.sorted { ($0.page, $0.created) < ($1.page, $1.created) }
            guard !cards.isEmpty else { continue }
            out += "## \(doc.title)\n\n"
            if let src = doc.source { out += "Source: <\(src)>\n\n" }
            for c in cards {
                let tag = "#readit/" + (highlightNames[c.color % highlightNames.count])
                if c.isImage { out += "- " + L("［图片摘录］") + " (p.\(c.page + 1)) \(tag)\n" } else {
                    let quote = c.text.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
                    out += quote + "\n"
                    if let t = c.translation, !t.isEmpty { out += ">\n" + t.split(separator: "\n").map { "> *" + $0 + "*" }.joined(separator: "\n") + "\n" }
                    out += "\n— p.\(c.page + 1) \(tag)\n"
                }
                for cm in c.comments where !cm.isEmpty { out += "- 💬 \(cm)\n" }
                let links = s.linkedCards(c.id)
                for l in links { out += "- 🔗 \(s.doc(l.docId)?.title ?? "") p.\(l.page + 1): \(l.text.prefix(60))\n" }
                out += "\n"
            }
        }
        return out
    }

    /// Anki "Text separated by tabs" with header directives (Anki 2.1.55+): front, back, tags
    @MainActor static func anki(notebook nb: Notebook, store s: Store, includeFlashcards: Bool = true, includeExcerpts: Bool = true) -> (text: String, count: Int) {
        func cell(_ v: String) -> String {
            v.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        func tagify(_ v: String) -> String {
            String(v.map { $0.isWhitespace || $0 == ":" || $0 == "\"" ? "_" : $0 }.prefix(60))
        }
        var rows: [String] = []
        for docId in nb.docIds {
            guard let doc = s.doc(docId) else { continue }
            let dtag = "readit::" + tagify(doc.title)
            if includeFlashcards {
                for deck in FlashStore.shared.decks(docId) {
                    for c in deck.cards {
                        var back = c.answer
                        if let e = c.explanation, !e.isEmpty { back += "<br><br><small>" + e + "</small>" }
                        if let p = c.page { back += "<br><small>— \(doc.title) p.\(p)</small>" }
                        rows.append([cell(c.question), cell(back), dtag + " " + tagify(c.kind)].joined(separator: "\t"))
                    }
                }
            }
            if includeExcerpts {
                for c in s.lib.cards where c.docId == docId && !c.isImage && !c.text.isEmpty {
                    var back = c.translation ?? ""
                    if !c.commentText.isEmpty { back += (back.isEmpty ? "" : "<br><br>") + "💬 " + c.commentText }
                    back += "<br><small>— \(doc.title) p.\(c.page + 1)</small>"
                    rows.append([cell(c.text), cell(back), dtag + " excerpt"].joined(separator: "\t"))
                }
            }
        }
        let header = "#separator:tab\n#html:true\n#tags column:3\n"
        return (header + rows.joined(separator: "\n") + "\n", rows.count)
    }

    @MainActor static func save(_ text: String, name: String, ext: String) {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        p.nameFieldStringValue = name + "." + ext
        if p.runModal() == .OK, let u = p.url { try? text.write(to: u, atomically: true, encoding: .utf8) }
    }
}

@MainActor func exportNotesMarkdown() {
    let s = Store.shared
    guard let nb = s.currentNotebook else { return }
    Exports.save(Exports.notesMarkdown(notebook: nb, store: s), name: nb.name + " – " + L("摘录笔记"), ext: "md")
}

@MainActor func exportAnki() {
    let s = Store.shared
    guard let nb = s.currentNotebook else { return }
    let r = Exports.anki(notebook: nb, store: s)
    guard r.count > 0 else {
        let a = NSAlert(); a.messageText = L("没有可导出的卡片"); a.informativeText = L("先生成闪卡或摘录一些内容。"); a.runModal(); return
    }
    Exports.save(r.text, name: nb.name + " – Anki", ext: "txt")
}
