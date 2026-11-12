import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class AutosaveTests: XCTestCase {
    private final class WriteRecorder {
        var count = 0
        var lastWrittenProject: FrameProject?
        var lastURL: URL?
    }

    func testAutosaveIntervalDefaultsToTenSecondsAndIsClampedToTheSettingsRange() {
        XCTAssertEqual(AppSettings.defaults.generalPreferences.autosaveIntervalSeconds, 10)
        XCTAssertEqual(AutosaveInterval.defaultSeconds, 10)
        XCTAssertEqual(AutosaveInterval.clampedSeconds(0), 5)
        XCTAssertEqual(AutosaveInterval.clampedSeconds(5), 5)
        XCTAssertEqual(AutosaveInterval.clampedSeconds(42), 42)
        XCTAssertEqual(AutosaveInterval.clampedSeconds(120), 120)
        XCTAssertEqual(AutosaveInterval.clampedSeconds(9_999), 120)
        XCTAssertEqual(AutosaveInterval.duration(forSeconds: 10), .seconds(10))
    }

    func testSavedAutosaveIntervalIsKeptWhenSettingsAreDecoded() throws {
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveIntervalSeconds = 45
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.generalPreferences.autosaveIntervalSeconds, 45)
    }

    func testAutosaveWaitsForTheConfiguredIntervalInsteadOfSixtyMilliseconds() async throws {
        let recorder = WriteRecorder()
        let appState = makeAppState(
            scenes: [Scene(order: 0, sectionType: .hook, title: "Scene", scriptText: "One")],
            interval: 5
        ) { project, url in
            recorder.count += 1
            recorder.lastWrittenProject = project
            recorder.lastURL = url
        }

        appState.touchProject()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(recorder.count, 0, "The old 60 ms debounce must not write before the configured interval")
        XCTAssertEqual(appState.saveState, .edited)
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        try await Task.sleep(for: .milliseconds(5_000))

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(appState.saveState, .saved)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
        XCTAssertEqual(recorder.lastWrittenProject?.title, appState.project.title)
    }

    func testSceneSwitchCommitsTextAndMetricsImmediatelyAndWritesWithoutWaitingForTheInterval() throws {
        let first = Scene(order: 0, sectionType: .hook, title: "First", scriptText: "Old text")
        let second = Scene(order: 1, sectionType: .problem, title: "Second", scriptText: "Other scene")
        let recorder = WriteRecorder()
        let appState = makeAppState(scenes: [first, second], interval: 10) { project, url in
            recorder.count += 1
            recorder.lastWrittenProject = project
            recorder.lastURL = url
        }
        appState.editorState.selectedSceneID = first.id

        appState.commitScriptTextChange(sceneID: first.id, text: "one two three four")

        XCTAssertEqual(first.scriptText, "one two three four")
        XCTAssertEqual(first.estimatedDuration, DurationEstimator.estimate(text: "one two three four", wordsPerMinute: 150))
        XCTAssertEqual(recorder.count, 0)

        appState.selectScene(second.id)

        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(appState.saveState, .saved)
        XCTAssertEqual(recorder.lastWrittenProject?.scenes.first(where: { $0.id == first.id })?.scriptText, "one two three four")
    }

    func testResignActiveWindowCloseAndTerminationFlushPendingChangesImmediately() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Scene", scriptText: "Initial")
        let recorder = WriteRecorder()
        let appState = makeAppState(scenes: [scene], interval: 10) { project, url in
            recorder.count += 1
            recorder.lastWrittenProject = project
            recorder.lastURL = url
        }

        appState.commitScriptTextChange(sceneID: scene.id, text: "resign active text")
        appState.flushForApplicationResignation()
        XCTAssertEqual(recorder.count, 1)
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)

        appState.commitScriptTextChange(sceneID: scene.id, text: "window close text")
        appState.flushForWindowClose()
        XCTAssertEqual(recorder.count, 2)
        XCTAssertEqual(recorder.lastWrittenProject?.scenes.first?.scriptText, "window close text")

        appState.commitScriptTextChange(sceneID: scene.id, text: "termination text")
        XCTAssertTrue(appState.confirmApplicationTermination())
        XCTAssertEqual(recorder.count, 3)
        XCTAssertEqual(recorder.lastWrittenProject?.scenes.first?.scriptText, "termination text")
    }

    func testLifecycleFlushDoesNothingWhenThereAreNoUnsavedChanges() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Scene", scriptText: "Saved")
        let recorder = WriteRecorder()
        let appState = makeAppState(scenes: [scene], interval: 10) { project, url in
            recorder.count += 1
            recorder.lastWrittenProject = project
            recorder.lastURL = url
        }

        appState.flushForApplicationResignation()
        appState.flushForWindowClose()
        XCTAssertTrue(appState.confirmApplicationTermination())

        XCTAssertEqual(recorder.count, 0)
    }

    private func makeAppState(
        scenes: [Scene],
        interval: Int,
        closeConfirmation: AppState.CloseConfirmation? = { .save },
        projectWriter: @escaping (FrameProject, URL) throws -> Void
    ) -> AppState {
        let project = FrameProject(title: "Project", scenes: scenes)
        let store = ProjectStore(project: project, projectWriter: projectWriter)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveTests-\(UUID().uuidString).fscr")
        store.openProject(project, fileURL: url, wordsPerMinute: 150, markUnsaved: false)

        let suite = UserDefaults(suiteName: "AutosaveTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = true
        settings.generalPreferences.autosaveIntervalSeconds = interval
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: closeConfirmation
        )
        appState.editorState.selectedSceneID = scenes.first?.id
        return appState
    }
}
