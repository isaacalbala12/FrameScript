import Foundation
import FrameScriptCore
import OSLog

/// Last automatic-backup failure, shown in the backups sheet so a broken
/// folder does not leave the user with zero backups and only a log entry.
/// Failures are keyed by project so switching documents does not show one
/// project's problem in another project's sheet.
@MainActor
@Observable
final class BackupHealth {
    static let shared = BackupHealth()

    private(set) var lastFailure: BackupFailure?
    private(set) var lastFailureProjectID: String?

    private init() {}

    func record(_ failure: BackupFailure, projectID: String) {
        lastFailure = failure
        lastFailureProjectID = projectID
    }

    func clear(projectID: String) {
        guard lastFailureProjectID == projectID else { return }
        lastFailure = nil
        lastFailureProjectID = nil
    }

    func failure(for projectID: String?) -> BackupFailure? {
        guard let projectID, projectID == lastFailureProjectID else { return nil }
        return lastFailure
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
        if AppEnvironment.isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "FrameScriptAppTestBackups-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        }
        return BackupStore.defaultRootDirectory
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

    /// Drops the throttle entry when a project closes so a reopened document
    /// starts with a clean interval.
    static func forget(projectID: String) {
        lastAttempt[projectID] = nil
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

        // Shared Core helper so future CLI/MCP writes use the same rules.
        let outcome = store.backUpBeforeOverwrite(projectUUID: project.id, fileURL: fileURL)
        handle(outcome, projectID: identity)
        // Only a created backup starts the interval. A transient failure must
        // not silence backups for the next ten minutes.
        if case .created = outcome {
            lastAttempt[identity] = now
        }
    }

    /// Saves the in-memory project as a forced safety copy before a reload
    /// replaces it. The bytes written here are the user's edits, not the
    /// external file, so a wrong "Reload" is always recoverable.
    static func backUpInMemoryProject(_ project: FrameProject, fileURL: URL) {        let identity = projectID(for: project, fileURL: fileURL)
        let data: Data
        do {
            data = try FrameScriptFileStore.encode(project: project)
        } catch {
            logger.error("In-memory backup encode failed: \(error.localizedDescription, privacy: .private)")
            return
        }
        let outcome = store.backUpData(
            data,
            originalFileName: fileURL.lastPathComponent,
            originalPath: fileURL.path,
            projectID: identity
        )
        handle(outcome, projectID: identity)
    }

    /// A Save As may target an existing file that belongs to another project.
    /// Back that file up under its own path identity before replacing it.
    static func backUpBeforeSaveAs(to url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let identity = BackupProjectIdentity.identifier(projectUUID: nil, fileURL: url)
        let outcome = store.backUpBeforeOverwrite(projectUUID: nil, fileURL: url, force: true)
        handle(outcome, projectID: identity)
    }

    private static func handle(_ outcome: BackupOutcome, projectID: String) {
        switch outcome {
        case let .created(_, warning):
            BackupHealth.shared.clear(projectID: projectID)
            if let warning {
                logger.warning(
                    "Backup warning (\(warning.operation.rawValue, privacy: .public)): \(warning.reason, privacy: .private)"
                )
            }
        case let .failed(failure):
            logger.error(
                "Backup failed (\(failure.operation.rawValue, privacy: .public)): \(failure.reason, privacy: .private)"
            )
            BackupHealth.shared.record(failure, projectID: projectID)
        case .skipped:
            break
        }
    }

    /// True when the in-memory minimum interval allows another automatic backup
    /// for this project. The core policy checks the backup folder as well; this
    /// only avoids listing it on every board write.
    @MainActor
    static func shouldAttemptBackup(projectID: String, now: Date = Date()) -> Bool {
        guard let last = lastAttempt[projectID] else { return true }
        return now.timeIntervalSince(last) >= max(0, store.policy.minimumInterval)
    }

    /// Records a backup outcome produced off the main actor (the board writes
    /// closed files in a detached task). Keeps the same logging, health
    /// reporting and minimum-interval bookkeeping as the synchronous path.
    @MainActor
    static func record(_ outcome: BackupOutcome, projectID: String, attemptedAt: Date = Date()) {
        handle(outcome, projectID: projectID)
        if case .created = outcome {
            lastAttempt[projectID] = attemptedAt
        }
    }
}
