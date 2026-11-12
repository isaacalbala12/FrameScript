import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class ProjectFileChangeDetectionTests: XCTestCase {
    private final class ConfirmationRecorder {
        var count = 0
        var resolution: ExternalProjectChangeResolution = .cancel
    }

    private final class CopyDestination {
        var url: URL?
        weak var appState: AppState?
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
        saveProjectCopyHandler: (@MainActor () -> Bool)? = nil
    ) -> AppState {
        let suite = UserDefaults(suiteName: "ProjectFileChangeDetectionTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = false
        let store = ProjectStore(project: SampleData.defaultProject, projectWriter: FrameScriptFileStore.write)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            externalChangeConfirmation: {
                recorder.count += 1
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
