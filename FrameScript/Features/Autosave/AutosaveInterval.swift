import Foundation

/// Resolves the user-facing autosave interval into the delay used before the
/// next disk write. The Settings stepper enforces 5...120 s, but values can also
/// come from older or hand-edited settings files, so clamp again at the point
/// of use. New and reset settings default to 10 seconds.
enum AutosaveInterval {
    static let allowedSeconds = 5...120
    static let defaultSeconds = 10

    static func clampedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, allowedSeconds.lowerBound), allowedSeconds.upperBound)
    }

    static func duration(forSeconds seconds: Int) -> Duration {
        .seconds(clampedSeconds(seconds))
    }
}
