import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Cross-review regressions – published compare")
struct PublishedCompareCrossReviewTests {
    private func srt(_ text: String) throws -> [SubtitleSegment] {
        try SubtitleParser.parseSRT(text)
    }

    private func vtt(_ text: String) throws -> [SubtitleSegment] {
        try SubtitleParser.parseWebVTT(text)
    }

    // #1 / #2: only genuine rolling cues are de-duplicated.
    @Test func karaokeInlineTimestampsKeepEveryLine() throws {
        let text = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        Hello<00:00:01.200><c> world</c>
        Second<00:00:02.000><c> line</c>
        """
        let segments = try vtt(text)

        #expect(segments.count == 1)
        #expect(segments[0].text == "Hello world Second line")
    }

    @Test func nonYouTubeTwoLineCueWithYouTubeSettingsKeepsEveryLine() throws {
        let text = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000 align:start position:0%
        First line
        Second line
        """
        let segments = try vtt(text)

        #expect(segments.count == 1)
        #expect(segments[0].text == "First line Second line")
    }

    @Test func repeatedNormalDurationCuesAreNotSettleCues() throws {
        let text = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500 align:start position:0%
        no no no

        00:00:01.500 --> 00:00:03.000 align:start position:0%
        no no no
        """
        let segments = try vtt(text)

        #expect(segments.count == 2)
        #expect(segments.map(\.text) == ["no no no", "no no no"])
    }

    // #3: whitespace-only lines may separate cues.
    @Test func whitespaceOnlyLineSeparatesWebVTTCues() throws {
        let text = [
            "WEBVTT",
            "",
            "00:00:00.000 --> 00:00:02.000",
            "First",
            " ",
            "00:00:03.000 --> 00:00:04.000",
            "Second"
        ].joined(separator: "\n")
        let segments = try vtt(text)

        #expect(segments.count == 2)
        #expect(segments.map(\.text) == ["First", "Second"])
    }

    // #4: ratio positions must never use thousands grouping.
    @Test func quotedRatioPositionWithCommaIsTreatedAsDecimal() throws {
        let text = """
        elapsedVideoTimeRatio,audienceWatchRatio
        "0,012",0.98
        "0,500",0.60
        "1,000",0.42
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 300)

        #expect(result.samples.count == 3)
        #expect(approximatelyEqual(result.samples[0].position, 3.6, tolerance: 0.01))
        #expect(approximatelyEqual(result.samples[1].position, 150))
        #expect(approximatelyEqual(result.samples[2].position, 300))
    }

    // #5: overflow fields from an unquoted decimal comma are rejoined.
    @Test func unquotedDecimalCommaInCommaFileIsRepaired() throws {
        let text = """
        Video position,Absolute audience retention (%)
        15,84,2
        30,76,5
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 120)

        #expect(result.samples.count == 2)
        #expect(approximatelyEqual(result.samples[0].position, 15))
        #expect(approximatelyEqual(result.samples[0].retention, 0.842))
        #expect(approximatelyEqual(result.samples[1].retention, 0.765))
    }

    // #6: headerless data with an index column uses the retention shape.
    @Test func headerlessIndexColumnIsNotPickedAsPosition() throws {
        let text = """
        1,0,100
        2,15,84
        3,30,76
        """
        let result = try RetentionCSVParser.parsePastedColumns(text, videoDuration: 30)

        #expect(result.samples.count == 3)
        #expect(approximatelyEqual(result.samples[0].position, 0))
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[2].position, 30))
        #expect(approximatelyEqual(result.samples[0].retention, 1.0))
        #expect(approximatelyEqual(result.samples[1].retention, 0.84))
        #expect(approximatelyEqual(result.samples[2].retention, 0.76))
    }

    // #7: a multi-word whitespace header still selects the two data columns.
    @Test func multiWordWhitespaceHeaderPasteParses() throws {
        let text = """
        Video position  Audience retention
        0:00  100%
        0:15  84%
        """
        let result = try RetentionCSVParser.parsePastedColumns(text)

        #expect(result.samples.count == 2)
        #expect(approximatelyEqual(result.samples[0].position, 0))
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[1].retention, 0.84))
    }

    // #8: reordered scenes get the right timings and coverage.
    @Test func reorderedScenesKeepTheirOwnContent() {
        let scenes = [
            SceneScript(id: "a", text: "alpha bravo charlie delta"),
            SceneScript(id: "b", text: "echo foxtrot golf hotel")
        ]
        let transcript = [
            SubtitleSegment(start: 0, end: 4, text: "echo foxtrot golf hotel"),
            SubtitleSegment(start: 4, end: 8, text: "alpha bravo charlie delta")
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)
        let a = alignment.scenes[0]
        let b = alignment.scenes[1]

        #expect(a.coverage == 1)
        #expect(b.coverage == 1)
        #expect(approximatelyEqual(a.start, 4))
        #expect(approximatelyEqual(a.end, 8))
        #expect(approximatelyEqual(b.start, 0))
        #expect(approximatelyEqual(b.end, 4))
        #expect(alignment.totalMatchedWords == 8)
    }

    // #9: large scripts must not scan every word once per scene.
    @Test func largeScriptWithEmptyTranscriptIsLinearAndCorrect() {
        let sceneCount = 360
        let wordsPerScene = 80
        var scenes: [SceneScript] = []
        scenes.reserveCapacity(sceneCount)

        for sceneIndex in 0..<sceneCount {
            let words = (0..<wordsPerScene).map { "s\(sceneIndex)w\($0)" }
            scenes.append(SceneScript(id: "s\(sceneIndex)", text: words.joined(separator: " ")))
        }

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let alignment = TranscriptAligner().align(scenes: scenes, transcript: [])
            #expect(alignment.scenes.count == sceneCount)
            #expect(alignment.scenes.allSatisfy { $0.coverage == 0 })
            #expect(alignment.scenes.allSatisfy { $0.scriptWordCount == wordsPerScene })
        }

        #expect(elapsed < .seconds(1))
    }

    // #10: unmatched '<' is literal text.
    @Test func unmatchedLessThanIsLiteral() throws {
        let segments = try srt("""
        1
        00:00:00,000 --> 00:00:02,000
        I <3 this

        2
        00:00:02,000 --> 00:00:04,000
        three < 5 is true
        """)

        #expect(segments.count == 2)
        #expect(segments[0].text.contains("<3"))
        #expect(segments[1].text.contains("< 5"))
    }

    // #11: a numeric payload line is not mistaken for a cue number.
    @Test func numericPayloadSurvivesMissingBlankLine() throws {
        let segments = try srt("""
        1
        00:00:00,000 --> 00:00:02,000
        Hello
        2024
        00:00:03,000 --> 00:00:05,000
        World
        """)

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello 2024")
        #expect(segments[1].text == "World")
    }

    @Test func realCueIndexIsStillDroppedWithoutBlankLine() throws {
        let segments = try srt("""
        1
        00:00:00,000 --> 00:00:02,000
        Hello
        2
        00:00:03,000 --> 00:00:05,000
        World
        """)

        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello")
        #expect(segments[1].text == "World")
    }

    // #12: validation and argv use the same normalized URL.
    @Test func ytDlpNormalizesURLForValidationAndArguments() {
        let command = YtDlpSubtitleCommand(
            url: "  https://example.com/watch?v=abc  ",
            language: .english
        )

        #expect(command.url == "https://example.com/watch?v=abc")
        #expect(command.arguments.last == "https://example.com/watch?v=abc")
        #expect(command.validationMessage == nil)
        #expect(YtDlpSubtitleCommand(url: "https://", language: .english).validationMessage != nil)
        #expect(YtDlpSubtitleCommand(url: "https:foo", language: .english).validationMessage != nil)
    }

    // Suspicions.
    @Test func zeroDurationSceneIsPreserved() {
        let samples = [
            RetentionSample(position: 0, retention: 1.0),
            RetentionSample(position: 10, retention: 0.7),
            RetentionSample(position: 20, retention: 0.4)
        ]
        let scenes = [
            RetentionScene(id: "s1", start: 0, end: 10),
            RetentionScene(id: "s2", start: 10, end: 10),
            RetentionScene(id: "s3", start: 10, end: 20)
        ]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(result.scenes.count == 3)
        #expect(approximatelyEqual(result.scenes[1].averageRetention, 0.7))
        #expect(approximatelyEqual(result.scenes[1].delta, 0))
        #expect(result.scenes[1].sampleCount == 0)
    }

    @Test func tinyHookLossIsNotReported() {
        let samples = [
            RetentionSample(position: 0, retention: 1.0),
            RetentionSample(position: 30, retention: 0.999),
            RetentionSample(position: 60, retention: 0.5)
        ]
        let scenes = [RetentionScene(id: "s1", start: 0, end: 60)]

        let result = RetentionAnalysis.analyze(samples: samples, scenes: scenes)

        #expect(result.hookLoss == nil)
    }

    @Test func headerlessRetentionAboveOneHundredPercentStaysRatio() throws {
        let text = """
        0.01,1.60
        0.50,1.20
        1.00,0.90
        """
        let result = try RetentionCSVParser.parsePastedColumns(text, videoDuration: 300)

        #expect(result.retentionUnit == .ratio)
        #expect(result.samples.count == 3)
        #expect(approximatelyEqual(result.samples[0].retention, 1.6))
        #expect(approximatelyEqual(result.samples[1].retention, 1.2))
        #expect(approximatelyEqual(result.samples[2].retention, 0.9))
    }

    @Test func numericCharacterEntitiesAreDecoded() throws {
        let text = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        It&#39;s fine.
        """
        let segments = try vtt(text)

        #expect(segments.count == 1)
        #expect(segments[0].text == "It's fine.")
    }

    @Test func webVTTWithoutBlankLineAfterHeaderParses() throws {
        let text = """
        WEBVTT
        00:00:00.000 --> 00:00:01.000
        Hi there
        """
        let segments = try vtt(text)

        #expect(segments.count == 1)
        #expect(segments[0].text == "Hi there")
    }
}
