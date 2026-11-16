import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class FullScriptEditorTests: FrameScriptTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000)

    override func setUp() async throws {
        try await super.setUp()
        clock = Date(timeIntervalSinceReferenceDate: 1_000)
        FullScriptUndoHub.shared.discardAllSteps()
        FullScriptUndoHub.shared.now = { [unowned self] in self.clock }
        FullScriptUndoHub.shared.coalescingInterval = FullScriptUndoHub.defaultCoalescingInterval
    }

    override func tearDown() async throws {
        FullScriptUndoHub.shared.discardAllSteps()
        FullScriptUndoHub.shared.now = { Date() }
        FullScriptUndoHub.shared.coalescingInterval = FullScriptUndoHub.defaultCoalescingInterval
        try await super.tearDown()
    }

    private func advanceClock(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    // MARK: - Typing

    func testTypingCommitsOnlyTheEditedScene() throws {
        let scenes = makeScenes(["aaa", "bbb", "ccc"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("1", replacementRange: harness.textView.selectedRange())
        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("2", replacementRange: harness.textView.selectedRange())
        try caretEnd(of: scenes[2], in: harness)
        harness.textView.insertText("3", replacementRange: harness.textView.selectedRange())

        assertTexts(scenes, ["aaa1", "bbb2", "ccc3"])
        XCTAssertEqual(harness.appState.project.scenes.count, 3)
        XCTAssertTrue(harness.textView.string.contains("aaa1"))
        XCTAssertTrue(harness.textView.string.contains("bbb2"))
        XCTAssertTrue(harness.textView.string.contains("ccc3"))
    }

    func testReturnAtTheEndAndStartOfASceneStaysInThatScene() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertNewline(nil)
        harness.textView.insertText("X", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["aaa\nX", "bbb"])

        try caretStart(of: scenes[1], in: harness)
        harness.textView.insertNewline(nil)
        harness.textView.insertText("Y", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["aaa\nX", "\nYbbb"])
    }

    func testBackspaceAtSceneStartDoesNotMergeOrDeleteTheHeader() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        let firstHeader = try XCTUnwrap(harness.layout.segment(for: scenes[0].id)?.headerRange)
        let headerBefore = (harness.textView.string as NSString).substring(with: firstHeader)

        try caretStart(of: scenes[1], in: harness)
        harness.textView.deleteBackward(nil)

        assertTexts(scenes, ["aaa", "bbb"])
        let firstHeaderAfter = try XCTUnwrap(harness.layout.segment(for: scenes[0].id)?.headerRange)
        XCTAssertEqual((harness.textView.string as NSString).substring(with: firstHeaderAfter), headerBefore)
    }

    func testForwardDeleteAtSceneEndDoesNotDeleteTheSeparator() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.deleteForward(nil)

        assertTexts(scenes, ["aaa", "bbb"])
        let segment = try XCTUnwrap(harness.layout.segment(for: scenes[1].id))
        XCTAssertEqual(
            (harness.textView.string as NSString).character(at: segment.bodyRange.location),
            UInt16(98)
        )
    }

    func testSelectAllAndTypeIsRejectedInsteadOfWipingEveryScene() throws {
        let scenes = makeScenes(["aaa", "bbb", "ccc"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let before = harness.textView.string

        harness.textView.selectAll(nil)
        harness.textView.insertText("WIPED", replacementRange: harness.textView.selectedRange())

        assertTexts(scenes, ["aaa", "bbb", "ccc"])
        XCTAssertEqual(harness.textView.string, before)
        XCTAssertEqual(harness.layout.text, before)
    }

    func testPasteAcrossASceneBoundaryIsRejected() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let first = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        let second = try XCTUnwrap(harness.layout.segment(for: scenes[1].id))
        let before = harness.textView.string

        harness.textView.setSelectedRange(NSRange(
            location: NSMaxRange(first.bodyRange) - 1,
            length: (second.bodyRange.location + 1) - (NSMaxRange(first.bodyRange) - 1)
        ))
        let selected = harness.textView.selectedRange()
        harness.textView.insertText("PASTE", replacementRange: selected)

        assertTexts(scenes, ["aaa", "bbb"])
        XCTAssertEqual(harness.textView.string, before)

        // Deleting the same cross-boundary selection is rejected too.
        harness.textView.setSelectedRange(selected)
        harness.textView.insertText("", replacementRange: selected)
        assertTexts(scenes, ["aaa", "bbb"])
        XCTAssertEqual(harness.textView.string, before)
    }

    func testIMEMarkedTextCommitsOnlyToTheCaretScene() throws {
        let scenes = makeScenes(["hola mundo", "segunda escena"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caret(scenes[0], offset: 4, in: harness)
        harness.textView.setMarkedText(
            "ñ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.textView.unmarkText()

        assertTexts(scenes, ["holañ mundo", "segunda escena"])
    }

    func testMultiStepIMECompositionCommitsTheWholeComposedText() throws {
        let scenes = makeScenes(["hola mundo", "segunda escena"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caret(scenes[0], offset: 4, in: harness)
        harness.textView.setMarkedText(
            "ñ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.textView.setMarkedText(
            "ño",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.textView.setMarkedText(
            "ñor",
            selectedRange: NSRange(location: 3, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.textView.insertText(
            "ñor",
            replacementRange: harness.textView.markedRange()
        )

        assertTexts(scenes, ["holañor mundo", "segunda escena"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
    }

    func testIMEIntoAnEmptySceneStillStaysInThatScene() throws {
        let scenes = makeScenes(["", "segunda"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretStart(of: scenes[0], in: harness)
        harness.textView.setMarkedText(
            "ñ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.textView.unmarkText()

        assertTexts(scenes, ["ñ", "segunda"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
    }

    // MARK: - Undo / redo

    func testUndoAndRedoChainAcrossTwoScenes() throws {
        let scenes = makeScenes(["aaa", "bbb", "ccc"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        XCTAssertTrue(manager.canUndo, "typing must register an undo step")
        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("B", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["aaaA", "bbbB", "ccc"])

        manager.undo()
        assertTexts(scenes, ["aaaA", "bbb", "ccc"])

        manager.undo()
        assertTexts(scenes, ["aaa", "bbb", "ccc"])

        manager.redo()
        assertTexts(scenes, ["aaaA", "bbb", "ccc"])

        manager.redo()
        assertTexts(scenes, ["aaaA", "bbbB", "ccc"])
    }

    func testUndoStepsStayIndependentInsideOneRunLoopTurn() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("1", replacementRange: harness.textView.selectedRange())
        advanceClock(5)
        harness.textView.insertText("2", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["uno12", "dos"])

        manager.undo()
        assertTexts(scenes, ["uno1", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno", "dos"])
        manager.redo()
        manager.redo()
        assertTexts(scenes, ["uno12", "dos"])
    }

    func testStandardUndoAndRedoActionsReachTheWindowManager() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("X", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["unoX", "dos"])

        harness.textView.undo(nil)
        assertTexts(scenes, ["uno", "dos"])
        harness.textView.redo(nil)
        assertTexts(scenes, ["unoX", "dos"])
    }

    func testCollapsedHeaderHidesTheBodyButNeverTouchesSceneText() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        harness.syncParentFromModel(collapsed: [scenes[0].id])
        harness.applyModelTextIfNeeded()

        let collapsed = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        XCTAssertTrue(collapsed.isCollapsed)
        XCTAssertEqual(collapsed.bodyRange.length, 0)
        XCTAssertFalse(harness.layout.text.contains("aaa"))
        XCTAssertEqual(scenes[0].scriptText, "aaa")
        XCTAssertEqual(harness.textView.string, harness.layout.text)
        XCTAssertEqual(
            harness.textView.headerSceneProvider?(collapsed.headerRange.location),
            scenes[0].id
        )
        // The caret is kept inside the collapsed scene instead of jumping to
        // another scene or into the following header.
        XCTAssertEqual(
            harness.layout.sceneID(atUTF16Location: harness.textView.selectedRange().location),
            scenes[0].id
        )
        assertTexts(scenes, ["aaa", "bbb"])
    }

    func testClickingASceneHeaderInvokesTheCollapseAction() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        var toggled: [UUID] = []
        harness.textView.headerClickAction = { toggled.append($0) }

        let segment = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        let layoutManager = try XCTUnwrap(harness.textView.layoutManager)
        let textContainer = try XCTUnwrap(harness.textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyph = layoutManager.glyphIndexForCharacter(at: segment.headerRange.location + 2)
        let rect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        let point = harness.textView.convert(
            NSPoint(
                x: rect.midX + harness.textView.textContainerOrigin.x,
                y: rect.midY + harness.textView.textContainerOrigin.y
            ),
            to: nil
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        harness.textView.mouseDown(with: event)

        XCTAssertEqual(toggled, [scenes[0].id])
        assertTexts(scenes, ["aaa", "bbb"])
    }

    // MARK: - External changes

    func testExternalRewriteOfSceneTwoPreservesCaretInSceneThree() throws {
        let scenes = makeScenes(["uno", "dos", "tres"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caret(scenes[2], offset: 2, in: harness)
        let caretBefore = harness.textView.selectedRange()
        let oldSegment = try XCTUnwrap(harness.layout.segment(for: scenes[2].id))
        let localOffset = caretBefore.location - oldSegment.bodyRange.location

        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "DOS REESCRITO")
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        let newSegment = try XCTUnwrap(harness.layout.segment(for: scenes[2].id))
        XCTAssertEqual(harness.textView.selectedRange().location, newSegment.bodyRange.location + localOffset)
        XCTAssertEqual(harness.layout.sceneID(atUTF16Location: harness.textView.selectedRange().location), scenes[2].id)
        assertTexts(scenes, ["uno", "DOS REESCRITO", "tres"])
        XCTAssertTrue(harness.textView.string.contains("DOS REESCRITO"))
    }

    func testExternalRewriteWhileMarkedTextIsDeferredUntilCompositionEnds() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.setMarkedText(
            "ñ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "DOS EXTERNO")
        XCTAssertTrue(harness.textView.hasMarkedText(), "composition must still be open")
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()
        XCTAssertTrue(harness.textView.hasMarkedText(), "deferral must keep the composition")
        XCTAssertFalse(harness.textView.string.contains("DOS EXTERNO"))
        XCTAssertFalse(harness.layout.text.contains("DOS EXTERNO"), harness.layout.text)

        harness.textView.unmarkText()
        // The composition commit must merge the deferred external scene, not
        // replace the freshly typed character with the pre-composition parent.
        XCTAssertTrue(
            harness.textView.string.contains("DOS EXTERNO"),
            "view=\(harness.textView.string) layout=\(harness.layout.text)"
        )
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        XCTAssertTrue(harness.textView.string.contains("DOS EXTERNO"))
        XCTAssertTrue(
            harness.layout.text.contains("unoñ"),
            "appState=\(scenes.map(\.scriptText)) layout=\(harness.layout.text) view=\(harness.textView.string)"
        )
        assertTexts(scenes, ["unoñ", "DOS EXTERNO"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
    }

    func testReplacingAnEntireSceneBodyOnlyTouchesThatSceneAndCanBeUndone() throws {
        let scenes = makeScenes(["aaa", "bbb", "ccc"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)
        let second = try XCTUnwrap(harness.layout.segment(for: scenes[1].id))

        harness.textView.setSelectedRange(second.bodyRange)
        harness.textView.insertText("NUEVO", replacementRange: second.bodyRange)
        assertTexts(scenes, ["aaa", "NUEVO", "ccc"])

        manager.undo()
        assertTexts(scenes, ["aaa", "bbb", "ccc"])
        manager.redo()
        assertTexts(scenes, ["aaa", "NUEVO", "ccc"])
    }

    func testDeletingAWholeSceneBodyLeavesAnEmptyEditableScene() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let first = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))

        harness.textView.setSelectedRange(first.bodyRange)
        harness.textView.insertText("", replacementRange: first.bodyRange)
        assertTexts(scenes, ["", "bbb"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)

        harness.textView.setSelectedRange(NSRange(location: first.bodyRange.location, length: 0))
        harness.textView.insertText("x", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["x", "bbb"])
    }

    func testUndoAfterAnExternalRewriteOnlyRestoresTheEditedScene() throws {
        let scenes = makeScenes(["uno", "dos", "tres"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "DOS EXTERNO")
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        manager.undo()
        assertTexts(scenes, ["uno", "DOS EXTERNO", "tres"])
        manager.redo()
        assertTexts(scenes, ["unoA", "DOS EXTERNO", "tres"])
    }

    // MARK: - Autosave

    func testAutosaveMidTypingWritesTheCommittedSceneText() throws {
        let scenes = makeScenes(["aaa", "bbb", "ccc"])
        let recorder = SaveRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullScriptEditorTests-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = makeHarness(
            scenes: scenes,
            autosave: true,
            projectURL: url,
            projectWriter: { project, _ in
                recorder.write(project)
            }
        )
        defer { harness.teardown() }

        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("X", replacementRange: harness.textView.selectedRange())
        harness.appState.performAutosave(synchronous: true)

        XCTAssertEqual(recorder.projects.last?.scenes.first(where: { $0.id == scenes[1].id })?.scriptText, "bbbX")
        XCTAssertEqual(recorder.projects.last?.scenes.first(where: { $0.id == scenes[0].id })?.scriptText, "aaa")

        harness.textView.insertText("Y", replacementRange: harness.textView.selectedRange())
        harness.appState.performAutosave(synchronous: true)
        XCTAssertEqual(recorder.projects.last?.scenes.first(where: { $0.id == scenes[1].id })?.scriptText, "bbbXY")
        assertTexts(scenes, ["aaa", "bbbXY", "ccc"])
    }

    // MARK: - View switching

    func testSwitchingToSingleSceneAndBackKeepsTheLastKeystroke() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("Z", replacementRange: harness.textView.selectedRange())
        XCTAssertEqual(scenes[0].scriptText, "aaaZ")

        harness.appState.selectScene(scenes[1].id)
        XCTAssertFalse(harness.appState.isFullScriptSelected)
        XCTAssertEqual(harness.appState.selectedScene?.id, scenes[1].id)
        XCTAssertEqual(scenes[0].scriptText, "aaaZ")

        harness.appState.selectFullScript()
        XCTAssertTrue(harness.appState.isFullScriptSelected)
        XCTAssertEqual(harness.appState.selectedMode, .script)

        // Recreate the AppKit editor the way SwiftUI does when the user comes
        // back; the text comes from the committed model, not from a stale view.
        harness.teardown()
        let reopened = makeHarness(appState: harness.appState)
        defer { reopened.teardown() }
        XCTAssertTrue(reopened.layout.text.contains("aaaZ"), "layout=\(reopened.layout.text)")
        XCTAssertTrue(reopened.textView.string.contains("aaaZ"), "view=\(reopened.textView.string)")
        XCTAssertEqual(reopened.textView.string, reopened.layout.text)
    }

    func testUndoAfterSwitchingViewsAndBackDoesNotCorruptAnything() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        let window = harness.window
        let manager = try XCTUnwrap(window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        XCTAssertEqual(scenes[0].scriptText, "aaaA")

        // Tear down the full-script editor (as switching to a scene does) and
        // leave only the long-lived undo hub as the action target.
        harness.coordinator?.detach(from: harness.container)
        harness.coordinator = nil
        window.contentView = nil
        XCTAssertTrue(manager.canUndo)

        manager.undo()
        XCTAssertEqual(scenes[0].scriptText, "aaa")
        XCTAssertEqual(scenes[1].scriptText, "bbb")

        // Coming back mounts a fresh coordinator; redo must reach it.
        let reopened = makeHarness(appState: harness.appState, window: window)
        defer { reopened.teardown() }
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        XCTAssertEqual(scenes[0].scriptText, "aaaA")
        XCTAssertEqual(reopened.textView.string, reopened.layout.text)
    }

    func testExternalFileReloadRebuildsTheDocumentAndKeepsTheCaretScene() throws {
        let ids = [UUID(), UUID(), UUID()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullScriptReload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.fscr")

        func project(title: String, texts: [String]) -> FrameProject {
            FrameProject(
                title: title,
                scenes: ids.enumerated().map { index, id in
                    Scene(id: id, order: index, sectionType: .custom, title: "Escena \(index + 1)", scriptText: texts[index])
                }
            )
        }

        try FrameScriptFileStore.write(project: project(title: "Local", texts: ["uno", "dos", "tres"]), to: url)
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        let appState = AppState(
            projectStore: ProjectStore(project: project(title: "Local", texts: ["uno", "dos", "tres"]), projectWriter: FrameScriptFileStore.write),
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            customTemplates: []
        )
        appState.openProject(at: url)
        defer { appState.resetProjectFileTracking() }
        appState.selectFullScript()
        let harness = makeHarness(appState: appState)
        defer { harness.teardown() }

        let third = try XCTUnwrap(appState.project.scenes.first(where: { $0.id == ids[2] }))
        try caret(third, offset: 2, in: harness)

        try FrameScriptFileStore.write(
            project: project(title: "External", texts: ["uno", "DOS EXTERNO", "tres"]),
            to: url
        )
        appState.checkForExternalProjectChanges()
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        assertTexts(
            appState.project.scenes.sortedByOrder,
            ["uno", "DOS EXTERNO", "tres"]
        )
        XCTAssertEqual(harness.textView.string, harness.layout.text)
        let thirdSegment = try XCTUnwrap(harness.layout.segment(for: ids[2]))
        XCTAssertEqual(harness.textView.selectedRange().location, thirdSegment.bodyRange.location + 2)
        XCTAssertEqual(harness.layout.sceneID(atUTF16Location: harness.textView.selectedRange().location), ids[2])
    }

    // MARK: - Selection and view model

    func testSelectingTheFullScriptEntryAndASceneTogglesThePresentation() {
        let scenes = makeScenes(["aaa", "bbb"])
        let appState = makeAppState(scenes: scenes)
        XCTAssertFalse(appState.isFullScriptSelected)

        appState.selectFullScript()
        XCTAssertTrue(appState.isFullScriptSelected, "selectFullScript must select the entry")
        XCTAssertEqual(appState.fullScriptCaretScene?.id, scenes[0].id)
        XCTAssertEqual(appState.activeEditorScene?.id, scenes[0].id)
        XCTAssertTrue(appState.toolbarContextTitle.contains("01"), appState.toolbarContextTitle)

        appState.setFullScriptCaretScene(scenes[1].id)
        XCTAssertEqual(appState.activeEditorScene?.id, scenes[1].id)

        appState.selectScene(scenes[1].id)
        XCTAssertFalse(appState.isFullScriptSelected)
        XCTAssertEqual(appState.activeEditorScene?.id, scenes[1].id)

        appState.selectFullScript()
        appState.editorState.resetScriptEditorStates()
        XCTAssertFalse(appState.isFullScriptSelected)
        XCTAssertNil(appState.fullScriptCaretScene)
    }

    // MARK: - Performance

    func testKeystrokeRestylesOnlyTheEditedSceneOnThirtyScenesOfSevenHundredWords() throws {
        let word = "palabra"
        let scenes: [Scene] = (0..<30).map { index in
            let paragraphs = (0..<7).map { paragraph in
                Array(repeating: word, count: 100).joined(separator: " ")
                    + (paragraph == 6 ? "." : "\n\n")
            }
            return Scene(
                order: index,
                sectionType: .custom,
                title: "Escena \(index + 1)",
                scriptText: paragraphs.joined()
            )
        }
        XCTAssertGreaterThan(
            scenes.reduce(0) { $0 + ScriptMarkup.spokenWordCount($1.scriptText) },
            20_000
        )
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let edited = scenes[15]
        let editedLength = try XCTUnwrap(harness.layout.segment(for: edited.id)?.bodyRange.length)
        try caretEnd(of: edited, in: harness)
        let originalEditedText = edited.scriptText

        var total = 0.0
        let iterations = 8
        for _ in 0..<iterations {
            let started = DispatchTime.now()
            harness.textView.insertText("a", replacementRange: harness.textView.selectedRange())
            total += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            XCTAssertGreaterThan(harness.lastAppliedCharacterCount, 0)
            XCTAssertLessThanOrEqual(
                harness.lastAppliedCharacterCount,
                editedLength + iterations,
                "a keystroke must restyle only the edited scene"
            )
        }
        let average = total / Double(iterations)
        let documentLength = harness.layout.utf16Length
        let measurement = String(
            format: "Full-script keystroke: %.2f ms, restyled %d of %d UTF-16 units",
            average,
            harness.lastAppliedCharacterCount,
            documentLength
        )
        let attachment = XCTAttachment(string: measurement)
        attachment.name = "full-script-perf"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(harness.lastAppliedCharacterCount, documentLength / 10)
        #if DEBUG
        let limit = 120.0
        #else
        let limit = 60.0
        #endif
        XCTAssertLessThan(average, limit, "keystroke average \(average) ms")
        let expected = scenes.enumerated().map { index, scene in
            index == 15 ? originalEditedText + String(repeating: "a", count: iterations) : scene.scriptText
        }
        assertTexts(scenes, expected)
    }

    // MARK: - Undo safety (external text is never overwritten)

    func testUndoNeverDiscardsTextTypedInTheSingleSceneEditor() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        // The single-scene editor appends "B" to the same scene.
        harness.appState.commitScriptTextChange(sceneID: scenes[0].id, text: "aaaAB")
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        manager.undo()
        XCTAssertEqual(scenes[0].scriptText, "aaaAB", "B must survive the first undo")
        manager.undo()
        XCTAssertEqual(scenes[0].scriptText, "aaaAB", "B must survive the second undo")
        XCTAssertEqual(harness.textView.string, harness.layout.text)
        manager.redo()
        XCTAssertEqual(scenes[0].scriptText, "aaaAB", "a stale redo must not overwrite external text either")
    }

    func testRedoIsASafeNoOpAfterTheSceneChangedExternally() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("X", replacementRange: harness.textView.selectedRange())
        manager.undo()
        assertTexts(scenes, ["uno", "dos"])

        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "dos EXTERNO")
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        assertTexts(scenes, ["uno", "dos EXTERNO"])
    }

    func testUndoAfterReloadFromDiskKeepsTheExternalTextAndClearsTheHistory() throws {
        let ids = [UUID(), UUID()]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullScriptUndoReload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Project.fscr")
        func project(_ texts: [String]) -> FrameProject {
            FrameProject(title: "Local", scenes: ids.enumerated().map { index, id in
                Scene(id: id, order: index, sectionType: .custom, title: "Escena \(index + 1)", scriptText: texts[index])
            })
        }
        try FrameScriptFileStore.write(project: project(["uno", "dos"]), to: url)
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        let appState = AppState(
            projectStore: ProjectStore(project: project(["uno", "dos"]), projectWriter: FrameScriptFileStore.write),
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            customTemplates: []
        )
        appState.openProject(at: url)
        defer { appState.resetProjectFileTracking() }
        appState.selectFullScript()
        let harness = makeHarness(appState: appState)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        let second = try XCTUnwrap(appState.project.scenes.first { $0.id == ids[1] })
        try caretEnd(of: second, in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        XCTAssertTrue(manager.canUndo)

        try FrameScriptFileStore.write(project: project(["uno", "DOS EXTERNO REESCRITO"]), to: url)
        XCTAssertTrue(appState.reloadProjectFromDisk())
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()
        XCTAssertEqual(second.scriptText, "dosA", "precondition: the old object is replaced")
        let reloaded = try XCTUnwrap(appState.project.scenes.first { $0.id == ids[1] })
        XCTAssertEqual(reloaded.scriptText, "DOS EXTERNO REESCRITO")
        XCTAssertFalse(manager.canUndo, "reload must clear the full-script steps")

        manager.undo()
        XCTAssertEqual(reloaded.scriptText, "DOS EXTERNO REESCRITO")
    }

    func testUndoStepOnlyAppliesWhenTheSceneHoldsTheTextItProduced() throws {
        // An unregistered change of the same scene (no reload) must also win.
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("A", replacementRange: harness.textView.selectedRange())
        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "dosA + texto externo")
        manager.undo()
        XCTAssertEqual(scenes[1].scriptText, "dosA + texto externo")
    }

    // MARK: - Undo granularity

    func testTypingCoalescesIntoOneUndoGroupAndStoresDiffs() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        for character in ["h", "o", "l", "a"] {
            harness.textView.insertText(character, replacementRange: harness.textView.selectedRange())
            advanceClock(0.2)
        }
        assertTexts(scenes, ["unohola", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno", "dos"])
        XCTAssertFalse(manager.canUndo, "four keystrokes must be one group")
        manager.redo()
        assertTexts(scenes, ["unohola", "dos"])
    }

    func testBackspaceRunCoalescesToo() throws {
        let scenes = makeScenes(["abcdef"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        try caretEnd(of: scenes[0], in: harness)
        harness.textView.deleteBackward(nil)
        harness.textView.deleteBackward(nil)
        harness.textView.deleteBackward(nil)
        assertTexts(scenes, ["abc"])
        manager.undo()
        assertTexts(scenes, ["abcdef"])
        XCTAssertFalse(manager.canUndo)
    }

    func testPauseCaretJumpAndSceneChangeBreakTheUndoGroup() throws {
        let scenes = makeScenes(["uno", "dos"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let manager = try XCTUnwrap(harness.window.undoManager)

        // Pause.
        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("1", replacementRange: harness.textView.selectedRange())
        advanceClock(0.3)
        harness.textView.insertText("2", replacementRange: harness.textView.selectedRange())
        advanceClock(3)
        harness.textView.insertText("3", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["uno123", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno12", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno", "dos"])
        XCTAssertFalse(manager.canUndo)
        manager.redo()
        manager.redo()
        assertTexts(scenes, ["uno123", "dos"])

        // Caret jump inside the same scene.
        try caret(scenes[0], offset: 0, in: harness)
        harness.textView.insertText("<", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["<uno123", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno123", "dos"])

        // Scene change.
        try caretEnd(of: scenes[0], in: harness)
        harness.textView.insertText("x", replacementRange: harness.textView.selectedRange())
        try caretEnd(of: scenes[1], in: harness)
        harness.textView.insertText("y", replacementRange: harness.textView.selectedRange())
        manager.undo()
        assertTexts(scenes, ["uno123x", "dos"])
        manager.undo()
        assertTexts(scenes, ["uno123", "dos"])
    }

    func testTextEditDiffHandlesSurrogatePairsAndRoundTrips() throws {
        let edit = try XCTUnwrap(FullScriptTextEdit.diff(old: "a😀c", new: "a😎c"))
        XCTAssertEqual(edit.location, 1)
        XCTAssertEqual(edit.removed, "😀")
        XCTAssertEqual(edit.inserted, "😎")
        XCTAssertEqual(edit.applied(to: "a😎c"), "a😀c")
        XCTAssertNil(edit.applied(to: "a😀c"), "the inserted run must be present")
        XCTAssertNil(FullScriptTextEdit.diff(old: "same", new: "same"))
        let insertion = try XCTUnwrap(FullScriptTextEdit.diff(old: "ab", new: "aXXb"))
        XCTAssertEqual(insertion, FullScriptTextEdit(location: 1, removed: "", inserted: "XX"))
    }

    // MARK: - Stale write-back

    func testKeystrokeWithAStaleViewRebuildsFromTheModelInsteadOfOverwritingIt() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }

        try caretEnd(of: scenes[1], in: harness)
        // Another writer changes the model; SwiftUI has not refreshed the view.
        harness.appState.commitScriptTextChange(sceneID: scenes[1].id, text: "bbb DEL MODELO")
        harness.textView.insertText("Z", replacementRange: harness.textView.selectedRange())

        assertTexts(scenes, ["aaa", "bbb DEL MODELO"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
        XCTAssertTrue(harness.textView.string.contains("bbb DEL MODELO"))
        XCTAssertFalse(harness.textView.string.contains("bbbZ"))
    }

    // MARK: - Triple-click on the last paragraph

    func testTypingOverATripleClickedLastParagraphReplacesItInsteadOfBeeping() throws {
        let scenes = makeScenes(["primera linea\nsegunda linea", "otra"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let segment = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        let paragraphStart = segment.bodyRange.location + ("primera linea\n" as NSString).length

        // A triple-click selects the paragraph plus the protected separator.
        let tripleClick = NSRange(
            location: paragraphStart,
            length: NSMaxRange(segment.separatorRange) - paragraphStart
        )
        harness.textView.setSelectedRange(tripleClick)
        harness.textView.insertText("nueva", replacementRange: harness.textView.selectedRange())

        assertTexts(scenes, ["primera linea\nnueva", "otra"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
        XCTAssertEqual(harness.layout.sceneID(atUTF16Location: harness.textView.selectedRange().location), scenes[0].id)

        // Deleting the same kind of selection works as well, and the header
        // of the next scene is untouched.
        let after = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        let start = after.bodyRange.location + ("primera linea\n" as NSString).length
        let again = NSRange(location: start, length: NSMaxRange(after.separatorRange) - start)
        harness.textView.setSelectedRange(again)
        harness.textView.deleteBackward(nil)
        assertTexts(scenes, ["primera linea\n", "otra"])
        XCTAssertEqual(harness.textView.string, harness.layout.text)
    }

    func testSelectionReachingIntoTheNextHeaderIsStillRejected() throws {
        let scenes = makeScenes(["aaa", "bbb"])
        let harness = makeHarness(scenes: scenes)
        defer { harness.teardown() }
        let first = try XCTUnwrap(harness.layout.segment(for: scenes[0].id))
        let second = try XCTUnwrap(harness.layout.segment(for: scenes[1].id))
        let before = harness.textView.string
        harness.textView.setSelectedRange(NSRange(
            location: first.bodyRange.location,
            length: second.headerRange.location + 3 - first.bodyRange.location
        ))
        harness.textView.insertText("X", replacementRange: harness.textView.selectedRange())
        assertTexts(scenes, ["aaa", "bbb"])
        XCTAssertEqual(harness.textView.string, before)
    }

    // MARK: - Scene commands follow the caret scene

    private func harnessWithCaretInSceneThree(
        confirmationHandler: AppState.ConfirmationHandler? = nil
    ) throws -> (FullScriptHarness, [Scene]) {
        let scenes = makeScenes(["uno importante", "dos", "tres. cuatro. cinco."])
        let harness = makeHarness(scenes: scenes, confirmationHandler: confirmationHandler)
        try caretEnd(of: scenes[2], in: harness)
        XCTAssertEqual(harness.appState.editorState.selectedSceneID, scenes[0].id, "sidebar selection is stale on purpose")
        XCTAssertEqual(harness.appState.activeEditorScene?.id, scenes[2].id)
        XCTAssertEqual(harness.appState.selectedScene?.id, scenes[2].id)
        return (harness, scenes)
    }

    func testDeleteSceneRemovesTheCaretSceneAndNamesItInTheConfirmation() throws {
        var messages: [String] = []
        let (harness, scenes) = try harnessWithCaretInSceneThree { _, message in
            messages.append(message)
            return true
        }
        defer { harness.teardown() }

        harness.appState.deleteSelectedScene()

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("03 Escena 3"), messages[0])
        let remaining = harness.appState.project.scenes.sortedByOrder.map(\.id)
        XCTAssertEqual(remaining, [scenes[0].id, scenes[1].id])
        XCTAssertEqual(scenes[0].scriptText, "uno importante")
    }

    func testDeleteSceneConfirmationCancelKeepsEverything() throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree { _, _ in false }
        defer { harness.teardown() }
        harness.appState.deleteSelectedScene()
        XCTAssertEqual(harness.appState.project.scenes.count, scenes.count)
    }

    func testDuplicateSceneCopiesTheCaretScene() throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree()
        defer { harness.teardown() }

        harness.appState.duplicateSelectedScene()

        let texts = harness.appState.project.scenes.map(\.scriptText)
        XCTAssertEqual(texts.count, 4)
        XCTAssertEqual(texts.filter { $0 == "tres. cuatro. cinco." }.count, 2)
        XCTAssertEqual(texts.filter { $0 == "uno importante" }.count, 1)
        XCTAssertEqual(scenes[0].scriptText, "uno importante")
    }

    func testRenameSceneTargetsTheCaretSceneAndNamesItInThePrompt() throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree()
        defer { harness.teardown() }
        var promptMessage = ""
        var promptDefault = ""
        harness.appState.promptHandler = { _, message, defaultValue in
            promptMessage = message
            promptDefault = defaultValue
            return "Cierre"
        }

        harness.appState.renameSelectedScene()

        XCTAssertTrue(promptMessage.contains("03 Escena 3"), promptMessage)
        XCTAssertEqual(promptDefault, "Escena 3")
        XCTAssertEqual(scenes[2].title, "Cierre")
        XCTAssertEqual(scenes[0].title, "Escena 1")
    }

    func testMoveSceneUpAndDownMoveTheCaretScene() throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree()
        defer { harness.teardown() }

        harness.appState.moveSelectedSceneUp()
        XCTAssertEqual(
            harness.appState.project.scenes.sortedByOrder.map(\.id),
            [scenes[0].id, scenes[2].id, scenes[1].id]
        )
        harness.appState.moveSelectedSceneUp()
        XCTAssertEqual(
            harness.appState.project.scenes.sortedByOrder.map(\.id),
            [scenes[2].id, scenes[0].id, scenes[1].id]
        )
        harness.appState.moveSelectedSceneDown()
        XCTAssertEqual(
            harness.appState.project.scenes.sortedByOrder.map(\.id),
            [scenes[0].id, scenes[2].id, scenes[1].id]
        )
    }

    func testRehookSuggestionsTargetAndInsertIntoTheCaretScene() async throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree()
        defer { harness.teardown() }
        // A long first scene pushes the short last scene out of the re-hook
        // window, so no positions are planned and no provider is called.
        let longText = Array(repeating: "Frase con diez palabras de relleno para el guion.", count: 40).joined(separator: " ")
        scenes[0].scriptText = longText
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()
        let result: RehookGenerationResult
        do {
            result = try await harness.appState.generateRehookSuggestions()
        } catch {
            XCTFail("generate threw \(error)")
            return
        }
        XCTAssertEqual(result.sceneID, scenes[2].id)
        XCTAssertNotEqual(result.sceneID, scenes[0].id)

        scenes[2].scriptText = "Uno. Dos. Tres."
        harness.syncParentFromModel()
        harness.applyModelTextIfNeeded()

        let range = try XCTUnwrap(HookInsertion.anchorRange(for: "Dos.", in: scenes[2].scriptText))
        let suggestion = RehookSuggestion(
            text: "Puente.",
            anchor: "Dos.",
            anchorRange: range,
            wordCount: 1,
            estimatedSeconds: 0.4
        )
        XCTAssertTrue(harness.appState.insertRehookSuggestion(suggestion, sceneID: result.sceneID, undoManager: UndoManager()))
        XCTAssertEqual(scenes[2].scriptText, "Uno.\n\n[RE-HOOK]\nPuente.\n\nDos. Tres.")
        XCTAssertEqual(scenes[0].scriptText, longText)
    }

    func testSidebarSelectionIsUsedAgainOutsideFullScriptMode() throws {
        let (harness, scenes) = try harnessWithCaretInSceneThree()
        defer { harness.teardown() }
        harness.appState.selectScene(scenes[1].id)
        XCTAssertFalse(harness.appState.isFullScriptSelected)
        XCTAssertEqual(harness.appState.selectedScene?.id, scenes[1].id)
        XCTAssertEqual(harness.appState.activeEditorScene?.id, scenes[1].id)
    }

    // MARK: - Helpers

    private func makeScenes(_ texts: [String]) -> [Scene] {
        texts.enumerated().map { index, text in
            Scene(
                order: index,
                sectionType: .custom,
                title: "Escena \(index + 1)",
                scriptText: text
            )
        }
    }

    private func makeAppState(
        scenes: [Scene],
        autosave: Bool = false,
        projectURL: URL? = nil,
        projectWriter: ((FrameProject, URL) throws -> Void)? = nil,
        confirmationHandler: AppState.ConfirmationHandler? = nil
    ) -> AppState {
        let defaults = makeDefaults()
        let project = FrameProject(title: "Prueba de guion completo", scenes: scenes)
        let store = ProjectStore(project: project, projectWriter: projectWriter)
        store.openProject(project, fileURL: projectURL, wordsPerMinute: 150, markUnsaved: false)
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = autosave
        settings.editorPreferences.spellcheck = false
        settings.editorPreferences.smartQuotes = false
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            confirmationHandler: confirmationHandler,
            customTemplates: []
        )
        appState.editorState.selectedSceneID = scenes.first?.id
        return appState
    }

    private func makeHarness(
        scenes: [Scene],
        autosave: Bool = false,
        projectURL: URL? = nil,
        projectWriter: ((FrameProject, URL) throws -> Void)? = nil,
        confirmationHandler: AppState.ConfirmationHandler? = nil
    ) -> FullScriptHarness {
        let appState = makeAppState(
            scenes: scenes,
            autosave: autosave,
            projectURL: projectURL,
            projectWriter: projectWriter,
            confirmationHandler: confirmationHandler
        )
        appState.selectFullScript()
        return makeHarness(appState: appState)
    }

    private func makeHarness(appState: AppState, window existingWindow: NSWindow? = nil) -> FullScriptHarness {
        let window: NSWindow
        if let existingWindow {
            window = existingWindow
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isRestorable = false
        }
        let container = FullScriptTextContainerView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700)
        )
        window.contentView = container
        window.layoutIfNeeded()
        container.layoutSubtreeIfNeeded()
        let scenes = appState.project.scenes.sortedByOrder
        let representable = makeRepresentable(appState: appState, scenes: scenes)
        let coordinator = FullScriptTextView.Coordinator(parent: representable)
        coordinator.attach(to: container)
        container.layoutSubtreeIfNeeded()
        return FullScriptHarness(
            appState: appState,
            window: window,
            container: container,
            coordinator: coordinator
        )
    }

    private func makeRepresentable(
        appState: AppState,
        scenes: [Scene]
    ) -> FullScriptTextView {
        let snapshots = scenes.map { scene in
            let number = String(format: "%02d", scene.order + 1)
            return FullScriptSceneSnapshot(
                id: scene.id,
                order: scene.order,
                headerText: "▾  ESCENA \(number)  ·  \(scene.title)  ·  1:00",
                numberText: number,
                durationText: "1:00",
                scriptText: scene.scriptText,
                isCollapsed: false
            )
        }
        return FullScriptTextView(
            scenes: snapshots,
            appearance: FullScriptEditorAppearance(
                fontSize: 20,
                textColor: .labelColor,
                secondaryTextColor: .secondaryLabelColor,
                accentColor: .systemBlue,
                backgroundColor: .textBackgroundColor
            ),
            spellcheck: false,
            smartQuotes: false,
            pauseDefaults: .standard,
            placeholder: "Texto",
            accessibilityLabel: "Guion completo",
            accessibilityHint: "Todas las escenas",
            loadRestorationState: {
                appState.editorState.fullScriptEditorState()
            },
            saveRestorationState: { state in
                appState.editorState.setFullScriptEditorState(state)
            },
            currentSceneText: { @MainActor @Sendable [weak appState] sceneID in
                appState?.project.scenes.first { $0.id == sceneID }?.scriptText
            },
            onSceneTextCommitted: { @MainActor @Sendable [weak appState] sceneID, previousText, text in
                appState?.commitScriptTextChange(
                    sceneID: sceneID,
                    previousText: previousText,
                    text: text
                )
            },
            onCaretSceneChanged: { [weak appState] sceneID in
                appState?.setFullScriptCaretScene(sceneID)
            },
            onToggleCollapse: { _ in },
            onTeardown: {}
        )
    }

    private func caretStart(of scene: Scene, in harness: FullScriptHarness) throws {
        try caret(scene, offset: 0, in: harness)
    }

    private func caretEnd(of scene: Scene, in harness: FullScriptHarness) throws {
        let segment = try XCTUnwrap(harness.layout.segment(for: scene.id))
        try caret(scene, offset: segment.bodyRange.length, in: harness)
    }

    private func caret(_ scene: Scene, offset: Int, in harness: FullScriptHarness) throws {
        let segment = try XCTUnwrap(harness.layout.segment(for: scene.id))
        XCTAssertEqual(segment.bodyRange.length, (scene.scriptText as NSString).length, "harness must be synced")
        let clamped = min(max(0, offset), segment.bodyRange.length)
        harness.textView.setSelectedRange(
            NSRange(location: segment.bodyRange.location + clamped, length: 0)
        )
    }

    private func assertTexts(
        _ scenes: [Scene],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(scenes.count, expected.count, file: file, line: line)
        for (scene, text) in zip(scenes, expected) {
            XCTAssertEqual(scene.scriptText, text, "scene \(scene.order + 1)", file: file, line: line)
        }
    }

    private final class SaveRecorder {
        private(set) var projects: [FrameProject] = []

        func write(_ project: FrameProject) {
            projects.append(project)
        }
    }
}

@MainActor
private final class FullScriptHarness {
    let appState: AppState
    let window: NSWindow
    let container: FullScriptTextContainerView
    var coordinator: FullScriptTextView.Coordinator?

    var textView: FullScriptEditableTextView { container.textView }

    var layout: FullScriptLayout {
        coordinator?.layout ?? FullScriptLayout(scenes: [])
    }

    var lastAppliedCharacterCount: Int {
        coordinator?.lastAppliedCharacterCount ?? 0
    }

    func applyModelTextIfNeeded() {
        coordinator?.applyModelTextIfNeeded()
    }

    init(
        appState: AppState,
        window: NSWindow,
        container: FullScriptTextContainerView,
        coordinator: FullScriptTextView.Coordinator
    ) {
        self.appState = appState
        self.window = window
        self.container = container
        self.coordinator = coordinator
    }

    func syncParentFromModel(collapsed: Set<UUID> = []) {
        guard let coordinator else { return }
        let scenes = appState.project.scenes.sortedByOrder
        var parent = coordinator.parent
        parent.scenes = scenes.map { scene in
            let number = String(format: "%02d", scene.order + 1)
            let isCollapsed = collapsed.contains(scene.id)
            return FullScriptSceneSnapshot(
                id: scene.id,
                order: scene.order,
                headerText: "\(isCollapsed ? "▸" : "▾")  ESCENA \(number)  ·  \(scene.title)  ·  1:00",
                numberText: number,
                durationText: "1:00",
                scriptText: scene.scriptText,
                isCollapsed: isCollapsed
            )
        }
        coordinator.parent = parent
    }

    func teardown() {
        if let coordinator {
            coordinator.detach(from: container)
        }
        coordinator = nil
        window.contentView = nil
    }
}
