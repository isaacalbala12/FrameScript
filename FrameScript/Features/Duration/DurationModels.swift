import Foundation
import FrameScriptCore

// MARK: - Language codes

/// Normalises the BCP-47-ish language codes used by takes and the project.
enum DurationLanguage {
    /// `es-ES`, `ES` and `es_ES` all become `es`. Empty input stays empty.
    static func normalized(_ code: String) -> String {
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return cleaned
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
    }

    /// Code understood by `WPMLearner`/`SpeechLanguage`, if any.
    static func speechLanguage(for code: String) -> SpeechLanguage? {
        SpeechLanguage(rawValue: normalized(code))
    }
}

// MARK: - Scene duration

/// Everything the UI needs to show one scene's estimated, real and target
/// durations. `real` comes from ``DurationTakeSelector``.
struct SceneDurationSummary: Equatable, Sendable {
    let sceneID: UUID
    let estimated: TimeInterval
    let real: TimeInterval?
    let realTakeID: UUID?
    let realTakeNumber: Int?
    let realTakeRating: TakeRating?
    let target: TimeInterval?

    init(
        sceneID: UUID,
        estimated: TimeInterval,
        real: TimeInterval? = nil,
        realTakeID: UUID? = nil,
        realTakeNumber: Int? = nil,
        realTakeRating: TakeRating? = nil,
        target: TimeInterval? = nil
    ) {
        self.sceneID = sceneID
        self.estimated = max(0, estimated)
        self.real = real.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.realTakeID = realTakeID
        self.realTakeNumber = realTakeNumber
        self.realTakeRating = realTakeRating
        self.target = target.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Real duration when a take exists, otherwise the estimate. This is the
    /// value compared against the target and summed into the project.
    var displayed: TimeInterval {
        real ?? estimated
    }

    /// Seconds above the target. Zero when there is no target or it is met.
    var overrun: TimeInterval {
        guard let target, target > 0 else { return 0 }
        return max(0, displayed - target)
    }

    var isOverTarget: Bool {
        overrun > 0
    }

    /// `displayed / target`, or `nil` without a target. Can exceed 1.
    var progress: Double? {
        guard let target, target > 0 else { return nil }
        return displayed / target
    }

    var hasRealTake: Bool {
        real != nil
    }
}

/// Sum of every scene's real-or-estimated duration against the project target.
struct ProjectDurationSummary: Equatable, Sendable {
    let sceneCount: Int
    let estimated: TimeInterval
    let realOrEstimated: TimeInterval
    let recorded: TimeInterval
    let scenesWithReal: Int
    let target: TimeInterval?

    init(
        sceneSummaries: [SceneDurationSummary],
        target: TimeInterval?
    ) {
        sceneCount = sceneSummaries.count
        estimated = sceneSummaries.reduce(0) { $0 + $1.estimated }
        realOrEstimated = sceneSummaries.reduce(0) { $0 + $1.displayed }
        recorded = sceneSummaries.compactMap(\.real).reduce(0, +)
        scenesWithReal = sceneSummaries.filter(\.hasRealTake).count
        self.target = target.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    var allScenesHaveReal: Bool {
        sceneCount > 0 && scenesWithReal == sceneCount
    }

    var overrun: TimeInterval {
        guard let target, target > 0 else { return 0 }
        return max(0, realOrEstimated - target)
    }

    var isOverTarget: Bool {
        overrun > 0
    }

    /// `realOrEstimated / target`, or `nil` without a target. Can exceed 1.
    var progress: Double? {
        guard let target, target > 0 else { return nil }
        return realOrEstimated / target
    }
}

// MARK: - Real take selection

/// F11 selection rules: the good take wins, otherwise the latest take that is
/// not rated bad. Takes with no measured duration are ignored.
enum DurationTakeSelector {
    static func selectedTake(
        from takes: [Take],
        language: String,
        primaryLanguage: String
    ) -> Take? {
        let targetLanguage = DurationLanguage.normalized(language)
        guard !targetLanguage.isEmpty else { return nil }

        let matching = takes.filter { take in
            guard take.duration.isFinite, take.duration > 0 else { return false }
            let code = take.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty take language means "the scene's original language".
            let takeLanguage = code.isEmpty ? primaryLanguage : code
            return DurationLanguage.normalized(takeLanguage) == targetLanguage
        }

        let goodTakes = matching.filter { $0.rating == .good }
        let candidates = goodTakes.isEmpty
            ? matching.filter { $0.rating != .bad }
            : goodTakes
        return candidates.max(by: isOlder)
    }

    static func isOlder(_ lhs: Take, _ rhs: Take) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.number < rhs.number
    }
}

// MARK: - Learning

/// One good take reduced to the sample `WPMLearner` needs.
struct DurationLearningSample: Equatable, Sendable {
    let languageCode: String
    let wordCount: Int
    let duration: TimeInterval
    let startedAt: Date
    let takeNumber: Int
}

/// Learned values plus the diagnostics needed by the project-info popover.
struct DurationLearningResult: Equatable, Sendable {
    let learnedWordsPerMinuteByLanguage: [String: Double]
    let statisticsByLanguage: [String: WPMLanguageStatistics]

    static let empty = DurationLearningResult(
        learnedWordsPerMinuteByLanguage: [:],
        statisticsByLanguage: [:]
    )

    func statistics(for language: String) -> WPMLanguageStatistics? {
        statisticsByLanguage[DurationLanguage.normalized(language)]
    }
}

enum DurationLearning {
    /// Reads every good take. The spoken word count comes from `readText`
    /// (markup-aware); older takes without read text fall back to the scene.
    @MainActor
    static func samples(
        from scenes: [Scene],
        primaryLanguage: String
    ) -> [DurationLearningSample] {
        var samples: [DurationLearningSample] = []
        for scene in scenes {
            for take in scene.takes where take.rating == .good {
                guard take.duration.isFinite, take.duration > 0 else { continue }
                let readText = take.readText.trimmingCharacters(in: .whitespacesAndNewlines)
                let spokenText = readText.isEmpty ? scene.scriptText : take.readText
                let languageCode = take.languageCode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                    ? primaryLanguage
                    : take.languageCode
                samples.append(
                    DurationLearningSample(
                        languageCode: DurationLanguage.normalized(languageCode),
                        wordCount: ScriptMarkup.spokenWordCount(spokenText),
                        duration: take.duration,
                        startedAt: take.startedAt,
                        takeNumber: take.number
                    )
                )
            }
        }
        return samples
    }

    /// Rebuilds the per-language EMA from scratch. Rebuilding makes the result
    /// idempotent, so this is safe to run on every project open and every take
    /// rating change. Takes at or before a reset cutoff are ignored.
    static func recompute(
        samples: [DurationLearningSample],
        resetCutoffs: [String: Date] = [:],
        configuration: WPMConfiguration = WPMConfiguration()
    ) -> DurationLearningResult {
        var grouped: [String: [DurationLearningSample]] = [:]
        for sample in samples {
            let code = DurationLanguage.normalized(sample.languageCode)
            guard DurationLanguage.speechLanguage(for: code) != nil else { continue }
            grouped[code, default: []].append(sample)
        }

        var learned: [String: Double] = [:]
        var statistics: [String: WPMLanguageStatistics] = [:]

        for code in grouped.keys.sorted() {
            guard let speechLanguage = DurationLanguage.speechLanguage(for: code),
                  let languageSamples = grouped[code] else { continue }

            var learner = WPMLearner(configuration: configuration)
            let cutoff = resetCutoffs[code]
            for sample in languageSamples.sorted(by: isOlder) {
                if let cutoff, sample.startedAt <= cutoff { continue }
                learner.record(
                    wordCount: sample.wordCount,
                    duration: sample.duration,
                    source: .take,
                    language: speechLanguage
                )
            }

            let languageStatistics = learner.statistics(for: speechLanguage)
            statistics[code] = languageStatistics
            if languageStatistics.acceptedSampleCount >= max(1, configuration.minimumAcceptedSamples) {
                learned[code] = languageStatistics.effectiveWordsPerMinute
            }
        }

        return DurationLearningResult(
            learnedWordsPerMinuteByLanguage: learned,
            statisticsByLanguage: statistics
        )
    }

    private static func isOlder(_ lhs: DurationLearningSample, _ rhs: DurationLearningSample) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.takeNumber < rhs.takeNumber
    }
}

// MARK: - Target input

/// Parses the small target field. Accepts `m:ss` (`1:30`) and plain seconds
/// (`90`, `90.5`). Values are deliberately not clipped here; callers decide
/// what range is sensible.
enum DurationInput {
    static func parse(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")

        if normalized.contains(":") {
            let parts = normalized.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]),
                  minutes >= 0,
                  seconds >= 0,
                  seconds < 60 else {
                return nil
            }
            return minutes * 60 + seconds
        }

        guard let seconds = Double(normalized), seconds >= 0, seconds.isFinite else {
            return nil
        }
        return seconds
    }

    /// `m:ss` suitable for the target field.
    static func fieldValue(_ duration: TimeInterval) -> String {
        DurationEstimator.formatted(duration)
    }
}
