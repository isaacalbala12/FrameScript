import AppKit
import XCTest
@testable import FrameScript

/// WP5 items 1 and 3: the recording guard matrix and the palette/shortcut
/// availability that follow from it.
final class WP5CommandAvailabilityTests: FrameScriptTestCase {
    // MARK: - Menu enablement matrix

    func testNoProjectOnlyAllowsProjectCreationAndAppLevelCommands() {
        let availability = CommandAvailability()

        XCTAssertTrue(availability.canReplaceProject)
        XCTAssertTrue(availability.canOpenProject)
        XCTAssertFalse(availability.canCloseProject)
        XCTAssertFalse(availability.canDeleteProject)
        XCTAssertFalse(availability.canSaveProject)
        XCTAssertFalse(availability.canRevertToSaved)
        XCTAssertFalse(availability.canAddScene)
        XCTAssertFalse(availability.canDeleteScene)
        XCTAssertFalse(availability.canNavigateScenes)
        XCTAssertFalse(availability.canOpenTeleprompter)
        XCTAssertFalse(availability.canToggleRecording)

        // App-level windows must stay reachable from the welcome screen.
        XCTAssertTrue(availability.canShowBackups)
        XCTAssertTrue(availability.canOpenOBSSettings)
        XCTAssertTrue(availability.canShowCommandPalette)
        XCTAssertTrue(availability.canShowShortcuts)
    }

    func testEmptyProjectDisablesSceneAndToolCommands() {
        let availability = CommandAvailability(hasOpenProject: true, hasScenes: false, hasSelectedScene: false)

        XCTAssertTrue(availability.canAddScene)
        XCTAssertTrue(availability.canSaveProject)
        XCTAssertTrue(availability.canCloseProject)
        XCTAssertTrue(availability.canDeleteProject)
        XCTAssertFalse(availability.canDuplicateScene)
        XCTAssertFalse(availability.canDeleteScene)
        XCTAssertFalse(availability.canMoveScene)
        XCTAssertFalse(availability.canRenameScene)
        XCTAssertFalse(availability.canNavigateScenes)
        XCTAssertFalse(availability.canAnalyzeScene)
        XCTAssertFalse(availability.canAnalyzeFullScript)
        XCTAssertFalse(availability.canOpenTeleprompter)
        XCTAssertFalse(availability.canToggleRecording)
    }

    func testSelectedSceneEnablesSceneTools() {
        let availability = CommandAvailability(hasOpenProject: true, hasScenes: true, hasSelectedScene: true)

        XCTAssertTrue(availability.canDuplicateScene)
        XCTAssertTrue(availability.canDeleteScene)
        XCTAssertTrue(availability.canMoveScene)
        XCTAssertTrue(availability.canRenameScene)
        XCTAssertTrue(availability.canNavigateScenes)
        XCTAssertTrue(availability.canAnalyzeScene)
        XCTAssertTrue(availability.canOpenTeleprompter)
    }

    func testActiveTakeBlocksEveryProjectReplacementButKeepsStopReachable() {
        let availability = CommandAvailability(
            hasOpenProject: true,
            hasScenes: true,
            hasSelectedScene: true,
            isRecordingActive: true,
            hasActiveTake: true
        )

        // lifecycle P1-1: a take must not be orphaned by a project swap.
        XCTAssertFalse(availability.canReplaceProject)
        XCTAssertFalse(availability.canOpenProject)
        XCTAssertFalse(availability.canCloseProject)
        XCTAssertFalse(availability.canDeleteProject)
        XCTAssertFalse(availability.canDeleteScene)
        XCTAssertFalse(availability.isEnabled(.newProject))
        XCTAssertFalse(availability.isEnabled(.openProject))
        XCTAssertFalse(availability.isEnabled(.deleteScene))
        XCTAssertFalse(availability.isEnabled(.importEscaleta))

        // ... but the take can always be stopped.
        XCTAssertTrue(availability.canToggleRecording)
        XCTAssertTrue(availability.isEnabled(.recordTake))
        // Restoring a backup would replace the project mid-take.
        XCTAssertFalse(availability.canShowBackups)
        XCTAssertFalse(availability.isEnabled(.showBackups))
        // Non-destructive edits stay available.
        XCTAssertTrue(availability.canAddScene)
        XCTAssertTrue(availability.canAnalyzeScene)
    }

    func testRecordingWithoutAProjectStillAllowsStop() {
        let availability = CommandAvailability(isRecordingActive: true, hasActiveTake: true)

        XCTAssertTrue(availability.canToggleRecording)
        XCTAssertTrue(availability.isEnabled(.recordTake))
        XCTAssertFalse(availability.isEnabled(.toggleRecordingPanel))
        XCTAssertFalse(availability.canCloseProject)
    }

    func testEnabledMatrixCoversEveryCommand() {
        let availability = CommandAvailability(
            hasOpenProject: true,
            hasScenes: true,
            hasSelectedScene: true
        )
        // Every case must have an answer; this also documents that no command is
        // accidentally enabled by a missing branch.
        for command in ShortcutCommand.allCases {
            _ = availability.isEnabled(command)
        }
        XCTAssertTrue(availability.isEnabled(.deleteScene))
        XCTAssertFalse(CommandAvailability().isEnabled(.deleteScene))
    }

    // MARK: - AppState integration

    @MainActor
    func testAvailabilityReadsTheOpenProjectAndSelection() throws {
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "Text")
        let project = FrameProject(title: "Project", scenes: [scene])
        let store = ProjectStore(project: project)
        let appState = makeAppState(store: store)

        XCTAssertFalse(CommandAvailability(appState: appState).hasOpenProject)

        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        appState.editorState.selectedSceneID = scene.id
        let availability = CommandAvailability(appState: appState)

        XCTAssertTrue(availability.hasOpenProject)
        XCTAssertTrue(availability.hasScenes)
        XCTAssertTrue(availability.hasSelectedScene)
        XCTAssertFalse(availability.hasSavedFile)
        XCTAssertFalse(availability.canRevertToSaved)
        XCTAssertFalse(availability.isRecordingActive)
        XCTAssertFalse(availability.hasActiveTake)
    }

    @MainActor
    func testAvailabilityDetectsAnEmptyProject() {
        let project = FrameProject(title: "Empty", scenes: [])
        let store = ProjectStore(project: project)
        let appState = makeAppState(store: store)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let availability = CommandAvailability(appState: appState)
        XCTAssertTrue(availability.hasOpenProject)
        XCTAssertFalse(availability.hasScenes)
        XCTAssertFalse(availability.canAnalyzeFullScript)
        XCTAssertTrue(availability.canAddScene)
    }

    // MARK: - Drag and drop

    func testDropResolverOpensProjectsImportsEscaletasAndIgnoresTheRest() {
        let project = URL(fileURLWithPath: "/tmp/Proyecto.fscr")
        let legacy = URL(fileURLWithPath: "/tmp/Viejo.framescript")
        let escaleta = URL(fileURLWithPath: "/tmp/escaleta.md")
        let other = URL(fileURLWithPath: "/tmp/image.png")

        XCTAssertEqual(ProjectDropAction.resolve([project]), .openProject(project))
        XCTAssertEqual(ProjectDropAction.resolve([legacy]), .openProject(legacy))
        XCTAssertEqual(ProjectDropAction.resolve([escaleta]), .importEscaleta(escaleta))
        XCTAssertEqual(ProjectDropAction.resolve([other]), .ignore)
        XCTAssertEqual(ProjectDropAction.resolve([other, project]), .openProject(project))
        XCTAssertEqual(ProjectDropAction.resolve([]), .ignore)
    }

    // MARK: - Palette catalogue

    func testPaletteCoversEveryCommandInMenuOrder() {
        let catalogue = PaletteCatalog.commands

        XCTAssertEqual(Set(catalogue), Set(ShortcutCommand.allCases).subtracting([.commandPalette]))
        XCTAssertEqual(catalogue.count, Set(catalogue).count, "duplicate palette entry")
        XCTAssertTrue(catalogue.contains(.save))
        XCTAssertTrue(catalogue.contains(.openProject))
        XCTAssertTrue(catalogue.contains(.export))
        XCTAssertTrue(catalogue.contains(.showBackups))
        XCTAssertTrue(catalogue.contains(.moveSceneUp))
        XCTAssertTrue(catalogue.contains(.nextScene))
    }

    func testPaletteHidesProjectCommandsWithoutAProject() {
        let welcome = CommandAvailability()
        XCTAssertFalse(PaletteCatalog.isAvailable(.save, availability: welcome))
        XCTAssertFalse(PaletteCatalog.isAvailable(.deleteScene, availability: welcome))
        XCTAssertTrue(PaletteCatalog.isAvailable(.openProject, availability: welcome))
        XCTAssertTrue(PaletteCatalog.isAvailable(.openSettings, availability: welcome))

        let recording = CommandAvailability(
            hasOpenProject: true, hasScenes: true, hasSelectedScene: true, isRecordingActive: true, hasActiveTake: true
        )
        XCTAssertFalse(PaletteCatalog.isAvailable(.newProject, availability: recording))
        XCTAssertFalse(PaletteCatalog.isAvailable(.deleteScene, availability: recording))
        XCTAssertTrue(PaletteCatalog.isAvailable(.recordTake, availability: recording))
    }

    // MARK: - Application menu mirror

    func testMenuSpecificationHasExactlyOneItemPerCommand() {
        let spec = ApplicationMenuSpec.items

        XCTAssertEqual(Set(spec.map(\.command)), Set(ShortcutCommand.allCases))
        XCTAssertEqual(spec.count, Set(spec.map(\.command)).count)
        for menu in ApplicationMenuID.allCases {
            XCTAssertFalse(ApplicationMenuSpec.items(in: menu).isEmpty, "\(menu.rawValue) has no items")
        }
        XCTAssertEqual(spec.first?.command, .newProject)
    }

    // MARK: - Window frame keys

    func testLegacyWindowFrameKeysArePurgedOnceAndStableKeysSurvive() {
        let testDefaults = makeTestDefaults()
        let defaults = testDefaults.defaults
        let legacy = "NSWindow Frame SwiftUI.ModifiedContent<FrameScript.(unknown context at $100a1b2c0).ThemedSceneRoot<FrameScript.AppRootView>>_NSThemeFrame"
        let stable = "NSWindow Frame main"
        defaults.set("frame", forKey: legacy)
        defaults.set("frame", forKey: stable)
        defaults.set("value", forKey: "FrameScript.settings.v1")

        XCTAssertEqual(LegacyWindowFrameKeys.purgeIfNeeded(defaults: defaults, domainName: testDefaults.suiteName), 1)
        XCTAssertNil(defaults.object(forKey: legacy))
        XCTAssertEqual(defaults.string(forKey: stable), "frame")
        XCTAssertNotNil(defaults.object(forKey: "FrameScript.settings.v1"))

        // The flag makes the scan a one-time cost.
        defaults.set("frame", forKey: legacy)
        XCTAssertEqual(LegacyWindowFrameKeys.purgeIfNeeded(defaults: defaults, domainName: testDefaults.suiteName), 0)
        XCTAssertEqual(defaults.string(forKey: legacy), "frame")
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
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings")
        )
    }
}
