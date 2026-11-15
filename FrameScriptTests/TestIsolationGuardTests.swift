import Foundation
@testable import FrameScript
import XCTest

/// Read-only tripwires for the whole app test bundle.
///
/// The baseline is captured in `FrameScriptApp.init`, before XCTest starts any
/// test, so a store that still reaches the real app domain fails here even if
/// it lives in another test class.
@MainActor
final class TestIsolationGuardTests: XCTestCase {
    func testRealStandardDomainIsUnchangedByTheTestSuite() throws {
        let baseline = try XCTUnwrap(
            TestIsolationBaseline.initial,
            "The app test host did not capture the standard-domain baseline at launch."
        )
        let current = TestIsolationBaseline.current()
        let currentValues = TestIsolationGuard.appValuesIgnoringLaunchMaintenance(current.appValues)
        let baselineValues = TestIsolationGuard.appValuesIgnoringLaunchMaintenance(baseline.appValues)
        let changedKeys = Set(currentValues.keys).symmetricDifference(Set(baselineValues.keys))
            + currentValues.keys.filter { key in
                guard let currentValue = currentValues[key],
                      let baselineValue = baselineValues[key] else { return false }
                return currentValue != baselineValue
            }

        XCTAssertEqual(
            currentValues,
            baselineValues,
            """
            The test suite wrote to the real com.drashko.FrameScript standard domain.
            Changed keys: \(Set(changedKeys).sorted().joined(separator: ", "))
            Before:
            \(baseline.appDescription)
            After:
            \(current.appDescription)
            """
        )
    }

    /// The launch-maintenance exemption must stay one key wide: the one-time
    /// window-frame purge flag is written by the app itself from another
    /// process, but every other key is still the test suite's responsibility.
    func testLaunchMaintenanceExemptionIgnoresOnlyThePurgeFlag() {
        let flag = LegacyWindowFrameKeys.purgeFlagKey
        let values: [String: Data] = [
            flag: Data("1".utf8),
            "FrameScript.settings.v1": Data("settings".utf8)
        ]

        let filtered = TestIsolationGuard.appValuesIgnoringLaunchMaintenance(values)

        XCTAssertNil(filtered[flag])
        XCTAssertEqual(filtered["FrameScript.settings.v1"], Data("settings".utf8))
        XCTAssertEqual(TestIsolationGuard.launchMaintenanceKeys, [flag])
    }

    func testRealSettingsLanguageProviderAndExportFolderAreUnchanged() throws {
        let baseline = try XCTUnwrap(
            TestIsolationBaseline.initial,
            "The app test host did not capture the standard-domain baseline at launch."
        )
        let current = TestIsolationBaseline.current()

        XCTAssertEqual(
            current.settingsBlob,
            baseline.settingsBlob,
            "The test suite rewrote FrameScript.settings.v1 in the real app domain."
        )

        guard let baselineBlob = baseline.settingsBlob,
              let currentBlob = current.settingsBlob else { return }
        let before = try JSONDecoder().decode(AppSettings.self, from: baselineBlob)
        let after = try JSONDecoder().decode(AppSettings.self, from: currentBlob)
        XCTAssertEqual(
            after.generalPreferences.language,
            before.generalPreferences.language,
            "The test suite changed the user's app language."
        )
        XCTAssertEqual(
            after.aiPreferences.provider,
            before.aiPreferences.provider,
            "The test suite changed the user's AI provider."
        )
        XCTAssertEqual(
            after.exportPreferences,
            before.exportPreferences,
            "The test suite changed the user's export preferences (default folder included)."
        )
    }

    func testTestSuitesNeverCreateARealPreferencesPlist() {
        let preferencesDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)

        for suiteName in TestDefaults.registeredSuiteNames {
            XCTAssertTrue(
                suiteName.hasPrefix(FileManager.default.temporaryDirectory.path),
                "TestDefaults used a named suite instead of a temporary path: \(suiteName)"
            )
            let preferenceFile = preferencesDirectory
                .appendingPathComponent("\(suiteName).plist")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: preferenceFile.path),
                "A test suite left \(preferenceFile.path) behind."
            )
        }

        // The app-host suite must also stay outside ~/Library/Preferences.
        XCTAssertFalse(
            AppEnvironment.testDefaultsSuiteURL.path.hasPrefix(preferencesDirectory.path),
            "The test host defaults suite points at the real preferences folder."
        )
        XCTAssertTrue(
            AppEnvironment.testDefaultsSuiteURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "The test host defaults suite must live in the temporary directory."
        )
    }

    func testAppEnvironmentUsesIsolatedDefaultsAndDirectories() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
        XCTAssertFalse(
            AppEnvironment.defaults === UserDefaults.standard,
            "App code in the test host must not use the standard defaults domain."
        )
        XCTAssertTrue(
            AppEnvironment.testDefaultsSuiteURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.path
            ),
            "The test defaults suite must live in the temporary directory."
        )
        XCTAssertTrue(
            AppEnvironment.applicationSupportDirectory.path.hasPrefix(
                FileManager.default.temporaryDirectory.path
            ),
            "Application Support must be redirected while testing."
        )
        XCTAssertFalse(
            AppEnvironment.applicationSupportDirectory.path
                .contains("/Library/Application Support/FrameScript")
        )
        XCTAssertTrue(
            AppEnvironment.recentsFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        )
    }

    func testKeychainIsReplacedByAnInMemoryStoreWhileTesting() throws {
        let account = "frame-script.isolation-guard.\(UUID().uuidString)"
        defer { try? KeychainStore.deleteAPIKey(account: account) }

        XCTAssertNil(try KeychainStore.readAPIKey(account: account))
        try KeychainStore.saveAPIKey("secret", account: account)
        XCTAssertEqual(try KeychainStore.readAPIKey(account: account), "secret")
        try KeychainStore.deleteAPIKey(account: account)
        XCTAssertNil(try KeychainStore.readAPIKey(account: account))
    }

    func testTestDefaultsHelperRemovesItsSuiteAndPlist() throws {
        let isolated = TestDefaults.make()
        isolated.defaults.set("value", forKey: "key")
        XCTAssertEqual(isolated.defaults.string(forKey: "key"), "value")
        XCTAssertFalse(
            isolated.suiteName.hasPrefix(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences").path
            )
        )

        isolated.cleanup()

        XCTAssertNil(isolated.defaults.string(forKey: "key"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.suiteName + ".plist"))
    }
}
