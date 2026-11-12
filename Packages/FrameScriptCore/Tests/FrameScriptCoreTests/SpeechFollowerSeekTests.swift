import Testing
@testable import FrameScriptCore

@Suite("Speech follower seek")
struct SpeechFollowerSeekTests {
    @Test("seek moves the anchor and the next hypothesis continues from there")
    func seekContinuesFromNewAnchor() {
        let script = ScriptTokenizer.tokenize(
            "alfa beta gamma delta epsilon zeta",
            language: .spanish
        )
        var follower = SpeechFollower(script: script)
        follower.seek(toToken: 3)

        #expect(follower.state.tokenIndex == 3)
        #expect(follower.state.confidence == 0)
        #expect(follower.state.isLost == false)

        let state = follower.process(text: "delta epsilon zeta", at: 1)
        #expect(state.tokenIndex == 5)
        #expect(state.confidence >= 0.4)
    }

    @Test("seek clamps to the script bounds")
    func seekClamps() {
        let script = ScriptTokenizer.tokenize("alfa beta", language: .spanish)
        var follower = SpeechFollower(script: script)
        follower.seek(toToken: 99)
        #expect(follower.state.tokenIndex == 1)
        follower.seek(toToken: -5)
        #expect(follower.state.tokenIndex == 0)
    }
}
