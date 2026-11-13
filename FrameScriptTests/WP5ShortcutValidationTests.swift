import AppKit
import XCTest
@testable import FrameScript

/// WP5 item 2: the shortcut recorder must reject bindings that would hijack
/// plain typing or AppKit's own key handling.
final class WP5ShortcutValidationTests: XCTestCase {
    // MARK: - Validity rules

    func testShiftOnlyCharacterBindingsAreInvalid() {
        XCTAssertFalse(ShortcutBinding("s", modifiers: [.shift]).isValid)
        XCTAssertFalse(ShortcutBinding("/", modifiers: [.shift]).isValid)
        XCTAssertTrue(ShortcutBinding("s", modifiers: [.command, .shift]).isValid)
        XCTAssertTrue(ShortcutBinding("k", modifiers: [.option, .command]).isValid)
        XCTAssertTrue(ShortcutBinding("e", modifiers: [.control]).isValid)
    }

    func testNonCharacterKeysRequireCommand() {
        XCTAssertFalse(ShortcutBinding(key: .delete, modifiers: []).isValid)
        XCTAssertFalse(ShortcutBinding(key: .upArrow, modifiers: []).isValid)
        XCTAssertFalse(ShortcutBinding(key: .downArrow, modifiers: [.shift]).isValid)
        XCTAssertFalse(ShortcutBinding(key: .forwardDelete, modifiers: [.control]).isValid)
        XCTAssertTrue(ShortcutBinding(key: .delete, modifiers: [.command]).isValid)
        XCTAssertTrue(ShortcutBinding(key: .upArrow, modifiers: [.command, .control]).isValid)
    }

    /// The physical mapper still produces the raw key, but the recorder and the
    /// override decoder both refuse it.
    func testPhysicalBareDeleteIsMappedButRejected() throws {
        let binding = try XCTUnwrap(ShortcutPhysicalKeyMapper.binding(for: 51, modifiers: []))
        XCTAssertEqual(binding, ShortcutBinding(key: .delete, modifiers: []))
        XCTAssertFalse(binding.isValid)
        XCTAssertNil(ShortcutCaptureParser.binding(from: try keyEvent(keyCode: 51, characters: "", modifiers: [])))
        XCTAssertEqual(ShortcutRecordingCoordinator.result(for: binding), .invalid)
    }

    func testControlCaretAndKillKeysAreReserved() {
        let reserved = [
            ShortcutBinding("a", modifiers: [.control]),
            ShortcutBinding("e", modifiers: [.control]),
            ShortcutBinding("k", modifiers: [.control])
        ]
        for binding in reserved {
            XCTAssertTrue(ShortcutRegistry.nonAssignableBindings.contains(binding), binding.display)
            XCTAssertFalse(ShortcutRegistry.isAssignable(binding))
            XCTAssertEqual(ShortcutRecordingCoordinator.result(for: binding), .reserved)
        }
        // ⌘A was already reserved and keeps its meaning.
        XCTAssertTrue(ShortcutRegistry.nonAssignableBindings.contains(ShortcutBinding("a", modifiers: [.command])))
    }

    func testRejectionReasonsDistinguishTheMissingModifier() {
        XCTAssertEqual(ShortcutRegistry.rejection(for: ShortcutBinding("s", modifiers: [.shift])), .needsCommandControlOrOption)
        XCTAssertEqual(ShortcutRegistry.rejection(for: ShortcutBinding(key: .delete, modifiers: [])), .needsCommand)
        XCTAssertNil(ShortcutRegistry.rejection(for: ShortcutBinding("s", modifiers: [.command])))
        XCTAssertNil(ShortcutRegistry.rejection(for: ShortcutBinding(key: .delete, modifiers: [.command])))
    }

    // MARK: - Persistence

    func testAnOverrideThatBecameInvalidDecodesAsUnassigned() throws {
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any]
        )
        root["shortcutOverrides"] = [
            ShortcutCommand.commandPalette.rawValue: [
                "key": ShortcutKey.character.rawValue,
                "character": "s",
                "modifiers": [ShortcutModifier.shift.rawValue]
            ],
            ShortcutCommand.deleteScene.rawValue: [
                "key": ShortcutKey.character.rawValue,
                "character": "d",
                "modifiers": [ShortcutModifier.command.rawValue]
            ]
        ]

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: root)
        )

        XCTAssertNil(settings.activeShortcut(for: .commandPalette))
        XCTAssertEqual(settings.shortcutOverrides[.commandPalette], .unassigned)
        // A still-valid custom binding survives.
        XCTAssertEqual(settings.activeShortcut(for: .deleteScene), ShortcutBinding("d", modifiers: [.command]))
    }

    // MARK: - Recorder feedback

    func testRecorderReportsWhyACapturedCombinationIsRejected() throws {
        let monitor = WP5ShortcutEventMonitor()
        var recorded: [ShortcutBinding] = []
        var rejections: [(ShortcutRejection, ShortcutBinding)] = []
        let session = ShortcutCaptureSession(
            eventMonitor: monitor,
            onRecord: { recorded.append($0) },
            onReject: { rejections.append(($0, $1)) },
            onCancel: {}
        )
        session.start()

        // ⇧S: a capital S in any text field.
        XCTAssertNil(monitor.send(try keyEvent(keyCode: 1, characters: "S", modifiers: .shift)))
        // Bare Delete.
        XCTAssertNil(monitor.send(try keyEvent(keyCode: 51, characters: "", modifiers: [])))
        // ⌘⇧S is accepted and terminates the capture.
        XCTAssertNil(monitor.send(try keyEvent(keyCode: 1, characters: "s", modifiers: [.command, .shift])))

        XCTAssertEqual(rejections.map(\.0), [.needsCommandControlOrOption, .needsCommand])
        XCTAssertEqual(rejections.map(\.1.display), ["⇧S", "⌫"])
        XCTAssertEqual(recorded, [ShortcutBinding("s", modifiers: [.command, .shift])])
        XCTAssertFalse(session.isActive)
    }

    func testRejectionHintKeysAreLocalized() {
        XCTAssertEqual(ShortcutRejectionText.localizationKey(for: .needsCommandControlOrOption), "shortcuts.rejected.modifiers")
        XCTAssertEqual(ShortcutRejectionText.localizationKey(for: .needsCommand), "shortcuts.rejected.command")
        for key in ["shortcuts.rejected.modifiers", "shortcuts.rejected.command", "shortcuts.remove"] {
            for language in [AppLanguage.english, .russian, .spanish] {
                let text = L10n.tr(key, language: language)
                XCTAssertNotEqual(text, key, "\(key) is missing in \(language.rawValue)")
            }
        }
    }

    // MARK: - Unassignment

    func testRemovingAShortcutWritesAnExplicitUnassignment() throws {
        var settings = AppSettings.defaults
        XCTAssertNotNil(settings.activeShortcut(for: .commandPalette))
        settings.clearShortcut(.commandPalette)
        XCTAssertNil(settings.activeShortcut(for: .commandPalette))
        XCTAssertEqual(settings.shortcutOverrides[.commandPalette], .unassigned)
        // Reset restores the factory default.
        _ = settings.resetShortcut(.commandPalette)
        XCTAssertEqual(
            settings.activeShortcut(for: .commandPalette),
            ShortcutRegistry.definition(for: .commandPalette).factoryDefault
        )
    }

    private func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private final class WP5ShortcutEventMonitor: ShortcutCaptureEventMonitoring {
    private var handler: ((NSEvent) -> NSEvent?)?

    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any {
        self.handler = handler
        return NSObject()
    }

    func removeMonitor(_ monitor: Any) {
        handler = nil
    }

    func send(_ event: NSEvent) -> NSEvent? {
        guard let handler else { return event }
        return handler(event)
    }
}
