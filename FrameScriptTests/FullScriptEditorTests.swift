import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class FullScriptEditorTests: FrameScriptTestCase {
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
        projectWriter: ((FrameProject, URL) throws -> Void)? = nil
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
            customTemplates: []
        )
        appState.editorState.selectedSceneID = scenes.first?.id
        return appState
    }

    private func makeHarness(
        scenes: [Scene],
        autosave: Bool = false,
        projectURL: URL? = nil,
        projectWriter: ((FrameProject, URL) throws -> Void)? = nil
    ) -> FullScriptHarness {
        let appState = makeAppState(
            scenes: scenes,
            autosave: autosave,
            projectURL: projectURL,
            projectWriter: projectWriter
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
