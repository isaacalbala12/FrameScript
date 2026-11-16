import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest

@testable import FrameScript

/// A-1 / A-2: the AV paragraph editor must never commit a stale row's text
/// over a different paragraph. These tests host the real editor offscreen and
/// drive its `NSTextView`s; the window is never ordered front.
@MainActor
final class W3FixABFAVEditorTests: XCTestCase {
    private var isolatedDefaults: TestDefaults!
    private var appState: AppState!
    private var project: FrameProject!
    private var editorScene: FrameScript.Scene!
    private var host: W3FixABFOffscreenHost!

    override func setUp() async throws {
        try await super.setUp()
        isolatedDefaults = W3FixABFSupport.makeDefaults()
        project = W3FixABFSupport.makeProject(sceneText: "P1\n\nP2")
        editorScene = project.scenes[0]
        appState = W3FixABFSupport.makeAppState(
            project: project,
            defaults: isolatedDefaults.defaults
        )
        appState.editorState.selectedSceneID = editorScene.id
        appState.editorState.selectedMode = .avScript
        host = makeHost()
    }

    override func tearDown() async throws {
        host?.window.contentView = nil
        host = nil
        isolatedDefaults?.cleanup()
        isolatedDefaults = nil
        appState = nil
        project = nil
        editorScene = nil
        try await super.tearDown()
    }

    func testW3FixABFReturnTwiceSplitsParagraphWithoutDuplicatingText() throws {
        let first = try paragraphTextView(showing: "P1")
        host.window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 2, length: 0))

        first.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.pump()

        // Return at the end of a paragraph creates an empty draft row; the
        // model itself stays untouched until the first character is typed.
        XCTAssertEqual(editorScene.scriptText, "P1\n\nP2")
        let draft = try XCTUnwrap(
            paragraphTextViews().first { $0.string.isEmpty },
            "Return at the end of a paragraph must create an empty paragraph row"
        )
        host.window.makeFirstResponder(draft)
        draft.setSelectedRange(NSRange(location: 0, length: 0))
        draft.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.pump()

        draft.insertText("New", replacementRange: draft.selectedRange())
        host.pump()

        XCTAssertEqual(editorScene.scriptText, "P1\n\nNew\n\nP2")
        XCTAssertEqual(paragraphTextViews().map(\.string), ["P1", "New", "P2"])
    }

    func testW3FixABFClearingParagraphThenTypingNeverOverwritesNextParagraph() throws {
        let first = try paragraphTextView(showing: "P1")
        host.window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 0, length: (first.string as NSString).length))
        first.doCommand(by: #selector(NSText.deleteBackward(_:)))
        host.pump()

        let current = try XCTUnwrap(paragraphTextViews().first)
        current.insertText("X", replacementRange: current.selectedRange())
        host.pump()

        XCTAssertTrue(
            editorScene.scriptText.contains("P2"),
            "Deleting one paragraph and typing must never erase the next paragraph: \(editorScene.scriptText)"
        )
        XCTAssertFalse(
            paragraphTextViews().contains { $0.string.contains("P1\n\nP2") },
            "A paragraph row must never hold more than one model paragraph"
        )
    }

    func testW3FixABFUndoAfterRowShiftDoesNotTouchOtherParagraph() throws {
        let first = try paragraphTextView(showing: "P1")
        let undoManager = try XCTUnwrap(first.undoManager)
        host.window.makeFirstResponder(first)
        first.setSelectedRange(NSRange(location: 2, length: 0))
        first.insertText("A", replacementRange: first.selectedRange())
        host.pump()
        XCTAssertEqual(editorScene.scriptText, "P1A\n\nP2")
        XCTAssertTrue(undoManager.canUndo)

        // An external edit removes paragraph 1; row 0 is now reused for P2.
        appState.commitScriptTextChange(
            sceneID: editorScene.id,
            previousText: editorScene.scriptText,
            text: "P2"
        )
        host.pump()
        XCTAssertTrue(paragraphTextViews().contains { $0.string == "P2" })

        undoManager.undo()
        host.pump()

        XCTAssertTrue(
            editorScene.scriptText.contains("P2"),
            "⌘Z after a row shift must not write another paragraph's text: \(editorScene.scriptText)"
        )
        XCTAssertNotEqual(editorScene.scriptText, "A")
    }

    func testW3FixABFStaleParagraphCommitIsRefused() {
        let original = editorScene.scriptText
        let accepted = appState.commitAVParagraph(
            sceneID: editorScene.id,
            paragraphRange: NSRange(location: 0, length: 2),
            previousText: "Texto que el modelo ya no tiene",
            text: "No debe aplicarse"
        )

        XCTAssertFalse(accepted)
        XCTAssertEqual(editorScene.scriptText, original)
    }

    func testW3FixABFParagraphCommitRegistersAppUndo() {
        let undoManager = UndoManager()
        let accepted = appState.commitAVParagraph(
            sceneID: editorScene.id,
            paragraphRange: NSRange(location: 0, length: 2),
            previousText: "P1",
            text: "Uno",
            undoManager: undoManager
        )

        XCTAssertTrue(accepted)
        XCTAssertEqual(editorScene.scriptText, "Uno\n\nP2")
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(editorScene.scriptText, "P1\n\nP2")
    }

    func testW3FixABFAVCSVExportEscapesFormulasAndAddsBOM() throws {
        editorScene.scriptText = "=SUM(1)\n\nTexto normal"
        appState.touchProject()

        let data = appState.avScriptExportData(format: .csv)
        XCTAssertTrue(data.starts(with: [0xEF, 0xBB, 0xBF]), "accented CSV header needs a BOM")
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(csv.contains("'=SUM(1)"), "spreadsheet formulas must stay text")

        let markdown = try XCTUnwrap(String(
            data: appState.avScriptExportData(format: .markdown),
            encoding: .utf8
        ))
        XCTAssertFalse(markdown.hasPrefix("\u{FEFF}"))
    }

    func testW3FixABFDoneStateAndExportMessagesAreSpanish() {
        XCTAssertEqual(L10n.tr("avScript.done", language: .spanish), "Hecho")
        XCTAssertNotEqual(
            L10n.tr("avScript.exportPanelMessage", language: .spanish),
            L10n.tr("avScript.exportPanelMessage.csv", language: .spanish)
        )
        XCTAssertTrue(
            L10n.tr("avScript.exportPanelMessage.csv", language: .spanish).contains("CSV")
        )
    }

    // MARK: - Hosting

    private func makeHost() -> W3FixABFOffscreenHost {
        let theme = FrameTheme(colorScheme: .light, accent: .sage)
        let root = AVScriptEditorView(scene: editorScene)
            .environment(appState)
            .environment(\.frameTheme, theme)
            .frame(width: 1180, height: 760)
        let host = W3FixABFOffscreenHost(root, size: CGSize(width: 1180, height: 760))
        host.pump()
        return host
    }

    private func paragraphTextViews() -> [NSTextView] {
        host.subviews(of: NSTextView.self)
            .filter { $0 is PlaceholderTextView }
            .sorted { lhs, rhs in
                let left = lhs.convert(lhs.bounds, to: host.hosting)
                let right = rhs.convert(rhs.bounds, to: host.hosting)
                if abs(left.minY - right.minY) > 1 {
                    return left.minY < right.minY
                }
                return left.minX < right.minX
            }
    }

    private func paragraphTextView(showing string: String) throws -> NSTextView {
        try XCTUnwrap(
            paragraphTextViews().first { $0.string == string },
            "No paragraph text view shows \(string): \(paragraphTextViews().map(\.string))"
        )
    }
}
