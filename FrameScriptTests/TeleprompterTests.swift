import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class TeleprompterTests: XCTestCase {
    // MARK: Converter

    func testConverterProducesEmphasisAndPauseRuns() {
        let runs = TeleprompterConverter.runs(
            from: "This is *soft* and **strong** / then // done [2s] end"
        )

        XCTAssertEqual(runs, [
            .text("This is "),
            .emphasis("soft", strong: false),
            .text(" and "),
            .emphasis("strong", strong: true),
            .pause(seconds: 0.5),
            .text("then"),
            .pause(seconds: 1.0),
            .text("done "),
            .pause(seconds: 2.0),
            .text(" end")
        ])
    }

    func testConverterKeepsNonStandaloneSlashesAsText() {
        let runs = TeleprompterConverter.runs(from: "200 km/h on a 1/4 mile and/or more.")
        XCTAssertEqual(runs, [.text("200 km/h on a 1/4 mile and/or more.")])
        XCTAssertFalse(runs.contains { run in
            if case .pause = run {
                return true
            }
            return false
        })
    }

    func testConverterRecognisesExplicitPauseForms() {
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("2s"), 2)
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("2 s"), 2)
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("pausa"), 1)
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("pausa 2s"), 2)
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("pause 1.5"), 1.5)
        XCTAssertEqual(TeleprompterConverter.explicitPauseSeconds("3 segundos"), 3)
        XCTAssertNil(TeleprompterConverter.explicitPauseSeconds("CAM"))
        XCTAssertNil(TeleprompterConverter.explicitPauseSeconds("2x"))
        XCTAssertNil(TeleprompterConverter.explicitPauseSeconds(""))
    }

    func testConverterTurnsWholeBracketLinesIntoCues() {
        let runs = TeleprompterConverter.runs(from: "Line one\n[CAM: Wide shot]\nLine two")

        XCTAssertEqual(runs, [
            .text("Line one\n"),
            .cue(label: "CAM · Wide shot"),
            .text("\nLine two")
        ])
    }

    func testConverterIgnoresVeryShortOrUnclosedMarkers() {
        XCTAssertEqual(TeleprompterConverter.runs(from: "a * b"), [.text("a * b")])
        XCTAssertEqual(TeleprompterConverter.runs(from: "a ** b"), [.text("a ** b")])
        XCTAssertEqual(TeleprompterConverter.runs(from: "a [not a pause] b"), [.text("a [not a pause] b")])
    }

    func testConverterBuildsOneSectionPerSceneInOrder() {
        let first = TeleprompterSceneText(id: UUID(), title: "Hook", text: "Hello / world")
        let second = TeleprompterSceneText(id: UUID(), title: "Close", text: "Bye")
        let sections = TeleprompterConverter.makeSections(from: [first, second])

        XCTAssertEqual(sections.map(\.sceneID), [first.id, second.id])
        XCTAssertEqual(sections.map(\.title), ["Hook", "Close"])
        XCTAssertEqual(sections[0].runs, [.text("Hello"), .pause(seconds: 0.5), .text("world")])
        XCTAssertEqual(sections[1].runs, [.text("Bye")])
    }

    // MARK: Speed → pixels

    func testPointsPerSecondScalesLinearlyWithWordsPerMinute() {
        let baseline = TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 150, fontSize: 64, columnWidth: 900)
        let doubled = TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 300, fontSize: 64, columnWidth: 900)

        XCTAssertGreaterThan(baseline, 0)
        XCTAssertEqual(doubled, baseline * 2, accuracy: 0.000_001)
        XCTAssertEqual(TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 0, fontSize: 64, columnWidth: 900), 0)
    }

    func testNarrowerColumnOrLargerFontScrollsFasterForTheSameWPM() {
        let wide = TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 150, fontSize: 64, columnWidth: 1200)
        let narrow = TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 150, fontSize: 64, columnWidth: 420)
        let large = TeleprompterSpeed.pointsPerSecond(wordsPerMinute: 150, fontSize: 110, columnWidth: 900)

        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(large, wide)
    }

    func testWordsPerLineNeverDropsBelowOne() {
        XCTAssertEqual(TeleprompterSpeed.wordsPerLine(fontSize: 160, columnWidth: 40), 1)
    }

    // MARK: Layout

    func testSectionStartsAccumulateHeights() {
        XCTAssertEqual(
            TeleprompterLayout.sectionStarts(heights: [100, 200, 50], topInset: 64),
            [64, 164, 364]
        )
    }

    func testCurrentSectionUsesReadingLine() {
        let starts = [64.0, 164.0, 364.0]
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 0, readingLineY: 300, starts: starts),
            1
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 0, readingLineY: 20, starts: starts),
            0
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 500, readingLineY: 300, starts: starts),
            2
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 0, readingLineY: 300, starts: []),
            0
        )
    }

    func testOffsetForSectionPlacesHeaderAboveReadingLine() {
        XCTAssertEqual(
            TeleprompterLayout.offsetForSection(
                1,
                starts: [100, 800],
                readingLineY: 300,
                lead: 48
            ),
            548
        )
        XCTAssertEqual(
            TeleprompterLayout.offsetForSection(
                5,
                starts: [100, 800],
                readingLineY: 300,
                lead: 48
            ),
            0
        )
    }

    // MARK: Timing

    func testDurationEstimateAddsWordsAndPauses() {
        let runs: [TeleprompterRun] = [
            .text("one two three"),
            .emphasis("four five", strong: true),
            .pause(seconds: 2),
            .cue(label: "CAM · Wide"),
            .pause(seconds: 0.5)
        ]

        XCTAssertEqual(TeleprompterTiming.wordCount(in: runs), 5)
        XCTAssertEqual(TeleprompterTiming.pauseSeconds(in: runs), 2.5)
        XCTAssertEqual(
            TeleprompterTiming.estimatedDuration(for: runs, wordsPerMinute: 150),
            4.5,
            accuracy: 0.000_001
        )
    }

    func testSectionDurationEstimateSumsSections() {
        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "A", runs: [.text("one two three")]),
            TeleprompterSection(sceneID: UUID(), title: "B", runs: [.text("four five six"), .pause(seconds: 1)])
        ]

        XCTAssertEqual(
            TeleprompterTiming.estimatedDuration(for: sections, wordsPerMinute: 60),
            (6.0 / 60.0) * 60 + 1,
            accuracy: 0.000_001
        )
    }

    // MARK: Settings

    func testSettingsDecodeToDefaultsFromEmptyObject() throws {
        let decoded = try JSONDecoder().decode(TeleprompterSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TeleprompterSettings())
        XCTAssertEqual(decoded.wordsPerMinute, 150)
        XCTAssertEqual(decoded.readingLineFraction, 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertFalse(decoded.mirrorHorizontal)
        XCTAssertFalse(decoded.mirrorVertical)
        XCTAssertFalse(decoded.countdownEnabled)
        XCTAssertNil(decoded.preferredDisplayID)
    }

    func testSettingsRoundTrip() throws {
        let settings = TeleprompterSettings(
            wordsPerMinute: 172,
            fontSize: 88,
            columnWidth: 760,
            mirrorHorizontal: true,
            mirrorVertical: true,
            readingLineFraction: 0.42,
            countdownEnabled: true,
            preferredDisplayID: 42
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(TeleprompterSettings.self, from: data), settings)
    }

    func testSettingsDecodeClampsCorruptValues() throws {
        let json = """
        {"wordsPerMinute":9999,"fontSize":1,"columnWidth":99999,"readingLineFraction":0.95}
        """
        let decoded = try JSONDecoder().decode(TeleprompterSettings.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.wordsPerMinute, TeleprompterSettings.Limits.wordsPerMinute.upperBound)
        XCTAssertEqual(decoded.fontSize, TeleprompterSettings.Limits.fontSize.lowerBound)
        XCTAssertEqual(decoded.columnWidth, TeleprompterSettings.Limits.columnWidth.upperBound)
        XCTAssertEqual(decoded.readingLineFraction, TeleprompterSettings.Limits.readingLineFraction.upperBound)
    }

    func testSettingsStoreUsesTeleprompterNamespaceAndPersists() throws {
        XCTAssertTrue(TeleprompterSettingsStore.settingsKey.hasPrefix(TeleprompterSettingsStore.namespace))

        let suiteName = "TeleprompterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TeleprompterSettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.load(), .defaults)

        var settings = TeleprompterSettings.defaults
        settings.wordsPerMinute = 185
        settings.mirrorHorizontal = true
        store.save(settings)

        XCTAssertNotNil(defaults.data(forKey: TeleprompterSettingsStore.settingsKey))
        XCTAssertEqual(store.load(), settings)
    }

    func testSpanishAndRussianTablesCoverEveryEnglishKey() throws {
        let english = try XCTUnwrap(L10n.teleprompterStrings[.english])
        let russian = try XCTUnwrap(L10n.teleprompterStrings[.russian])

        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        XCTAssertEqual(Set(english.keys), Set(L10n.teleprompterSpanish.keys))
        XCTAssertEqual(L10n.tr("menu.teleprompter", language: .english), "Teleprompter")
        XCTAssertEqual(L10n.tr("menu.teleprompter", language: .russian), "Телесуфлёр")
    }

    // MARK: Scroll engine

    func testScrollEngineIsFrameRateIndependent() {
        var singleStep = TeleprompterScrollEngine()
        singleStep.maxOffset = 10_000
        singleStep.isPlaying = true
        singleStep.pointsPerSecond = 120

        var manySteps = singleStep
        singleStep.advance(by: 1)
        for _ in 0..<60 {
            manySteps.advance(by: 1.0 / 60.0)
        }

        XCTAssertEqual(singleStep.offset, manySteps.offset, accuracy: 0.000_001)
        XCTAssertEqual(singleStep.offset, 120, accuracy: 0.000_001)
    }

    func testScrollEngineStopsAtTheEnd() {
        var engine = TeleprompterScrollEngine()
        engine.maxOffset = 100
        engine.isPlaying = true
        engine.pointsPerSecond = 80
        engine.advance(by: 3)

        XCTAssertEqual(engine.offset, 100)
        XCTAssertFalse(engine.isPlaying)
    }

    func testScrollEngineFollowsExternalTargetWhilePaused() {
        var engine = TeleprompterScrollEngine()
        engine.maxOffset = 1_000
        engine.isPlaying = false
        engine.pointsPerSecond = 10
        engine.setTargetOffset(500)

        engine.advance(by: 0.1)
        XCTAssertEqual(engine.offset, 240, accuracy: 0.000_001)
        engine.advance(by: 1)
        XCTAssertEqual(engine.offset, 500, accuracy: 0.000_001)

        engine.setTargetOffset(nil)
        engine.advance(by: 1)
        XCTAssertEqual(engine.offset, 500, accuracy: 0.000_001)
    }

    func testScrollEngineClampsExternalTargetToBounds() {
        var engine = TeleprompterScrollEngine()
        engine.maxOffset = 300
        engine.setTargetOffset(900)
        engine.advance(by: 1)
        XCTAssertEqual(engine.offset, 300)
    }

    func testTimestampAdvanceCapsHugeDeltas() {
        var engine = TeleprompterScrollEngine()
        engine.maxOffset = 1_000
        engine.isPlaying = true
        engine.pointsPerSecond = 100
        engine.advance(to: 10)
        engine.advance(to: 20)

        XCTAssertEqual(engine.offset, 25, accuracy: 0.000_001)
    }

    func testSeekClampsAndResetsPlaybackPosition() {
        var engine = TeleprompterScrollEngine()
        engine.maxOffset = 200
        engine.seek(to: -50)
        XCTAssertEqual(engine.offset, 0)
        engine.seek(to: 500)
        XCTAssertEqual(engine.offset, 200)
    }

    // MARK: Window model

    func testModelJumpsToStartingSceneAfterFirstLayout() async throws {
        let suiteName = "TeleprompterModel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one two")]),
            TeleprompterSection(sceneID: UUID(), title: "Two", runs: [.text("three four")]),
            TeleprompterSection(sceneID: UUID(), title: "Three", runs: [.text("five six")])
        ]
        let model = TeleprompterModel(
            sections: sections,
            startingSectionIndex: 2,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: defaults)
        )
        defer { model.stop() }

        XCTAssertEqual(model.currentSectionIndex, 2)
        XCTAssertEqual(model.offset, 0)

        model.updateViewport(height: 600)
        model.updateContentHeight(1500)
        model.updateSectionHeights([0: 400, 1: 400, 2: 400])
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertGreaterThan(model.offset, 0)
        XCTAssertEqual(model.currentSectionIndex, 2)
    }

    func testModelStaysAtTopWhenFirstSceneIsSelected() async throws {
        let suiteName = "TeleprompterModel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one two")]),
            TeleprompterSection(sceneID: UUID(), title: "Two", runs: [.text("three four")])
        ]
        let model = TeleprompterModel(
            sections: sections,
            startingSectionIndex: 0,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: defaults)
        )
        defer { model.stop() }

        model.updateViewport(height: 600)
        model.updateSectionHeights([0: 400, 1: 400])
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(model.offset, 0)
        XCTAssertEqual(model.currentSectionIndex, 0)
    }
}
