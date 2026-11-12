import Foundation

/// Shared limits for the AI hook and re-hook generator (F13).
public enum HookLimits {
    /// A spoken hook must fit in the first 15 seconds.
    public static let maximumHookSeconds: TimeInterval = 15
    /// A spoken re-hook bridge must fit in 6 seconds.
    public static let maximumRehookSeconds: TimeInterval = 6
    /// Scenes above this duration are candidates for an internal re-hook.
    public static let defaultLongSceneSeconds: TimeInterval = 90
    /// The part of the video where a short scene still earns a re-hook.
    public static let videoMidpointRange: ClosedRange<Double> = 0.4...0.6
    /// The model is asked for 3–5 alternatives; never accept more than this.
    public static let maximumHookAlternatives = 5
    /// Each suggested position accepts at most two bridges.
    public static let maximumRehooksPerPosition = 2
}

/// One alternative opening hook returned by the model.
///
/// `text` is spoken narration only. `estimatedSeconds` is computed with
/// `ScriptMarkup.estimateDuration` at the speaking rate supplied to the parser,
/// so it includes pause markers and ignores cues. A candidate that runs past
/// `maximumSeconds` is still returned and flagged instead of being silently
/// dropped: the UI can show it and keep the Insert action disabled.
public struct HookSuggestion: Sendable, Equatable, Hashable {
    public let angle: String
    public let text: String
    public let onScreenText: String
    public let wordCount: Int
    public let estimatedSeconds: TimeInterval
    public let maximumSeconds: TimeInterval

    public init(
        angle: String,
        text: String,
        onScreenText: String = "",
        wordCount: Int,
        estimatedSeconds: TimeInterval,
        maximumSeconds: TimeInterval = HookLimits.maximumHookSeconds
    ) {
        self.angle = angle
        self.text = text
        self.onScreenText = onScreenText
        self.wordCount = wordCount
        self.estimatedSeconds = estimatedSeconds
        self.maximumSeconds = maximumSeconds
    }

    public var exceedsLimit: Bool { estimatedSeconds > maximumSeconds }
    public var isWithinLimit: Bool { !exceedsLimit }
}

/// One re-engagement bridge returned by the model.
///
/// `anchor` and `anchorRange` point at the sentence the bridge must be inserted
/// before. The parser resolves the model's anchor text against the canonical
/// positions supplied by ``RehookPlanner`` so an insertion can never land in an
/// arbitrary place.
public struct RehookSuggestion: Sendable, Equatable, Hashable {
    public let text: String
    public let anchor: String
    public let anchorRange: UTF16Span
    public let wordCount: Int
    public let estimatedSeconds: TimeInterval
    public let maximumSeconds: TimeInterval

    public init(
        text: String,
        anchor: String,
        anchorRange: UTF16Span,
        wordCount: Int,
        estimatedSeconds: TimeInterval,
        maximumSeconds: TimeInterval = HookLimits.maximumRehookSeconds
    ) {
        self.text = text
        self.anchor = anchor
        self.anchorRange = anchorRange
        self.wordCount = wordCount
        self.estimatedSeconds = estimatedSeconds
        self.maximumSeconds = maximumSeconds
    }

    public var exceedsLimit: Bool { estimatedSeconds > maximumSeconds }
    public var isWithinLimit: Bool { !exceedsLimit }
}

/// A position where the planner suggests inserting a bridge.
public struct RehookPosition: Sendable, Equatable, Hashable {
    public enum Reason: String, Sendable, Equatable, Hashable, Codable {
        /// The scene itself is longer than `HookLimits.defaultLongSceneSeconds`.
        case longScene
        /// The scene covers the 40–60% window of the full video.
        case videoMidpoint
    }

    public let anchor: String
    public let anchorRange: UTF16Span
    public let sentenceIndex: Int
    public let reason: Reason

    public init(anchor: String, anchorRange: UTF16Span, sentenceIndex: Int, reason: Reason) {
        self.anchor = anchor
        self.anchorRange = anchorRange
        self.sentenceIndex = sentenceIndex
        self.reason = reason
    }
}

public enum HookParsingError: Error, Equatable, Sendable {
    /// The provider text contained no JSON object or array at all.
    case invalidJSON
    /// JSON was found, but no entry had usable spoken text.
    case noSuggestions
    /// Re-hook suggestions were requested without any usable anchor position.
    case noValidAnchors
}

/// Failures raised by the app-side hook service.
public enum HookServiceError: Error, Equatable, Sendable {
    case providerDisabled
    case truncated
    case noSuggestions
}
