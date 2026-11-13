import Foundation
import FrameScriptCore

/// Everything the estimator needs to turn a script into seconds.
///
/// The app resolves one of these per scene (language, learned rate, pause
/// defaults) and passes it around instead of a bare words-per-minute value.
struct DurationConfiguration: Equatable, Sendable {
    /// Speaking rate, in words per minute, used for the spoken words.
    var wordsPerMinute: Double
    /// Durations of `/` and `//` (plus bare `[pausa]`).
    var pauseDefaults: PauseDefaults

    /// Used by tests and by callers that have no project or settings yet.
    static let standard = DurationConfiguration(wordsPerMinute: 150, pauseDefaults: .standard)

    init(wordsPerMinute: Double, pauseDefaults: PauseDefaults = .standard) {
        self.wordsPerMinute = wordsPerMinute.isFinite ? wordsPerMinute : 0
        self.pauseDefaults = pauseDefaults
    }
}

/// Estimates scene and project duration from a script.
///
/// The estimate uses `ScriptMarkup.estimateDuration`: spoken words only
/// (markers and cues such as `[IMAGEN: …]` never count) plus every pause
/// marker. Reading speed is per language: the project's learned rate (F11)
/// wins, then an explicit per-language setting, then a customized legacy global
/// rate, then the built-in default for `es`/`en`/`ru`, then the global rate.
enum DurationEstimator {
    /// Built-in reading speeds used until the user or the project says
    /// otherwise.
    static let defaultWordsPerMinuteByLanguage: [String: Int] = [
        "es": 150,
        "en": 160,
        "ru": 140
    ]

    /// Value `EditorPreferences.wordsPerMinute` had before per-language rates
    /// existed. A different value is treated as a deliberate global choice and
    /// keeps applying to every language.
    static let defaultLegacyWordsPerMinute = 150

    /// Lowest and highest learned rate accepted from `FrameProject`. Values
    /// outside this range are treated as missing so a corrupt measurement never
    /// produces an absurd estimate.
    static let learnedWordsPerMinuteRange: ClosedRange<Double> = 30...400

    // MARK: - Estimating

    /// Estimates the duration of marker-free or marked-up text.
    ///
    /// Kept for source compatibility with existing call sites. Pauses use
    /// `PauseDefaults.standard`; prefer ``estimate(text:configuration:)`` or one
    /// of the language-aware overloads.
    static func estimate(text: String, wordsPerMinute: Int) -> TimeInterval {
        estimate(
            text: text,
            configuration: DurationConfiguration(wordsPerMinute: Double(wordsPerMinute))
        )
    }

    /// Markup-aware estimate: only spoken words count and inline pauses add
    /// their real duration. Callers pass the learned per-language pace.
    static func estimate(text: String, wordsPerMinute: Double) -> TimeInterval {
        let pace = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 0
        return estimate(
            text: text,
            configuration: DurationConfiguration(wordsPerMinute: pace)
        )
    }

    static func estimate(text: String, configuration: DurationConfiguration) -> TimeInterval {
        ScriptMarkup.estimateDuration(
            text,
            wordsPerMinute: configuration.wordsPerMinute,
            defaults: configuration.pauseDefaults
        )
    }

    static func estimate(text: String, language: String, settings: AppSettings) -> TimeInterval {
        estimate(
            text: text,
            configuration: configuration(language: language, project: nil, settings: settings)
        )
    }

    static func estimate(text: String, language: AppLanguage, settings: AppSettings) -> TimeInterval {
        estimate(text: text, language: language.code, settings: settings)
    }

    /// Uses the project's learned rate for `language` when it exists (F11) and
    /// the app defaults otherwise.
    static func estimate(
        text: String,
        language: String,
        project: FrameProject?,
        settings: AppSettings
    ) -> TimeInterval {
        estimate(
            text: text,
            configuration: configuration(language: language, project: project, settings: settings)
        )
    }

    // MARK: - Resolving the effective rate

    static func configuration(
        language: String,
        project: FrameProject?,
        settings: AppSettings
    ) -> DurationConfiguration {
        configuration(
            language: language,
            learnedWordsPerMinute: project?.learnedWordsPerMinuteByLanguage ?? [:],
            settings: settings
        )
    }

    static func configuration(
        language: String,
        learnedWordsPerMinute: [String: Double],
        settings: AppSettings
    ) -> DurationConfiguration {
        DurationConfiguration(
            wordsPerMinute: effectiveWordsPerMinute(
                language: language,
                learnedWordsPerMinute: learnedWordsPerMinute,
                settings: settings
            ),
            pauseDefaults: pauseDefaults(settings: settings)
        )
    }

    /// Learned rate first, then the user's explicit or legacy global setting,
    /// then the built-in value for `es`/`en`/`ru`.
    static func effectiveWordsPerMinute(
        language: String,
        learnedWordsPerMinute: [String: Double],
        settings: AppSettings
    ) -> Double {
        let code = normalizedLanguageCode(language)
        if let learned = learnedWordsPerMinute[code] ?? learnedWordsPerMinute[language],
           learned.isFinite,
           learnedWordsPerMinuteRange.contains(learned) {
            return learned
        }
        return settings.editorPreferences.effectiveWordsPerMinute(for: code)
    }

    static func pauseDefaults(settings: AppSettings) -> PauseDefaults {
        settings.editorPreferences.markupPauseDefaults
    }

    /// Normalises BCP-47-ish codes to the two-letter keys used by settings and
    /// `FrameProject.learnedWordsPerMinuteByLanguage`.
    static func normalizedLanguageCode(_ language: String) -> String {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? trimmed.prefix(2))
    }

    // MARK: - Formatting

    /// `m:ss` (or `h:mm:ss`) for a non-negative duration, clamped and rounded
    /// to seconds. Values read from disk or typed by the user are untrusted, so
    /// the conversion never traps.
    static func formatted(_ interval: TimeInterval) -> String {
        let maximumFormattable: TimeInterval = 999_999_999
        let safeInterval = interval.isFinite ? min(max(interval, 0), maximumFormattable) : 0
        let seconds = Int(safeInterval.rounded())
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainder))"
        }
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}
