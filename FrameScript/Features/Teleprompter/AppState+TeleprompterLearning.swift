import Foundation
import FrameScriptCore

/// Identity of one accepted teleprompter reading. The same report can arrive
/// twice (window teardown plus an explicit stop); the second one must not teach
/// the learner twice.
struct TeleprompterLearningSignature: Equatable, Sendable {
    let projectID: UUID
    let languageCode: String
    let spokenWords: Int
    let duration: TimeInterval
}

@MainActor
extension AppState: TeleprompterReadingSessionReporting {
    /// Minimum session worth learning from. Shorter reports are dominated by
    /// recognition latency and would distort every estimate in the project.
    static let minimumTeleprompterLearningWords = 20
    static let minimumTeleprompterLearningDuration: TimeInterval = 10

    func teleprompterDidFinishReadingSession(_ session: TeleprompterReadingSession) {
        _ = recordTeleprompterReadingSession(session)
    }

    /// Folds one finished voice-follow reading into the project's learned pace
    /// (F11). Returns whether the project changed.
    @discardableResult
    func recordTeleprompterReadingSession(
        _ session: TeleprompterReadingSession,
        now: Date = Date()
    ) -> Bool {
        guard hasOpenProject else { return false }
        guard session.spokenWords >= Self.minimumTeleprompterLearningWords,
              session.duration >= Self.minimumTeleprompterLearningDuration,
              session.duration.isFinite,
              session.spokenWords > 0 else {
            return false
        }

        let code = DurationLanguage.normalized(session.language.rawValue)
        guard let speechLanguage = DurationLanguage.speechLanguage(for: code) else { return false }

        // A reset makes older evidence stop teaching. The session just finished,
        // so a cutoff at or after `now` (for example a reset while reading) wins.
        if let cutoff = project.learnedWordsPerMinuteResetAtByLanguage[code], now <= cutoff {
            return false
        }

        let signature = TeleprompterLearningSignature(
            projectID: project.id,
            languageCode: code,
            spokenWords: session.spokenWords,
            // Millisecond precision: a duplicate report can differ in the last
            // bits and must still be recognised as the same reading.
            duration: (session.duration * 1_000).rounded() / 1_000
        )
        guard lastTeleprompterLearningSignature != signature else { return false }

        var configuration = WPMConfiguration()
        configuration.minimumAcceptedSamples = 1
        configuration.minimumSampleDuration = Self.minimumTeleprompterLearningDuration
        var learner = WPMLearner(configuration: configuration)

        // Seed the EMA with the value currently in use, so one session nudges
        // the pace instead of replacing it. The synthetic sample only carries
        // the old rate; it is not stored anywhere.
        if let existing = project.learnedWordsPerMinuteByLanguage[code],
           existing.isFinite,
           existing > 0,
           DurationLimits.plausibleWordsPerMinute.contains(existing) {
            learner.record(
                wordCount: 100,
                duration: 6_000 / existing,
                source: .teleprompter,
                language: speechLanguage
            )
        }

        let sample = WPMSample(
            wordCount: session.spokenWords,
            duration: session.duration,
            source: .teleprompter
        )
        guard case .accepted = learner.record(sample, language: speechLanguage) else { return false }

        let updated = learner.effectiveWordsPerMinute(for: speechLanguage)
        guard updated.isFinite,
              DurationLimits.plausibleWordsPerMinute.contains(updated) else {
            return false
        }

        project.learnedWordsPerMinuteByLanguage[code] = updated
        lastTeleprompterLearningSignature = signature
        refreshDurationEstimates()
        touchProject()
        return true
    }
}
