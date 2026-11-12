import Foundation
import FrameScriptCore
import OSLog

/// App-facing entry points for F29 automatic backups.
///
/// The pure copy/rotation rules live in `FrameScriptCore.BackupStore`; this
/// type only supplies the app's default location and project identity.
@MainActor
enum BackupsCenter {
    static let store = BackupStore(rootDirectory: BackupStore.defaultRootDirectory)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Backups"
    )

    static func projectID(for project: FrameProject, fileURL: URL) -> String {
        BackupProjectIdentity.identifier(projectUUID: project.id, fileURL: fileURL)
    }

    /// Copies the current project file before it is overwritten. Failures are
    /// logged and never interrupt saving.
    static func backUpBeforeOverwrite(project: FrameProject, fileURL: URL) {
        let identity = projectID(for: project, fileURL: fileURL)
        guard case let .failed(failure) = store.backUpIfNeeded(fileURL: fileURL, projectID: identity) else {
            return
        }
        logger.error(
            "Backup failed (\(failure.operation.rawValue, privacy: .public)): \(failure.reason, privacy: .public)"
        )
    }
}
