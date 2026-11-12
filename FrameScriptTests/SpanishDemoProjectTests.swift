import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class SpanishDemoProjectTests: XCTestCase {
    private let expectedTitle = "Análisis de Apexia: la actualización 3.0"

    func testSpanishDemoIsCompleteAnchorFirstShowcase() throws {
        let project = SampleData.demoProject(language: .spanish)
        let scenes = project.scenes.sortedByOrder

        XCTAssertEqual(project.title, expectedTitle)
        XCTAssertEqual(scenes.count, 5)
        XCTAssertEqual(scenes.map(\.sectionType), [.hook, .problem, .explanation, .example, .takeaway])
        XCTAssertTrue(scenes.allSatisfy { !$0.notes.isEmpty })
        XCTAssertTrue(scenes.allSatisfy { !$0.scriptText.isEmpty && $0.estimatedDuration > 0 && !$0.textSegments.isEmpty })
        XCTAssertTrue(scenes.filter { !$0.bRollItems.isEmpty }.count >= 4)
        XCTAssertTrue(scenes.filter { !$0.editingItems.isEmpty }.count >= 4)
        XCTAssertTrue(scenes.filter { !$0.aiComments.isEmpty }.count >= 3)
        XCTAssertTrue(scenes.flatMap(\.aiComments).allSatisfy { $0.status == .new && !$0.message.isEmpty && !$0.suggestion.isEmpty })
        XCTAssertGreaterThanOrEqual(Set(scenes.flatMap(\.bRollItems).map(\.sourceType)).count, 5)
        XCTAssertGreaterThanOrEqual(Set(scenes.flatMap(\.bRollItems).map(\.status)).count, 4)

        let first = try XCTUnwrap(scenes.first)
        XCTAssertLessThanOrEqual(first.estimatedDuration, 15)
        XCTAssertFalse(first.bRollItems.isEmpty)
        XCTAssertFalse(first.editingItems.isEmpty)
        XCTAssertFalse(first.aiComments.isEmpty)
        XCTAssertTrue(scenes.flatMap { [$0.scriptText] }.joined().contains("Apexia"))
        XCTAssertTrue(scenes.flatMap { [$0.scriptText] }.joined().contains("actualización 3.0"))
        XCTAssertEqual(scenes.last?.title, "Conclusión y llamada a la acción")

        let analysis = try XCTUnwrap(SimracingTemplates.all.first { $0.kind == .updateAnalysis })
        XCTAssertEqual(project.templateID, analysis.id)

        assertCurrentAnchors(in: scenes)
        assertRequiredGroups(in: scenes)
    }

    func testSpanishDemoSelectionReturnsSpanishProject() {
        XCTAssertEqual(SampleData.demoProject(language: .spanish).title, expectedTitle)
        XCTAssertNotEqual(SampleData.demoProject(language: .english).title, expectedTitle)
        XCTAssertNotEqual(SampleData.demoProject(language: .russian).title, expectedTitle)
    }

    func testSpanishDemoSaveRoundTripPreservesContentAndAnchors() throws {
        let project = SampleData.demoProject(language: .spanish)
        let url = temporaryProjectURL()
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)

        XCTAssertEqual(loaded.title, project.title)
        XCTAssertEqual(loaded.scenes.map(\.title), project.scenes.map(\.title))
        XCTAssertEqual(loaded.scenes.map(\.scriptText), project.scenes.map(\.scriptText))
        XCTAssertEqual(loaded.scenes.flatMap(\.bRollItems).count, project.scenes.flatMap(\.bRollItems).count)
        XCTAssertEqual(loaded.scenes.flatMap(\.editingItems).count, project.scenes.flatMap(\.editingItems).count)
        XCTAssertEqual(loaded.scenes.flatMap(\.aiComments).count, project.scenes.flatMap(\.aiComments).count)
        assertCurrentAnchors(in: loaded.scenes)
    }

    func testOpenDemoProjectUsesSpanishWhenSelected() {
        let suite = UserDefaults(suiteName: "SpanishDemoProjectTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        let store = ProjectStore()
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings")
        )

        appState.openDemoProject()

        XCTAssertTrue(store.isBuiltInDemo)
        XCTAssertEqual(store.project.title, expectedTitle)
        XCTAssertEqual(store.project.scenes.count, 5)
        XCTAssertEqual(store.project.scenes.sortedByOrder.first?.title, "Gancho")
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

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SpanishDemoProjectTests-\(UUID().uuidString).fscr")
    }
}
