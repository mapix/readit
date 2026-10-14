import Foundation
import AppKit

/// Checks the website's `download/latest.json` for a newer release (on launch at most once a day, or on demand).
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct Release: Decodable { var version: String; var file: String?; var size: String?; var date: String?; var notes: String? }

    static var feedURL: URL {
        URL(string: ConfigFile.string("app.update_url") ?? "https://readit.novarock.io/download/latest.json")
            ?? URL(fileURLWithPath: "/")
    }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var d: UserDefaults { .standard }

    func checkOnLaunch() {
        if ConfigFile.string("app.check_updates") == "false" { return }
        let last = d.object(forKey: "updateCheckedAt") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func check(manual: Bool) async {
        d.set(Date(), forKey: "updateCheckedAt")
        var req = URLRequest(url: UpdateChecker.feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Readit/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rel = try? JSONDecoder().decode(Release.self, from: data) else {
            if manual { alert(L("检查更新失败"), L("暂时无法连接更新服务器，请稍后再试。"), buttons: [L("好")]) }
            return
        }
        let cur = UpdateChecker.currentVersion
        guard UpdateChecker.isNewer(rel.version, than: cur) else {
            if manual { alert(L("已是最新版本"), LF("Readit %@ 是目前的最新版本。", cur), buttons: [L("好")]) }
            return
        }
        if !manual, d.string(forKey: "updateSkipVersion") == rel.version { return }
        let info = [rel.size, rel.date.map { String($0.prefix(10)) }].compactMap { $0 }.joined(separator: " · ")
        let r = alert(LF("Readit %@ 可以更新了", rel.version),
                      LF("当前版本 %@。", cur) + (info.isEmpty ? "" : " " + info) + (rel.notes.map { "\n\n" + $0 } ?? ""),
                      buttons: [L("下载新版本"), L("稍后"), L("跳过这个版本")])
        switch r {
        case .alertFirstButtonReturn:
            let base = UpdateChecker.feedURL.deletingLastPathComponent()
            let u = rel.file.map { base.appendingPathComponent($0) } ?? URL(string: "https://readit.novarock.io/#download")!
            NSWorkspace.shared.open(u)
        case .alertThirdButtonReturn:
            d.set(rel.version, forKey: "updateSkipVersion")
        default: break
        }
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal()
    }

    /// "0.10.1" > "0.9.3"; missing parts count as 0; non-numeric suffixes ignored
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
