import Foundation
import XCTest

/// Owns an isolated `UserDefaults` suite and every artefact it creates.
///
/// The suite name is an absolute path inside the process temporary directory,
/// so CFPreferences writes `<path>.plist` there instead of
/// `~/Library/Preferences`. `cleanup()` also removes the classic
/// `~/Library/Preferences/<suite>.plist` file in case a named fallback suite
/// was used, and deletes the temporary directory.
final class TestDefaults {
    let suiteName: String
    let defaults: UserDefaults

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var suiteRegistry: Set<String> = []

    /// Every suite this process created, used by the isolation guard.
    static var registeredSuiteNames: Set<String> {
        registryLock.withLock { suiteRegistry }
    }

    private let directory: URL?
    private let lock = NSLock()
    private var didCleanup = false

    private init(suiteName: String, defaults: UserDefaults, directory: URL?) {
        self.suiteName = suiteName
        self.defaults = defaults
        self.directory = directory
        Self.registryLock.withLock { Self.suiteRegistry.insert(suiteName) }
    }

    /// Creates a fresh, empty, isolated defaults suite for one test.
    static func make() -> TestDefaults {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptTestDefaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suiteURL = directory.appendingPathComponent("defaults")
        if let defaults = UserDefaults(suiteName: suiteURL.path) {
            defaults.removePersistentDomain(forName: suiteURL.path)
            return TestDefaults(suiteName: suiteURL.path, defaults: defaults, directory: directory)
        }

        // Practically unreachable on macOS, but never fall back to `.standard`.
        let fallbackName = "FrameScript.TestDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: fallbackName) ?? UserDefaults()
        defaults.removePersistentDomain(forName: fallbackName)
        return TestDefaults(suiteName: fallbackName, defaults: defaults, directory: directory)
    }

    /// Removes the persistent domain, the isolated plist and the temp folder.
    /// Safe to call more than once (for example from `deinit`).
    func cleanup() {
        lock.lock()
        guard !didCleanup else {
            lock.unlock()
            return
        }
        didCleanup = true
        lock.unlock()

        defaults.removePersistentDomain(forName: suiteName)

        let suitePlist = URL(fileURLWithPath: suiteName + ".plist")
        try? FileManager.default.removeItem(at: suitePlist)

        // Named suites (older tests and the fallback above) persist here.
        if !suiteName.hasPrefix("/") {
            let preferencesPlist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences", isDirectory: true)
                .appendingPathComponent("\(suiteName).plist")
            try? FileManager.default.removeItem(at: preferencesPlist)
        }

        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        cleanup()
    }
}

/// Base class for tests that need preferences.
///
/// One isolated suite is created lazily per test instance (XCTest creates a
/// fresh instance per test method) and is always removed in `tearDown`, even
/// when the test fails.
class FrameScriptTestCase: XCTestCase {
    private var isolatedTestDefaults: TestDefaults?

    override func setUp() {
        super.setUp()
        failIfRealDomainChanged(phase: "before")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        failIfRealDomainChanged(phase: "before")
    }

    func makeTestDefaults() -> TestDefaults {
        if let isolatedTestDefaults { return isolatedTestDefaults }
        let made = TestDefaults.make()
        isolatedTestDefaults = made
        return made
    }

    /// The injected defaults suite for this test method.
    func makeDefaults() -> UserDefaults {
        makeTestDefaults().defaults
    }

    override func tearDown() {
        failIfRealDomainChanged(phase: "after")
        cleanUpIsolatedDefaults()
        super.tearDown()
    }

    override func tearDownWithError() throws {
        failIfRealDomainChanged(phase: "after")
        cleanUpIsolatedDefaults()
        try super.tearDownWithError()
    }

    private func cleanUpIsolatedDefaults() {
        isolatedTestDefaults?.cleanup()
        isolatedTestDefaults = nil
    }

    private func failIfRealDomainChanged(phase: String) {
        guard let message = TestIsolationGuard.failureMessage(phase: phase, testName: name) else {
            return
        }
        XCTFail(message)
    }
}
