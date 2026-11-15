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

    /// Launch arguments the UI-test target passes to the app it drives. The
    /// UI-test app is a separate, non-XCTest process, so it needs its own
    /// isolation check (see `mustStayIsolated`).
    static let uiTestArgumentPrefix = "--framescript-ui-test"

    static func isLegacyKey(_ key: String) -> Bool {
        key.hasPrefix("NSWindow Frame ") && key.contains("(unknown context at ")
    }

    /// Every stale key in a persisted defaults domain.
    static func legacyKeys(inDomain domain: [String: Any]) -> [String] {
        domain.keys.filter(isLegacyKey)
    }

    static func isUITestLaunch(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix(uiTestArgumentPrefix) }
    }

    /// True in processes that must never write the user's real preferences.
    ///
    /// The XCTest host is caught by `AppEnvironment.isRunningTests`; the
    /// UI-test app is a production-mode process, so its launch arguments are
    /// the signal. Writing the one-time flag from either process used to make
    /// `TestIsolationGuardTests` fail when a build or a UI test ran in parallel
    /// with the unit tests.
    static var mustStayIsolated: Bool {
        AppEnvironment.isRunningTests
            || isUITestLaunch(arguments: ProcessInfo.processInfo.arguments)
    }

    /// Removes the stale keys once per installation from `domainName` (the app
    /// bundle identifier by default), using the app's own defaults domain.
    ///
    /// `defaults` defaults to `AppEnvironment.defaults`, which is the isolated
    /// suite under tests, and the call is skipped entirely in test processes so
    /// neither the flag nor a real-domain read can leak out.
    @discardableResult
    static func purgeIfNeeded(
        defaults: UserDefaults = AppEnvironment.defaults,
        domainName: String? = Bundle.main.bundleIdentifier
    ) -> Int {
        guard !mustStayIsolated else { return 0 }
        return purge(defaults: defaults, domainName: domainName)
    }

    /// The purge mechanics, without the process isolation guard.
    ///
    /// Only the named persistent domain is inspected: `dictionaryRepresentation`
    /// also reports other domains, and a purge must never touch anything but the
    /// application's own preferences. Returns how many keys were removed. The
    /// flag is written even when nothing was found so the scan runs once.
    @discardableResult
    static func purge(defaults: UserDefaults, domainName: String? = Bundle.main.bundleIdentifier) -> Int {
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
