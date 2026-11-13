import AppKit
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

/// Offscreen snapshots for the WP7 visual changes in Settings:
/// localized video-type labels, the reading-speed unit and the app-language
/// decimal separator in the rhythm threshold rows.
///
/// The assertions run with or without `FS_SNAPSHOTS=1`; set it to also write
/// the PNGs under `/tmp/fs-snapshots/WP7LocalizationSnapshotTests/`.
@MainActor
final class WP7LocalizationSnapshotTests: FrameScriptTestCase {
    func testMarkupRhythmSettingsSnapshots() {
        let appState = makeSnapshotAppState()
        for appearance in SnapshotAppearance.allCases {
            let result = SnapshotRenderer.render(
                ScrollView {
                    EditorMarkupSettingsSection()
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                },
                name: "settings-markup-rhythm-\(appearance.rawValue)",
                suite: "WP7LocalizationSnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )

            XCTAssertGreaterThan(result.pixelSize.width, 0)
            let text = result.textFragments.joined(separator: "\n")
            XCTAssertTrue(text.contains("Análisis"), "localized video type missing:\n\(text)")
            XCTAssertTrue(text.contains("ppm"), "Spanish reading-speed unit missing:\n\(text)")
            XCTAssertFalse(text.contains(" wpm"), "English unit leaked into Spanish:\n\(text)")
            XCTAssertTrue(text.contains("0,5"), "Spanish decimal separator missing:\n\(text)")
            XCTAssertFalse(text.contains("0.5"), "English decimal separator leaked into Spanish:\n\(text)")
        }
    }

    private func makeSnapshotAppState() -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.rhythmReviewEnabled = true
        // A table saved by an older build, under the Spanish display name.
        settings.rhythmThresholdsByVideoType["Análisis"] = AppRhythmThresholds(
            longSentenceWordLimit: 22,
            uncoveredSecondsLimit: 4.5,
            sceneLengthRatioLimit: 1.9,
            hookSecondsLimit: 14
        )

        var project = SampleData.demoProject(language: .spanish)
        project.videoType = "analysis"
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: WP7OBSSecretStore()
            ),
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
        return appState
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct WP7OBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
