import AppKit
import Foundation
import OSLog

private let projectFileChangeLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
    category: "ProjectFileChanges"
)

/// External-change detection for the open `.fscr` file. The last read/write
/// fingerprint is kept in memory; a file-system source and app activation both
/// ask `checkForExternalProjectChanges()` to compare it with the file on disk.
extension AppState {
    func resetProjectFileTracking() {
        projectFileMonitor?.stop()
        projectFileMonitor = nil
        trackedProjectFileURL = nil
        trackedProjectFileSnapshot = nil
        declinedExternalProjectSnapshot = nil
    }

    func startTrackingProjectFile(at url: URL) {
        projectFileMonitor?.stop()
        trackedProjectFileURL = url
        declinedExternalProjectSnapshot = nil
        recordProjectFileSnapshot(at: url)
        let monitor = ProjectFileMonitor()
        monitor.start(watching: url) { [weak self] in
            self?.checkForExternalProjectChanges()
        }
        projectFileMonitor = monitor
    }

    func recordProjectFileSnapshot(at url: URL) {
        guard projectStore.currentFileURL == url else { return }
        do {
            trackedProjectFileSnapshot = try securityScope.withAccess(to: url) {
                try ProjectFileSnapshotReader.read(at: url)
            }
            trackedProjectFileURL = url
            declinedExternalProjectSnapshot = nil
        } catch {
            projectFileChangeLogger.error("Project file fingerprint read failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
        }
    }

    /// Called by the file monitor and when the app becomes active. Reloads
    /// silently when there are no local edits; otherwise asks what to do.
    func checkForExternalProjectChanges() {
        guard projectStore.hasOpenProject,
              !projectStore.isBuiltInDemo,
              !externalChangePromptIsActive,
              let url = projectStore.currentFileURL,
              let known = trackedProjectFileSnapshot,
              let disk = currentDiskSnapshot(at: url) else {
            return
        }
        if disk.contentHash == known.contentHash {
            trackedProjectFileSnapshot = disk
            return
        }
        if let declined = declinedExternalProjectSnapshot, declined.contentHash == disk.contentHash {
            return
        }
        if projectStore.hasUnsavedFileChanges {
            _ = resolveExternalProjectChange(diskSnapshot: disk, url: url)
        } else {
            _ = reloadProjectFromDisk()
        }
    }

    /// Must run before every write to the current project file. If the file
    /// changed outside FrameScript, the same reload/overwrite/copy prompt is
    /// used instead of clobbering the external version.
    func prepareProjectFileForWrite() -> ProjectFileWriteAuthorization {
        guard let url = projectStore.currentFileURL else { return .failed }
        guard trackedProjectFileURL == url, let known = trackedProjectFileSnapshot else {
            trackedProjectFileURL = url
            trackedProjectFileSnapshot = currentDiskSnapshot(at: url)
            return .proceed
        }
        guard let disk = currentDiskSnapshot(at: url) else {
            return resolveExternalProjectChange(diskSnapshot: nil, url: url)
        }
        if disk.contentHash == known.contentHash {
            trackedProjectFileSnapshot = disk
            return .proceed
        }
        return resolveExternalProjectChange(diskSnapshot: disk, url: url)
    }

    @discardableResult
    func reloadProjectFromDisk() -> Bool {
        guard let url = projectStore.currentFileURL else { return false }
        let previousSceneID = editorState.selectedSceneID
        let previousSceneIndex = projectStore.selectedSceneIndex(id: previousSceneID)
        let previousMode = editorState.selectedMode
        do {
            let project = try securityScope.withAccess(to: url) {
                try FrameScriptFileStore.read(from: url)
            }
            projectStore.openProject(
                project,
                fileURL: url,
                wordsPerMinute: settings.editorPreferences.wordsPerMinute,
                markUnsaved: false
            )
            projectStore.synchronizeTextSegments(
                splitMode: settings.generalPreferences.defaultSplitMode,
                wordsPerMinute: settings.editorPreferences.wordsPerMinute,
                markUnsaved: false
            )
            let orderedScenes = project.scenes.sortedByOrder
            let targetSceneID: UUID?
            if let previousSceneID, orderedScenes.contains(where: { $0.id == previousSceneID }) {
                targetSceneID = previousSceneID
            } else if let previousSceneIndex, orderedScenes.indices.contains(previousSceneIndex) {
                targetSceneID = orderedScenes[previousSceneIndex].id
            } else {
                targetSceneID = orderedScenes.first?.id
            }
            setEditorContextAfterFlush(sceneID: .some(targetSceneID), mode: previousMode)
            recordProjectFileSnapshot(at: url)
            return true
        } catch {
            Self.projectFilesLogger.error("Operation project-reload failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: url, operation: .read))
            return false
        }
    }

    /// Writes the in-memory project even though the file changed externally.
    /// Only used after the user explicitly chose "Keep Mine".
    @discardableResult
    func forceWriteProjectFile() -> Bool {
        guard let url = projectStore.currentFileURL else { return false }
        do {
            try securityScope.withAccess(to: url) {
                try projectStore.saveCurrentProject(wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            }
            recordProjectFileSnapshot(at: url)
            errorCenter.clearAutosaveFailureSuppression()
            return true
        } catch {
            Self.projectFilesLogger.error("Operation project-overwrite failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: url, operation: .write))
            return false
        }
    }

    private func resolveExternalProjectChange(
        diskSnapshot: ProjectFileSnapshot?,
        url: URL
    ) -> ProjectFileWriteAuthorization {
        guard !externalChangePromptIsActive else { return .failed }
        externalChangePromptIsActive = true
        defer { externalChangePromptIsActive = false }

        switch externalChangeResolution() {
        case .reload:
            return reloadProjectFromDisk() ? .handled : .failed
        case .keepMine:
            return forceWriteProjectFile() ? .handled : .failed
        case .saveCopy:
            let saved = saveProjectCopyHandler?() ?? saveProjectAs()
            if saved, let newURL = projectStore.currentFileURL {
                startTrackingProjectFile(at: newURL)
            }
            return saved ? .handled : .failed
        case .cancel:
            declinedExternalProjectSnapshot = diskSnapshot
            return .failed
        }
    }

    private func externalChangeResolution() -> ExternalProjectChangeResolution {
        if let externalChangeConfirmation {
            return externalChangeConfirmation()
        }
        let alert = NSAlert()
        alert.messageText = localized("dialog.externalChange.title")
        alert.informativeText = localized("dialog.externalChange.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("dialog.externalChange.reload"))
        alert.addButton(withTitle: localized("dialog.externalChange.keepMine"))
        alert.addButton(withTitle: localized("dialog.externalChange.saveCopy"))
        alert.addButton(withTitle: localized("project.unsaved.cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .reload
        case .alertSecondButtonReturn:
            return .keepMine
        case .alertThirdButtonReturn:
            return .saveCopy
        default:
            return .cancel
        }
    }

    private func currentDiskSnapshot(at url: URL) -> ProjectFileSnapshot? {
        do {
            return try securityScope.withAccess(to: url) {
                try ProjectFileSnapshotReader.read(at: url)
            }
        } catch {
            return nil
        }
    }

    private static func diagnosticCode(for error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}
