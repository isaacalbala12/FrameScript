import Foundation
import FrameScriptCore
import OSLog

/// Result of a restore. `failed` carries the Core failure so the backups sheet
/// can show the operating-system reason instead of a generic message.
enum BackupRestoreOutcome: Equatable {
    case restored
    case cancelled
    case failed(BackupFailure)

    var didRestore: Bool {
        if case .restored = self { return true }
        return false
    }

    var failure: BackupFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }
}

@MainActor
extension AppState {
    /// File the current project is saved to, if any.
    var currentProjectFileURL: URL? {
        projectStore.currentFileURL
    }

    /// Stable backup folder id for the current project.
    var currentBackupProjectID: String? {
        if let url = BackupsPresentation.shared.targetFileURLOverride {
            if let identity = FrameScriptFileStore.projectIDInFile(at: url) {
                return BackupProjectIdentity.identifier(projectUUID: identity, fileURL: url)
            }
            return BackupProjectIdentity.identifier(projectUUID: nil, fileURL: url)
        }
        if let url = projectStore.currentFileURL {
            return BackupsCenter.projectID(for: project, fileURL: url)
        }
        // No project is open: the backups sheet still lists the failed file's
        // history so the user can recover from a corrupt document.
        if let url = failedOpenProjectFileURL {
            let identity = FrameScriptFileStore.projectIDInFile(at: url)
            return BackupProjectIdentity.identifier(projectUUID: identity, fileURL: url)
        }
        return nil
    }

    /// The file the backups sheet describes, open or not.
    var backupsProjectFileURL: URL? {
        BackupsPresentation.shared.targetFileURLOverride
            ?? projectStore.currentFileURL
            ?? failedOpenProjectFileURL
    }

    /// A restore writes over the open project file. When the sheet is showing a
    /// file that is not the open project, restoring is impossible and must not
    /// overwrite whatever project happens to be open.
    var canRestoreBackup: Bool {
        BackupsPresentation.shared.targetFileURLOverride == nil && projectStore.currentFileURL != nil
    }

    func showBackupsWindow() {
        BackupsPresentation.shared.targetFileURLOverride = nil
        BackupsPresentation.shared.isPresented = true
    }

    /// Opens the backups sheet for a specific file, even when another project is
    /// open (used by the failed-open error's recovery action).
    func showBackupsWindow(for url: URL) {
        failedOpenProjectFileURL = url
        BackupsPresentation.shared.targetFileURLOverride = url
        BackupsPresentation.shared.isPresented = true
    }

    /// Opens a backup as a new untitled project. The backup file itself is
    /// never modified and the current project file is not touched.
    @discardableResult
    func openBackupAsCopy(_ entry: BackupEntry) -> Bool {
        guard !refuseProjectChangeWhileRecording() else { return false }
        let restoredProject: FrameProject
        do {
            restoredProject = try FrameScriptFileStore.decodeProject(from: Data(contentsOf: entry.url))
            // A copy is a new project: give it its own identity and no AI
            // threads so future backups and runs do not land in the original.
            restoredProject.id = UUID()
            restoredProject.aiThreadMap = AIThreadMap()
        } catch {
            Self.backupLogger.error("Backup copy decode failed: \(error.localizedDescription, privacy: .private)")
            if let appError = AppError.project(error, fileURL: entry.url, operation: .read) {
                errorCenter.present(appError)
            }
            return false
        }

        guard closeProject() else { return false }

        projectStore.openProject(
            restoredProject,
            fileURL: nil,
            wordsPerMinute: durationWordsPerMinute(for: restoredProject),
            markUnsaved: true
        )
        editorState.selectedSceneID = restoredProject.scenes.sortedByOrder.first?.id
        editorState.selectedMode = .script
        isFocusModeEnabled = false
        return true
    }

    /// Restores a backup over the current project file. The current version is
    /// always backed up first (ignoring the automatic interval); the backup is
    /// decoded before anything is written, and if the safeguard cannot be
    /// written the restore is refused.
    @discardableResult
    func restoreBackup(_ entry: BackupEntry) -> BackupRestoreOutcome {
        guard !refuseProjectChangeWhileRecording() else { return .cancelled }
        guard canRestoreBackup,
              let destination = projectStore.currentFileURL,
              let projectID = currentBackupProjectID else {
            return .cancelled
        }

        // Validate the selected backup before touching the destination. A
        // corrupt backup must leave the current project file exactly as it was.
        // The bytes are kept in memory because saving unsaved edits can run
        // retention and remove the selected backup before the write.
        let backupData: Data
        let restoredProject: FrameProject
        do {
            backupData = try Data(contentsOf: entry.url)
            // Goes through the codec, so v1-v3 backups migrate before they are
            // written back as current-format documents.
            restoredProject = try FrameScriptFileStore.decodeProject(from: backupData)
        } catch {
            Self.backupLogger.error("Backup restore validation failed: \(error.localizedDescription, privacy: .private)")
            if let appError = AppError.project(error, fileURL: entry.url, operation: .read) {
                errorCenter.present(appError)
            }
            return .failed(BackupFailure(
                operation: .validateBackup,
                path: entry.url.path,
                reason: error.localizedDescription
            ))
        }

        if projectStore.hasUnsavedFileChanges, !saveProject() {
            return .cancelled
        }

        let previousSceneID = editorState.selectedSceneID
        let outcome = withFileAccess(to: destination) {
            BackupsCenter.store.restore(data: backupData, over: destination, projectID: projectID) { data in
                _ = try FrameScriptFileStore.decodeProject(from: data)
            }
        }

        switch outcome {
        case let .failed(failure):
            Self.backupLogger.error("Backup restore failed: \(failure.reason, privacy: .private)")
            return .failed(failure)
        case .restored:
            NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: self)
            projectStore.openProject(
                restoredProject,
                fileURL: destination,
                wordsPerMinute: durationWordsPerMinute(for: restoredProject),
                markUnsaved: false,
                recalculateDurations: false
            )
            projectStore.synchronizeTextSegments(
                splitMode: settings.generalPreferences.defaultSplitMode,
                wordsPerMinute: currentDurationWordsPerMinute,
                markUnsaved: false
            )
            // The restored bytes are on disk now. Track their hash so the next
            // save does not report them as an external change.
            startTrackingProjectFile(at: destination, data: backupData)
            let orderedScenes = restoredProject.scenes.sortedByOrder
            editorState.selectedSceneID = orderedScenes.contains(where: { $0.id == previousSceneID })
                ? previousSceneID
                : orderedScenes.first?.id
            editorState.selectedMode = .script
            return .restored
        }
    }

    /// Best-effort security scope wrapper. The app is moving away from the
    /// sandbox; this keeps restore working while it is still enabled.
    private func withFileAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }

    private static let backupLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Backups"
    )
}
