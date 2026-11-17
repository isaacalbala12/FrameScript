import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

@MainActor
final class TimelineTests: XCTestCase {
    /// Isolated suites live in the process temporary directory, so no test
    /// writes `~/Library/Preferences`.
    private var testDefaults: [TestDefaults] = []

    override func setUp() {
        super.setUp()
        TestBundleCleanup.register()
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let pending = TimelineNavigation.shared.pendingRequest {
                TimelineNavigation.shared.consume(pending.id)
            }
            for defaults in testDefaults {
                defaults.cleanup()
            }
            testDefaults.removeAll()
        }
        try await super.tearDown()
    }

    // MARK: Mode

    func testTimelineModeHasStableRawValueAndShortcut() {
        XCTAssertEqual(WorkspaceMode.timeline.rawValue, "Timeline")
        // Integration moved the timeline to ⌘5: the clips workspace landed
        // first and already owns ⌘4.
        XCTAssertEqual(ShortcutRegistry.definition(for: .timelineMode).factoryDefault, .init("5", modifiers: [.command]))
        XCTAssertEqual(ShortcutRegistry.definition(for: .timelineZoomIn).factoryDefault, .init("=", modifiers: [.command]))
        XCTAssertEqual(ShortcutRegistry.definition(for: .timelineZoomOut).factoryDefault, .init("-", modifiers: [.command]))
    }

    func testTimelineShortcutsDoNotConflictWithExistingCommands() {
        var seen = Set<ShortcutBinding>()
        for command in ShortcutCommand.allCases {
            let binding = ShortcutRegistry.definition(for: command).factoryDefault
            XCTAssertTrue(seen.insert(binding).inserted, "Duplicate default shortcut for \(command.rawValue)")
        }
    }

    // MARK: Input

    func testInputFollowsSortedSceneOrderAndMapsEveryTrack() {
        let first = makeScene(order: 1, title: "Segunda", text: "Dos palabras")
        let second = makeScene(order: 0, title: "Primera", text: "Dos palabras más")
        let project = FrameProject(title: "Sintético", scenes: [first, second], primaryLanguage: "es")
        let anchor = second.bRollItems[0].textAnchor?.startUTF16
        XCTAssertNotNil(anchor)

        let selectedTakeID = first.takes[0].id
        let warning = RhythmWarning(
            sceneID: first.id.uuidString,
            kind: .longSentence,
            range: UTF16Span(location: 0, length: 4),
            messageKey: RhythmMessageKey.longSentence
        )
        let input = TimelineInputBuilder.input(
            project: project,
            configuration: DurationConfiguration(wordsPerMinute: 150),
            selectedTakeIDs: [first.id: selectedTakeID],
            warningsByScene: [first.id: [warning]],
            projectWarnings: []
        )

        XCTAssertEqual(input.scenes.map(\.title), ["Primera", "Segunda"])
        XCTAssertEqual(input.scenes[0].bRoll.count, 1)
        XCTAssertEqual(input.scenes[0].editing.count, 1)
        XCTAssertEqual(input.scenes[0].warnings.count, 0)
        XCTAssertEqual(input.scenes[1].warnings.first?.kind, .longSentence)
        XCTAssertEqual(input.scenes[1].takes.first(where: \.isSelected)?.id, selectedTakeID)
        XCTAssertEqual(input.scenes[1].takes.first(where: \.isSelected)?.rating, .good)
        XCTAssertEqual(input.configuration.wordsPerMinute, 150)
    }

    func testInputMarksUnanchoredProductionItems() {
        let scene = makeScene(order: 0, title: "Escena", text: "Texto")
        scene.bRollItems[0].textAnchor = nil
        let project = FrameProject(title: "Sintético", scenes: [scene], primaryLanguage: "es")

        let input = TimelineInputBuilder.input(
            project: project,
            configuration: DurationConfiguration(wordsPerMinute: 150),
            selectedTakeIDs: [:],
            warningsByScene: [:],
            projectWarnings: []
        )

        XCTAssertNil(input.scenes[0].bRoll[0].anchorUTF16)
        XCTAssertEqual(input.scenes[0].bRoll[0].label, "Plano de apoyo")
    }

    func testProjectLevelWarningsAreAttachedToTheirSceneOnly() {
        let first = makeScene(order: 0, title: "Uno", text: "Uno dos")
        let second = makeScene(order: 1, title: "Dos", text: "Tres cuatro")
        let project = FrameProject(title: "Sintético", scenes: [first, second], primaryLanguage: "es")
        let warning = RhythmWarning(
            sceneID: second.id.uuidString,
            kind: .sceneLengthOutlier,
            range: UTF16Span(location: 0, length: 4),
            messageKey: RhythmMessageKey.sceneLengthOutlier
        )

        let input = TimelineInputBuilder.input(
            project: project,
            configuration: DurationConfiguration(wordsPerMinute: 150),
            selectedTakeIDs: [:],
            warningsByScene: [:],
            projectWarnings: [warning]
        )

        XCTAssertTrue(input.scenes[0].warnings.isEmpty)
        XCTAssertEqual(input.scenes[1].warnings.count, 1)
        XCTAssertEqual(input.scenes[1].warnings[0].kind, .sceneLengthOutlier)
    }

    // MARK: Hit testing

    func testHitTestingFindsBlocksOnEveryTrack() {
        let text = "Uno dos / tres\n\nCuatro cinco"
        let scene = makeScene(order: 0, title: "Escena", text: text)
        let input = TimelineInputBuilder.input(
            project: FrameProject(title: "Sintético", scenes: [scene], primaryLanguage: "es"),
            configuration: DurationConfiguration(wordsPerMinute: 60),
            selectedTakeIDs: [scene.id: scene.takes[0].id],
            warningsByScene: [:],
            projectWarnings: []
        )
        let layout = TimelineLayoutBuilder.build(input)
        let metrics = TimelineTrackMetrics.standard
        let viewport = TimelineViewport(pointsPerSecond: 8)

        for block in layout.blocks {
            let x = viewport.x(for: block.start + block.duration / 2)
            let y: CGFloat
            if block.track == .takes {
                let rect = metrics.takeLaneRect(lane: block.lane, lanesUsed: layout.maximumLane(on: .takes) + 1)
                y = metrics.yOffset(for: .takes) + rect.offset + rect.height / 2
            } else {
                y = metrics.yOffset(for: block.track) + metrics.height(for: block.track) / 2
            }
            let hit = TimelineHitTester.block(
                at: CGPoint(x: x, y: y),
                layout: layout,
                metrics: metrics,
                viewport: viewport
            )
            XCTAssertNotNil(hit, "No hit for \(block.track.rawValue) \(block.id)")
            XCTAssertEqual(hit?.track, block.track)
        }
    }

    func testTakeLaneHitTestingPicksTheRightTake() {
        let firstTake = Take(number: 1, startedAt: Date(timeIntervalSince1970: 1), duration: 8, rating: .good)
        let secondTake = Take(number: 2, startedAt: Date(timeIntervalSince1970: 2), duration: 8, rating: .safe)
        let scene = makeScene(order: 0, title: "Escena", text: "Uno dos tres", takes: [firstTake, secondTake])
        let input = TimelineInputBuilder.input(
            project: FrameProject(title: "Sintético", scenes: [scene], primaryLanguage: "es"),
            configuration: DurationConfiguration(wordsPerMinute: 60),
            selectedTakeIDs: [scene.id: firstTake.id],
            warningsByScene: [:],
            projectWarnings: []
        )
        let layout = TimelineLayoutBuilder.build(input)
        let metrics = TimelineTrackMetrics.standard
        let viewport = TimelineViewport(pointsPerSecond: 8)
        let takeTop = metrics.yOffset(for: .takes)
        let rect0 = metrics.takeLaneRect(lane: 0, lanesUsed: 2)
        let rect1 = metrics.takeLaneRect(lane: 1, lanesUsed: 2)

        let lane0 = TimelineHitTester.block(
            at: CGPoint(x: 4, y: takeTop + rect0.offset + rect0.height / 2),
            layout: layout,
            metrics: metrics,
            viewport: viewport
        )
        let lane1 = TimelineHitTester.block(
            at: CGPoint(x: 4, y: takeTop + rect1.offset + rect1.height / 2),
            layout: layout,
            metrics: metrics,
            viewport: viewport
        )

        XCTAssertEqual(lane0?.lane, 0)
        XCTAssertEqual(lane1?.lane, 1)
        XCTAssertEqual(lane0?.itemID, firstTake.id)
        XCTAssertEqual(lane1?.itemID, secondTake.id)
    }

    func testSceneInsertionIndexAccountsForTheDraggedScene() {
        let sceneA = TimelineSceneInput(id: UUID(), title: "A", text: "uno dos")
        let sceneB = TimelineSceneInput(id: UUID(), title: "B", text: "tres cuatro")
        let sceneC = TimelineSceneInput(id: UUID(), title: "C", text: "cinco seis")
        let layout = TimelineLayoutBuilder.build(
            scenes: [sceneA, sceneB, sceneC],
            configuration: TimelineConfiguration(wordsPerMinute: 60)
        )
        let viewport = TimelineViewport(pointsPerSecond: 10)

        XCTAssertEqual(
            TimelineHitTester.sceneInsertionIndex(
                atX: viewport.x(for: 5.5),
                layout: layout,
                viewport: viewport,
                excluding: sceneA.id
            ),
            2
        )
        XCTAssertEqual(
            TimelineHitTester.sceneInsertionIndex(
                atX: viewport.x(for: 0.5),
                layout: layout,
                viewport: viewport,
                excluding: sceneA.id
            ),
            0
        )
    }

    // MARK: Navigation

    func testTimelineParagraphClickOpensScriptEditorWithTheParagraphRange() {
        let scene = makeScene(order: 0, title: "Escena", text: "Uno dos tres")
        let appState = makeAppState(project: FrameProject(
            title: "Sintético",
            scenes: [scene],
            primaryLanguage: "es"
        ))
        let range = NSRange(location: 4, length: 3)

        appState.openTimelineScene(scene.id, sourceRange: range)

        XCTAssertEqual(appState.selectedMode, .script)
        XCTAssertEqual(appState.selectedScene?.id, scene.id)
        XCTAssertEqual(TimelineNavigation.shared.pendingRequest?.sceneID, scene.id)
        XCTAssertEqual(TimelineNavigation.shared.pendingRequest?.range, range)
    }

    func testTimelineProductionItemClickSelectsItInItsWorkspace() {
        let scene = makeScene(order: 0, title: "Escena", text: "Uno dos tres")
        let item = scene.bRollItems[0]
        let appState = makeAppState(project: FrameProject(
            title: "Sintético",
            scenes: [scene],
            primaryLanguage: "es"
        ))

        appState.openTimelineProductionItem(item.id, sceneID: scene.id, mode: .bRoll)

        XCTAssertEqual(appState.selectedMode, .bRoll)
        XCTAssertEqual(appState.selectedScene?.id, scene.id)
        XCTAssertTrue(appState.editorState.selectedProductionItemIDs.contains(item.id))
    }

    // MARK: Reorder

    func testReorderMovesASceneAndUndoIsOneStep() {
        let sceneA = makeScene(order: 0, title: "A", text: "Uno dos")
        let sceneB = makeScene(order: 1, title: "B", text: "Tres cuatro")
        let sceneC = makeScene(order: 2, title: "C", text: "Cinco seis")
        let project = FrameProject(title: "Sintético", scenes: [sceneA, sceneB, sceneC], primaryLanguage: "es")
        let appState = makeAppState(project: project)
        let undoManager = UndoManager()

        appState.moveTimelineScene(sceneC.id, toSortedIndex: 0, undoManager: undoManager)

        XCTAssertEqual(appState.project.scenes.sortedByOrder.map(\.title), ["C", "A", "B"])
        XCTAssertEqual(appState.project.scenes.sortedByOrder.map(\.order), [0, 1, 2])
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(appState.project.scenes.sortedByOrder.map(\.title), ["A", "B", "C"])
        XCTAssertTrue(undoManager.canRedo)

        undoManager.redo()
        XCTAssertEqual(appState.project.scenes.sortedByOrder.map(\.title), ["C", "A", "B"])
    }

    func testReorderingToTheSamePlaceDoesNotRegisterUndo() {
        let sceneA = makeScene(order: 0, title: "A", text: "Uno")
        let sceneB = makeScene(order: 1, title: "B", text: "Dos")
        let project = FrameProject(title: "Sintético", scenes: [sceneA, sceneB], primaryLanguage: "es")
        let appState = makeAppState(project: project)
        let undoManager = UndoManager()

        appState.moveTimelineScene(sceneA.id, toSortedIndex: 0, undoManager: undoManager)

        XCTAssertFalse(undoManager.canUndo)
    }

    func testTimelineSceneOrderReordersPureIDs() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(
            TimelineSceneOrder.reorderedIDs([a, b, c], moving: a, to: 2),
            [b, c, a]
        )
        XCTAssertEqual(
            TimelineSceneOrder.reorderedIDs([a, b, c], moving: c, to: 0),
            [c, a, b]
        )
        XCTAssertEqual(
            TimelineSceneOrder.reorderedIDs([a, b, c], moving: b, to: 99),
            [a, c, b]
        )
    }

    // MARK: Zoom

    func testZoomStateClampsAndSteps() {
        let state = TimelineViewState(pointsPerSecond: 4)
        state.zoomIn()
        XCTAssertEqual(state.pointsPerSecond, 5)
        state.zoomOut()
        XCTAssertEqual(state.pointsPerSecond, 4)
        state.setPointsPerSecond(1_000)
        XCTAssertEqual(state.pointsPerSecond, TimelineZoom.maximumPointsPerSecond)
        state.zoomFraction = 0
        XCTAssertEqual(state.pointsPerSecond, TimelineZoom.minimumPointsPerSecond)
    }

    // MARK: Fixtures

    private func makeScene(
        order: Int,
        title: String,
        text: String,
        takes: [Take]? = nil
    ) -> FrameScript.Scene {
        let id = UUID()
        let bRollAnchor = TextAnchorRepair.anchor(
            in: text,
            range: (text as NSString).range(of: "Dos").location == NSNotFound
                ? NSRange(location: 0, length: min(3, (text as NSString).length))
                : (text as NSString).range(of: "Dos")
        )
        let editingAnchor = TextAnchorRepair.anchor(
            in: text,
            range: NSRange(location: 0, length: min(4, (text as NSString).length))
        )
        return FrameScript.Scene(
            id: id,
            order: order,
            sectionType: .custom,
            title: title,
            scriptText: text,
            bRollItems: [
                BRollItem(
                    textAnchor: bRollAnchor,
                    templateType: "",
                    sourceType: .stockFootage,
                    descriptionText: "Plano de apoyo"
                )
            ],
            editingItems: [
                EditingItem(
                    textAnchor: editingAnchor,
                    templateType: "",
                    cutStyle: "Corte suave",
                    transition: "",
                    subtitleStyle: ""
                )
            ],
            takes: takes ?? [
                Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 10),
                    duration: 6,
                    rating: .good,
                    readText: text,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                )
            ]
        )
    }

    private func makeAppState(project: FrameProject) -> AppState {
        let isolated = TestDefaults.make()
        testDefaults.append(isolated)
        let defaults = isolated.defaults
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: EmptyOBSSecrets()),
            defaults: defaults
        )
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: defaults, key: "settings"),
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            customTemplates: []
        )
    }
}

private struct EmptyOBSSecrets: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
