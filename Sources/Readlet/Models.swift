import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import PDFKit

enum Variant: String, Codable, Hashable { case original, bilingual }

/// Document storage & rendering kind: `.pdf` (static PDF file) or `.web` (live interactive webpage stored by URL only).
enum DocKind: String, Codable, Hashable {
    case pdf
    case web
}

/// Viewport-independent reading anchor for live interactive web documents.
/// Coordinates cross-window resizes (full window vs split mind-map pane) and cross-device sync (Mac / iPad / iPhone).
struct WebReadingAnchor: Codable, Hashable {
    /// Semantic DOM element identifier (e.g. `s-2-1`, `s-1::p-3`, `viz:token-routing`)
    var anchorId: String = ""
    /// Fractional vertical offset (`0.0 ... 1.0`) within the anchor element at the reading line
    var intraOffset: Double = 0.0
    /// Continuous document scroll fraction (`0.0 ... 1.0`)
    var scrollFraction: Double
    /// Human-readable current section title (e.g. `"2.1 Routing Collapse"`)
    var sectionTitle: String? = nil
    /// 0-indexed logical section index for TOC & AI Narration alignment
    var sectionIndex: Int? = nil

    var progressPermille: Int {
        min(1000, max(0, Int((scrollFraction * 1000.0).rounded())))
    }

    var progressPercent: Int {
        min(100, max(0, Int((scrollFraction * 100.0).rounded())))
    }
}

/// Viewport-independent DOM anchor for text highlights and area/chart excerpts on interactive webpages.
struct WebCardAnchor: Codable, Hashable {
    /// Section heading ID (`s-1`, `s-2-0`, etc.)
    var sectionId: String? = nil
    /// Section heading title (`"1. A visual guide to Mixture of Experts"`)
    var sectionTitle: String? = nil
    /// Semantic block ID within the article (`s-1::p-2`, `viz:moe-layer`, etc.)
    var blockId: String? = nil
    /// W3C TextQuoteSelector exact text
    var exact: String = ""
    /// W3C TextQuoteSelector preceding context (~32 chars)
    var prefix: String = ""
    /// W3C TextQuoteSelector following context (~32 chars)
    var suffix: String = ""
    /// Normalized bounding box (`0.0 ... 1.0` relative to `blockId` or interactive chart container) for area/chart excerpts
    var relRect: CGRect? = nil
    /// Continuous scroll permille (`0 ... 1000`) for sorting and progress display
    var progressPermille: Int? = nil
}

/// Logical section extracted from a live interactive webpage (`h1` / `h2` / `h3`) for TOC, Copilot, Flashcards, MindMap & Narration.
struct WebSection: Codable, Hashable, Identifiable {
    var index: Int
    var id: String
    var title: String
    var depth: Int
    var text: String
    var blockIds: [String] = []
    /// Fractional scroll position (`0.0 ... 1.0`) where this section starts
    var scrollFraction: Double = 0.0
}

/// Resolves and normalizes interactive web URLs, including deterministic unwrapping of outer container shells
/// (such as Hugging Face Spaces `huggingface.co/spaces/<owner>/<space>#s-1` -> `https://<owner>-<space>.hf.space/#s-1`)
/// when `cleanMode` is enabled.
enum WebURLResolver {
    /// Normalizes user input into a valid `http`/`https` URL string.
    static func normalizedInputURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let withScheme = (s.hasPrefix("http://") || s.hasPrefix("https://")) ? s : "https://" + s
        guard let u = URL(string: withScheme), let host = u.host, host.contains(".") else { return nil }
        return u
    }

    /// Alias for `normalizedInputURL` used across macOS/iOS import flows.
    static func normalize(_ raw: String) -> URL? {
        normalizedInputURL(raw)
    }

    /// Canonical key used to deduplicate web documents in the library (ignores fragment `#...` and trailing slash).
    static func canonicalIdentity(_ rawURL: String) -> String {
        guard let u = normalizedInputURL(rawURL),
              var comp = URLComponents(url: u, resolvingAgainstBaseURL: false) else {
            return rawURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        comp.fragment = nil
        comp.scheme = comp.scheme?.lowercased()
        comp.host = comp.host?.lowercased()
        if comp.path.count > 1 && comp.path.hasSuffix("/") {
            comp.path.removeLast()
        }
        return comp.string ?? rawURL.lowercased()
    }

    /// Returns the effective URL to load in `WKWebView`.
    /// When `cleanMode == true`, known outer wrapper shells (e.g. Hugging Face Spaces `/spaces/<org>/<repo>`)
    /// are unwrapped directly to the embedded interactive app host while preserving path suffixes, query, and `#fragment`.
    static func resolvedLoadURL(originalURL: String, cleanMode: Bool) -> URL? {
        guard let u = normalizedInputURL(originalURL) else { return nil }
        guard cleanMode else { return u }
        if let unwrapped = unwrapHuggingFaceSpaceURL(u) {
            return unwrapped
        }
        return u
    }

    /// Unwraps `https://huggingface.co/spaces/<owner>/<space>[/...][#hash]` -> `https://<owner>-<space>.hf.space[/...][#hash]`.
    static func unwrapHuggingFaceSpaceURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              (host == "huggingface.co" || host == "www.huggingface.co"),
              let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let parts = comp.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "spaces" else { return nil }
        let owner = parts[1].lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        let space = parts[2].lowercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: ".", with: "-")
        guard !owner.isEmpty, !space.isEmpty else { return nil }
        // Do not unwrap repository tree/settings URLs like /spaces/org/repo/tree/main
        let remainder = Array(parts.dropFirst(3))
        if let firstSub = remainder.first?.lowercased(),
           ["tree", "blob", "commits", "discussions", "settings", "raw"].contains(firstSub) {
            return nil
        }
        var out = URLComponents()
        out.scheme = "https"
        out.host = "\(owner)-\(space).hf.space"
        out.path = remainder.isEmpty ? "/" : ("/" + remainder.joined(separator: "/"))
        out.query = comp.query
        out.fragment = comp.fragment
        return out.url
    }

    /// Human-friendly initial title derived from a URL before the live DOM finishes loading `<title>`.
    static func fallbackTitle(for rawURL: String) -> String {
        guard let u = normalizedInputURL(rawURL) else { return rawURL }
        let parts = u.path.split(separator: "/").map(String.init)
        if let host = u.host?.lowercased(), host.contains("huggingface.co"), parts.count >= 3, parts[0] == "spaces" {
            return parts[2].replacingOccurrences(of: "-", with: " ").capitalized
        }
        if let last = parts.last, !last.isEmpty, last != "index.html" {
            return last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        return u.host ?? rawURL
    }
}

/// Built-in workflow status tags for documents (`TODO`, `DOING`, `DONE`).
enum DocStatusTag: String, CaseIterable, Codable, Identifiable, Equatable {
    case todo = "TODO"
    case doing = "DOING"
    case done = "DONE"
    var id: String { rawValue }
    var label: String { rawValue }
    var icon: String {
        switch self {
        case .todo: return "circle.dashed"
        case .doing: return "timelapse"
        case .done: return "checkmark.circle.fill"
        }
    }
}

enum DeviceIdentity {
    static let currentDeviceId: String = {
        let key = "readlet.device.id"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    static var currentDeviceName: String {
        #if os(macOS)
        if let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return "Mac"
        #elseif os(iOS)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "iPhone" : name
        #endif
    }

    static func todayDateKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct DeviceProgressSnapshot: Codable, Hashable, Identifiable {
    var deviceId: String
    var deviceName: String
    var readPage: Int
    var narrationPage: Int? = nil
    var narrationSeg: Int? = nil
    var webAnchor: WebReadingAnchor? = nil
    var updatedAt: Date

    var id: String { deviceId.isEmpty ? deviceName : deviceId }
}

struct ProgressConflict: Codable, Hashable {
    var localDeviceId: String
    var localDeviceName: String
    var localPage: Int
    var localNarrationPage: Int? = nil
    var localNarrationSeg: Int? = nil
    var localWebAnchor: WebReadingAnchor? = nil
    var localUpdatedAt: Date

    var remoteDeviceId: String
    var remoteDeviceName: String
    var remotePage: Int
    var remoteNarrationPage: Int? = nil
    var remoteNarrationSeg: Int? = nil
    var remoteWebAnchor: WebReadingAnchor? = nil
    var remoteUpdatedAt: Date

    var detectedAt: Date = Date()
}

struct Doc: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var added = Date()
    /// `.pdf` (default) or `.web` (live interactive webpage imported by URL)
    var kind: DocKind = .pdf
    /// web page the PDF was imported from, or the live URL for `.web` documents
    var source: String? = nil
    /// Whether peripheral non-body DOM elements & outer wrapper shells are automatically removed for `.web` documents (per-article toggle, default `true`)
    var webCleanMode: Bool = true
    /// Additional user-selected CSS selectors hidden in clean mode for this article
    var webHiddenSelectors: [String] = []
    /// Viewport-independent reading anchor (`anchorId`, `intraOffset`, `scrollFraction`, `sectionTitle`) for `.web` documents
    var webAnchor: WebReadingAnchor? = nil
    /// workflow status tags (`TODO`, `DOING`, `DONE`) + arbitrary user tags
    var tags: [String] = []
    /// total page count cached for bookshelf progress display (for `.web`, stores total section count when available)
    var pageCount: Int? = nil
    /// 0-indexed current / furthest page read (for `.web`, stores current 0-indexed section index)
    var readPage: Int? = nil
    /// when `readPage` / `webAnchor` was last updated by user navigation
    var readUpdatedAt: Date? = nil
    /// device name & id that recorded `readPage` / `webAnchor`
    var lastReadDevice: String? = nil
    var lastReadDeviceId: String? = nil
    /// 0-indexed page (or web section index) and segment for AI Narration progress (synced across Mac & iOS)
    var narrationPage: Int? = nil
    var narrationSeg: Int? = nil
    var narrationUpdatedAt: Date? = nil
    var lastNarrationDevice: String? = nil
    /// per-device progress snapshots (up to 6 devices) for cross-device tracking & recovery
    var deviceProgressHistory: [DeviceProgressSnapshot] = []
    /// daily reading log: `"yyyy-MM-dd"` -> 0-indexed page reached that day (or permille `0..1000` for `.web`)
    var dailyReadingLog: [String: Int] = [:]
    /// non-nil when two devices reported conflicting reading/narration progress
    var pendingConflict: ProgressConflict? = nil
    /// last modified timestamp for conflict-free iCloud sync
    var updatedAt: Date? = nil

    var isWeb: Bool { kind == .web }

    /// Effective source URL string for `.web` documents (or imported web PDFs)
    var webURL: String? {
        guard let s = source?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    init(
        id: UUID = UUID(),
        title: String,
        added: Date = Date(),
        kind: DocKind = .pdf,
        source: String? = nil,
        webCleanMode: Bool = true,
        webHiddenSelectors: [String] = [],
        webAnchor: WebReadingAnchor? = nil,
        tags: [String] = [],
        pageCount: Int? = nil,
        readPage: Int? = nil,
        readUpdatedAt: Date? = nil,
        lastReadDevice: String? = nil,
        lastReadDeviceId: String? = nil,
        narrationPage: Int? = nil,
        narrationSeg: Int? = nil,
        narrationUpdatedAt: Date? = nil,
        lastNarrationDevice: String? = nil,
        deviceProgressHistory: [DeviceProgressSnapshot] = [],
        dailyReadingLog: [String: Int] = [:],
        pendingConflict: ProgressConflict? = nil,
        updatedAt: Date? = Date()
    ) {
        self.id = id
        self.title = title
        self.added = added
        self.kind = kind
        self.source = source
        self.webCleanMode = webCleanMode
        self.webHiddenSelectors = webHiddenSelectors
        self.webAnchor = webAnchor
        self.tags = tags
        self.pageCount = pageCount
        self.readPage = readPage
        self.readUpdatedAt = readUpdatedAt
        self.lastReadDevice = lastReadDevice
        self.lastReadDeviceId = lastReadDeviceId
        self.narrationPage = narrationPage
        self.narrationSeg = narrationSeg
        self.narrationUpdatedAt = narrationUpdatedAt
        self.lastNarrationDevice = lastNarrationDevice
        self.deviceProgressHistory = deviceProgressHistory
        self.dailyReadingLog = dailyReadingLog
        self.pendingConflict = pendingConflict
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, added, kind, source, webCleanMode, webHiddenSelectors, webAnchor
        case tags, pageCount
        case readPage, readUpdatedAt, lastReadDevice, lastReadDeviceId
        case narrationPage, narrationSeg, narrationUpdatedAt, lastNarrationDevice
        case deviceProgressHistory, dailyReadingLog, pendingConflict, updatedAt
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let decodedId = try c.decode(UUID.self, forKey: .id)
        id = decodedId
        title = try c.decode(String.self, forKey: .title)
        added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
        let decodedSource = try c.decodeIfPresent(String.self, forKey: .source)
        source = decodedSource
        webCleanMode = try c.decodeIfPresent(Bool.self, forKey: .webCleanMode) ?? true
        webHiddenSelectors = try c.decodeIfPresent([String].self, forKey: .webHiddenSelectors) ?? []
        let decodedAnchor = try c.decodeIfPresent(WebReadingAnchor.self, forKey: .webAnchor)
        webAnchor = decodedAnchor
        if let explicitKind = try c.decodeIfPresent(DocKind.self, forKey: .kind) {
            kind = explicitKind
        } else if decodedAnchor != nil || (decodedSource?.hasPrefix("http") == true && !FileManager.default.fileExists(atPath: Paths.pdf(decodedId).path)) {
            kind = .web
        } else {
            kind = .pdf
        }
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        readPage = try c.decodeIfPresent(Int.self, forKey: .readPage)
        readUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .readUpdatedAt)
        lastReadDevice = try c.decodeIfPresent(String.self, forKey: .lastReadDevice)
        lastReadDeviceId = try c.decodeIfPresent(String.self, forKey: .lastReadDeviceId)
        narrationPage = try c.decodeIfPresent(Int.self, forKey: .narrationPage)
        narrationSeg = try c.decodeIfPresent(Int.self, forKey: .narrationSeg)
        narrationUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .narrationUpdatedAt)
        lastNarrationDevice = try c.decodeIfPresent(String.self, forKey: .lastNarrationDevice)
        deviceProgressHistory = try c.decodeIfPresent([DeviceProgressSnapshot].self, forKey: .deviceProgressHistory) ?? []
        dailyReadingLog = try c.decodeIfPresent([String: Int].self, forKey: .dailyReadingLog) ?? [:]
        pendingConflict = try c.decodeIfPresent(ProgressConflict.self, forKey: .pendingConflict)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var statusTag: DocStatusTag? {
        for t in tags {
            if let st = DocStatusTag(rawValue: t.uppercased()) { return st }
        }
        return nil
    }

    var customTags: [String] {
        tags.filter { DocStatusTag(rawValue: $0.uppercased()) == nil }
    }

    /// Resolved 0-indexed page (from `readPage` or `UserDefaults` fallback)
    var resolvedReadPage: Int? {
        if let rp = readPage { return rp }
        if UserDefaults.standard.object(forKey: "page-" + id.uuidString) != nil {
            return UserDefaults.standard.integer(forKey: "page-" + id.uuidString)
        }
        return nil
    }

    /// Reading progress in `0.0 ... 1.0`
    var progressFraction: Double {
        if statusTag == .done { return 1.0 }
        if isWeb {
            if let anchor = webAnchor {
                return min(1.0, max(0.0, anchor.scrollFraction))
            }
            if let total = pageCount, total > 0, let rp = resolvedReadPage {
                return min(1.0, max(0.0, Double(rp + 1) / Double(total)))
            }
            return 0.0
        }
        let total = max(1, pageCount ?? 0)
        guard pageCount != nil, let rp = resolvedReadPage else { return 0.0 }
        return min(1.0, max(0.0, Double(rp + 1) / Double(total)))
    }

    var progressPercent: Int {
        Int((progressFraction * 100.0).rounded())
    }

    /// Human-readable progress location string (page-less for `.web` documents, page-based for `.pdf`).
    var progressLocationLabel: String {
        if isWeb {
            let pct = "\(progressPercent)%"
            if let sec = webAnchor?.sectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !sec.isEmpty {
                return "\(pct) · \(sec)"
            }
            return pct
        }
        let curPage = (resolvedReadPage ?? 0) + 1
        let total = pageCount ?? 0
        return total > 0 ? "\(curPage)/\(total) \(L("页"))" : "P\(curPage)"
    }

    mutating func recordDeviceSnapshot(
        deviceId: String = DeviceIdentity.currentDeviceId,
        deviceName: String = DeviceIdentity.currentDeviceName,
        page: Int,
        narrationPage: Int? = nil,
        narrationSeg: Int? = nil,
        webAnchor: WebReadingAnchor? = nil,
        at date: Date = Date()
    ) {
        let resolvedAnchor = webAnchor ?? self.webAnchor
        let snap = DeviceProgressSnapshot(
            deviceId: deviceId,
            deviceName: deviceName,
            readPage: max(0, page),
            narrationPage: narrationPage ?? self.narrationPage,
            narrationSeg: narrationSeg ?? self.narrationSeg,
            webAnchor: resolvedAnchor,
            updatedAt: date
        )
        deviceProgressHistory.removeAll { $0.deviceId == deviceId || $0.deviceName == deviceName }
        deviceProgressHistory.insert(snap, at: 0)
        if deviceProgressHistory.count > 6 {
            deviceProgressHistory = Array(deviceProgressHistory.prefix(6))
        }
        let dayKey = DeviceIdentity.todayDateKey(date)
        let metricValue = isWeb ? (resolvedAnchor?.progressPermille ?? max(0, page)) : max(0, page)
        let prevDayMax = dailyReadingLog[dayKey] ?? 0
        dailyReadingLog[dayKey] = max(prevDayMax, metricValue)
        if dailyReadingLog.count > 45 {
            let sortedKeys = dailyReadingLog.keys.sorted(by: >).prefix(45)
            let keep = Set(sortedKeys)
            dailyReadingLog = dailyReadingLog.filter { keep.contains($0.key) }
        }
    }
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
    /// Viewport-independent DOM anchor for cards created on interactive `.web` documents
    var webAnchor: WebCardAnchor? = nil
    var updatedAt: Date? = nil

    init(docId: UUID, page: Int, variant: Variant, rects: [CGRect], text: String, color: Int = 0, webAnchor: WebCardAnchor? = nil) {
        self.docId = docId; self.page = page; self.variant = variant; self.rects = rects; self.text = text; self.color = color; self.webAnchor = webAnchor; self.updatedAt = Date()
    }
    enum CodingKeys: String, CodingKey { case id, docId, page, variant, rects, text, note, color, created, translation, comments, isImage, webAnchor, updatedAt }
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
        webAnchor = try c.decodeIfPresent(WebCardAnchor.self, forKey: .webAnchor)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        let legacy = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        if !legacy.isEmpty && comments.isEmpty { comments = [legacy] }
    }
    /// all comments joined (for display in PDF annotations / exports)
    var commentText: String { comments.filter { !$0.isEmpty }.joined(separator: "\n") }

    /// Page-less location label for `.web` cards (e.g. `"§2.1 · 34%"`), or `"P3"` for `.pdf` cards.
    func locationLabel(isWebDoc: Bool = false) -> String {
        if let wa = webAnchor {
            if let st = wa.sectionTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !st.isEmpty {
                let short = st.count > 18 ? String(st.prefix(18)) + "…" : st
                return short
            }
            if let perm = wa.progressPermille {
                return "\(Int((Double(perm) / 10.0).rounded()))%"
            }
            return L("网页摘录")
        }
        if isWebDoc {
            return L("第 \(page + 1) 节")
        }
        return "P\(page + 1)"
    }
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
    var updatedAt: Date? = nil

    init(id: UUID = UUID(), name: String, docIds: [UUID] = [], root: MindNode, updatedAt: Date? = Date()) {
        self.id = id
        self.name = name
        self.docIds = docIds
        self.root = root
        self.updatedAt = updatedAt
    }
}

struct CardLink: Codable, Hashable {
    var a: UUID
    var b: UUID
}

struct Library: Codable, Equatable {
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
        let env = ProcessInfo.processInfo.environment
        if let custom = env["READLET_DATA"] ?? env["BIREADER_DATA"], !custom.isEmpty {
            let u = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = appSupport.appendingPathComponent("Readlet", isDirectory: true)
        if !AppInfo.isAppStore {
            for oldName in ["Readit", "BiReader"] {
                let oldDir = appSupport.appendingPathComponent(oldName, isDirectory: true)
                if fm.fileExists(atPath: oldDir.appendingPathComponent("library.json").path) {
                    if !fm.fileExists(atPath: newDir.appendingPathComponent("library.json").path) {
                        try? fm.moveItem(at: oldDir, to: newDir)
                    }
                    if fm.fileExists(atPath: oldDir.appendingPathComponent("library.json").path),
                       !fm.fileExists(atPath: newDir.appendingPathComponent("library.json").path) {
                        return oldDir
                    }
                }
            }
        }
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        return newDir
    }()
    static var libraryFile: URL { base.appendingPathComponent("library.json") }
    static func docDir(_ id: UUID) -> URL {
        let u = base.appendingPathComponent("docs/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static func pdf(_ id: UUID) -> URL { docDir(id).appendingPathComponent("original.pdf") }
    static func hasLocalPDF(_ id: UUID) -> Bool {
        let u = pdf(id)
        guard FileManager.default.fileExists(atPath: u.path),
              let sz = (try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              sz > 100 else { return false }
        return true
    }
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
    private(set) var localMutationVersion: UInt64 = 0

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
        refreshMissingPageCounts()
    }

    func refreshMissingPageCounts() {
        var changed = false
        for i in lib.docs.indices {
            let docId = lib.docs[i].id
            if !lib.docs[i].isWeb, lib.docs[i].pageCount == nil, let pdf = PDFDocument(url: Paths.pdf(docId)) {
                lib.docs[i].pageCount = pdf.pageCount
                changed = true
            }
            if UserDefaults.standard.object(forKey: "page-" + docId.uuidString) != nil {
                let udPage = UserDefaults.standard.integer(forKey: "page-" + docId.uuidString)
                if lib.docs[i].readPage == nil || (udPage > (lib.docs[i].readPage ?? 0) && lib.docs[i].readUpdatedAt == nil) {
                    lib.docs[i].readPage = udPage
                    changed = true
                }
            }
            if lib.docs[i].narrationPage == nil,
               let prog = Narrator.savedDiskProgress(docId),
               (prog.page > 0 || prog.seg > 0) {
                lib.docs[i].narrationPage = prog.page
                lib.docs[i].narrationSeg = prog.seg
                lib.docs[i].narrationUpdatedAt = prog.date
                changed = true
            }
            if lib.docs[i].deviceProgressHistory.isEmpty,
               let rp = lib.docs[i].readPage,
               (rp > 0 || (lib.docs[i].narrationPage ?? 0) > 0 || (lib.docs[i].narrationSeg ?? 0) > 0 || (lib.docs[i].webAnchor?.scrollFraction ?? 0) > 0.01) {
                let ts = lib.docs[i].readUpdatedAt ?? lib.docs[i].updatedAt ?? Date()
                if lib.docs[i].readUpdatedAt == nil { lib.docs[i].readUpdatedAt = ts }
                if lib.docs[i].lastReadDevice == nil { lib.docs[i].lastReadDevice = DeviceIdentity.currentDeviceName }
                if lib.docs[i].lastReadDeviceId == nil { lib.docs[i].lastReadDeviceId = DeviceIdentity.currentDeviceId }
                lib.docs[i].recordDeviceSnapshot(
                    page: rp,
                    narrationPage: lib.docs[i].narrationPage,
                    narrationSeg: lib.docs[i].narrationSeg,
                    webAnchor: lib.docs[i].webAnchor,
                    at: ts
                )
                changed = true
            }
        }
        if changed { save() }
    }

    /// Flushes any pending debounced disk write immediately so disk and memory stay consistent before sync.
    func flushPendingSave() {
        guard saveWork != nil else { return }
        saveWork?.cancel()
        saveWork = nil
        if let d = try? JSONEncoder().encode(lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
        UserDefaults.standard.set(currentNotebookId?.uuidString, forKey: "lastNotebook")
        UserDefaults.standard.set(currentDocId?.uuidString, forKey: "lastDoc")
        UserDefaults.standard.set(variant.rawValue, forKey: "lastVariant")
    }

    /// write immediately (imports, deletes, notebooks — never lose these to a quit or in-flight sync within the debounce window)
    func saveNow() {
        localMutationVersion &+= 1
        saveWork?.cancel()
        saveWork = nil
        if let d = try? JSONEncoder().encode(lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
        UserDefaults.standard.set(currentNotebookId?.uuidString, forKey: "lastNotebook")
        UserDefaults.standard.set(currentDocId?.uuidString, forKey: "lastDoc")
        UserDefaults.standard.set(variant.rawValue, forKey: "lastVariant")
        CloudSync.shared.notifyLocalChange()
    }

    func save() {
        localMutationVersion &+= 1
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.saveWork = nil
            if let d = try? JSONEncoder().encode(self.lib) { try? d.write(to: Paths.libraryFile, options: .atomic) }
            UserDefaults.standard.set(self.currentNotebookId?.uuidString, forKey: "lastNotebook")
            UserDefaults.standard.set(self.currentDocId?.uuidString, forKey: "lastDoc")
            UserDefaults.standard.set(self.variant.rawValue, forKey: "lastVariant")
            CloudSync.shared.notifyLocalChange()
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Applies a merged library from `CloudSync` without triggering a redundant re-upload loop.
    func applyCloudMergedLibrary(_ merged: Library) {
        let oldPages = Dictionary(uniqueKeysWithValues: lib.docs.map { ($0.id, $0.readPage) })
        let oldAnchors = Dictionary(uniqueKeysWithValues: lib.docs.map { ($0.id, $0.webAnchor) })
        let goneCards = Set(lib.cards.map(\.id)).subtracting(merged.cards.map(\.id))
        lib = merged
        let myDeviceId = DeviceIdentity.currentDeviceId
        let myDeviceName = DeviceIdentity.currentDeviceName
        for d in lib.docs {
            if let rp = d.readPage {
                UserDefaults.standard.set(rp, forKey: "page-" + d.id.uuidString)
            }
            guard d.pendingConflict == nil else { continue }
            // Only jump an open reader window if the winning reading progress actually came from another device
            let cameFromOtherDevice: Bool = {
                if let devId = d.lastReadDeviceId, !devId.isEmpty {
                    return devId != myDeviceId
                }
                if let devName = d.lastReadDevice, !devName.isEmpty {
                    return devName != myDeviceName
                }
                return false
            }()
            guard cameFromOtherDevice else { continue }
            if d.isWeb {
                if let anchor = d.webAnchor, oldAnchors[d.id] != anchor {
                    #if os(macOS)
                    if let entry = DocWindows.shared.entries[d.id] {
                        entry.reader.applyRemoteSyncedWebAnchor(anchor)
                    }
                    #elseif os(iOS)
                    if ReaderController.shared.docId == d.id {
                        ReaderController.shared.applyRemoteSyncedWebAnchor(anchor)
                    }
                    #endif
                }
            } else if let rp = d.readPage, oldPages[d.id] != rp {
                #if os(macOS)
                if let entry = DocWindows.shared.entries[d.id], entry.reader.currentPageIndex != rp {
                    entry.reader.applyRemoteSyncedPage(rp)
                }
                #elseif os(iOS)
                if ReaderController.shared.docId == d.id, ReaderController.shared.currentPageIndex != rp {
                    ReaderController.shared.applyRemoteSyncedPage(rp)
                }
                #endif
            }
        }
        if currentNotebookId == nil || !lib.notebooks.contains(where: { $0.id == currentNotebookId }) {
            currentNotebookId = lib.notebooks.first?.id
        }
        if let cid = currentDocId, !lib.docs.contains(where: { $0.id == cid }) {
            currentDocId = currentNotebook?.docIds.first
        }
        for ses in sessions.values {
            for id in goneCards { ses.removeAnnotations(cardId: id) }
            ses.applyAnnotations()
        }
    }

    var currentNotebook: Notebook? { lib.notebooks.first { $0.id == currentNotebookId } }
    var currentDoc: Doc? { lib.docs.first { $0.id == currentDocId } }
    func doc(_ id: UUID) -> Doc? { lib.docs.first { $0.id == id } }
    func card(_ id: UUID?) -> Card? { guard let id else { return nil }; return lib.cards.first { $0.id == id } }

    func session(_ id: UUID) -> DocSession? {
        if let s = sessions[id] { return s }
        guard let d = doc(id), let s = DocSession(doc: d) else { return nil }
        sessions[id] = s
        if !d.isWeb, d.pageCount != s.pageCount, let idx = lib.docs.firstIndex(where: { $0.id == id }) {
            lib.docs[idx].pageCount = s.pageCount
            save()
        }
        return s
    }

    // MARK: notebooks & docs
    func updateNotebook(_ f: (inout Notebook) -> Void) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == currentNotebookId }) else { return }
        f(&lib.notebooks[i])
        lib.notebooks[i].updatedAt = Date()
        saveNow()
    }

    func newNotebook(name: String = L("新笔记本")) {
        let nb = Notebook(name: name, root: MindNode(title: name), updatedAt: Date())
        lib.notebooks.append(nb)
        currentNotebookId = nb.id
        currentDocId = nil
        saveNow()
    }

    func renameNotebook(_ id: UUID, _ name: String) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == id }) else { return }
        lib.notebooks[i].name = name
        lib.notebooks[i].root.title = name
        lib.notebooks[i].updatedAt = Date()
        saveNow()
    }

    func deleteNotebook(_ id: UUID) {
        registerUndo(L("删除笔记本"))
        CloudSync.shared.recordDeletion(id)
        lib.notebooks.removeAll { $0.id == id }
        if lib.notebooks.isEmpty { lib.notebooks.append(Notebook(name: L("我的笔记本"), root: MindNode(title: L("我的笔记本")), updatedAt: Date())) }
        if currentNotebookId == id { currentNotebookId = lib.notebooks.first?.id; currentDocId = currentNotebook?.docIds.first }
        saveNow()
    }

    @discardableResult
    func importPDF(_ url: URL, open: Bool = false) -> UUID? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        let title = url.deletingPathExtension().lastPathComponent
        // same file imported before? reuse
        if let existing = lib.docs.first(where: { !$0.isWeb && $0.title == title }),
           let a = try? Data(contentsOf: Paths.pdf(existing.id)), let b = try? Data(contentsOf: url), a == b {
            addDocToNotebook(existing.id)
            #if os(macOS)
            if open { DocWindows.shared.open(existing.id) }
            #else
            if open { openDoc(existing.id) }
            #endif
            return existing.id
        }
        let d = Doc(title: title, kind: .pdf, tags: [DocStatusTag.todo.rawValue], pageCount: pdf.pageCount, readPage: nil, updatedAt: Date())
        do { try FileManager.default.copyItem(at: url, to: Paths.pdf(d.id)) } catch { return nil }
        lib.docs.append(d)
        addDocToNotebook(d.id)
        saveNow()
        #if os(macOS)
        if open { DocWindows.shared.open(d.id) }
        #else
        if open { openDoc(d.id) }
        #endif
        return d.id
    }

    /// Imports an interactive webpage by URL only (no PDF or HTML copy stored on disk; preserves live DOM interactivity).
    @discardableResult
    func importWebURL(_ rawURL: String, title: String? = nil, cleanMode: Bool = true, open: Bool = false) -> UUID? {
        guard let normalized = WebURLResolver.normalizedInputURL(rawURL) else { return nil }
        let urlString = normalized.absoluteString
        let canonical = WebURLResolver.canonicalIdentity(urlString)
        let fragment = normalized.fragment?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existingIdx = lib.docs.firstIndex(where: {
            $0.isWeb && WebURLResolver.canonicalIdentity($0.source ?? "") == canonical
        }) {
            let existingId = lib.docs[existingIdx].id
            lib.docs[existingIdx].source = urlString
            if let fragment, !fragment.isEmpty {
                var anchor = lib.docs[existingIdx].webAnchor ?? WebReadingAnchor(anchorId: fragment, intraOffset: 0, scrollFraction: 0)
                anchor.anchorId = fragment
                lib.docs[existingIdx].webAnchor = anchor
            }
            lib.docs[existingIdx].updatedAt = Date()
            addDocToNotebook(existingId)
            saveNow()
            #if os(macOS)
            if open { DocWindows.shared.open(existingId) }
            #else
            if open { openDoc(existingId) }
            #endif
            return existingId
        }

        let initialTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? WebURLResolver.fallbackTitle(for: urlString)
        let initialAnchor: WebReadingAnchor? = {
            guard let fragment, !fragment.isEmpty else { return nil }
            return WebReadingAnchor(anchorId: fragment, intraOffset: 0, scrollFraction: 0)
        }()
        let d = Doc(
            title: initialTitle,
            kind: .web,
            source: urlString,
            webCleanMode: cleanMode,
            webHiddenSelectors: [],
            webAnchor: initialAnchor,
            tags: [DocStatusTag.todo.rawValue],
            pageCount: nil,
            readPage: 0,
            updatedAt: Date()
        )
        _ = Paths.docDir(d.id)
        lib.docs.append(d)
        addDocToNotebook(d.id)
        saveNow()
        #if os(macOS)
        if open { DocWindows.shared.open(d.id) }
        #else
        if open { openDoc(d.id) }
        #endif
        return d.id
    }

    func setSource(_ docId: UUID, _ url: String) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        lib.docs[i].source = url
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    /// Toggles automatic peripheral content removal (`webCleanMode`) per article.
    func setWebCleanMode(_ docId: UUID, _ enabled: Bool) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        guard lib.docs[i].webCleanMode != enabled else { return }
        lib.docs[i].webCleanMode = enabled
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    func toggleWebCleanMode(_ docId: UUID) -> Bool {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return true }
        lib.docs[i].webCleanMode.toggle()
        let next = lib.docs[i].webCleanMode
        lib.docs[i].updatedAt = Date()
        saveNow()
        return next
    }

    func addWebHiddenSelector(_ docId: UUID, _ selector: String) {
        let s = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        if !lib.docs[i].webHiddenSelectors.contains(s) {
            lib.docs[i].webHiddenSelectors.append(s)
            lib.docs[i].updatedAt = Date()
            saveNow()
        }
    }

    func clearWebHiddenSelectors(_ docId: UUID) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        guard !lib.docs[i].webHiddenSelectors.isEmpty else { return }
        lib.docs[i].webHiddenSelectors.removeAll()
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    /// Updates continuous viewport-independent reading progress for `.web` documents.
    func updateWebReadingProgress(
        docId: UUID,
        anchor: WebReadingAnchor,
        sectionCount: Int? = nil,
        discoveredTitle: String? = nil
    ) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        let now = Date()
        var changed = false

        if let discoveredTitle = discoveredTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !discoveredTitle.isEmpty {
            let fallback = WebURLResolver.fallbackTitle(for: lib.docs[i].source ?? "")
            if lib.docs[i].title == fallback || lib.docs[i].title == lib.docs[i].source {
                lib.docs[i].title = discoveredTitle
                #if os(macOS)
                DocWindows.shared.entries[docId]?.window.title = discoveredTitle
                #endif
                changed = true
            }
        }

        if let sectionCount, sectionCount > 0, lib.docs[i].pageCount != sectionCount {
            lib.docs[i].pageCount = sectionCount
            changed = true
        }

        let clampedFraction = min(1.0, max(0.0, anchor.scrollFraction))
        var normalizedAnchor = anchor
        normalizedAnchor.scrollFraction = clampedFraction
        let secIndex = max(0, anchor.sectionIndex ?? lib.docs[i].readPage ?? 0)

        let prevPermille = lib.docs[i].webAnchor?.progressPermille ?? -1
        let newPermille = normalizedAnchor.progressPermille
        let anchorMovedMeaningfully = abs(newPermille - prevPermille) >= 5
            || lib.docs[i].webAnchor?.anchorId != normalizedAnchor.anchorId
            || lib.docs[i].readPage != secIndex

        if anchorMovedMeaningfully {
            lib.docs[i].webAnchor = normalizedAnchor
            lib.docs[i].readPage = secIndex
            lib.docs[i].readUpdatedAt = now
            lib.docs[i].lastReadDevice = DeviceIdentity.currentDeviceName
            lib.docs[i].lastReadDeviceId = DeviceIdentity.currentDeviceId
            lib.docs[i].pendingConflict = nil
            lib.docs[i].recordDeviceSnapshot(
                page: secIndex,
                webAnchor: normalizedAnchor,
                at: now
            )
            UserDefaults.standard.set(secIndex, forKey: "page-" + docId.uuidString)
            changed = true
        } else {
            let dayKey = DeviceIdentity.todayDateKey(now)
            let newPct = normalizedAnchor.progressPercent
            if (lib.docs[i].dailyReadingLog[dayKey] ?? -1) < newPct {
                lib.docs[i].dailyReadingLog[dayKey] = newPct
                changed = true
            }
        }

        if lib.docs[i].statusTag == .todo && (clampedFraction >= 0.03 || secIndex > 0) {
            var custom = lib.docs[i].customTags
            custom.insert(DocStatusTag.doing.rawValue, at: 0)
            lib.docs[i].tags = custom
            changed = true
        } else if lib.docs[i].statusTag == .doing && clampedFraction >= 0.96 {
            var custom = lib.docs[i].customTags
            custom.insert(DocStatusTag.done.rawValue, at: 0)
            lib.docs[i].tags = custom
            changed = true
        }

        if changed {
            lib.docs[i].updatedAt = now
            save()
        }
    }

    // MARK: - Document Tags & Reading Progress

    /// Sets or clears the mutually exclusive status tag (`TODO`, `DOING`, `DONE`) while preserving custom tags.
    func setStatusTag(_ docId: UUID, _ status: DocStatusTag?) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        var custom = lib.docs[i].customTags
        if let status {
            custom.insert(status.rawValue, at: 0)
        }
        lib.docs[i].tags = custom
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    /// Cycles status tag: `nil -> TODO -> DOING -> DONE -> TODO`
    func cycleStatusTag(_ docId: UUID) {
        guard let d = doc(docId) else { return }
        let next: DocStatusTag
        switch d.statusTag {
        case nil: next = .todo
        case .todo: next = .doing
        case .doing: next = .done
        case .done: next = .todo
        }
        setStatusTag(docId, next)
    }

    func addTag(_ docId: UUID, _ rawTag: String) {
        let t = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        if let st = DocStatusTag(rawValue: t.uppercased()) {
            setStatusTag(docId, st)
            return
        }
        if !lib.docs[i].tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) {
            lib.docs[i].tags.append(t)
            lib.docs[i].updatedAt = Date()
            saveNow()
        }
    }

    func removeTag(_ docId: UUID, _ tag: String) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        lib.docs[i].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    func toggleTag(_ docId: UUID, _ tag: String) {
        guard let d = doc(docId) else { return }
        if let st = DocStatusTag(rawValue: tag.uppercased()) {
            setStatusTag(docId, d.statusTag == st ? nil : st)
        } else if d.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            removeTag(docId, tag)
        } else {
            addTag(docId, tag)
        }
    }

    var allCustomTags: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in lib.docs {
            for t in d.customTags {
                let key = t.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    out.append(t)
                }
            }
        }
        return out
    }

    /// Updates reading progress for `docId` and automatically transitions `TODO -> DOING` (or `DONE` on the last page if appropriate).
    func updateReadingProgress(docId: UUID, page: Int, pageCount: Int) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        let clampedPage = min(max(0, page), max(0, pageCount - 1))
        let now = Date()
        var changed = false
        if lib.docs[i].pageCount != pageCount {
            lib.docs[i].pageCount = pageCount
            changed = true
        }
        if lib.docs[i].readPage != clampedPage {
            lib.docs[i].readPage = clampedPage
            lib.docs[i].readUpdatedAt = now
            lib.docs[i].lastReadDevice = DeviceIdentity.currentDeviceName
            lib.docs[i].lastReadDeviceId = DeviceIdentity.currentDeviceId
            lib.docs[i].pendingConflict = nil
            lib.docs[i].recordDeviceSnapshot(page: clampedPage, at: now)
            UserDefaults.standard.set(clampedPage, forKey: "page-" + docId.uuidString)
            changed = true
        } else {
            let dayKey = DeviceIdentity.todayDateKey(now)
            if (lib.docs[i].dailyReadingLog[dayKey] ?? -1) < clampedPage {
                lib.docs[i].dailyReadingLog[dayKey] = clampedPage
                changed = true
            }
        }
        // Automatically transition TODO -> DOING when the user reads past page 1
        if lib.docs[i].statusTag == .todo && clampedPage > 0 {
            var custom = lib.docs[i].customTags
            custom.insert(DocStatusTag.doing.rawValue, at: 0)
            lib.docs[i].tags = custom
            changed = true
        }
        if changed {
            lib.docs[i].updatedAt = now
            save()
        }
    }

    func updateNarrationProgress(docId: UUID, page: Int, seg: Int, date: Date = Date()) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        let clampedPage = max(0, page)
        let clampedSeg = max(0, seg)
        guard lib.docs[i].narrationPage != clampedPage || lib.docs[i].narrationSeg != clampedSeg else { return }
        lib.docs[i].narrationPage = clampedPage
        lib.docs[i].narrationSeg = clampedSeg
        lib.docs[i].narrationUpdatedAt = date
        lib.docs[i].lastNarrationDevice = DeviceIdentity.currentDeviceName
        lib.docs[i].recordDeviceSnapshot(
            page: lib.docs[i].readPage ?? clampedPage,
            narrationPage: clampedPage,
            narrationSeg: clampedSeg,
            webAnchor: lib.docs[i].webAnchor,
            at: date
        )
        lib.docs[i].updatedAt = date
        save()
    }

    func clearNarrationProgress(docId: UUID) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        lib.docs[i].narrationPage = nil
        lib.docs[i].narrationSeg = nil
        lib.docs[i].narrationUpdatedAt = Date()
        lib.docs[i].updatedAt = Date()
        save()
    }

    /// Resolves a cross-device progress conflict by choosing either the local or remote snapshot, or restores any device snapshot.
    func resolveProgressConflict(_ docId: UUID, useRemote: Bool) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }),
              let conflict = lib.docs[i].pendingConflict else { return }
        let chosenPage = useRemote ? conflict.remotePage : conflict.localPage
        let chosenNarrPage = useRemote ? conflict.remoteNarrationPage : conflict.localNarrationPage
        let chosenNarrSeg = useRemote ? conflict.remoteNarrationSeg : conflict.localNarrationSeg
        let chosenAnchor = useRemote ? conflict.remoteWebAnchor : conflict.localWebAnchor
        restoreProgressSnapshot(docId, page: chosenPage, narrationPage: chosenNarrPage, narrationSeg: chosenNarrSeg, webAnchor: chosenAnchor)
    }

    func dismissProgressConflict(_ docId: UUID) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        lib.docs[i].pendingConflict = nil
        lib.docs[i].readUpdatedAt = Date()
        lib.docs[i].updatedAt = Date()
        saveNow()
    }

    func restoreProgressSnapshot(_ docId: UUID, page: Int, narrationPage: Int? = nil, narrationSeg: Int? = nil, webAnchor: WebReadingAnchor? = nil) {
        guard let i = lib.docs.firstIndex(where: { $0.id == docId }) else { return }
        let total = max(1, lib.docs[i].pageCount ?? 9999)
        let clampedPage = min(max(0, page), total - 1)
        let now = Date()
        lib.docs[i].readPage = clampedPage
        if let webAnchor {
            lib.docs[i].webAnchor = webAnchor
        }
        lib.docs[i].readUpdatedAt = now
        lib.docs[i].lastReadDevice = DeviceIdentity.currentDeviceName
        lib.docs[i].lastReadDeviceId = DeviceIdentity.currentDeviceId
        if let np = narrationPage {
            lib.docs[i].narrationPage = max(0, np)
            lib.docs[i].narrationSeg = max(0, narrationSeg ?? 0)
            lib.docs[i].narrationUpdatedAt = now
            lib.docs[i].lastNarrationDevice = DeviceIdentity.currentDeviceName
        }
        lib.docs[i].pendingConflict = nil
        lib.docs[i].recordDeviceSnapshot(
            page: clampedPage,
            narrationPage: lib.docs[i].narrationPage,
            narrationSeg: lib.docs[i].narrationSeg,
            webAnchor: lib.docs[i].webAnchor,
            at: now
        )
        lib.docs[i].updatedAt = now
        UserDefaults.standard.set(clampedPage, forKey: "page-" + docId.uuidString)
        saveNow()

        #if os(macOS)
        if let entry = DocWindows.shared.entries[docId] {
            if let webAnchor {
                entry.reader.applyRemoteSyncedWebAnchor(webAnchor)
            } else {
                entry.reader.goToPage(clampedPage)
            }
        }
        #elseif os(iOS)
        if ReaderController.shared.docId == docId {
            if let webAnchor {
                ReaderController.shared.applyRemoteSyncedWebAnchor(webAnchor)
            } else {
                ReaderController.shared.goToPage(clampedPage)
            }
        }
        #endif
    }

    func addDocToNotebook(_ docId: UUID, notebook: UUID? = nil) {
        guard let i = lib.notebooks.firstIndex(where: { $0.id == (notebook ?? currentNotebookId) }) else { return }
        if !lib.notebooks[i].docIds.contains(docId) {
            lib.notebooks[i].docIds.append(docId)
            lib.notebooks[i].updatedAt = Date()
        }
        saveNow()
    }

    func renameDoc(_ id: UUID, _ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = lib.docs.firstIndex(where: { $0.id == id }) else { return }
        lib.docs[i].title = t
        lib.docs[i].updatedAt = Date()
        #if os(macOS)
        DocWindows.shared.entries[id]?.window.title = t
        #endif
        saveNow()
    }

    func removeDocFromNotebook(_ docId: UUID) {
        registerUndo(L("从笔记本移除"))
        updateNotebook { $0.docIds.removeAll { $0 == docId } }
        if currentDocId == docId { currentDocId = currentNotebook?.docIds.first }
    }

    func deleteDoc(_ docId: UUID) {
        let cardIds = Set(lib.cards.filter { $0.docId == docId }.map { $0.id })
        CloudSync.shared.recordDeletions([docId] + Array(cardIds))
        lib.docs.removeAll { $0.id == docId }
        for i in lib.notebooks.indices { lib.notebooks[i].docIds.removeAll { $0 == docId } }
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
        lib.cards[i].updatedAt = Date()
        let c = lib.cards[i]
        sessions[c.docId]?.refreshAnnotations(for: c)
        save()
    }

    func deleteCard(_ id: UUID) {
        guard let c = card(id) else { return }
        registerUndo(L("删除卡片"))
        CloudSync.shared.recordDeletion(id)
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
        #if os(macOS)
        if let e = DocWindows.shared.entries[card.docId] {
            e.window.makeKeyAndOrderFront(nil)
            if e.reader.variant != card.variant { e.reader.setVariant(card.variant) }
            DispatchQueue.main.asyncAfter(deadline: .now() + (e.reader.variant == card.variant ? 0 : 0.3)) { e.reader.jump(to: card) }
        } else {
            UserDefaults.standard.set(card.variant.rawValue, forKey: "variant-" + card.docId.uuidString)
            DocWindows.shared.open(card.docId, jump: card)
        }
        #else
        currentDocId = card.docId
        variant = card.variant
        pendingJump = card
        ReaderController.shared.setVariant(card.variant)
        ReaderController.shared.jump(to: card)
        #endif
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
        registerUndo(L("删除主题"))
        CloudSync.shared.recordDeletion(id)
        let parent = nb.root.parentOf(id)
        updateNotebook { nb in _ = nb.root.remove(id) }
        selectedNodeId = parent?.id
    }

    func toggleCollapse(_ id: UUID) { updateNotebook { nb in nb.root.mutate(id) { $0.collapsed.toggle() } } }

    func moveNode(_ id: UUID, under newParent: UUID) {
        guard let nb = currentNotebook, id != nb.root.id, id != newParent,
              let node = nb.root.find(id), !node.contains(newParent) else { return }
        registerUndo(L("移动主题"))
        updateNotebook { nb in
            if let n = nb.root.remove(id) { nb.root.mutate(newParent) { $0.children.append(n); $0.collapsed = false } }
        }
    }

    func shift(_ id: UUID, by delta: Int) {
        guard let nb = currentNotebook, let parent = nb.root.parentOf(id) else { return }
        registerUndo(L("移动主题"))
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
        registerUndo(L("移动主题"))
        updateNotebook { nb in
            guard let n = nb.root.remove(id) else { return }
            nb.root.mutate(grand.id) { g in
                let i = (g.children.firstIndex { $0.id == parent.id } ?? g.children.count - 1) + 1
                g.children.insert(n, at: i)
            }
        }
    }

    // MARK: undo — snapshot of the whole library (cheap value copy), registered on the key window

    private let fallbackUndo = UndoManager()
    private var undoManager: UndoManager {
        #if os(macOS)
        return NSApp.keyWindow?.undoManager ?? fallbackUndo
        #else
        return fallbackUndo
        #endif
    }

    /// call before a user-initiated destructive edit; ⌘Z restores the library as it was
    func registerUndo(_ name: String) {
        let before = lib
        let um = undoManager
        um.registerUndo(withTarget: self) { s in MainActor.assumeIsolated { s.restore(before, name: name, um: um) } }
        um.setActionName(name)
    }

    private func restore(_ snapshot: Library, name: String, um: UndoManager) {
        let current = lib
        um.registerUndo(withTarget: self) { s in MainActor.assumeIsolated { s.restore(current, name: name, um: um) } }
        um.setActionName(name)
        let gone = Set(current.cards.map(\.id)).subtracting(snapshot.cards.map(\.id))
        lib = snapshot
        for ses in sessions.values {
            for id in gone { ses.removeAnnotations(cardId: id) }
            ses.applyAnnotations()
        }
        if let sel = selectedCardId, card(sel) == nil { selectedCardId = nil }
        if let n = selectedNodeId, !(currentNotebook?.root.contains(n) ?? false) { selectedNodeId = nil }
        save()
    }

    /// put an existing card into the mind map (e.g. dragged from the card list)
    func attachCard(_ cardId: UUID, under parent: UUID) {
        guard let nb = currentNotebook else { return }
        if let existing = nb.root.nodeFor(card: cardId) { moveNode(existing.id, under: parent); return }
        updateNotebook { nb in nb.root.mutate(parent) { $0.children.append(MindNode(title: "", cardId: cardId)); $0.collapsed = false } }
    }

    func nodeTitle(_ n: MindNode) -> String {
        if !n.title.isEmpty { return n.title }
        if let c = card(n.cardId) { return c.text.isEmpty ? (c.isImage ? L("［图片摘录］") : L("（空）")) : c.text }
        return "（空）"
    }
}
