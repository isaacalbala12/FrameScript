import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// FU2 regressions for WP2 item 12/B3: an unknown stored subscription provider
/// kind must survive a decode -> encode -> decode round trip instead of being
/// rewritten as T3, and choosing a provider (including T3 itself) must clear
/// the "unknown provider" error.
@MainActor
final class FU2SubscriptionAIKindTests: FrameScriptTestCase {
    private func decodeSelection(_ json: String) throws -> SubscriptionAISelection {
        try JSONDecoder().decode(SubscriptionAISelection.self, from: Data(json.utf8))
    }

    private func encodedObject(_ selection: SubscriptionAISelection) throws -> [String: Any] {
        let data = try JSONEncoder().encode(selection)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAnUnknownKindSurvivesAJSONRoundTrip() throws {
        let first = try decodeSelection(#"{"kind":"quantum","providerInstanceID":"p","modelSlug":"m"}"#)
        XCTAssertTrue(first.hasUnknownKind)

        let encoded = try encodedObject(first)
        XCTAssertEqual(
            encoded["kind"] as? String,
            "quantum",
            "encoding must not rewrite the unknown kind as t3"
        )

        let second = try JSONDecoder().decode(
            SubscriptionAISelection.self,
            from: try JSONEncoder().encode(first)
        )
        XCTAssertTrue(second.hasUnknownKind)
        XCTAssertEqual(second.validationIssue, .unknownProviderKind)
    }

    func testASettingsRoundTripKeepsAnUnknownKindInEverySelection() throws {
        let json = """
        {
          "useForAllTasks": false,
          "defaultSelection": {"kind":"quantum","providerInstanceID":"","modelSlug":""},
          "taskSelections": {
            "review": {"kind":"warp","providerInstanceID":"","modelSlug":""},
            "hooks": {"kind":"claude","providerInstanceID":"","modelSlug":"sonnet"}
          },
          "t3Project": {"name":"FrameScript IA"},
          "defaultTimeout": 180
        }
        """
        let settings = try JSONDecoder().decode(SubscriptionAISettings.self, from: Data(json.utf8))
        var edited = settings
        // An unrelated edit re-saves the whole blob; it must not launder an
        // unknown kind into T3.
        edited.defaultTimeout = 60

        let reloaded = try JSONDecoder().decode(
            SubscriptionAISettings.self,
            from: JSONEncoder().encode(edited)
        )

        XCTAssertTrue(reloaded.defaultSelection.hasUnknownKind)
        let review = try XCTUnwrap(reloaded.taskSelections["review"])
        XCTAssertTrue(review.hasUnknownKind)
        XCTAssertNil(reloaded.taskSelections["hooks"]?.validationIssue)
        XCTAssertEqual(reloaded.defaultTimeout, 60)
    }

    func testTheSettingsStorePersistsAnUnknownKind() throws {
        let defaults = makeDefaults()
        let seeded = try JSONDecoder().decode(
            SubscriptionAISettings.self,
            from: Data(#"{"defaultSelection":{"kind":"quantum","providerInstanceID":"","modelSlug":""}}"#.utf8)
        )
        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        store.replace(with: seeded)
        store.settings.defaultTimeout = 45

        let reloaded = SubscriptionAISettingsStore(userDefaults: defaults)

        XCTAssertTrue(reloaded.settings.defaultSelection.hasUnknownKind)
        XCTAssertEqual(reloaded.settings.defaultSelection.validationIssue, .unknownProviderKind)
        XCTAssertEqual(reloaded.settings.defaultTimeout, 45)
    }

    func testChoosingT3ClearsAnUnknownKind() throws {
        let unknown = try decodeSelection(#"{"kind":"quantum","providerInstanceID":"","modelSlug":""}"#)

        let cleared = unknown.selecting(kind: .t3)

        XCTAssertFalse(cleared.hasUnknownKind)
        XCTAssertNil(cleared.validationIssue)
        XCTAssertEqual(cleared.kind, .t3)
        XCTAssertEqual(cleared.modelSlug, SubscriptionAISelection.defaultT3.modelSlug)
        XCTAssertEqual(try encodedObject(cleared)["kind"] as? String, "t3")
    }

    func testChoosingAKnownKindAlsoClearsAnUnknownKind() throws {
        let unknown = try decodeSelection(#"{"kind":"quantum","providerInstanceID":"","modelSlug":""}"#)

        let cleared = unknown.selecting(kind: .claude)

        XCTAssertFalse(cleared.hasUnknownKind)
        XCTAssertNil(cleared.validationIssue)
        XCTAssertEqual(cleared.kind, .claude)
    }

    func testSelectingTheSameKnownKindKeepsTheEditedModel() {
        let selection = SubscriptionAISelection(kind: .claude, modelSlug: "opus")

        XCTAssertEqual(selection.selecting(kind: .claude), selection)
    }

    func testTheGlobalDefaultKindSetterClearsAnUnknownKind() throws {
        let unknown = try decodeSelection(#"{"kind":"quantum","providerInstanceID":"","modelSlug":""}"#)
        var settings = SubscriptionAISettings(defaultSelection: unknown)

        settings.setDefaultKind(.t3)

        XCTAssertFalse(settings.defaultSelection.hasUnknownKind)
        XCTAssertNil(settings.defaultSelection.validationIssue)
        XCTAssertEqual(settings.defaultSelection.kind, .t3)
    }
}
