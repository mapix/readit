#if os(macOS)
import Foundation
import AppKit

/// Local documents → HTML content for Readlet's print template (then printed to PDF by WebImporter).
/// EPUB: chapters in spine order, images resolved to files; Markdown: rendered by marked in the page;
/// Word / RTF / ODT: via NSAttributedString; plain text: paragraphs.
enum DocConverter {
    struct Converted {
        var title: String
        var author = ""
        var body: String          // HTML, or Markdown when `markdown`
        var markdown = false
        var source = ""
    }

    static let supportedExtensions = ["epub", "md", "markdown", "mdown", "txt", "text", "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xhtml", "webarchive"]

    static func convert(_ url: URL, workDir: URL) async throws -> Converted {
        let ext = url.pathExtension.lowercased()
        let name = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "epub":
            return try EPUB.convert(url, workDir: workDir)
        case "md", "markdown", "mdown":
            let text = try readText(url)
            var c = Converted(title: markdownTitle(text) ?? name, body: absolutizeMarkdownImages(text, base: url.deletingLastPathComponent()), markdown: true)
            c.source = url.path
            return c
        case "txt", "text":
            let text = try readText(url)
            let paras = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                .map { "<p>" + escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            return Converted(title: name, body: paras.joined(separator: "\n"))
        case "docx", "doc", "rtf", "rtfd", "odt":
            return Converted(title: name, body: try richTextHTML(url))
        default:
            throw TranslateError.bad(L("不支持的文件格式：") + ext)
        }
    }

    static func readText(_ url: URL) throws -> String {
        let d = try Data(contentsOf: url)
        if let s = String(data: d, encoding: .utf8) { return s }
        if let s = String(data: d, encoding: .utf16) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: d, encoding: String.Encoding(rawValue: gb)) { return s }
        return String(decoding: d, as: UTF8.self)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// first "# Heading" of a Markdown file
    static func markdownTitle(_ md: String) -> String? {
        for line in md.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// ![alt](relative.png) → file:///…/relative.png so the print view can load it
    static func absolutizeMarkdownImages(_ md: String, base: URL) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(!\[[^\]]*\]\()([^)\s]+)"#) else { return md }
        let ns = md as NSString
        var out = md
        for m in re.matches(in: md, range: NSRange(location: 0, length: ns.length)).reversed() {
            let path = ns.substring(with: m.range(at: 2))
            if path.contains("://") || path.hasPrefix("data:") || path.hasPrefix("#") { continue }
            let abs = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path.removingPercentEncoding ?? path)
            out = (out as NSString).replacingCharacters(in: m.range(at: 2), with: abs.absoluteString)
        }
        return out
    }

    /// Word / RTF via AppKit's text system; their font styles are dropped so Readlet's print CSS applies
    static func richTextHTML(_ url: URL) throws -> String {
        let attr = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue])
        let html = String(decoding: data, as: UTF8.self)
        var style = ""
        if let r = html.range(of: #"<style[^>]*>([\s\S]*?)</style>"#, options: .regularExpression) {
            style = String(html[r])
                .replacingOccurrences(of: #"font(-family|-size)?\s*:[^;}]*;?"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"line-height\s*:[^;}]*;?"#, with: "", options: .regularExpression)
        }
        var body = html
        if let r = html.range(of: #"<body[^>]*>([\s\S]*)</body>"#, options: .regularExpression) {
            body = String(html[r]).replacingOccurrences(of: #"^<body[^>]*>|</body>$"#, with: "", options: .regularExpression)
        }
        return style + body
    }
}

// MARK: - EPUB

enum EPUB {
    static func convert(_ url: URL, workDir: URL) throws -> DocConverter.Converted {
        let root = workDir.appendingPathComponent("epub", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try unzip(url, to: root)
        // META-INF/container.xml → the OPF package file
        let container = root.appendingPathComponent("META-INF/container.xml")
        guard let cdata = try? Data(contentsOf: container) else { throw TranslateError.bad(L("不是有效的 EPUB 文件")) }
        let c = XMLScan(cdata)
        guard let opfPath = c.elements.first(where: { $0.name.hasSuffix("rootfile") })?.attrs["full-path"] else { throw TranslateError.bad(L("不是有效的 EPUB 文件")) }
        let opfURL = root.appendingPathComponent(opfPath)
        guard let odata = try? Data(contentsOf: opfURL) else { throw TranslateError.bad(L("不是有效的 EPUB 文件")) }
        let opf = XMLScan(odata)
        var manifest: [String: (href: String, type: String)] = [:]
        var spine: [String] = []
        for e in opf.elements {
            if e.name.hasSuffix("item"), let id = e.attrs["id"], let href = e.attrs["href"] { manifest[id] = (href, e.attrs["media-type"] ?? "") }
            if e.name.hasSuffix("itemref"), let id = e.attrs["idref"], e.attrs["linear"] != "no" { spine.append(id) }
        }
        let title = opf.elements.first { $0.name.hasSuffix("title") }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? url.deletingPathExtension().lastPathComponent
        let author = opf.elements.first { $0.name.hasSuffix("creator") }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = opfURL.deletingLastPathComponent()
        var parts: [String] = []
        for id in spine {
            guard let item = manifest[id], item.type.contains("html") || item.href.hasSuffix("html") || item.href.hasSuffix("htm") else { continue }
            let chapter = base.appendingPathComponent(item.href.removingPercentEncoding ?? item.href)
            guard let d = try? Data(contentsOf: chapter) else { continue }
            let html = String(decoding: d, as: UTF8.self)
            var body = html
            if let r = html.range(of: #"<body[^>]*>([\s\S]*)</body>"#, options: .regularExpression) {
                body = String(html[r]).replacingOccurrences(of: #"^<body[^>]*>|</body>$"#, with: "", options: .regularExpression)
            }
            body = body.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
            body = absolutize(body, chapter: chapter)
            parts.append("<section class=\"readit-chapter\">\n" + body + "\n</section>")
        }
        guard !parts.isEmpty else { throw TranslateError.bad(L("EPUB 里没有可读的章节")) }
        let css = "<style>.readit-chapter + .readit-chapter { break-before: page; page-break-before: always; } .readit-chapter img { max-height: 90vh; }</style>"
        return DocConverter.Converted(title: title, author: author, body: css + parts.joined(separator: "\n"))
    }

    static func unzip(_ src: URL, to dst: URL) throws {
        do { try ZipReader.extract(src, to: dst) }
        catch { throw TranslateError.bad(L("无法解压 EPUB") + "（\(error.localizedDescription)）") }
    }

    /// src / href / xlink:href / poster relative to the chapter file → absolute file URLs
    static func absolutize(_ html: String, chapter: URL) -> String {
        guard let re = try? NSRegularExpression(pattern: #"((?:src|xlink:href|poster)\s*=\s*["'])([^"'#][^"']*)(["'])"#, options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = html
        let dir = chapter.deletingLastPathComponent()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)).reversed() {
            let v = ns.substring(with: m.range(at: 2))
            if v.contains("://") || v.hasPrefix("data:") { continue }
            let abs = URL(fileURLWithPath: (v.removingPercentEncoding ?? v), relativeTo: dir).standardizedFileURL.absoluteString
            out = (out as NSString).replacingCharacters(in: m.range(at: 2), with: abs)
        }
        return out
    }
}

/// tiny XML walker: every element with its attributes and direct text
final class XMLScan: NSObject, XMLParserDelegate {
    struct Element { var name: String; var attrs: [String: String]; var text = "" }
    private(set) var elements: [Element] = []
    private var stack: [Int] = []

    init(_ data: Data) {
        super.init()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = false
        p.delegate = self
        p.parse()
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        elements.append(Element(name: name, attrs: attributes))
        stack.append(elements.count - 1)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let i = stack.last { elements[i].text += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }
}
#endif
