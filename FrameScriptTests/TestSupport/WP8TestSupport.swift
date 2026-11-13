import Foundation
@testable import FrameScript
import XCTest

/// Shared polling helper for the app tests.
///
/// Tests must not guess a fixed sleep for work that is scheduled (autosave,
/// debounced metrics, editor delegates). Poll the observable condition instead
/// so a loaded machine only makes the test slower, never flaky.
@discardableResult
@MainActor
func waitUntil(
    _ description: String = "condition",
    timeout: Duration = .seconds(5),
    interval: Duration = .milliseconds(10),
    _ condition: @MainActor () -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now <= deadline else {
            XCTFail("Timed out waiting for \(description)")
            return false
        }
        try await Task.sleep(for: interval)
    }
    return true
}

/// Overload kept for the older `waitUntil({ … }, message:)` call sites in the
/// editor persistence tests.
@discardableResult
@MainActor
func waitUntil(
    _ condition: @MainActor () -> Bool,
    message: String = "condition",
    timeout: Duration = .seconds(5)
) async throws -> Bool {
    try await waitUntil(message, timeout: timeout, condition)
}

/// Deletes the per-run app test artefacts when the test process exits.
///
/// XCTest has no bundle-level teardown callback, so the backup root (keyed by
/// the process id) is removed with `atexit`. The path is derived exactly like
/// `BackupsCenter.rootDirectory` derives it during tests, without touching
/// `BackupsCenter` (which is `@MainActor`) from this context.
enum TestBundleCleanup {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didRegister = false
    nonisolated(unsafe) fileprivate static var backupRootPath: String?

    static func register() {
        lock.lock()
        guard !didRegister else {
            lock.unlock()
            return
        }
        didRegister = true
        backupRootPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "FrameScriptAppTestBackups-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            .path
        lock.unlock()
        atexit(cleanUpTestBundleAtExit)
    }
}

private func cleanUpTestBundleAtExit() {
    guard let path = TestBundleCleanup.backupRootPath else { return }
    try? FileManager.default.removeItem(atPath: path)
}
