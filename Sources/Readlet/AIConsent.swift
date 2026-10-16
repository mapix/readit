import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// App Review 5.1.2: before content goes to a third-party AI service, tell the user and ask once.
@MainActor
enum AIConsent {
    static let key = "aiConsent.v1"
    static var granted: Bool { UserDefaults.standard.bool(forKey: key) }
    static func grant() { UserDefaults.standard.set(true, forKey: key) }

    /// shows the one-time notice; throws when the user declines
    static func ensure() throws {
        if granted || ProcessInfo.processInfo.environment["BIREADER_SCRIPT"] != nil { return }
        #if os(macOS)
        let a = NSAlert()
        a.messageText = L("使用 AI 功能前请确认")
        a.informativeText = L("翻译、AI 解读、AI 助手、闪卡和脑图会把相关页面的文字（AI 解读还包括页面截图）发送给你在设置中配置的 AI 服务；在线语音会把讲稿文字发送给你选择的语音服务。Readlet 本身不收集、不存储你的任何数据。") + "\n\n" + LF("当前 AI 服务：%@", currentService)
        a.addButton(withTitle: L("同意并继续"))
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("隐私政策"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: grant()
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(AppInfo.privacyURL)
            throw TranslateError.bad(L("已取消：需要先同意发送内容给 AI 服务"))
        default:
            throw TranslateError.bad(L("已取消：需要先同意发送内容给 AI 服务"))
        }
        #else
        grant()
        #endif
    }

    static var currentService: String {
        if ModelConfig.style("chat") == .chatgpt { return "ChatGPT (OpenAI)" }
        return URL(string: Settings.baseURL)?.host ?? Settings.baseURL
    }
}
