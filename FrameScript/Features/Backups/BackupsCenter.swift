import Foundation
import FrameScriptCore
import OSLog

/// Last automatic-backup failure, shown in the backups sheet so a broken
/// folder does not leave the user with zero backups and only a log entry.
@MainActor
@Observable
final class BackupHealth {
    static let shared = BackupHealth()

    private(set) var lastFailure: BackupFailure?

    private init() {}

    func record(_ failure: BackupFailure) {
        lastFailure = failure
    }

    func clear() {
        lastFailure = nil
    }
}

/// App-facing entry points for F29 automatic backups.
///
/// The pure copy/rotation rules live in `FrameScriptCore.BackupStore`; this
/// type only supplies the app's default location, project identity and the
/// light in-memory throttle that keeps autosave off the backup folder.
@MainActor
enum BackupsCenter {
    static let store = BackupStore(rootDirectory: rootDirectory)

    /// The app unit tests host the real app, so they must never touch the
    /// user's real backup folder. Production keeps the documented location.
    static var rootDirectory: URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "FrameScriptAppTestBackups-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        return BackupStore.defaultRootDirectory
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Backups"
    )

    /// Last time a backup was attempted per project. The Core policy remains
    /// authoritative for retention; this only avoids listing the folder on
    /// every 10-second autosave.
    private static var lastAttempt: [String: Date] = [:]

    static func projectID(for project: FrameProject, fileURL: URL) -> String {
        BackupProjectIdentity.identifier(projectUUID: project.id, fileURL: fileURL)
    }

    /// Copies the current project file before it is overwritten. Failures are
    /// logged and surfaced in the backups sheet, never interrupting saving.
    static func backUpBeforeOverwrite(project: FrameProject, fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let identity = projectID(for: project, fileURL: fileURL)
        let now = Date()
        if let last = lastAttempt[identity],
           now.timeIntervalSince(last) < max(0, store.policy.minimumInterval) {
            return
        }
        lastAttempt[identity] = now

        // Shared Core helper so future CLI/MCP writes use the same rules.
        switch store.backUpBeforeOverwrite(projectUUID: project.id, fileURL: fileURL) {
        case let .created(_, warning):
            BackupHealth.shared.clear()
            if let warning {
                logger.warning(
                    "Backup warning (\(warning.operation.rawValue, privacy: .public)): \(warning.reason, privacy: .public)"
                )
            }
        case let .failed(failure):
            logger.error(
                "Backup failed (\(failure.operation.rawValue, privacy: .public)): \(failure.reason, privacy: .public)"
            )
            BackupHealth.shared.record(failure)
        case .skipped:
            break
        }
    }
}
