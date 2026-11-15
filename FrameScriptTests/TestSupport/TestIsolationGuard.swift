import Foundation
import XCTest
@testable import FrameScript

/// Compares the real app domain with the launch baseline.
///
/// `FrameScriptTestCase` calls this before and after every test that uses
/// isolated preferences. The check lives in the normal XCTest lifecycle
/// instead of an `XCTestObservation` callback because `recordFailure` from the
/// observation center aborts the test host.
enum TestIsolationGuard {
    /// Keys the app writes about itself at launch. A non-test process (a
    /// UI-test run or a manual launch while this suite runs) updates them, so
    /// they cannot be attributed to the test suite. The list is deliberately
    /// one exact key wide: any other `FrameScript.*` write still fails.
    static let launchMaintenanceKeys: Set<String> = [LegacyWindowFrameKeys.purgeFlagKey]

    static func appValuesIgnoringLaunchMaintenance(_ values: [String: Data]) -> [String: Data] {
        values.filter { !launchMaintenanceKeys.contains($0.key) }
    }

    static func failureMessage(phase: String, testName: String) -> String? {
        guard AppEnvironment.isRunningTests,
              let baseline = TestIsolationBaseline.initial else { return nil }
        let current = TestIsolationBaseline.current()
        guard appValuesIgnoringLaunchMaintenance(current.appValues)
                != appValuesIgnoringLaunchMaintenance(baseline.appValues)
                || current.settingsBlob != baseline.settingsBlob else {
            return nil
        }

        let changed = changedKeys(baseline: baseline, current: current)
        let details = settingsDetails(current.settingsBlob)
        return """
        The real com.drashko.FrameScript domain changed \(phase) \(testName).
        Changed keys: \(changed.joined(separator: ", "))
        Current settings: \(details)
        Process: \(ProcessInfo.processInfo.processIdentifier)
        """
    }

    private static func settingsDetails(_ blob: Data?) -> String {
        guard let blob,
              let settings = try? JSONDecoder().decode(AppSettings.self, from: blob) else {
            return "unreadable"
        }
        return """
        language=\(settings.generalPreferences.language.rawValue) \
        provider=\(settings.aiPreferences.provider.rawValue) \
        exportFolder=\(settings.exportPreferences.defaultExportFolder)
        """
    }

    private static func changedKeys(
        baseline: TestIsolationBaseline.Baseline,
        current: TestIsolationBaseline.Baseline
    ) -> [String] {
        let baselineValues = appValuesIgnoringLaunchMaintenance(baseline.appValues)
        let currentValues = appValuesIgnoringLaunchMaintenance(current.appValues)
        var keys = Set(currentValues.keys).symmetricDifference(Set(baselineValues.keys))
        keys.formUnion(currentValues.compactMap { key, value in
            baselineValues[key] == value ? nil : key
        })
        if current.settingsBlob != baseline.settingsBlob {
            keys.insert("FrameScript.settings.v1")
        }
        return keys.sorted()
    }
}
