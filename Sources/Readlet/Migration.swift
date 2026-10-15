import Foundation

/// One-time carry-over from builds released before the rename (bundle id `local.bireader.app`).
enum Migration {
    static let legacyBundleId = "local.bireader.app"

    static func run() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migrated.legacyPrefs"), Bundle.main.bundleIdentifier != legacyBundleId else { return }
        #if !MAS
        // not sandboxed: the old preferences domain is readable; keep anything already set in the new one
        if let old = d.persistentDomain(forName: legacyBundleId) {
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        }
        #endif
        d.set(true, forKey: "migrated.legacyPrefs")
    }
}
