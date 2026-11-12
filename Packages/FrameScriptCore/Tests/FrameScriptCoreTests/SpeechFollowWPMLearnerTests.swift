import Foundation
import Testing
@testable import FrameScriptCore

@Test func wpmLearnerReturnsLanguageDefaultInitially() {
    let learner = WPMLearner()
    #expect(learner.effectiveWordsPerMinute(for: .spanish) == 150)
    #expect(learner.effectiveWordsPerMinute(for: .english) == 150)

    let statistics = learner.statistics(for: .spanish)
    #expect(statistics.acceptedSampleCount == 0)
    #expect(statistics.emaWordsPerMinute == nil)
    #expect(statistics.effectiveWordsPerMinute == 150)
}

@Test func wpmLearnerKeepsDefaultUntilMinimumSampleCount() {
    var learner = WPMLearner()
    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .spanish)   // 150
    _ = learner.record(wordCount: 60, duration: 20, source: .teleprompter, language: .spanish) // 180

    #expect(learner.statistics(for: .spanish).acceptedSampleCount == 2)
    #expect(learner.effectiveWordsPerMinute(for: .spanish) == 150)

    _ = learner.record(wordCount: 40, duration: 20, source: .take, language: .spanish) // 120
    #expect(learner.statistics(for: .spanish).acceptedSampleCount == 3)
    #expect(learner.effectiveWordsPerMinute(for: .spanish) < 150)
}

@Test func wpmLearnerUsesExponentialMovingAverage() {
    var learner = WPMLearner(
        configuration: WPMConfiguration(
            defaultWordsPerMinute: [.spanish: 150],
            minimumAcceptedSamples: 3,
            smoothingFactor: 0.3,
            minimumSampleDuration: 5,
            minimumWordsPerMinute: 60,
            maximumWordsPerMinute: 260
        )
    )

    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .spanish) // 150
    _ = learner.record(wordCount: 60, duration: 18, source: .take, language: .spanish) // 200
    // EMA after two samples: 0.3 * 200 + 0.7 * 150 = 165
    #expect(abs((learner.statistics(for: .spanish).emaWordsPerMinute ?? 0) - 165) < 0.0001)
    // Still below minimum sample count.
    #expect(learner.effectiveWordsPerMinute(for: .spanish) == 150)

    _ = learner.record(wordCount: 50, duration: 30, source: .teleprompter, language: .spanish) // 100
    // EMA: 0.3 * 100 + 0.7 * 165 = 145.5
    #expect(abs(learner.effectiveWordsPerMinute(for: .spanish) - 145.5) < 0.0001)
}

@Test func wpmLearnerRejectsShortSamples() {
    var learner = WPMLearner()
    let result = learner.record(
        wordCount: 30,
        duration: 4,
        source: .take,
        language: .spanish
    )

    guard case .rejected(let reason, let wordsPerMinute) = result else {
        Issue.record("Expected rejection")
        return
    }
    #expect(reason == .tooShort)
    #expect(abs((wordsPerMinute ?? 0) - 450) < 0.0001)
    #expect(learner.statistics(for: .spanish).acceptedSampleCount == 0)
    #expect(learner.statistics(for: .spanish).rejectedSampleCount == 1)
}

@Test func wpmLearnerRejectsOutOfRangeSamples() {
    var learner = WPMLearner()

    let slow = learner.record(wordCount: 10, duration: 20, source: .take, language: .spanish) // 30
    guard case .rejected(let slowReason, _) = slow else {
        Issue.record("Expected slow rejection")
        return
    }
    #expect(slowReason == .outOfRange)

    let fast = learner.record(wordCount: 30, duration: 5, source: .take, language: .spanish) // 360
    guard case .rejected(let fastReason, _) = fast else {
        Issue.record("Expected fast rejection")
        return
    }
    #expect(fastReason == .outOfRange)

    #expect(learner.statistics(for: .spanish).rejectedSampleCount == 2)
    #expect(learner.effectiveWordsPerMinute(for: .spanish) == 150)
}

@Test func wpmLearnerAcceptsRangeBoundaries() {
    var learner = WPMLearner()
    let slow = learner.record(wordCount: 5, duration: 5, source: .take, language: .english) // 60
    guard case .accepted(let slowWPM) = slow else {
        Issue.record("Expected boundary sample to be accepted")
        return
    }
    #expect(abs(slowWPM - 60) < 0.0001)

    let fast = learner.record(wordCount: 26, duration: 6, source: .take, language: .english) // 260
    guard case .accepted(let fastWPM) = fast else {
        Issue.record("Expected boundary sample to be accepted")
        return
    }
    #expect(abs(fastWPM - 260) < 0.0001)
}

@Test func wpmLearnerRejectsInvalidInput() {
    var learner = WPMLearner()
    let zeroWords = learner.record(wordCount: 0, duration: 20, source: .take, language: .spanish)
    guard case .rejected(let reason, _) = zeroWords else {
        Issue.record("Expected invalid input rejection")
        return
    }
    #expect(reason == .invalidInput)
    #expect(learner.statistics(for: .spanish).rejectedSampleCount == 1)
    #expect(learner.effectiveWordsPerMinute(for: .spanish) == 150)
}

@Test func wpmLearnerKeepsLanguagesIndependent() {
    var learner = WPMLearner()
    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .spanish)
    _ = learner.record(wordCount: 55, duration: 20, source: .take, language: .spanish)
    _ = learner.record(wordCount: 45, duration: 20, source: .take, language: .spanish)

    #expect(learner.statistics(for: .spanish).acceptedSampleCount == 3)
    #expect(learner.statistics(for: .english).acceptedSampleCount == 0)
    #expect(learner.effectiveWordsPerMinute(for: .english) == 150)
}

@Test func wpmLearnerRecordsSourceAndLastSample() {
    var learner = WPMLearner()
    _ = learner.record(wordCount: 60, duration: 20, source: .teleprompter, language: .spanish)

    let statistics = learner.statistics(for: .spanish)
    #expect(statistics.lastSource == .teleprompter)
    #expect(abs((statistics.lastSampleWordsPerMinute ?? 0) - 180) < 0.0001)
}

@Test func wpmLearnerSupportsCustomMinimumSampleCount() {
    var configuration = WPMConfiguration()
    configuration.minimumAcceptedSamples = 1
    var learner = WPMLearner(configuration: configuration)

    _ = learner.record(wordCount: 60, duration: 20, source: .take, language: .spanish)
    #expect(abs(learner.effectiveWordsPerMinute(for: .spanish) - 180) < 0.0001)
}

@Test func wpmLearnerSurvivesCodableRoundTrip() throws {
    var learner = WPMLearner()
    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .spanish)
    _ = learner.record(wordCount: 60, duration: 20, source: .teleprompter, language: .spanish)
    _ = learner.record(wordCount: 40, duration: 20, source: .take, language: .spanish)

    let data = try JSONEncoder().encode(learner)
    let decoded = try JSONDecoder().decode(WPMLearner.self, from: data)

    #expect(decoded == learner)
    #expect(abs(decoded.effectiveWordsPerMinute(for: .spanish) - learner.effectiveWordsPerMinute(for: .spanish)) < 0.0001)
}

@Test func wpmLearnerResetForgetsOneOrAllLanguages() {
    var learner = WPMLearner()
    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .spanish)
    _ = learner.record(wordCount: 50, duration: 20, source: .take, language: .english)

    learner.reset(language: .spanish)
    #expect(learner.statistics(for: .spanish).acceptedSampleCount == 0)
    #expect(learner.statistics(for: .english).acceptedSampleCount == 1)

    learner.reset()
    #expect(learner.statistics(for: .english).acceptedSampleCount == 0)
}
