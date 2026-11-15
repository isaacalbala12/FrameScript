import Foundation
import FrameScriptCore
import Observation

/// Debounced cache of the derived production checklist.
///
/// The pure rules live in `FrameScriptCore.ProductionChecklist`; this type only
/// keeps the sidebar badge and the panel from rebuilding the document on every
/// keystroke. `ProjectStore` calls `scheduleRefresh` after any project change,
/// and manual task mutations refresh immediately.
@MainActor
@Observable
final class ProductionChecklistCenter {
    static let shared = ProductionChecklistCenter()

    private(set) var snapshot: ProductionSnapshot = .empty

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {}

    func scheduleRefresh(
        project: FrameProject,
        delay: Duration = .milliseconds(300)
    ) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.refreshNow(project: project)
        }
    }

    func refreshNow(project: FrameProject) {
        refreshTask?.cancel()
        refreshTask = nil
        snapshot = ProductionChecklist.snapshot(
            for: FrameScriptDocument.Project(project: project)
        )
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        snapshot = .empty
    }
}
