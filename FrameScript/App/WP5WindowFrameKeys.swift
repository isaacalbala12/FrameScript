import Foundation

/// One-time cleanup for the window-frame keys AppKit wrote before the main
/// scene had a stable root view type (tests P2-3).
///
/// Every launch used to add a new key whose name embedded
/// `String(reflecting:)` of a `private` generic view, i.e. a per-process heap
/// address: `NSWindow Frame SwiftUI.ModifiedContent<…(unknown context at
/// $1xxxxxxxx)…ThemedSceneRoot…>`. The fix is two-part — a stable
/// `WindowGroup(id:)` and a non-private `ThemedSceneRoot` — but the stale keys
/// stay in the user's preferences until they are removed once.
enum LegacyWindowFrameKeys {
    static let purgeFlagKey = "FrameScript.maintenance.purgedLegacyWindowFrameKeys.v1"

    static func isLegacyKey(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame ") && key.contains("(unknown context at ")
    }

    /// Every stale key in a persisted defaults domain.
    static func legacyKeys(inDomain domain: [String: Any]) -> [String] {
        domain.keys.filter(isLegacyKey)
    }

    /// Removes the stale keys once per installation from `domainName` (the app
    /// bundle identifier by default).
    ///
    /// Only the named persistent domain is inspected: `dictionaryRepresentation`
    /// also reports other domains, and a purge must never touch anything but the
    /// application's own preferences. Returns how many keys were removed. The
    /// flag is written even when nothing was found so the scan runs once.
    @discardableResult
    static func purgeIfNeeded(defaults: UserDefaults, domainName: String? = Bundle.main.bundleIdentifier) -> Int {
        guard !defaults.bool(forKey: purgeFlagKey) else { return 0 }
        let domain = domainName.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let staleKeys = legacyKeys(inDomain: domain)
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: purgeFlagKey)
        return staleKeys.count
    }
}
