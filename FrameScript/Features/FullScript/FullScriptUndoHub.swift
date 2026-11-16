import AppKit

/// One text replacement inside a scene body, in scene-local UTF-16 units.
///
/// Undo steps store this diff (the removed and inserted substrings) instead of
/// two full copies of the scene, so a keystroke costs a few bytes.
struct FullScriptTextEdit: Equatable, Sendable {
    var location: Int
    var removed: String
    var inserted: String

    var removedLength: Int { removed.utf16.count }
    var insertedLength: Int { inserted.utf16.count }

    var inverse: FullScriptTextEdit {
        FullScriptTextEdit(location: location, removed: inserted, inserted: removed)
    }

    /// Smallest single replacement that turns `old` into `new`, or `nil` when
    /// they are equal. The common prefix/suffix never splits a surrogate pair.
    static func diff(old: String, new: String) -> FullScriptTextEdit? {
        guard old != new else { return nil }
        let oldText = old as NSString
        let newText = new as NSString
        let oldLength = oldText.length
        let newLength = newText.length
        let limit = min(oldLength, newLength)

        var prefix = 0
        while prefix < limit, oldText.character(at: prefix) == newText.character(at: prefix) {
            prefix += 1
        }
        if prefix > 0, UTF16.isLeadSurrogate(oldText.character(at: prefix - 1)) {
            prefix -= 1
        }
        var suffix = 0
        while suffix < limit - prefix,
              oldText.character(at: oldLength - 1 - suffix) == newText.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(oldText.character(at: oldLength - suffix)) {
            suffix -= 1
        }
        return FullScriptTextEdit(
            location: prefix,
            removed: oldText.substring(with: NSRange(location: prefix, length: oldLength - prefix - suffix)),
            inserted: newText.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        )
    }

    /// Applies the edit to `text`, verifying that the inserted run is really
    /// there. Returns `nil` when the range does not match.
    func applied(to text: String) -> String? {
        let nsText = text as NSString
        guard location >= 0, location + insertedLength <= nsText.length else { return nil }
        let range = NSRange(location: location, length: insertedLength)
        guard nsText.substring(with: range) == inserted else { return nil }
        return nsText.replacingCharacters(in: range, with: removed)
    }
}

/// One reversible scene edit. The step is retained by NSUndoManager through the
/// selector-based registration below.
///
/// The step knows the text its edit produced (`afterFingerprint`). It only
/// applies while the scene still holds exactly that text; anything else
/// (text typed in the single-scene editor, an AI insert, a reload from disk)
/// makes it a safe no-op instead of a blind overwrite.
private final class FullScriptUndoStep: NSObject {
    let sceneID: UUID
    var edit: FullScriptTextEdit
    var beforeFingerprint: Int
    var afterFingerprint: Int
    /// Selection to restore after performing this step.
    var performSelection: FullScriptSceneSelection?
    /// Selection to restore after performing the inverse of this step.
    var inverseSelection: FullScriptSceneSelection?
    let currentText: @MainActor (UUID) -> String?
    let commit: @MainActor (UUID, String, String) -> Void
    let actionName: String?
    weak var manager: UndoManager?

    init(
        sceneID: UUID,
        edit: FullScriptTextEdit,
        beforeFingerprint: Int,
        afterFingerprint: Int,
        performSelection: FullScriptSceneSelection?,
        inverseSelection: FullScriptSceneSelection?,
        currentText: @escaping @MainActor (UUID) -> String?,
        commit: @escaping @MainActor (UUID, String, String) -> Void,
        actionName: String?,
        manager: UndoManager
    ) {
        self.sceneID = sceneID
        self.edit = edit
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.performSelection = performSelection
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

    /// Consecutive typing in one scene within this interval is one undo group.
    static let defaultCoalescingInterval: TimeInterval = 1.0

    private final class WeakCoordinator {
        weak var value: FullScriptTextView.Coordinator?
        init(_ value: FullScriptTextView.Coordinator) { self.value = value }
    }

    /// The step still at the top of the undo stack that the next keystroke may
    /// extend. Any undo/redo, rebuild, scene change or pause closes it.
    private struct OpenStep {
        let step: FullScriptUndoStep
        let managerID: ObjectIdentifier
        let date: Date
    }

    /// One mounted full-script editor per window. Keeping the list (instead of
    /// a single slot) lets two project windows each undo through their own
    /// window manager without a stale coordinator being picked.
    private var coordinators: [WeakCoordinator] = []
    private let managers = NSHashTable<UndoManager>.weakObjects()
    private var openStep: OpenStep?

    /// Test seams.
    var now: () -> Date = { Date() }
    var coalescingInterval: TimeInterval = FullScriptUndoHub.defaultCoalescingInterval

    private override init() {
        super.init()
    }

    func activate(_ coordinator: FullScriptTextView.Coordinator) {
        coordinators.removeAll { $0.value == nil || $0.value === coordinator }
        coordinators.append(WeakCoordinator(coordinator))
    }

    func deactivate(_ coordinator: FullScriptTextView.Coordinator) {
        coordinators.removeAll { $0.value == nil || $0.value === coordinator }
        openStep = nil
    }

    /// Closes the current typing group. The coordinator calls it when the text
    /// is rebuilt from the model or an edit is rejected.
    func breakCoalescing() {
        openStep = nil
    }

    /// Removes every full-script step from every window manager.
    func discardAllSteps() {
        openStep = nil
        for manager in managers.allObjects {
            manager.removeAllActions(withTarget: self)
        }
    }

    static func fingerprint(of text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(text.utf16.count)
        return hasher.finalize()
    }

    /// Registers one user edit, or extends the open typing group when the edit
    /// continues it. The grouping toggle makes a new step independent from
    /// NSUndoManager's event grouping, so edits in two scenes undo one at a
    /// time even when a test drives both in the same run-loop turn.
    func register(
        sceneID: UUID,
        previousText: String,
        newText: String,
        selectionBeforeEdit: FullScriptSceneSelection?,
        selectionAfterEdit: FullScriptSceneSelection?,
        currentText: @escaping @MainActor (UUID) -> String?,
        commit: @escaping @MainActor (UUID, String, String) -> Void,
        actionName: String?,
        in manager: UndoManager?
    ) {
        guard let manager,
              let edit = FullScriptTextEdit.diff(old: previousText, new: newText) else { return }
        let beforeFingerprint = Self.fingerprint(of: previousText)
        let afterFingerprint = Self.fingerprint(of: newText)
        let date = now()

        if let open = openStep,
           open.managerID == ObjectIdentifier(manager),
           open.step.sceneID == sceneID,
           date.timeIntervalSince(open.date) <= coalescingInterval,
           open.step.afterFingerprint == beforeFingerprint,
           !manager.isUndoing, !manager.isRedoing,
           let merged = Self.merged(open.step.edit, with: edit) {
            open.step.edit = merged
            open.step.afterFingerprint = afterFingerprint
            open.step.inverseSelection = selectionAfterEdit
            openStep = OpenStep(step: open.step, managerID: open.managerID, date: date)
            return
        }

        let step = FullScriptUndoStep(
            sceneID: sceneID,
            edit: edit,
            beforeFingerprint: beforeFingerprint,
            afterFingerprint: afterFingerprint,
            performSelection: selectionBeforeEdit,
            inverseSelection: selectionAfterEdit,
            currentText: currentText,
            commit: commit,
            actionName: actionName,
            manager: manager
        )
        register(step, in: manager)
        openStep = OpenStep(step: step, managerID: ObjectIdentifier(manager), date: date)
    }

    /// Typing continuing to the right, backspace continuing to the left and
    /// forward-delete continuing in place are one group; anything else (caret
    /// jump, replacement of a selection) starts a new one.
    private static func merged(
        _ first: FullScriptTextEdit,
        with next: FullScriptTextEdit
    ) -> FullScriptTextEdit? {
        if first.removed.isEmpty, next.removed.isEmpty,
           next.location == first.location + first.insertedLength {
            return FullScriptTextEdit(
                location: first.location,
                removed: "",
                inserted: first.inserted + next.inserted
            )
        }
        if first.inserted.isEmpty, next.inserted.isEmpty {
            if next.location + next.removedLength == first.location {
                return FullScriptTextEdit(
                    location: next.location,
                    removed: next.removed + first.removed,
                    inserted: ""
                )
            }
            if next.location == first.location {
                return FullScriptTextEdit(
                    location: first.location,
                    removed: first.removed + next.removed,
                    inserted: ""
                )
            }
        }
        return nil
    }

    private func register(_ step: FullScriptUndoStep, in manager: UndoManager) {
        managers.add(manager)
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
        openStep = nil
        guard let manager = step.manager,
              let currentText = step.currentText(step.sceneID) else { return }
        // The scene changed since this step was recorded (single-scene editor,
        // AI insert, reload from disk, ...). Keep the external text.
        guard Self.fingerprint(of: currentText) == step.afterFingerprint,
              let newText = step.edit.applied(to: currentText),
              Self.fingerprint(of: newText) == step.beforeFingerprint else {
            Self.beepUnlessTesting()
            return
        }

        let coordinator = coordinators
            .compactMap(\.value)
            .first { $0.canHandleUndoManager(manager) }
        let currentSelection = coordinator?.currentSceneSelection()

        if let coordinator {
            coordinator.applyUndoText(
                sceneID: step.sceneID,
                text: newText,
                selection: step.performSelection
            )
        } else {
            step.commit(step.sceneID, currentText, newText)
        }

        // A scene can disappear (project replaced, scene deleted) while the
        // action is on the stack. In that case leave no inverse behind.
        guard step.currentText(step.sceneID) != nil else { return }
        let inverse = FullScriptUndoStep(
            sceneID: step.sceneID,
            edit: step.edit.inverse,
            beforeFingerprint: step.afterFingerprint,
            afterFingerprint: step.beforeFingerprint,
            performSelection: currentSelection ?? step.inverseSelection,
            inverseSelection: step.performSelection,
            currentText: step.currentText,
            commit: step.commit,
            actionName: step.actionName,
            manager: manager
        )
        register(inverse, in: manager)
    }

    private static func beepUnlessTesting() {
        if !AppEnvironment.isRunningTests {
            NSSound.beep()
        }
    }
}
