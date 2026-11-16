import AppKit
import FrameScriptCore
import XCTest
@testable import FrameScript

/// Behavioural coverage for the script action bar and the inspector shell.
///
/// Everything here is headless: the text view lives in an offscreen borderless
/// window that is never ordered front, and every preference goes through the
/// isolated `TestDefaults` suite.
@MainActor
final class UXActionBarTests: FrameScriptTestCase {
    // MARK: - Insertion planner

    func testPausePlanAddsAWordBreakWithoutDoublingWhitespace() {
        let text = "Hola mundo" as NSString
        let plan = UXMarkupInsertion.shortPause.plan(
            in: text,
            replacing: NSRange(location: 4, length: 0)
        )

        XCTAssertEqual(plan.replacementText, " /")
        XCTAssertEqual(plan.selectedRange, NSRange(location: 6, length: 0))

        let atEnd = UXMarkupInsertion.longPause.plan(
            in: text,
            replacing: NSRange(location: text.length, length: 0)
        )
        XCTAssertEqual(atEnd.replacementText, " //")
        XCTAssertEqual(atEnd.selectedRange, NSRange(location: text.length + 3, length: 0))
    }

    func testInsertionAtTheStartOfAnEmptyScriptDoesNotAddLeadingSpace() {
        let plan = UXMarkupInsertion.shortPause.plan(
            in: "" as NSString,
            replacing: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(plan.replacementText, "/")
        XCTAssertEqual(plan.selectedRange, NSRange(location: 1, length: 0))
    }

    func testImageCueLeavesTheCaretInsideTheBrackets() {
        let plan = UXMarkupInsertion.imageCue.plan(
            in: "Hola" as NSString,
            replacing: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(plan.replacementText, " [IMAGEN: ]")
        XCTAssertEqual(plan.selectedRange, NSRange(location: 4 + 1 + 9, length: 0))
        XCTAssertEqual(
            (" [IMAGEN: ]" as NSString).substring(with: NSRange(location: 1 + 9, length: 1)),
            "]"
        )
    }

    func testInsertionReplacesTheCurrentSelection() {
        let text = "uno dos tres" as NSString
        let plan = UXMarkupInsertion.bRollCue.plan(
            in: text,
            replacing: NSRange(location: 4, length: 3)
        )
        XCTAssertEqual(plan.replacementRange, NSRange(location: 4, length: 3))
        XCTAssertEqual(plan.replacementText, "[B-ROLL]")
    }

    // MARK: - Text view path

    func testInsertionUsesTheTypingPathAndUndoesInOneStep() {
        let harness = makeTextView(text: "Hola mundo", caret: 4)
        defer { harness.close() }

        let plan = UXMarkupInsertionEngine.insert(.shortPause, into: harness.textView)

        XCTAssertEqual(harness.textView.string, "Hola / mundo")
        XCTAssertEqual(harness.textView.selectedRange(), NSRange(location: 6, length: 0))
        XCTAssertEqual(plan?.replacementText, " /")
        XCTAssertEqual(harness.changeRecorder.calls, 1, "the delegate must run as if the user typed")

        let undoManager = harness.textView.undoManager
        XCTAssertEqual(undoManager?.canUndo, true)
        undoManager?.undo()
        XCTAssertEqual(harness.textView.string, "Hola mundo")
        XCTAssertEqual(undoManager?.canUndo, false, "one undo step must revert the whole insertion")
    }

    func testInsertionKeepsAnotherFirstResponder() {
        let harness = makeTextView(text: "Hola mundo", caret: 4)
        defer { harness.close() }
        let probe = FocusProbe(frame: NSRect(x: 0, y: 240, width: 120, height: 24))
        harness.container.addSubview(probe)
        XCTAssertTrue(harness.window.makeFirstResponder(probe))

        UXMarkupInsertionEngine.insert(.longPause, into: harness.textView)

        XCTAssertTrue(
            harness.window.firstResponder === probe,
            "inserting from a toolbar button must not steal focus"
        )
        XCTAssertEqual(harness.textView.string, "Hola // mundo")
    }

    func testEveryInsertedTokenIsRecognisedByTheMarkupParser() {
        for insertion in UXMarkupInsertion.allCases {
            let harness = makeTextView(text: "Hola mundo", caret: 4)
            defer { harness.close() }
            UXMarkupInsertionEngine.insert(insertion, into: harness.textView)

            let tokens = ScriptMarkup.parse(harness.textView.string)
            switch insertion {
            case .shortPause:
                XCTAssertTrue(
                    tokens.contains { if case .pause(0.5, false) = $0.kind { true } else { false } },
                    "short pause not parsed: \(harness.textView.string)"
                )
            case .longPause:
                XCTAssertTrue(
                    tokens.contains { if case .pause(1.0, false) = $0.kind { true } else { false } },
                    "long pause not parsed: \(harness.textView.string)"
                )
            case .bRollCue:
                XCTAssertTrue(
                    tokens.contains { if case .cue("B-ROLL", "") = $0.kind { true } else { false } },
                    "B-roll cue not parsed: \(harness.textView.string)"
                )
            case .imageCue:
                XCTAssertTrue(
                    tokens.contains { if case .cue("IMAGEN", "") = $0.kind { true } else { false } },
                    "image cue not parsed: \(harness.textView.string)"
                )
            }
        }
    }

    // MARK: - Enablement

    func testDisabledAIExplainsWhyOnlyWhenAIShouldBeAvailable() {
        let welcome = UXActionBarModel(
            availability: CommandAvailability(),
            isAIProviderConfigured: false
        )
        XCTAssertNil(welcome.disabledReasonKey(for: .generateHook))

        let sceneWithoutProvider = UXActionBarModel(
            availability: CommandAvailability(
                hasOpenProject: true,
                hasScenes: true,
                hasSelectedScene: true
            ),
            isAIProviderConfigured: false
        )
        XCTAssertEqual(
            sceneWithoutProvider.disabledReasonKey(for: .generateHook),
            "ux.action.aiUnavailable"
        )
        XCTAssertTrue(sceneWithoutProvider.isEnabled(.insertShortPause))
        XCTAssertFalse(sceneWithoutProvider.isEnabled(.generateHook))
    }

    // MARK: - Tooltips

    func testTooltipReflectsShortcutOverridesAndOmitsUnassignedCommands() {
        var settings = AppSettings.defaults
        XCTAssertEqual(
            UXActionTooltip.text(title: "Gancho", command: .generateHook, settings: settings),
            "Gancho (⇧⌘G)"
        )

        settings.shortcutOverrides[.generateHook] = .assigned(
            ShortcutBinding("g", modifiers: [.command, .option])
        )
        XCTAssertEqual(
            UXActionTooltip.text(title: "Gancho", command: .generateHook, settings: settings),
            "Gancho (⌥⌘G)"
        )

        settings.shortcutOverrides[.suggestRehooks] = .unassigned
        XCTAssertEqual(
            UXActionTooltip.text(title: "Re-ganchos", command: .suggestRehooks, settings: settings),
            "Re-ganchos"
        )
    }

    func testEveryBarActionHasALabelAndHelpWithItsShortcut() {
        var settings = AppSettings.defaults
        settings.shortcutOverrides[.suggestRehooks] = .unassigned

        for action in UXEditorAction.allCases {
            for language in [AppLanguage.english, .spanish, .russian] {
                let title = L10n.tr(action.titleKey, language: language)
                XCTAssertFalse(title.isEmpty, "\(action) has an empty title")
                XCTAssertNotEqual(title, action.titleKey, "\(action) is untranslated in \(language)")
            }

            let title = L10n.tr(action.titleKey, language: .spanish)
            let help = UXActionTooltip.text(
                title: title,
                command: action.shortcutCommand,
                settings: settings
            )
            XCTAssertTrue(help.hasPrefix(title), "\(action) help lost its label: \(help)")

            if let command = action.shortcutCommand,
               let binding = settings.activeShortcut(for: command) {
                XCTAssertTrue(
                    help.contains(binding.display),
                    "\(action) help omits \(binding.display): \(help)"
                )
            } else {
                XCTAssertEqual(help, title, "\(action) should omit an unassigned shortcut")
            }
        }
    }

    func testInsertionButtonsHaveNoShortcutTheyCouldPretendToOwn() {
        for action in UXEditorAction.allCases where action.group == .insert {
            XCTAssertNil(action.shortcutCommand)
            XCTAssertNotNil(action.insertion)
        }
    }

    // MARK: - Narrow column

    func testOnlyRecordTakeUsesTheFilledPrimaryStyle() {
        for action in UXEditorAction.allCases {
            XCTAssertEqual(
                UXActionEmphasisPolicy.emphasis(for: action),
                action == .recordTake ? .filled : .standard,
                "\(action) must not look toggled on"
            )
        }
    }

    func testSceneTargetAffordanceIsNotShownTwice() {
        XCTAssertTrue(SceneTargetIndicatorPolicy.showsLegacyGlyph(hasTarget: false))
        XCTAssertFalse(SceneTargetIndicatorPolicy.showsLegacyGlyph(hasTarget: true))
    }

    // MARK: - Inspector

    func testInspectorTabPersistenceUsesIsolatedDefaults() {
        let defaults = makeDefaults()
        let key = "ux.inspector.selectedTab.test"

        let state = UXInspectorState(defaults: defaults, key: key)
        XCTAssertEqual(state.selectedTab, .ai, "a fresh window starts on the AI tab")

        state.select(.scene)
        XCTAssertEqual(defaults.string(forKey: key), "scene")

        let restored = UXInspectorState(defaults: defaults, key: key)
        XCTAssertEqual(restored.selectedTab, .scene)

        defaults.set("not-a-tab", forKey: key)
        XCTAssertEqual(UXInspectorState(defaults: defaults, key: key).selectedTab, .ai)
    }

    func testInspectorRegistryRegistersEveryTabAndNoPlaceholders() {
        XCTAssertEqual(
            UXInspectorRegistry.definitions.map(\.tab),
            UXInspectorTab.allCases,
            "the registry must list every tab in display order"
        )
        for definition in UXInspectorRegistry.definitions {
            XCTAssertFalse(definition.systemImage.isEmpty)
            XCTAssertNotEqual(
                L10n.tr(definition.titleKey, language: .english),
                definition.titleKey,
                "\(definition.tab) has no English title"
            )
            XCTAssertNotEqual(
                L10n.tr(definition.titleKey, language: .spanish),
                definition.titleKey,
                "\(definition.tab) has no Spanish title"
            )
        }
    }

    func testInspectorStillHidesBelowTheMinimumWindowWidth() {
        let minimum = AppShellView.aiPanelMinimumWindowWidth
        XCTAssertEqual(minimum, 1080)
        XCTAssertTrue(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: minimum))
        XCTAssertTrue(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: 1440))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: minimum - 1))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: 980))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: false, windowWidth: 1440))
    }

    // MARK: - Harness

    private final class ChangeRecorder: NSObject, NSTextViewDelegate {
        var calls = 0

        func textDidChange(_ notification: Notification) {
            calls += 1
        }
    }

    private final class FocusProbe: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct TextViewHarness {
        let textView: NSTextView
        let container: NSView
        let window: NSWindow
        let changeRecorder: ChangeRecorder

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private func makeTextView(text: String, caret: Int) -> TextViewHarness {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = text
        let recorder = ChangeRecorder()
        textView.delegate = recorder

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        container.addSubview(textView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = container
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return TextViewHarness(
            textView: textView,
            container: container,
            window: window,
            changeRecorder: recorder
        )
    }
}
