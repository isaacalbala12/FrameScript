import Foundation
import Testing
@testable import FrameScriptCore

@Suite("TimelineText")
struct TimelineTextTests {
    @Test func blankLinesSplitParagraphsAndSingleBreaksStayInside() {
        let text = "Primer párrafo\ncon dos líneas.\n\nSegundo párrafo.\nTercera línea."
        let paragraphs = TimelineText.paragraphs(in: text)

        #expect(paragraphs.map(\.text) == [
            "Primer párrafo\ncon dos líneas.",
            "Segundo párrafo.\nTercera línea."
        ])
        #expect(paragraphs[0].range == TimelineSourceRange(location: 0, length: 30))
        #expect(paragraphs[1].range.location == 32)
        #expect(paragraphs[1].range.end == (text as NSString).length)
    }

    @Test func crlfBlankLineSplitsAndRangesStayInUTF16() {
        let text = "Uno\r\n\r\nDos"
        let paragraphs = TimelineText.paragraphs(in: text)

        #expect(paragraphs.map(\.text) == ["Uno", "Dos"])
        #expect(paragraphs[0].range == TimelineSourceRange(location: 0, length: 3))
        #expect(paragraphs[1].range == TimelineSourceRange(location: 7, length: 3))
    }

    @Test func trimsSurroundingWhitespace() {
        let text = "   Hola   \n\n \t Adiós \t "
        let paragraphs = TimelineText.paragraphs(in: text)

        #expect(paragraphs.map(\.text) == ["Hola", "Adiós"])
        #expect(paragraphs[0].range == TimelineSourceRange(location: 3, length: 4))
    }

    @Test func whitespaceOnlyTextHasNoParagraphs() {
        #expect(TimelineText.paragraphs(in: "").isEmpty)
        #expect(TimelineText.paragraphs(in: " \n\r\n\t ").isEmpty)
    }

    @Test func emojiAndAccentsUseUTF16Locations() {
        let text = "🎬 Uno\n\nDos 👋"
        let paragraphs = TimelineText.paragraphs(in: text)

        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].range == TimelineSourceRange(location: 0, length: 6))
        #expect(paragraphs[1].range.location == 8)
        #expect(paragraphs[1].text == "Dos 👋")
    }
}

@Suite("TimelineLayout")
struct TimelineLayoutTests {
    private let wordsPerMinute60 = TimelineConfiguration(wordsPerMinute: 60, pauseDefaults: PauseDefaults(short: 0.5, long: 1))

    @Test func oneSceneWithoutTakesUsesTheMarkupEstimate() {
        let scene = makeScene(text: "uno dos tres cuatro cinco")
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)

        #expect(layout.totalDuration == 5)
        #expect(layout.scenes.count == 1)
        #expect(layout.scenes[0].start == 0)
        #expect(layout.scenes[0].end == 5)
        #expect(layout.scenes[0].estimatedDuration == 5)
        #expect(layout.scenes[0].realDuration == nil)
        #expect(layout.scenes[0].hasRealTake == false)

        let scenes = layout.blocks(on: .scenes)
        #expect(scenes.count == 1)
        #expect(scenes[0].start == 0)
        #expect(scenes[0].end == 5)
        #expect(scenes[0].label == "Escena")
    }

    @Test func paragraphBlocksMatchParagraphBoundaries() {
        let text = "uno dos tres\n\ncuatro cinco"
        let scene = makeScene(text: text)
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let narration = layout.blocks(on: .narration)

        #expect(narration.count == 2)
        #expect(narration[0].start == 0)
        #expect(narration[0].end == 3)
        #expect(narration[0].sourceRange == TimelineSourceRange(location: 0, length: 12))
        #expect(narration[1].start == 3)
        #expect(narration[1].end == 5)
        #expect(narration[1].label == "cuatro cinco")
    }

    @Test func pauseBlocksUseMarkupPositionsAndDurations() {
        let scene = makeScene(text: "Hola / mundo [pausa 2s] fin")
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let pauses = layout.blocks(on: .pauses)

        #expect(pauses.count == 2)
        #expect(abs(pauses[0].start - 1) < 0.0001)
        #expect(abs(pauses[0].duration - 0.5) < 0.0001)
        #expect(pauses[0].pauseSeconds == 0.5)
        #expect(abs(pauses[1].start - 2.5) < 0.0001)
        #expect(abs(pauses[1].duration - 2) < 0.0001)
        #expect(pauses[1].pauseSeconds == 2)
        #expect(layout.totalDuration == 5.5)
    }

    @Test func pauseAtOffsetReturnsThePauseStartAndEndIncludesIt() {
        let scene = makeScene(text: "uno / dos")
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let narration = layout.blocks(on: .narration)
        let pauses = layout.blocks(on: .pauses)

        #expect(narration.count == 1)
        #expect(abs(pauses[0].start - 1) < 0.0001)
        // The one narration paragraph spans the pause in the same scene time.
        #expect(narration[0].start == 0)
        #expect(abs(narration[0].end - 2.5) < 0.0001)
    }

    @Test func selectedRealTakeScalesEverySceneBlock() {
        let takeID = UUID()
        let scene = makeScene(
            text: "uno dos tres cuatro cinco",
            takes: [
                TimelineTakeInput(id: takeID, number: 1, duration: 20, isSelected: true, rating: .good),
                TimelineTakeInput(id: UUID(), number: 2, duration: 12, rating: .bad)
            ]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)

        #expect(layout.totalDuration == 20)
        #expect(layout.scenes[0].realDuration == 20)
        #expect(layout.scenes[0].estimatedDuration == 5)
        #expect(layout.blocks(on: .narration)[0].end == 20)

        let takes = layout.blocks(on: .takes)
        #expect(takes.count == 2)
        #expect(takes[0].isSelected)
        #expect(takes[0].start == 0)
        #expect(takes[0].end == 20)
        #expect(takes[1].end == 12)
        #expect(takes[1].lane == 1)
    }

    @Test func realTakeScalesAnchorsAndPauses() {
        let text = "uno dos / tres cuatro"
        let anchor = (text as NSString).range(of: "tres").location
        let takeID = UUID()
        let scene = makeScene(
            text: text,
            takes: [TimelineTakeInput(id: takeID, number: 1, duration: 2 * 4.5, isSelected: true)],
            bRoll: [TimelineMarkerInput(id: UUID(), anchorUTF16: anchor, duration: 1)]
        )
        // 4 words at 60 wpm = 4 s plus a 0.5 s short pause = 4.5 s estimated.
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let scaledAnchor = (text as NSString).range(of: "tres").location
        let expectedAnchorTime = (1.0 + 0.5 + 1.0) / 4.5 * 9
        let bRoll = layout.blocks(on: .bRoll)[0]
        let pause = layout.blocks(on: .pauses)[0]

        #expect(scaledAnchor == anchor)
        #expect(abs(bRoll.start - expectedAnchorTime) < 0.0001)
        #expect(abs(pause.duration - 1) < 0.0001)
        #expect(layout.totalDuration == 9)
    }

    @Test func fortyScenesWithFourHundredNarrationBlocksBuild() {
        let scenes = (0..<40).map { sceneIndex in
            let paragraphs = (0..<10).map { "escena \(sceneIndex) párrafo \($0) con cuatro palabras" }
            return makeScene(
                title: "Escena \(sceneIndex)",
                text: paragraphs.joined(separator: "\n\n"),
                bRoll: [TimelineMarkerInput(id: UUID(), anchorUTF16: 0, duration: 2)],
                warnings: [TimelineWarningInput(kind: .longSentence, location: 0, length: 10)]
            )
        }
        let layout = TimelineLayoutBuilder.build(scenes: scenes, configuration: wordsPerMinute60)

        #expect(layout.scenes.count == 40)
        #expect(layout.blocks(on: .narration).count == 400)
        #expect(Set(layout.blocks.map(\.id)).count == layout.blocks.count)
        #expect(layout.totalDuration > 0)
    }

    @Test func takeLanesAreCappedAndClippedToTheScene() {
        let takes = (1...5).map {
            TimelineTakeInput(id: UUID(), number: $0, duration: 30, rating: .safe)
        }
        let scene = makeScene(text: "uno dos", takes: takes)
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)

        let blocks = layout.blocks(on: .takes)
        #expect(blocks.count == 5)
        #expect(blocks.map(\.lane) == [0, 1, 2, 2, 2])
        #expect(blocks.allSatisfy { $0.end == layout.scenes[0].end })
        #expect(layout.maximumLane(on: .takes) == 2)
    }

    @Test func bRollAnchorMapsToSpokenTime() {
        let text = "uno dos tres cuatro"
        let anchor = (text as NSString).range(of: "tres").location
        let scene = makeScene(
            text: text,
            bRoll: [TimelineMarkerInput(id: UUID(), anchorUTF16: anchor, duration: 1.5, label: "Plano")]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let bRoll = layout.blocks(on: .bRoll)[0]

        #expect(bRoll.start == 2)
        #expect(bRoll.end == 3.5)
        #expect(bRoll.isAnchored)
        #expect(bRoll.label == "Plano")
    }

    @Test func bRollWithoutAnchorStartsAtSceneAndIsClippedAtTheEnd() {
        let scene = makeScene(
            text: "uno dos tres cuatro",
            bRoll: [
                TimelineMarkerInput(id: UUID(), anchorUTF16: nil, duration: 1, label: "Sin ancla"),
                TimelineMarkerInput(id: UUID(), anchorUTF16: 16, duration: 10, label: "Largo")
            ]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let bRoll = layout.blocks(on: .bRoll)

        #expect(bRoll[0].start == 0)
        #expect(bRoll[0].isAnchored == false)
        #expect(bRoll[1].start == 3.5)
        #expect(bRoll[1].end == 4)
        #expect(bRoll[1].isAnchored)
    }

    @Test func bRollWithoutPlannedDurationUsesTheDefault() {
        let scene = makeScene(
            text: "uno dos tres cuatro cinco seis siete ocho nueve diez",
            bRoll: [TimelineMarkerInput(id: UUID(), anchorUTF16: 0, duration: 0, label: "Plano")]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let block = layout.blocks(on: .bRoll)[0]

        #expect(block.duration == TimelineLayoutBuilder.defaultBRollDuration)
    }

    @Test func editingMarkerIsAZeroLengthBlockAtTheAnchor() {
        let text = "uno dos tres cuatro"
        let anchor = (text as NSString).range(of: "cuatro").location
        let scene = makeScene(
            text: text,
            editing: [TimelineMarkerInput(id: UUID(), anchorUTF16: anchor, label: "Corte")]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let marker = layout.blocks(on: .editing)[0]

        #expect(marker.start == 3)
        #expect(marker.end == 3)
        #expect(marker.duration == 0)
        #expect(marker.isAnchored)
    }

    @Test func rhythmWarningRangesMapToTimeStripes() {
        let text = "uno dos tres cuatro"
        let scene = makeScene(
            text: text,
            warnings: [
                TimelineWarningInput(kind: .longSentence, location: 0, length: 8),
                TimelineWarningInput(kind: .sceneLengthOutlier, location: 0, length: 19)
            ]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)
        let warnings = layout.blocks(on: .warnings)

        #expect(warnings.count == 2)
        #expect(warnings[0].start == 0)
        #expect(warnings[0].end == 2)
        #expect(warnings[0].warningKind == .longSentence)
        #expect(warnings[1].start == 0)
        #expect(warnings[1].end == 4)
        #expect(warnings[1].warningKind == .sceneLengthOutlier)
    }

    @Test func scenesAreLaidOutInInputOrderWithoutGaps() {
        let first = makeScene(title: "Uno", text: "uno dos")
        let second = makeScene(title: "Dos", text: "tres cuatro")
        let layout = TimelineLayoutBuilder.build(scenes: [first, second], configuration: wordsPerMinute60)
        let scenes = layout.blocks(on: .scenes)

        #expect(layout.totalDuration == 4)
        #expect(scenes.count == 2)
        #expect(scenes[0].start == 0)
        #expect(scenes[0].end == 2)
        #expect(scenes[1].start == 2)
        #expect(scenes[1].end == 4)
        #expect(layout.scenes.map(\.order) == [0, 1])
    }

    @Test func emptySceneKeepsAClickableMinimumAndTheNextSceneStartsAfterIt() {
        let empty = makeScene(title: "Vacía", text: "   ")
        let second = makeScene(title: "Llena", text: "uno dos")
        let layout = TimelineLayoutBuilder.build(scenes: [empty, second], configuration: wordsPerMinute60)

        #expect(layout.scenes[0].duration == TimelineLayoutBuilder.minimumSceneDuration)
        #expect(layout.totalDuration == 2.5)
        #expect(layout.scenes[1].start == 0.5)
    }

    @Test func invalidWordsPerMinuteStillCountsPauses() {
        let configuration = TimelineConfiguration(wordsPerMinute: .nan)
        let scene = makeScene(text: "uno [pausa 2s] dos")
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: configuration)

        #expect(layout.totalDuration == 2)
        #expect(layout.blocks(on: .pauses).count == 1)
    }

    @Test func nonFiniteTakeAndMarkerValuesAreSanitized() {
        let take = TimelineTakeInput(id: UUID(), number: 1, duration: .infinity, isSelected: true)
        let marker = TimelineMarkerInput(id: UUID(), anchorUTF16: 0, duration: .nan)
        let scene = makeScene(text: "uno dos", takes: [take], bRoll: [marker])
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)

        #expect(take.duration == 0)
        #expect(marker.duration == 0)
        #expect(layout.scenes[0].realDuration == nil)
        #expect(layout.totalDuration == 2)
    }

    @Test func blockIDsAreUniqueAndLookupWorks() {
        let text = "uno / dos\n\ncuatro [pausa 2s] cinco"
        let scene = makeScene(
            text: text,
            takes: [TimelineTakeInput(id: UUID(), number: 1, duration: 8, isSelected: true)],
            bRoll: [TimelineMarkerInput(id: UUID(), anchorUTF16: 2, duration: 1)],
            editing: [TimelineMarkerInput(id: UUID(), anchorUTF16: 4)],
            warnings: [TimelineWarningInput(kind: .longSentence, location: 0, length: 4)]
        )
        let layout = TimelineLayoutBuilder.build(scenes: [scene], configuration: wordsPerMinute60)

        #expect(Set(layout.blocks.map(\.id)).count == layout.blocks.count)
        for block in layout.blocks {
            #expect(layout.block(id: block.id) == block)
        }
        #expect(layout.scene(containing: 1)?.id == scene.id)
        #expect(layout.scene(containing: layout.totalDuration) == nil)
    }

    @Test func labelExcerptCollapsesWhitespaceAndTruncates() {
        let long = String(repeating: "palabra ", count: 20)
        let excerpt = TimelineLayoutBuilder.excerpt("Hola\n\nmundo \(long)")

        #expect(excerpt.hasPrefix("Hola mundo palabra"))
        #expect(excerpt.hasSuffix("…"))
        #expect(excerpt.count <= TimelineLayoutBuilder.maximumLabelLength + 1)
    }

    @Test func emptyProjectProducesAnEmptyLayout() {
        let layout = TimelineLayoutBuilder.build(scenes: [], configuration: .standard)

        #expect(layout.isEmpty)
        #expect(layout.totalDuration == 0)
        #expect(layout.blocks.isEmpty)
    }

    private func makeScene(
        title: String = "Escena",
        text: String,
        takes: [TimelineTakeInput] = [],
        bRoll: [TimelineMarkerInput] = [],
        editing: [TimelineMarkerInput] = [],
        warnings: [TimelineWarningInput] = []
    ) -> TimelineSceneInput {
        TimelineSceneInput(
            id: UUID(),
            title: title,
            text: text,
            takes: takes,
            bRoll: bRoll,
            editing: editing,
            warnings: warnings
        )
    }
}

@Suite("TimelineViewport")
struct TimelineViewportTests {
    @Test func xAndTimeRoundTripWithLeadingInset() {
        let viewport = TimelineViewport(pointsPerSecond: 4, leadingInset: 12)

        #expect(viewport.x(for: 0) == 12)
        #expect(viewport.x(for: 10) == 52)
        #expect(viewport.time(forX: 52) == 10)
        #expect(viewport.width(for: 2.5) == 10)
        #expect(viewport.contentWidth(totalDuration: 10) == 52)
    }

    @Test func invalidViewportValuesFallBackSafely() {
        let viewport = TimelineViewport(pointsPerSecond: .nan, leadingInset: -10)

        #expect(viewport.pointsPerSecond == TimelineZoom.defaultPointsPerSecond)
        #expect(viewport.leadingInset == 0)
        #expect(viewport.time(forX: -20) == 0)
    }

    @Test func zoomClampsAndSteps() {
        #expect(TimelineZoom.clamp(.nan) == TimelineZoom.defaultPointsPerSecond)
        #expect(TimelineZoom.clamp(0) == TimelineZoom.minimumPointsPerSecond)
        #expect(TimelineZoom.clamp(1_000) == TimelineZoom.maximumPointsPerSecond)
        #expect(TimelineZoom.zoomedIn(4) == 5)
        #expect(TimelineZoom.zoomedOut(4) == 3.2)
        #expect(TimelineZoom.zoomedIn(TimelineZoom.maximumPointsPerSecond) == TimelineZoom.maximumPointsPerSecond)
    }

    @Test func sliderFractionIsInverseOfZoomMapping() {
        for pointsPerSecond in [1.5, 2.0, 4.0, 8.0, 16.0] {
            let fraction = TimelineZoom.fraction(forPointsPerSecond: pointsPerSecond)
            let roundTrip = TimelineZoom.pointsPerSecond(forFraction: fraction)
            #expect(abs(roundTrip - pointsPerSecond) < 0.0001)
        }
        #expect(TimelineZoom.fraction(forPointsPerSecond: TimelineZoom.minimumPointsPerSecond) == 0)
        #expect(TimelineZoom.fraction(forPointsPerSecond: TimelineZoom.maximumPointsPerSecond) == 1)
    }

    @Test func rulerChoosesReadableIntervalsAtEveryZoom() {
        #expect(TimelineRuler.tickInterval(pointsPerSecond: 1.5) == 60)
        #expect(TimelineRuler.tickInterval(pointsPerSecond: 4) == 30)
        #expect(TimelineRuler.tickInterval(pointsPerSecond: 16) == 5)
    }

    @Test func rulerTicksAreLabelledAndBoundedByTheDuration() {
        let ticks = TimelineRuler.ticks(totalDuration: 125, pointsPerSecond: 4)

        #expect(ticks.map(\.time) == [0, 30, 60, 90, 120])
        #expect(ticks.map(\.label) == ["0:00", "0:30", "1:00", "1:30", "2:00"])
    }

    @Test func shortTimelineGetsAnEndTick() {
        let ticks = TimelineRuler.ticks(totalDuration: 7, pointsPerSecond: 4)

        #expect(ticks.map(\.time) == [0, 7])
        #expect(ticks.map(\.label) == ["0:00", "0:07"])
    }

    @Test func emptyTimelineStillHasAZeroTick() {
        let ticks = TimelineRuler.ticks(totalDuration: 0, pointsPerSecond: 4)

        #expect(ticks.count == 1)
        #expect(ticks[0].time == 0)
        #expect(ticks[0].label == "0:00")
    }

    @Test func invalidRulerInputsDoNotProduceDuplicateOrHugeTickSets() {
        let ticks = TimelineRuler.ticks(totalDuration: .infinity, pointsPerSecond: .nan)

        #expect(ticks.count == 1)
        #expect(ticks[0].time == 0)
    }
}
