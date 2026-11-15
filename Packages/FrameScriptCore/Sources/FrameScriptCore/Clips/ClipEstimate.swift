import Foundation

/// How a clip's live estimate compares with its target.
public struct ClipDurationEstimate: Sendable, Equatable {
    public enum Fit: String, Sendable, Equatable {
        case under
        case onTarget
        case over
    }

    public enum HookFit: String, Sendable, Equatable {
        case empty
        case tooShort
        case ok
        case tooLong
    }

    public let seconds: TimeInterval
    public let hookSeconds: TimeInterval
    public let adaptedSeconds: TimeInterval
    public let wordCount: Int
    public let targetSeconds: TimeInterval
    public let tolerance: TimeInterval
    public let fit: Fit
    public let hookFit: HookFit

    public init(
        seconds: TimeInterval,
        hookSeconds: TimeInterval,
        adaptedSeconds: TimeInterval,
        wordCount: Int,
        targetSeconds: TimeInterval,
        tolerance: TimeInterval,
        fit: Fit,
        hookFit: HookFit
    ) {
        self.seconds = Self.sanitized(seconds)
        self.hookSeconds = Self.sanitized(hookSeconds)
        self.adaptedSeconds = Self.sanitized(adaptedSeconds)
        self.wordCount = max(0, wordCount)
        self.targetSeconds = ClipLimits.sanitizedTarget(targetSeconds)
            ?? ClipLimits.defaultTargetSeconds
        self.tolerance = max(0, tolerance.isFinite ? tolerance : 0)
        self.fit = fit
        self.hookFit = hookFit
    }

    /// Positive when the clip runs long, negative when it runs short.
    public var delta: TimeInterval { seconds - targetSeconds }

    public var overrun: TimeInterval { max(0, seconds - targetSeconds) }

    public var underrun: TimeInterval { max(0, targetSeconds - seconds) }

    public var percentOfTarget: Int {
        guard targetSeconds > 0 else { return 0 }
        let value = seconds / targetSeconds * 100
        guard value.isFinite else { return 0 }
        return min(9_999, max(0, Int(value.rounded())))
    }

    public var isOverTarget: Bool { fit == .over }

    public var isUnderTarget: Bool { fit == .under }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return 0 }
        return min(value, 86_400)
    }
}

/// Markup-aware clip estimates. The hook and the adapted text are separate
/// fields, so both are measured and added.
public enum ClipEstimator {
    /// Ten percent of the target, with a floor so a 15 s clip is not treated as
    /// "on target" just because it is one second off.
    public static func tolerance(for targetSeconds: TimeInterval) -> TimeInterval {
        max(1.5, targetSeconds * 0.1)
    }

    public static func fit(
        seconds: TimeInterval,
        targetSeconds: TimeInterval,
        tolerance: TimeInterval? = nil
    ) -> ClipDurationEstimate.Fit {
        let target = ClipLimits.sanitizedTarget(targetSeconds) ?? ClipLimits.defaultTargetSeconds
        let limit = tolerance ?? self.tolerance(for: target)
        if seconds > target + limit { return .over }
        if seconds < target - limit { return .under }
        return .onTarget
    }

    public static func hookFit(seconds: TimeInterval, hasHook: Bool) -> ClipDurationEstimate.HookFit {
        guard hasHook else { return .empty }
        if seconds < ClipLimits.hookMinimumSeconds { return .tooShort }
        if seconds > ClipLimits.hookMaximumSeconds { return .tooLong }
        return .ok
    }

    public static func estimate(
        hook: String,
        adaptedText: String,
        targetSeconds: TimeInterval = ClipLimits.defaultTargetSeconds,
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard
    ) -> ClipDurationEstimate {
        let hookEstimate = ScriptMarkup.estimate(
            hook,
            wordsPerMinute: wordsPerMinute,
            defaults: pauseDefaults
        )
        let adaptedEstimate = ScriptMarkup.estimate(
            adaptedText,
            wordsPerMinute: wordsPerMinute,
            defaults: pauseDefaults
        )
        let target = ClipLimits.sanitizedTarget(targetSeconds) ?? ClipLimits.defaultTargetSeconds
        let total = hookEstimate.duration + adaptedEstimate.duration
        let hasHook = !hook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return ClipDurationEstimate(
            seconds: total,
            hookSeconds: hookEstimate.duration,
            adaptedSeconds: adaptedEstimate.duration,
            wordCount: hookEstimate.spokenWordCount + adaptedEstimate.spokenWordCount,
            targetSeconds: target,
            tolerance: tolerance(for: target),
            fit: fit(seconds: total, targetSeconds: target),
            hookFit: hookFit(seconds: hookEstimate.duration, hasHook: hasHook)
        )
    }
}
