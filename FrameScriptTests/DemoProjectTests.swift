import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class DemoProjectTests: XCTestCase {
    func testEditedDemoClosesAndReplacesWithoutConfirmationWhileNormalUnsavedProjectDoesNot() {
        let demo = SampleData.demoProject(language: .english)
        let store = ProjectStore(project: demo)
        store.openProject(demo, fileURL: nil, wordsPerMinute: 150, markUnsaved: false, origin: .builtInDemo)
        let appState = makeAppState(store: store)
        store.markProjectDirty()

        XCTAssertTrue(store.isBuiltInDemo)
        XCTAssertFalse(store.needsCloseConfirmation)

        appState.createNewProject(named: "Replacement", template: SampleData.templates.first)
        XCTAssertEqual(store.project.title, "Replacement")
        XCTAssertFalse(store.isBuiltInDemo)

        store.openProject(demo, fileURL: nil, wordsPerMinute: 150, markUnsaved: false, origin: .builtInDemo)
        store.markProjectDirty()
        XCTAssertTrue(appState.closeProject())
        XCTAssertFalse(store.hasOpenProject)

        let normal = FrameProject(title: "Untitled", scenes: [])
        store.openProject(normal, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)
        XCTAssertFalse(store.isBuiltInDemo)
        XCTAssertTrue(store.needsCloseConfirmation)
    }

    func testReturningToProjectListPromptsDirtyProjectOnceAndNeverPromptsBuiltInDemo() {
        let normal = FrameProject(title: "Untitled", scenes: [])
        let store = ProjectStore(project: normal)
        store.openProject(normal, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)
        var confirmations = 0
        let appState = makeAppState(store: store, closeConfirmation: {
            confirmations += 1
            return .discard
        })

        XCTAssertTrue(appState.returnToProjectList())
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(store.hasOpenProject)

        let demo = SampleData.demoProject(language: .english)
        store.openProject(demo, fileURL: nil, wordsPerMinute: 150, markUnsaved: false, origin: .builtInDemo)
        store.markProjectDirty()
        XCTAssertTrue(appState.returnToProjectList())
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(store.hasOpenProject)
    }

    func testDemoEditsDoNotAutosave() async throws {
        let demo = SampleData.demoProject(language: .english)
        var writes = 0
        let store = ProjectStore(project: demo) { _, _ in writes += 1 }
        store.openProject(demo, fileURL: temporaryProjectURL(), wordsPerMinute: 150, markUnsaved: false, origin: .builtInDemo)
        let appState = makeAppState(store: store)

        appState.touchProject()
        appState.flushForApplicationResignation()
        appState.flushForWindowClose()
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(writes, 0)
        XCTAssertTrue(store.hasUnsavedFileChanges)
        XCTAssertFalse(store.needsCloseConfirmation)
    }

    func testManualDemoSaveConvertsSessionIntoNormalSavedProject() throws {
        let demo = SampleData.demoProject(language: .english)
        let url = temporaryProjectURL()
        let store = ProjectStore(project: demo)
        store.openProject(demo, fileURL: nil, wordsPerMinute: 150, markUnsaved: false, origin: .builtInDemo)
        store.markProjectDirty()

        try store.saveCurrentProject(to: url, wordsPerMinute: 150)

        XCTAssertEqual(store.origin, .normal)
        XCTAssertFalse(store.isBuiltInDemo)
        XCTAssertEqual(store.currentFileURL, url)
        XCTAssertFalse(store.hasUnsavedFileChanges)
        XCTAssertFalse(store.needsCloseConfirmation)

        store.markProjectDirty()
        XCTAssertTrue(store.needsCloseConfirmation)
    }

    func testLocalizedDemosAreCompleteAnchorFirstShowcases() throws {
        for language in [AppLanguage.english, .russian] {
            let project = SampleData.demoProject(language: language)
            let scenes = project.scenes.sortedByOrder

            XCTAssertEqual(scenes.count, 5)
            XCTAssertEqual(scenes.map(\.sectionType), [.hook, .problem, .explanation, .example, .takeaway])
            XCTAssertTrue(scenes.allSatisfy { !$0.scriptText.contains("\n\n") || !$0.notes.isEmpty })
            XCTAssertTrue(scenes.filter { !$0.notes.isEmpty }.count >= 4)
            XCTAssertTrue(scenes.allSatisfy { !$0.scriptText.isEmpty && $0.estimatedDuration > 0 && !$0.textSegments.isEmpty })
            XCTAssertTrue(scenes.filter { !$0.bRollItems.isEmpty }.count >= 4)
            XCTAssertTrue(scenes.filter { !$0.editingItems.isEmpty }.count >= 4)
            XCTAssertTrue(scenes.filter { !$0.aiComments.isEmpty }.count >= 3)
            XCTAssertTrue(scenes.flatMap(\.aiComments).allSatisfy { $0.status == .new && !$0.message.isEmpty && !$0.suggestion.isEmpty })
            XCTAssertGreaterThanOrEqual(Set(scenes.flatMap(\.bRollItems).map(\.sourceType)).count, 5)
            XCTAssertGreaterThanOrEqual(Set(scenes.flatMap(\.bRollItems).map(\.status)).count, 4)

            let first = try XCTUnwrap(scenes.first)
            XCTAssertFalse(first.bRollItems.isEmpty)
            XCTAssertFalse(first.editingItems.isEmpty)
            XCTAssertFalse(first.aiComments.isEmpty)
            assertCurrentAnchors(in: scenes)
            assertRequiredGroups(in: scenes)
        }
    }

    func testExplicitDemoSaveAndFileRoundTripPreserveContentAndAnchors() throws {
        for language in [AppLanguage.english, .russian] {
            let project = SampleData.demoProject(language: language)
            let url = temporaryProjectURL()
            try FrameScriptFileStore.write(project: project, to: url)
            let loaded = try FrameScriptFileStore.read(from: url)

            XCTAssertEqual(loaded.title, project.title)
            XCTAssertEqual(loaded.scenes.map(\.title), project.scenes.map(\.title))
            XCTAssertEqual(loaded.scenes.map(\.scriptText), project.scenes.map(\.scriptText))
            XCTAssertEqual(loaded.scenes.flatMap(\.bRollItems).count, project.scenes.flatMap(\.bRollItems).count)
            XCTAssertEqual(loaded.scenes.flatMap(\.editingItems).count, project.scenes.flatMap(\.editingItems).count)
            assertCurrentAnchors(in: loaded.scenes)
        }
    }

    private func assertCurrentAnchors(in scenes: [Scene], line: UInt = #line) {
        for scene in scenes {
            XCTAssertEqual(scene.bRollItems.compactMap(\.textAnchor).count, scene.bRollItems.count, line: line)
            XCTAssertEqual(scene.editingItems.compactMap(\.textAnchor).count, scene.editingItems.count, line: line)
            for anchor in scene.bRollItems.compactMap(\.textAnchor) + scene.editingItems.compactMap(\.textAnchor) {
                let text = scene.scriptText as NSString
                XCTAssertFalse(anchor.selectedText.isEmpty, line: line)
                XCTAssertGreaterThan(anchor.lengthUTF16, 0, line: line)
                XCTAssertGreaterThanOrEqual(anchor.startUTF16, 0, line: line)
                XCTAssertLessThanOrEqual(NSMaxRange(anchor.nsRange), text.length, line: line)
                XCTAssertEqual(text.substring(with: anchor.nsRange), anchor.selectedText, line: line)
                XCTAssertEqual(text.substring(with: NSRange(location: max(0, anchor.startUTF16 - anchor.prefixContext.utf16.count), length: anchor.prefixContext.utf16.count)), anchor.prefixContext, line: line)
                XCTAssertEqual(text.substring(with: NSRange(location: NSMaxRange(anchor.nsRange), length: anchor.suffixContext.utf16.count)), anchor.suffixContext, line: line)
            }
        }
    }

    private func assertRequiredGroups(in scenes: [Scene], line: UInt = #line) {
        let first = scenes[0]
        let visualRanges = first.bRollItems.compactMap(\.textAnchor).map(\.nsRange)
        XCTAssertGreaterThanOrEqual(Set(visualRanges.map { "\($0.location):\($0.length)" }).count, 2, line: line)
        XCTAssertTrue(hasDuplicateRange(visualRanges), "Expected a duplicate production group", line: line)
        let allRanges = first.bRollItems.compactMap(\.textAnchor).map(\.nsRange) + first.editingItems.compactMap(\.textAnchor).map(\.nsRange)
        XCTAssertTrue(hasOverlappingRanges(allRanges), "Expected an overlapping production group", line: line)
    }

    private func hasDuplicateRange(_ ranges: [NSRange]) -> Bool {
        Set(ranges.map { "\($0.location):\($0.length)" }).count < ranges.count
    }

    private func hasOverlappingRanges(_ ranges: [NSRange]) -> Bool {
        ranges.enumerated().contains { index, range in
            ranges.dropFirst(index + 1).contains { candidate in
                range.location < NSMaxRange(candidate) && candidate.location < NSMaxRange(range)
            }
        }
    }

    private func makeAppState(
        store: ProjectStore,
        closeConfirmation: AppState.CloseConfirmation? = nil
    ) -> AppState {
        let suite = UserDefaults(suiteName: "DemoProjectTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = true
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: closeConfirmation
        )
    }

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DemoProjectTests-\(UUID().uuidString).fscr")
    }
}
