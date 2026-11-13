import Foundation

extension Notification.Name {
    /// Posted on the main actor right before the open project is closed, replaced or deleted.
    /// Observers (AI runtime, teleprompter, recording) must drop project-bound state.
    static let frameScriptProjectWillChange = Notification.Name("FrameScript.projectWillChange")
}
