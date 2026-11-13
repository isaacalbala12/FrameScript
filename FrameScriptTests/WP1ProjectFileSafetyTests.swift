import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// WP1 regression tests for the project-file safety net: flush dirtying, the
/// external-change dialog, missing files, restore, fingerprints, recents,
/// copies, templates and crash hardening.
@MainActor
final class WP1ProjectFileSafetyTests: FrameScriptTestCase {
    private let recorder = WP1ConfirmationRecorder()
    // MARK: - No-op flush

    /// Fails before the fix: `flush()` always returned true, so closing or
    /// quitting marked a clean project dirty and prompted to save.
    func testNoOpFlushDoesNotMarkTheProjectDirty() throws {
        let url = try makeProjectFile(title: "Clean", text: "clean text")
        let appState = makeAppState()
        appState.openProject(at: url)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)

        let editor = FlushStub(result: false)
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        appState.flushActiveEditorBoundary()

        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges, "A no-op flush must not dirty the project")
        XCTAssertFalse(appState.projectStore.needsCloseConfirmation)
        XCTAssertFalse(ActiveScriptEditorSession.shared.flush(), "flush() reports the editor result")
        XCTAssertFalse(ActiveScriptEditorSession.shared.flushAllForAppResignation())
    }

    /// The other half of the contract: an editor that committed marked text must
    /// still mark the project dirty.
    func testFlushThatCommitsTextMarksTheProjectDirty() throws {
        let url = try makeProjectFile(title: "Dirty", text: "text")
        let appState = makeAppState()
        appState.openProject(at: url)
        let editor = FlushStub(result: true)
        ActiveScriptEditorSession.shared.register(editor)
        defer { ActiveScriptEditorSession.shared.unregister(editor) }

        appState.flushActiveEditorBoundary()

        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
        XCTAssertTrue(appState.projectStore.needsCloseConfirmation)
    }

    // MARK: - External change

    /// Fails before the fix: Reload was the default (Return) button.
    func testKeepMineIsTheDefaultExternalChangeButton() {
        XCTAssertEqual(AppState.externalChangeButtonOrder.first, .keepMine)
        XCTAssertEqual(AppState.externalChangeButtonOrder.count, 4)
    }

    /// Fails before the fix: Reload discarded the in-memory text without a copy.
    func testReloadBacksUpTheInMemoryTextFirst() throws {
        let url = try makeProjectFile(title: "Local", text: "local text")
        let appState = makeAppState()
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "unsaved local edit")

        var external = makeProject(title: "External", text: "external text")
        external.id = appState.project.id
        try FrameScriptFileStore.write(project: external, to: url)
        recorder.resolution = .reload
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(appState.project.title, "External")
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let backups = BackupsCenter.store.listBackups(projectID: projectID)
        XCTAssertFalse(backups.isEmpty, "Reload must keep a safety copy")
        let restored = try backups.compactMap { entry -> FrameProject? in
            try? FrameScriptFileStore.decodeProject(from: Data(contentsOf: entry.url))
        }
        XCTAssertTrue(
            restored.contains { $0.scenes.first?.scriptText == "unsaved local edit" },
            "A backup must contain the text the reload discarded"
        )
    }

    /// Fails before the fix: a silent reload (no local edits) kept no copy.
    func testSilentReloadBacksUpThePreviousVersion() throws {
        let url = try makeProjectFile(title: "Local", text: "before reload")
        let appState = makeAppState()
        appState.openProject(at: url)

        var external = makeProject(title: "External", text: "after reload")
        external.id = appState.project.id
        try FrameScriptFileStore.write(project: external, to: url)
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(appState.project.title, "External")
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let backups = BackupsCenter.store.listBackups(projectID: projectID)
        let restored = try backups.compactMap { entry -> FrameProject? in
            try? FrameScriptFileStore.decodeProject(from: Data(contentsOf: entry.url))
        }
        XCTAssertTrue(restored.contains { $0.scenes.first?.scriptText == "before reload" })
    }

    /// Fails before the fix: without a tracked baseline the declined hash was
    /// ignored and autosave prompted again on every interval.
    func testDeclinedConflictWithoutBaselineIsNotPromptedAgain() throws {
        let url = try makeProjectFile(title: "External", text: "external")
        let sceneID = UUID()
        let project = makeProject(title: "Local", text: "local", sceneID: sceneID)
        let store = ProjectStore(project: project, projectWriter: FrameScriptFileStore.write)
        // Mimic a failed fingerprint read at open time: no baseline.
        store.openProject(project, fileURL: url, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store, autosaveEnabled: true)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")

        recorder.resolution = .cancel
        appState.performAutosave()
        XCTAssertEqual(recorder.count, 1)

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit again")
        appState.performAutosave()

        XCTAssertEqual(recorder.count, 1, "The declined hash must suppress the second prompt")
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
    }

    /// Fails before the fix: keeping the local version over a file written by a
    /// newer build was silent.
    func testKeepMineOverANewerFileVersionShowsAWarning() throws {
        let url = try makeProjectFile(title: "Local", text: "local")
        let appState = makeAppState()
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")

        // A v5 document: readable as JSON for the version, not decodable.
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        payload["fileVersion"] = 5
        try JSONSerialization.data(withJSONObject: payload).write(to: url)

        recorder.resolution = .keepMine
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(appState.errorCenter.notice?.kind, .overwroteNewerFileVersion)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).scenes.first?.scriptText, "local edit")
    }

    // MARK: - Missing file

    /// Fails before the fix: deleting the open file was silent and saving could
    /// not recreate it without an "changed outside" question.
    func testMissingFileMarksDirtyRecreatesOnSaveAndDoesNotAskAgain() throws {
        let url = try makeProjectFile(title: "Deletable", text: "keep me")
        let appState = makeAppState()
        appState.openProject(at: url)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)

        try FileManager.default.removeItem(at: url)
        appState.checkForExternalProjectChanges()

        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges, "A missing file must make the project dirty")
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .projectMissing)
        XCTAssertEqual(appState.errorCenter.presentedError?.recoveryAction, .saveAs)

        XCTAssertTrue(appState.saveProject(), "Saving must recreate the file")
        XCTAssertEqual(recorder.count, 0, "The missing file is not an external edit")
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.scenes.first?.scriptText, "keep me")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    // MARK: - Restore

    /// Fails before the fix: the baseline stayed on the pre-restore file, so the
    /// next check reported the user's own restore as an external change.
    func testRestoreRecordsTheRestoredBytesAsTheBaseline() throws {
        let url = try makeProjectFile(title: "Restorable", text: "original")
        let appState = makeAppState()
        appState.openProject(at: url)
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let backupData = try FrameScriptFileStore.encode(project: makeProject(title: "From backup", text: "restored text"))
        let entry = try XCTUnwrap(backedUpEntry(data: backupData, fileName: url.lastPathComponent, url: url, projectID: projectID))

        let outcome = appState.restoreBackup(entry)

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(appState.project.title, "From backup")
        let diskData = try Data(contentsOf: url)
        XCTAssertEqual(
            appState.trackedProjectFileSnapshot?.contentHash,
            ProjectFileSnapshotReader.hash(of: diskData),
            "The baseline must be the bytes that were restored"
        )
        appState.checkForExternalProjectChanges()
        XCTAssertEqual(recorder.count, 0, "The restore must not look like an external change")
    }

    /// Fails before the fix: an old backup was decoded by the app model decoder
    /// without the codec's migration path.
    func testOldBackupMigratesOnRestore() throws {
        let url = try makeProjectFile(title: "Legacy", text: "current")
        let appState = makeAppState()
        appState.openProject(at: url)
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)

        let modern = try FrameScriptFileStore.encode(project: makeProject(title: "Legacy backup", text: "legacy text"))
        var payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: modern) as? [String: Any])
        payload["fileVersion"] = 3
        let legacyData = try JSONSerialization.data(withJSONObject: payload)
        let entry = try XCTUnwrap(backedUpEntry(data: legacyData, fileName: url.lastPathComponent, url: url, projectID: projectID))

        XCTAssertEqual(appState.restoreBackup(entry), .restored)
        XCTAssertEqual(appState.project.scenes.first?.scriptText, "legacy text")

        // Restore writes the backup's bytes untouched; the migrated document is
        // what the app now holds and what the next save will write.
        let restoredRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(restoredRoot["fileVersion"] as? Int, 3)
        XCTAssertEqual(appState.projectStore.hasUnsavedFileChanges, false)
    }

    /// A refused save (external conflict cancelled) must cancel the restore.
    func testRestoreIsCancelledWhenSavingTheCurrentVersionIsRefused() throws {
        let url = try makeProjectFile(title: "Busy", text: "original")
        let appState = makeAppState(autosaveEnabled: false)
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "unsaved edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", text: "external"), to: url)
        recorder.resolution = .cancel

        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let backupData = try FrameScriptFileStore.encode(project: makeProject(title: "Backup", text: "backup"))
        let entry = try XCTUnwrap(backedUpEntry(data: backupData, fileName: url.lastPathComponent, url: url, projectID: projectID))

        XCTAssertEqual(appState.restoreBackup(entry), .cancelled)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External", "The destination must be untouched")
        XCTAssertEqual(appState.projectStore.hasUnsavedFileChanges, true)
    }

    // MARK: - Fingerprint

    /// Fails before the fix: the baseline was read back from disk, so an
    /// external write that landed between the save and the read was adopted as
    /// FrameScript's own version and overwritten without asking.
    func testSaveBaselineIsTheBytesWrittenEvenWhenTheFileChangesInTheMeantime() throws {
        let url = try makeProjectFile(title: "Race", text: "original")
        let externalText = "external write after ours"
        let store = ProjectStore(project: SampleData.defaultProject) { project, destination in
            try FrameScriptFileStore.write(project: project, to: destination)
            // Simulate another writer replacing the file immediately after our
            // atomic write, before any read-back could happen.
            var payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any]
            )
            var projectObject = try XCTUnwrap(payload["project"] as? [String: Any])
            var scenes = try XCTUnwrap(projectObject["scenes"] as? [[String: Any]])
            scenes[0]["scriptText"] = externalText
            projectObject["scenes"] = scenes
            payload["project"] = projectObject
            try JSONSerialization.data(withJSONObject: payload).write(to: destination)
        }
        let appState = makeAppState(store: store)
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")

        XCTAssertTrue(appState.saveProject())
        XCTAssertEqual(recorder.count, 0, "The first save is the one that wrote the file")

        appState.commitScriptTextChange(sceneID: sceneID, text: "second local edit")
        recorder.resolution = .cancel
        XCTAssertFalse(appState.saveProject())
        XCTAssertEqual(recorder.count, 1, "The external write must be detected, not adopted")
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "Race")
    }

    // MARK: - Delete Project

    /// Fails before the fix: Delete skipped the save prompt when
    /// `confirmBeforeDeleting` was off, discarding unsaved edits.
    func testDeletingAProjectWithUnsavedEditsAsksFirst() throws {
        let url = try makeProjectFile(title: "Delete me", text: "original")
        let closeRecorder = CloseRecorder(result: .cancel)
        let appState = makeAppState(
            autosaveEnabled: false,
            confirmBeforeDeleting: false,
            closeRecorder: closeRecorder
        )
        appState.openProject(at: url)
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        appState.commitScriptTextChange(sceneID: sceneID, text: "unsaved edit")

        appState.deleteProject()

        XCTAssertEqual(closeRecorder.count, 1, "Delete must run the Save / Don't Save / Cancel flow")
        XCTAssertTrue(appState.hasOpenProject)
        XCTAssertEqual(appState.project.scenes.first?.scriptText, "unsaved edit")

        closeRecorder.result = .discard
        appState.deleteProject()
        XCTAssertFalse(appState.hasOpenProject)
    }

    // MARK: - Copies

    /// Fails before the fix: duplicates inherited the original's AI threads and
    /// a duplicated scene inherited its takes.
    func testDuplicatesGetFreshThreadsAndScenesLoseTheirTakes() throws {
        let url = try makeProjectFile(title: "Original", text: "one two three")
        let appState = makeAppState()
        appState.openProject(at: url)
        appState.project.aiThreadMap.threadIDsByProviderModel["openai|gpt"] = "thread-1"
        let scene = try XCTUnwrap(appState.project.scenes.first)
        scene.takes = [Take(number: 1, startedAt: Date(timeIntervalSince1970: 0))]

        appState.duplicateSelectedScene()
        XCTAssertEqual(appState.project.scenes.count, 2)
        let copy = try XCTUnwrap(appState.project.scenes.sortedByOrder.last)
        XCTAssertTrue(copy.takes.isEmpty, "A duplicated scene must not clone recording takes")

        appState.duplicateProject()
        XCTAssertTrue(appState.project.aiThreadMap.threadIDsByProviderModel.isEmpty)
        XCTAssertFalse(appState.project.scenes.isEmpty)
    }

    /// Fails before the fix: thread IDs survived Open as Copy.
    func testOpenBackupAsCopyClearsThreads() throws {
        let url = try makeProjectFile(title: "Original", text: "text")
        let appState = makeAppState()
        appState.openProject(at: url)
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        var source = appState.project
        source.aiThreadMap.threadIDsByProviderModel["openai|gpt"] = "thread-1"
        let data = try FrameScriptFileStore.encode(project: source)
        let entry = try XCTUnwrap(backedUpEntry(data: data, fileName: url.lastPathComponent, url: url, projectID: projectID))

        XCTAssertTrue(appState.openBackupAsCopy(entry))
        XCTAssertTrue(appState.project.aiThreadMap.threadIDsByProviderModel.isEmpty)
        XCTAssertNil(appState.projectStore.currentFileURL)
    }

    // MARK: - Backups window without an open project

    /// Fails before the fix: with no project open the backups sheet had no
    /// project id, so a corrupt file's backups were unreachable.
    func testFailedOpenRemembersTheFileForTheBackupsWindow() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Broken.fscr")
        try Data("{ not a project".utf8).write(to: url)
        let appState = makeAppState()

        appState.openProject(at: url)

        XCTAssertEqual(appState.failedOpenProjectFileURL, url)
        XCTAssertNotNil(appState.currentBackupProjectID)
        XCTAssertEqual(appState.backupsProjectFileURL, url)
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .corruptedProject)
        XCTAssertEqual(appState.errorCenter.presentedError?.recoveryAction, .openBackups(url))
    }

    // MARK: - Corrupt templates blob

    func testCorruptTemplatesBlobIsPreservedAndSavingWaitsForAnExplicitChange() throws {
        let key = "FrameScript.customTemplates.v1"
        let corrupt = Data("{broken".utf8)
        AppEnvironment.defaults.set(corrupt, forKey: key)
        AppEnvironment.defaults.removeObject(forKey: key + ".unreadable-backup")
        defer {
            AppEnvironment.defaults.removeObject(forKey: key)
            AppEnvironment.defaults.removeObject(forKey: key + ".unreadable-backup")
        }

        let appState = makeAppState()
        // SandboxDataMigrationTests may have left a one-shot launch notice
        // pending; it is a process-global in production and would replace the
        // template notice asserted below.
        _ = SandboxDataMigration.consumePendingReadFailureNotice()
        appState.configure()

        XCTAssertEqual(AppEnvironment.defaults.data(forKey: key + ".unreadable-backup"), corrupt)
        XCTAssertEqual(AppEnvironment.defaults.data(forKey: key), corrupt, "Nothing may overwrite the unreadable blob")
        XCTAssertEqual(appState.errorCenter.notice?.kind, .customTemplatesUnreadable)

        appState.createCustomTemplate()
        let saved = try XCTUnwrap(AppEnvironment.defaults.data(forKey: key))
        XCTAssertNoThrow(try JSONDecoder().decode([FrameTemplate].self, from: saved))
    }

    // MARK: - Save does one estimate pass

    /// Fails before the fix: `prepareForSave` recalculated every duration twice.
    func testSaveRunsOneDurationEstimatePerScene() throws {
        let url = try makeProjectFile(title: "Estimates", text: "one two three four five")
        let appState = makeAppState()
        appState.openProject(at: url)
        appState.projectStore.synchronizeTextSegments(
            splitMode: .paragraph,
            wordsPerMinute: 150,
            markUnsaved: false
        )
        var providerCalls = 0
        appState.projectStore.durationConfigurationProvider = { _ in
            providerCalls += 1
            return .standard
        }

        XCTAssertTrue(appState.saveProject())

        XCTAssertEqual(providerCalls, appState.project.scenes.count)
    }

    // MARK: - Recents on an unmounted volume

    /// Fails before the fix: an entry on a missing volume was dropped and the
    /// shorter list was persisted.
    func testUnmountedVolumeEntriesSurviveValidation() throws {
        let defaults = makeDefaults()
        let missingVolumePath = "/Volumes/FrameScriptTestVolume-\(UUID().uuidString)/Project.fscr"
        let codec = WP1BookmarkCodec(redirects: [:], stalePaths: [])
        let store = RecentProjectStore(
            userDefaults: defaults,
            storageKey: "recents",
            legacyPathsKey: "legacy",
            bookmarkCreator: codec.createBookmark(for:),
            bookmarkResolver: codec.resolveBookmark(data:isStale:),
            entriesEncoder: { try JSONEncoder().encode($0) },
            securityScope: SecurityScopedResourceAccess(start: { _ in false }, stop: { _ in })
        )
        let entry = RecentProjectEntry(
            id: UUID(),
            bookmarkData: Data(missingVolumePath.utf8),
            displayName: "Project",
            lastKnownPath: missingVolumePath,
            lastOpenedAt: Date()
        )
        defaults.set(try JSONEncoder().encode([entry]), forKey: "recents")
        store.load()

        let result = store.validateEntriesNow()

        XCTAssertEqual(result.removedMissingCount, 0)
        XCTAssertEqual(store.entries.map(\.id), [entry.id])
        XCTAssertFalse(store.availability(for: entry))
        XCTAssertTrue(store.unavailableEntryIDs.contains(entry.id))
        let persisted = try XCTUnwrap(defaults.data(forKey: "recents"))
        XCTAssertEqual(try JSONDecoder().decode([RecentProjectEntry].self, from: persisted).map(\.id), [entry.id])
    }

    // MARK: - Crash hardening

    func testAbsurdStoredSecondsAreClamped() throws {
        let pack = FrameScriptDocument.PublishingPack(
            chapterOverrides: [
                FrameScriptDocument.ChapterOverride(
                    title: "Chapter",
                    startSeconds: 1e300
                )
            ]
        )
        let document = FrameScriptDocument(
            project: FrameScriptDocument.Project(
                title: "Clamped",
                publishingPacks: ["es": pack]
            )
        )

        let project = document.project.makeProject()

        let start = try XCTUnwrap(project.publishingPacks["es"]?.chapterOverrides.first?.startSeconds)
        XCTAssertTrue(start.isFinite)
        XCTAssertEqual(start, 86_400)
    }

    // MARK: - Error presentation

    func testUnsupportedVersionErrorNamesTheVersionAndOffersBackups() throws {
        let url = URL(fileURLWithPath: "/tmp/Newer.fscr")
        let error = try XCTUnwrap(AppError.project(FrameScriptFileError.unsupportedVersion(9), fileURL: url, operation: .read))

        XCTAssertEqual(error.kind, .unsupportedProjectVersion)
        XCTAssertEqual(error.recoveryAction, .openBackups(url))
        let message = error.presentation(language: .english).message
        XCTAssertTrue(message.contains("9"), "The message must name the file version: \(message)")
        XCTAssertTrue(message.contains("Update FrameScript"))
    }

    func testCommonFileErrorsGetALocalizedReason() throws {
        let url = URL(fileURLWithPath: "/tmp/Locked.fscr")
        let error = try XCTUnwrap(
            AppError.project(CocoaError(.fileWriteNoPermission), fileURL: url, operation: .write)
        )
        let message = error.presentation(language: .english).message
        XCTAssertTrue(message.contains("permission"), message)
        XCTAssertFalse(message.contains("error.reason"), "The key must be translated")
    }

    // MARK: - Localization

    func testBackupOperationNamesAndWordPluralsAreLocalized() {
        for language in [AppLanguage.english, .russian, .spanish] {
            for operation in BackupFailure.Operation.allCases {
                let key = "backups.operation.\(operation.rawValue)"
                XCTAssertNotEqual(L10n.tr(key, language: language), key, "\(language) \(key)")
            }
            for count in [1, 2, 5, 11, 21, 22] {
                XCTAssertNotEqual(
                    L10n.plural("script.words", count: count, language: language),
                    "script.words",
                    "\(language) plural for \(count)"
                )
            }
        }
        XCTAssertEqual(L10n.plural("script.words", count: 1, language: .english), "1 word")
        XCTAssertEqual(L10n.plural("script.words", count: 2, language: .english), "2 words")
    }

    // MARK: - Helpers

    private final class FlushStub: ActiveScriptEditor {
        let result: Bool
        let sceneID = UUID()
        let editorIdentity = UUID()
        var owningWindow: NSWindow?
        var isActualFirstResponder = true

        init(result: Bool) { self.result = result }

        func commitMarkedTextAndFlush() -> Bool { result }
        func cancelAutocomplete(clearStatus: Bool) {}
    }

    private final class WP1BookmarkCodec: @unchecked Sendable {
        let redirects: [String: String]
        var stalePaths: Set<String>

        init(redirects: [String: String], stalePaths: Set<String>) {
            self.redirects = redirects
            self.stalePaths = stalePaths
        }

        @MainActor
        func createBookmark(for url: URL) throws -> Data {
            Data(url.path.utf8)
        }

        @MainActor
        func resolveBookmark(data: Data, isStale: inout Bool) throws -> URL {
            let path = String(decoding: data, as: UTF8.self)
            if stalePaths.remove(path) != nil { isStale = true }
            return URL(fileURLWithPath: redirects[path] ?? path)
        }
    }

    private final class WP1ConfirmationRecorder {
        var count = 0
        var resolution: ExternalProjectChangeResolution = .cancel
    }

    private final class CloseRecorder {
        var count = 0
        var result: AppState.CloseConfirmationResult

        init(result: AppState.CloseConfirmationResult) {
            self.result = result
        }
    }

    private func makeProject(title: String, text: String, sceneID: UUID = UUID()) -> FrameProject {
        FrameProject(
            title: title,
            scenes: [Scene(id: sceneID, order: 0, sectionType: .custom, title: "Scene", scriptText: text)]
        )
    }

    private func makeProjectFile(title: String, text: String) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "-")).fscr")
        try FrameScriptFileStore.write(project: makeProject(title: title, text: text), to: url)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func backedUpEntry(
        data: Data,
        fileName: String,
        url: URL,
        projectID: String
    ) -> BackupEntry? {
        guard case let .created(entry, _) = BackupsCenter.store.backUpData(
            data,
            originalFileName: fileName,
            originalPath: url.path,
            projectID: projectID
        ) else {
            return nil
        }
        return entry
    }

    private func makeAppState(
        store: ProjectStore = ProjectStore(project: SampleData.defaultProject),
        autosaveEnabled: Bool = false,
        confirmBeforeDeleting: Bool = true,
        closeRecorder: CloseRecorder? = nil
    ) -> AppState {
        let suite = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        settings.generalPreferences.confirmBeforeDeleting = confirmBeforeDeleting
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: {
                closeRecorder?.count += 1
                return closeRecorder?.result ?? .discard
            },
            externalChangeConfirmation: { [recorder] in
                recorder.count += 1
                return recorder.resolution
            }
        )
        return appState
    }
}
