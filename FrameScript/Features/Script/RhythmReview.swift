import Foundation
import FrameScriptCore

/// App-side glue between the document model and `RhythmAnalyzer`.
///
/// Everything here is deterministic and testable without SwiftUI: the editor,
/// the sidebar badge and the review panel all consume the same warnings.
enum RhythmReview {
    /// Starts of anchored B-roll and editing items. Those are the points where
    /// the video changes image, so they split the "no visual change" stretches
    /// analyzed by `RhythmAnalyzer`.
    static func visualChangeOffsets(for scene: Scene) -> [Int] {
        var offsets = Set<Int>()
        for item in scene.bRollItems {
            if let anchor = TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) {
                offsets.insert(anchor.startUTF16)
            }
        }
        for item in scene.editingItems {
            if let anchor = TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) {
                offsets.insert(anchor.startUTF16)
            }
        }
        return offsets.sorted()
    }

    /// Builds the analyzer input for one scene.
    static func input(
        for scene: Scene,
        wordsPerMinute: Double
    ) -> RhythmSceneInput {
        RhythmSceneInput(
            id: scene.id.uuidString,
            text: scene.scriptText,
            wordsPerMinute: wordsPerMinute,
            visualChangeOffsets: visualChangeOffsets(for: scene),
            role: scene.sectionType == .hook ? .hook : .normal
        )
    }

    /// `RhythmAnalyzer.analyzeProject` shares one pause provider across scenes,
    /// which cannot work when each scene has its own text. The app analyzes
    /// scenes individually and applies the same outlier rule here.
    ///
    /// Mirrors the core implementation: empty scenes are ignored for the
    /// average, at least two non-empty scenes are required, and the factor must
    /// be finite and positive.
    static func sceneLengthOutlierWarnings(
        from analyses: [RhythmSceneAnalysis],
        factor: Double
    ) -> [RhythmWarning] {
        let nonEmptyDurations = analyses
            .map(\.durationSeconds)
            .filter { $0.isFinite && $0 > 0 }
        guard nonEmptyDurations.count >= 2,
              factor.isFinite,
              factor > 0 else { return [] }
        let average = nonEmptyDurations.reduce(0, +) / Double(nonEmptyDurations.count)
        guard average.isFinite, average > 0 else { return [] }

        var warnings: [RhythmWarning] = []
        for analysis in analyses {
            guard analysis.durationSeconds > average * factor else { continue }
            warnings.append(RhythmWarning(
                sceneID: analysis.sceneID,
                kind: .sceneLengthOutlier,
                range: UTF16Span(location: 0, length: analysis.utf16Length),
                messageKey: RhythmMessageKey.sceneLengthOutlier,
                arguments: [
                    RhythmArgument("seconds", analysis.durationSeconds),
                    RhythmArgument("average", average),
                    RhythmArgument("factor", factor)
                ]
            ))
        }
        return warnings.sorted { lhs, rhs in
            (lhs.sceneID ?? "") < (rhs.sceneID ?? "")
        }
    }

    /// Sums the pause markers inside a range. Analyzer pauses must match
    /// `ScriptMarkup`, so both the editor styling and the rhythm review use the
    /// same configured short/long values.
    static func pauseDuration(
        in span: UTF16Span,
        pauses: [(range: NSRange, seconds: TimeInterval)]
    ) -> TimeInterval {
        guard span.length > 0 else { return 0 }
        let spanEnd = span.end
        var total = 0.0
        for pause in pauses {
            let pauseStart = pause.range.location
            let pauseEnd = NSMaxRange(pause.range)
            guard pauseEnd > span.location, pauseStart < spanEnd else { continue }
            total += pause.seconds
        }
        return total
    }

    /// Flattens `[pausa]` markers into ranges and seconds for ``pauseDuration``.
    static func pauses(in text: String, defaults: PauseDefaults) -> [(range: NSRange, seconds: TimeInterval)] {
        ScriptMarkup.parse(text, defaults: defaults).compactMap { token in
            guard case .pause(let seconds, _) = token.kind else { return nil }
            return (token.range, seconds)
        }
    }

    /// Effective thresholds for one project.
    ///
    /// Precedence: project override → app default for the project's video type
    /// → core defaults. Overrides only replace the fields they set; the rest
    /// keep the lower layer's value.
    static func effectiveThresholds(
        project: FrameProject,
        settings: AppSettings
    ) -> RhythmCalibration {
        let videoType = project.videoType.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeOverride = settings.rhythmThresholdsByVideoType[videoType]
        var calibration = (typeOverride ?? AppRhythmThresholds())
            .applied(to: .standard)
        if let projectOverride = project.rhythmThresholdsOverride {
            calibration = projectOverride.applied(to: calibration)
        }
        return calibration
    }
}

/// App-side copy of the analyzer limits.
///
/// `FrameScriptCore` already exports `RhythmThresholds`, but this target also
/// has an app-level `RhythmThresholds` (the persisted override shape). The app
/// value type avoids the name clash and is converted with `.init(...)` only at
/// the `RhythmAnalyzer` call site.
struct RhythmCalibration: Equatable, Sendable {
    var maxSentenceWords: Int
    var maxSentenceSeconds: Double
    var maxSecondsWithoutVisualChange: Double
    var hookMaxSeconds: Double
    var sceneLengthOutlierFactor: Double

    init(
        maxSentenceWords: Int = 25,
        maxSentenceSeconds: Double = 9,
        maxSecondsWithoutVisualChange: Double = 5,
        hookMaxSeconds: Double = 15,
        sceneLengthOutlierFactor: Double = 1.8
    ) {
        self.maxSentenceWords = maxSentenceWords
        self.maxSentenceSeconds = maxSentenceSeconds
        self.maxSecondsWithoutVisualChange = maxSecondsWithoutVisualChange
        self.hookMaxSeconds = hookMaxSeconds
        self.sceneLengthOutlierFactor = sceneLengthOutlierFactor
    }

    /// Mirrors `FrameScriptCore.RhythmThresholds.default`.
    static let standard = RhythmCalibration()
}

extension AppRhythmThresholds {
    /// Values shown when a video type has no override yet. Matches the core
    /// defaults (25 words, 5 s, 1.8×, 15 s).
    static let appDefaults = AppRhythmThresholds(
        longSentenceWordLimit: 25,
        uncoveredSecondsLimit: 5,
        sceneLengthRatioLimit: 1.8,
        hookSecondsLimit: 15
    )

    init(core: RhythmCalibration) {
        self.init(
            longSentenceWordLimit: core.maxSentenceWords,
            uncoveredSecondsLimit: core.maxSecondsWithoutVisualChange,
            sceneLengthRatioLimit: core.sceneLengthOutlierFactor,
            hookSecondsLimit: core.hookMaxSeconds
        )
    }

    /// Applies only the non-`nil` fields on top of `base`.
    func applied(to base: RhythmCalibration) -> RhythmCalibration {
        var thresholds = base
        if let longSentenceWordLimit {
            thresholds.maxSentenceWords = max(1, longSentenceWordLimit)
        }
        if let uncoveredSecondsLimit {
            thresholds.maxSecondsWithoutVisualChange = max(0.1, uncoveredSecondsLimit)
        }
        if let sceneLengthRatioLimit {
            thresholds.sceneLengthOutlierFactor = max(1.01, sceneLengthRatioLimit)
        }
        if let hookSecondsLimit {
            thresholds.hookMaxSeconds = max(0.1, hookSecondsLimit)
        }
        return thresholds
    }
}

/// Localized warning text for tooltips and the review panel.
enum RhythmWarningFormatter {
    static func text(for warning: RhythmWarning, language: AppLanguage) -> String {
        let template = L10n.tr(warning.messageKey, language: language)
        let locale = locale(for: language)
        switch warning.kind {
        case .longSentence:
            return String(
                format: template,
                locale: locale,
                Int(argument("words", in: warning).rounded()),
                argument("seconds", in: warning),
                Int(argument("maxWords", in: warning).rounded()),
                argument("maxSeconds", in: warning)
            )
        case .noVisualChange, .longHook:
            return String(
                format: template,
                locale: locale,
                argument("seconds", in: warning),
                argument("limit", in: warning)
            )
        case .sceneLengthOutlier:
            return String(
                format: template,
                locale: locale,
                argument("seconds", in: warning),
                argument("average", in: warning),
                argument("factor", in: warning)
            )
        }
    }

    static func argument(_ name: String, in warning: RhythmWarning) -> Double {
        warning.arguments.first { $0.name == name }?.value ?? 0
    }

    static func locale(for language: AppLanguage) -> Locale {
        switch language {
        case .english: Locale(identifier: "en_US")
        case .spanish: Locale(identifier: "es_ES")
        case .russian: Locale(identifier: "ru_RU")
        case .system: .current
        }
    }
}
