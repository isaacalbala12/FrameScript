import Foundation
import FrameScriptCore

// MARK: - Limits and formatting

/// Untrusted duration inputs (typed targets, documents from disk) are kept in
/// a range the UI can safely compare, format and convert to integers.
enum DurationLimits {
    static let minimumTarget: TimeInterval = 0.1
    static let maximumDuration: TimeInterval = 86_400
    static let plausibleWordsPerMinute: ClosedRange<Double> = 30...400

    static func sanitizedTarget(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, isPlausibleDuration(value) else { return nil }
        return min(max(value, minimumTarget), maximumDuration)
    }

    static func isPlausibleDuration(_ value: TimeInterval, allowingZero: Bool = false) -> Bool {
        guard value.isFinite else { return false }
        let lowerBound = allowingZero ? 0 : minimumTarget
        return value >= lowerBound && value <= maximumDuration
    }
}

enum DurationNumber {
    /// Converts a Double to Int without trapping on NaN, infinity or values
    /// larger than `Int.max`.
    static func clampedInt(_ value: Double, range: ClosedRange<Int>) -> Int {
        guard value.isFinite else { return range.lowerBound }
        let rounded = value.rounded()
        if rounded <= Double(range.lowerBound) { return range.lowerBound }
        if rounded >= Double(range.upperBound) { return range.upperBound }
        return Int(rounded)
    }

    static func percent(_ fraction: Double) -> Int {
        clampedInt(fraction * 100, range: 0...9_999)
    }
}

extension AppLanguage {
    /// Project script language for newly created content.
    var contentLanguageCode: String {
        switch L10n.resolve(self) {
        case .system, .english: "en"
        case .spanish: "es"
        case .russian: "ru"
        }
    }
}

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
        self.estimated = estimated.isFinite
            ? min(max(0, estimated), DurationLimits.maximumDuration)
            : 0
        self.real = real.flatMap {
            DurationLimits.isPlausibleDuration($0) ? $0 : nil
        }
        self.realTakeID = self.real == nil ? nil : realTakeID
        self.realTakeNumber = self.real == nil ? nil : realTakeNumber
        self.realTakeRating = self.real == nil ? nil : realTakeRating
        self.target = DurationLimits.sanitizedTarget(target)
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
        let value = displayed / target
        return value.isFinite ? value : nil
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
        self.target = DurationLimits.sanitizedTarget(target)
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
        let value = realOrEstimated / target
        return value.isFinite ? value : nil
    }

    /// Total the toolbar compares with the target.
    var displayTotal: TimeInterval {
        realOrEstimated
    }
}

// MARK: - Real take selection

/// One take together with the text it was recorded against. Scene takes and
/// translated-variant takes share this shape so selection and learning can
/// treat them uniformly.
struct DurationTakeRecord: Equatable, Sendable {
    let take: Take
    let languageCode: String
    let sourceText: String
    let sourceTextHash: String

    var normalizedLanguage: String {
        DurationLanguage.normalized(languageCode)
    }

    /// A take only describes the current scene while its hash matches. Empty
    /// hashes are legacy takes written before the hash existed.
    var matchesSourceText: Bool {
        take.sceneTextHash.isEmpty || take.sceneTextHash == sourceTextHash
    }

    var isUsableRealTake: Bool {
        matchesSourceText && DurationLimits.isPlausibleDuration(take.duration)
    }
}

/// F11 selection rules: the good take wins, otherwise the latest take that is
/// not rated bad. Stale takes (scene text changed since recording) are ignored.
enum DurationTakeSelector {
    static func selectedTake(
        from records: [DurationTakeRecord],
        language: String
    ) -> DurationTakeRecord? {
        let targetLanguage = DurationLanguage.normalized(language)
        guard !targetLanguage.isEmpty else { return nil }

        let matching = records.filter {
            $0.normalizedLanguage == targetLanguage && $0.isUsableRealTake
        }

        let goodTakes = matching.filter { $0.take.rating == .good }
        let candidates = goodTakes.isEmpty
            ? matching.filter { $0.take.rating != .bad }
            : goodTakes
        return candidates.max(by: isOlder)
    }

    static func isOlder(_ lhs: DurationTakeRecord, _ rhs: DurationTakeRecord) -> Bool {
        if lhs.take.startedAt != rhs.take.startedAt {
            return lhs.take.startedAt < rhs.take.startedAt
        }
        return lhs.take.number < rhs.take.number
    }
}

// MARK: - Learning

/// One good take reduced to the sample `WPMLearner` needs. `duration` is the
/// speaking time: wall-clock take duration minus the inline pauses, so pause
/// heavy takes do not bias the learned words-per-minute value.
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
    /// Reads every good scene take and every good variant take. Pauses are
    /// removed from the measured speaking time; word counts use `readText`
    /// (markup-aware). A take without read text is only usable while its scene
    /// text hash still matches, so editing the script cannot retroactively
    /// rewrite history.
    @MainActor
    static func samples(
        from scenes: [Scene],
        primaryLanguage: String
    ) -> [DurationLearningSample] {
        let primary = DurationLanguage.normalized(primaryLanguage)
        var samples: [DurationLearningSample] = []

        for scene in scenes {
            let sceneHash = FrameScriptDocument.TextHash.hash(scene.scriptText)
            for take in scene.takes {
                let language = take.languageCode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty ? primary : take.languageCode
                if let sample = makeSample(
                    take: take,
                    languageCode: language,
                    sourceText: scene.scriptText,
                    sourceTextHash: sceneHash
                ) {
                    samples.append(sample)
                }
            }

            for variant in scene.languageVariants {
                let variantHash = FrameScriptDocument.TextHash.hash(variant.text)
                for take in variant.takes {
                    if let sample = makeSample(
                        take: take,
                        languageCode: variant.languageCode,
                        sourceText: variant.text,
                        sourceTextHash: variantHash
                    ) {
                        samples.append(sample)
                    }
                }
            }
        }

        return samples
    }

    private static func makeSample(
        take: Take,
        languageCode: String,
        sourceText: String,
        sourceTextHash: String
    ) -> DurationLearningSample? {
        guard take.rating == .good,
              DurationLimits.isPlausibleDuration(take.duration) else {
            return nil
        }
        let readText = take.readText.trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenText: String
        if !readText.isEmpty {
            spokenText = take.readText
        } else {
            guard take.sceneTextHash.isEmpty || take.sceneTextHash == sourceTextHash else {
                return nil
            }
            spokenText = sourceText
        }

        let pauseSeconds = ScriptMarkup.estimateDuration(spokenText, wordsPerMinute: 0)
        let speakingDuration = take.duration - pauseSeconds
        guard speakingDuration.isFinite, speakingDuration > 0 else { return nil }

        return DurationLearningSample(
            languageCode: DurationLanguage.normalized(languageCode),
            wordCount: ScriptMarkup.spokenWordCount(spokenText),
            duration: speakingDuration,
            startedAt: take.startedAt,
            takeNumber: take.number
        )
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

/// Parses the small target field. Accepts `m:ss` (`1:30`), fractional seconds
/// (`1:30.5`) and plain seconds (`90`). Results are bounded to the same range
/// the model and formatter accept.
enum DurationInput {
    static func parse(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")

        let value: Double?
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
            value = minutes * 60 + seconds
        } else {
            value = Double(normalized)
        }

        guard let value,
              value.isFinite,
              value >= DurationLimits.minimumTarget,
              value <= DurationLimits.maximumDuration else {
            return nil
        }
        return value
    }

    /// Target-field text that round-trips through ``parse(_:)``, preserving
    /// fractional seconds for small targets.
    static func fieldValue(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "0:00" }
        let clamped = min(max(duration, DurationLimits.minimumTarget), DurationLimits.maximumDuration)
        let minutes = Int(clamped / 60)
        let seconds = clamped - Double(minutes * 60)
        let wholeSeconds = Int(seconds)
        let fraction = seconds - Double(wholeSeconds)

        if fraction < 0.0005 {
            return "\(minutes):\(String(format: "%02d", wholeSeconds))"
        }

        var fractionText = String(format: "%.3f", fraction)
        if fractionText.hasPrefix("0") {
            fractionText.removeFirst()
        }
        while fractionText.last == "0" {
            fractionText.removeLast()
        }
        return "\(minutes):\(String(format: "%02d", wholeSeconds))\(fractionText)"
    }
}
