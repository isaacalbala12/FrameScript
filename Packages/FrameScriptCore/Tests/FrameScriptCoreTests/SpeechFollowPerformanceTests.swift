import Foundation
import Testing
@testable import FrameScriptCore

@Test func followerMeetsPerUpdateBudgetOn5000WordScript() {
    let sentences: [String] = (0..<500).map { sentence in
        let words = (0..<10).map { "palabra\(sentence)x\($0)" }
        return words.joined(separator: " ") + "."
    }

    let multiSentence = ScriptTokenizer.tokenize(
        sentences.joined(separator: "\n"),
        language: .spanish
    )
    let oneSentence = ScriptTokenizer.tokenize(
        sentences.joined(separator: " ").replacingOccurrences(of: ".", with: ""),
        language: .spanish
    )

    #expect(multiSentence.wordCount == 5_000)
    #expect(oneSentence.wordCount == 5_000)
    #expect(oneSentence.sentenceCount == 1)

    let clock = ContinuousClock()
    for script in [multiSentence, oneSentence] {
        var follower = SpeechFollower(script: script)
        let makeTranscript: (Int) -> String = { update in
            let start = update * 10
            let end = min(script.wordCount, start + 14)
            return script.tokens[start..<end].map(\.normalized).joined(separator: " ")
        }

        // Warm up, then measure individual updates. The minimum is a robust
        // regression guard under parallel test scheduling; the average still
        // catches a broad slowdown.
        for update in 0..<5 {
            _ = follower.process(text: makeTranscript(update), at: Double(update) * 0.3)
        }

        var durations: [Duration] = []
        for update in 5..<25 {
            let duration = clock.measure {
                _ = follower.process(text: makeTranscript(update), at: Double(update) * 0.3)
            }
            durations.append(duration)
        }

        guard let fastest = durations.min() else {
            Issue.record("No performance samples")
            return
        }
        let average = durations.reduce(.zero, +) / durations.count
        // Budget from the cross-review: 100 ms per recognizer update. Debug
        // builds get 5x headroom so a loaded CI machine cannot fail the suite
        // while still catching an order-of-magnitude regression.
        #if DEBUG
        let fastestLimit = Duration.milliseconds(500)
        let averageLimit = Duration.milliseconds(1_250)
        #else
        let fastestLimit = Duration.milliseconds(100)
        let averageLimit = Duration.milliseconds(250)
        #endif
        #expect(fastest < fastestLimit)
        #expect(average < averageLimit)
    }
}
