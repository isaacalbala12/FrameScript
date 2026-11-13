import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class SettingsPreferencesTests: XCTestCase {
    func testLegacyLaunchBehaviorMigrationRestoresOnlyTheUnambiguousCombination() throws {
        for (showBrowser, restoreLastProject, expected) in [
            (false, true, LaunchBehavior.restoreLastProject),
            (true, true, .showProjectBrowser),
            (true, false, .showProjectBrowser),
            (false, false, .showProjectBrowser)
        ] {
            let preferences = try JSONDecoder().decode(
                GeneralPreferences.self,
                from: legacyGeneralPreferencesData(
                    showProjectBrowserOnLaunch: showBrowser,
                    restoreLastProjectOnLaunch: restoreLastProject
                )
            )
            XCTAssertEqual(preferences.launchBehavior, expected)
        }
    }

    func testRestoreLastProjectFallsBackToProjectBrowserWhenNoRecentProjectIsValid() {
        XCTAssertFalse(LaunchBehavior.restoreLastProject.shouldRestoreLastProject(hasOpenProject: false, hasRecentProject: false))
        XCTAssertFalse(LaunchBehavior.restoreLastProject.shouldRestoreLastProject(hasOpenProject: true, hasRecentProject: true))
        XCTAssertTrue(LaunchBehavior.restoreLastProject.shouldRestoreLastProject(hasOpenProject: false, hasRecentProject: true))
        XCTAssertFalse(LaunchBehavior.showProjectBrowser.shouldRestoreLastProject(hasOpenProject: false, hasRecentProject: true))
    }

    func testMissingInlineAutocompletePreferenceDefaultsToDisabled() throws {
        let data = Data("""
        {"provider":"Disabled","model":"gpt-4.1-mini","baseURL":"","temperature":0.4,"maxTokens":420,"privacyMode":true}
        """.utf8)

        XCTAssertFalse(try JSONDecoder().decode(AIPreferences.self, from: data).enableInlineAutocomplete)
    }

    func testDisabledInlineAutocompleteBlocksOnlyAutocompleteEligibility() async {
        let suiteName = "SettingsPreferencesTests-autocomplete-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = AIProviderConfigurationStore(userDefaults: defaults)
        configurationStore.setHasStoredKey(true, for: .openAICompatible)
        var settings = AppSettings.defaults
        settings.aiPreferences.provider = .openAICompatible
        settings.aiPreferences.enableInlineAutocomplete = false
        let appState = AppState(
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: configurationStore
        )

        XCTAssertEqual(appState.autocompleteConfigurationEligibility, .blockedPreferenceDisabled)
        let result = await appState.autocompleteScript(
            context: AutocompleteContext(prefix: "A sufficiently long script prefix.", suffix: "", sceneTitle: "Scene", language: .english)
        )
        XCTAssertEqual(result, .none)

        appState.settings.aiPreferences.enableInlineAutocomplete = true
        appState.inlineAutocompletePreferenceDidChange()
        XCTAssertEqual(appState.autocompleteConfigurationEligibility, .eligible)
    }

    func testNewAndResetSettingsEnableAIReviewAndKeepInlineAutocompleteOff() {
        XCTAssertTrue(AppSettings.defaults.editorPreferences.showAIReviewPanel)
        XCTAssertFalse(AppSettings.defaults.aiPreferences.enableInlineAutocomplete)

        let suiteName = "SettingsPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(settings: .defaults, userDefaults: defaults, key: "settings")
        store.settings.editorPreferences.showAIReviewPanel = false
        store.settings.aiPreferences.enableInlineAutocomplete = true
        store.reset()

        XCTAssertTrue(store.settings.editorPreferences.showAIReviewPanel)
        XCTAssertFalse(store.settings.aiPreferences.enableInlineAutocomplete)
    }

    func testProviderSwitchesNeverReEnableInlineAutocomplete() {
        var preferences = AppSettings.defaults.aiPreferences
        XCTAssertFalse(preferences.enableInlineAutocomplete)

        preferences.provider = .t3Code
        XCTAssertFalse(preferences.enableInlineAutocomplete)
        preferences.provider = .claudeCode
        XCTAssertFalse(preferences.enableInlineAutocomplete)
        preferences.provider = .codex
        XCTAssertFalse(preferences.enableInlineAutocomplete)
        preferences.provider = .openAICompatible
        XCTAssertFalse(preferences.enableInlineAutocomplete)
    }

    func testSavedAIReviewPreferenceIsPreservedAndFooterStateIsNotEncoded() throws {
        var settings = AppSettings.defaults
        settings.editorPreferences.showAIReviewPanel = false
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let editor = try XCTUnwrap(root["editorPreferences"] as? [String: Any])

        XCTAssertFalse(decoded.editorPreferences.showAIReviewPanel)
        XCTAssertNil(editor["showFooterShortcuts"])
    }

    func testLegacyEditorGeometrySettingsDecodeWithoutAffectingCuratedLayout() throws {
        var expected = AppSettings.defaults
        expected.generalPreferences.language = .russian
        expected.editorPreferences.wordsPerMinute = 177
        expected.editorPreferences.fontSize = 28
        expected.editorPreferences.spellcheck = false
        expected.editorPreferences.defaultNotesVisibility = .expanded
        expected.aiPreferences.enableInlineAutocomplete = false
        let legacyData = try legacySettingsData(from: expected, editorGeometry: (width: 560, lineHeight: 1.2))

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(ScriptEditorLayout.maximumTextColumnWidth, 900)
        XCTAssertEqual(ScriptEditorLayout.textKitLineSpacing, 1.48 * 4, accuracy: 0.001)
    }

    func testEncodedSettingsOmitLegacyEditorGeometryFields() throws {
        let legacyData = try legacySettingsData(from: .defaults, editorGeometry: (width: 980, lineHeight: 1.8))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        let encoded = try JSONEncoder().encode(decoded)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let editor = try XCTUnwrap(root["editorPreferences"] as? [String: Any])

        XCTAssertNil(editor["editorWidth"])
        XCTAssertNil(editor["lineHeight"])
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded), decoded)
    }

    private func legacyGeneralPreferencesData(
        showProjectBrowserOnLaunch: Bool,
        restoreLastProjectOnLaunch: Bool
    ) -> Data {
        Data("""
        {
          "showProjectBrowserOnLaunch": \(showProjectBrowserOnLaunch),
          "restoreLastProjectOnLaunch": \(restoreLastProjectOnLaunch),
          "language": "system",
          "autosaveEnabled": true,
          "autosaveIntervalSeconds": 10,
          "defaultNewProjectTemplate": "Blank",
          "blankProjectStart": "One empty scene",
          "defaultSplitMode": "paragraph",
          "confirmBeforeDeleting": true
        }
        """.utf8)
    }

    private func legacySettingsData(
        from settings: AppSettings,
        editorGeometry: (width: Double, lineHeight: Double)
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(settings)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var editor = try XCTUnwrap(root["editorPreferences"] as? [String: Any])
        editor["editorWidth"] = editorGeometry.width
        editor["lineHeight"] = editorGeometry.lineHeight
        root["editorPreferences"] = editor
        return try JSONSerialization.data(withJSONObject: root)
    }
}
