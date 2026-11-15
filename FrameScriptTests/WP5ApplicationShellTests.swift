import AppKit
import XCTest
@testable import FrameScript

/// WP5 items 3–10: the application menu mirror, the single error presenter and
/// the export seam.
///
/// The earlier version of this file pinned most items with source-string greps.
/// Those are gone: the shell wiring they described is exercised behaviourally by
/// `FU4AppShellBehaviourTests` (a hosted `AppRootView`), `WP5SnapshotTests`
/// (rendered screens and the AI-panel width rule) and the pure tests below.
///
/// Three SwiftUI facts genuinely cannot be observed in this test host and are
/// therefore covered by review, not by a test:
/// - `WindowGroup(id: "main")` is a `Scene` declaration; the stable name half
///   (`ThemedSceneRoot`) is pinned below and the purge mechanics are covered in
///   `WP5CommandAvailabilityTests`.
/// - `appCommands` only exists once an `App` is running; the menu data it uses
///   is tested through `ApplicationMenuBuilder` + `ApplicationMenuSpec`.
/// - `@FocusState` in `WelcomeView` needs a key window, which a headless test
///   must not create.
final class WP5ApplicationShellTests: FrameScriptTestCase {
    // MARK: - Window identity (item 4)

    func testThemedSceneRootNameIsStableAcrossLaunches() {
        let name = String(reflecting: ThemedSceneRoot<AppRootView>.self)

        XCTAssertFalse(name.contains("unknown context"), name)
        XCTAssertTrue(name.contains("ThemedSceneRoot"), name)
        XCTAssertEqual(name, String(reflecting: ThemedSceneRoot<AppRootView>.self))
    }

    /// Wiring guard: a `Scene` cannot be instantiated headless, so this pins the
    /// two lines that stop every launch from adding a new window-frame key to
    /// the user's preferences (stable `WindowGroup` id + the one-time purge).
    func testMainSceneKeepsTheStableIdentifierAndTheLegacyKeyPurge() throws {
        let appFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FrameScript/App/FrameScriptApp.swift")
        let source = try String(contentsOf: appFile, encoding: .utf8)

        XCTAssertTrue(source.contains("WindowGroup(id: \"main\")"))
        XCTAssertTrue(source.contains("LegacyWindowFrameKeys.purgeIfNeeded"))
    }

    // MARK: - AI panel in narrow windows

    func testAIReviewPanelHidesBelowTheMinimumWindowWidth() {
        let minimum = AppShellView.aiPanelMinimumWindowWidth
        XCTAssertEqual(minimum, 1080)
        XCTAssertTrue(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: minimum))
        XCTAssertTrue(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: 1440))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: minimum - 1))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: true, windowWidth: 980))
        XCTAssertFalse(AppShellView.showsAIReviewPanel(enabled: false, windowWidth: 1440))
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

    // MARK: - Settings scene composition (item 5)

    /// The hosted composition test lives in `FU4AppShellBehaviourTests`; this
    /// pins the production order, which cannot be hosted without an `App`.
    /// `.errorAlert()` reads `AppState` from the environment, so applying it
    /// outside `.environment(appState)` traps the moment Settings opens.
    func testSettingsSceneAppliesTheErrorAlertInsideTheAppStateEnvironment() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("FrameScript/App/FrameScriptApp.swift"),
            encoding: .utf8
        )
        let settingsStart = try XCTUnwrap(source.range(of: "Settings {"))
        let sceneEnd = try XCTUnwrap(
            source.range(of: "\n        }", range: settingsStart.upperBound..<source.endIndex)
        )
        let block = String(source[settingsStart.lowerBound..<sceneEnd.upperBound])
        let alert = try XCTUnwrap(block.range(of: ".errorAlert()"), block)
        let environment = try XCTUnwrap(block.range(of: ".environment(appState)"), block)

        XCTAssertLessThan(
            alert.lowerBound,
            environment.lowerBound,
            "the Settings scene must apply .errorAlert() inside .environment(appState)"
        )
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

    // MARK: - Accessibility announcement (item 9)

    func testNoticesAreAnnouncedWithHighPriority() {
        let info = AccessibilityAnnouncement.userInfo(for: "Recent project removed")

        XCTAssertEqual(info[.announcement] as? String, "Recent project removed")
        XCTAssertEqual(info[.priority] as? Int, NSAccessibilityPriorityLevel.high.rawValue)
        // Empty notices are not posted; the payload stays usable either way.
        XCTAssertEqual(AccessibilityAnnouncement.userInfo(for: "")[.announcement] as? String, "")
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

    // MARK: - App-level windows (item 6)

    func testBackupsAndOBSSettingsAreReachableWithoutAProject() {
        let availability = CommandAvailability()

        // Both are app-level windows: no project, no recording, still enabled.
        XCTAssertTrue(availability.canShowBackups)
        XCTAssertTrue(availability.canOpenOBSSettings)

        var recording = availability
        recording.hasActiveTake = true
        XCTAssertFalse(recording.canShowBackups, "restoring a backup replaces the project")
        XCTAssertTrue(recording.canOpenOBSSettings, "OBS configuration never touches the project")
    }

    // MARK: - Export sheet (item 7)

    @MainActor
    func testExportSeamWritesTheFileAndReportsSuccess() throws {
        let appState = try makeExportAppState()
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

    /// The export sheet only dismisses when the write succeeds. A failed write
    /// must report `false` and present the export error, so the sheet (and the
    /// chosen format) stays open instead of silently losing the export.
    @MainActor
    func testExportSeamReportsFailureSoTheSheetStaysOpen() throws {
        let appState = try makeExportAppState()
        // `/dev/null` is a file, so it can never be the parent of an export.
        let url = URL(fileURLWithPath: "/dev/null/FrameScriptExport-\(UUID().uuidString).txt")

        let wrote = appState.saveExportReportingStatus(
            format: .plainText,
            preferences: AppSettings.defaults.exportPreferences,
            to: url
        )

        XCTAssertFalse(wrote, "a failed write must keep the sheet open")
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .export)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Helpers

    @MainActor
    private func makeExportAppState() throws -> AppState {
        let scene = Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: "Texto del gancho")
        var project = FrameProject(title: "Proyecto", scenes: [scene])
        project.targetDuration = 60
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = makeAppState(store: store)
        appState.editorState.selectedSceneID = scene.id
        return appState
    }

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
}
