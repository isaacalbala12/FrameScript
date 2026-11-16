import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest

@testable import FrameScript

/// A-1 / A-2 after the navigation redesign: AV narration is read-only and the
/// Script workspace is the single narration editor. The right column remains
/// editable.
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
        let anchor = try XCTUnwrap(
            TextAnchorRepair.anchor(
                in: editorScene.scriptText,
                range: NSRange(location: 0, length: 2)
            )
        )
        editorScene.bRollItems = [
            BRollItem(
                textAnchor: anchor,
                templateType: "",
                sourceType: .stockFootage,
                descriptionText: "Plano de prueba"
            )
        ]
        appState = W3FixABFSupport.makeAppState(
            project: project,
            defaults: isolatedDefaults.defaults
        )
        appState.editorState.selectedSceneID = editorScene.id
        appState.editorState.selectedMode = .avScript
        host = makeHost()
    }

    override func tearDown() async throws {
        if let pending = TimelineNavigation.shared.pendingRequest {
            TimelineNavigation.shared.consume(pending.id)
        }
        host?.window.contentView = nil
        host = nil
        isolatedDefaults?.cleanup()
        isolatedDefaults = nil
        appState = nil
        project = nil
        editorScene = nil
        try await super.tearDown()
    }

    // MARK: - Read-only narration

    func testW3FixABFNarrationColumnHasNoEditableTextView() {
        let views = narrationViews()

        XCTAssertEqual(views.map(\.string), ["P1", "P2"])
        XCTAssertTrue(
            views.allSatisfy { !$0.isEditable },
            "AV narration must never expose an editable text view"
        )
        XCTAssertTrue(
            views.allSatisfy(\.isSelectable),
            "AV narration stays selectable and copyable"
        )
        XCTAssertTrue(
            views.allSatisfy { !$0.allowsUndo },
            "AV narration must not register undo actions"
        )
    }

    func testW3FixABFEditInScriptSwitchesModeAndSelectsTheParagraph() throws {
        let paragraphRange = (editorScene.scriptText as NSString).range(of: "P2")

        appState.editAVParagraphInScript(
            sceneID: editorScene.id,
            range: paragraphRange
        )

        XCTAssertEqual(appState.selectedMode, .script)
        XCTAssertEqual(appState.selectedScene?.id, editorScene.id)
        XCTAssertEqual(TimelineNavigation.shared.pendingRequest?.sceneID, editorScene.id)
        XCTAssertEqual(TimelineNavigation.shared.pendingRequest?.range, paragraphRange)
    }

    func testW3FixABFDoubleClickingNarrationOpensTheScriptEditor() throws {
        let view = try XCTUnwrap(narrationViews().first { $0.string == "P2" })
        let paragraphRange = (editorScene.scriptText as NSString).range(of: "P2")
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: host.window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 2,
                pressure: 1
            )
        )

        view.mouseDown(with: event)

        XCTAssertEqual(appState.selectedMode, .script)
        XCTAssertEqual(TimelineNavigation.shared.pendingRequest?.range, paragraphRange)
    }

    func testW3FixABFEditActionIsVisibleInTheRow() {
        let result = SnapshotRenderer.render(
            AVScriptEditorView(scene: editorScene),
            name: "av-editor-readonly-1180x760-light",
            suite: "w3-fix-abf2",
            size: CGSize(width: 1180, height: 760),
            appearance: .light,
            language: .spanish,
            appState: appState
        )

        XCTAssertGreaterThan(result.pixelSize.width, 0)
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("Editar en Guion") },
            "each paragraph row must expose the edit action: \(result.textFragments)"
        )
    }

    // MARK: - External edits

    func testW3FixABFExternalScriptEditIsReflectedInAV() {
        appState.commitScriptTextChange(
            sceneID: editorScene.id,
            previousText: editorScene.scriptText,
            text: "P1 edited\n\nP2"
        )
        host.pump()

        XCTAssertEqual(narrationViews().map(\.string), ["P1 edited", "P2"])
    }

    // MARK: - Annotations stay editable

    func testW3FixABFAnnotationTextStaysEditable() throws {
        let annotationView = try XCTUnwrap(
            host.subviews(of: NSTextView.self).first { $0.string == "Plano de prueba" },
            "the B-roll description editor is missing"
        )
        XCTAssertTrue(annotationView.isEditable)

        host.window.makeFirstResponder(annotationView)
        annotationView.setSelectedRange(
            NSRange(location: (annotationView.string as NSString).length, length: 0)
        )
        annotationView.insertText(" ampliado", replacementRange: annotationView.selectedRange())
        host.pump()

        XCTAssertEqual(editorScene.bRollItems.first?.descriptionText, "Plano de prueba ampliado")
        XCTAssertTrue(narrationViews().allSatisfy { !$0.isEditable })
    }

    // MARK: - A-6 CSV

    func testW3FixABFAVCSVExemptsDashSpaceNarrationButEscapesFormulas() throws {
        editorScene.scriptText = "- uno dos\n\n=SUM(1)"
        appState.touchProject()

        let csv = appState.avScriptExportText(format: .csv, escapeFormulas: true)
        XCTAssertTrue(csv.contains(",- uno dos,"), "dialogue dashes must not become apostrophes: \(csv)")
        XCTAssertFalse(csv.contains("'- uno dos"), csv)
        XCTAssertTrue(csv.contains("'=SUM(1)"), "formula-like narration stays neutralised")
    }

    func testW3FixABFAVCSVExportAddsBOMForFileWrites() throws {
        let data = appState.avScriptExportData(format: .csv)
        XCTAssertTrue(data.starts(with: [0xEF, 0xBB, 0xBF]))

        let markdown = try XCTUnwrap(
            String(data: appState.avScriptExportData(format: .markdown), encoding: .utf8)
        )
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
        XCTAssertEqual(L10n.tr("avScript.editInScript", language: .spanish), "Editar en Guion")
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

    private func narrationViews() -> [NSTextView] {
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
}
