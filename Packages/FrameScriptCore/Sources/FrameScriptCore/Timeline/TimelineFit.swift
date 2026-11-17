import Foundation

/// "Ajustar": the zoom that makes the whole video fill the visible canvas.
public extension TimelineZoom {
    /// Lowest zoom the fit command may use. Lower than `minimumPointsPerSecond`
    /// so a long video (an hour fits 900 pt at 0.25 pt/s) can still be fitted;
    /// manual zoom keeps its own limits.
    static let minimumFitPointsPerSecond = 0.05

    /// Points per second that make `totalDuration` span `availableWidth`.
    /// Never zoomed in past `maximumPointsPerSecond`. A zero or invalid
    /// duration or width falls back to the default zoom.
    static func fitPointsPerSecond(
        totalDuration: TimeInterval,
        availableWidth: Double
    ) -> Double {
        guard totalDuration.isFinite, totalDuration > 0,
              availableWidth.isFinite, availableWidth > 0 else {
            return defaultPointsPerSecond
        }
        return min(
            max(availableWidth / totalDuration, minimumFitPointsPerSecond),
            maximumPointsPerSecond
        )
    }

    /// True when `pointsPerSecond` is the fitted zoom, within rounding.
    static func isFitted(
        pointsPerSecond: Double,
        totalDuration: TimeInterval,
        availableWidth: Double
    ) -> Bool {
        let fit = fitPointsPerSecond(totalDuration: totalDuration, availableWidth: availableWidth)
        return abs(pointsPerSecond - fit) <= max(0.001, fit * 0.005)
    }

    /// Seconds between ruler divisions at this zoom, for the «10 s por
    /// división» readout. Same rule the ruler uses to place its ticks.
    static func secondsPerDivision(pointsPerSecond: Double) -> TimeInterval {
        TimelineRuler.tickInterval(pointsPerSecond: pointsPerSecond)
    }
}

/// When the timeline has too little to draw, the app shows a friendly empty
/// state instead of seven nearly empty tracks.
public enum TimelineEmptyState {
    /// Videos shorter than this (estimated) read as "not written yet".
    public static let minimumDuration: TimeInterval = 30

    /// True when no scene has any narration text, or when the whole video is
    /// under `minimumDuration` and nothing was actually recorded.
    public static func shouldShow(for layout: TimelineLayout) -> Bool {
        guard !layout.isEmpty else { return true }
        if layout.scenes.allSatisfy({ $0.paragraphCount == 0 }) { return true }
        let hasRealTake = layout.scenes.contains { $0.hasRealTake }
        return layout.totalDuration < minimumDuration && !hasRealTake
    }
}
