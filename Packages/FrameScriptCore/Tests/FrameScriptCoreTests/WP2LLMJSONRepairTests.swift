import Foundation
import Testing
@testable import FrameScriptCore

/// WP2 regression: the scene review uses the same tolerant JSON extraction as
/// the hook parser, so "Here is the JSON:" prose no longer fails the review.
@Suite("WP2 tolerant LLM JSON")
struct WP2LLMJSONRepairTests {
    @Test("extracts JSON that follows prose")
    func extractsJSONAfterProse() {
        let response = """
        Here is the JSON:
        {"title":"Hook","severity":"suggestion","message":"Make it concrete.","suggestion":"Name the benefit."}
        """
        let payloads = LLMJSONRepair.parsedPayloads(in: response)
        let object = payloads.compactMap { $0 as? [String: Any] }.first

        #expect(object?["title"] as? String == "Hook")
    }

    @Test("extracts JSON from a fenced block")
    func extractsFencedJSON() {
        let response = """
        Sure. ```json
        {"title":"Hook","severity":"note","message":"Fine.","suggestion":""}
        ```
        """
        let payloads = LLMJSONRepair.parsedPayloads(in: response)

        #expect(payloads.contains { ($0 as? [String: Any])?["severity"] as? String == "note" })
    }

    @Test("plain prose yields no payload")
    func proseYieldsNothing() {
        #expect(LLMJSONRepair.parsedPayloads(in: "This scene needs a stronger hook.").isEmpty)
        #expect(LLMJSONRepair.parsedPayloads(in: "").isEmpty)
    }

    @Test("the legacy HookJSONRepair name still works")
    func legacyNameIsAnAlias() {
        #expect(HookJSONRepair.candidates(from: "{\"a\":1}").first == "{\"a\":1}")
    }
}
