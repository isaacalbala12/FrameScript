import AppKit
import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class ProjectFileChangeDetectionTests: XCTestCase {
    private final class ConfirmationRecorder {
        var count = 0
        var resolution: ExternalProjectChangeResolution = .cancel
        var onPrompt: (@MainActor () -> Void)?
    }

    private final class CopyDestination {
        var url: URL?
        weak var appState: AppState?
    }

    @MainActor
    private final class SecurityAccessRecorder {
        var startCount = 0
    }

    func testSnapshotReaderHashesContentAndRecordsModificationMetadata() throws {
        let url = try temporaryFileURL()
        try Data("first".utf8).write(to: url)

        let first = try ProjectFileSnapshotReader.read(at: url)

        XCTAssertEqual(first.contentHash, ProjectFileSnapshotReader.hash(of: Data("first".utf8)))
        XCTAssertEqual(first.fileSize, 5)
        XCTAssertNotNil(first.modificationDate)

        try Data("second".utf8).write(to: url)
        let second = try ProjectFileSnapshotReader.read(at: url)

        XCTAssertNotEqual(second.contentHash, first.contentHash)
        XCTAssertEqual(second.fileSize, 6)
    }

    func testMonitorReportsInPlaceWritesAndRearmsAfterAtomicReplacement() async throws {
        let url = try temporaryFileURL()
        try Data("start".utf8).write(to: url)
        let monitor = ProjectFileMonitor()
        var eventCount = 0
        monitor.start(watching: url) {
            eventCount += 1
        }
        defer { monitor.stop() }

        try Data("in place".utf8).write(to: url)
        try await waitUntil("in-place write event") { eventCount >= 1 }

        try Data("atomic replacement".utf8).write(to: url, options: .atomic)
        try await waitUntil("atomic replacement event after re-arm") { eventCount >= 2 }
    }

    func testMonitorArmsAndRearmsInsideSecurityScopedAccess() async throws {
        let url = try temporaryFileURL()
        try Data("start".utf8).write(to: url)
        let recorder = SecurityAccessRecorder()
        let access = SecurityScopedResourceAccess(
            start: { _ in
                recorder.startCount += 1
                return false
            },
            stop: { _ in }
        )
        let monitor = ProjectFileMonitor(securityScope: access)
        monitor.start(watching: url) {}
        defer { monitor.stop() }

        XCTAssertEqual(recorder.startCount, 1)

        try Data("atomic replacement".utf8).write(to: url, options: .atomic)
        try await waitUntil("security-scoped re-arm") { recorder.startCount >= 2 }
    }

    func testExternalChangeWithoutLocalEditsReloadsSilentlyAndPreservesTheSelectedScene() throws {
        let selectedID = UUID()
        let otherID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(
            project: makeProject(title: "Local", scenes: [(selectedID, "local one"), (otherID, "local two")]),
            to: url
        )
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder)
        defer { appState.resetProjectFileTracking() }
        XCTAssertEqual(appState.editorState.selectedSceneID, selectedID)

        try FrameScriptFileStore.write(
            project: makeProject(title: "External", scenes: [(selectedID, "external one"), (otherID, "external two")]),
            to: url
        )
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 0)
        XCTAssertEqual(appState.project.title, "External")
        XCTAssertEqual(appState.project.scenes.first(where: { $0.id == selectedID })?.scriptText, "external one")
        XCTAssertEqual(appState.editorState.selectedSceneID, selectedID)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
        XCTAssertEqual(appState.saveState, .saved)
    }

    func testExternalChangeWithLocalEditsCanReloadAndDiscardTheLocalVersion() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder)
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .reload

        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(appState.project.title, "External")
        XCTAssertEqual(appState.project.scenes.first(where: { $0.id == sceneID })?.scriptText, "external")
        XCTAssertEqual(appState.editorState.selectedSceneID, sceneID)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    func testKeepMineOverwritesTheExternalVersionAfterThePrompt() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder)
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .keepMine

        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 1)
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.title, "Local")
        XCTAssertEqual(saved.scenes.first?.scriptText, "local edit")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    func testCancelLeavesBothVersionsAloneAndSnoozesTheSameExternalContent() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder)
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .cancel

        appState.checkForExternalProjectChanges()
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(appState.project.title, "Local")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")

        try FrameScriptFileStore.write(project: makeProject(title: "External again", scenes: [(sceneID, "external again")]), to: url)
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 2)
    }

    func testSaveNeverClobbersAnUnacknowledgedExternalChange() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder)
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .cancel

        XCTAssertFalse(appState.saveProject())
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        recorder.resolution = .keepMine
        XCTAssertTrue(appState.saveProject())
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).scenes.first?.scriptText, "local edit")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    func testSaveMineAsCopyLeavesTheExternalFileUntouched() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let destination = CopyDestination()
        destination.url = url.deletingLastPathComponent().appendingPathComponent("Local copy \(UUID().uuidString).fscr")
        let appState = makeAppState(
            url: url,
            recorder: recorder,
            saveProjectCopyHandler: {
                guard let target = destination.url, let appState = destination.appState else { return false }
                do {
                    try appState.projectStore.saveCurrentProject(to: target, wordsPerMinute: 150)
                    return true
                } catch {
                    return false
                }
            }
        )
        destination.appState = appState
        defer {
            appState.resetProjectFileTracking()
            if let target = destination.url { try? FileManager.default.removeItem(at: target) }
        }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .saveCopy

        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
        XCTAssertEqual(appState.projectStore.currentFileURL, destination.url)
        let copyURL = try XCTUnwrap(destination.url)
        XCTAssertEqual(try FrameScriptFileStore.read(from: copyURL).scenes.first?.scriptText, "local edit")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    func testAutosaveDoesNotRepeatADeclinedConflictForTheSameDiskHash() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder, autosaveEnabled: true)
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .cancel
        appState.checkForExternalProjectChanges()
        XCTAssertEqual(recorder.count, 1)

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit again")
        appState.performAutosave()

        XCTAssertEqual(recorder.count, 1, "Autosave must remember the declined hash instead of prompting again")
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        try FrameScriptFileStore.write(project: makeProject(title: "External again", scenes: [(sceneID, "external again")]), to: url)
        appState.checkForExternalProjectChanges()

        XCTAssertEqual(recorder.count, 2, "A different on-disk hash must be shown again")
    }

    func testKeepMineAbortsIfAnotherProjectOpensWhileThePromptIsVisible() throws {
        let sceneID = UUID()
        let urlA = try temporaryFileURL()
        let urlB = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Project A", scenes: [(sceneID, "local A")]), to: urlA)
        try FrameScriptFileStore.write(project: makeProject(title: "Project B", scenes: [(sceneID, "local B")]), to: urlB)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(
            url: urlA,
            recorder: recorder,
            closeConfirmation: { .discard }
        )
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local A edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External A", scenes: [(sceneID, "external A")]), to: urlA)
        recorder.resolution = .keepMine
        recorder.onPrompt = {
            appState.openProject(at: urlB)
        }

        appState.checkForExternalProjectChanges()

        XCTAssertEqual(appState.project.title, "Project B")
        XCTAssertEqual(appState.projectStore.currentFileURL, urlB)
        XCTAssertEqual(try FrameScriptFileStore.read(from: urlA).title, "External A")
        XCTAssertEqual(try FrameScriptFileStore.read(from: urlA).scenes.first?.scriptText, "external A")
    }

    func testOnlyProjectWindowCloseRunsTheProjectSaveFlow() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(url: url, recorder: recorder, autosaveEnabled: true)
        defer {
            appState.setProjectWindow(nil)
            appState.resetProjectFileTracking()
        }
        let projectWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        appState.setProjectWindow(projectWindow)
        appState.commitScriptTextChange(sceneID: sceneID, text: "project window edit")

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: otherWindow)

        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "Local")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: projectWindow)

        XCTAssertEqual(try FrameScriptFileStore.read(from: url).scenes.first?.scriptText, "project window edit")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    func testExistingFileWithoutBaselinePromptsInsteadOfOverwriting() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        let recorder = ConfirmationRecorder()
        recorder.resolution = .cancel
        let suite = UserDefaults(suiteName: "ProjectFileChangeDetectionTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = false
        let project = makeProject(title: "Local", scenes: [(sceneID, "local")])
        let store = ProjectStore(project: project, projectWriter: FrameScriptFileStore.write)
        // Bypass AppState.openProject so no baseline is recorded, mimicking a
        // failed fingerprint read. The existing file must not be overwritten.
        store.openProject(project, fileURL: url, wordsPerMinute: 150, markUnsaved: false)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            externalChangeConfirmation: {
                recorder.count += 1
                return recorder.resolution
            }
        )
        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")

        XCTAssertFalse(appState.saveProject())
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).scenes.first?.scriptText, "external")
    }

    func testTerminationDoesNotQuitWhenTheExternalConflictPromptIsCancelled() throws {
        let sceneID = UUID()
        let url = try temporaryFileURL()
        try FrameScriptFileStore.write(project: makeProject(title: "Local", scenes: [(sceneID, "local")]), to: url)
        let recorder = ConfirmationRecorder()
        let appState = makeAppState(
            url: url,
            recorder: recorder,
            closeConfirmation: { .save }
        )
        defer { appState.resetProjectFileTracking() }

        appState.commitScriptTextChange(sceneID: sceneID, text: "local edit")
        try FrameScriptFileStore.write(project: makeProject(title: "External", scenes: [(sceneID, "external")]), to: url)
        recorder.resolution = .cancel

        XCTAssertFalse(appState.confirmApplicationTermination())
        XCTAssertFalse(appState.isTerminatingApplication)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).title, "External")
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)
    }

    func testExternalChangeStringsAreLocalizedInEnglishRussianAndDraftSpanish() throws {
        let keys = [
            "dialog.externalChange.title",
            "dialog.externalChange.message",
            "dialog.externalChange.reload",
            "dialog.externalChange.keepMine",
            "dialog.externalChange.saveCopy"
        ]
        for key in keys {
            XCTAssertNotEqual(L10n.tr(key, language: .english), key)
            XCTAssertNotEqual(L10n.tr(key, language: .russian), key)
            XCTAssertNotNil(L10n.autosaveSpanish[key])
        }
        let englishKeys = try XCTUnwrap(L10n.autosaveStrings[.english]).keys
        XCTAssertEqual(Set(L10n.autosaveSpanish.keys), Set(englishKeys))
    }

    private func makeProject(title: String, scenes: [(UUID, String)]) -> FrameProject {
        FrameProject(
            title: title,
            scenes: scenes.enumerated().map { index, scene in
                Scene(id: scene.0, order: index, sectionType: .custom, title: "Scene \(index + 1)", scriptText: scene.1)
            }
        )
    }

    private func makeAppState(
        url: URL,
        recorder: ConfirmationRecorder,
        autosaveEnabled: Bool = false,
        closeConfirmation: AppState.CloseConfirmation? = nil,
        saveProjectCopyHandler: (@MainActor () -> Bool)? = nil
    ) -> AppState {
        let suite = UserDefaults(suiteName: "ProjectFileChangeDetectionTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        let store = ProjectStore(project: SampleData.defaultProject, projectWriter: FrameScriptFileStore.write)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: closeConfirmation,
            externalChangeConfirmation: {
                recorder.count += 1
                recorder.onPrompt?()
                return recorder.resolution
            },
            saveProjectCopyHandler: saveProjectCopyHandler
        )
        appState.openProject(at: url)
        return appState
    }

    private func temporaryFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFileChangeDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("Project.fscr")
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(4),
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                XCTFail("Timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
