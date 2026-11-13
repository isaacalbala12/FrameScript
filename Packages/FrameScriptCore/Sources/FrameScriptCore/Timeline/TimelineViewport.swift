import Foundation

/// Converts between timeline seconds and horizontal points.
///
/// The app owns scrolling; this only applies the current zoom and the optional
/// leading inset so hit testing and drawing agree.
public struct TimelineViewport: Sendable, Equatable {
    public var pointsPerSecond: Double {
        didSet { pointsPerSecond = Self.sanitize(pointsPerSecond) }
    }
    /// Empty space before time zero, in points.
    public var leadingInset: Double {
        didSet { leadingInset = leadingInset.isFinite ? max(0, leadingInset) : 0 }
    }

    public init(pointsPerSecond: Double, leadingInset: Double = 0) {
        self.pointsPerSecond = Self.sanitize(pointsPerSecond)
        self.leadingInset = leadingInset.isFinite ? max(0, leadingInset) : 0
    }

    public func x(for time: TimeInterval) -> Double {
        let seconds = time.isFinite ? max(0, time) : 0
        return leadingInset + seconds * pointsPerSecond
    }

    public func time(forX x: Double) -> TimeInterval {
        guard x.isFinite else { return 0 }
        return max(0, (x - leadingInset) / pointsPerSecond)
    }

    public func width(for duration: TimeInterval) -> Double {
        let seconds = duration.isFinite ? max(0, duration) : 0
        return seconds * pointsPerSecond
    }

    /// Content width for a total duration, never negative.
    public func contentWidth(totalDuration: TimeInterval) -> Double {
        leadingInset + width(for: totalDuration)
    }

    private static func sanitize(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return TimelineZoom.defaultPointsPerSecond }
        return min(max(value, 0.05), 1_000)
    }
}

/// Zoom limits and the slider mapping shared by the timeline UI and its
/// commands.
public enum TimelineZoom {
    public static let minimumPointsPerSecond = 1.5
    public static let maximumPointsPerSecond = 16.0
    public static let defaultPointsPerSecond = 4.0
    /// Multiplier applied by ⌘+ and ⌘-.
    public static let stepFactor = 1.25

    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPointsPerSecond }
        return min(max(value, minimumPointsPerSecond), maximumPointsPerSecond)
    }

    public static func zoomedIn(_ value: Double) -> Double {
        clamp(clamp(value) * stepFactor)
    }

    public static func zoomedOut(_ value: Double) -> Double {
        clamp(clamp(value) / stepFactor)
    }

    /// `0...1` position for a zoom slider. Uses a logarithmic scale so each
    /// slider step feels like the same relative change.
    public static func fraction(forPointsPerSecond pointsPerSecond: Double) -> Double {
        let value = clamp(pointsPerSecond)
        let ratio = log(value / minimumPointsPerSecond)
            / log(maximumPointsPerSecond / minimumPointsPerSecond)
        return ratio.isFinite ? min(max(0, ratio), 1) : 0
    }

    public static func pointsPerSecond(forFraction fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultPointsPerSecond }
        let bounded = min(max(0, fraction), 1)
        return clamp(minimumPointsPerSecond * pow(
            maximumPointsPerSecond / minimumPointsPerSecond,
            bounded
        ))
    }
}

/// One labelled tick on the time ruler.
public struct TimelineTick: Sendable, Equatable, Identifiable {
    public var time: TimeInterval
    public var label: String

    public init(time: TimeInterval, label: String) {
        self.time = time
        self.label = label
    }

    public var id: Int { Int((time.isFinite ? max(0, time) : 0).rounded()) }
}

/// Chooses ruler intervals that stay readable at every zoom level.
public enum TimelineRuler {
    /// Preferred intervals in seconds: 1 s, 2 s, 5 s, 10 s, 15 s, 30 s, then
    /// whole minutes and longer.
    public static let preferredIntervals: [TimeInterval] = [
        1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1_800, 3_600
    ]

    /// Smallest preferred interval whose on-screen spacing is at least
    /// `minimumSpacing` points.
    public static func tickInterval(
        pointsPerSecond: Double,
        minimumSpacing: Double = 64
    ) -> TimeInterval {
        let pace = pointsPerSecond.isFinite && pointsPerSecond > 0 ? pointsPerSecond : 1
        let spacing = minimumSpacing.isFinite ? max(1, minimumSpacing) : 64
        if let interval = preferredIntervals.first(where: { $0 * pace >= spacing }) {
            return interval
        }
        let secondsNeeded = spacing / pace
        let hours = max(1, (secondsNeeded / 3_600).rounded(.up))
        return hours * 3_600
    }

    /// Ticks from zero through `totalDuration`, inclusive. Always returns the
    /// zero tick so an empty timeline still has a ruler origin.
    public static func ticks(
        totalDuration: TimeInterval,
        pointsPerSecond: Double,
        minimumSpacing: Double = 64
    ) -> [TimelineTick] {
        let total = totalDuration.isFinite ? max(0, totalDuration) : 0
        let interval = tickInterval(
            pointsPerSecond: pointsPerSecond,
            minimumSpacing: minimumSpacing
        )
        guard interval.isFinite, interval > 0 else {
            return [TimelineTick(time: 0, label: DurationFormat.clock(seconds: 0))]
        }

        var ticks: [TimelineTick] = []
        let lastIndex = Int(floor(total / interval + 1e-9))
        ticks.reserveCapacity(lastIndex + 1)
        for index in 0...lastIndex {
            let seconds = Double(index) * interval
            ticks.append(TimelineTick(
                time: seconds,
                label: DurationFormat.clock(seconds: Int(seconds.rounded()))
            ))
        }
        if ticks.count == 1, total > 0 {
            ticks.append(TimelineTick(
                time: total,
                label: DurationFormat.clock(seconds: Int(total.rounded()))
            ))
        }
        return ticks
    }
}
