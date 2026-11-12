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
    /// F3 fixes ~150 WPM for Spanish; English uses the same conservative value.
    public var defaultWordsPerMinute: Double {
        switch self {
        case .spanish: 150
        case .english: 150
        }
    }
}
