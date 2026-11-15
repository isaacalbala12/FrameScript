import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// Behavioural replacements for the WP5 tests that only grepped production
/// source text.
///
/// The shell views are real SwiftUI views, so they are hosted in an offscreen
/// `NSWindow` (never ordered front, like `SnapshotRenderer`) and their
/// observable state is driven directly. That catches wiring regressions the
/// greps could not see.
@MainActor
final class FU4AppShellBehaviourTests: FrameScriptTestCase {
    // MARK: - Palette and shortcuts on the welcome screen (WP5 item 3)

    func testPaletteAndShortcutFlagsAreResetWhenTheProjectChanges() {
        let appState = makeAppState()
        let shell = HostedShell(appState: appState)
        defer { shell.tearDown() }

        appState.windowState.isCommandPalettePresented = true
        appState.windowState.isShortcutsPresented = true
        shell.pump()

        // The sheets live at the window root, so opening a project must reset
        // both flags instead of leaving an orphaned presentation behind.
        appState.projectStore.openProject(makeProject(), fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        shell.pump()

        XCTAssertTrue(appState.hasOpenProject, "the fixture must actually open a project")
        XCTAssertFalse(appState.windowState.isCommandPalettePresented)
        XCTAssertFalse(appState.windowState.isShortcutsPresented)
    }

    // MARK: - Notice announcement (WP5 item 9)

    func testNoticeIsAnnouncedFromTheHostedShell() {
        let appState = makeAppState()
        let shell = HostedShell(appState: appState)
        defer { shell.tearDown() }

        var announcements: [String] = []
        AccessibilityAnnouncement.testRecorder = { announcements.append($0) }
        defer { AccessibilityAnnouncement.testRecorder = nil }

        appState.errorCenter.showNotice(AppNotice(kind: .recentRemoved))
        shell.pump()

        XCTAssertEqual(announcements, [appState.errorCenter.notice?.message(language: appState.currentLanguage)])
    }

    // MARK: - Settings scene composition (WP5 item 5)

    /// The Settings scene must put `.errorAlert()` inside `.environment(appState)`:
    /// the modifier reads `AppState` from the environment, and the reversed
    /// order traps as soon as the Settings window is opened. This hosts the
    /// composition the scene builds and lays it out.
    func testSettingsSceneContentLaysOutWithTheErrorAlertInsideTheEnvironment() {
        let appState = makeAppState()
        let content = ThemedSceneRoot { SettingsRootView() }
            .errorAlert()
            .environment(appState)
            .frame(width: 940, height: 650)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 940, height: 650)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = hosting
        window.setFrame(hosting.frame, display: false)

        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))

        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0)
        XCTAssertFalse(hosting.subviews.isEmpty, "the Settings content rendered no view hierarchy")

        window.contentView = nil
        hosting.removeFromSuperview()
    }

    // MARK: - Scene sidebar (WP6 item 5)

    /// Deleting a scene follows the same rule as the menu and the palette: an
    /// active take blocks it even when the take belongs to a different scene.
    func testSceneSidebarDeleteRuleMatchesTheCommandMatrix() {
        XCTAssertTrue(SceneSidebarDeleteRule.isDisabled(hasSelection: false, hasActiveTake: false))
        XCTAssertFalse(SceneSidebarDeleteRule.isDisabled(hasSelection: true, hasActiveTake: false))
        XCTAssertTrue(SceneSidebarDeleteRule.isDisabled(hasSelection: true, hasActiveTake: true))

        var availability = CommandAvailability(hasOpenProject: true, hasScenes: true, hasSelectedScene: true)
        availability.hasActiveTake = true
        XCTAssertEqual(
            SceneSidebarDeleteRule.isDisabled(hasSelection: true, hasActiveTake: true),
            !availability.canDeleteScene,
            "the sidebar and the menu must agree about Delete Scene"
        )
    }

    // MARK: - Helpers

    private func makeProject() -> FrameProject {
        var project = SampleData.demoProject(language: .spanish)
        project.targetDuration = 300
        return project
    }

    private func makeAppState() -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = false
        return AppState(
            projectStore: ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: .live,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }
}

/// Offscreen host for a production view plus the environments `AppRootView`
/// needs. The window is never ordered front.
@MainActor
private final class HostedShell {
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init(appState: AppState, size: CGSize = CGSize(width: 1180, height: 760)) {
        let root = AnyView(
            AppRootView()
                .environment(appState)
                .environment(EscaletaImportCoordinator())
                .environment(\.frameTheme, FrameTheme(colorScheme: .light, accent: appState.settings.accentColor))
                .frame(width: size.width, height: size.height)
        )
        hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = hosting
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        pump()
    }

    func pump(_ seconds: TimeInterval = 0.12) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        hosting.removeFromSuperview()
    }
}
