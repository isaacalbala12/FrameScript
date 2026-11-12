import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class SceneDeletionSelectionTests: XCTestCase {
    func testDeletingSceneAfterAddSceneAfterSelectsTheVisualNeighbor() throws {
        let first = Scene(order: 0, sectionType: .hook, title: "First", scriptText: "First scene")
        let second = Scene(order: 1, sectionType: .problem, title: "Second", scriptText: "Second scene")
        let project = FrameProject(title: "Project", scenes: [first, second])
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store)
        appState.editorState.selectedSceneID = first.id

        // Mirrors the documented repro: storage order stays [first, second, added]
        // while visual order becomes [first, added, second].
        appState.addScene(after: first.id)
        let added = try XCTUnwrap(appState.selectedScene)
        XCTAssertNotEqual(added.id, first.id)
        XCTAssertNotEqual(added.id, second.id)
        XCTAssertEqual(store.project.scenes.sortedByOrder.map(\.id), [first.id, added.id, second.id])

        appState.deleteSelectedScene()

        XCTAssertEqual(appState.editorState.selectedSceneID, second.id)
        XCTAssertEqual(store.project.scenes.sortedByOrder.map(\.id), [first.id, second.id])
    }

    func testDeletingTheLastVisualSceneSelectsThePreviousVisualNeighbor() {
        let first = Scene(order: 0, sectionType: .hook, title: "First", scriptText: "First scene")
        let second = Scene(order: 1, sectionType: .problem, title: "Second", scriptText: "Second scene")
        let third = Scene(order: 2, sectionType: .takeaway, title: "Third", scriptText: "Third scene")
        // Storage order differs from visual order to catch the sorted-index bug.
        let project = FrameProject(title: "Project", scenes: [first, third, second])
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store)
        appState.editorState.selectedSceneID = second.id

        appState.deleteSelectedScene()

        XCTAssertEqual(appState.editorState.selectedSceneID, third.id)
        XCTAssertEqual(store.project.scenes.sortedByOrder.map(\.id), [first.id, third.id])
    }

    func testDeletingTheOnlyRemainingSceneKeepsIt() {
        let only = Scene(order: 0, sectionType: .hook, title: "Only", scriptText: "Only scene")
        let project = FrameProject(title: "Project", scenes: [only])
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store)
        appState.editorState.selectedSceneID = only.id

        appState.deleteSelectedScene()

        XCTAssertEqual(store.project.scenes.map(\.id), [only.id])
        XCTAssertEqual(appState.editorState.selectedSceneID, only.id)
    }

    private func makeAppState(store: ProjectStore) -> AppState {
        let suite = UserDefaults(suiteName: "SceneDeletionSelectionTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.confirmBeforeDeleting = false
        settings.generalPreferences.autosaveEnabled = false
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings")
        )
    }
}
