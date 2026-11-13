import AppKit
import XCTest
@testable import FrameScript

/// WP5 items 3–10: the window root type, the real application menu mirror,
/// the single error presenter and the shell accessibility seams.
final class WP5ApplicationShellTests: FrameScriptTestCase {
    // MARK: - Window identity (item 4)

    func testThemedSceneRootNameIsStableAcrossLaunches() {
        let name = String(reflecting: ThemedSceneRoot<AppRootView>.self)

        XCTAssertFalse(name.contains("unknown context"), name)
        XCTAssertTrue(name.contains("ThemedSceneRoot"), name)
        XCTAssertEqual(name, String(reflecting: ThemedSceneRoot<AppRootView>.self))
    }

    func testMainSceneUsesAStableWindowGroupIdentifier() throws {
        let source = try productionSource("FrameScript/App/FrameScriptApp.swift")

        XCTAssertTrue(source.contains("WindowGroup(id: \"main\")"))
        XCTAssertFalse(source.contains("private struct ThemedSceneRoot"))
        XCTAssertTrue(source.contains("LegacyWindowFrameKeys.purgeIfNeeded"))
    }

    // MARK: - Application menu (item 10)

    @MainActor
    func testMenuMirrorHasOneItemPerCommandWithTheActiveKeyEquivalent() {
        var settings = AppSettings.defaults
        let availability = CommandAvailability(hasOpenProject: true, hasScenes: true, hasSelectedScene: true)
        let menu = ApplicationMenuBuilder.makeMenu(
            .file,
            title: "File",
            settings: settings,
            availability: availability,
            localized: { L10n.tr($0, language: .english) }
        )

        let fileCommands = ApplicationMenuSpec.items(in: .file).map(\.command)
        XCTAssertEqual(menu.items.count, fileCommands.count)
        for (item, command) in zip(menu.items, fileCommands) {
            let binding = settings.activeShortcut(for: command)
            XCTAssertEqual(item.keyEquivalent, binding?.appKitKeyEquivalent, "\(command.rawValue)")
            XCTAssertEqual(item.keyEquivalentModifierMask, binding?.appKitModifierMask, "\(command.rawValue)")
            XCTAssertEqual(item.representedObject as? String, command.rawValue)
            XCTAssertNotEqual(item.title, command.definition.localizationKey, "missing localized title")
        }

        // A changed binding reaches the rebuilt menu, and the old one is gone.
        XCTAssertNil(settings.setShortcut(ShortcutBinding("p", modifiers: [.command, .option]), for: .save))
        let updated = ApplicationMenuBuilder.makeMenu(
            .file,
            title: "File",
            settings: settings,
            availability: availability,
            localized: { L10n.tr($0, language: .english) }
        )
        let saveItem = try? XCTUnwrap(updated.items.first { $0.representedObject as? String == ShortcutCommand.save.rawValue })
        XCTAssertEqual(saveItem?.keyEquivalent, "p")
        XCTAssertEqual(saveItem?.keyEquivalentModifierMask, [.command, .option])

        // An explicit unassignment leaves the item without a key equivalent.
        settings.clearShortcut(.save)
        let cleared = ApplicationMenuBuilder.makeMenu(
            .file,
            title: "File",
            settings: settings,
            availability: availability,
            localized: { L10n.tr($0, language: .english) }
        )
        XCTAssertEqual(cleared.items.first { $0.representedObject as? String == ShortcutCommand.save.rawValue }?.keyEquivalent, "")
    }

    @MainActor
    func testMenuMirrorReflectsTheEnablementMatrix() {
        let welcome = CommandAvailability()
        let menu = ApplicationMenuBuilder.makeMenu(
            .scene,
            title: "Scene",
            settings: .defaults,
            availability: welcome,
            localized: { L10n.tr($0, language: .english) }
        )
        for command in ApplicationMenuSpec.items(in: .scene).map(\.command) {
            let item = menu.items.first { $0.representedObject as? String == command.rawValue }
            XCTAssertEqual(item?.isEnabled, welcome.isEnabled(command), command.rawValue)
        }
        XCTAssertEqual(menu.items.filter(\.isEnabled).count, 0)
    }

    /// The SwiftUI commands scene cannot be instanced in a test host (it needs a
    /// running `App`), so this pins the production wiring to the mirror: every
    /// command appears exactly once with its configured shortcut, and no raw
    /// `.keyboardShortcut(` bypasses the registry.
    func testProductionMenuWiresEveryCommandExactlyOnce() throws {
        let source = try productionSource("FrameScript/App/FrameScriptApp.swift")

        XCTAssertEqual(source.components(separatedBy: ".keyboardShortcut(").count - 1, 0)
        XCTAssertTrue(source.contains("CommandAvailability(appState: appState)"))
        XCTAssertFalse(source.contains("!appState.hasOpenProject"))
        for command in ShortcutCommand.allCases {
            let needle = ".configuredKeyboardShortcut(appState.shortcutBinding(for: .\(command.rawValue)))"
            XCTAssertEqual(
                source.components(separatedBy: needle).count - 1,
                1,
                "\(command.rawValue) must be wired exactly once in the menu"
            )
        }
    }

    // MARK: - Error presentation (item 5)

    func testErrorAlertPresentsOnlyInTheKeyWindow() {
        // Error raised while the main window is key: main presents, Settings does not.
        XCTAssertTrue(ErrorAlertPresentation.shouldPresent(hasError: true, isPresenting: false, isKeyWindow: true))
        XCTAssertFalse(ErrorAlertPresentation.shouldPresent(hasError: true, isPresenting: false, isKeyWindow: false))
        // No error: nothing to present.
        XCTAssertFalse(ErrorAlertPresentation.shouldPresent(hasError: false, isPresenting: true, isKeyWindow: true))
    }

    func testErrorAlertStaysAttachedWhileItsOwnSheetTakesKey() {
        // The alert appeared in the key window and latched.
        var presenting = ErrorAlertPresentation.presentingAfterErrorChange(
            previousPresenting: false,
            newErrorIsNil: false,
            isKeyWindow: true
        )
        XCTAssertTrue(presenting)
        // The parent window resigns key to its own alert; the alert must stay.
        XCTAssertTrue(ErrorAlertPresentation.shouldPresent(hasError: true, isPresenting: presenting, isKeyWindow: false))
        // Dismissal clears the latch.
        presenting = ErrorAlertPresentation.presentingAfterErrorChange(
            previousPresenting: presenting,
            newErrorIsNil: true,
            isKeyWindow: false
        )
        XCTAssertFalse(presenting)
        XCTAssertFalse(ErrorAlertPresentation.shouldPresent(hasError: false, isPresenting: presenting, isKeyWindow: true))
    }

    func testAnErrorRaisedWhileSettingsIsKeyDoesNotLatchTheMainWindow() {
        let presenting = ErrorAlertPresentation.presentingAfterErrorChange(
            previousPresenting: false,
            newErrorIsNil: false,
            isKeyWindow: false
        )
        XCTAssertFalse(presenting)
        XCTAssertFalse(ErrorAlertPresentation.shouldPresent(hasError: true, isPresenting: presenting, isKeyWindow: false))
    }

    func testBothWindowsHostTheSharedErrorAlert() throws {
        let main = try productionSource("FrameScript/App/AppShellView.swift")
        let settings = try productionSource("FrameScript/App/FrameScriptApp.swift")

        XCTAssertTrue(main.contains(".errorAlert()"))
        XCTAssertTrue(settings.contains(".errorAlert()"))
    }

    // MARK: - Accessibility announcement (item 9)

    func testNoticesAreAnnouncedWithHighPriority() {
        let info = AccessibilityAnnouncement.userInfo(for: "Recent project removed")

        XCTAssertEqual(info[.announcement] as? String, "Recent project removed")
        XCTAssertEqual(info[.priority] as? Int, NSAccessibilityPriorityLevel.high.rawValue)
        // Empty notices are not posted; the payload stays usable either way.
        XCTAssertEqual(AccessibilityAnnouncement.userInfo(for: "")[.announcement] as? String, "")
    }

    func testNoticeAnnouncementIsWiredToTheSharedNotice() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")

        XCTAssertTrue(source.contains("AccessibilityAnnouncement.post("))
        XCTAssertTrue(source.contains("appState.errorCenter.notice"))
    }

    // MARK: - Palette handoff (item 8)

    @MainActor
    func testPaletteExportHandoffIsDeliveredOnce() {
        let handoff = PaletteActionHandoff()
        XCTAssertFalse(handoff.takeExportRequest())
        handoff.opensExport = true
        XCTAssertTrue(handoff.takeExportRequest())
        XCTAssertFalse(handoff.takeExportRequest())
    }

    // MARK: - Welcome and shortcut flags (item 3)

    func testPaletteAndShortcutFlagsAreResetWhenTheProjectChanges() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")

        // The sheets live at the window root so ⌘K/⇧⌘/ work on the welcome screen.
        XCTAssertTrue(source.contains("CommandPaletteView()"))
        XCTAssertTrue(source.contains("ShortcutsOverlay()"))
        XCTAssertTrue(source.contains("isCommandPalettePresented = false"))
        XCTAssertTrue(source.contains("isShortcutsPresented = false"))
        XCTAssertTrue(source.contains("onChange(of: appState.hasOpenProject)"))
        // The project shell must no longer own the two sheets.
        let shell = try XCTUnwrap(source.components(separatedBy: "struct AppShellView: View").last)
        XCTAssertFalse(shell.contains(".sheet(isPresented: $windowState.isCommandPalettePresented"))
        XCTAssertFalse(shell.contains(".sheet(isPresented: $windowState.isShortcutsPresented"))
    }

    // MARK: - App-level windows (item 6)

    func testBackupsAndOBSSettingsAreReachableWithoutAProject() throws {
        let source = try productionSource("FrameScript/App/FrameScriptApp.swift")
        let availability = CommandAvailability()

        XCTAssertTrue(availability.canShowBackups)
        XCTAssertTrue(availability.canOpenOBSSettings)
        XCTAssertTrue(source.contains("appState.showBackupsWindow()"))
        XCTAssertTrue(source.contains("appState.recording.isSettingsPresented = true"))
        // The OBS sheet moved to the window root so it also works on the welcome screen.
        let shell = try productionSource("FrameScript/App/AppShellView.swift")
        XCTAssertTrue(shell.contains("OBSSettingsSheet()"))
    }

    // MARK: - Shell accessibility (item 9)

    func testShellHonoursReduceMotionAndHidesTheAIPanelWhenNarrow() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")

        XCTAssertTrue(source.contains("accessibilityReduceMotion"))
        XCTAssertTrue(source.contains("reduceMotion ? nil :"))
        XCTAssertTrue(source.contains("aiPanelMinimumWindowWidth"))
        XCTAssertTrue(source.contains("windowWidth >= Self.aiPanelMinimumWindowWidth"))
    }

    func testWelcomeStartsWithAKeyboardFocusTarget() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")

        XCTAssertTrue(source.contains("focusedWelcomeAction = .blankProject"))
        XCTAssertTrue(source.contains(".focused($focusedAction, equals: kind)"))
        XCTAssertTrue(source.contains("welcome.dropProject"))
    }

    func testEmptyProjectAddSceneUsesAButtonStyle() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")
        let emptyState = try XCTUnwrap(source.components(separatedBy: "struct EmptyProjectView").last)

        XCTAssertTrue(emptyState.contains(".buttonStyle(.borderedProminent)"))
    }

    // MARK: - Export sheet (item 7)

    @MainActor
    func testExportSeamWritesTheFileAndReportsSuccess() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: "Texto del gancho")
        var project = FrameProject(title: "Proyecto", scenes: [scene])
        project.targetDuration = 60
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store)
        appState.editorState.selectedSceneID = scene.id
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP5Export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("export.txt")

        let wrote = appState.saveExportReportingStatus(
            format: .plainText,
            preferences: AppSettings.defaults.exportPreferences,
            to: url
        )

        XCTAssertTrue(wrote)
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.isEmpty)
        XCTAssertTrue(contents.contains("Texto del gancho"))
    }

    func testExportSheetKeepsTheChosenFormatWhenTheWriteSucceeds() throws {
        let source = try productionSource("FrameScript/App/AppShellView.swift")

        XCTAssertTrue(source.contains("saveExportReportingStatus("))
        XCTAssertTrue(source.contains("exportPreferences.defaultFormat = format"))
        XCTAssertTrue(source.contains("guard appState.saveExportReportingStatus"))
    }

    // MARK: - Helpers

    @MainActor
    private func makeAppState(store: ProjectStore) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = false
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }

    private func productionSource(_ path: String) throws -> String {        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path))
    }
}
