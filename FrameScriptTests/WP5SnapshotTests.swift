import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// Visual coverage for the WP5 surfaces: the command palette (project, welcome
/// and no-results states), the shortcuts overlay with its new Close button, the
/// shortcut settings row with Remove, and the AI panel width rule.
///
/// Run with `TEST_RUNNER_FS_SNAPSHOTS=1` to write PNGs to
/// `/tmp/fs-snapshots/WP5SnapshotTests/`.
@MainActor
final class WP5SnapshotTests: FrameScriptTestCase {
    func testCommandPaletteSnapshots() {
        let appState = makeSnapshotAppState(project: makeProject())
        renderAll("command-palette", appState: appState) {
            CommandPaletteView()
        }
    }

    func testCommandPaletteWithoutProjectSnapshots() {
        let appState = makeSnapshotAppState()
        renderAll("command-palette-welcome", appState: appState) {
            CommandPaletteView()
        }
    }

    func testCommandPaletteNoResultsSnapshots() {
        let appState = makeSnapshotAppState(project: makeProject())
        renderAll("command-palette-no-results", appState: appState) {
            CommandPaletteView(initialQuery: "zzzz")
        }
    }

    func testShortcutsOverlaySnapshots() {
        let appState = makeSnapshotAppState(project: makeProject())
        renderAll("shortcuts-overlay", appState: appState) {
            ShortcutsOverlay()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func testEmptyProjectSnapshots() {
        let empty = FrameProject(title: "Proyecto vacío", scenes: [])
        let appState = makeSnapshotAppState(project: empty)
        renderAll("shell-empty-project", appState: appState) {
            AppShellView()
        }
    }

    func testShortcutSettingsWithRemoveSnapshots() {
        let appState = makeSnapshotAppState(project: makeProject())
        var settings = appState.settings
        settings.shortcutOverrides[.save] = .assigned(ShortcutBinding("s", modifiers: [.command, .option]))
        settings.shortcutOverrides[.commandPalette] = .unassigned
        appState.settings = settings
        appState.windowState.requestedSettingsTab = .keyboardShortcuts
        renderAll("settings-keyboard-shortcuts-remove", appState: appState) {
            SettingsRootView()
        }
    }

    /// A factory-default shortcut is removable too: Remove is the only way to
    /// free a default key without stealing it from another command. Before the
    /// fix the button only appeared on rows that were already customized, so an
    /// untouched settings page showed no "Quitar" at all.
    func testShortcutSettingsShowRemoveForFactoryDefaults() {
        let appState = makeSnapshotAppState(project: makeProject())
        XCTAssertTrue(appState.settings.shortcutOverrides.isEmpty)
        appState.windowState.requestedSettingsTab = .keyboardShortcuts
        let remove = L10n.tr("shortcuts.remove", language: .spanish)
        XCTAssertEqual(remove, "Quitar")

        let result = SnapshotRenderer.render(
            SettingsRootView(),
            name: "settings-keyboard-shortcuts-remove-defaults",
            suite: "WP5SnapshotTests",
            size: SnapshotSize.standard.size,
            appearance: .light,
            language: .spanish,
            appState: appState
        )

        XCTAssertTrue(
            result.textFragments.contains { $0 == remove },
            "an uncustomized shortcut row must offer \(remove); text was \(result.textFragments)"
        )
    }

    func testAIPanelHidesAtTheMinimumWidth() {
        let project = makeProject()
        let appState = makeSnapshotAppState(project: project)
        appState.settings.editorPreferences.showAIReviewPanel = true
        appState.editorState.selectedMode = .script

        let standard = SnapshotRenderer.render(
            AppShellView(),
            name: "shell-ai-panel-1180x760",
            suite: "WP5SnapshotTests",
            size: SnapshotSize.standard.size,
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        XCTAssertTrue(
            standard.textFragments.contains { $0.contains(L10n.tr("ux.inspector.title", language: .spanish)) },
            "the inspector must render at 1180 pt"
        )

        let minimum = SnapshotRenderer.render(
            AppShellView(),
            name: "shell-ai-panel-980x712",
            suite: "WP5SnapshotTests",
            size: SnapshotSize.minimum.size,
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        XCTAssertFalse(
            minimum.textFragments.contains { $0.contains(L10n.tr("ux.inspector.title", language: .spanish)) },
            "the inspector must hide below 1080 pt"
        )
        XCTAssertTrue(
            minimum.textFragments.contains { $0.contains("Apexia") },
            "the script editor must keep rendering"
        )
    }

    // MARK: - Helpers

    private func renderAll<Content: View>(
        _ screen: String,
        appState: AppState,
        @ViewBuilder content: () -> Content
    ) {
        for size in SnapshotSize.allCases {
            for appearance in SnapshotAppearance.allCases {
                let name = "\(screen)-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    content(),
                    name: name,
                    suite: "WP5SnapshotTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels")
                XCTAssertFalse(result.textFragments.isEmpty, "\(name) has no text")
            }
        }
    }

    private func makeProject() -> FrameProject {
        var project = SampleData.demoProject(language: .spanish)
        project.targetDuration = 600
        return project
    }

    private func makeSnapshotAppState(project: FrameProject? = nil) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = false

        let store = ProjectStore(project: project ?? SampleData.defaultProject)
        if let project {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        }
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: SnapshotOBSSecretStore()),
            defaults: defaults
        )
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: .live,
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
        appState.editorState.selectedSceneID = project?.scenes.sortedByOrder.first?.id
        return appState
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct SnapshotOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
