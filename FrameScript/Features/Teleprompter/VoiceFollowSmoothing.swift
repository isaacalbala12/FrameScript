import Foundation

// MARK: - Smoothing

/// Critically damped scroll smoothing for voice following.
///
/// The raw target jumps by a whole word (and sometimes by a whole line) every
/// recognizer update. Feeding that straight to the scroll engine makes the
/// teleprompter twitch. This value type turns the target into a smooth motion
/// with no overshoot:
///
/// - the exact critically damped solution is evaluated per frame, so the
///   motion is independent of the frame rate;
/// - target changes smaller than `minimumTargetChange` are ignored, which
///   suppresses sub-line jitter from revised hypotheses;
/// - speed is capped so a big jump never becomes a visual jump cut.
struct TeleprompterVoiceSmoother: Equatable, Sendable {
    /// Natural frequency in radians per second. Higher is snappier.
    var naturalFrequency: Double = 6
    /// Hard speed limit in points per second.
    var maximumSpeed: Double = 2400
    /// A new target closer than this to the previous target is ignored.
    var minimumTargetChange: Double = 8
    /// Snap to the target once this close, so the scroll settles exactly.
    var snapDistance: Double = 0.5

    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    private(set) var target: Double = 0
    private(set) var hasTarget = false

    mutating func reset(at value: Double) {
        self.value = value
        self.velocity = 0
        self.target = value
        self.hasTarget = true
    }

    mutating func setTarget(_ newTarget: Double) {
        guard newTarget.isFinite else { return }
        guard hasTarget else {
            target = newTarget
            hasTarget = true
            return
        }
        guard abs(newTarget - target) >= minimumTargetChange else { return }
        target = newTarget
    }

    @discardableResult
    mutating func advance(by delta: TimeInterval) -> Double {
        guard hasTarget else { return value }
        let dt = min(max(0, delta), 0.25)
        guard dt > 0 else { return value }

        let omega = max(0.1, naturalFrequency)
        let x0 = value - target
        let v0 = velocity
        let decay = exp(-omega * dt)
        let x = (x0 + (v0 + omega * x0) * dt) * decay
        let v = (v0 - omega * (v0 + omega * x0) * dt) * decay

        var next = target + x
        let maximumStep = max(0, maximumSpeed) * dt
        if maximumStep > 0, abs(next - value) > maximumStep {
            next = value + (next > value ? maximumStep : -maximumStep)
        }
        if abs(next - target) <= snapDistance {
            value = target
            velocity = 0
        } else {
            value = next
            velocity = v
        }
        return value
    }
}

// MARK: - Fallback state machine

/// Decides when the teleprompter follows speech and when it falls back to
/// timed scrolling.
///
/// `SpeechFollower` already reports `lost` after three seconds without a
/// confident match. This tracker adds the hysteresis needed to avoid a
/// fallback/resume flicker: recovering from fallback requires a confident
/// position sustained for `recoveryDuration`.
struct VoiceFollowModeTracker: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case waiting
        case following
        case timedFallback
    }

    var followConfidence: Double = 0.4
    var recoveryConfidence: Double = 0.5
    var recoveryDuration: TimeInterval = 0.4

    private(set) var mode: Mode = .waiting
    private var recoveryStartedAt: TimeInterval?

    @discardableResult
    mutating func update(
        confidence: Double,
        isLost: Bool,
        hasPosition: Bool,
        at timestamp: TimeInterval
    ) -> Mode {
        if isLost {
            mode = .timedFallback
            recoveryStartedAt = nil
            return mode
        }

        switch mode {
        case .waiting:
            if hasPosition, confidence >= followConfidence {
                mode = .following
            }
        case .following:
            // Losing confidence without being lost means the follower is
            // holding its last position; do not start timed scrolling for a
            // short recognition hiccup.
            break
        case .timedFallback:
            guard hasPosition, confidence >= recoveryConfidence else {
                recoveryStartedAt = nil
                return mode
            }
            if recoveryStartedAt == nil {
                recoveryStartedAt = timestamp
            }
            if timestamp - (recoveryStartedAt ?? timestamp) >= recoveryDuration {
                mode = .following
                recoveryStartedAt = nil
            }
        }
        return mode
    }

    mutating func reset() {
        mode = .waiting
        recoveryStartedAt = nil
    }
}
