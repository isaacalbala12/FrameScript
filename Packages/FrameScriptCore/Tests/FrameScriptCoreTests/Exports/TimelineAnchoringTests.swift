import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Timeline anchoring")
struct TimelineAnchoringTests {
    @Test("The start of the text is time zero")
    func start() {
        #expect(TimelineAnchoring.seconds(text: "Uno dos tres", utf16Offset: 0, wordsPerMinute: 120) == 0)
    }

    @Test("Word offsets use the same pace as the estimate")
    func words() {
        let text = "uno dos tres cuatro"
        let pace = 120.0
        // At 120 wpm one word is half a second.
        #expect(abs(TimelineAnchoring.seconds(text: text, utf16Offset: 4, wordsPerMinute: pace) - 0.5) < 0.0001)
        #expect(abs(TimelineAnchoring.seconds(text: text, utf16Offset: 8, wordsPerMinute: pace) - 1.0) < 0.0001)
        #expect(abs(TimelineAnchoring.seconds(text: text, utf16Offset: (text as NSString).length, wordsPerMinute: pace) - 2.0) < 0.0001)
    }

    @Test("Pauses before the offset count and cues never do")
    func pausesAndCues() {
        let text = "uno / dos [IMAGEN: coche] tres"
        let offsetAfterCue = ("uno / dos [IMAGEN: coche]" as NSString).length
        let seconds = TimelineAnchoring.seconds(
            text: text,
            utf16Offset: offsetAfterCue,
            wordsPerMinute: 60,
            defaults: PauseDefaults(short: 0.5, long: 1)
        )
        // "uno" (1 s) + short pause (0.5 s) + "dos" (1 s); the cue is silent.
        #expect(abs(seconds - 2.5) < 0.0001)

        let end = TimelineAnchoring.seconds(
            text: text,
            utf16Offset: (text as NSString).length,
            wordsPerMinute: 60,
            defaults: PauseDefaults(short: 0.5, long: 1)
        )
        #expect(abs(end - 3.5) < 0.0001)
    }

    @Test("An offset inside a word counts the partial word")
    func partialWord() {
        let seconds = TimelineAnchoring.seconds(
            text: "abcdefghij",
            utf16Offset: 5,
            wordsPerMinute: 60
        )
        // The partial prefix is one whitespace-separated token, so it counts as
        // one spoken word rather than snapping to zero or to the whole token.
        #expect(abs(seconds - 1.0) < 0.0001)
    }

    @Test("Clamps offsets outside the text")
    func clamps() {
        let text = "uno dos"
        #expect(TimelineAnchoring.seconds(text: text, utf16Offset: -10, wordsPerMinute: 60) == 0)
        #expect(
            abs(TimelineAnchoring.seconds(text: text, utf16Offset: 10_000, wordsPerMinute: 60) - 2.0) < 0.0001
        )
    }

    @Test("Never exceeds the plain estimate")
    func boundedByEstimate() {
        let text = "uno dos tres / cuatro [RÓTULO: hola] cinco"
        let estimate = ScriptMarkup.estimateDuration(text, wordsPerMinute: 145)
        for offset in stride(from: 0, through: (text as NSString).length, by: 3) {
            let value = TimelineAnchoring.seconds(text: text, utf16Offset: offset, wordsPerMinute: 145)
            #expect(value >= 0)
            #expect(value <= estimate + 0.0001)
        }
    }

    @Test("Non-positive pace still measures pauses")
    func zeroPace() {
        let text = "uno / dos"
        let seconds = TimelineAnchoring.seconds(
            text: text,
            utf16Offset: (text as NSString).length,
            wordsPerMinute: 0,
            defaults: PauseDefaults(short: 0.5, long: 1)
        )
        #expect(abs(seconds - 0.5) < 0.0001)
    }
}
