import AppKit
import Foundation

/// Process-wide launch environment.
///
/// When FrameScript runs as the XCTest host it must never touch the real
/// user's preferences, Keychain items, recents, backups or Application Support
/// files. Every store that used to default to `UserDefaults.standard` now
/// defaults to `AppEnvironment.defaults`, which is an isolated suite living in
/// a per-process temporary directory during tests.
enum AppEnvironment {
    /// Explicit opt-in used by tooling that cannot set `XCTestConfigurationFilePath`.
    static let testIsolationLaunchArgument = "--framescript-test-isolation"
    static let testIsolationEnvironmentKey = "FS_TEST_ISOLATION"

    static var isRunningTests: Bool {
        detectTestProcess()
    }

    private static func detectTestProcess() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment[testIsolationEnvironmentKey] == "1" { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("XCTest") == true { return true }
        if ProcessInfo.processInfo.arguments.contains(testIsolationLaunchArgument) { return true }
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-XCTest") }) { return true }
        return NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTestObservationCenter") != nil
    }

    /// Root for every file the test host would otherwise write into the user's
    /// home directory. Production never reads this value.
    static let testRootDirectory: URL = {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FrameScriptTestHost-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// The suite name is an absolute path on purpose: CFPreferences then writes
    /// the plist inside the temporary directory instead of
    /// `~/Library/Preferences`, so a crashed test run cannot leave a stray
    /// `FrameScript.*` preference file behind.
    static let testDefaultsSuiteURL: URL = testRootDirectory
        .appendingPathComponent("TestDefaults")

    nonisolated(unsafe) static let testDefaults: UserDefaults = {
        if let defaults = UserDefaults(suiteName: testDefaultsSuiteURL.path) {
            return defaults
        }
        // Extremely unlikely fallback. It is still a named suite, never the
        // app's standard domain.
        return UserDefaults(suiteName: "FrameScript.TestHost.\(UUID().uuidString)") ?? .standard
    }()

    /// The defaults every store must use. Production keeps the normal domain.
    static var defaults: UserDefaults {
        isRunningTests ? testDefaults : .standard
    }

    /// Last line of defence for tests that still pass `UserDefaults.standard`
    /// explicitly: redirect it to the isolated suite instead of writing the
    /// user's real domain.
    static func isolatedDefaults(_ candidate: UserDefaults) -> UserDefaults {
        guard isRunningTests, candidate === UserDefaults.standard else { return candidate }
        return testDefaults
    }

    /// Reads only macOS-owned appearance keys and is never written to.
    static var systemDefaults: UserDefaults { .standard }

    static var applicationSupportDirectory: URL {
        if isRunningTests {
            return testRootDirectory.appendingPathComponent("Application Support", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameScript", isDirectory: true)
    }

    static var recentsFileURL: URL {
        applicationSupportDirectory.appendingPathComponent("recents.json")
    }

    /// Called once from the app entry point, before any store is created.
    @MainActor
    static func prepareForLaunch() {
        guard isRunningTests else { return }
        try? FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        // Keep the test host invisible and out of the user's way.
        NSApplication.shared.setActivationPolicy(.prohibited)
        atexit(cleanUpTestRootAtExit)
    }
}

/// `atexit` needs a C-compatible function, so it cannot capture the URL.
private func cleanUpTestRootAtExit() {
    UserDefaults().removePersistentDomain(forName: AppEnvironment.testDefaultsSuiteURL.path)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: AppEnvironment.testDefaultsSuiteURL.path + ".plist"))
    try? FileManager.default.removeItem(at: AppEnvironment.testRootDirectory)
}

/// Read-only snapshot of the real app domain taken at test-host launch.
///
/// `TestIsolationGuardTests` compares it after the test bundle has run, so any
/// store that still reaches the real domain fails the suite instead of quietly
/// polluting the user's Mac.
enum TestIsolationBaseline {
    struct Baseline: Equatable, Sendable {
        var appValues: [String: Data]
        var appDescription: String
        var settingsBlob: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedInitial: Baseline?

    static var initial: Baseline? {
        lock.withLock { storedInitial }
    }

    static func captureIfNeeded() {
        lock.lock()
        let alreadyCaptured = storedInitial != nil
        lock.unlock()
        guard AppEnvironment.isRunningTests, !alreadyCaptured else { return }

        let captured = current()
        lock.withLock {
            if storedInitial == nil {
                storedInitial = captured
            }
        }
    }

    static func current() -> Baseline {
        let domain = UserDefaults.standard.persistentDomain(
            forName: SandboxDataMigration.bundleIdentifier
        ) ?? [:]
        // AppKit writes window geometry and panel-size keys (`NSWindow Frame …`,
        // `NSOSPLastRootDirectory`, …) into the app domain. Those belong to the
        // running UI, not to the app's own data, and other processes may update
        // them concurrently. The guard owns the `FrameScript.*` keys.
        let appDomain = domain.filter { $0.key.hasPrefix("FrameScript") }
        let serialized = serializedDomain(appDomain)
        return Baseline(
            appValues: serialized.values,
            appDescription: serialized.description,
            settingsBlob: UserDefaults.standard.data(forKey: "FrameScript.settings.v1")
        )
    }

    /// Diagnostic list of preference files the test host can see. Other
    /// agents and the user's real app share this folder, so the guard only
    /// fails on files whose suite name this process actually registered.
    static func frameScriptPreferenceFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: preferencesDirectory.path
        )) ?? []
        return Set(names.filter { $0.hasPrefix("FrameScript") })
    }

    private static var preferencesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    private static func serializedDomain(_ domain: [String: Any]) -> (values: [String: Data], description: String) {
        let sorted = domain.sorted { $0.key < $1.key }
        var values: [String: Data] = [:]
        var descriptionLines: [String] = []
        for (key, value) in sorted {
            let data: Data
            if let plist = try? PropertyListSerialization.data(
                fromPropertyList: [key: value],
                format: .binary,
                options: 0
            ) {
                data = plist
            } else {
                data = Data(String(describing: value).utf8)
            }
            values[key] = data
            descriptionLines.append("\(key)=\(String(describing: value))")
        }
        return (values, descriptionLines.joined(separator: "\n"))
    }
}
