import Foundation

/// Language used by the speech-following pipeline.
///
/// The app translates only between Spanish and English, and those are the two
/// locales F9 requires for on-device recognition. The Russian UI is unaffected.
public enum SpeechLanguage: String, CaseIterable, Codable, Sendable, Hashable {
    case spanish = "es"
    case english = "en"

    /// Locale identifier passed to `SFSpeechRecognizer`.
    public var localeIdentifier: String {
        switch self {
        case .spanish: "es-ES"
        case .english: "en-US"
        }
    }

    /// Starting point used until the learner has enough personal samples.
    ///
    /// This is the single English default: `DurationEstimator` builds its
    /// per-language table from these values, so the editor estimate, the
    /// teleprompter and the learner can never disagree again.
    public var defaultWordsPerMinute: Double {
        switch self {
        case .spanish: 150
        case .english: 160
        }
    }
}
