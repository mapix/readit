import Foundation
import AppKit
import SwiftUI
import WebKit
import PDFKit

/// "从网页导入": turn an online article into a clean PDF and add it to the library.
///
/// 1. load the page in a real (offscreen) WKWebView — JS-rendered sites, cookies and logins work;
/// 2. scroll through it so lazy images load, then run Mozilla Readability + `readit-extract.js`, which keep only
///    the article (no nav, sidebars, comments, share bars, cookie banners…) and wrap it in Readlet's print CSS;
/// 3. download the article images with the page as Referer (hotlink-protected CDNs) next to an `index.html`;
/// 4. print that document to an A4 PDF and import it.
/// Direct links to PDF files are downloaded as-is. When a site needs a login / captcha, the page can be opened
/// in a visible window; after signing in, "提取正文并导入" continues from step 2.
@MainActor
final class WebImporter: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = WebImporter()

    enum Phase: Equatable { case idle, loading, extracting, images, rendering, done, failed }
    @Published var phase: Phase = .idle
    @Published var status = ""
    @Published var error = ""
    /// extraction failed in a way a visible browser can fix (login wall, captcha, too little text)
    @Published var canOpenInteractive = false
    @Published var lastURL = ""
    var running: Bool { ![.idle, .done, .failed].contains(phase) }

    private var web: WKWebView?
    private var host: NSWindow?
    private var browser: NSWindow?
    private var navWaiter: CheckedContinuation<Void, Error>?
    private var printWaiter: CheckedContinuation<Bool, Never>?
    private var targetNotebook: UUID?
    private var task: Task<Void, Never>?

    static let userAgentSuffix = "Version/18.0 Safari/605.1.15"
    static let pageSize = NSSize(width: 595.28, height: 841.89)   // A4 in points

    // MARK: entry points

    func start(_ raw: String, notebook: UUID? = nil) {
        guard !running else { return }
        guard let url = WebImporter.normalize(raw) else { fail(L("网址无效")); return }
        targetNotebook = notebook
        lastURL = url.absoluteString
        canOpenInteractive = false
        error = ""
        task = Task { await self.run(url) }
    }

    /// local documents: EPUB, Markdown, Word/RTF, HTML, plain text → PDF (PDFs are imported as they are)
    private var fileQueue: [(URL, UUID?)] = []
    func startFile(_ url: URL, notebook: UUID? = nil) {
        guard !running else { fileQueue.append((url, notebook)); return }
        targetNotebook = notebook
        lastURL = url.absoluteString
        canOpenInteractive = false
        error = ""
        task = Task { await self.runFile(url) }
    }

    private func runFile(_ url: URL) async {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent
        do {
            if ext == "pdf" { finishImport(url, source: nil, title: title); return }
            phase = .loading; status = LF("正在转换 %@…", url.lastPathComponent)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readlet-doc-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            if ["html", "htm", "xhtml", "webarchive"].contains(ext) {
                // a saved web page: same article extraction as for links
                let wv = makeWebView()
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false; w.contentView = wv; w.orderFrontRegardless()
                host = w; web = wv
                try await loadFile(wv, url, dir: url.deletingLastPathComponent())
                try await process(from: wv, url: url)
                return
            }
            phase = .extracting
            let doc = try await DocConverter.convert(url, workDir: dir)
            let html = try await buildPrintHTML(doc)
            let index = dir.appendingPathComponent("index.html")
            try html.write(to: index, atomically: true, encoding: .utf8)
            let pdf = try await printDocument(index: index, readAccess: URL(fileURLWithPath: "/"), name: doc.title.isEmpty ? title : doc.title)
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(pdf.lastPathComponent)
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: pdf, to: keep)
            finishImport(keep, source: nil, title: doc.title.isEmpty ? title : doc.title)
        } catch is CancellationError {
            teardown()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// wrap converted content in Readlet's print template (same CSS as web articles); Markdown is rendered with marked
    private func buildPrintHTML(_ d: DocConverter.Converted) async throws -> String {
        let wv = makeWebView()
        try await waitNavigation(wv) { wv.loadHTMLString("<html><body></body></html>", baseURL: nil) }
        let js = WebImporter.script("marked.umd") + "\n;\n" + WebImporter.script("readit-extract") + """
        \n;
        const content = isMarkdown ? marked.parse(body) : body;
        return window.__readit.build({ title: title, byline: author, site: "", date: "", url: source, lang: "", content: content });
        """
        let r = try await wv.callAsyncJavaScript(js, arguments: ["isMarkdown": d.markdown, "body": d.body, "title": d.title, "author": d.author, "source": d.source],
                                                 in: nil, contentWorld: .defaultClient)
        guard let html = r as? String, !html.isEmpty else { throw ImportError.message(L("页面脚本执行失败")) }
        return html
    }

    func cancel() {
        task?.cancel(); task = nil
        web?.stopLoading()
        navWaiter?.resume(throwing: CancellationError()); navWaiter = nil
        teardown()
        phase = .idle; status = ""
    }

    /// show the page in a normal window so the user can sign in / pass a check, then import from there
    func openInteractive() {
        guard let url = URL(string: lastURL) else { return }
        canOpenInteractive = false
        error = ""
        let wv = makeWebView()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("从网页导入") + " — " + (url.host ?? "")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WebImportBrowserView(web: wv, importer: self))
        w.center()
        w.makeKeyAndOrderFront(nil)
        browser = w
        web = wv
        phase = .idle
        status = L("登录或完成验证后，点击「提取正文并导入」")
        wv.load(URLRequest(url: url))
    }

    /// from the visible browser window: use whatever page it shows now
    func importFromBrowser() {
        guard let wv = web, !running else { return }
        task = Task {
            guard let u = wv.url ?? URL(string: self.lastURL) else { self.fail(L("网址无效")); return }
            do { try await self.process(from: wv, url: u) }
            catch { self.fail(error.localizedDescription) }
        }
    }

    // MARK: pipeline

    private func run(_ url: URL) async {
        do {
            if url.pathExtension.lowercased() == "pdf" { try await importPDFLink(url); return }
            phase = .loading; status = L("正在打开网页…")
            let wv = makeWebView()
            let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1100, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = wv
            w.orderFrontRegardless()                     // laid out & "visible" so lazy loaders and printing work
            host = w; web = wv
            try await load(wv, URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45))
            try await process(from: wv, url: url)
        } catch is CancellationError {
            teardown()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func process(from wv: WKWebView, url: URL) async throws {
        phase = .extracting; status = L("正在识别正文…")
        try await Task.sleep(nanoseconds: 1_200_000_000)     // late JS rendering
        var info = try await extract(wv)
        var blocked = WebImporter.looksBlocked(info.title) && (info.textLength ?? 0) < 1500
        // bot checks ("Just a moment…") often clear themselves in a real browser: give them a few seconds
        var tries = 0
        while (!info.ok || blocked) && tries < 3 && browser == nil {
            tries += 1
            status = L("等待页面加载完成…")
            try await Task.sleep(nanoseconds: 3_500_000_000)
            if let again = try? await extract(wv) { info = again }      // may be mid-redirect: just try again
            blocked = WebImporter.looksBlocked(info.title) && (info.textLength ?? 0) < 1500
        }
        guard info.ok, !blocked else {
            canOpenInteractive = browser == nil
            throw ImportError.message(blocked ? L("网站要求登录或人机验证") : L("没有识别到正文（可能需要登录，或页面不是文章）"))
        }
        // images
        phase = .images
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readlet-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = await downloadImages(info.imageURLs, referer: info.url, into: dir)
        var html = info.html
        for (i, u) in info.imageURLs.enumerated() {
            let src = files[i] ?? WebImporter.attr(u)
            html = html.replacingOccurrences(of: "src=\"readit-img-\(i)\"", with: "src=\"\(src)\"")
        }
        // a <base> would send relative image paths back to the site; the page URL is kept as metadata only
        html = html.replacingOccurrences(of: "<base href=", with: "<meta name=\"readit-source\" content=")
        let index = dir.appendingPathComponent("index.html")
        try html.write(to: index, atomically: true, encoding: .utf8)

        let name = WebImporter.fileName(info.title.isEmpty ? (url.host ?? "web") : info.title)
        let pdf = try await printDocument(index: index, readAccess: url.isFileURL ? URL(fileURLWithPath: "/") : dir, name: name)
        finishImport(pdf, source: url.isFileURL ? nil : info.url, title: info.title)
        try? FileManager.default.removeItem(at: dir)
    }

    /// render a prepared print document (index.html + assets) and print it to an A4 PDF next to it
    func printDocument(index: URL, readAccess: URL, name: String) async throws -> URL {
        phase = .rendering; status = L("正在生成 PDF…")
        let pv = makeWebView(width: 760)
        let pw = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 760, height: 1100), styleMask: [.borderless], backing: .buffered, defer: false)
        pw.isReleasedWhenClosed = false
        pw.contentView = pv
        pw.orderFrontRegardless()
        defer { pw.orderOut(nil) }
        try await loadFile(pv, index, dir: readAccess)
        try await waitForImages(pv)
        let pdf = index.deletingLastPathComponent().appendingPathComponent(WebImporter.fileName(name) + ".pdf")
        var ok = await printPDF(pv, window: pw, to: pdf)
        if !ok || (PDFDocument(url: pdf)?.pageCount ?? 0) == 0 { ok = try await slicedPDF(pv, to: pdf) }
        guard ok else { throw ImportError.message(L("生成 PDF 失败")) }
        return pdf
    }

    private func extract(_ wv: WKWebView) async throws -> Extracted {
        try await primeLazyImages(wv)
        let body = WebImporter.extractorJS + "\nreturn window.__readitExtract();"
        guard !WebImporter.extractorJS.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(";") else {
            throw ImportError.message(L("页面脚本执行失败") + "：readit-extract.js not found")
        }
        // isolated content world first: shares the DOM but not the page's JS and is not subject to its
        // Trusted Types / CSP rules; the page world is the fallback
        var problems: [String] = []
        for world in [WKContentWorld.defaultClient, WKContentWorld.page] {
            let name = world == .page ? "page" : "client"
            do {
                let r = try await wv.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)
                guard let json = r as? String else { problems.append("\(name): result \(String(describing: type(of: r)))"); continue }
                if let info = Extracted(json: json) {
                    WebImporter.log("extract[\(name)] ok=\(info.ok) reason=\(info.reason ?? "") title=\(info.title) chars=\(info.textLength ?? 0) images=\(info.imageURLs.count) url=\(info.url)")
                    if info.ok || world == .page { return info }
                    problems.append("\(name): \(info.reason ?? "not ok")")
                    continue
                }
                problems.append("\(name): bad JSON (\(json.count) chars) \(json.prefix(120))")
            } catch {
                problems.append("\(name): \(error.localizedDescription) \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? "")")
            }
        }
        // last resort: classic evaluateJavaScript in the page world
        do {
            let r = try await wv.evaluateJavaScript(WebImporter.extractorJS + "\nwindow.__readitExtract();")
            if let json = r as? String, let info = Extracted(json: json) {
                WebImporter.log("extract[eval] ok=\(info.ok) reason=\(info.reason ?? "") title=\(info.title)")
                return info
            }
            problems.append("eval: result \(String(describing: type(of: r)))")
        } catch {
            problems.append("eval: \(error.localizedDescription) \((error as NSError).userInfo["WKJavaScriptExceptionMessage"] ?? "")")
        }
        WebImporter.log("extract failed: " + problems.joined(separator: " ; "))
        throw ImportError.message(L("页面脚本执行失败") + "：" + (problems.last ?? ""))
    }

    /// ~/Library/Logs/Readlet/web-import.log — what happened on the last imports (for bug reports)
    static func log(_ s: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Readlet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("web-import.log")
        let line = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: f) }
        print("WEBIMPORT", s)
    }

    private func importPDFLink(_ url: URL) async throws {
        phase = .loading; status = L("正在下载 PDF…")
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebImporter.userAgentSuffix, forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { throw ImportError.message(L("下载失败")) }
        let name = WebImporter.fileName(url.deletingPathExtension().lastPathComponent)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        guard PDFDocument(url: dst) != nil else { throw ImportError.message(L("链接不是有效的 PDF")) }
        finishImport(dst, source: url.absoluteString, title: name)
    }

    private func finishImport(_ pdf: URL, source: String?, title: String) {
        if let nb = targetNotebook { Store.shared.currentNotebookId = nb }
        let id = Store.shared.importPDF(pdf, open: true)
        if let id, let source { Store.shared.setSource(id, source) }
        teardown()
        phase = id == nil ? .failed : .done
        status = id == nil ? "" : LF("已导入：%@", title)
        if id == nil { error = L("导入失败") }
        nextQueued()
    }

    private func nextQueued() {
        guard !fileQueue.isEmpty else { return }
        let (u, nb) = fileQueue.removeFirst()
        DispatchQueue.main.async { self.startFile(u, notebook: nb) }
    }

    private func fail(_ m: String) {
        teardown(keepBrowser: true)
        phase = .failed; status = ""; error = m
        nextQueued()
    }

    private func teardown(keepBrowser: Bool = false) {
        host?.orderOut(nil); host = nil
        if !keepBrowser { browser?.close(); browser = nil }
        if browser == nil { web = nil }
    }

    // MARK: web view plumbing

    private func makeWebView(width: CGFloat = 1100) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()                 // keep logins between imports
        cfg.applicationNameForUserAgent = WebImporter.userAgentSuffix
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1400), configuration: cfg)
        wv.navigationDelegate = self
        return wv
    }

    private var navToken = UUID()

    /// resolves on didFinish / failure, or after 30 s for pages that never finish (endless trackers)
    private weak var navTarget: WKWebView?
    func waitNavigation(_ wv: WKWebView, _ start: () -> Void) async throws {
        let token = UUID(); navToken = token; navTarget = wv
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navWaiter = c
            start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.navToken == token, let w = self.navWaiter else { return }
                self.navWaiter = nil; w.resume()
            }
        }
    }

    private func load(_ wv: WKWebView, _ req: URLRequest) async throws {
        try await waitNavigation(wv) { wv.load(req) }
    }

    private func loadFile(_ wv: WKWebView, _ file: URL, dir: URL) async throws {
        try await waitNavigation(wv) { wv.loadFileURL(file, allowingReadAccessTo: dir) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in if webView === self.navTarget, let w = self.navWaiter { self.navWaiter = nil; w.resume() } }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }      // redirects / replaced loads
        Task { @MainActor in if webView === self.navTarget, let w = self.navWaiter { self.navWaiter = nil; w.resume(throwing: error) } }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }      // redirects / replaced loads
        Task { @MainActor in if webView === self.navTarget, let w = self.navWaiter { self.navWaiter = nil; w.resume(throwing: error) } }
    }

    /// scroll in steps driven from here (page timers may be throttled offscreen) so lazy loaders fire
    private func primeLazyImages(_ wv: WKWebView) async throws {
        let h = (try? await wv.evaluateJavaScript("Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight)") as? Double) ?? 0
        var y = 0.0, steps = 0
        while y < h && steps < 80 {
            try Task.checkCancellation()
            y += 900; steps += 1
            _ = try? await wv.evaluateJavaScript("window.scrollTo(0, \(Int(y))); 0")
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        _ = try? await wv.evaluateJavaScript("window.scrollTo(0, 0); 0")
        try await Task.sleep(nanoseconds: 600_000_000)
    }

    private func waitForImages(_ wv: WKWebView) async throws {
        for _ in 0..<60 {
            try Task.checkCancellation()
            let done = (try? await wv.evaluateJavaScript("Array.from(document.images).every(function(i){return i.complete})") as? Bool) ?? true
            if done { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func downloadImages(_ urls: [String], referer: String, into dir: URL) async -> [Int: String] {
        guard !urls.isEmpty else { return [:] }
        status = LF("正在下载图片 %d 张…", urls.count)
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) " + WebImporter.userAgentSuffix
        var out: [Int: String] = [:]
        @Sendable func fetch(_ i: Int, _ s: String) async -> (Int, String?) {
            guard let u = URL(string: s) else { return (i, nil) }
            var req = URLRequest(url: u, timeoutInterval: 25)
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
            guard let r = try? await URLSession.shared.data(for: req),
                  let http = r.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  r.0.count > 64, r.0.count < 30_000_000 else { return (i, nil) }
            let data = r.0
            let name = "img-\(i).\(WebImporter.imageExtension(mime: http.mimeType, url: u, data: data))"
            do { try data.write(to: dir.appendingPathComponent(name)) } catch { return (i, nil) }
            return (i, name)
        }
        await withTaskGroup(of: (Int, String?).self) { g in
            var next = 0
            while next < min(6, urls.count) { let i = next; g.addTask { await fetch(i, urls[i]) }; next += 1 }
            while let r = await g.next() {
                if let name = r.1 { out[r.0] = name }
                if next < urls.count { let i = next; g.addTask { await fetch(i, urls[i]) }; next += 1 }
            }
        }
        return out
    }

    // MARK: PDF output

    /// paginated A4 via the WebKit print path (honours page-break CSS)
    private func printPDF(_ wv: WKWebView, window: NSWindow, to url: URL) async -> Bool {
        let pi = NSPrintInfo(dictionary: [
            NSPrintInfo.AttributeKey.jobDisposition: NSPrintInfo.JobDisposition.save,
            NSPrintInfo.AttributeKey.jobSavingURL: url,
        ])
        pi.paperSize = WebImporter.pageSize
        pi.topMargin = 46; pi.bottomMargin = 50; pi.leftMargin = 46; pi.rightMargin = 46
        pi.horizontalPagination = .fit
        pi.verticalPagination = .automatic
        pi.isHorizontallyCentered = true
        pi.isVerticallyCentered = false
        pi.orientation = .portrait
        let op = wv.printOperation(with: pi)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = wv.bounds
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            printWaiter = c
            op.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    @objc private func printOperationDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        let w = printWaiter; printWaiter = nil
        w?.resume(returning: success)
    }

    /// fallback: one tall PDF from WebKit, cut into A4-proportioned pages
    private func slicedPDF(_ wv: WKWebView, to url: URL) async throws -> Bool {
        let data = try await wv.pdf(configuration: WKPDFConfiguration())
        guard let tall = PDFDocument(data: data), let page = tall.page(at: 0) else { return false }
        let b = page.bounds(for: .mediaBox)
        let sliceH = b.width * WebImporter.pageSize.height / WebImporter.pageSize.width
        let out = PDFDocument()
        var top = b.maxY, k = 0
        while top > b.minY + 1 {
            guard let p = page.copy() as? PDFPage else { break }
            let r = CGRect(x: b.minX, y: top - sliceH, width: b.width, height: sliceH)
            p.setBounds(r, for: .mediaBox); p.setBounds(r, for: .cropBox)
            out.insert(p, at: k); k += 1
            top -= sliceH
        }
        return out.pageCount > 0 && out.write(to: url)
    }

    // MARK: helpers

    struct Extracted: Decodable {
        var ok: Bool
        var reason: String?
        var title: String
        var byline: String?
        var site: String?
        var date: String?
        var url: String
        var textLength: Int?
        var imageURLs: [String]
        var html: String

        /// lenient: JSONSerialization accepts what strict decoders reject; missing fields get defaults
        init?(json: String) {
            guard let d = json.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) as? [String: Any] else { return nil }
            ok = o["ok"] as? Bool ?? false
            reason = o["reason"] as? String
            title = o["title"] as? String ?? ""
            byline = o["byline"] as? String
            site = o["site"] as? String
            date = o["date"] as? String
            url = o["url"] as? String ?? ""
            textLength = (o["textLength"] as? NSNumber)?.intValue
            imageURLs = o["imageURLs"] as? [String] ?? []
            html = o["html"] as? String ?? ""
        }

        enum CodingKeys: String, CodingKey { case ok, reason, title, byline, site, date, url, textLength, imageURLs, html }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
            reason = try? c.decode(String.self, forKey: .reason)
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            byline = try? c.decode(String.self, forKey: .byline)
            site = try? c.decode(String.self, forKey: .site)
            date = try? c.decode(String.self, forKey: .date)
            url = (try? c.decode(String.self, forKey: .url)) ?? ""
            textLength = try? c.decode(Int.self, forKey: .textLength)
            imageURLs = (try? c.decode([String].self, forKey: .imageURLs)) ?? []
            html = (try? c.decode(String.self, forKey: .html)) ?? ""
        }
    }

    enum ImportError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    nonisolated static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let u = URL(string: s) ?? URL(string: s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let h = u.host, h.contains(".") || h == "localhost" else { return nil }
        return u
    }

    nonisolated static func looksBlocked(_ title: String) -> Bool {
        title.range(of: "(安全验证|人机验证|验证码|请登录|登录|请稍候|Security Verification|Just a moment|Please wait|Checking your browser|Attention Required|Access denied|captcha|Sign in|Log in)", options: [.regularExpression, .caseInsensitive]) != nil
            && title.count < 40
    }

    nonisolated static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let s = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let t = String(s.prefix(120))
        return t.isEmpty ? "Web Article" : t
    }

    nonisolated static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated static func imageExtension(mime: String?, url: URL, data: Data) -> String {
        switch (mime ?? "").lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/avif": return "avif"
        case "image/heic": return "heic"
        default: break
        }
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        if let s = String(data: data.prefix(256), encoding: .utf8), s.contains("<svg") { return "svg" }
        let e = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"].contains(e) ? e : "jpg"
    }

    /// a bundled script from Resources/web (app bundle, or the source tree when run from `swift run`)
    static func script(_ name: String) -> String {
        if let u = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "web"), let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/web/\(name).js")
        return (try? String(contentsOf: src, encoding: .utf8)) ?? ""
    }
    /// Readability + Readlet's extractor
    static let extractorJS: String = script("Readability") + "\n;\n" + script("readit-extract") + "\n;"
}

// MARK: - UI

/// small panel: paste a link, import; shows progress and errors
struct WebImportView: View {
    @ObservedObject var w = WebImporter.shared
    @State var url = ""
    var notebook: UUID?
    var initialURL: String? = nil
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("从网页导入"), systemImage: "globe").font(.headline)
            Text(L("粘贴文章链接，Readlet 会提取正文（去掉导航、侧栏、评论、广告等），排版成 PDF 加入文档库。也支持直接下载 PDF 链接。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://", text: $url)
                .textFieldStyle(.roundedBorder)
                .onSubmit { go() }
                .disabled(w.running)
            if w.running || !w.status.isEmpty {
                HStack(spacing: 8) {
                    if w.running { ProgressView().controlSize(.small) }
                    else if w.phase == .done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text(w.status).font(.callout).lineLimit(2)
                }
            }
            if !w.error.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(w.error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                    if w.canOpenInteractive {
                        Button(L("在窗口中打开（登录或验证后导入）")) { w.openInteractive(); close() }
                    }
                }
            }
            HStack {
                Spacer()
                if w.running { Button(L("取消")) { w.cancel() } }
                else { Button(w.phase == .done ? L("完成") : L("取消")) { close() }.keyboardShortcut(.cancelAction) }
                Button(L("导入")) { go() }.keyboardShortcut(.defaultAction).disabled(w.running || url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear {
            if w.running { return }
            w.phase = .idle; w.status = ""; w.error = ""
            if let s = initialURL { url = s; return }
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               s.hasPrefix("http"), !s.contains(" "), s.count < 2000 { url = s }
        }
        .onChange(of: w.phase) { _, p in if p == .done { DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { close() } } }
    }

    func go() { w.start(url, notebook: notebook) }
}

/// visible browser used when the site needs a login / captcha
struct WebImportBrowserView: View {
    let web: WKWebView
    @ObservedObject var importer: WebImporter
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text(importer.error.isEmpty ? importer.status : importer.error).font(.callout).lineLimit(1)
                    .foregroundStyle(importer.error.isEmpty ? Color.secondary : Color.orange)
                Spacer()
                if importer.running { ProgressView().controlSize(.small) }
                Button(L("提取正文并导入")) { importer.importFromBrowser() }
                    .keyboardShortcut(.defaultAction).disabled(importer.running)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            WebViewHost(web: web)
        }
    }
}

struct WebViewHost: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

/// floating panel host for WebImportView (works from the menu bar command too)
@MainActor
enum WebImportPanel {
    private static var panel: NSPanel?
    static func show(notebook: UUID? = nil, url: String? = nil) {
        if let p = panel { p.makeKeyAndOrderFront(nil); return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.isFloatingPanel = true
        p.contentView = NSHostingView(rootView: WebImportView(notebook: notebook, initialURL: url, close: { close() }))
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
    static func close() { panel?.close(); panel = nil }
}
