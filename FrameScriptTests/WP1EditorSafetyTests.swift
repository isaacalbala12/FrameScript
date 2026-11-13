import AppKit
import Foundation
import SwiftUI
@testable import FrameScript
import XCTest

/// WP1 editor regressions: undo must not cross scenes, autocomplete language
/// detection stays bounded, and the marker column explains itself.
@MainActor
final class WP1EditorSafetyTests: FrameScriptTestCase {
    private final class TextBox {
        var value: String
        init(_ value: String) { self.value = value }
    }

    @MainActor
    private final class AutocompleteRecorder {
        private(set) var contexts: [AutocompleteContext] = []

        func request(_ context: AutocompleteContext) async -> AutocompleteResult {
            contexts.append(context)
            return .none
        }
    }

    /// Fails before the fix: the reused NSTextView kept scene A's undo stack, so
    /// Cmd-Z in scene B re-applied scene A's edit (and autosave kept it).
    func testUndoHistoryIsClearedWhenTheSceneChanges() throws {
        let sceneAID = UUID()
        let sceneBID = UUID()
        let box = TextBox("scene A text")
        let parentA = makeRepresentable(sceneID: sceneAID, text: Binding(get: { box.value }, set: { box.value = $0 }))
        let coordinator = LinkedScriptTextView.Coordinator(parent: parentA)
        let container = MarkerTextContainerView()
        coordinator.attach(to: container)
        coordinator.applyModelTextIfNeeded()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        container.layoutSubtreeIfNeeded()
        let textView = container.textView
        let undoManager = try XCTUnwrap(textView.undoManager, "The text view must have an undo manager")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        // A real edit so NSTextView registers its own undo action, exactly like
        // a user typing.
        textView.insertText("!", replacementRange: textView.selectedRange())
        textView.didChangeText()
        XCTAssertTrue(undoManager.canUndo)

        // What SwiftUI does when the selected scene changes: same view, new
        // scene ID, then the model text is applied.
        coordinator.parent = makeRepresentable(
            sceneID: sceneBID,
            text: Binding(get: { "scene B text" }, set: { _ in })
        )
        coordinator.applyModelTextIfNeeded()

        XCTAssertEqual(textView.string, "scene B text")
        XCTAssertFalse(undoManager.canUndo, "Scene A's undo actions must be gone")
        if undoManager.canUndo {
            undoManager.undo()
        }
        XCTAssertEqual(textView.string, "scene B text", "Undo must never rewrite the new scene")
    }

    /// Fails before the fix: language detection ran over the whole script before
    /// the caret, not the bounded context prefix.
    func testAutocompleteLanguageDetectionUsesTheBoundedPrefix() async throws {
        let recorder = AutocompleteRecorder()
        let russianFiller = String(repeating: "слово ", count: 2_000)
        let englishTail = String(repeating: "This is an English sentence. ", count: 30)
        let text = russianFiller + englishTail
        let box = TextBox(text)
        let parent = makeRepresentable(
            sceneID: UUID(),
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            autocomplete: { context in await recorder.request(context) }
        )
        let coordinator = LinkedScriptTextView.Coordinator(parent: parent)
        let container = MarkerTextContainerView()
        coordinator.attach(to: container)
        container.textView.delegate = coordinator
        container.textView.string = text
        container.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: container.textView))
        for _ in 0..<200 where recorder.contexts.isEmpty {
            await Task.yield()
        }

        let context = try XCTUnwrap(recorder.contexts.first)
        XCTAssertEqual(context.language, .english, "Only the last 600 characters may be classified")
        XCTAssertLessThanOrEqual(context.prefix.count, 600)
    }

    func testMarkerTooltipDescribesTheMarkerMode() throws {
        let text = "alpha target omega"
        let anchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: (text as NSString).range(of: "target")))
        let container = MarkerTextContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.textView.string = text
        container.textView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.addBRollLabel = "Add visual for selection"
        container.addEditingLabel = "Add editing note for selection"
        container.markers = [
            ProductionTextMarker(itemID: UUID(), mode: .bRoll, anchor: anchor)
        ]
        container.layoutSubtreeIfNeeded()
        let rect = try XCTUnwrap(container.markerRects().first?.rect)

        let point = NSPoint(x: rect.midX, y: rect.midY)

        XCTAssertEqual(container.markerTooltip(at: point), "Add visual for selection")
        XCTAssertNil(container.markerTooltip(at: NSPoint(x: -50, y: -50)))
    }

    // MARK: - Helpers

    private func makeRepresentable(
        sceneID: UUID,
        text: Binding<String>,
        onTextCommitted: @escaping (String, String) -> Void = { _, _ in },
        autocomplete: @escaping @MainActor (AutocompleteContext) async -> AutocompleteResult = { _ in .none }
    ) -> LinkedScriptTextView {
        LinkedScriptTextView(
            text: text,
            sceneID: sceneID,
            editorIdentity: UUID(),
            sceneTitle: "Scene",
            autocompleteProvider: .openAICompatible,
            autocompleteConfigurationVersion: 0,
            autocompleteConfigurationEligibility: .eligible,
            autocompleteDelay: .zero,
            autocompleteFallbackLanguage: .english,
            autocompleteState: .constant(.idle),
            loadRestorationState: { nil },
            saveRestorationState: { _ in },
            markers: [],
            fontSize: 16,
            spellcheck: false,
            smartQuotes: false,
            placeholder: "Placeholder",
            textColor: .labelColor,
            placeholderColor: .secondaryLabelColor,
            backgroundColor: .textBackgroundColor,
            bRollColor: .systemBlue,
            editingColor: .systemGreen,
            addBRollLabel: "Add Visual",
            addEditingLabel: "Editing",
            onTextCommitted: onTextCommitted,
            autocomplete: autocomplete,
            onTeardown: {},
            markerAction: { _, _ in },
            addMarkerAction: { _, _ in }
        )
    }
}
