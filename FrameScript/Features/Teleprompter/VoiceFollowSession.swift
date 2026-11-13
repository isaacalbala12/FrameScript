import Foundation
import FrameScriptCore

/// One finished teleprompter reading with voice following.
///
/// This is the hand-off to the duration/WPM learner (F11). The teleprompter
/// owns measuring the session; the learner owns persisting and smoothing the
/// learned words-per-minute value.
struct TeleprompterReadingSession: Equatable, Sendable {
    /// Words the follower actually matched, not the whole script.
    let spokenWords: Int
    /// Wall-clock time the voice-follow session was active.
    let duration: TimeInterval
    /// Recognition language used for the session.
    let language: SpeechLanguage
}

/// Small protocol the WPM learner can conform to without the teleprompter
/// knowing anything about its storage.
@MainActor
protocol TeleprompterReadingSessionReporting: AnyObject {
    func teleprompterDidFinishReadingSession(_ session: TeleprompterReadingSession)
}
