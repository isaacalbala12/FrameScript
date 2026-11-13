import Foundation
import FrameScriptCore

enum DurationEstimator {
    static func estimate(text: String, wordsPerMinute: Int) -> TimeInterval {
        estimate(text: text, wordsPerMinute: Double(wordsPerMinute))
    }

    /// Markup-aware estimate: only spoken words count and inline pauses add
    /// their real duration. Callers pass the learned per-language pace.
    static func estimate(text: String, wordsPerMinute: Double) -> TimeInterval {
        let pace = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 0
        return ScriptMarkup.estimateDuration(text, wordsPerMinute: pace)
    }

    /// Formats seconds as `m:ss`. Values read from disk or typed by the user
    /// are untrusted, so the conversion is clamped and never traps.
    static func formatted(_ interval: TimeInterval) -> String {
        let maximumFormattable: TimeInterval = 999_999_999
        let safeInterval = interval.isFinite ? min(max(interval, 0), maximumFormattable) : 0
        let seconds = Int(safeInterval.rounded())
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes):\(String(format: "%02d", remainder))"
    }
}
