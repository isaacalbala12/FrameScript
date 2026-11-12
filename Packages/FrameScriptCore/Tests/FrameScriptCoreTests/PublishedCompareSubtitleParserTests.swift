import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Published compare – subtitle parsing")
struct PublishedCompareSubtitleParserTests {
    @Test func parsesSRTWithCueNumbersAndCommaTimestamps() throws {
        let text = try PublishedCompareFixtures.text("sample", extension: "srt")
        let segments = try SubtitleParser.parseSRT(text)

        #expect(segments.count == 4)
        #expect(approximatelyEqual(segments[0].start, 0, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[0].end, 3.5, tolerance: 0.0001))
        #expect(segments[0].text.contains("Hola"))
        #expect(segments[0].words.count == 4)
        #expect(segments[1].text.contains("Assetto Corsa EVO"))
        #expect(segments[1].words.count == 11)
        #expect(segments[2].text.contains("[risas]"))
        #expect(segments[3].words.count == 4)
        #expect(approximatelyEqual(segments[3].end, 13, tolerance: 0.0001))
    }

    @Test func parsesSRTWithoutCueIndexesAndWithDotMilliseconds() throws {
        let text = """
        00:00:01.500 --> 00:00:03.250
        Primera
        Segunda

        00:03.250 --> 00:04.000
        Tercera
        """
        let segments = try SubtitleParser.parseSRT(text)

        #expect(segments.count == 2)
        #expect(approximatelyEqual(segments[0].start, 1.5))
        #expect(approximatelyEqual(segments[0].end, 3.25))
        #expect(segments[0].text == "Primera Segunda")
        #expect(approximatelyEqual(segments[1].start, 3.25))
        #expect(segments[1].text == "Tercera")
    }

    @Test func rejectsEmptySRT() {
        #expect(throws: SubtitleParserError.emptyInput) {
            try SubtitleParser.parseSRT("")
        }
    }

    @Test func parsesWebVTTWithNotesEntitiesAndShortTimestamps() throws {
        let text = try PublishedCompareFixtures.text("sample", extension: "vtt")
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(segments.count == 2)
        #expect(approximatelyEqual(segments[0].start, 1))
        #expect(approximatelyEqual(segments[0].end, 4))
        #expect(segments[0].text == "Hola bienvenidos.")
        #expect(approximatelyEqual(segments[1].start, 4))
        #expect(approximatelyEqual(segments[1].end, 6.5))
        #expect(segments[1].text == "Esto es WebVTT.")
    }

    @Test func throwsWhenWebVTTHasNoTimedCues() {
        #expect(throws: SubtitleParserError.noCuesFound) {
            try SubtitleParser.parseWebVTT("WEBVTT\n\nNOTE only a note\n")
        }
    }

    @Test func detectsSubtitleFormatFromContent() {
        #expect(SubtitleFormat.detect(from: "\u{FEFF}WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHi") == .webVTT)
        #expect(SubtitleFormat.detect(from: "1\n00:00:00,000 --> 00:00:01,000\nHola") == .srt)
    }

    @Test func youtubeAutoCaptionsAreDeduplicatedIntoCleanLines() throws {
        let text = try PublishedCompareFixtures.text("youtube-auto-en", extension: "vtt")
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(segments.count == 4)
        #expect(segments.map(\.text) == [
            "welcome back to the channel",
            "today we're going to test",
            "the new build on track",
            "let's go"
        ])
    }

    @Test func youtubeAutoCaptionsUseInlineWordTimestamps() throws {
        let text = try PublishedCompareFixtures.text("youtube-auto-en", extension: "vtt")
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(approximatelyEqual(segments[0].start, 0, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[0].end, 2.710, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[1].start, 2.720, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[1].end, 5.679, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[3].start, 8.240, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[3].end, 11.000, tolerance: 0.0001))
        #expect(segments[0].words.first?.text == "welcome")
        #expect(approximatelyEqual(segments[0].words.first?.end, 0.160, tolerance: 0.0001))
        #expect(segments[0].words.last?.text == "channel")
    }

    @Test func youtubeAutoSpanishKeepsAccentsAndQuestionMarks() throws {
        let text = try PublishedCompareFixtures.text("youtube-auto-es", extension: "vtt")
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(segments.count == 3)
        #expect(segments[0].text == "hoy probamos el nuevo mod")
        #expect(segments[1].text == "en el circuito de Spa")
        #expect(segments[2].text == "¿vamos a por la vuelta rápida?")
        #expect(segments[2].words.first?.text == "¿vamos")
        #expect(approximatelyEqual(segments[2].start, 6.7, tolerance: 0.0001))
        #expect(approximatelyEqual(segments[2].end, 9.0, tolerance: 0.0001))
    }

    @Test func youtubeRollingDeduplicationWorksWithoutInlineTimestamps() throws {
        let text = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.000 --> 00:00:02.000 align:start position:0%
        hello world

        00:00:02.000 --> 00:00:02.010 align:start position:0%
        hello world

        00:00:02.010 --> 00:00:04.000 align:start position:0%
        hello world
        next line
        """
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(segments.count == 2)
        #expect(segments.map(\.text) == ["hello world", "next line"])
        #expect(approximatelyEqual(segments[1].start, 2.010, tolerance: 0.0001))
    }

    @Test func youtubeAutoCaptionsKeepAGenuineRepeatedPhrase() throws {
        let text = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.000 --> 00:00:02.000 align:start position:0%
        no<00:00:00.100><c> no</c><00:00:00.300><c> no</c>

        00:00:02.000 --> 00:00:04.000 align:start position:0%
        no<00:00:02.100><c> no</c><00:00:02.300><c> no</c>
        """
        let segments = try SubtitleParser.parseWebVTT(text)

        #expect(segments.count == 2)
        #expect(segments.map(\.text) == ["no no no", "no no no"])
    }
}
