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
        let typeOverride = videoTypeThresholds(for: project.videoType, settings: settings)
        var calibration = (typeOverride ?? AppRhythmThresholds())
            .applied(to: .standard)
        if let projectOverride = project.rhythmThresholdsOverride {
            calibration = projectOverride.applied(to: calibration)
        }
        return calibration
    }

    /// Thresholds stored for `rawVideoType`, matching through
    /// ``VideoTypeID/canonicalID(for:)`` so tables saved under the old Spanish
    /// display names ("Análisis") and the importer's English ids ("review")
    /// both keep working without a migration.
    static func videoTypeThresholds(
        for rawVideoType: String,
        settings: AppSettings
    ) -> AppRhythmThresholds? {
        guard let key = storageKey(
            for: rawVideoType,
            in: settings.rhythmThresholdsByVideoType
        ) else { return nil }
        return settings.rhythmThresholdsByVideoType[key]
    }

    /// Writes the table under the key that already represents this video type,
    /// so an existing legacy key is updated instead of shadowed by a new one.
    static func setVideoTypeThresholds(
        _ thresholds: AppRhythmThresholds,
        for rawVideoType: String,
        in settings: inout AppSettings
    ) {
        let canonical = VideoTypeID.canonicalID(for: rawVideoType)
        guard !canonical.isEmpty else { return }
        let key = storageKey(
            for: rawVideoType,
            in: settings.rhythmThresholdsByVideoType
        ) ?? canonical
        settings.rhythmThresholdsByVideoType[key] = thresholds
    }

    /// Removes every key that means `rawVideoType`, legacy spellings included.
    static func removeVideoTypeThresholds(
        for rawVideoType: String,
        in settings: inout AppSettings
    ) {
        let canonical = VideoTypeID.canonicalID(for: rawVideoType)
        guard !canonical.isEmpty else { return }
        for key in settings.rhythmThresholdsByVideoType.keys.sorted()
        where VideoTypeID.canonicalID(for: key) == canonical {
            settings.rhythmThresholdsByVideoType.removeValue(forKey: key)
        }
    }

    /// The rows of the rhythm threshold table, in display order.
    ///
    /// Built-in ids stay visible so the table is useful before any project
    /// defines a type; custom types and the open project's type are appended.
    static func videoTypeIDs(
        projectVideoType: String,
        settings: AppSettings,
        language: AppLanguage
    ) -> [String] {
        var ids = Set(VideoTypeID.builtIn)
        for key in settings.rhythmThresholdsByVideoType.keys {
            let id = VideoTypeID.canonicalID(for: key)
            if !id.isEmpty { ids.insert(id) }
        }
        let projectID = VideoTypeID.canonicalID(for: projectVideoType)
        if !projectID.isEmpty { ids.insert(projectID) }
        return ids.sorted { lhs, rhs in
            let left = VideoTypeID.displayName(lhs, language: language)
            let right = VideoTypeID.displayName(rhs, language: language)
            let order = left.localizedCaseInsensitiveCompare(right)
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
    }

    /// The key that holds the table for `rawVideoType`: the canonical id when
    /// it exists, otherwise the first legacy spelling that normalises to it.
    private static func storageKey(
        for rawVideoType: String,
        in table: [String: AppRhythmThresholds]
    ) -> String? {
        let canonical = VideoTypeID.canonicalID(for: rawVideoType)
        guard !canonical.isEmpty else { return nil }
        if table[canonical] != nil { return canonical }
        return table.keys.sorted().first {
            VideoTypeID.canonicalID(for: $0) == canonical
        }
    }
}

/// Stable identifiers for the built-in video types.
///
/// The rhythm threshold table is persisted by id, so the labels can be
/// translated and reworded without orphaning anyone's thresholds. Settings
/// saved by older builds use the Spanish display names, and the escaleta
/// importer already writes English ids; ``canonicalID(for:)`` maps every
/// historical spelling to one id.
enum VideoTypeID {
    static let analysis = "analysis"
    static let gameplay = "gameplay"
    static let review = "review"
    static let comparison = "comparison"
    static let news = "news"
    static let chronicle = "chronicle"
    static let tutorial = "tutorial"
    static let update = "update"
    static let vantare = "vantare"

    /// Built-in types shown in Settings, always in this order before sorting.
    static let builtIn: [String] = [
        analysis, gameplay, review, comparison, news, chronicle, tutorial, update, vantare
    ]

    /// Normalises a stored or project-supplied video type to its stable id.
    /// Unknown types keep their trimmed text so custom types still work.
    static func canonicalID(for rawVideoType: String) -> String {
        let trimmed = rawVideoType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let folded = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch folded {
        case "analysis", "analisis": return analysis
        case "gameplay": return gameplay
        case "review": return review
        case "comparison", "comparativa": return comparison
        case "news", "noticia": return news
        case "chronicle", "cronica": return chronicle
        case "tutorial": return tutorial
        case "update", "actualizacion": return update
        case "vantare": return vantare
        default: return trimmed
        }
    }

    /// Localized label for a built-in id; custom types show their own text.
    static func displayName(_ id: String, language: AppLanguage) -> String {
        guard builtIn.contains(id) else { return id }
        let key = "videoType.\(id)"
        let value = L10n.tr(key, language: language)
        return value == key ? id : value
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
