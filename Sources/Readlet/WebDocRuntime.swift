import Foundation
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - Live Interactive Web Document Controller

/// Payload sent from injected JS when the user selects text in a live web document.
struct WebSelectionPayload: Codable, Equatable {
    var text: String
    var sectionIndex: Int
    var sectionId: String?
    var sectionTitle: String?
    var blockId: String?
    var exact: String
    var prefix: String
    var suffix: String
    var progressPermille: Int
    /// Client-coordinate bounding rect `[x, y, width, height]` of the selection
    var clientRect: [Double]?
}

/// Payload sent from injected JS when resolving a rubber-band box selection (`areaMode`) to a semantic DOM block.
struct WebAreaAnchorPayload: Codable {
    var sectionIndex: Int
    var sectionId: String?
    var sectionTitle: String?
    var blockId: String?
    var relRect: [Double]? // [x, y, w, h] normalized 0..1 relative to block
    var progressPermille: Int
    var captionText: String?
}

/// Search match item in a live web document (`⌘F`).
struct WebFindMatch: Identifiable, Hashable {
    var id: Int { index }
    var index: Int
    var sectionIndex: Int
    var sectionTitle: String
    var snippet: String
}

/// Manages a live interactive `WKWebView` for a `.web` document (`Doc.kind == .web`),
/// bridging non-destructive DOM decluttering, cross-window/cross-device reading anchors,
/// in-place bilingual translation, text/chart annotations, TOC, Find, and AI Narration spotlighting.
@MainActor
final class WebDocController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let docId: UUID
    weak var reader: ReaderController?

    private(set) var webView: WKWebView!
    @Published var isLoading: Bool = false
    @Published var loadProgress: Double = 0.0
    @Published var pageTitle: String = ""
    @Published var currentURLString: String = ""
    @Published var cleanMode: Bool = true
    @Published var hiddenSelectors: [String] = []
    @Published var sections: [WebSection] = []
    @Published var currentSectionIndex: Int = 0
    @Published var currentSectionTitle: String = ""
    @Published var scrollFraction: Double = 0.0
    @Published var currentSelection: WebSelectionPayload? = nil
    @Published var loadError: String? = nil

    private var loadedResolvedURL: URL?
    private var mainNavigation: WKNavigation?
    private var pendingAnchorToRestore: WebReadingAnchor?
    private var pendingJumpCard: Card?
    private var translatedBlocks: [String: String] = [:] // blockId -> translation
    private var inFlightBlockIds: Set<String> = []
    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var hasCapturedCoverThumb = false

    init(docId: UUID, reader: ReaderController? = nil) {
        self.docId = docId
        self.reader = reader
        super.init()
        if let d = Store.shared.doc(docId) {
            self.cleanMode = d.webCleanMode
            self.hiddenSelectors = d.webHiddenSelectors
            self.pendingAnchorToRestore = d.webAnchor
            self.scrollFraction = d.webAnchor?.scrollFraction ?? 0.0
            self.currentSectionTitle = d.webAnchor?.sectionTitle ?? ""
            self.currentSectionIndex = d.webAnchor?.sectionIndex ?? d.readPage ?? 0
        }
        setupWebView()
    }

    deinit {
        progressObservation?.invalidate()
        titleObservation?.invalidate()
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif

        let ucc = WKUserContentController()
        let proxy = WeakScriptMessageHandler(target: self)
        for name in [
            "readletReady",
            "readletSections",
            "readletProgress",
            "readletSelection",
            "readletCardClick",
            "readletHideSelector",
            "readletNeedTranslation"
        ] {
            ucc.add(proxy, name: name)
        }

        let userScript = WKUserScript(
            source: Self.injectedRuntimeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        ucc.addUserScript(userScript)
        config.userContentController = ucc

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 960, height: 760), configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        #if os(macOS)
        wv.underPageBackgroundColor = .white
        #elseif os(iOS)
        wv.isOpaque = true
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        #endif
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let p = view.estimatedProgress
            Task { @MainActor [weak self] in
                self?.loadProgress = p
            }
        }
        titleObservation = wv.observe(\.title, options: [.new]) { [weak self] view, _ in
            let t = view.title ?? ""
            Task { @MainActor [weak self] in
                guard let self, !t.isEmpty else { return }
                self.pageTitle = t
            }
        }

        self.webView = wv
    }

    // MARK: - Loading & Clean Mode

    func loadIfNeeded() {
        guard let doc = Store.shared.doc(docId),
              let rawURL = doc.webURL else { return }
        guard let targetURL = WebURLResolver.resolvedLoadURL(originalURL: rawURL, cleanMode: doc.webCleanMode) else {
            self.loadError = L("无效的网页地址") + ": \(rawURL)"
            return
        }
        // Once the target URL is already loaded (or currently loading), never re-trigger navigation or reset scroll anchors on SwiftUI view updates.
        if loadedResolvedURL == targetURL, (webView.url != nil || isLoading) {
            return
        }
        self.cleanMode = doc.webCleanMode
        self.hiddenSelectors = doc.webHiddenSelectors
        loadedResolvedURL = targetURL
        currentURLString = targetURL.absoluteString
        loadError = nil
        isLoading = true
        let req = URLRequest(url: targetURL, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 45)
        mainNavigation = webView.load(req)
    }

    func reload() {
        if let currentAnchor = Store.shared.doc(docId)?.webAnchor {
            pendingAnchorToRestore = currentAnchor
        }
        loadedResolvedURL = nil
        loadIfNeeded()
    }

    /// Toggles automatic peripheral non-body content removal (`webCleanMode`) for this article while keeping the current reading anchor.
    func setCleanMode(_ enabled: Bool) {
        guard let doc = Store.shared.doc(docId), let rawURL = doc.webURL else { return }
        self.cleanMode = enabled
        Store.shared.setWebCleanMode(docId, enabled)

        let newTargetURL = WebURLResolver.resolvedLoadURL(originalURL: rawURL, cleanMode: enabled)
        // If cleanMode changes the outer host (e.g. huggingface.co/spaces/... <-> *.hf.space), reload at the new host while preserving anchor
        if let newTargetURL,
           let oldHost = loadedResolvedURL?.host?.lowercased(),
           let newHost = newTargetURL.host?.lowercased(),
           oldHost != newHost {
            if let currentAnchor = Store.shared.doc(docId)?.webAnchor {
                pendingAnchorToRestore = currentAnchor
            }
            loadedResolvedURL = newTargetURL
            currentURLString = newTargetURL.absoluteString
            isLoading = true
            mainNavigation = webView.load(URLRequest(url: newTargetURL))
            return
        }
        applyCleanModeToDOM()
    }

    func toggleCleanMode() -> Bool {
        let next = !cleanMode
        setCleanMode(next)
        return next
    }

    func clearCustomHiddenSelectors() {
        hiddenSelectors.removeAll()
        Store.shared.clearWebHiddenSelectors(docId)
        applyCleanModeToDOM()
    }

    func setEraseMode(_ enabled: Bool) {
        let js = "window.__readletLive && window.__readletLive.setEraseMode(\(enabled ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func applyCleanModeToDOM() {
        let selectorsJSON = (try? String(data: JSONEncoder().encode(hiddenSelectors), encoding: .utf8)) ?? "[]"
        let js = "window.__readletLive && window.__readletLive.setCleanMode(\(cleanMode ? "true" : "false"), \(selectorsJSON));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Bilingual Mode (`Variant`)

    func setVariant(_ variant: Variant) {
        let mode = (variant == .bilingual) ? "bilingual" : "original"
        let js = "window.__readletLive && window.__readletLive.setVariant('\(mode)');"
        webView.evaluateJavaScript(js, completionHandler: nil)
        if variant == .bilingual {
            translateVisibleAndNearbySections(centerSection: currentSectionIndex)
        }
    }

    func translateVisibleAndNearbySections(centerSection: Int) {
        let total = max(1, sections.count)
        var indices: [Int] = []
        for idx in max(0, centerSection - 1)...min(total - 1, centerSection + 2) {
            indices.append(idx)
        }
        for idx in indices {
            translateSection(idx)
        }
    }

    func translateAllSections() {
        for sec in sections {
            translateSection(sec.index)
        }
    }

    func retranslateSection(_ sectionIndex: Int) {
        let secBlockIds = Set(sections.first(where: { $0.index == sectionIndex })?.blockIds ?? [])
        for bid in secBlockIds {
            translatedBlocks.removeValue(forKey: bid)
        }
        translateSection(sectionIndex, forceRetranslate: true)
    }

    func translateSection(_ sectionIndex: Int, forceRetranslate: Bool = false) {
        let js = "window.__readletLive ? JSON.stringify(window.__readletLive.getTranslatableBlocks(\(sectionIndex))) : '[]'"
        webView.evaluateJavaScript(js) { [weak self] res, _ in
            guard let self,
                  let jsonStr = res as? String,
                  let data = jsonStr.data(using: .utf8),
                  let items = try? JSONDecoder().decode([[String: String]].self, from: data),
                  !items.isEmpty else { return }
            Task { @MainActor [weak self] in
                await self?.performBlockTranslations(items, forceRetranslate: forceRetranslate)
            }
        }
    }

    private func performBlockTranslations(_ items: [[String: String]], forceRetranslate: Bool) async {
        guard let ses = Store.shared.session(docId) else { return }
        var cachedToApply: [String: String] = [:]
        var pendingItems: [(id: String, text: String)] = []

        for item in items {
            guard let bid = item["id"], let text = item["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty, !text.isEmpty else { continue }
            if !forceRetranslate, let mem = translatedBlocks[bid] {
                cachedToApply[bid] = mem
                continue
            }
            if !forceRetranslate, let diskCached = ses.cachedTranslation(for: text) {
                translatedBlocks[bid] = diskCached
                cachedToApply[bid] = diskCached
                continue
            }
            guard !inFlightBlockIds.contains(bid), Translator.needsTranslation(text) else { continue }
            inFlightBlockIds.insert(bid)
            pendingItems.append((id: bid, text: text))
        }

        if !cachedToApply.isEmpty {
            injectBlockTranslationsIntoDOM(cachedToApply)
        }
        guard !pendingItems.isEmpty else { return }

        // Translate in batches of up to 8 paragraphs to keep visual feedback responsive
        let batchSize = 8
        for start in stride(from: 0, to: pendingItems.count, by: batchSize) {
            let slice = Array(pendingItems[start..<min(pendingItems.count, start + batchSize)])
            let texts = slice.map(\.text)
            if forceRetranslate {
                ses.invalidateCachedTranslations(for: texts)
            }
            let translated = await ses.translateWebTexts(texts)
            var batchMap: [String: String] = [:]
            for (idx, pair) in slice.enumerated() {
                inFlightBlockIds.remove(pair.id)
                if idx < translated.count {
                    let tr = translated[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tr.isEmpty {
                        translatedBlocks[pair.id] = tr
                        batchMap[pair.id] = tr
                    }
                }
            }
            if !batchMap.isEmpty {
                injectBlockTranslationsIntoDOM(batchMap)
            }
        }
    }

    private func injectBlockTranslationsIntoDOM(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__readletLive && window.__readletLive.applyTranslations(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Navigation, Anchors & Scroll Coordination

    func scrollToSection(_ sectionIndex: Int) {
        let clamped = max(0, min(sectionIndex, max(0, sections.count - 1)))
        currentSectionIndex = clamped
        if clamped < sections.count {
            currentSectionTitle = sections[clamped].title
        }
        let js = "window.__readletLive && window.__readletLive.scrollToSection(\(clamped));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func scrollToAnchor(_ anchor: WebReadingAnchor, initialOnly: Bool = false) {
        if isLoading {
            pendingAnchorToRestore = anchor
            return
        }
        pendingAnchorToRestore = nil
        guard let data = try? JSONEncoder().encode(anchor),
              let json = String(data: data, encoding: .utf8) else { return }
        let fn = initialOnly ? "restoreInitialAnchor" : "restoreAnchor"
        let js = "window.__readletLive && window.__readletLive.\(fn)(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func restoreAnchor(_ anchor: WebReadingAnchor) {
        let clamped = min(1.0, max(0.0, anchor.scrollFraction))
        self.scrollFraction = clamped
        reader?.webScrollFraction = clamped
        scrollToAnchor(anchor, initialOnly: false)
    }

    func seekToFraction(_ fraction: Double) {
        let clamped = min(1.0, max(0.0, fraction))
        self.scrollFraction = clamped
        reader?.webScrollFraction = clamped
        let js = "window.__readletLive && window.__readletLive.seekToFraction(\(clamped));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func stepScroll(direction: Int) {
        let js = "window.scrollBy({ top: Math.round(window.innerHeight * 0.78) * (\(direction)), behavior: 'smooth' });"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func zoom(delta: Double) {
        if delta == 0 {
            webView.pageZoom = 1.0
        } else {
            webView.pageZoom = max(0.6, min(2.4, webView.pageZoom + CGFloat(delta)))
        }
    }

    func clearSelection() {
        currentSelection = nil
        webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges();", completionHandler: nil)
    }

    // MARK: - Cards & Annotations

    private struct WebDOMCardRepresentation: Codable {
        var id: String
        var colorHex: String
        var bgRgba: String
        var hasComment: Bool
        var isImage: Bool
        var sectionId: String?
        var blockId: String?
        var exact: String
        var prefix: String
        var suffix: String
        var relRect: [Double]?
    }

    func refreshAnnotations() {
        let cards = Store.shared.lib.cards.filter { $0.docId == docId }
        let domCards: [WebDOMCardRepresentation] = cards.map { c in
            let col = highlightColors[c.color % highlightColors.count]
            #if os(macOS)
            let srgb = col.usingColorSpace(.sRGB) ?? col
            let r = Int((srgb.redComponent * 255).rounded())
            let g = Int((srgb.greenComponent * 255).rounded())
            let b = Int((srgb.blueComponent * 255).rounded())
            #else
            var rf: CGFloat = 1, gf: CGFloat = 0.89, bf: CGFloat = 0.36, af: CGFloat = 1
            col.getRed(&rf, green: &gf, blue: &bf, alpha: &af)
            let r = Int((rf * 255).rounded())
            let g = Int((gf * 255).rounded())
            let b = Int((bf * 255).rounded())
            #endif
            let hex = String(format: "#%02X%02X%02X", r, g, b)
            let rgba = "rgba(\(r), \(g), \(b), 0.38)"
            let rel: [Double]? = c.webAnchor?.relRect.map {
                [Double($0.origin.x), Double($0.origin.y), Double($0.size.width), Double($0.size.height)]
            }
            return WebDOMCardRepresentation(
                id: c.id.uuidString,
                colorHex: hex,
                bgRgba: rgba,
                hasComment: !c.commentText.isEmpty,
                isImage: c.isImage,
                sectionId: c.webAnchor?.sectionId,
                blockId: c.webAnchor?.blockId,
                exact: c.webAnchor?.exact ?? c.text,
                prefix: c.webAnchor?.prefix ?? "",
                suffix: c.webAnchor?.suffix ?? "",
                relRect: rel
            )
        }
        guard let data = try? JSONEncoder().encode(domCards),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.__readletLive && window.__readletLive.renderCards(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func jumpToCard(_ card: Card) {
        pendingJumpCard = card
        let cid = card.id.uuidString
        let blockId = card.webAnchor?.blockId ?? ""
        let secId = card.webAnchor?.sectionId ?? ""
        let perm = card.webAnchor?.progressPermille ?? -1
        let secIdx = card.page
        let js = "window.__readletLive && window.__readletLive.jumpToCard('\(cid)', '\(blockId)', '\(secId)', \(perm), \(secIdx));"
        webView.evaluateJavaScript(js) { [weak self] found, _ in
            if let ok = found as? Bool, ok {
                self?.pendingJumpCard = nil
            }
        }
    }

    // MARK: - Area Capture & Snapshots (Interactive Charts -> MindMap & Visual Q&A)

    /// Captures a cropped snapshot of the live `WKWebView` for a view-space rectangle (`rectInWebView`, top-left origin or AppKit bottom-left converted)
    /// and resolves its semantic DOM anchor (`blockId` + normalized `relRect`).
    func captureAreaExcerpt(viewRect: CGRect, isFlippedAppKitRect: Bool = true) async -> (imageData: Data?, anchor: WebCardAnchor, sectionIndex: Int)? {
        let bounds = webView.bounds
        guard bounds.width > 10, bounds.height > 10 else { return nil }
        let topDownRect: CGRect = {
            if isFlippedAppKitRect {
                // Convert AppKit bottom-left origin to WKWebView top-left origin
                return CGRect(
                    x: viewRect.minX,
                    y: bounds.height - viewRect.maxY,
                    width: viewRect.width,
                    height: viewRect.height
                ).intersection(bounds)
            }
            return viewRect.intersection(bounds)
        }()
        guard topDownRect.width > 8, topDownRect.height > 8 else { return nil }

        let normX = Double(topDownRect.minX / bounds.width)
        let normY = Double(topDownRect.minY / bounds.height)
        let normW = Double(topDownRect.width / bounds.width)
        let normH = Double(topDownRect.height / bounds.height)

        let anchorPayload: WebAreaAnchorPayload? = await withCheckedContinuation { cont in
            let js = "window.__readletLive ? JSON.stringify(window.__readletLive.resolveAreaBox(\(normX), \(normY), \(normW), \(normH))) : null"
            webView.evaluateJavaScript(js) { res, _ in
                if let str = res as? String,
                   let data = str.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(WebAreaAnchorPayload.self, from: data) {
                    cont.resume(returning: decoded)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }

        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = topDownRect
        let pngData: Data? = await withCheckedContinuation { cont in
            webView.takeSnapshot(with: snapConfig) { image, _ in
                guard let image else {
                    cont.resume(returning: nil)
                    return
                }
                #if os(macOS)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    cont.resume(returning: png)
                } else {
                    cont.resume(returning: nil)
                }
                #elseif os(iOS)
                cont.resume(returning: image.pngData())
                #endif
            }
        }

        let relRect: CGRect? = {
            guard let r = anchorPayload?.relRect, r.count == 4 else {
                return CGRect(x: normX, y: normY, width: normW, height: normH)
            }
            return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }()
        let secIdx = anchorPayload?.sectionIndex ?? currentSectionIndex
        let webCardAnchor = WebCardAnchor(
            sectionId: anchorPayload?.sectionId,
            sectionTitle: anchorPayload?.sectionTitle ?? currentSectionTitle,
            blockId: anchorPayload?.blockId,
            exact: anchorPayload?.captionText ?? "",
            prefix: "",
            suffix: "",
            relRect: relRect,
            progressPermille: anchorPayload?.progressPermille ?? Int((scrollFraction * 1000.0).rounded())
        )
        return (pngData, webCardAnchor, secIdx)
    }

    /// Captures a JPEG snapshot of the currently visible interactive viewport (used for cover thumbnail `thumb.png` and multimodal AI Narration / Visual Q&A).
    func captureViewportJPEG(maxSide: CGFloat = 1120) async -> Data? {
        guard webView.bounds.width > 20, webView.bounds.height > 20 else { return nil }
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = webView.bounds
        snapConfig.snapshotWidth = NSNumber(value: Double(min(maxSide, max(webView.bounds.width, 640))))
        return await withCheckedContinuation { cont in
            webView.takeSnapshot(with: snapConfig) { image, _ in
                guard let image else {
                    cont.resume(returning: nil)
                    return
                }
                #if os(macOS)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) {
                    cont.resume(returning: jpg)
                } else {
                    cont.resume(returning: nil)
                }
                #elseif os(iOS)
                cont.resume(returning: image.jpegData(compressionQuality: 0.78))
                #endif
            }
        }
    }

    private func captureCoverThumbnailIfNeeded() {
        guard !hasCapturedCoverThumb else { return }
        let thumbURL = Paths.docDir(docId).appendingPathComponent("thumb.png")
        guard !FileManager.default.fileExists(atPath: thumbURL.path) else {
            hasCapturedCoverThumb = true
            return
        }
        hasCapturedCoverThumb = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.webView.bounds.width > 40 else { return }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: self.webView.bounds.width, height: min(self.webView.bounds.height, self.webView.bounds.width * 1.32))
            cfg.snapshotWidth = 360
            self.webView.takeSnapshot(with: cfg) { image, _ in
                guard let image else { return }
                #if os(macOS)
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: thumbURL, options: .atomic)
                }
                #elseif os(iOS)
                if let png = image.pngData() {
                    try? png.write(to: thumbURL, options: .atomic)
                }
                #endif
            }
        }
    }

    // MARK: - In-Page Find (`⌘F`) & AI Narration Spotlight

    func findText(_ query: String) async -> [WebFindMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            clearFind()
            return []
        }
        guard let qData = try? JSONEncoder().encode(q),
              let qJSON = String(data: qData, encoding: .utf8) else { return [] }
        let js = "window.__readletLive ? JSON.stringify(window.__readletLive.findText(\(qJSON))) : '[]'"
        return await withCheckedContinuation { cont in
            webView.evaluateJavaScript(js) { res, _ in
                guard let str = res as? String,
                      let data = str.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    cont.resume(returning: [])
                    return
                }
                let matches: [WebFindMatch] = raw.compactMap { dict in
                    guard let idx = dict["index"] as? Int else { return nil }
                    let secIdx = dict["sectionIndex"] as? Int ?? 0
                    let secTitle = dict["sectionTitle"] as? String ?? ""
                    let snippet = dict["snippet"] as? String ?? ""
                    return WebFindMatch(index: idx, sectionIndex: secIdx, sectionTitle: secTitle, snippet: snippet)
                }
                cont.resume(returning: matches)
            }
        }
    }

    func jumpToFindMatch(_ index: Int) {
        let js = "window.__readletLive && window.__readletLive.jumpToFindMatch(\(index));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func clearFind() {
        let js = "window.__readletLive && window.__readletLive.clearFind();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func highlightNarration(sectionIndex: Int, quote: String, mentionsFigure: Bool) {
        let qJSON = (try? String(data: JSONEncoder().encode(quote), encoding: .utf8)) ?? "\"\""
        let js = "window.__readletLive && window.__readletLive.highlightNarration(\(sectionIndex), \(qJSON), \(mentionsFigure ? "true" : "false"));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func clearNarrationHighlight() {
        let js = "window.__readletLive && window.__readletLive.clearNarrationHighlight();"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate & WKUIDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard mainNavigation == nil || navigation == mainNavigation else { return }
        isLoading = true
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard mainNavigation == nil || navigation == mainNavigation else { return }
        isLoading = false
        if loadedResolvedURL == nil, let doc = Store.shared.doc(docId), let rawURL = doc.webURL {
            loadedResolvedURL = WebURLResolver.resolvedLoadURL(originalURL: rawURL, cleanMode: doc.webCleanMode)
        }
        currentURLString = webView.url?.absoluteString ?? currentURLString
        syncRuntimeState()
        captureCoverThumbnailIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard mainNavigation == nil || navigation == mainNavigation else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
        isLoading = false
        loadError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard mainNavigation == nil || navigation == mainNavigation else { return }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
        isLoading = false
        loadError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #elseif os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
        return nil
    }

    private func syncRuntimeState() {
        applyCleanModeToDOM()
        let v = reader?.variant ?? Store.shared.variant
        setVariant(v)
        refreshAnnotations()
        if let jump = pendingJumpCard {
            pendingJumpCard = nil
            jumpToCard(jump)
        } else if let anchor = pendingAnchorToRestore {
            pendingAnchorToRestore = nil
            scrollToAnchor(anchor, initialOnly: true)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "readletReady":
            syncRuntimeState()

        case "readletSections":
            guard let jsonStr = message.body as? String,
                  let data = jsonStr.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([WebSection].self, from: data) else { return }
            self.sections = decoded
            if let ses = Store.shared.session(docId) {
                ses.updateWebSections(decoded)
            }
            reader?.totalPages = max(1, decoded.count)
            if let jump = pendingJumpCard {
                pendingJumpCard = nil
                jumpToCard(jump)
            } else if let anchor = pendingAnchorToRestore {
                pendingAnchorToRestore = nil
                scrollToAnchor(anchor, initialOnly: true)
            }
            if (reader?.variant ?? Store.shared.variant) == .bilingual {
                translateVisibleAndNearbySections(centerSection: currentSectionIndex)
            }

        case "readletProgress":
            guard let dict = message.body as? [String: Any] else { return }
            let anchorId = dict["anchorId"] as? String ?? ""
            let intraOffset = dict["intraOffset"] as? Double ?? 0.0
            let frac = dict["scrollFraction"] as? Double ?? 0.0
            let secIdx = dict["sectionIndex"] as? Int ?? 0
            let secTitle = dict["sectionTitle"] as? String ?? ""
            let docTitle = dict["docTitle"] as? String

            self.scrollFraction = min(1.0, max(0.0, frac))
            self.currentSectionIndex = max(0, secIdx)
            self.currentSectionTitle = secTitle
            reader?.syncWebProgressFromDOM(
                sectionIndex: self.currentSectionIndex,
                sectionCount: max(1, sections.count),
                scrollFraction: self.scrollFraction,
                sectionTitle: secTitle
            )

            let anchor = WebReadingAnchor(
                anchorId: anchorId,
                intraOffset: intraOffset,
                scrollFraction: self.scrollFraction,
                sectionTitle: secTitle.isEmpty ? nil : secTitle,
                sectionIndex: self.currentSectionIndex
            )
            Store.shared.updateWebReadingProgress(
                docId: docId,
                anchor: anchor,
                sectionCount: sections.isEmpty ? nil : sections.count,
                discoveredTitle: docTitle
            )
            if (reader?.variant ?? Store.shared.variant) == .bilingual {
                translateVisibleAndNearbySections(centerSection: self.currentSectionIndex)
            }

        case "readletSelection":
            guard let jsonStr = message.body as? String,
                  let data = jsonStr.data(using: .utf8) else { return }
            if jsonStr == "null" || jsonStr.isEmpty {
                currentSelection = nil
                reader?.onWebSelectionChanged(nil)
                return
            }
            if let payload = try? JSONDecoder().decode(WebSelectionPayload.self, from: data) {
                if payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    currentSelection = nil
                    reader?.onWebSelectionChanged(nil)
                } else {
                    currentSelection = payload
                    reader?.onWebSelectionChanged(payload)
                }
            }

        case "readletCardClick":
            guard let dict = message.body as? [String: Any],
                  let idStr = dict["cardId"] as? String,
                  let cardId = UUID(uuidString: idStr),
                  let card = Store.shared.card(cardId) else { return }
            let x = dict["clientX"] as? Double ?? Double(webView.bounds.midX)
            let y = dict["clientY"] as? Double ?? Double(webView.bounds.midY)
            Store.shared.selectedCardId = card.id
            Store.shared.focusInMap(card.id)
            #if os(macOS)
            let ptRect = CGRect(x: CGFloat(x) - 12, y: CGFloat(y) - 12, width: 24, height: 24)
            reader?.openWebCard(card.id, anchorRect: ptRect)
            #endif

        case "readletHideSelector":
            guard let selector = message.body as? String, !selector.isEmpty else { return }
            if !hiddenSelectors.contains(selector) {
                hiddenSelectors.append(selector)
            }
            Store.shared.addWebHiddenSelector(docId, selector)
            applyCleanModeToDOM()

        case "readletNeedTranslation":
            if let secIdx = message.body as? Int {
                translateVisibleAndNearbySections(centerSection: secIdx)
            }

        default:
            break
        }
    }
}

/// Breaks the retain cycle between `WKUserContentController` and `WebDocController`.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(target: WKScriptMessageHandler) {
        self.target = target
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - SwiftUI Bridge for Live WebView

#if os(macOS)
struct LiveWebReaderRepresentable: NSViewRepresentable {
    @ObservedObject var webController: WebDocController

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let wv = webController.webView!
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        webController.loadIfNeeded()
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        webController.loadIfNeeded()
    }
}
#elseif os(iOS)
struct LiveWebReaderRepresentable: UIViewRepresentable {
    @ObservedObject var webController: WebDocController

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        let wv = webController.webView!
        wv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        webController.loadIfNeeded()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        webController.loadIfNeeded()
    }
}
#endif

// MARK: - Injected JavaScript Runtime (`readlet-live.js`)

extension WebDocController {
    static let injectedRuntimeJS: String = #"""
    (function() {
        if (window.__readletLive) return;

        const state = {
            cleanMode: true,
            customSelectors: [],
            declutterAppliedOnce: false,
            variant: 'original',
            eraseMode: false,
            sections: [],
            blockEls: new Map(),
            blockToSection: new Map(),
            translations: new Map(),
            cards: [],
            findMatches: [],
            lockedAnchor: null,
            isRestoringScroll: false,
            userHasScrolled: false,
            initialAnchorRestored: false,
            lastUserScrollTime: 0,
            hoveredEraseEl: null
        };

        ['wheel', 'touchmove', 'pointerdown', 'keydown'].forEach(evName => {
            window.addEventListener(evName, function(ev) {
                if (evName === 'keydown') {
                    const k = ev.key || '';
                    if (!['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', ' ', 'Home', 'End'].includes(k)) return;
                }
                state.userHasScrolled = true;
                state.lastUserScrollTime = Date.now();
            }, { passive: true, capture: true });
        });

        function post(name, body) {
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[name]) {
                    window.webkit.messageHandlers[name].postMessage(body);
                }
            } catch (e) {}
        }

        function ensureStyles() {
            if (document.getElementById('readlet-live-style')) return;
            const st = document.createElement('style');
            st.id = 'readlet-live-style';
            st.textContent = `
                html[data-readlet-clean="on"] [data-readlet-clutter="1"],
                html[data-readlet-clean="on"] [data-readlet-user-hidden="1"],
                html[data-readlet-clean="on"] .table-of-contents,
                html[data-readlet-clean="on"] .toc-mobile-toggle,
                html[data-readlet-clean="on"] .toc-mobile-backdrop,
                html[data-readlet-clean="on"] .toc-mobile-sidebar {
                    display: none !important;
                }
                html[data-readlet-clean="on"] section.content-grid {
                    grid-template-columns: minmax(0, 780px) !important;
                    justify-content: center !important;
                }
                /* Prevent wide figures / embeds with solid --page-bg or mask-composite from occluding content during scroll */
                figure.viz {
                    background: transparent !important;
                    z-index: 1 !important;
                }
                figure.viz:before,
                figure.viz:after {
                    display: none !important;
                }
                .wide,
                .html-embed--wide,
                .full-width {
                    -webkit-mask: none !important;
                    mask: none !important;
                    z-index: 1 !important;
                }
                .readlet-bi-trans {
                    display: none;
                    margin: 6px 0 14px 0;
                    padding: 8px 12px;
                    border-left: 3px solid rgba(59, 130, 246, 0.65);
                    background: rgba(59, 130, 246, 0.055);
                    border-radius: 0 6px 6px 0;
                    font-size: 0.95em;
                    line-height: 1.68;
                    color: inherit;
                    opacity: 0.92;
                }
                html[data-readlet-variant="bilingual"] .readlet-bi-trans {
                    display: block;
                }
                mark.readlet-card-hl {
                    border-radius: 3px;
                    padding: 1px 0;
                    cursor: pointer;
                    color: inherit;
                    transition: filter 0.15s ease, outline 0.15s ease;
                }
                mark.readlet-card-hl:hover {
                    filter: brightness(0.93);
                }
                .readlet-card-badge {
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    margin-left: 3px;
                    padding: 0 4px;
                    font-size: 11px;
                    line-height: 1.3;
                    border-radius: 999px;
                    cursor: pointer;
                    vertical-align: middle;
                    user-select: none;
                }
                .readlet-area-badge {
                    position: absolute;
                    top: 8px;
                    right: 8px;
                    z-index: 40;
                    padding: 3px 8px;
                    font-size: 11px;
                    font-weight: 600;
                    border-radius: 999px;
                    color: #111;
                    box-shadow: 0 2px 8px rgba(0,0,0,0.18);
                    cursor: pointer;
                    user-select: none;
                }
                @keyframes readletPulse {
                    0% { outline: 3px solid rgba(59, 130, 246, 0.95); outline-offset: 4px; }
                    100% { outline: 3px solid rgba(59, 130, 246, 0.0); outline-offset: 10px; }
                }
                .readlet-jump-flash {
                    animation: readletPulse 1.5s ease-out 1;
                }
                .readlet-narr-active {
                    outline: 2.5px solid rgba(245, 158, 11, 0.88) !important;
                    outline-offset: 6px !important;
                    background-color: rgba(245, 158, 11, 0.07) !important;
                    border-radius: 6px;
                    transition: outline 0.25s ease, background-color 0.25s ease;
                }
                .readlet-erase-hover {
                    outline: 2px dashed rgba(239, 68, 68, 0.95) !important;
                    outline-offset: 2px !important;
                    background-color: rgba(239, 68, 68, 0.08) !important;
                    cursor: crosshair !important;
                }
                mark.readlet-find-hl {
                    background: rgba(250, 204, 21, 0.55);
                    color: inherit;
                    border-radius: 2px;
                }
                mark.readlet-find-hl.active {
                    background: rgba(249, 115, 22, 0.85);
                    color: #fff;
                    outline: 2px solid rgba(249, 115, 22, 0.9);
                }
            `;
            (document.head || document.documentElement).appendChild(st);
        }

        function hasInteractiveContent(el) {
            if (!el || !el.querySelector) return false;
            if (el.matches && el.matches('.viz, .viz-box, figure.viz, iframe, canvas')) return true;
            return !!el.querySelector('.viz, .viz-box, figure.viz, iframe[src*="viz"], canvas, video');
        }

        function detectMainRoots() {
            const roots = [];
            const mainEl = document.querySelector('main, article, [role="main"], .article-content, .post-content, .prose');
            if (mainEl) roots.push(mainEl);
            const heroEl = document.querySelector('header.hero, .hero-header, header:has(h1)');
            if (heroEl && !roots.includes(heroEl)) roots.unshift(heroEl);
            if (roots.length === 0 && document.body) {
                roots.push(document.body);
            }
            return roots;
        }

        // 1. Non-Destructive Peripheral Content Decluttering
        function applyDecluttering() {
            ensureStyles();
            document.documentElement.setAttribute('data-readlet-clean', state.cleanMode ? 'on' : 'off');
            document.querySelectorAll('[data-readlet-clutter]').forEach(el => el.removeAttribute('data-readlet-clutter'));
            document.querySelectorAll('[data-readlet-user-hidden]').forEach(el => el.removeAttribute('data-readlet-user-hidden'));

            if (!document.body) return;
            const roots = detectMainRoots();
            const protectedSet = new Set();
            roots.forEach(r => {
                protectedSet.add(r);
                let p = r.parentElement;
                while (p && p !== document.body && p !== document.documentElement) {
                    protectedSet.add(p);
                    p = p.parentElement;
                }
            });

            const clutterSelectors = [
                'body > nav',
                'body > footer',
                'body > aside',
                'header:not(.hero):not(:has(h1))',
                'nav[role="navigation"]',
                '[role="banner"]:not(.hero):not(:has(h1))',
                '[role="contentinfo"]',
                '.cookie-banner, .cookie-consent, #cookie-banner, [class*="cookie-"]',
                '.newsletter-signup, .share-bar, .social-share, .floating-share',
                '.ad-container, .ads-wrapper, .advertisement, [id^="google_ads"]'
            ];

            clutterSelectors.forEach(sel => {
                try {
                    document.querySelectorAll(sel).forEach(el => {
                        if (protectedSet.has(el)) return;
                        if (roots.some(r => el.contains(r) || r.contains(el))) return;
                        if (hasInteractiveContent(el)) return;
                        el.setAttribute('data-readlet-clutter', '1');
                    });
                } catch (e) {}
            });

            // Also hide direct body children that are outside the main article/hero spine and contain no main content
            if (roots.length > 0 && roots[0] !== document.body) {
                Array.from(document.body.children).forEach(ch => {
                    if (ch.tagName === 'SCRIPT' || ch.tagName === 'STYLE' || ch.tagName === 'LINK') return;
                    if (protectedSet.has(ch)) return;
                    if (roots.some(r => ch.contains(r) || r.contains(ch))) return;
                    if (hasInteractiveContent(ch)) return;
                    const tag = ch.tagName.toLowerCase();
                    if (tag === 'nav' || tag === 'footer' || tag === 'aside' || tag === 'header') {
                        ch.setAttribute('data-readlet-clutter', '1');
                    }
                });
            }

            // Apply per-article custom hidden selectors chosen by user
            (state.customSelectors || []).forEach(sel => {
                try {
                    document.querySelectorAll(sel).forEach(el => {
                        if (el !== document.body && el !== document.documentElement) {
                            el.setAttribute('data-readlet-user-hidden', '1');
                        }
                    });
                } catch (e) {}
            });
        }

        // 2. Cross-Window & Cross-Device Responsive Chart Scaling
        function fitWideVisualizations() {
            const availW = Math.max(280, document.documentElement.clientWidth - 28);
            const vizBoxes = document.querySelectorAll('figure.viz .viz-box, .viz-box');
            vizBoxes.forEach(box => {
                const iframe = box.querySelector('iframe');
                if (!iframe) return;
                // If the page's own runtime (e.g. moe-blogpost hoisted.js) already manages responsive scaling via CSS zoom + aspect-ratio,
                // only clear any negative marginLeft injected by viz-fit.js so we don't double-scale or lock stale heights during scroll.
                const pageManagesZoom = !!(iframe.style.zoom && iframe.style.zoom !== '' && iframe.style.zoom !== '1')
                    || !!(box.style.aspectRatio && box.hasAttribute('data-w'));
                if (pageManagesZoom) {
                    iframe.style.marginLeft = '0px';
                    return;
                }
                const declaredW = parseFloat(iframe.getAttribute('data-readlet-orig-w') || box.getAttribute('data-w') || iframe.getAttribute('width') || iframe.style.width || iframe.offsetWidth || '0');
                const declaredH = parseFloat(iframe.getAttribute('data-readlet-orig-h') || box.getAttribute('data-h') || iframe.getAttribute('height') || iframe.style.height || iframe.offsetHeight || '0');
                if (declaredW > 100 && !iframe.getAttribute('data-readlet-orig-w')) {
                    iframe.setAttribute('data-readlet-orig-w', String(declaredW));
                }
                if (declaredH > 40 && !iframe.getAttribute('data-readlet-orig-h')) {
                    iframe.setAttribute('data-readlet-orig-h', String(declaredH));
                }
                const targetW = parseFloat(iframe.getAttribute('data-readlet-orig-w') || declaredW);
                const targetH = parseFloat(iframe.getAttribute('data-readlet-orig-h') || declaredH);
                if (!targetW || targetW <= 0) return;

                if (targetW > availW) {
                    const scale = availW / targetW;
                    box.setAttribute('data-readlet-scaled', '1');
                    box.style.width = availW + 'px';
                    box.style.maxWidth = '100%';
                    box.style.overflow = 'hidden';
                    if (targetH > 0) {
                        box.style.height = Math.ceil(targetH * scale) + 'px';
                    }
                    iframe.style.width = targetW + 'px';
                    iframe.style.marginLeft = '0px';
                    iframe.style.transformOrigin = 'left top';
                    iframe.style.transform = `scale(${scale.toFixed(4)})`;
                } else if (box.getAttribute('data-readlet-scaled') === '1') {
                    box.removeAttribute('data-readlet-scaled');
                    box.style.width = '';
                    box.style.maxWidth = '';
                    box.style.overflow = '';
                    if (targetH > 0) {
                        box.style.height = targetH + 'px';
                    }
                    iframe.style.transform = '';
                    iframe.style.transformOrigin = '';
                }
            });
        }

        window.addEventListener('message', function(ev) {
            const d = ev && ev.data;
            if (d && d.moeviz) {
                const box = document.querySelector(`.viz-box[data-name="${d.moeviz}"]`);
                const iframe = box && box.querySelector('iframe');
                if (iframe) {
                    if (d.w) iframe.setAttribute('data-readlet-orig-w', String(d.w + 2));
                    if (d.h) iframe.setAttribute('data-readlet-orig-h', String(d.h + 2));
                }
                setTimeout(fitWideVisualizations, 25);
            }
        });

        // 3. Semantic Block Indexing & Section Discovery
        function indexSectionsAndBlocks() {
            const roots = detectMainRoots();
            const container = (roots.length === 1) ? roots[0] : document.body;
            if (!container) return;

            state.sections = [];
            state.blockEls.clear();
            state.blockToSection.clear();

            const docTitle = (document.querySelector('h1')?.innerText || document.title || '').trim();
            let currentSec = {
                index: 0,
                id: 'sec-0',
                title: docTitle || 'Introduction',
                depth: 1,
                textParts: [],
                blockIds: [],
                scrollFraction: 0.0,
                anchorEl: roots[0] || document.body
            };
            state.sections.push(currentSec);

            const selector = 'h1, h2, h3, p, li, blockquote, figcaption, figure.viz, .viz-box, figure, pre';
            const nodes = Array.from(container.querySelectorAll(selector));
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            let blockCounter = 0;

            nodes.forEach(el => {
                if (el.closest('.readlet-bi-trans')) return;
                if (el.getAttribute('data-readlet-clutter') === '1') return;
                // Avoid double-counting .viz-box inside figure.viz
                if (el.classList.contains('viz-box') && el.closest('figure.viz')) return;
                // Avoid indexing <p> inside <li> or <blockquote> if already covered
                const tag = el.tagName.toLowerCase();
                if (tag === 'p' && (el.closest('li') || el.closest('figcaption'))) return;

                if (tag === 'h1' || tag === 'h2' || tag === 'h3') {
                    const headingText = (el.innerText || '').replace(/\s+/g, ' ').trim();
                    if (!headingText) return;
                    const secId = el.id || `sec-${state.sections.length}`;
                    if (!el.id) el.id = secId;
                    const depth = tag === 'h1' ? 1 : (tag === 'h2' ? 2 : 3);
                    const rect = el.getBoundingClientRect();
                    const absTop = Math.max(0, rect.top + window.scrollY);
                    const frac = Math.min(1.0, Math.max(0.0, absTop / maxScroll));

                    if (state.sections.length === 1 && currentSec.blockIds.length === 0 && tag === 'h1') {
                        currentSec.id = secId;
                        currentSec.title = headingText;
                        currentSec.anchorEl = el;
                        currentSec.scrollFraction = frac;
                    } else {
                        currentSec = {
                            index: state.sections.length,
                            id: secId,
                            title: headingText,
                            depth: depth,
                            textParts: [headingText],
                            blockIds: [],
                            scrollFraction: frac,
                            anchorEl: el
                        };
                        state.sections.push(currentSec);
                    }
                    el.setAttribute('data-readlet-bid', secId);
                    state.blockEls.set(secId, el);
                    state.blockToSection.set(secId, currentSec.index);
                    currentSec.blockIds.push(secId);
                    return;
                }

                // Interactive chart figure
                if (el.matches('figure.viz, .viz-box, figure')) {
                    const vizBox = el.matches('.viz-box') ? el : el.querySelector('.viz-box');
                    const vizName = vizBox ? (vizBox.getAttribute('data-name') || '') : '';
                    const cap = (el.querySelector('figcaption')?.innerText || vizName || '').replace(/\s+/g, ' ').trim();
                    const bid = vizName ? `viz:${vizName}` : `${currentSec.id}::fig-${blockCounter++}`;
                    el.setAttribute('data-readlet-bid', bid);
                    if (getComputedStyle(el).position === 'static') {
                        el.style.position = 'relative';
                    }
                    state.blockEls.set(bid, el);
                    state.blockToSection.set(bid, currentSec.index);
                    currentSec.blockIds.push(bid);
                    if (vizName || cap) {
                        currentSec.textParts.push(`[Interactive Visualization ${vizName ? '(' + vizName + ')' : ''}: ${cap}]`);
                    }
                    return;
                }

                const txt = (el.innerText || '').replace(/\s+/g, ' ').trim();
                if (txt.length < 2) return;
                const bid = el.id || `${currentSec.id}::b-${blockCounter++}`;
                el.setAttribute('data-readlet-bid', bid);
                state.blockEls.set(bid, el);
                state.blockToSection.set(bid, currentSec.index);
                currentSec.blockIds.push(bid);
                currentSec.textParts.push(txt);
            });

            const payload = state.sections.map(s => ({
                index: s.index,
                id: s.id,
                title: s.title,
                depth: s.depth,
                text: s.textParts.join('\n\n'),
                blockIds: s.blockIds,
                scrollFraction: s.scrollFraction
            }));
            post('readletSections', JSON.stringify(payload));
        }

        // 4. Viewport-Independent Reading Anchor (Lock & Restore across Resizes & Devices)
        function captureCurrentAnchor() {
            const readingY = window.innerHeight * 0.24;
            let bestBid = null;
            let bestDist = Infinity;
            let bestRect = null;

            state.blockEls.forEach((el, bid) => {
                if (!el.isConnected || el.offsetParent === null) return;
                const r = el.getBoundingClientRect();
                if (r.height <= 0) return;
                if (r.top <= readingY && r.bottom >= readingY) {
                    bestBid = bid;
                    bestRect = r;
                    bestDist = 0;
                } else {
                    const dist = Math.min(Math.abs(r.top - readingY), Math.abs(r.bottom - readingY));
                    if (dist < bestDist) {
                        bestDist = dist;
                        bestBid = bid;
                        bestRect = r;
                    }
                }
            });

            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            const scrollFraction = Math.min(1.0, Math.max(0.0, window.scrollY / maxScroll));
            let intraOffset = 0.0;
            if (bestRect && bestRect.height > 1) {
                intraOffset = Math.min(1.0, Math.max(0.0, (readingY - bestRect.top) / bestRect.height));
            }
            const secIdx = bestBid && state.blockToSection.has(bestBid) ? state.blockToSection.get(bestBid) : 0;
            const sec = state.sections[secIdx] || state.sections[0];
            return {
                anchorId: bestBid || (sec ? sec.id : 'sec-0'),
                intraOffset: intraOffset,
                scrollFraction: scrollFraction,
                sectionIndex: sec ? sec.index : 0,
                sectionTitle: sec ? sec.title : '',
                docTitle: (document.querySelector('h1')?.innerText || document.title || '').replace(/\s+/g, ' ').trim()
            };
        }

        function restoreAnchor(anchor, reportBack) {
            if (!anchor) return;
            if (scrollTimer) {
                clearTimeout(scrollTimer);
                scrollTimer = null;
            }
            state.isRestoringScroll = true;
            try {
                let targetEl = null;
                if (anchor.anchorId) {
                    targetEl = state.blockEls.get(anchor.anchorId)
                        || document.getElementById(anchor.anchorId)
                        || document.querySelector(`[data-readlet-bid="${CSS.escape(anchor.anchorId)}"]`);
                }
                if (targetEl) {
                    const r = targetEl.getBoundingClientRect();
                    const readingY = window.innerHeight * 0.24;
                    const intra = (typeof anchor.intraOffset === 'number') ? anchor.intraOffset : 0.0;
                    const targetScrollY = window.scrollY + r.top + (r.height * intra) - readingY;
                    window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
                } else if (typeof anchor.scrollFraction === 'number' && anchor.scrollFraction >= 0) {
                    const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
                    window.scrollTo({ top: Math.max(0, anchor.scrollFraction * maxScroll), behavior: 'instant' });
                }
                const updated = captureCurrentAnchor();
                state.lockedAnchor = updated;
                if (reportBack !== false) {
                    post('readletProgress', updated);
                }
            } catch (e) {}
            setTimeout(() => { state.isRestoringScroll = false; }, 120);
        }

        function seekToFraction(fraction) {
            const clamped = Math.min(1.0, Math.max(0.0, Number(fraction) || 0));
            if (scrollTimer) {
                clearTimeout(scrollTimer);
                scrollTimer = null;
            }
            state.userHasScrolled = true;
            state.lastUserScrollTime = Date.now();
            state.isRestoringScroll = true;
            try {
                const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
                window.scrollTo({ top: Math.max(0, clamped * maxScroll), behavior: 'instant' });
                const updated = captureCurrentAnchor();
                updated.scrollFraction = clamped;
                state.lockedAnchor = updated;
                post('readletProgress', updated);
            } catch (e) {}
            setTimeout(() => { state.isRestoringScroll = false; }, 120);
        }

        function restoreInitialAnchor(anchor) {
            if (!anchor || state.userHasScrolled || state.initialAnchorRestored) return;
            if (Date.now() - state.lastUserScrollTime < 1500) return;
            state.initialAnchorRestored = true;
            restoreAnchor(anchor, true);
        }

        function withScrollLock(mutator) {
            if (Date.now() - state.lastUserScrollTime < 800) {
                mutator();
                return;
            }
            const snap = captureCurrentAnchor();
            mutator();
            restoreAnchor(snap, false);
        }

        let scrollTimer = null;
        window.addEventListener('scroll', function() {
            if (state.isRestoringScroll) return;
            state.lockedAnchor = captureCurrentAnchor();
            if (scrollTimer) return;
            scrollTimer = setTimeout(() => {
                scrollTimer = null;
                if (!state.isRestoringScroll) {
                    const a = captureCurrentAnchor();
                    state.lockedAnchor = a;
                    post('readletProgress', a);
                }
            }, 150);
        }, { passive: true });

        let lastViewportW = document.documentElement.clientWidth;
        window.addEventListener('resize', function() {
            const w = document.documentElement.clientWidth;
            if (Math.abs(w - lastViewportW) < 8) return;
            lastViewportW = w;
            const saved = state.lockedAnchor || captureCurrentAnchor();
            fitWideVisualizations();
            if (saved && (Date.now() - state.lastUserScrollTime > 800)) {
                restoreAnchor(saved);
            }
        });

        // 5. In-Place Bilingual Translation
        function getTranslatableBlocks(sectionIndex) {
            const sec = state.sections[sectionIndex];
            if (!sec) return [];
            const out = [];
            sec.blockIds.forEach(bid => {
                if (bid.startsWith('viz:')) return;
                const el = state.blockEls.get(bid);
                if (!el) return;
                const tag = el.tagName.toLowerCase();
                if (tag === 'pre' || tag === 'code' || tag === 'figure') return;
                const txt = (el.innerText || '').replace(/\s+/g, ' ').trim();
                if (txt.length >= 4) {
                    out.push({ id: bid, text: txt });
                }
            });
            return out;
        }

        function applyTranslations(map) {
            if (!map) return;
            withScrollLock(() => {
                Object.keys(map).forEach(bid => {
                    const tr = map[bid];
                    if (!tr) return;
                    state.translations.set(bid, tr);
                    const el = state.blockEls.get(bid) || document.querySelector(`[data-readlet-bid="${CSS.escape(bid)}"]`);
                    if (!el || !el.parentElement) return;
                    let transNode = el.nextElementSibling;
                    if (!transNode || !transNode.classList.contains('readlet-bi-trans') || transNode.getAttribute('data-for-bid') !== bid) {
                        transNode = document.createElement('div');
                        transNode.className = 'readlet-bi-trans';
                        transNode.setAttribute('data-for-bid', bid);
                        el.insertAdjacentElement('afterend', transNode);
                    }
                    transNode.textContent = tr;
                });
            });
        }

        // 6. Selection & W3C TextQuoteSelector + Card Highlighting
        function buildSelectionPayload() {
            const sel = window.getSelection();
            if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
            const rawText = sel.toString().replace(/\s+/g, ' ').trim();
            if (!rawText) return null;
            const range = sel.getRangeAt(0);
            let node = range.commonAncestorContainer;
            if (node.nodeType === Node.TEXT_NODE) node = node.parentElement;
            if (!node || !(node instanceof Element)) return null;
            if (node.closest('.readlet-bi-trans')) return null;

            const blockEl = node.closest('[data-readlet-bid]') || node;
            const bid = blockEl.getAttribute('data-readlet-bid') || '';
            const secIdx = state.blockToSection.has(bid) ? state.blockToSection.get(bid) : (state.lockedAnchor ? state.lockedAnchor.sectionIndex : 0);
            const sec = state.sections[secIdx] || state.sections[0];
            const blockText = (blockEl.innerText || '').replace(/\s+/g, ' ');
            const matchIdx = blockText.indexOf(rawText);
            let prefix = '';
            let suffix = '';
            if (matchIdx >= 0) {
                prefix = blockText.slice(Math.max(0, matchIdx - 32), matchIdx);
                suffix = blockText.slice(matchIdx + rawText.length, matchIdx + rawText.length + 32);
            }
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            const r = range.getBoundingClientRect();
            const permille = Math.min(1000, Math.max(0, Math.round(((window.scrollY + r.top) / maxScroll) * 1000)));
            return {
                text: rawText,
                sectionIndex: sec ? sec.index : 0,
                sectionId: sec ? sec.id : null,
                sectionTitle: sec ? sec.title : null,
                blockId: bid || null,
                exact: rawText,
                prefix: prefix,
                suffix: suffix,
                progressPermille: permille,
                clientRect: [r.left, r.top, r.width, r.height]
            };
        }

        let selTimer = null;
        document.addEventListener('selectionchange', function() {
            if (selTimer) clearTimeout(selTimer);
            selTimer = setTimeout(() => {
                const p = buildSelectionPayload();
                post('readletSelection', p ? JSON.stringify(p) : 'null');
            }, 140);
        });

        function unwrapMarks(selector) {
            document.querySelectorAll(selector).forEach(mark => {
                const parent = mark.parentNode;
                if (!parent) return;
                while (mark.firstChild) {
                    if (mark.firstChild.classList && mark.firstChild.classList.contains('readlet-card-badge')) {
                        mark.removeChild(mark.firstChild);
                    } else {
                        parent.insertBefore(mark.firstChild, mark);
                    }
                }
                parent.removeChild(mark);
                parent.normalize();
            });
        }

        function highlightTextInElement(rootEl, exact, card) {
            if (!rootEl || !exact) return false;
            const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, {
                acceptNode(n) {
                    if (!n.parentElement) return NodeFilter.FILTER_REJECT;
                    if (n.parentElement.closest('.readlet-bi-trans, mark.readlet-card-hl, script, style')) {
                        return NodeFilter.FILTER_REJECT;
                    }
                    return NodeFilter.FILTER_ACCEPT;
                }
            });
            const needle = exact.trim();
            if (!needle) return false;
            let textNode;
            while ((textNode = walker.nextNode())) {
                const val = textNode.nodeValue || '';
                const idx = val.indexOf(needle);
                if (idx >= 0) {
                    const range = document.createRange();
                    range.setStart(textNode, idx);
                    range.setEnd(textNode, idx + needle.length);
                    const mark = document.createElement('mark');
                    mark.className = 'readlet-card-hl';
                    mark.setAttribute('data-card-id', card.id);
                    mark.style.backgroundColor = card.bgRgba;
                    mark.style.borderBottom = `2px solid ${card.colorHex}`;
                    range.surroundContents(mark);
                    if (card.hasComment) {
                        const badge = document.createElement('span');
                        badge.className = 'readlet-card-badge';
                        badge.style.backgroundColor = card.colorHex;
                        badge.textContent = '💬';
                        mark.appendChild(badge);
                    }
                    mark.addEventListener('click', function(ev) {
                        ev.stopPropagation();
                        post('readletCardClick', {
                            cardId: card.id,
                            clientX: ev.clientX,
                            clientY: ev.clientY
                        });
                    });
                    return true;
                }
            }
            return false;
        }

        function renderCards(cards) {
            state.cards = cards || [];
            unwrapMarks('mark.readlet-card-hl');
            document.querySelectorAll('.readlet-area-badge').forEach(b => b.remove());

            state.cards.forEach(card => {
                const targetEl = (card.blockId && (state.blockEls.get(card.blockId) || document.querySelector(`[data-readlet-bid="${CSS.escape(card.blockId)}"]`)))
                    || (card.sectionId && document.getElementById(card.sectionId))
                    || document.body;

                if (card.isImage) {
                    if (targetEl && targetEl !== document.body) {
                        if (getComputedStyle(targetEl).position === 'static') {
                            targetEl.style.position = 'relative';
                        }
                        const badge = document.createElement('div');
                        badge.className = 'readlet-area-badge';
                        badge.setAttribute('data-card-id', card.id);
                        badge.style.backgroundColor = card.colorHex;
                        badge.textContent = card.hasComment ? '🖼 💬' : '🖼 摘录';
                        badge.addEventListener('click', function(ev) {
                            ev.stopPropagation();
                            post('readletCardClick', {
                                cardId: card.id,
                                clientX: ev.clientX,
                                clientY: ev.clientY
                            });
                        });
                        targetEl.appendChild(badge);
                    }
                } else if (card.exact) {
                    if (!highlightTextInElement(targetEl, card.exact, card)) {
                        highlightTextInElement(document.body, card.exact, card);
                    }
                }
            });
        }

        function jumpToCard(cardId, blockId, sectionId, permille, sectionIndex) {
            let target = document.querySelector(`mark.readlet-card-hl[data-card-id="${CSS.escape(cardId)}"]`)
                || document.querySelector(`.readlet-area-badge[data-card-id="${CSS.escape(cardId)}"]`)
                || (blockId && (state.blockEls.get(blockId) || document.querySelector(`[data-readlet-bid="${CSS.escape(blockId)}"]`)))
                || (sectionId && document.getElementById(sectionId));

            if (target) {
                target.scrollIntoView({ behavior: 'smooth', block: 'center' });
                const flashEl = target.classList.contains('readlet-area-badge') ? (target.parentElement || target) : target;
                flashEl.classList.remove('readlet-jump-flash');
                void flashEl.offsetWidth;
                flashEl.classList.add('readlet-jump-flash');
                return true;
            }
            if (permille >= 0) {
                const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
                window.scrollTo({ top: (permille / 1000.0) * maxScroll, behavior: 'smooth' });
                return true;
            }
            if (sectionIndex >= 0 && state.sections[sectionIndex]) {
                scrollToSection(sectionIndex);
                return true;
            }
            return false;
        }

        function resolveAreaBox(normX, normY, normW, normH) {
            const cx = (normX + normW * 0.5) * window.innerWidth;
            const cy = (normY + normH * 0.5) * window.innerHeight;
            let bestBid = null;
            let bestEl = null;
            let bestScore = Infinity;

            state.blockEls.forEach((el, bid) => {
                const r = el.getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) return;
                const inside = cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom;
                const dy = inside ? 0 : Math.min(Math.abs(cy - r.top), Math.abs(cy - r.bottom));
                // Prefer figure/viz blocks when capturing charts
                const bonus = bid.startsWith('viz:') || el.tagName === 'FIGURE' ? -50 : 0;
                const score = dy + bonus;
                if (score < bestScore) {
                    bestScore = score;
                    bestBid = bid;
                    bestEl = el;
                }
            });

            const secIdx = bestBid && state.blockToSection.has(bestBid) ? state.blockToSection.get(bestBid) : 0;
            const sec = state.sections[secIdx] || state.sections[0];
            let relRect = [normX, normY, normW, normH];
            let caption = '';
            if (bestEl) {
                const r = bestEl.getBoundingClientRect();
                if (r.width > 1 && r.height > 1) {
                    const boxLeft = normX * window.innerWidth;
                    const boxTop = normY * window.innerHeight;
                    const boxW = normW * window.innerWidth;
                    const boxH = normH * window.innerHeight;
                    relRect = [
                        Math.max(0, Math.min(1, (boxLeft - r.left) / r.width)),
                        Math.max(0, Math.min(1, (boxTop - r.top) / r.height)),
                        Math.max(0.05, Math.min(1, boxW / r.width)),
                        Math.max(0.05, Math.min(1, boxH / r.height))
                    ];
                }
                caption = (bestEl.querySelector('figcaption')?.innerText || bestEl.getAttribute('data-name') || '').replace(/\s+/g, ' ').trim();
            }
            const maxScroll = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);
            const permille = Math.min(1000, Math.max(0, Math.round(((window.scrollY + cy) / maxScroll) * 1000)));
            return {
                sectionIndex: sec ? sec.index : 0,
                sectionId: sec ? sec.id : null,
                sectionTitle: sec ? sec.title : null,
                blockId: bestBid,
                relRect: relRect,
                progressPermille: permille,
                captionText: caption
            };
        }

        // 7. Interactive Element Picker (`eraseMode`) for Custom Decluttering
        function uniqueSelectorFor(el) {
            if (!el || el === document.body || el === document.documentElement) return null;
            if (el.id) return '#' + CSS.escape(el.id);
            const classes = Array.from(el.classList || []).filter(c => !c.startsWith('readlet-'));
            if (classes.length > 0) {
                const sel = el.tagName.toLowerCase() + '.' + classes.slice(0, 2).map(c => CSS.escape(c)).join('.');
                if (document.querySelectorAll(sel).length <= 3) return sel;
            }
            const parent = el.parentElement;
            if (!parent) return el.tagName.toLowerCase();
            const children = Array.from(parent.children);
            const idx = children.indexOf(el) + 1;
            const pSel = uniqueSelectorFor(parent);
            return pSel ? `${pSel} > ${el.tagName.toLowerCase()}:nth-child(${idx})` : el.tagName.toLowerCase();
        }

        document.addEventListener('mousemove', function(ev) {
            if (!state.eraseMode) return;
            const t = ev.target;
            if (state.hoveredEraseEl && state.hoveredEraseEl !== t) {
                state.hoveredEraseEl.classList.remove('readlet-erase-hover');
            }
            if (t && t !== document.body && t !== document.documentElement) {
                state.hoveredEraseEl = t;
                t.classList.add('readlet-erase-hover');
            }
        }, true);

        document.addEventListener('click', function(ev) {
            if (!state.eraseMode) return;
            ev.preventDefault();
            ev.stopPropagation();
            const t = ev.target;
            if (!t || t === document.body || t === document.documentElement) return;
            t.classList.remove('readlet-erase-hover');
            const sel = uniqueSelectorFor(t);
            if (sel) {
                t.setAttribute('data-readlet-user-hidden', '1');
                post('readletHideSelector', sel);
            }
        }, true);

        // 8. In-Page Find (`⌘F`) & AI Narration Spotlight
        function clearFind() {
            unwrapMarks('mark.readlet-find-hl');
            state.findMatches = [];
        }

        function findText(query) {
            clearFind();
            if (!query || !query.trim()) return [];
            const q = query.trim().toLowerCase();
            const results = [];
            state.sections.forEach(sec => {
                sec.blockIds.forEach(bid => {
                    const el = state.blockEls.get(bid);
                    if (!el) return;
                    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
                        acceptNode(n) {
                            if (!n.parentElement || n.parentElement.closest('script, style, mark.readlet-find-hl')) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    });
                    let tn;
                    while ((tn = walker.nextNode())) {
                        const val = tn.nodeValue || '';
                        const idx = val.toLowerCase().indexOf(q);
                        if (idx >= 0 && results.length < 150) {
                            const matchIndex = results.length;
                            const start = Math.max(0, idx - 24);
                            const end = Math.min(val.length, idx + q.length + 36);
                            const snippet = (start > 0 ? '…' : '') + val.slice(start, end).replace(/\s+/g, ' ') + (end < val.length ? '…' : '');
                            try {
                                const r = document.createRange();
                                r.setStart(tn, idx);
                                r.setEnd(tn, idx + q.length);
                                const m = document.createElement('mark');
                                m.className = 'readlet-find-hl';
                                m.setAttribute('data-find-idx', String(matchIndex));
                                r.surroundContents(m);
                                state.findMatches.push(m);
                                results.push({
                                    index: matchIndex,
                                    sectionIndex: sec.index,
                                    sectionTitle: sec.title,
                                    snippet: snippet
                                });
                            } catch (e) {}
                            break;
                        }
                    }
                });
            });
            if (state.findMatches.length > 0) {
                jumpToFindMatch(0);
            }
            return results;
        }

        function jumpToFindMatch(index) {
            state.findMatches.forEach((m, i) => {
                if (i === index) m.classList.add('active');
                else m.classList.remove('active');
            });
            const target = state.findMatches[index];
            if (target) {
                target.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
        }

        function clearNarrationHighlight() {
            document.querySelectorAll('.readlet-narr-active').forEach(el => el.classList.remove('readlet-narr-active'));
        }

        function highlightNarration(sectionIndex, quote, mentionsFigure) {
            clearNarrationHighlight();
            const sec = state.sections[sectionIndex] || state.sections[0];
            if (!sec) return;
            let bestEl = null;

            if (mentionsFigure) {
                for (const bid of sec.blockIds) {
                    if (bid.startsWith('viz:') || bid.includes('::fig-')) {
                        bestEl = state.blockEls.get(bid);
                        if (bestEl) break;
                    }
                }
            }
            if (!bestEl && quote && quote.trim().length >= 4) {
                const needle = quote.trim().toLowerCase().slice(0, 36);
                for (const bid of sec.blockIds) {
                    const el = state.blockEls.get(bid);
                    if (el && (el.innerText || '').toLowerCase().includes(needle)) {
                        bestEl = el;
                        break;
                    }
                }
            }
            if (!bestEl) {
                bestEl = sec.anchorEl || state.blockEls.get(sec.blockIds[0]);
            }
            if (bestEl) {
                bestEl.classList.add('readlet-narr-active');
                bestEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
            }
        }

        function scrollToSection(sectionIndex) {
            const sec = state.sections[sectionIndex];
            if (!sec) return;
            state.userHasScrolled = true;
            state.lastUserScrollTime = Date.now();
            const el = sec.anchorEl || document.getElementById(sec.id) || state.blockEls.get(sec.blockIds[0]);
            if (el) {
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
            }
        }

        window.__readletLive = {
            setCleanMode(enabled, customSelectors) {
                const nextClean = !!enabled;
                const nextSel = Array.isArray(customSelectors) ? customSelectors : [];
                if (state.declutterAppliedOnce
                    && state.cleanMode === nextClean
                    && JSON.stringify(state.customSelectors) === JSON.stringify(nextSel)) {
                    return;
                }
                withScrollLock(() => {
                    state.cleanMode = nextClean;
                    state.customSelectors = nextSel;
                    state.declutterAppliedOnce = true;
                    applyDecluttering();
                    fitWideVisualizations();
                });
            },
            setVariant(variant) {
                const nextVariant = variant || 'original';
                if (state.variant === nextVariant && document.documentElement.getAttribute('data-readlet-variant') === nextVariant) {
                    return;
                }
                withScrollLock(() => {
                    state.variant = nextVariant;
                    document.documentElement.setAttribute('data-readlet-variant', state.variant);
                });
            },
            setEraseMode(enabled) {
                state.eraseMode = !!enabled;
                if (!state.eraseMode && state.hoveredEraseEl) {
                    state.hoveredEraseEl.classList.remove('readlet-erase-hover');
                    state.hoveredEraseEl = null;
                }
            },
            getTranslatableBlocks: getTranslatableBlocks,
            applyTranslations: applyTranslations,
            renderCards: renderCards,
            jumpToCard: jumpToCard,
            resolveAreaBox: resolveAreaBox,
            restoreAnchor: restoreAnchor,
            restoreInitialAnchor: restoreInitialAnchor,
            seekToFraction: seekToFraction,
            scrollToSection: scrollToSection,
            findText: findText,
            jumpToFindMatch: jumpToFindMatch,
            clearFind: clearFind,
            highlightNarration: highlightNarration,
            clearNarrationHighlight: clearNarrationHighlight,
            fitWideVisualizations: fitWideVisualizations
        };

        function boot() {
            ensureStyles();
            state.declutterAppliedOnce = true;
            document.documentElement.setAttribute('data-readlet-variant', state.variant);
            applyDecluttering();
            indexSectionsAndBlocks();
            fitWideVisualizations();
            if (!state.userHasScrolled && window.location.hash && window.location.hash.length > 1) {
                const hid = decodeURIComponent(window.location.hash.slice(1));
                const hel = document.getElementById(hid);
                if (hel) hel.scrollIntoView({ behavior: 'instant', block: 'start' });
            }
            post('readletReady', true);
            setTimeout(() => {
                indexSectionsAndBlocks();
                fitWideVisualizations();
                if (!state.isRestoringScroll) {
                    post('readletProgress', captureCurrentAnchor());
                }
            }, 700);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', boot);
        } else {
            boot();
        }
    })();
    """#
}
