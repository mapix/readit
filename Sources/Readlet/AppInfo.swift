import Foundation

/// Build-edition facts. The Mac App Store edition is compiled with `-DMAS` (see build_mas.sh).
enum AppInfo {
    static let name = "Readlet"
    #if MAS
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif
    static let website = URL(string: "https://readit.novarock.io")!
    static var privacyURL: URL { website.appendingPathComponent("privacy.html") }
    static var supportURL: URL { website.appendingPathComponent("support.html") }
    static let issuesURL = URL(string: "https://github.com/mapix/readit/issues")!
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }

    /// OpenAI's "ChatGPT plan usage" is open to open-source, locally running apps. Readlet is open source and free
    /// in every edition, so it's available everywhere. If a paid or remotely hosted edition is ever offered, it needs
    /// OpenAI's approval first (https://openai.com/form/sign-in-with-chatgpt-interest/) — set READLET_SIWC=0 to hide it.
    static var chatGPTAvailable: Bool { ProcessInfo.processInfo.environment["READLET_SIWC"] != "0" }
    /// the App Store updates the App Store edition
    static var selfUpdates: Bool { !isAppStore }
    /// `api_key_command` runs a shell command — not possible inside the App Store sandbox
    static var shellCommands: Bool { !isAppStore }
}
