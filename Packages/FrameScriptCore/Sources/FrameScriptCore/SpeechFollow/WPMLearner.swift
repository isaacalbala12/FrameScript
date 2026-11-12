import Foundation

/// Where a WPM sample came from.
public enum WPMSampleSource: String, Sendable, Codable, CaseIterable, Hashable {
    /// A recorded take (ideally the good take of a scene).
    case take
    /// A teleprompter session with speech following enabled.
    case teleprompter
}

/// One observed reading speed.
public struct WPMSample: Sendable, Codable, Equatable {
    public let wordCount: Int
    public let duration: TimeInterval
    public let source: WPMSampleSource

    public init(wordCount: Int, duration: TimeInterval, source: WPMSampleSource) {
        self.wordCount = wordCount
        self.duration = duration
        self.source = source
    }

    public var wordsPerMinute: Double? {
        guard wordCount > 0, duration > 0 else { return nil }
        return Double(wordCount) / duration * 60
    }
}

/// Why a sample was not folded into the learned WPM.
public enum WPMSampleRejection: String, Sendable, Codable, Equatable {
    case invalidInput
    case tooShort
    case outOfRange
}

/// Result of recording one sample.
public enum WPMSampleResult: Sendable, Equatable {
    case accepted(wordsPerMinute: Double)
    case rejected(reason: WPMSampleRejection, wordsPerMinute: Double?)
}

/// Configuration for ``WPMLearner``.
public struct WPMConfiguration: Sendable, Codable, Equatable {
    /// Default WPM per language, used until enough samples exist.
    public var defaultWordsPerMinute: [SpeechLanguage: Double]
    /// How many accepted samples are needed before the learned value replaces
    /// the default.
    public var minimumAcceptedSamples: Int
    /// Exponential moving average weight for the newest sample, `0...1`.
    public var smoothingFactor: Double
    /// Samples shorter than this are ignored: they are too noisy.
    public var minimumSampleDuration: TimeInterval
    /// Samples outside this speaking range are treated as measurement errors.
    public var minimumWordsPerMinute: Double
    public var maximumWordsPerMinute: Double

    public init(
        defaultWordsPerMinute: [SpeechLanguage: Double] = [
            .spanish: SpeechLanguage.spanish.defaultWordsPerMinute,
            .english: SpeechLanguage.english.defaultWordsPerMinute
        ],
        minimumAcceptedSamples: Int = 3,
        smoothingFactor: Double = 0.3,
        minimumSampleDuration: TimeInterval = 5,
        minimumWordsPerMinute: Double = 60,
        maximumWordsPerMinute: Double = 260
    ) {
        self.defaultWordsPerMinute = defaultWordsPerMinute
        self.minimumAcceptedSamples = minimumAcceptedSamples
        self.smoothingFactor = smoothingFactor
        self.minimumSampleDuration = minimumSampleDuration
        self.minimumWordsPerMinute = minimumWordsPerMinute
        self.maximumWordsPerMinute = maximumWordsPerMinute
    }
}

/// Snapshot of what the learner knows about one language.
public struct WPMLanguageStatistics: Sendable, Codable, Equatable {
    public let language: SpeechLanguage
    public let acceptedSampleCount: Int
    public let rejectedSampleCount: Int
    /// Internal exponential moving average of accepted samples.
    public let emaWordsPerMinute: Double?
    public let lastSampleWordsPerMinute: Double?
    public let lastSource: WPMSampleSource?
    /// What callers should use for estimates: the default until the minimum
    /// sample count is reached, then the learned EMA.
    public let effectiveWordsPerMinute: Double
}

/// Learns a personal words-per-minute value per language.
///
/// F11 uses the good take of each scene plus teleprompter sessions as samples.
/// Short takes and physically implausible rates are rejected so a single
/// mistake cannot distort every duration estimate in the project.
public struct WPMLearner: Sendable, Codable, Equatable {
    public var configuration: WPMConfiguration

    private struct Bucket: Sendable, Codable, Equatable {
        var acceptedSampleCount: Int = 0
        var rejectedSampleCount: Int = 0
        var emaWordsPerMinute: Double?
        var lastSampleWordsPerMinute: Double?
        var lastSource: WPMSampleSource?
    }

    private var buckets: [SpeechLanguage: Bucket]

    public init(configuration: WPMConfiguration = WPMConfiguration()) {
        self.configuration = configuration
        self.buckets = [:]
    }

    @discardableResult
    public mutating func record(
        _ sample: WPMSample,
        language: SpeechLanguage
    ) -> WPMSampleResult {
        record(
            wordCount: sample.wordCount,
            duration: sample.duration,
            source: sample.source,
            language: language
        )
    }

    @discardableResult
    public mutating func record(
        wordCount: Int,
        duration: TimeInterval,
        source: WPMSampleSource,
        language: SpeechLanguage
    ) -> WPMSampleResult {
        var bucket = buckets[language] ?? Bucket()

        guard wordCount > 0, duration > 0 else {
            bucket.rejectedSampleCount += 1
            buckets[language] = bucket
            return .rejected(reason: .invalidInput, wordsPerMinute: nil)
        }

        let wordsPerMinute = Double(wordCount) / duration * 60

        guard duration >= configuration.minimumSampleDuration else {
            bucket.rejectedSampleCount += 1
            buckets[language] = bucket
            return .rejected(reason: .tooShort, wordsPerMinute: wordsPerMinute)
        }

        guard wordsPerMinute >= configuration.minimumWordsPerMinute,
              wordsPerMinute <= configuration.maximumWordsPerMinute else {
            bucket.rejectedSampleCount += 1
            buckets[language] = bucket
            return .rejected(reason: .outOfRange, wordsPerMinute: wordsPerMinute)
        }

        let alpha = min(1, max(0, configuration.smoothingFactor))
        if let previous = bucket.emaWordsPerMinute {
            bucket.emaWordsPerMinute = alpha * wordsPerMinute + (1 - alpha) * previous
        } else {
            bucket.emaWordsPerMinute = wordsPerMinute
        }
        bucket.acceptedSampleCount += 1
        bucket.lastSampleWordsPerMinute = wordsPerMinute
        bucket.lastSource = source
        buckets[language] = bucket

        return .accepted(wordsPerMinute: wordsPerMinute)
    }

    /// The value duration estimates should use right now.
    public func effectiveWordsPerMinute(for language: SpeechLanguage) -> Double {
        let bucket = buckets[language]
        if let bucket,
           bucket.acceptedSampleCount >= max(1, configuration.minimumAcceptedSamples),
           let ema = bucket.emaWordsPerMinute {
            return ema
        }
        return configuration.defaultWordsPerMinute[language]
            ?? language.defaultWordsPerMinute
    }

    public func statistics(for language: SpeechLanguage) -> WPMLanguageStatistics {
        let bucket = buckets[language] ?? Bucket()
        return WPMLanguageStatistics(
            language: language,
            acceptedSampleCount: bucket.acceptedSampleCount,
            rejectedSampleCount: bucket.rejectedSampleCount,
            emaWordsPerMinute: bucket.emaWordsPerMinute,
            lastSampleWordsPerMinute: bucket.lastSampleWordsPerMinute,
            lastSource: bucket.lastSource,
            effectiveWordsPerMinute: effectiveWordsPerMinute(for: language)
        )
    }

    /// Forget one language, or everything when `language` is `nil`.
    public mutating func reset(language: SpeechLanguage? = nil) {
        if let language {
            buckets[language] = nil
        } else {
            buckets = [:]
        }
    }
}
