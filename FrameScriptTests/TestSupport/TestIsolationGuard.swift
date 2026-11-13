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
    static func failureMessage(phase: String, testName: String) -> String? {
        guard AppEnvironment.isRunningTests,
              let baseline = TestIsolationBaseline.initial else { return nil }
        let current = TestIsolationBaseline.current()
        guard current.appValues != baseline.appValues || current.settingsBlob != baseline.settingsBlob else {
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
        var keys = Set(current.appValues.keys).symmetricDifference(Set(baseline.appValues.keys))
        keys.formUnion(current.appValues.compactMap { key, value in
            baseline.appValues[key] == value ? nil : key
        })
        if current.settingsBlob != baseline.settingsBlob {
            keys.insert("FrameScript.settings.v1")
        }
        return keys.sorted()
    }
}
