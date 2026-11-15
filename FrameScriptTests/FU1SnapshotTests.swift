import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// FU1 fix-up visual coverage: the default project must never show the English
/// "Untitled Script"/"New scene" next to a Spanish interface (V10).
///
/// The fixture is the same one the other main-window snapshots use
/// (`SampleData.defaultProject`), rendered in Spanish, so this test fails while
/// those titles are hard-coded in English. Without `FS_SNAPSHOTS=1` it still
/// asserts the rendered text.
@MainActor
final class FU1SnapshotTests: FrameScriptTestCase {
    func testTheSpanishDefaultProjectShowsSpanishTitles() {
        let project = SampleData.defaultProject(language: .spanish)
        let appState = makeSnapshotAppState(project: project)

        for size in SnapshotSize.allCases {
            for appearance in SnapshotAppearance.allCases {
                let name = "fu1-default-project-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    AppShellView(),
                    name: name,
                    suite: "FU1SnapshotTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels")
                XCTAssertTrue(
                    result.textFragments.contains("Guion sin título"),
                    "\(name): the toolbar must show the localized project title, got \(result.textFragments)"
                )
                XCTAssertTrue(
                    result.textFragments.contains("Escena nueva"),
                    "\(name): the sidebar must show the localized scene title, got \(result.textFragments)"
                )
            }
        }
    }

    private func makeSnapshotAppState(project: FrameProject) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = false

        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: FU1SnapshotSecretStore()),
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
        appState.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        appState.editorState.selectedMode = .script
        return appState
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct FU1SnapshotSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
