import Foundation

/// Tunable limits for the rhythm review (F26). Values are project- or
/// template-level settings in the app; this struct is `Codable` so they can be
/// stored in the `.fscr` file or in a template.
///
/// Decoding is tolerant: missing keys keep their defaults, so older project
/// files and partial JSON stay readable.
public struct RhythmThresholds: Sendable, Equatable, Codable {
    /// A sentence longer than this many words is flagged. Default 25.
    public var maxSentenceWords: Int
    /// A sentence that takes longer than this many seconds is flagged. Default 9.
    public var maxSentenceSeconds: Double
    /// Narration without an anchored visual change longer than this is flagged.
    /// Default 5 s, matching the VRC "cut every 3–5 s" rule.
    public var maxSecondsWithoutVisualChange: Double
    /// A scene with the hook role longer than this is flagged. Default 15 s.
    public var hookMaxSeconds: Double
    /// A scene longer than the project average times this factor is flagged.
    /// Default 1.8.
    public var sceneLengthOutlierFactor: Double

    public init(
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

    public static let `default` = RhythmThresholds()

    private enum CodingKeys: String, CodingKey {
        case maxSentenceWords
        case maxSentenceSeconds
        case maxSecondsWithoutVisualChange
        case hookMaxSeconds
        case sceneLengthOutlierFactor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RhythmThresholds()
        self.maxSentenceWords = try container.decodeIfPresent(
            Int.self,
            forKey: .maxSentenceWords
        ) ?? defaults.maxSentenceWords
        self.maxSentenceSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .maxSentenceSeconds
        ) ?? defaults.maxSentenceSeconds
        self.maxSecondsWithoutVisualChange = try container.decodeIfPresent(
            Double.self,
            forKey: .maxSecondsWithoutVisualChange
        ) ?? defaults.maxSecondsWithoutVisualChange
        self.hookMaxSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .hookMaxSeconds
        ) ?? defaults.hookMaxSeconds
        self.sceneLengthOutlierFactor = try container.decodeIfPresent(
            Double.self,
            forKey: .sceneLengthOutlierFactor
        ) ?? defaults.sceneLengthOutlierFactor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxSentenceWords, forKey: .maxSentenceWords)
        try container.encode(maxSentenceSeconds, forKey: .maxSentenceSeconds)
        try container.encode(
            maxSecondsWithoutVisualChange,
            forKey: .maxSecondsWithoutVisualChange
        )
        try container.encode(hookMaxSeconds, forKey: .hookMaxSeconds)
        try container.encode(sceneLengthOutlierFactor, forKey: .sceneLengthOutlierFactor)
    }
}
