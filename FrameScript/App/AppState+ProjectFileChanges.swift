import AppKit
import Foundation
import FrameScriptCore
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
        reportedMissingProjectFileURL = nil
    }

    func startTrackingProjectFile(at url: URL) {
        projectFileMonitor?.stop()
        trackedProjectFileURL = url
        declinedExternalProjectSnapshot = nil
        recordProjectFileSnapshot(at: url)
        startProjectFileMonitor(at: url)
    }

    /// Starts tracking with the exact bytes that were decoded. The fingerprint is
    /// the hash of those bytes, not a later re-read that an external writer could
    /// already have replaced.
    func startTrackingProjectFile(at url: URL, data: Data) {
        projectFileMonitor?.stop()
        declinedExternalProjectSnapshot = nil
        recordProjectFileSnapshot(data: data, at: url)
        startProjectFileMonitor(at: url)
    }

    /// Records the baseline after a save: the bytes the writer produced when they
    /// are known, otherwise a read of the file.
    func startTrackingProjectFileAfterSave(at url: URL) {
        projectFileMonitor?.stop()
        declinedExternalProjectSnapshot = nil
        recordProjectFileSnapshotAfterSave(at: url)
        startProjectFileMonitor(at: url)
    }

    private func startProjectFileMonitor(at url: URL) {
        let monitor = ProjectFileMonitor(securityScope: securityScope)
        monitor.start(watching: url) { [weak self] in
            self?.checkForExternalProjectChanges()
        }
        projectFileMonitor = monitor
    }

    func recordProjectFileSnapshot(data: Data, at url: URL) {
        guard projectStore.currentFileURL == url else { return }
        trackedProjectFileSnapshot = ProjectFileSnapshot(
            contentHash: ProjectFileSnapshotReader.hash(of: data),
            modificationDate: Self.modificationDate(of: url),
            fileSize: data.count
        )
        trackedProjectFileURL = url
        declinedExternalProjectSnapshot = nil
        reportedMissingProjectFileURL = nil
    }

    /// Preferred after a save. `ProjectStore` remembers the exact bytes it wrote,
    /// so no read-back race can adopt an external version as the baseline.
    func recordProjectFileSnapshotAfterSave(at url: URL) {
        if let data = projectStore.lastSavedFileData {
            recordProjectFileSnapshot(data: data, at: url)
        } else {
            recordProjectFileSnapshot(at: url)
        }
    }

    func recordProjectFileSnapshot(at url: URL) {
        guard projectStore.currentFileURL == url else { return }
        // A single retry covers a transient read failure (a virus scanner, a
        // network volume waking up) instead of leaving the baseline nil.
        for attempt in 0...1 {
            do {
                trackedProjectFileSnapshot = try securityScope.withAccess(to: url) {
                    try ProjectFileSnapshotReader.read(at: url)
                }
                trackedProjectFileURL = url
                declinedExternalProjectSnapshot = nil
                reportedMissingProjectFileURL = nil
                return
            } catch {
                if attempt == 0 { continue }
                projectFileChangeLogger.error("Project file fingerprint read failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
            }
        }
    }

    /// Called by the file monitor. Reloads silently when there are no local
    /// edits; otherwise asks what to do.
    func checkForExternalProjectChanges() {
        guard projectStore.hasOpenProject,
              !projectStore.isBuiltInDemo,
              !externalChangePromptIsActive,
              let url = projectStore.currentFileURL else {
            return
        }
        switch diskStatus(at: url) {
        case .missing:
            handleMissingProjectFile(at: url)
        case let .snapshot(disk):
            guard let known = trackedProjectFileSnapshot else {
                // No baseline (the open-time read failed): the model may be
                // stale. Adopt the disk state silently while there are no local
                // edits; the pre-write check asks before clobbering anything.
                if projectStore.hasUnsavedFileChanges {
                    return
                }
                _ = reloadProjectFromDisk(presentsErrors: false)
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
                _ = reloadProjectFromDisk(presentsErrors: false)
            }
        }
    }

    /// Must run before every write to the current project file. If the file
    /// changed outside FrameScript, the same reload/overwrite/copy prompt is
    /// used instead of clobbering the external version. Background autosaves
    /// pass `honoringDeclinedConflict: true` so a decision the user already
    /// made for this exact on-disk hash is not shown again every interval.
    func prepareProjectFileForWrite(
        honoringDeclinedConflict: Bool = false,
        reportsMissingFile: Bool = true
    ) -> ProjectFileWriteAuthorization {
        guard let url = projectStore.currentFileURL else { return .failed }
        guard trackedProjectFileURL == url, let known = trackedProjectFileSnapshot else {
            // No baseline for an existing file means it may have been changed
            // after FrameScript last saw it. Ask instead of adopting it.
            switch diskStatus(at: url) {
            case .missing:
                // The file is gone: saving recreates it. Tell the user once and
                // let the write try instead of blocking their save forever.
                handleMissingProjectFile(at: url, reportsError: reportsMissingFile)
                return .proceed
            case let .snapshot(disk):
                if honoringDeclinedConflict,
                   let declined = declinedExternalProjectSnapshot,
                   declined.contentHash == disk.contentHash {
                    return .declined
                }
                return resolveExternalProjectChange(diskSnapshot: disk, url: url)
            }
        }
        switch diskStatus(at: url) {
        case .missing:
            handleMissingProjectFile(at: url, reportsError: reportsMissingFile)
            return .proceed
        case let .snapshot(disk):
            if disk.contentHash == known.contentHash {
                trackedProjectFileSnapshot = disk
                return .proceed
            }
            if honoringDeclinedConflict,
               let declined = declinedExternalProjectSnapshot,
               declined.contentHash == disk.contentHash {
                return .declined
            }
            return resolveExternalProjectChange(diskSnapshot: disk, url: url)
        }
    }

    @discardableResult
    func reloadProjectFromDisk(expectedURL: URL? = nil, presentsErrors: Bool = true) -> Bool {
        guard let url = projectStore.currentFileURL,
              expectedURL == nil || expectedURL == url else {
            return false
        }
        let previousSceneID = editorState.selectedSceneID
        let previousSceneIndex = projectStore.selectedSceneIndex(id: previousSceneID)
        let previousMode = editorState.selectedMode
        // The in-memory version is about to be replaced by the external one.
        // Keep it as a forced safety copy before decoding anything.
        backUpInMemoryProjectBeforeReload(at: url)
        do {
            let opened = try securityScope.withAccess(to: url) {
                try FrameScriptFileStore.readWithData(from: url)
            }
            let project = opened.project
            projectStore.openProject(
                project,
                fileURL: url,
                wordsPerMinute: durationWordsPerMinute(for: project),
                markUnsaved: false,
                recalculateDurations: false
            )
            projectStore.synchronizeTextSegments(
                splitMode: settings.generalPreferences.defaultSplitMode,
                wordsPerMinute: currentDurationWordsPerMinute,
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
            // The baseline is the hash of the bytes we actually decoded. A later
            // external write is detected on the next check instead of being
            // adopted silently.
            recordProjectFileSnapshot(data: opened.data, at: url)
            return true
        } catch {
            projectFileChangeLogger.error("Operation project-reload failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
            if Self.isMissingFileError(error, url: url) {
                handleMissingProjectFile(at: url)
            } else if presentsErrors {
                errorCenter.present(AppError.project(error, fileURL: url, operation: .read))
            }
            return false
        }
    }

    /// Writes the in-memory project even though the file changed externally.
    /// Only used after the user explicitly chose "Keep Mine" for this URL.
    @discardableResult
    func forceWriteProjectFile(at expectedURL: URL) -> Bool {
        guard projectStore.currentFileURL == expectedURL else { return false }
        do {
            try securityScope.withAccess(to: expectedURL) {
                try projectStore.saveCurrentProject(wordsPerMinute: currentDurationWordsPerMinute)
            }
            recordProjectFileSnapshotAfterSave(at: expectedURL)
            errorCenter.clearAutosaveFailureSuppression()
            return true
        } catch {
            projectFileChangeLogger.error("Operation project-overwrite failed. Code: \(Self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: expectedURL, operation: .write))
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

        let promptProjectID = projectStore.project.id
        let resolution = externalChangeResolution()
        // Opening another project from Finder can spin the modal run loop.
        // Never apply this project's answer to whatever is open now.
        guard projectStore.currentFileURL == url, projectStore.project.id == promptProjectID else {
            projectFileChangeLogger.notice("Discarding external-change decision because the open project changed.")
            return .failed
        }

        switch resolution {
        case .reload:
            return reloadProjectFromDisk(expectedURL: url) ? .handled : .failed
        case .keepMine:
            warnIfDiskFileIsNewer(at: url)
            return forceWriteProjectFile(at: url) ? .handled : .failed
        case .saveCopy:
            let saved = saveProjectCopyHandler?() ?? saveProjectAs()
            if saved, let newURL = projectStore.currentFileURL {
                startTrackingProjectFileAfterSave(at: newURL)
            }
            return saved ? .handled : .failed
        case .cancel:
            declinedExternalProjectSnapshot = diskSnapshot
            return .failed
        }
    }

    /// Button order of the external-change alert. The first button is the
    /// default (Return) answer; Keep Mine must be first so pressing Return never
    /// discards the user's local text.
    static let externalChangeButtonOrder: [ExternalProjectChangeResolution] = [
        .keepMine,
        .reload,
        .saveCopy,
        .cancel
    ]

    private func externalChangeButtonTitle(_ resolution: ExternalProjectChangeResolution) -> String {
        switch resolution {
        case .keepMine: localized("dialog.externalChange.keepMine")
        case .reload: localized("dialog.externalChange.reload")
        case .saveCopy: localized("dialog.externalChange.saveCopy")
        case .cancel: localized("project.unsaved.cancel")
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
        for resolution in Self.externalChangeButtonOrder {
            alert.addButton(withTitle: externalChangeButtonTitle(resolution))
        }
        let response = alert.runModal()
        let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard Self.externalChangeButtonOrder.indices.contains(offset) else { return .cancel }
        return Self.externalChangeButtonOrder[offset]
    }

    // MARK: Disk state

    private enum DiskStatus {
        case snapshot(ProjectFileSnapshot)
        case missing
    }

    private func diskStatus(at url: URL) -> DiskStatus {
        do {
            return .snapshot(try securityScope.withAccess(to: url) {
                try ProjectFileSnapshotReader.read(at: url)
            })
        } catch {
            return .missing
        }
    }

    /// One error per file URL. Autosave runs every few seconds; a missing file
    /// must not produce an alert queue.
    private func presentMissingProjectFileErrorIfNeeded(at url: URL) {
        guard reportedMissingProjectFileURL != url else { return }
        reportedMissingProjectFileURL = url
        projectFileChangeLogger.error("The open project file is missing or unreadable; the project was marked dirty.")
        errorCenter.present(AppError(
            kind: .projectMissing,
            context: AppErrorContext(fileName: url.lastPathComponent),
            recoveryAction: .saveAs
        ))
    }

    private func handleMissingProjectFile(at url: URL, reportsError: Bool = true) {
        trackedProjectFileURL = url
        trackedProjectFileSnapshot = nil
        projectStore.markProjectDirty()
        guard reportsError else { return }
        presentMissingProjectFileErrorIfNeeded(at: url)
    }

    private func backUpInMemoryProjectBeforeReload(at url: URL) {
        guard !projectStore.isBuiltInDemo else { return }
        BackupsCenter.backUpInMemoryProject(projectStore.project, fileURL: url)
    }

    /// Keep Mine overwrites whatever is on disk. If that file was written by a
    /// newer FrameScript, warn instead of silently discarding fields this build
    /// does not understand.
    private func warnIfDiskFileIsNewer(at url: URL) {
        guard let version = FrameScriptFileStore.fileVersionInFile(at: url),
              version > FrameScriptFormat.currentFileVersion else {
            return
        }
        projectFileChangeLogger.notice("Overwriting a project file written by file version \(version, privacy: .public).")
        showNotice(.overwroteNewerFileVersion)
    }

    private static func isMissingFileError(_ error: Error, url: URL) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func diagnosticCode(for error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}
