import AppKit
import XCTest
@testable import FrameScript

final class ShortcutRegistryTests: XCTestCase {
    func testOldSettingsWithoutShortcutPreferencesUseFactoryDefaults() throws {
        let encoded = try JSONEncoder().encode(AppSettings.defaults)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "shortcutOverrides")
        let legacy = try JSONSerialization.data(withJSONObject: root)

        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertTrue(settings.shortcutOverrides.isEmpty)
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), ShortcutRegistry.definition(for: .commandPalette).factoryDefault)
    }

    func testBindingsRoundTripForCharactersPunctuationArrowsAndDelete() throws {
        let bindings = [
            ShortcutBinding("k", modifiers: [.command]),
            ShortcutBinding("/", modifiers: [.control, .option, .shift, .command]),
            ShortcutBinding(key: .upArrow, modifiers: [.command, .option]),
            ShortcutBinding(key: .delete, modifiers: [.command]),
            ShortcutBinding(key: .forwardDelete, modifiers: [.control])
        ]
        XCTAssertEqual(try JSONDecoder().decode([ShortcutBinding].self, from: JSONEncoder().encode(bindings)), bindings)
    }

    func testPhysicalLetterCaptureIgnoresEnglishAndRussianProducedCharacters() throws {
        let englishO = try keyEvent(keyCode: 31, characters: "o", modifiers: .command)
        let russianO = try keyEvent(keyCode: 31, characters: "щ", modifiers: .command)
        let englishC = try keyEvent(keyCode: 8, characters: "c", modifiers: .command)
        let russianC = try keyEvent(keyCode: 8, characters: "с", modifiers: .command)

        XCTAssertEqual(ShortcutCaptureParser.binding(from: englishO), .init("o", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: russianO), .init("o", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: englishC), .init("c", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: russianC), .init("c", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: englishO), ShortcutCaptureParser.binding(from: russianO))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: englishC), ShortcutCaptureParser.binding(from: russianC))
    }

    func testPhysicalPunctuationArrowsAndDeleteRemainStableAcrossLayouts() throws {
        let englishComma = try keyEvent(keyCode: 43, characters: ",", modifiers: .command)
        let russianComma = try keyEvent(keyCode: 43, characters: "б", modifiers: .command)

        XCTAssertEqual(ShortcutCaptureParser.binding(from: englishComma), .init(",", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: russianComma), .init(",", modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: try keyEvent(keyCode: 123, characters: "", modifiers: .command)), .init(key: .leftArrow, modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: try keyEvent(keyCode: 51, characters: "", modifiers: .command)), .init(key: .delete, modifiers: [.command]))
        XCTAssertEqual(ShortcutCaptureParser.binding(from: try keyEvent(keyCode: 117, characters: "", modifiers: .command)), .init(key: .forwardDelete, modifiers: [.command]))
        XCTAssertNil(ShortcutCaptureParser.binding(from: try keyEvent(keyCode: 36, characters: "\r", modifiers: .command)))
    }

    func testCanonicalBindingsDisplayAndEncodeWithLatinANSICharacters() throws {
        let binding = ShortcutBinding("щ", modifiers: [.command])
        let encoded = String(data: try JSONEncoder().encode(binding), encoding: .utf8)

        XCTAssertEqual(binding, .init("o", modifiers: [.command]))
        XCTAssertEqual(binding.display, "⌘O")
        XCTAssertFalse(encoded?.unicodeScalars.contains(where: { $0.value >= 0x0400 && $0.value <= 0x052F }) == true)
    }

    func testLegacyRussianBindingsMigrateWithoutDuplicateActiveShortcuts() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        root["shortcutOverrides"] = [
            ShortcutCommand.commandPalette.rawValue,
            [
                "key": ShortcutKey.character.rawValue,
                "character": "щ",
                "modifiers": [ShortcutModifier.command.rawValue]
            ],
            ShortcutCommand.toggleFocusMode.rawValue,
            [
                "key": ShortcutKey.character.rawValue,
                "character": "ґ",
                "modifiers": [ShortcutModifier.command.rawValue]
            ]
        ]

        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), .init("o", modifiers: [.command]))
        XCTAssertNil(settings.activeShortcut(for: .openProject))
        XCTAssertEqual(settings.shortcutOverrides[.openProject], .unassigned)
        XCTAssertNil(settings.activeShortcut(for: .toggleFocusMode))
        XCTAssertEqual(settings.shortcutOverrides[.toggleFocusMode], .unassigned)
        XCTAssertFalse(ShortcutCommand.allCases.compactMap(settings.activeShortcut(for:)).contains { $0.character?.unicodeScalars.contains(where: { $0.value >= 0x0400 && $0.value <= 0x052F }) == true })
    }

    func testConflictAndReservedValidationUseTheCanonicalPhysicalBinding() throws {
        let englishO = try XCTUnwrap(ShortcutCaptureParser.binding(from: keyEvent(keyCode: 31, characters: "o", modifiers: .command)))
        let russianO = try XCTUnwrap(ShortcutCaptureParser.binding(from: keyEvent(keyCode: 31, characters: "щ", modifiers: .command)))
        let englishC = try XCTUnwrap(ShortcutCaptureParser.binding(from: keyEvent(keyCode: 8, characters: "c", modifiers: .command)))
        let russianC = try XCTUnwrap(ShortcutCaptureParser.binding(from: keyEvent(keyCode: 8, characters: "с", modifiers: .command)))
        let russianW = try XCTUnwrap(ShortcutCaptureParser.binding(from: keyEvent(keyCode: 13, characters: "ц", modifiers: .command)))
        var settings = AppSettings.defaults

        XCTAssertEqual(englishO, russianO)
        XCTAssertEqual(settings.setShortcut(englishO, for: .duplicateScene), .openProject)
        XCTAssertEqual(settings.setShortcut(russianO, for: .duplicateScene), .openProject)
        XCTAssertEqual(englishC, russianC)
        XCTAssertEqual(settings.setShortcut(englishC, for: .duplicateScene), .duplicateScene)
        XCTAssertEqual(settings.setShortcut(russianC, for: .duplicateScene), .duplicateScene)
        XCTAssertEqual(russianW, .init("w", modifiers: [.command]))
        XCTAssertEqual(ShortcutRecordingCoordinator.result(for: russianW), .reserved)
    }

    func testPhysicalOpenProjectCommandDispatchesThroughAppKitAcrossInputLayouts() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Project", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: "o")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent(keyCode: 31, characters: "o", modifiers: .command)))
        XCTAssertEqual(target.executions, 1)
        // Native key-equivalent matching follows the produced character, so the
        // Russian event proves the fallback router is required.
        XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent(keyCode: 31, characters: "щ", modifiers: .command)))
        XCTAssertEqual(target.executions, 1)
        XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 31, characters: "щ", modifiers: .command),
            settings: .defaults,
            menu: menu
        ))
        XCTAssertEqual(target.executions, 2)
        XCTAssertFalse(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 32, characters: "u", modifiers: .command),
            settings: .defaults,
            menu: menu
        ))
        XCTAssertEqual(target.executions, 2)
    }

    func testPhysicalCommandOpenIgnoresCapsLockAcrossRussianAndEnglishLayouts() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Project", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: "o")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        for (characters, expectedExecutions) in [("щ", 1), ("o", 2)] {
            XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
                try keyEvent(keyCode: 31, characters: characters, modifiers: [.command, .capsLock]),
                settings: .defaults,
                menu: menu
            ))
            XCTAssertEqual(target.executions, expectedExecutions)
        }
    }

    func testPhysicalPunctuationCommandDispatchesThroughAppKitAcrossInputLayouts() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Settings", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        for characters in [",", "б"] {
            XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
                try keyEvent(keyCode: 43, characters: characters, modifiers: .command),
                settings: .defaults,
                menu: menu
            ))
        }
        XCTAssertEqual(target.executions, 2)
    }

    func testPhysicalCommandCommaIgnoresCapsLockOnRussianLayout() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Settings", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)

        XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 43, characters: "б", modifiers: [.command, .capsLock]),
            settings: .defaults,
            menu: menu
        ))
        XCTAssertEqual(target.executions, 1)
    }

    func testPhysicalCommandOptionUpIgnoresFunctionAndNumericPadFlags() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Move Scene Up",
            action: #selector(TestMenuCommandTarget.performCommand(_:)),
            keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        )
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = target
        menu.addItem(item)

        XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 126, characters: "", modifiers: [.command, .option, .function, .numericPad]),
            settings: .defaults,
            menu: menu
        ))
        XCTAssertEqual(target.executions, 1)
    }

    func testPhysicalCommandDispatcherUsesCurrentReassignedBindingAndLeavesUnassignedCommandsInactive() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Project", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: "p")
        item.keyEquivalentModifierMask = .command
        item.target = target
        menu.addItem(item)
        var settings = AppSettings.defaults

        XCTAssertNil(settings.reassignShortcut(.init("p", modifiers: [.command]), for: .openProject))
        XCTAssertFalse(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 31, characters: "o", modifiers: .command), settings: settings, menu: menu
        ))
        XCTAssertTrue(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 35, characters: "p", modifiers: .command), settings: settings, menu: menu
        ))
        XCTAssertEqual(target.executions, 1)

        settings.shortcutOverrides[.openProject] = .unassigned
        XCTAssertFalse(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 35, characters: "p", modifiers: .command), settings: settings, menu: menu
        ))
        XCTAssertEqual(target.executions, 1)
    }

    func testPhysicalCommandDispatcherPreservesDisabledMenuCommands() throws {
        let target = TestMenuCommandTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open Project", action: #selector(TestMenuCommandTarget.performCommand(_:)), keyEquivalent: "o")
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.isEnabled = false
        menu.addItem(item)

        XCTAssertFalse(PhysicalShortcutMenuDispatcher.dispatch(
            try keyEvent(keyCode: 31, characters: "щ", modifiers: .command), settings: .defaults, menu: menu
        ))
        XCTAssertEqual(target.executions, 0)
    }

    func testFactoryDefaultsAreUniqueAndModifierOrderIsMacStandard() {
        let defaults = ShortcutRegistry.definitions.map(\.factoryDefault)
        XCTAssertEqual(Set(defaults).count, defaults.count)
        XCTAssertEqual(ShortcutBinding("k", modifiers: [.command, .option, .shift, .control]).display, "⌃⌥⇧⌘K")
    }

    func testConflictWarningIdentifiesTheExistingCommandAndCancelPreservesAssignments() {
        var settings = AppSettings.defaults
        let original = settings.activeShortcut(for: .duplicateScene)
        let conflict = settings.setShortcut(try! XCTUnwrap(settings.activeShortcut(for: .save)), for: .duplicateScene)
        XCTAssertEqual(conflict, .save)
        XCTAssertEqual(settings.activeShortcut(for: .duplicateScene), original)
        XCTAssertEqual(settings.activeShortcut(for: .save), ShortcutRegistry.definition(for: .save).factoryDefault)
    }

    func testReassignMovesShortcutAndExplicitlyUnassignsDisplacedCommand() {
        var settings = AppSettings.defaults
        let saveBinding = try! XCTUnwrap(settings.activeShortcut(for: .save))

        XCTAssertEqual(settings.reassignShortcut(saveBinding, for: .duplicateScene), .save)
        XCTAssertEqual(settings.activeShortcut(for: .duplicateScene), saveBinding)
        XCTAssertNil(settings.activeShortcut(for: .save))
        XCTAssertEqual(settings.shortcutOverrides[.save], .unassigned)
        XCTAssertEqual(
            ShortcutDisplayFormatter.display(for: .save, settings: settings, notAssigned: "Not assigned"),
            "Not assigned"
        )
    }

    func testAssignedAndUnassignedShortcutsRoundTripThroughCodable() throws {
        var settings = AppSettings.defaults
        _ = settings.setShortcut(.init("p", modifiers: [.command, .option]), for: .commandPalette)
        _ = settings.reassignShortcut(try! XCTUnwrap(settings.activeShortcut(for: .save)), for: .duplicateScene)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.shortcutOverrides, settings.shortcutOverrides)
        XCTAssertEqual(decoded.activeShortcut(for: .commandPalette), .init("p", modifiers: [.command, .option]))
        XCTAssertNil(decoded.activeShortcut(for: .save))
    }

    func testOldShortcutOverridesDecodeWithoutDataLoss() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings.defaults)) as? [String: Any])
        let oldBinding = ShortcutBinding("p", modifiers: [.command, .option])
        let legacyOverrides: [ShortcutCommand: ShortcutBinding] = [.commandPalette: oldBinding]
        root["shortcutOverrides"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyOverrides))

        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), oldBinding)
    }

    func testPerCommandAndGlobalResets() {
        var settings = AppSettings.defaults
        XCTAssertNil(settings.setShortcut(ShortcutBinding("z", modifiers: [.command, .option]), for: .duplicateScene))
        XCTAssertNil(settings.resetShortcut(.duplicateScene))
        XCTAssertEqual(settings.activeShortcut(for: .duplicateScene), ShortcutRegistry.definition(for: .duplicateScene).factoryDefault)
        XCTAssertNil(settings.setShortcut(ShortcutBinding("z", modifiers: [.command, .option]), for: .duplicateScene))
        XCTAssertNil(settings.setShortcut(ShortcutBinding("g", modifiers: [.command, .option]), for: .toggleFocusMode))
        settings.resetAllShortcuts()
        XCTAssertTrue(settings.shortcutOverrides.isEmpty)
    }

    func testPerCommandResetIsConflictSafe() {
        var settings = AppSettings.defaults
        let defaultBinding = try! XCTUnwrap(settings.activeShortcut(for: .duplicateScene))
        _ = settings.reassignShortcut(defaultBinding, for: .save)

        XCTAssertEqual(settings.resetConflict(for: .duplicateScene), .save)
        XCTAssertEqual(settings.resetShortcut(.duplicateScene), .save)
        XCTAssertNil(settings.activeShortcut(for: .duplicateScene))
        XCTAssertEqual(settings.activeShortcut(for: .save), defaultBinding)

        XCTAssertEqual(settings.reassignFactoryDefault(to: .duplicateScene), .save)
        XCTAssertEqual(settings.activeShortcut(for: .duplicateScene), defaultBinding)
        XCTAssertNil(settings.activeShortcut(for: .save))
    }

    func testResetAllRestoresUniqueFactoryDefaults() {
        var settings = AppSettings.defaults
        _ = settings.reassignShortcut(try! XCTUnwrap(settings.activeShortcut(for: .save)), for: .duplicateScene)
        _ = settings.setShortcut(.init("p", modifiers: [.command, .option]), for: .commandPalette)

        settings.resetAllShortcuts()
        let activeBindings = ShortcutCommand.allCases.compactMap(settings.activeShortcut(for:))
        XCTAssertEqual(activeBindings.count, ShortcutCommand.allCases.count)
        XCTAssertEqual(Set(activeBindings).count, activeBindings.count)
        XCTAssertTrue(settings.shortcutOverrides.isEmpty)
    }

    func testEveryRegistryCommandHasEnglishAndRussianLocalization() {
        for definition in ShortcutRegistry.definitions {
            XCTAssertNotEqual(L10n.tr(definition.localizationKey, language: .english), definition.localizationKey)
            XCTAssertNotEqual(L10n.tr(definition.localizationKey, language: .russian), definition.localizationKey)
        }
    }

    func testEveryShortcutCommandHasExactlyOneRegisteredDefinition() {
        let registeredCommands = ShortcutRegistry.definitions.map(\.command)

        XCTAssertEqual(registeredCommands.count, ShortcutCommand.allCases.count)
        XCTAssertEqual(Set(registeredCommands), Set(ShortcutCommand.allCases))
        for command in ShortcutCommand.allCases {
            let definition = ShortcutRegistry.definition(for: command)
            XCTAssertEqual(definition.command, command)
            XCTAssertNotEqual(definition.order, Int.max, "Fallback definition used for \(command.rawValue)")
        }
    }

    func testMissingDefinitionFallbackKeepsTheCommandUsableWithoutCrashing() {
        let fallback = ShortcutRegistry.fallbackDefinition(for: .save)

        XCTAssertEqual(fallback.command, .save)
        XCTAssertEqual(fallback.localizationKey, "command.save")
        XCTAssertEqual(fallback.category, .application)
        XCTAssertEqual(fallback.order, Int.max)
        XCTAssertTrue(fallback.factoryDefault.isValid)
        XCTAssertTrue(ShortcutRegistry.isAssignable(fallback.factoryDefault))
    }

    func testReassignmentActionsAndUnassignedStateAreLocalized() {
        XCTAssertEqual(L10n.tr("shortcuts.reassign", language: .english), "Reassign")
        XCTAssertEqual(L10n.tr("project.unsaved.cancel", language: .english), "Cancel")
        XCTAssertEqual(L10n.tr("shortcuts.reassign", language: .russian), "Переназначить")
        XCTAssertEqual(L10n.tr("project.unsaved.cancel", language: .russian), "Отмена")
        XCTAssertEqual(L10n.tr("shortcuts.notAssigned", language: .english), "Not assigned")
        XCTAssertEqual(L10n.tr("shortcuts.notAssigned", language: .russian), "Не назначено")
        XCTAssertNotEqual(L10n.tr("shortcuts.reserved.message", language: .english), "shortcuts.reserved.message")
        XCTAssertNotEqual(L10n.tr("shortcuts.reserved.message", language: .russian), "shortcuts.reserved.message")
    }

    func testConfiguredBindingUpdatesEverySharedShortcutHintAndCommandBinding() {
        var settings = AppSettings.defaults
        let replacement = ShortcutBinding("p", modifiers: [.command, .option])
        XCTAssertNil(settings.setShortcut(replacement, for: .commandPalette))
        let hint = ShortcutDisplayFormatter.display(for: .commandPalette, settings: settings, notAssigned: "Not assigned")

        XCTAssertEqual(hint, "⌥⌘P")
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), replacement)
        XCTAssertNotEqual(settings.activeShortcut(for: .commandPalette), ShortcutRegistry.definition(for: .commandPalette).factoryDefault)

        settings.shortcutOverrides[.commandPalette] = .unassigned
        XCTAssertEqual(ShortcutDisplayFormatter.display(for: .commandPalette, settings: settings, notAssigned: "Not assigned"), "Not assigned")
        XCTAssertNil(settings.activeShortcut(for: .commandPalette))
    }

    func testReassignedMacOSCommandUsesTheNewBindingWithoutRestartAndTheOldBindingStopsWorking() {
        var settings = AppSettings.defaults
        let oldBinding = try! XCTUnwrap(settings.activeShortcut(for: .commandPalette))
        let newBinding = ShortcutBinding("p", modifiers: [.command, .option])

        XCTAssertNil(settings.setShortcut(newBinding, for: .commandPalette))
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), newBinding)
        XCTAssertNotEqual(settings.activeShortcut(for: .commandPalette), oldBinding)
    }

    func testProjectTitleMenuHintsResolveCurrentSettingsAndHideExplicitUnassignments() {
        var settings = AppSettings.defaults
        let replacement = ShortcutBinding("w", modifiers: [.command, .option])

        XCTAssertEqual(ProjectTitleMenuShortcutHints.binding(for: .save, settings: settings), settings.activeShortcut(for: .save))
        XCTAssertNil(settings.setShortcut(replacement, for: .export))
        XCTAssertEqual(ProjectTitleMenuShortcutHints.binding(for: .export, settings: settings), replacement)

        settings.shortcutOverrides[.saveAs] = .unassigned
        XCTAssertNil(ProjectTitleMenuShortcutHints.binding(for: .saveAs, settings: settings))
        XCTAssertNil(ProjectTitleMenuShortcutHints.binding(for: .commandPalette, settings: settings))
    }

    func testProductionShortcutSurfacesUseTheActiveBindingFormatter() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = try [
            "FrameScript/App/FrameScriptApp.swift",
            "FrameScript/Components/ModeSwitcher.swift",
            "FrameScript/Components/TopToolbar.swift",
            "FrameScript/Components/SceneSidebar.swift",
            "FrameScript/Features/CommandPalette/CommandPaletteView.swift",
            "FrameScript/Features/Settings/ShortcutsOverlay.swift"
        ].map { path in
            try String(contentsOf: root.appendingPathComponent(path))
        }

        let menuCommands = sources[0]
        XCTAssertEqual(menuCommands.components(separatedBy: ".keyboardShortcut(").count - 1, 0)
        XCTAssertTrue(menuCommands.contains(".configuredKeyboardShortcut(appState.shortcutBinding"))
        XCTAssertTrue(sources[2].contains("ProjectTitleMenuShortcutHints.binding"))
        XCTAssertFalse(sources[2].contains(".keyboardShortcut("))
        for source in sources.dropFirst() {
            XCTAssertTrue(source.contains("shortcutDisplay(for:"))
            XCTAssertFalse(source.contains("settings.shortcut(for:"))
        }
    }

    func testOnlyOneProjectListExitActionRemainsInProductionSurfaces() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "FrameScript/App/FrameScriptApp.swift",
            "FrameScript/Components/TopToolbar.swift",
            "FrameScript/Features/CommandPalette/CommandPaletteView.swift"
        ]
        let sources = try paths.map { try String(contentsOf: root.appendingPathComponent($0)) }.joined(separator: "\n")

        XCTAssertEqual(sources.components(separatedBy: "returnToProjectList()").count - 1, 3)
        XCTAssertFalse(sources.contains("closeProject()"))
        XCTAssertFalse(sources.contains("project.close"))
        XCTAssertFalse(sources.contains("command.closeProject"))
    }

    func testShortcutSettingsLayoutUsesOneOrderedCardForEveryCategory() {
        let cards = ShortcutSettingsLayout.categoryCards

        XCTAssertEqual(cards.map(\.category), ShortcutCategory.allCases)
        for card in cards {
            XCTAssertEqual(
                card.definitions.map(\.command),
                ShortcutRegistry.definitions
                    .filter { $0.category == card.category }
                    .sorted { $0.order < $1.order }
                    .map(\.command)
            )
        }
    }

    func testOverlayCategoryAndCommandOrderingIsDeterministic() {
        let sections = ShortcutsOverlayLayout.categorySections

        XCTAssertEqual(sections.map(\.category), ShortcutCategory.allCases)
        for section in sections {
            XCTAssertEqual(
                section.definitions.map(\.command),
                ShortcutRegistry.definitions
                    .filter { $0.category == section.category }
                    .map(\.command)
            )
        }
    }

    func testOverlayUsesBoundedVerticallyScrollableContent() throws {
        XCTAssertGreaterThan(ShortcutsOverlayLayout.maximumContentHeight, 0)
        XCTAssertLessThanOrEqual(ShortcutsOverlayLayout.maximumContentHeight, 700)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("FrameScript/Features/Settings/ShortcutsOverlay.swift"))
        XCTAssertTrue(source.contains("ScrollView(.vertical)"))
        XCTAssertTrue(source.contains(".frame(maxHeight: ShortcutsOverlayLayout.maximumContentHeight)"))
        XCTAssertFalse(source.contains("ScrollView(.horizontal)"))
    }

    func testShortcutSettingsRowStateOnlyShowsResetForCustomizedCommands() {
        let definition = ShortcutRegistry.definition(for: .commandPalette)

        XCTAssertFalse(
            ShortcutSettingsLayout.rowState(for: definition, customizedCommands: [], recording: nil).showsReset
        )
        XCTAssertTrue(
            ShortcutSettingsLayout.rowState(for: definition, customizedCommands: [.commandPalette], recording: nil).showsReset
        )
    }

    func testResetActionsAreLockedWhileAnotherShortcutIsBeingCaptured() {
        let active = ShortcutRegistry.definition(for: .commandPalette)
        let other = ShortcutRegistry.definition(for: .save)
        let state = ShortcutSettingsLayout.rowState(
            for: other,
            customizedCommands: [.save],
            recording: active.command
        )

        XCTAssertFalse(state.showsEdit)
        XCTAssertFalse(state.showsReset)
        XCTAssertFalse(ShortcutSettingsLayout.canResetAll(customizedCommands: [.save], recording: active.command))
    }

    func testShortcutSettingsRecordingStateOnlyHighlightsTheActiveRow() {
        let active = ShortcutRegistry.definition(for: .commandPalette)
        let inactive = ShortcutRegistry.definition(for: .save)

        XCTAssertTrue(
            ShortcutSettingsLayout.rowState(for: active, customizedCommands: [], recording: active.command).isRecording
        )
        XCTAssertFalse(
            ShortcutSettingsLayout.rowState(for: inactive, customizedCommands: [], recording: active.command).isRecording
        )
    }

    func testCapturedCandidateIsDisplayedInsteadOfTheRecordingPrompt() throws {
        let monitor = TestShortcutEventMonitor()
        var pendingBinding: ShortcutBinding?
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { pendingBinding = $0 }, onCancel: {})
        session.start()

        XCTAssertNil(monitor.send(try keyEvent(keyCode: 45, characters: "n", modifiers: .command)))

        XCTAssertEqual(
            ShortcutCapturePresentation.label(pendingBinding: pendingBinding, pressShortcut: "Press shortcut…"),
            "⌘N"
        )
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(ShortcutCapturePresentation.showsRecordingField(pendingBinding: pendingBinding, isCaptureActive: session.isActive))
    }

    func testConflictDetectionOccursImmediatelyAfterCaptureAndStopsBeforeAlertPresentation() throws {
        let monitor = TestShortcutEventMonitor()
        let settings = AppSettings.defaults
        var conflict: ShortcutCommand?
        var captureWasStoppedBeforeAlert = false
        var session: ShortcutCaptureSession!
        session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { candidate in
            conflict = ShortcutRegistry.conflict(
                for: candidate,
                excluding: .duplicateScene,
                overrides: settings.shortcutOverrides
            )
            captureWasStoppedBeforeAlert = !session.isActive
        }, onCancel: {})
        session.start()

        let result = monitor.send(try keyEvent(keyCode: 1, characters: "s", modifiers: .command))

        XCTAssertNil(result)
        XCTAssertEqual(conflict, .save)
        XCTAssertTrue(captureWasStoppedBeforeAlert)
        XCTAssertEqual(monitor.removedCount, 1)
    }

    func testAlertKeyboardEventsAreNotConsumedAndDoNotChangeThePendingCandidate() throws {
        let monitor = TestShortcutEventMonitor()
        var pendingBinding: ShortcutBinding?
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { pendingBinding = $0 }, onCancel: {})
        session.start()

        XCTAssertNil(monitor.send(try keyEvent(keyCode: 1, characters: "s", modifiers: .command)))
        let returnEvent = try keyEvent(keyCode: 36, characters: "\r", modifiers: [])
        let escapeEvent = try keyEvent(keyCode: 53, characters: "", modifiers: [])

        XCTAssertTrue(monitor.send(returnEvent) === returnEvent)
        XCTAssertTrue(monitor.send(escapeEvent) === escapeEvent)
        XCTAssertEqual(pendingBinding, .init("s", modifiers: [.command]))
        XCTAssertFalse(session.isActive)
    }

    func testNoCommandCanExecuteDuringTheInitialEditToCaptureTransition() throws {
        let monitor = TestShortcutEventMonitor()
        var recorded: [ShortcutBinding] = []
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { recorded.append($0) }, onCancel: {})

        // This matches beginRecording: the monitor starts before the row becomes recording.
        session.start()
        let recordingRowIsVisible = true
        let result = monitor.send(try keyEvent(keyCode: 45, characters: "n", modifiers: .command))
        var newProjectRequests = 0
        if result != nil && recordingRowIsVisible { newProjectRequests += 1 }

        XCTAssertNil(result)
        XCTAssertEqual(newProjectRequests, 0)
        XCTAssertEqual(recorded, [.init("n", modifiers: [.command])])
    }

    func testEscapeCancelsRecordingAndRemovesCaptureSession() throws {
        let monitor = TestShortcutEventMonitor()
        var cancellations = 0
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: { cancellations += 1 })
        session.start()

        XCTAssertNil(monitor.send(try keyEvent(keyCode: 53, characters: "", modifiers: [])))
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(monitor.removedCount, 1)
    }

    func testModifierOnlyAndUnmodifiedCharactersAreInvalidButConsumed() throws {
        let monitor = TestShortcutEventMonitor()
        var recorded: [ShortcutBinding] = []
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { recorded.append($0) }, onCancel: {})
        session.start()

        XCTAssertNil(monitor.send(try keyEvent(keyCode: 0, characters: "a", modifiers: [])))
        XCTAssertNil(monitor.send(try keyEvent(keyCode: 55, characters: "", modifiers: .command)))
        XCTAssertTrue(recorded.isEmpty)
    }

    func testReservedMacOSAndTextEditingShortcutsAreRejectedAndNeverExecute() throws {
        let reserved = [
            ShortcutBinding("q", modifiers: [.command]),
            ShortcutBinding("w", modifiers: [.command]),
            ShortcutBinding("h", modifiers: [.command]),
            ShortcutBinding("m", modifiers: [.command]),
            ShortcutBinding("z", modifiers: [.command]),
            ShortcutBinding("z", modifiers: [.command, .shift]),
            ShortcutBinding("x", modifiers: [.command]),
            ShortcutBinding("c", modifiers: [.command]),
            ShortcutBinding("v", modifiers: [.command]),
            ShortcutBinding("a", modifiers: [.command])
        ]
        XCTAssertTrue(reserved.allSatisfy { ShortcutRecordingCoordinator.result(for: $0) == .reserved })

        var settings = AppSettings.defaults
        let oldBinding = try XCTUnwrap(settings.activeShortcut(for: .commandPalette))
        let monitor = TestShortcutEventMonitor()
        var nativeActionExecutions = 0
        var frameScriptActionExecutions = 0
        let session = ShortcutCaptureSession(eventMonitor: monitor, onRecord: { candidate in
            if ShortcutRecordingCoordinator.result(for: candidate) == .accepted {
                frameScriptActionExecutions += 1
                _ = settings.setShortcut(candidate, for: .commandPalette)
            }
        }, onCancel: {})
        session.start()

        let result = monitor.send(try keyEvent(keyCode: 12, characters: "q", modifiers: .command))
        if result != nil { nativeActionExecutions += 1 }

        XCTAssertNil(result)
        XCTAssertEqual(nativeActionExecutions, 0)
        XCTAssertEqual(frameScriptActionExecutions, 0)
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), oldBinding)
        XCTAssertEqual(settings.setShortcut(.init("q", modifiers: [.command]), for: .commandPalette), .commandPalette)
        XCTAssertEqual(settings.activeShortcut(for: .commandPalette), oldBinding)
    }

    func testSuccessfulSaveReleasesItsCaptureSessionThroughTheLifecycle() {
        assertLifecycleReleasesCapture { $0.save() }
    }

    func testCancelReleasesItsCaptureSessionThroughTheLifecycle() {
        assertLifecycleReleasesCapture { $0.cancel() }
    }

    func testViewDisappearanceReleasesItsCaptureSessionThroughTheLifecycle() {
        assertLifecycleReleasesCapture { $0.viewDidDisappear() }
    }

    @MainActor
    func testClosingAnUnrelatedWindowDoesNotStopSettingsRecording() {
        let monitor = TestShortcutEventMonitor()
        let lifecycle = ShortcutRecordingLifecycle()
        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        let observer = SettingsWindowCloseObserver()
        let settingsWindow = NSWindow()
        let unrelatedWindow = NSWindow()
        observer.onClose = { lifecycle.settingsWindowDidClose() }
        observer.observe(window: settingsWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: unrelatedWindow)

        XCTAssertTrue(lifecycle.isCaptureActive)
        XCTAssertEqual(monitor.removedCount, 0)
    }

    @MainActor
    func testClosingTheOwningSettingsWindowStopsAndClearsRecording() {
        let monitor = TestShortcutEventMonitor()
        let lifecycle = ShortcutRecordingLifecycle()
        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        let observer = SettingsWindowCloseObserver()
        let settingsWindow = NSWindow()
        var recording: ShortcutCommand? = .openProject
        observer.onClose = {
            lifecycle.settingsWindowDidClose()
            recording = nil
        }
        observer.observe(window: settingsWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: settingsWindow)

        XCTAssertFalse(lifecycle.isCaptureActive)
        XCTAssertNil(recording)
        XCTAssertEqual(monitor.removedCount, 1)
    }

    func testDismissingReservedWarningResumesCaptureWithExactlyOneMonitor() {
        let monitor = TestShortcutEventMonitor()
        let lifecycle = ShortcutRecordingLifecycle()
        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        lifecycle.stopForAlert()

        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))

        XCTAssertTrue(lifecycle.isCaptureActive)
        XCTAssertEqual(monitor.installedCount, 2)
        XCTAssertEqual(monitor.removedCount, 1)
    }

    @MainActor
    func testClosingAnAlertDoesNotTriggerSettingsWindowCleanup() {
        let monitor = TestShortcutEventMonitor()
        let lifecycle = ShortcutRecordingLifecycle()
        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        let observer = SettingsWindowCloseObserver()
        let settingsWindow = NSWindow()
        let alertWindow = NSWindow()
        observer.onClose = { lifecycle.settingsWindowDidClose() }
        observer.observe(window: settingsWindow)

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: alertWindow)

        XCTAssertTrue(lifecycle.isCaptureActive)
        XCTAssertEqual(monitor.removedCount, 0)
    }

    func testLifecycleDeinitializationReleasesItsCaptureSession() {
        let monitor = TestShortcutEventMonitor()
        weak var deallocatedLifecycle: ShortcutRecordingLifecycle?
        var lifecycle: ShortcutRecordingLifecycle? = ShortcutRecordingLifecycle()
        deallocatedLifecycle = lifecycle
        lifecycle?.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        lifecycle = nil

        XCTAssertNil(deallocatedLifecycle)
        XCTAssertEqual(monitor.removedCount, 1)
    }

    func testOnlyOneRecorderCanBeActive() {
        let firstMonitor = TestShortcutEventMonitor()
        let secondMonitor = TestShortcutEventMonitor()
        let first = ShortcutCaptureSession(eventMonitor: firstMonitor, onRecord: { _ in }, onCancel: {})
        let second = ShortcutCaptureSession(eventMonitor: secondMonitor, onRecord: { _ in }, onCancel: {})

        first.start()
        second.start()

        XCTAssertFalse(first.isActive)
        XCTAssertEqual(firstMonitor.removedCount, 1)
        XCTAssertTrue(second.isActive)
        second.stop()
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

    private func assertLifecycleReleasesCapture(_ end: (ShortcutRecordingLifecycle) -> Void) {
        let monitor = TestShortcutEventMonitor()
        let lifecycle = ShortcutRecordingLifecycle()
        lifecycle.start(ShortcutCaptureSession(eventMonitor: monitor, onRecord: { _ in }, onCancel: {}))
        end(lifecycle)

        XCTAssertFalse(lifecycle.isCaptureActive)
        XCTAssertEqual(monitor.removedCount, 1)
    }
}

private final class TestShortcutEventMonitor: ShortcutCaptureEventMonitoring {
    private var handler: ((NSEvent) -> NSEvent?)?
    private var token: NSObject?
    private(set) var installedCount = 0
    private(set) var removedCount = 0

    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any {
        installedCount += 1
        self.handler = handler
        let token = NSObject()
        self.token = token
        return token
    }

    func removeMonitor(_ monitor: Any) {
        removedCount += 1
        handler = nil
        token = nil
    }

    func send(_ event: NSEvent) -> NSEvent? {
        guard let handler else { return event }
        return handler(event)
    }
}

private final class TestMenuCommandTarget: NSObject {
    private(set) var executions = 0

    @objc func performCommand(_ sender: Any?) {
        executions += 1
    }
}
