import AppKit

/// One reversible scene-text swap. The step is retained by NSUndoManager
/// through the selector-based registration below.
private final class FullScriptUndoStep: NSObject {
    let sceneID: UUID
    let targetText: String
    let targetSelection: FullScriptSceneSelection?
    let inverseSelection: FullScriptSceneSelection?
    let currentText: @MainActor (UUID) -> String?
    let commit: @MainActor (UUID, String, String) -> Void
    let actionName: String?
    weak var manager: UndoManager?

    init(
        sceneID: UUID,
        targetText: String,
        targetSelection: FullScriptSceneSelection?,
        inverseSelection: FullScriptSceneSelection?,
        currentText: @escaping @MainActor (UUID) -> String?,
        commit: @escaping @MainActor (UUID, String, String) -> Void,
        actionName: String?,
        manager: UndoManager
    ) {
        self.sceneID = sceneID
        self.targetText = targetText
        self.targetSelection = targetSelection
        self.inverseSelection = inverseSelection
        self.currentText = currentText
        self.commit = commit
        self.actionName = actionName
        self.manager = manager
    }
}

/// Long-lived undo target for full-script edits.
///
/// NSUndoManager does not retain its target. Registering directly on the
/// coordinator would leave a dangling action when the user switches to the
/// single-scene editor, and the next Cmd-Z would message a deallocated object.
/// The hub is a singleton instead, so every undo step stays safe for the life
/// of the window (and falls back to the model when the full-script view is not
/// mounted).
@MainActor
final class FullScriptUndoHub: NSObject {
    static let shared = FullScriptUndoHub()

    private final class WeakCoordinator {
        weak var value: FullScriptTextView.Coordinator?
        init(_ value: FullScriptTextView.Coordinator) { self.value = value }
    }

    /// One mounted full-script editor per window. Keeping the list (instead of
    /// a single slot) lets two project windows each undo through their own
    /// window manager without a stale coordinator being picked.
    private var coordinators: [WeakCoordinator] = []

    private override init() {
        super.init()
    }

    func activate(_ coordinator: FullScriptTextView.Coordinator) {
        coordinators.removeAll { $0.value == nil || $0.value === coordinator }
        coordinators.append(WeakCoordinator(coordinator))
    }

    func deactivate(_ coordinator: FullScriptTextView.Coordinator) {
        coordinators.removeAll { $0.value == nil || $0.value === coordinator }
    }

    /// Registers one user edit. The grouping toggle makes the step independent
    /// from NSUndoManager's event grouping, so two edits in two scenes undo one
    /// at a time even when a test drives both in the same run-loop turn.
    /// `groupsByEvent` is restored immediately; no other window state changes.
    func register(
        sceneID: UUID,
        targetText: String,
        targetSelection: FullScriptSceneSelection?,
        inverseSelection: FullScriptSceneSelection?,
        currentText: @escaping @MainActor (UUID) -> String?,
        commit: @escaping @MainActor (UUID, String, String) -> Void,
        actionName: String?,
        in manager: UndoManager?
    ) {
        guard let manager else { return }
        let step = FullScriptUndoStep(
            sceneID: sceneID,
            targetText: targetText,
            targetSelection: targetSelection,
            inverseSelection: inverseSelection,
            currentText: currentText,
            commit: commit,
            actionName: actionName,
            manager: manager
        )
        register(step, in: manager)
    }

    private func register(_ step: FullScriptUndoStep, in manager: UndoManager) {
        let groupsByEvent = manager.groupsByEvent
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        manager.registerUndo(
            withTarget: self,
            selector: #selector(performUndoStep(_:)),
            object: step
        )
        if let actionName = step.actionName {
            manager.setActionName(actionName)
        }
        manager.endUndoGrouping()
        manager.groupsByEvent = groupsByEvent
    }

    @objc private func performUndoStep(_ step: FullScriptUndoStep) {
        guard let manager = step.manager, let currentText = step.currentText(step.sceneID) else { return }
        let coordinator = coordinators
            .compactMap(\.value)
            .first { $0.canHandleUndoManager(manager) }
        let currentSelection = coordinator?.currentSceneSelection()

        if let coordinator {
            coordinator.applyUndoText(
                sceneID: step.sceneID,
                text: step.targetText,
                selection: step.targetSelection
            )
        } else {
            step.commit(step.sceneID, currentText, step.targetText)
        }

        // A scene can disappear (project replaced, scene deleted) while the
        // action is on the stack. In that case leave no inverse behind.
        guard step.currentText(step.sceneID) != nil else { return }
        let inverse = FullScriptUndoStep(
            sceneID: step.sceneID,
            targetText: currentText,
            targetSelection: currentSelection ?? step.inverseSelection,
            inverseSelection: step.targetSelection,
            currentText: step.currentText,
            commit: step.commit,
            actionName: step.actionName,
            manager: manager
        )
        register(inverse, in: manager)
    }
}
