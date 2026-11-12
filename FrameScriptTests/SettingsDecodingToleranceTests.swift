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
