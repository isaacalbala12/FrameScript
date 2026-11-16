import AppKit
import Foundation
import FrameScriptCore

@MainActor
extension AppState {
    // MARK: Layout input

    /// Snapshot of the document for one layout pass. Uses the same learned
    /// words-per-minute and pause defaults as every other duration surface.
    func timelineInput() -> TimelineProjectInput {
        let configuration = durationConfiguration(forLanguage: durationProjectLanguage)
        var selectedTakeIDs: [UUID: UUID] = [:]
        var warningsByScene: [UUID: [RhythmWarning]] = [:]

        for scene in project.scenes {
            if let takeID = sceneDurationSummary(for: scene).realTakeID {
                selectedTakeIDs[scene.id] = takeID
            }
            let warnings = RhythmReviewCenter.shared.warnings(for: scene.id)
            if !warnings.isEmpty {
                warningsByScene[scene.id] = warnings
            }
        }

        return TimelineInputBuilder.input(
            project: project,
            configuration: configuration,
            selectedTakeIDs: selectedTakeIDs,
            warningsByScene: warningsByScene,
            projectWarnings: RhythmReviewCenter.shared.projectWarnings,
            interfaceLanguage: currentLanguage
        )
    }

    // MARK: Navigation

    /// Selects a scene and opens the script editor. A paragraph range also
    /// places the caret on that paragraph.
    func openTimelineScene(_ sceneID: UUID, sourceRange: NSRange? = nil) {
        if let sourceRange {
            TimelineNavigation.shared.requestJump(sceneID: sceneID, range: sourceRange)
        } else {
            TimelineNavigation.shared.clear()
        }
        selectScene(sceneID)
        selectMode(.script)
    }

    /// Selects a Visuals or Editing item and opens its workspace. Unanchored
    /// items cannot be selected in their marker list, so the workspace still
    /// opens with no marker selected: there the user can repair or delete it.
    func openTimelineProductionItem(_ itemID: UUID, sceneID: UUID, mode: WorkspaceMode) {
        guard mode == .bRoll || mode == .editing else { return }
        TimelineNavigation.shared.clear()
        selectScene(sceneID)
        if !selectProductionItem(itemID, mode: mode) {
            clearProductionSelection()
            transitionEditorContext(mode: mode)
        }
    }

    // MARK: Scene reordering

    /// Moves a scene to an insertion index computed from the dragged block.
    /// One call registers exactly one undo step, mirroring the sidebar's
    /// move-up/move-down behaviour.
    func moveTimelineScene(
        _ sceneID: UUID,
        toSortedIndex destination: Int,
        undoManager: UndoManager? = nil
    ) {
        let currentIDs = project.scenes.sortedByOrder.map(\.id)
        let newIDs = TimelineSceneOrder.reorderedIDs(
            currentIDs,
            moving: sceneID,
            to: destination
        )
        guard newIDs != currentIDs else { return }
        applyTimelineSceneOrder(newIDs, undoManager: undoManager ?? projectWindow?.undoManager)
    }

    private func applyTimelineSceneOrder(_ ids: [UUID], undoManager: UndoManager?) {
        let currentIDs = project.scenes.sortedByOrder.map(\.id)
        guard ids != currentIDs else { return }

        undoManager?.registerUndo(withTarget: self) { target in
            target.applyTimelineSceneOrder(currentIDs, undoManager: undoManager)
        }
        undoManager?.setActionName(localized("timeline.moveSceneAction"))

        let scenesByID = Dictionary(uniqueKeysWithValues: project.scenes.map { ($0.id, $0) })
        let ordered = ids.compactMap { scenesByID[$0] }
        guard ordered.count == project.scenes.count else { return }
        project.scenes = ordered
        for (index, scene) in ordered.enumerated() {
            scene.order = index
        }
        touchProject()
    }

    // MARK: Zoom commands

    func timelineZoomIn() {
        TimelineViewState.shared.zoomIn()
    }

    func timelineZoomOut() {
        TimelineViewState.shared.zoomOut()
    }
}
