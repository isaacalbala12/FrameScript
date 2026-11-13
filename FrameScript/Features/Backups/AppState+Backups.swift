import Foundation
import FrameScriptCore

@MainActor
extension AppState {
    /// File the current project is saved to, if any.
    var currentProjectFileURL: URL? {
        projectStore.currentFileURL
    }

    /// Stable backup folder id for the current project.
    var currentBackupProjectID: String? {
        guard let url = projectStore.currentFileURL else { return nil }
        return BackupsCenter.projectID(for: project, fileURL: url)
    }

    func showBackupsWindow() {
        BackupsPresentation.shared.isPresented = true
    }

    /// Opens a backup as a new untitled project. The backup file itself is
    /// never modified and the current project file is not touched.
    @discardableResult
    func openBackupAsCopy(_ entry: BackupEntry) -> Bool {
        let restoredProject: FrameProject
        do {
            restoredProject = try FrameScriptFileStore.read(from: entry.url)
            // A copy is a new project: give it its own identity so future
            // backups do not land in the original project's folder.
            restoredProject.id = UUID()
        } catch {
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
    func restoreBackup(_ entry: BackupEntry) -> Bool {
        guard let destination = projectStore.currentFileURL,
              let projectID = currentBackupProjectID else {
            return false
        }

        // Validate the selected backup before touching the destination. A
        // corrupt backup must leave the current project file exactly as it was.
        // The bytes are kept in memory because saving unsaved edits can run
        // retention and remove the selected backup before the write.
        let backupData: Data
        let restoredProject: FrameProject
        do {
            backupData = try Data(contentsOf: entry.url)
            restoredProject = try FrameScriptFileStore.decoder
                .decode(FrameScriptFile.self, from: backupData)
                .makeProject()
        } catch {
            if let appError = AppError.project(error, fileURL: entry.url, operation: .read) {
                errorCenter.present(appError)
            }
            return false
        }

        if projectStore.hasUnsavedFileChanges, !saveProject() {
            return false
        }

        let previousSceneID = editorState.selectedSceneID
        let outcome = withFileAccess(to: destination) {
            BackupsCenter.store.restore(data: backupData, over: destination, projectID: projectID) { data in
                _ = try FrameScriptFileStore.decoder.decode(FrameScriptFile.self, from: data).makeProject()
            }
        }

        switch outcome {
        case .failed:
            return false
        case .restored:
            projectStore.openProject(
                restoredProject,
                fileURL: destination,
                wordsPerMinute: durationWordsPerMinute(for: restoredProject),
                markUnsaved: false
            )
            let orderedScenes = restoredProject.scenes.sortedByOrder
            editorState.selectedSceneID = orderedScenes.contains(where: { $0.id == previousSceneID })
                ? previousSceneID
                : orderedScenes.first?.id
            editorState.selectedMode = .script
            return true
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
}
