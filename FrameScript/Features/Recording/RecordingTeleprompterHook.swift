import Foundation

/// The seam between recording and the teleprompter (F8).
///
/// The teleprompter lives on a separate branch, so recording only depends on
/// this small protocol. The merge wires the real teleprompter in; until then
/// `NoOpRecordingTeleprompterHook` keeps the countdown, start and stop signals
/// harmless.
@MainActor
protocol RecordingTeleprompterHook: AnyObject {
    /// A 3-2-1 countdown started. `seconds` is the first value shown.
    func recordingCountdownDidBegin(seconds: Int)
    /// One countdown tick, including the initial value.
    func recordingCountdownDidTick(seconds: Int)
    /// OBS confirmed that recording started for this scene.
    func recordingDidStart(sceneID: UUID)
    /// A take was saved (or a take attempt failed and was closed out).
    /// `takeID` is `nil` when no take could be created.
    func recordingDidStop(sceneID: UUID, takeID: UUID?, wasInterrupted: Bool)
}

@MainActor
final class NoOpRecordingTeleprompterHook: RecordingTeleprompterHook {
    func recordingCountdownDidBegin(seconds: Int) {}
    func recordingCountdownDidTick(seconds: Int) {}
    func recordingDidStart(sceneID: UUID) {}
    func recordingDidStop(sceneID: UUID, takeID: UUID?, wasInterrupted: Bool) {}
}
