import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class SettingsDecodingToleranceTests: XCTestCase {
    func testEmptySettingsObjectFallsBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppSettings.defaults)
    }

    func testPartialSettingsNeverResetOtherSections() throws {
        let data = Data("""
        {
          "generalPreferences": {
            "language": "russian",
            "autosaveEnabled": false
          }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.generalPreferences.language, .russian)
        XCTAssertFalse(decoded.generalPreferences.autosaveEnabled)
        XCTAssertEqual(decoded.generalPreferences.autosaveIntervalSeconds, 10)
        XCTAssertEqual(decoded.generalPreferences.defaultNewProjectTemplate, "Blank")
        XCTAssertEqual(decoded.generalPreferences.defaultSplitMode, .paragraph)
        XCTAssertTrue(decoded.generalPreferences.confirmBeforeDeleting)

        XCTAssertEqual(decoded.theme, AppSettings.defaults.theme)
        XCTAssertEqual(decoded.accentColor, AppSettings.defaults.accentColor)
        XCTAssertEqual(decoded.editorPreferences, AppSettings.defaults.editorPreferences)
        XCTAssertEqual(decoded.aiPreferences, AppSettings.defaults.aiPreferences)
        XCTAssertEqual(decoded.voicePreferences, AppSettings.defaults.voicePreferences)
        XCTAssertEqual(decoded.exportPreferences, AppSettings.defaults.exportPreferences)
        XCTAssertEqual(decoded.windowPreferences, AppSettings.defaults.windowPreferences)
        XCTAssertTrue(decoded.shortcutOverrides.isEmpty)
    }

    func testMissingNestedPreferenceSectionsKeepStoredValues() throws {
        var settings = AppSettings.defaults
        settings.generalPreferences.defaultNewProjectTemplate = "Review"
        settings.generalPreferences.autosaveIntervalSeconds = 45
        settings.editorPreferences.wordsPerMinute = 177
        settings.aiPreferences.maxTokens = 900

        let encoded = try JSONEncoder().encode(settings)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "voicePreferences")
        root.removeValue(forKey: "exportPreferences")
        root.removeValue(forKey: "windowPreferences")
        let partial = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: partial)

        XCTAssertEqual(decoded.generalPreferences.defaultNewProjectTemplate, "Review")
        XCTAssertEqual(decoded.generalPreferences.autosaveIntervalSeconds, 45)
        XCTAssertEqual(decoded.editorPreferences.wordsPerMinute, 177)
        XCTAssertEqual(decoded.aiPreferences.maxTokens, 900)
        XCTAssertEqual(decoded.voicePreferences, AppSettings.defaults.voicePreferences)
        XCTAssertEqual(decoded.exportPreferences, AppSettings.defaults.exportPreferences)
        XCTAssertEqual(decoded.windowPreferences, AppSettings.defaults.windowPreferences)
    }

    func testEmptyPreferenceSectionsUseTheirDefaults() throws {
        let data = Data("""
        {
          "generalPreferences": {},
          "voicePreferences": {},
          "exportPreferences": {},
          "windowPreferences": {},
          "editorPreferences": {},
          "aiPreferences": {}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.generalPreferences, .defaults)
        XCTAssertEqual(decoded.voicePreferences, .defaults)
        XCTAssertEqual(decoded.exportPreferences, .defaults)
        XCTAssertEqual(decoded.windowPreferences, .defaults)
        XCTAssertEqual(decoded.editorPreferences, .defaults)
        XCTAssertEqual(decoded.aiPreferences, .defaults)
    }
}

extension SettingsDecodingToleranceTests {
    func testUnknownEnumRawValuesFallBackPerFieldWithoutWipingValues() throws {
        var settings = AppSettings.defaults
        settings.editorPreferences.wordsPerMinute = 177
        settings.editorPreferences.fontSize = 26
        settings.aiPreferences.model = "custom-model"
        settings.generalPreferences.autosaveIntervalSeconds = 45
        settings.rhythmThresholdsByVideoType = [
            "review": RhythmThresholds(longSentenceWordLimit: 30, uncoveredSecondsLimit: 4)
        ]

        let encoded = try JSONEncoder().encode(settings)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root["theme"] = "Neon"
        root["accentColor"] = 42

        var general = try XCTUnwrap(root["generalPreferences"] as? [String: Any])
        general["language"] = "klingon"
        general["launchBehavior"] = "explode"
        general["blankProjectStart"] = "somewhere"
        general["defaultSplitMode"] = "word"
        root["generalPreferences"] = general

        var editor = try XCTUnwrap(root["editorPreferences"] as? [String: Any])
        editor["defaultNotesVisibility"] = "invisible"
        root["editorPreferences"] = editor

        var ai = try XCTUnwrap(root["aiPreferences"] as? [String: Any])
        ai["provider"] = "Grok"
        root["aiPreferences"] = ai

        var voice = try XCTUnwrap(root["voicePreferences"] as? [String: Any])
        voice["provider"] = "Robot"
        root["voicePreferences"] = voice

        var export = try XCTUnwrap(root["exportPreferences"] as? [String: Any])
        export["defaultFormat"] = "PDF"
        root["exportPreferences"] = export

        var window = try XCTUnwrap(root["windowPreferences"] as? [String: Any])
        window["focusModeBehavior"] = "explode"
        root["windowPreferences"] = window

        let binding: [String: Any] = [
            "key": ShortcutKey.character.rawValue,
            "character": "p",
            "modifiers": [ShortcutModifier.command.rawValue]
        ]
        let invalidBinding: [String: Any] = [
            "key": ShortcutKey.character.rawValue,
            "character": "p",
            "modifiers": ["hyper"]
        ]
        root["shortcutOverrides"] = [
            ShortcutCommand.commandPalette.rawValue,
            binding,
            ShortcutCommand.save.rawValue,
            invalidBinding,
            "futureCommand",
            binding
        ]
        root["rhythmThresholdsByVideoType"] = [
            "review": ["longSentenceWordLimit": 30, "uncoveredSecondsLimit": 4],
            "broken": "not a dictionary"
        ]

        let data = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded.theme, .system)
        XCTAssertEqual(decoded.accentColor, .sage)
        XCTAssertEqual(decoded.generalPreferences.language, .system)
        XCTAssertEqual(decoded.generalPreferences.launchBehavior, .showProjectBrowser)
        XCTAssertEqual(decoded.generalPreferences.blankProjectStart, .oneEmptyScene)
        XCTAssertEqual(decoded.generalPreferences.defaultSplitMode, .paragraph)
        XCTAssertEqual(decoded.editorPreferences.defaultNotesVisibility, .collapsed)
        XCTAssertEqual(decoded.aiPreferences.provider, .disabled)
        XCTAssertEqual(decoded.voicePreferences.provider, .system)
        XCTAssertEqual(decoded.exportPreferences.defaultFormat, .productionOutline)
        XCTAssertEqual(decoded.windowPreferences.focusModeBehavior, .hidePanels)

        XCTAssertEqual(decoded.editorPreferences.wordsPerMinute, 177)
        XCTAssertEqual(decoded.editorPreferences.fontSize, 26)
        XCTAssertEqual(decoded.aiPreferences.model, "custom-model")
        XCTAssertEqual(decoded.generalPreferences.autosaveIntervalSeconds, 45)

        if case .assigned(let binding)? = decoded.shortcutOverrides[.commandPalette] {
            XCTAssertEqual(binding, ShortcutBinding("p", modifiers: [.command]))
        } else {
            XCTFail("Expected the valid shortcut override to survive an unknown command")
        }
        XCTAssertEqual(decoded.shortcutOverrides[.save], .unassigned)
        XCTAssertEqual(decoded.rhythmThresholdsByVideoType["review"]?.longSentenceWordLimit, 30)
        XCTAssertEqual(decoded.rhythmThresholdsByVideoType["review"]?.uncoveredSecondsLimit, 4)
        XCTAssertEqual(decoded.rhythmThresholdsByVideoType["broken"], RhythmThresholds())
    }
}

extension SettingsDecodingToleranceTests {
    func testUnreadableSettingsBlobIsBackedUp() throws {
        let suite = "SettingsDecodingToleranceTests-backup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "FrameScript.settings.v1"
        let original = Data("{not valid settings".utf8)
        defaults.set(original, forKey: key)
        enum Expected: Error { case failed }

        let store = SettingsStore(
            userDefaults: defaults,
            key: key,
            decoder: { _ in throw Expected.failed }
        )

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(defaults.data(forKey: key + ".unreadable-backup"), original)
    }
}
