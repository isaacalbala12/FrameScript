import Foundation
@testable import FrameScript
import FrameScriptCore
import XCTest

@MainActor
final class DurationTests: XCTestCase {
    // MARK: Real take selection

    func testLatestGoodTakeWinsOverOlderGoodAndNewerNonGoodTake() {
        let takes = [
            makeTake(number: 1, daysAgo: 4, duration: 70, rating: .good),
            makeTake(number: 2, daysAgo: 3, duration: 75, rating: .good),
            makeTake(number: 3, daysAgo: 1, duration: 88, rating: .safe)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: records(from: takes),
            language: "es"
        )

        XCTAssertEqual(selected?.take.id, takes[1].id)
        XCTAssertEqual(selected?.take.duration, 75)
    }

    func testFallsBackToLatestNonBadTakeWhenNoGoodTakeExists() {
        let takes = [
            makeTake(number: 1, daysAgo: 5, duration: 90, rating: .bad),
            makeTake(number: 2, daysAgo: 3, duration: 61, rating: .safe),
            makeTake(number: 3, daysAgo: 1, duration: 66, rating: .unrated)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: records(from: takes),
            language: "es"
        )

        XCTAssertEqual(selected?.take.id, takes[2].id)
        XCTAssertEqual(selected?.take.duration, 66)
    }

    func testBadTakesAndTakesWithoutMeasuredDurationAreIgnored() {
        let takes = [
            makeTake(number: 1, daysAgo: 5, duration: 58, rating: .safe),
            makeTake(number: 2, daysAgo: 2, duration: 120, rating: .bad),
            makeTake(number: 3, daysAgo: 1, duration: 0, rating: .good)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: records(from: takes),
            language: "es"
        )

        XCTAssertEqual(selected?.take.id, takes[0].id)
    }

    func testUnboundedTakeDurationIsIgnored() {
        let takes = [
            makeTake(number: 1, daysAgo: 2, duration: 70, rating: .good),
            makeTake(number: 2, daysAgo: 1, duration: 1e300, rating: .good)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: records(from: takes),
            language: "es"
        )

        XCTAssertEqual(selected?.take.id, takes[0].id)
    }

    func testEmptyTakeLanguageMeansPrimaryLanguageButNotAnotherLanguage() {
        let primaryTake = makeTake(number: 1, daysAgo: 2, duration: 70, rating: .good, language: "")
        let englishTake = makeTake(number: 2, daysAgo: 1, duration: 40, rating: .good, language: "en-GB")
        let scene = makeScene(text: "text", takes: [primaryTake, englishTake])

        let spanishProject = FrameProject(title: "Spanish", scenes: [scene], primaryLanguage: "es")
        let englishProject = FrameProject(title: "English", scenes: [scene], primaryLanguage: "en")
        let spanishState = makeAppState(project: spanishProject)
        let englishState = makeAppState(project: englishProject)

        XCTAssertEqual(spanishState.sceneDurationSummary(for: scene).realTakeID, primaryTake.id)
        XCTAssertEqual(englishState.sceneDurationSummary(for: scene).realTakeID, englishTake.id)
    }

    func testLanguageMatchPrefersLatestMatchingTake() {
        let olderSpanish = makeTake(number: 1, daysAgo: 4, duration: 70, rating: .good, language: "es-ES")
        let newerSpanish = makeTake(number: 2, daysAgo: 3, duration: 72, rating: .good, language: "es-MX")
        let newestEnglish = makeTake(number: 3, daysAgo: 1, duration: 44, rating: .good, language: "en")

        let selected = DurationTakeSelector.selectedTake(
            from: records(from: [olderSpanish, newerSpanish, newestEnglish]),
            language: "es"
        )

        XCTAssertEqual(selected?.take.id, newerSpanish.id)
    }

    func testStaleTakeIsIgnoredForRealDuration() {
        let sceneText = "the current script"
        let stale = makeTake(
            number: 1,
            daysAgo: 1,
            duration: 70,
            rating: .good,
            sceneTextHash: FrameScriptDocument.TextHash.hash("an older script")
        )
        let current = makeTake(
            number: 2,
            daysAgo: 2,
            duration: 62,
            rating: .good,
            sceneTextHash: FrameScriptDocument.TextHash.hash(sceneText)
        )
        let scene = makeScene(text: sceneText, takes: [stale, current])
        let appState = makeAppState(project: FrameProject(title: "Stale", scenes: [scene], primaryLanguage: "es"))

        let summary = appState.sceneDurationSummary(for: scene)

        XCTAssertEqual(summary.realTakeID, current.id)
        XCTAssertEqual(summary.real, 62)
    }

    func testLegacyTakeWithoutHashStillCounts() {
        let scene = makeScene(
            text: "current",
            takes: [makeTake(number: 1, daysAgo: 1, duration: 55, rating: .good, sceneTextHash: "")]
        )
        let appState = makeAppState(project: FrameProject(title: "Legacy", scenes: [scene], primaryLanguage: "es"))

        XCTAssertEqual(appState.sceneDurationSummary(for: scene).real, 55)
    }

    func testVariantTakeCanSupplyRealDurationForItsLanguage() throws {
        let variantText = "translated scene"
        let variantTake = makeTake(
            number: 1,
            daysAgo: 1,
            duration: 47,
            rating: .good,
            language: "en",
            readText: variantText,
            sceneTextHash: FrameScriptDocument.TextHash.hash(variantText)
        )
        let variant = SceneLanguageVariant(
            languageCode: "en",
            text: variantText,
            sourceHash: FrameScriptDocument.TextHash.hash("original"),
            takes: [variantTake]
        )
        let scene = makeScene(text: "original", takes: [], languageVariants: [variant])
        let project = FrameProject(title: "Variants", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        XCTAssertEqual(appState.durationTakeRecords(for: scene).count, 1)
        XCTAssertEqual(appState.sceneDurationSummary(for: scene, language: "en").realTakeID, variantTake.id)
        XCTAssertNil(appState.sceneDurationSummary(for: scene).real)
    }

    // MARK: Target and progress math

    func testSceneOverrunAndProgressWhenRealTakeExceedsTarget() {
        let summary = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 80,
            real: 95,
            realTakeNumber: 2,
            realTakeRating: .good,
            target: 90
        )

        XCTAssertEqual(summary.displayed, 95)
        XCTAssertEqual(summary.overrun, 5, accuracy: 0.001)
        XCTAssertTrue(summary.isOverTarget)
        XCTAssertEqual(summary.progress ?? 0, 95.0 / 90.0, accuracy: 0.0001)
    }

    func testSceneWithoutTargetNeverWarns() {
        let summary = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 120,
            real: 130,
            target: nil
        )

        XCTAssertEqual(summary.overrun, 0)
        XCTAssertFalse(summary.isOverTarget)
        XCTAssertNil(summary.progress)
    }

    func testTargetUsesEstimateWhenSceneHasNoRealTake() {
        let summary = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 84,
            target: 80
        )

        XCTAssertEqual(summary.displayed, 84)
        XCTAssertEqual(summary.overrun, 4, accuracy: 0.001)
        XCTAssertTrue(summary.isOverTarget)
    }

    func testProjectSummarySumsRealOrEstimatedAgainstTarget() {
        let withReal = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 90,
            real: 95,
            target: nil
        )
        let estimateOnly = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 80,
            target: nil
        )
        let summary = ProjectDurationSummary(
            sceneSummaries: [withReal, estimateOnly],
            target: 200
        )

        XCTAssertEqual(summary.sceneCount, 2)
        XCTAssertEqual(summary.estimated, 170)
        XCTAssertEqual(summary.realOrEstimated, 175)
        XCTAssertEqual(summary.displayTotal, 175)
        XCTAssertEqual(summary.recorded, 95)
        XCTAssertEqual(summary.scenesWithReal, 1)
        XCTAssertFalse(summary.allScenesHaveReal)
        XCTAssertEqual(summary.progress ?? 0, 0.875, accuracy: 0.0001)
        XCTAssertFalse(summary.isOverTarget)

        let overTarget = ProjectDurationSummary(
            sceneSummaries: [withReal, estimateOnly],
            target: 160
        )

        XCTAssertEqual(overTarget.overrun, 15, accuracy: 0.001)
        XCTAssertTrue(overTarget.isOverTarget)
    }

    func testProjectWithEverySceneRecordedUsesRealTotal() {
        let summaries = [
            SceneDurationSummary(sceneID: UUID(), estimated: 90, real: 95),
            SceneDurationSummary(sceneID: UUID(), estimated: 80, real: 78)
        ]
        let summary = ProjectDurationSummary(sceneSummaries: summaries, target: 180)

        XCTAssertTrue(summary.allScenesHaveReal)
        XCTAssertEqual(summary.realOrEstimated, 173)
        XCTAssertEqual(summary.displayTotal, 173)
        XCTAssertEqual(summary.recorded, 173)
        XCTAssertEqual(summary.overrun, 0)
    }

    func testProjectToolbarTotalMatchesWarningBasis() {
        let summaries = [
            SceneDurationSummary(sceneID: UUID(), estimated: 200, real: 220)
        ]
        let summary = ProjectDurationSummary(sceneSummaries: summaries, target: 210)

        XCTAssertEqual(summary.estimated, 200)
        XCTAssertEqual(summary.displayTotal, 220)
        XCTAssertEqual(summary.overrun, 10, accuracy: 0.001)
        XCTAssertTrue(summary.isOverTarget)
    }

    func testUnboundedDurationsAndTargetsAreSanitized() {
        let summary = SceneDurationSummary(
            sceneID: UUID(),
            estimated: 1e300,
            real: 1e300,
            target: 1e300
        )

        XCTAssertEqual(summary.estimated, DurationLimits.maximumDuration)
        XCTAssertNil(summary.real)
        XCTAssertNil(summary.target)

        let project = ProjectDurationSummary(sceneSummaries: [summary], target: 1e300)
        XCTAssertNil(project.target)
        XCTAssertFalse(project.isOverTarget)
    }

    // MARK: WPM learning

    func testLearningUsesExponentialMovingAverageWhenEnoughSamplesExist() {
        let samples = [
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 3),
            makeSample(language: "es", words: 120, duration: 60, daysAgo: 2),
            makeSample(language: "es", words: 180, duration: 60, daysAgo: 1)
        ]

        let result = DurationLearning.recompute(samples: samples)

        XCTAssertEqual(result.statistics(for: "es")?.acceptedSampleCount, 3)
        XCTAssertEqual(result.learnedWordsPerMinuteByLanguage["es"] ?? 0, 152.7, accuracy: 0.0001)
    }

    func testLearningDoesNotPersistUntilMinimumSampleCountIsReached() {
        let samples = [
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 2),
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 1)
        ]

        let result = DurationLearning.recompute(samples: samples)

        XCTAssertEqual(result.statistics(for: "es")?.acceptedSampleCount, 2)
        XCTAssertNil(result.learnedWordsPerMinuteByLanguage["es"])
    }

    func testLearningGroupsSamplesPerLanguage() {
        let samples = [
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 3),
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 2),
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 1),
            makeSample(language: "en", words: 120, duration: 60, daysAgo: 1)
        ]

        let result = DurationLearning.recompute(samples: samples)

        XCTAssertEqual(result.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
        XCTAssertNil(result.learnedWordsPerMinuteByLanguage["en"])
        XCTAssertEqual(result.statistics(for: "en-GB")?.acceptedSampleCount, 1)
    }

    func testOutlierSampleIsRejectedAndDoesNotDistortPace() {
        let samples = [
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 4),
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 3),
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 2),
            makeSample(language: "es", words: 400, duration: 60, daysAgo: 1)
        ]

        let result = DurationLearning.recompute(samples: samples)

        XCTAssertEqual(result.statistics(for: "es")?.acceptedSampleCount, 3)
        XCTAssertEqual(result.statistics(for: "es")?.rejectedSampleCount, 1)
        XCTAssertEqual(result.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
    }

    func testResetCutoffIgnoresTakesRecordedBeforeReset() {
        let old = (0..<3).map { index in
            makeSample(language: "es", words: 150, duration: 60, daysAgo: 10 - Double(index))
        }
        let new = makeSample(language: "es", words: 150, duration: 60, daysAgo: 1)
        let cutoff = Date(timeIntervalSinceNow: -2 * 86_400)

        let result = DurationLearning.recompute(
            samples: old + [new],
            resetCutoffs: ["es": cutoff]
        )

        XCTAssertEqual(result.statistics(for: "es")?.acceptedSampleCount, 1)
        XCTAssertNil(result.learnedWordsPerMinuteByLanguage["es"])
    }

    func testSamplesUseMarkupAwareReadTextInsteadOfRawWordSplit() {
        let scene = makeScene(
            text: "one two three four five six seven",
            takes: [
                makeTake(
                    number: 1,
                    daysAgo: 1,
                    duration: 30,
                    rating: .good,
                    readText: "[pause] uno dos / tres"
                )
            ]
        )

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.wordCount, 3)
        XCTAssertEqual(samples.first?.languageCode, "es")
    }

    func testSamplesSubtractPausesFromSpeakingTime() throws {
        let spoken = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let text = "\(spoken) [pausa 10s]"
        let scene = makeScene(
            text: text,
            takes: [
                makeTake(
                    number: 1,
                    daysAgo: 1,
                    duration: 60,
                    rating: .good,
                    readText: text,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                )
            ]
        )

        let sample = try XCTUnwrap(DurationLearning.samples(from: [scene], primaryLanguage: "es").first)

        XCTAssertEqual(sample.wordCount, 150)
        XCTAssertEqual(sample.duration, 50, accuracy: 0.001)
        let learned = DurationLearning.recompute(
            samples: [sample, sample, sample]
        )
        XCTAssertEqual(learned.learnedWordsPerMinuteByLanguage["es"] ?? 0, 180, accuracy: 0.001)
    }

    func testSamplesFallBackToSceneTextWhenReadTextIsMissing() {
        let scene = makeScene(
            text: "uno dos tres cuatro",
            takes: [makeTake(number: 1, daysAgo: 1, duration: 20, rating: .good, readText: "")]
        )

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")

        XCTAssertEqual(samples.first?.wordCount, 4)
    }

    func testStaleTakeWithoutReadTextDoesNotLearnFromEditedScene() {
        let stale = makeTake(
            number: 1,
            daysAgo: 1,
            duration: 20,
            rating: .good,
            readText: "",
            sceneTextHash: FrameScriptDocument.TextHash.hash("old text")
        )
        let scene = makeScene(text: "completely different current text", takes: [stale])

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")

        XCTAssertTrue(samples.isEmpty)
    }

    func testOnlyGoodTakesFeedLearning() {
        let scene = makeScene(
            text: "uno dos tres cuatro",
            takes: [
                makeTake(number: 1, daysAgo: 3, duration: 20, rating: .safe),
                makeTake(number: 2, daysAgo: 2, duration: 20, rating: .bad),
                makeTake(number: 3, daysAgo: 1, duration: 20, rating: .unrated)
            ]
        )

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")

        XCTAssertTrue(samples.isEmpty)
    }

    func testVariantTakesFeedLearningWithVariantTextAndLanguage() throws {
        let variantText = Array(repeating: "word", count: 150).joined(separator: " ")
        let variantTakes = (1...3).map { number in
            makeTake(
                number: number,
                daysAgo: Double(4 - number),
                duration: 60,
                rating: .good,
                language: "en",
                readText: variantText,
                sceneTextHash: FrameScriptDocument.TextHash.hash(variantText)
            )
        }
        let variant = SceneLanguageVariant(
            languageCode: "en",
            text: variantText,
            sourceHash: FrameScriptDocument.TextHash.hash("original"),
            takes: variantTakes
        )
        let scene = makeScene(text: "original", takes: [], languageVariants: [variant])

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")
        let result = DurationLearning.recompute(samples: samples)

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.first?.languageCode, "en")
        XCTAssertEqual(result.learnedWordsPerMinuteByLanguage["en"] ?? 0, 150, accuracy: 0.0001)
    }

    // MARK: Persistence

    func testDocumentRoundTripPreservesLearnedWPMTargetsAndReset() throws {
        let resetDate = Date(timeIntervalSince1970: 1_700_000_900)
        let scene = makeScene(
            text: "uno dos tres",
            takes: [makeTake(number: 1, daysAgo: 1, duration: 62, rating: .good)],
            target: 75
        )
        let project = FrameProject(
            title: "Durations",
            scenes: [scene],
            primaryLanguage: "es"
        )
        project.targetDuration = 420
        project.learnedWordsPerMinuteByLanguage = ["es": 143.5]
        project.learnedWordsPerMinuteResetAtByLanguage = ["es": resetDate]

        let restored = try FrameScriptFile(project: project).makeProject()

        XCTAssertEqual(restored.targetDuration, 420)
        XCTAssertEqual(restored.learnedWordsPerMinuteByLanguage["es"] ?? 0, 143.5, accuracy: 0.0001)
        XCTAssertEqual(restored.learnedWordsPerMinuteResetAtByLanguage["es"], resetDate)
        XCTAssertEqual(restored.scenes.first?.targetDuration, 75)
        XCTAssertEqual(restored.scenes.first?.takes.first?.duration, 62)
        XCTAssertEqual(restored.scenes.first?.takes.first?.rating, .good)
    }

    func testResetPersistsInDocumentAndSurvivesRelaunch() throws {
        let text = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let scenes = (0..<3).map { index in
            makeScene(
                text: text,
                takes: [
                    makeTake(
                        number: 1,
                        daysAgo: Double(3 - index),
                        duration: 60,
                        rating: .good,
                        readText: text,
                        sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                    )
                ]
            )
        }
        let project = FrameProject(title: "Reset", scenes: scenes, primaryLanguage: "es")
        let appState = makeAppState(project: project)
        appState.recomputeLearnedWPM(markDirty: false)
        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)

        let resetDate = Date(timeIntervalSinceNow: -1)
        appState.resetLearnedWPM(language: "es", at: resetDate)
        XCTAssertNil(project.learnedWordsPerMinuteByLanguage["es"])
        XCTAssertEqual(project.learnedWordsPerMinuteResetAtByLanguage["es"], resetDate)

        let restored = try FrameScriptFile(project: project).makeProject()
        let relaunched = makeAppState(project: restored)
        relaunched.recomputeLearnedWPM(markDirty: false)

        XCTAssertNil(restored.learnedWordsPerMinuteByLanguage["es"])

        for index in 0..<3 {
            restored.scenes[0].takes.append(
                makeTake(
                    number: 10 + index,
                    daysAgo: -Double(index + 1),
                    duration: 60,
                    rating: .good,
                    readText: text,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(text)
                )
            )
        }
        relaunched.recomputeLearnedWPM(markDirty: false)

        XCTAssertEqual(restored.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
    }

    func testPrimaryLanguageIsSetForNewProjectsAndDemos() {
        let english = SampleData.project(
            named: "English",
            template: SampleData.templates.first,
            language: .english
        )
        let spanish = SampleData.project(
            named: "Spanish",
            template: SampleData.templates.first,
            language: .spanish
        )
        let russian = SampleData.project(
            named: "Russian",
            template: SampleData.templates.first,
            language: .russian
        )

        XCTAssertEqual(english.primaryLanguage, "en")
        XCTAssertEqual(spanish.primaryLanguage, "es")
        XCTAssertEqual(russian.primaryLanguage, "ru")
        XCTAssertEqual(SampleData.demoProject(language: .english).primaryLanguage, "en")
        XCTAssertEqual(SampleData.demoProject(language: .spanish).primaryLanguage, "es")
        XCTAssertEqual(SampleData.demoProject(language: .russian).primaryLanguage, "ru")
    }

    // MARK: App integration

    func testEffectiveWPMUsesLearnedValueAndFallsBackToSettings() {
        let project = FrameProject(title: "Speech", scenes: [], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 168]
        var settings = AppSettings.defaults
        settings.editorPreferences.wordsPerMinute = 140
        let appState = makeAppState(project: project, settings: settings)

        XCTAssertEqual(appState.effectiveWPM(language: "es"), 168, accuracy: 0.0001)
        XCTAssertEqual(appState.effectiveWPM(language: "en"), 140, accuracy: 0.0001)
    }

    func testUnboundedLearnedWPMFallsBackToSettings() {
        let project = FrameProject(title: "Speech", scenes: [], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 1e300]
        let appState = makeAppState(project: project)

        XCTAssertEqual(appState.effectiveWPM(language: "es"), 150, accuracy: 0.0001)
    }

    func testEstimatedDurationUsesLearnedPaceAndMarkupPauses() {
        let text = "uno dos / tres [pausa 3s] [IMAGEN: coche] cuatro"
        let scene = makeScene(text: text)
        let project = FrameProject(title: "Speech", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 300]
        let appState = makeAppState(project: project)

        // 4 spoken words at 300 WPM (0.8 s) plus a 0.5 s slash and a 3 s pause.
        XCTAssertEqual(appState.estimatedDuration(for: scene), 4.3, accuracy: 0.001)
    }

    func testStoredEstimateAfterEditUsesLearnedPaceAndPauses() {
        let text = "uno dos / tres [pausa 3s] [IMAGEN: coche] cuatro"
        let scene = makeScene(text: text)
        let project = FrameProject(title: "Speech", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 300]
        let appState = makeAppState(project: project)

        appState.commitScriptTextChange(sceneID: scene.id)

        XCTAssertEqual(appState.currentDurationWordsPerMinute, 300)
        XCTAssertEqual(scene.estimatedDuration, 4.3, accuracy: 0.001)
    }

    func testSummaryUsesStoredEstimateInsteadOfReparsingText() {
        let scene = makeScene(text: "text with [pausa 10s] markup")
        let appState = makeAppState(project: FrameProject(
            title: "Stored",
            scenes: [scene],
            primaryLanguage: "es"
        ))

        scene.estimatedDuration = 42

        XCTAssertEqual(appState.sceneDurationSummary(for: scene).estimated, 42)
    }

    func testExportedTimestampUsesStoredLearnedEstimate() throws {
        let text = Array(repeating: "palabra", count: 300).joined(separator: " ")
        let scene = makeScene(text: text)
        let project = FrameProject(title: "Export", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 300]
        let appState = makeAppState(project: project)
        appState.commitScriptTextChange(sceneID: scene.id)

        var preferences = AppSettings.defaults.exportPreferences
        preferences.includeTimestamps = true
        preferences.includeSectionNames = true
        let output = ExportService().render(
            project: project,
            format: .plainText,
            preferences: preferences,
            language: .english
        )

        XCTAssertTrue(output.contains("[1:00]"), output)
    }

    func testSavedEstimateUsesLearnedPace() throws {
        let text = Array(repeating: "palabra", count: 300).joined(separator: " ")
        let scene = makeScene(text: text)
        let project = FrameProject(title: "Speech", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 300]
        let appState = makeAppState(project: project)
        let url = temporaryProjectURL()

        try appState.projectStore.saveCurrentProject(
            to: url,
            wordsPerMinute: appState.currentDurationWordsPerMinute
        )

        let restored = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(restored.scenes.first?.estimatedDuration ?? 0, 60, accuracy: 0.001)
    }

    func testSceneAndProjectTargetSettersRejectOutOfRangeValues() {
        let scene = makeScene(text: "uno dos")
        let project = FrameProject(title: "Targets", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        appState.setSceneTargetDuration(90, sceneID: scene.id)
        appState.setProjectTargetDuration(600)
        XCTAssertEqual(scene.targetDuration, 90)
        XCTAssertEqual(project.targetDuration, 600)

        appState.setSceneTargetDuration(1e300, sceneID: scene.id)
        appState.setProjectTargetDuration(1e300)
        XCTAssertEqual(scene.targetDuration, 90)
        XCTAssertEqual(project.targetDuration, 600)

        appState.setSceneTargetDuration(0.05, sceneID: scene.id)
        appState.setProjectTargetDuration(0.05)
        XCTAssertEqual(scene.targetDuration, 90)
        XCTAssertEqual(project.targetDuration, 600)

        appState.setSceneTargetDuration(nil, sceneID: scene.id)
        appState.setProjectTargetDuration(nil)
        XCTAssertNil(scene.targetDuration)
        XCTAssertNil(project.targetDuration)
    }

    // MARK: Input and formatting bounds

    func testDurationInputParsesMinutesAndSecondsWithinBounds() {
        XCTAssertEqual(DurationInput.parse("1:30") ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("90") ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("1,5") ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse(" 0:45 ") ?? 0, 45, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("0.1") ?? 0, 0.1, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("86400") ?? 0, 86_400, accuracy: 0.001)
        XCTAssertNil(DurationInput.parse(""))
        XCTAssertNil(DurationInput.parse("0"))
        XCTAssertNil(DurationInput.parse("1:75"))
        XCTAssertNil(DurationInput.parse("abc"))
        XCTAssertNil(DurationInput.parse("1:2:3"))
        XCTAssertNil(DurationInput.parse("86400.1"))
        XCTAssertNil(DurationInput.parse("999999999999999999999"))
    }

    func testFractionalTargetFieldRoundTrips() throws {
        XCTAssertEqual(try XCTUnwrap(DurationInput.parse(DurationInput.fieldValue(0.5))), 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(DurationInput.parse(DurationInput.fieldValue(90.25))), 90.25, accuracy: 0.001)
        XCTAssertEqual(DurationInput.fieldValue(0.5), "0:00.5")
        XCTAssertEqual(DurationInput.fieldValue(90.25), "1:30.25")
        XCTAssertEqual(DurationInput.fieldValue(1e300), "1440:00")
    }

    func testFormattingIsOverflowSafe() {
        XCTAssertEqual(DurationEstimator.formatted(1e300), "16666666:39")
        XCTAssertEqual(DurationEstimator.formatted(.nan), "0:00")
        XCTAssertEqual(DurationEstimator.formatted(.infinity), "0:00")
        XCTAssertEqual(DurationEstimator.formatted(-5), "0:00")
        XCTAssertEqual(DurationNumber.percent(1e300), 9_999)
        XCTAssertEqual(DurationNumber.percent(.nan), 0)
        XCTAssertEqual(DurationNumber.clampedInt(1e300, range: 0...500), 500)
    }

    // MARK: Helpers

    private func makeTake(
        number: Int,
        daysAgo: Double,
        duration: TimeInterval,
        rating: TakeRating,
        language: String = "",
        readText: String = "",
        sceneTextHash: String = ""
    ) -> Take {
        Take(
            number: number,
            startedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            duration: duration,
            rating: rating,
            languageCode: language,
            readText: readText,
            sceneTextHash: sceneTextHash
        )
    }

    private func records(
        from takes: [Take],
        language: String = "es",
        sourceText: String = "source"
    ) -> [DurationTakeRecord] {
        takes.map {
            DurationTakeRecord(
                take: $0,
                languageCode: $0.languageCode.isEmpty ? language : $0.languageCode,
                sourceText: sourceText,
                sourceTextHash: FrameScriptDocument.TextHash.hash(sourceText)
            )
        }
    }

    private func makeSample(
        language: String,
        words: Int,
        duration: TimeInterval,
        daysAgo: Double
    ) -> DurationLearningSample {
        DurationLearningSample(
            languageCode: language,
            wordCount: words,
            duration: duration,
            startedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            takeNumber: 1
        )
    }

    private func makeScene(
        text: String,
        takes: [Take] = [],
        target: TimeInterval? = nil,
        languageVariants: [SceneLanguageVariant] = []
    ) -> Scene {
        Scene(
            order: 0,
            sectionType: .hook,
            title: "Scene",
            scriptText: text,
            targetDuration: target,
            takes: takes,
            languageVariants: languageVariants
        )
    }

    private func makeAppState(
        project: FrameProject,
        settings: AppSettings = .defaults
    ) -> AppState {
        let suite = UserDefaults(suiteName: "DurationTests-\(UUID().uuidString)")!
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings")
        )
    }

    private func temporaryProjectURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DurationTests-\(UUID().uuidString).fscr")
    }
}
