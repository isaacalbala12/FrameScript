import FrameScriptCore
import Foundation

/// Integration seam for production destinations whose panels live on another
/// branch. `AppState` handles scene, B-roll, editing and take destinations
/// itself; publishing and research are forwarded here so the integrator can
/// connect the real panels without changing the checklist.
@MainActor
protocol ProductionNavigator: AnyObject {
    /// Presents the destination and returns true when it was shown.
    func navigate(to target: ProductionTarget) -> Bool
}
