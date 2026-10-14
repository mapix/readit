import XCTest
@testable import Readit

final class DocConverterTests: XCTestCase {
    func testEPUBChaptersImagesMetadata() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("readit-epub-test-\(UUID().uuidString)", isDirectory: true)
        let book = tmp.appendingPathComponent("book", isDirectory: true)
        try fm.createDirectory(at: book.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: book.appendingPathComponent("OEBPS/img"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        func w(_ p: String, _ s: String) throws { try s.write(to: book.appendingPathComponent(p), atomically: true, encoding: .utf8) }
        try w("mimetype", "application/epub+zip")
        try w("META-INF/container.xml", #"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#)
        try w("OEBPS/content.opf", #"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>测试之书</dc:title><dc:creator>作者甲</dc:creator></metadata><manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>"#)
        try w("OEBPS/ch1.xhtml", #"<html><body><h1>第一章</h1><img src="img/a.png"/><script>bad()</script></body></html>"#)
        try w("OEBPS/ch2.xhtml", #"<html><body><h1>Chapter 2</h1></body></html>"#)
        let epub = tmp.appendingPathComponent("t.epub")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = book
        zip.arguments = ["-qr", epub.path, "mimetype", "META-INF", "OEBPS"]
        try zip.run(); zip.waitUntilExit()
        let work = tmp.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let c = try EPUB.convert(epub, workDir: work)
        XCTAssertEqual(c.title, "测试之书")
        XCTAssertEqual(c.author, "作者甲")
        XCTAssertTrue(c.body.contains("第一章") && c.body.contains("Chapter 2"))
        XCTAssertFalse(c.body.contains("bad()"))
        XCTAssertTrue(c.body.contains("/OEBPS/img/a.png"))
    }

    func testMarkdownHelpers() {
        XCTAssertEqual(DocConverter.markdownTitle("intro\n# Title Here\ntext"), "Title Here")
        XCTAssertEqual(DocConverter.absolutizeMarkdownImages("![x](pics/a.png) ![y](https://e.com/b.png)", base: URL(fileURLWithPath: "/docs")),
                       "![x](file:///docs/pics/a.png) ![y](https://e.com/b.png)")
    }
}
