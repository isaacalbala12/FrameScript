import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class TeleprompterTests: XCTestCase {
    // MARK: Content builder

    func testContentBuilderUsesSharedMarkupParser() {
        let scene = TeleprompterSceneText(
            id: UUID(),
            title: "Hook",
            text: "Hola *mundo* y **fuerza** / seguimos [2s]\n[CAM: Plano medio]\nFinal"
        )
        let sections = TeleprompterContentBuilder.sections(from: [scene])

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].sceneID, scene.id)
        XCTAssertEqual(sections[0].title, "Hook")
        XCTAssertTrue(sections[0].runs.contains(.emphasis("mundo", level: .emphasis)))
        XCTAssertTrue(sections[0].runs.contains(.emphasis("fuerza", level: .strong)))
        XCTAssertTrue(sections[0].runs.contains(.pause(0.5)))
        XCTAssertTrue(sections[0].runs.contains(.pause(2)))
        XCTAssertTrue(sections[0].runs.contains(.cue("CAM")))
        XCTAssertFalse(sections[0].runs.contains(.cue("CAM · Plano medio")))
    }

    func testContentBuilderKeepsScenesInOrder() {
        let first = TeleprompterSceneText(id: UUID(), title: "One", text: "Hello")
        let second = TeleprompterSceneText(id: UUID(), title: "Two", text: "Bye")
        let sections = TeleprompterContentBuilder.sections(from: [first, second])

        XCTAssertEqual(sections.map(\.sceneID), [first.id, second.id])
        XCTAssertEqual(sections.map(\.title), ["One", "Two"])
    }

    // MARK: Attribution

    func testAttributedBuilderAddsNoBlankLineAfterCue() {
        let sections = [
            TeleprompterSection(
                sceneID: UUID(),
                title: "One",
                runs: [.text("Line\n"), .cue("CAM"), .text("\nNext")]
            )
        ]
        let document = TeleprompterAttributedStringBuilder.build(sections: sections, fontSize: 64)
        let string = document.attributedString.string

        XCTAssertTrue(string.contains("Line\n▸ CAM\nNext"), "Unexpected cue spacing: \(string)")
        XCTAssertFalse(string.contains("▸ CAM\n\nNext"))
        XCTAssertEqual(document.visibleCharacterCounts, [9])
    }

    func testAttributedBuilderRendersPauseGapAndCountsOnlyVisibleText() {
        let sections = [
            TeleprompterSection(
                sceneID: UUID(),
                title: "One",
                runs: [.text("uno"), .pause(2), .emphasis("dos", level: .strong)]
            )
        ]
        let document = TeleprompterAttributedStringBuilder.build(sections: sections, fontSize: 64)
        let string = document.attributedString.string

        XCTAssertTrue(string.contains("❚❚"))
        XCTAssertTrue(string.contains("2.0s"))
        XCTAssertEqual(document.visibleCharacterCounts, [6])
        XCTAssertEqual(document.sectionHeaderLocations.count, 1)
    }

    func testAttributedBuilderStripsOnlyOneLineBreakAfterBlock() {
        let sections = [
            TeleprompterSection(
                sceneID: UUID(),
                title: "One",
                runs: [.cue("CAM"), .text("\n\nAfter")]
            )
        ]
        let string = TeleprompterAttributedStringBuilder.build(sections: sections, fontSize: 64)
            .attributedString.string

        XCTAssertTrue(string.contains("▸ CAM\n\nAfter"), "Expected one blank line: \(string)")
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
            TeleprompterLayout.currentSectionIndex(offset: 0, readingContentY: 300, starts: starts),
            1
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 0, readingContentY: 20, starts: starts),
            0
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 500, readingContentY: 300, starts: starts),
            2
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(offset: 0, readingContentY: 300, starts: []),
            0
        )
    }

    func testOffsetForSectionPlacesHeaderAboveReadingLine() {
        XCTAssertEqual(
            TeleprompterLayout.offsetForSection(
                1,
                starts: [100, 800],
                readingContentY: 300,
                mirrorVertical: false,
                lead: 48
            ),
            548
        )
        XCTAssertEqual(
            TeleprompterLayout.offsetForSection(
                1,
                starts: [100, 800],
                readingContentY: 300,
                mirrorVertical: true,
                lead: 48
            ),
            452
        )
        XCTAssertEqual(
            TeleprompterLayout.offsetForSection(
                5,
                starts: [100, 800],
                readingContentY: 300,
                mirrorVertical: false,
                lead: 48
            ),
            0
        )
    }

    func testVerticalMirrorFlipsTheReadingContentLine() {
        XCTAssertEqual(
            TeleprompterLayout.readingContentY(
                viewportHeight: 900,
                fraction: 1.0 / 3.0,
                mirrorVertical: false
            ),
            300,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            TeleprompterLayout.readingContentY(
                viewportHeight: 900,
                fraction: 1.0 / 3.0,
                mirrorVertical: true
            ),
            600,
            accuracy: 0.000_001
        )
    }

    func testMirroredReadingLineSelectsTheSceneVisibleUnderTheGuide() {
        let starts = [64.0, 564.0, 1064.0]
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(
                offset: 0,
                readingContentY: TeleprompterLayout.readingContentY(
                    viewportHeight: 900,
                    fraction: 1.0 / 3.0,
                    mirrorVertical: true
                ),
                starts: starts
            ),
            1
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(
                offset: 0,
                readingContentY: TeleprompterLayout.readingContentY(
                    viewportHeight: 900,
                    fraction: 1.0 / 3.0,
                    mirrorVertical: false
                ),
                starts: starts
            ),
            0
        )
    }

    func testSceneProgressAndContentYAreInverses() {
        let progress = TeleprompterLayout.sceneProgress(
            offset: 300,
            readingContentY: 200,
            start: 100,
            height: 400
        )
        XCTAssertEqual(progress, 1, accuracy: 0.000_001)

        let y = TeleprompterLayout.contentY(
            forCharacterOffset: 50,
            characterCount: 100,
            start: 100,
            height: 400
        )
        XCTAssertEqual(y, 300, accuracy: 0.000_001)
    }

    func testSectionHeightsUseTextBottomForLastSection() {
        XCTAssertEqual(
            TeleprompterTextRenderer.heights(starts: [64, 500, 900], textBottom: 1200),
            [436, 400, 300]
        )
    }

    func testTextRendererReportsIncreasingSectionStarts() throws {
        let sections = (0..<3).map { index in
            TeleprompterSection(
                sceneID: UUID(),
                title: "Scene \(index + 1)",
                runs: (0..<8).map { line in
                    .text("Line \(line + 1) of scene \(index + 1) with enough words to wrap in the column.")
                }
            )
        }
        let renderer = TeleprompterTextRenderer(
            frame: NSRect(x: 0, y: 0, width: 1200, height: 800)
        )
        var metrics: TeleprompterTextMetrics?
        renderer.render(
            sections: sections,
            fontSize: 64,
            columnWidth: 900,
            viewportSize: CGSize(width: 1200, height: 800),
            readingLineFraction: 1.0 / 3.0,
            mirrorVertical: false,
            onMetrics: { metrics = $0 }
        )

        let result = try XCTUnwrap(metrics)
        XCTAssertEqual(result.sectionStarts.count, 3)
        XCTAssertEqual(result.sectionHeights.count, 3)
        XCTAssertEqual(result.visibleCharacterCounts.count, 3)
        XCTAssertLessThan(result.sectionStarts[0], result.sectionStarts[1])
        XCTAssertLessThan(result.sectionStarts[1], result.sectionStarts[2])
        XCTAssertGreaterThan(result.contentHeight, 800)
        XCTAssertGreaterThan(result.sectionHeights[0], 0)
    }

    // MARK: Timing

    func testDurationEstimateAddsWordsAndPauses() {
        let runs: [MarkupRun] = [
            .text("one two three"),
            .emphasis("four five", level: .strong),
            .pause(2),
            .cue("CAM"),
            .pause(0.5)
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
            TeleprompterSection(sceneID: UUID(), title: "B", runs: [.text("four five six"), .pause(1)])
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
        XCTAssertGreaterThanOrEqual(TeleprompterSettings.Limits.readingLineFraction.upperBound, 2.0 / 3.0)
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

    func testLocalizationTablesCoverEveryLanguage() throws {
        let english = try XCTUnwrap(L10n.teleprompterStrings[.english])
        let russian = try XCTUnwrap(L10n.teleprompterStrings[.russian])

        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        XCTAssertEqual(Set(english.keys), Set(L10n.teleprompterSpanish.keys))
        XCTAssertEqual(L10n.tr("menu.teleprompter", language: .english), "Teleprompter")
        XCTAssertEqual(L10n.tr("menu.teleprompter", language: .russian), "Телесуфлёр")
        XCTAssertEqual(L10n.tr("menu.teleprompter", language: .spanish), "Teleprompter")
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

    func testModelWaitsForLayoutThenJumpsToStartingScene() throws {
        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one two")]),
            TeleprompterSection(sceneID: UUID(), title: "Two", runs: [.text("three four")]),
            TeleprompterSection(sceneID: UUID(), title: "Three", runs: [.text("five six")])
        ]
        let model = try makeModel(sections: sections, start: 2)

        XCTAssertTrue(model.isAwaitingLayout)
        XCTAssertEqual(model.offset, 0)

        model.updateViewport(width: 1200, height: 600)
        model.updateTextMetrics(metrics(
            contentHeight: 1600,
            starts: [64, 564, 1064],
            heights: [500, 500, 436],
            counts: [7, 10, 8]
        ))

        XCTAssertFalse(model.isAwaitingLayout)
        XCTAssertGreaterThan(model.offset, 0)
        XCTAssertEqual(model.currentSectionIndex, 2)
    }

    func testFontSizeChangeKeepsTheReadingAnchor() throws {
        let first = TeleprompterSceneText(id: UUID(), title: "One", text: String(repeating: "uno dos tres ", count: 40))
        let second = TeleprompterSceneText(id: UUID(), title: "Two", text: String(repeating: "cuatro cinco ", count: 40))
        let model = try makeModel(scenes: [first, second], start: 0)

        model.updateViewport(width: 1200, height: 600)
        model.updateTextMetrics(metrics(
            contentHeight: 1600,
            starts: [64, 864],
            heights: [800, 736],
            counts: [first.text.count, second.text.count]
        ))
        model.restore(anchor: TeleprompterReadingAnchor(sceneID: first.id, characterOffset: 150))
        let before = try XCTUnwrap(model.readingAnchor(
            mirrorVertical: false,
            readingLineFraction: model.settings.readingLineFraction
        ))
        XCTAssertEqual(before.sceneID, first.id)
        XCTAssertGreaterThanOrEqual(before.characterOffset, 149)
        XCTAssertLessThanOrEqual(before.characterOffset, 151)

        model.settings.fontSize = 96
        XCTAssertTrue(model.isAwaitingLayout)
        let revision = model.layoutRevision
        model.updateTextMetrics(metrics(
            contentHeight: 2300,
            starts: [64, 1264],
            heights: [1200, 1036],
            counts: [first.text.count, second.text.count]
        ))

        XCTAssertFalse(model.isAwaitingLayout)
        XCTAssertGreaterThan(revision, 0)
        let after = try XCTUnwrap(model.readingAnchor(
            mirrorVertical: false,
            readingLineFraction: model.settings.readingLineFraction
        ))
        XCTAssertEqual(after.sceneID, first.id)
        XCTAssertGreaterThanOrEqual(after.characterOffset, 148)
        XCTAssertLessThanOrEqual(after.characterOffset, 152)
    }

    func testJumpWhileAwaitingLayoutUsesFreshHeights() throws {
        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one")]),
            TeleprompterSection(sceneID: UUID(), title: "Two", runs: [.text("two")]),
            TeleprompterSection(sceneID: UUID(), title: "Three", runs: [.text("three")])
        ]
        let model = try makeModel(sections: sections, start: 0)
        model.updateViewport(width: 1200, height: 600)
        model.updateTextMetrics(metrics(
            contentHeight: 1600,
            starts: [64, 564, 1064],
            heights: [500, 500, 436],
            counts: [3, 3, 5]
        ))

        model.settings.fontSize = 96
        XCTAssertTrue(model.isAwaitingLayout)
        model.nextSection()
        XCTAssertEqual(model.currentSectionIndex, 0, "Jump must wait for fresh heights")

        model.updateTextMetrics(metrics(
            contentHeight: 2400,
            starts: [64, 844, 1624],
            heights: [780, 780, 700],
            counts: [3, 3, 5]
        ))

        XCTAssertEqual(model.currentSectionIndex, 1)
        XCTAssertTrue(model.isAwaitingLayout == false)
    }

    func testLiveRefreshUpdatesTextAndPreservesSceneAndCharacter() throws {
        var currentScenes = [
            TeleprompterSceneText(id: UUID(), title: "One", text: String(repeating: "uno dos ", count: 30)),
            TeleprompterSceneText(id: UUID(), title: "Two", text: String(repeating: "tres cuatro ", count: 30))
        ]
        let provider: TeleprompterSceneProvider = { currentScenes }
        let model = try makeModel(scenes: currentScenes, start: 0, provider: provider)

        model.updateViewport(width: 1200, height: 600)
        let firstID = currentScenes[0].id
        model.updateTextMetrics(metrics(
            contentHeight: 1600,
            starts: [64, 864],
            heights: [800, 736],
            counts: [currentScenes[0].text.count, currentScenes[1].text.count]
        ))
        model.restore(anchor: TeleprompterReadingAnchor(sceneID: firstID, characterOffset: 100))
        let before = try XCTUnwrap(model.readingAnchor(
            mirrorVertical: false,
            readingLineFraction: model.settings.readingLineFraction
        ))

        currentScenes[0] = TeleprompterSceneText(
            id: firstID,
            title: "One revised",
            text: String(repeating: "uno dos ", count: 30) + " texto añadido"
        )
        model.refreshFromProvider()

        XCTAssertEqual(model.sections[0].title, "One revised")
        XCTAssertTrue(model.isAwaitingLayout)

        model.updateTextMetrics(metrics(
            contentHeight: 1660,
            starts: [64, 924],
            heights: [860, 736],
            counts: [currentScenes[0].text.count, currentScenes[1].text.count]
        ))

        XCTAssertFalse(model.isAwaitingLayout)
        let after = try XCTUnwrap(model.readingAnchor(
            mirrorVertical: false,
            readingLineFraction: model.settings.readingLineFraction
        ))
        XCTAssertEqual(after.sceneID, before.sceneID)
        XCTAssertGreaterThanOrEqual(after.characterOffset, before.characterOffset - 2)
        XCTAssertLessThanOrEqual(after.characterOffset, before.characterOffset + 2)
    }

    func testRefreshWithoutProviderIsANoOp() throws {
        let sections = [TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one")])]
        let model = try makeModel(sections: sections, start: 0)
        let before = model.sections
        model.refreshFromProvider()
        XCTAssertEqual(model.sections, before)
    }

    // MARK: Helpers

    private func makeModel(
        scenes: [TeleprompterSceneText],
        start: Int,
        provider: TeleprompterSceneProvider? = nil
    ) throws -> TeleprompterModel {
        let sections = TeleprompterContentBuilder.sections(from: scenes)
        return try makeModel(sections: sections, start: start, provider: provider)
    }

    private func makeModel(
        sections: [TeleprompterSection],
        start: Int,
        provider: TeleprompterSceneProvider? = nil
    ) throws -> TeleprompterModel {
        let suiteName = "TeleprompterModel-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TeleprompterModel(
            sections: sections,
            startingSectionIndex: start,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: defaults),
            sceneProvider: provider
        )
        addTeardownBlock {
            model.stop()
        }
        return model
    }

    private func metrics(
        contentHeight: Double,
        starts: [Double],
        heights: [Double],
        counts: [Int]
    ) -> TeleprompterTextMetrics {
        TeleprompterTextMetrics(
            contentHeight: contentHeight,
            sectionStarts: starts,
            sectionHeights: heights,
            visibleCharacterCounts: counts
        )
    }
}
