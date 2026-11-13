import Foundation
import FrameScriptCore

extension AppLanguage {
    /// Two-letter code used by settings, the document schema and learned WPM.
    var code: String {
        switch self {
        case .spanish: "es"
        case .english: "en"
        case .russian: "ru"
        case .system: Locale.current.language.languageCode?.identifier ?? "es"
        }
    }
}

extension EditorPreferences {
    /// The pause durations the editor, estimator and rhythm review must agree
    /// on. Values are clamped by `PauseDefaults` itself.
    var markupPauseDefaults: PauseDefaults {
        PauseDefaults(short: shortPauseSeconds, long: longPauseSeconds)
    }

    /// Reading speed for a language code.
    ///
    /// Order: explicit per-language setting → customized legacy global rate →
    /// built-in default for `es`/`en`/`ru` → the global rate. The global rate
    /// equal to its old default (`150`) counts as unchanged, so the per-language
    /// defaults still apply to new users.
    func effectiveWordsPerMinute(for language: String) -> Double {
        let code = DurationEstimator.normalizedLanguageCode(language)
        if let explicit = wordsPerMinuteByLanguage[code], explicit > 0 {
            return Double(explicit)
        }
        if wordsPerMinute != DurationEstimator.defaultLegacyWordsPerMinute {
            return Double(max(1, wordsPerMinute))
        }
        if let builtIn = DurationEstimator.defaultWordsPerMinuteByLanguage[code] {
            return Double(builtIn)
        }
        return Double(max(1, wordsPerMinute))
    }

    /// True when the user customized the rate for this language.
    func hasCustomWordsPerMinute(for language: String) -> Bool {
        let code = DurationEstimator.normalizedLanguageCode(language)
        return (wordsPerMinuteByLanguage[code] ?? 0) > 0
    }

    mutating func setWordsPerMinute(_ wordsPerMinute: Int, for language: String) {
        let code = DurationEstimator.normalizedLanguageCode(language)
        guard !code.isEmpty else { return }
        wordsPerMinuteByLanguage[code] = min(max(30, wordsPerMinute), 400)
    }

    mutating func resetWordsPerMinute(for language: String) {
        let code = DurationEstimator.normalizedLanguageCode(language)
        wordsPerMinuteByLanguage.removeValue(forKey: code)
    }

    /// Languages shown in Settings, in the order the app speaks them.
    static let configurableDurationLanguages: [String] = ["es", "en", "ru"]
}
