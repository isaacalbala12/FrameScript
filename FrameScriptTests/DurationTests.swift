import Foundation
@testable import FrameScript
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
            from: takes,
            language: "es",
            primaryLanguage: "es"
        )

        XCTAssertEqual(selected?.id, takes[1].id)
        XCTAssertEqual(selected?.duration, 75)
    }

    func testFallsBackToLatestNonBadTakeWhenNoGoodTakeExists() {
        let takes = [
            makeTake(number: 1, daysAgo: 5, duration: 90, rating: .bad),
            makeTake(number: 2, daysAgo: 3, duration: 61, rating: .safe),
            makeTake(number: 3, daysAgo: 1, duration: 66, rating: .unrated)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: takes,
            language: "es",
            primaryLanguage: "es"
        )

        XCTAssertEqual(selected?.id, takes[2].id)
        XCTAssertEqual(selected?.duration, 66)
    }

    func testBadTakesAndTakesWithoutMeasuredDurationAreIgnored() {
        let takes = [
            makeTake(number: 1, daysAgo: 5, duration: 58, rating: .safe),
            makeTake(number: 2, daysAgo: 2, duration: 120, rating: .bad),
            makeTake(number: 3, daysAgo: 1, duration: 0, rating: .good)
        ]

        let selected = DurationTakeSelector.selectedTake(
            from: takes,
            language: "es",
            primaryLanguage: "es"
        )

        XCTAssertEqual(selected?.id, takes[0].id)
    }

    func testEmptyTakeLanguageMeansPrimaryLanguageButNotAnotherLanguage() {
        let primaryTake = makeTake(number: 1, daysAgo: 1, duration: 70, rating: .good, language: "")
        let englishTake = makeTake(number: 2, daysAgo: 2, duration: 40, rating: .good, language: "en-GB")

        let spanish = DurationTakeSelector.selectedTake(
            from: [englishTake, primaryTake],
            language: "es-ES",
            primaryLanguage: "es"
        )
        let english = DurationTakeSelector.selectedTake(
            from: [englishTake, primaryTake],
            language: "en",
            primaryLanguage: "es"
        )

        XCTAssertEqual(spanish?.id, primaryTake.id)
        XCTAssertEqual(english?.id, englishTake.id)
    }

    func testLanguageMatchPrefersLatestMatchingTake() {
        let olderSpanish = makeTake(number: 1, daysAgo: 4, duration: 70, rating: .good, language: "es-ES")
        let newerSpanish = makeTake(number: 2, daysAgo: 3, duration: 72, rating: .good, language: "es-MX")
        let newestEnglish = makeTake(number: 3, daysAgo: 1, duration: 44, rating: .good, language: "en")

        let selected = DurationTakeSelector.selectedTake(
            from: [olderSpanish, newerSpanish, newestEnglish],
            language: "es",
            primaryLanguage: "es"
        )

        XCTAssertEqual(selected?.id, newerSpanish.id)
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
        XCTAssertEqual(summary.recorded, 173)
        XCTAssertEqual(summary.overrun, 0)
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

    func testSamplesFallBackToSceneTextWhenReadTextIsMissing() {
        let scene = makeScene(
            text: "uno dos tres cuatro",
            takes: [makeTake(number: 1, daysAgo: 1, duration: 20, rating: .good, readText: "")]
        )

        let samples = DurationLearning.samples(from: [scene], primaryLanguage: "es")

        XCTAssertEqual(samples.first?.wordCount, 4)
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

    // MARK: Persistence

    func testDocumentRoundTripPreservesLearnedWPMAndTargets() throws {
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

        let restored = try FrameScriptFile(project: project).makeProject()

        XCTAssertEqual(restored.targetDuration, 420)
        XCTAssertEqual(restored.learnedWordsPerMinuteByLanguage["es"] ?? 0, 143.5, accuracy: 0.0001)
        XCTAssertEqual(restored.scenes.first?.targetDuration, 75)
        XCTAssertEqual(restored.scenes.first?.takes.first?.duration, 62)
        XCTAssertEqual(restored.scenes.first?.takes.first?.rating, .good)
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

    func testEstimatedDurationUsesLearnedPace() {
        let words = Array(repeating: "palabra", count: 160).joined(separator: " ")
        let scene = makeScene(text: words)
        let project = FrameProject(title: "Speech", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage = ["es": 160]
        let appState = makeAppState(project: project)

        XCTAssertEqual(appState.estimatedDuration(for: scene), 60, accuracy: 0.001)
        XCTAssertEqual(appState.sceneDurationSummary(for: scene).estimated, 60, accuracy: 0.001)
    }

    func testRecomputeLearnedWPMPersistsValueFromGoodTakes() {
        let text = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let scenes = (0..<3).map { _ in
            makeScene(
                text: text,
                takes: [makeTake(number: 1, daysAgo: 1, duration: 60, rating: .good, readText: text)]
            )
        }
        let project = FrameProject(title: "Learning", scenes: scenes, primaryLanguage: "es")
        let appState = makeAppState(project: project)

        appState.recomputeLearnedWPM(markDirty: false)

        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
        XCTAssertEqual(project.scenes.first?.estimatedDuration ?? 0, 60, accuracy: 0.001)

        let restored = try? FrameScriptFile(project: project).makeProject()
        XCTAssertEqual(restored?.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
    }

    func testRecomputeReactsWhenATakeIsRatedGood() {
        let text = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let scenes = (0..<3).map { _ in
            makeScene(
                text: text,
                takes: [makeTake(number: 1, daysAgo: 1, duration: 60, rating: .safe, readText: text)]
            )
        }
        let project = FrameProject(title: "Learning", scenes: scenes, primaryLanguage: "es")
        let appState = makeAppState(project: project)

        appState.recomputeLearnedWPM(markDirty: false)
        XCTAssertNil(project.learnedWordsPerMinuteByLanguage["es"])

        for scene in scenes {
            scene.takes[0].rating = .good
        }
        appState.recomputeLearnedWPM(markDirty: false)

        XCTAssertEqual(project.learnedWordsPerMinuteByLanguage["es"] ?? 0, 150, accuracy: 0.0001)
    }

    func testSceneAndProjectTargetSettersIgnoreNonPositiveValues() {
        let scene = makeScene(text: "uno dos")
        let project = FrameProject(title: "Targets", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        appState.setSceneTargetDuration(90, sceneID: scene.id)
        appState.setProjectTargetDuration(600)
        XCTAssertEqual(scene.targetDuration, 90)
        XCTAssertEqual(project.targetDuration, 600)

        appState.setSceneTargetDuration(0, sceneID: scene.id)
        appState.setProjectTargetDuration(-5)
        XCTAssertNil(scene.targetDuration)
        XCTAssertNil(project.targetDuration)
    }

    // MARK: Input

    func testDurationInputParsesMinutesAndSeconds() {
        XCTAssertEqual(DurationInput.parse("1:30") ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("90") ?? 0, 90, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse("1,5") ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(DurationInput.parse(" 0:45 ") ?? 0, 45, accuracy: 0.001)
        XCTAssertNil(DurationInput.parse(""))
        XCTAssertNil(DurationInput.parse("1:75"))
        XCTAssertNil(DurationInput.parse("abc"))
        XCTAssertNil(DurationInput.parse("1:2:3"))
    }

    // MARK: Helpers

    private func makeTake(
        number: Int,
        daysAgo: Double,
        duration: TimeInterval,
        rating: TakeRating,
        language: String = "",
        readText: String = ""
    ) -> Take {
        Take(
            number: number,
            startedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            duration: duration,
            rating: rating,
            languageCode: language,
            readText: readText
        )
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
        target: TimeInterval? = nil
    ) -> Scene {
        Scene(
            order: 0,
            sectionType: .hook,
            title: "Scene",
            scriptText: text,
            targetDuration: target,
            takes: takes
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
}
