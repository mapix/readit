import Foundation

/// One-time carry-over from builds released before the rename (`local.bireader.app` and `io.novarock.readit`).
enum Migration {
    static let legacyBundleIds = ["io.novarock.readit", "local.bireader.app"]

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migrated.legacyPrefs") else { return }
        #if !MAS
        // not sandboxed: the old preferences domains are readable; keep anything already set in the new one
        for oldId in legacyBundleIds where Bundle.main.bundleIdentifier != oldId {
            if let old = d.persistentDomain(forName: oldId) {
                for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            }
        }
        #endif
        _ = ConfigFile.configDir
        d.set(true, forKey: "migrated.legacyPrefs")
    }
}
