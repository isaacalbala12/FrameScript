import Foundation
import FrameScriptCore

@MainActor
extension AppState {
    // MARK: - Derived checklist

    /// Builds a document snapshot and derives the checklist synchronously.
    /// The panel uses this on open; normal edits go through the debounced
    /// `ProductionChecklistCenter`.
    var productionSnapshot: ProductionSnapshot {
        ProductionChecklist.snapshot(for: FrameScriptDocument.Project(project: project))
    }

    func refreshProductionChecklist() {
        guard hasOpenProject else {
            ProductionChecklistCenter.shared.clear()
            return
        }
        ProductionChecklistCenter.shared.refreshNow(project: project)
    }

    // MARK: - Navigation

    /// Opens the place an item points at. Publishing and research are forwarded
    /// to the integration seam because those panels live on other branches.
    @discardableResult
    func navigateToProductionTarget(_ target: ProductionTarget) -> Bool {
        switch target {
        case let .scene(sceneID):
            guard project.scenes.contains(where: { $0.id == sceneID }) else { return false }
            selectScene(sceneID)
            selectMode(.script)
            return true

        case let .bRoll(sceneID, itemID):
            guard project.scenes.contains(where: { $0.id == sceneID }) else { return false }
            selectScene(sceneID)
            selectMode(.bRoll)
            selectProductionItem(itemID, mode: .bRoll)
            return true

        case let .editing(sceneID, itemID):
            guard project.scenes.contains(where: { $0.id == sceneID }) else { return false }
            selectScene(sceneID)
            selectMode(.editing)
            selectProductionItem(itemID, mode: .editing)
            return true

        case let .takes(sceneID, languageCode):
            guard project.scenes.contains(where: { $0.id == sceneID }) else { return false }
            selectScene(sceneID)
            selectMode(.script)
            recording.selectedLanguageCode = languageCode
            recording.isPanelVisible = true
            return true

        case .publishing, .research:
            return productionNavigator?.navigate(to: target) ?? false

        case .manualTask:
            // Manual rows are edited in the checklist itself.
            return true
        }
    }

    // MARK: - Manual tasks

    @discardableResult
    func addProductionTask(
        text: String,
        kind: ChecklistTaskKind = .other,
        sceneID: UUID? = nil
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        project.checklistTasks.append(
            ChecklistTask(text: trimmed, kind: kind, sceneID: sceneID)
        )
        touchProject()
        refreshProductionChecklist()
        return true
    }

    @discardableResult
    func updateProductionTask(
        id: UUID,
        text: String,
        kind: ChecklistTaskKind,
        sceneID: UUID?
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = project.checklistTasks.firstIndex(where: { $0.id == id })
        else { return false }
        project.checklistTasks[index].text = trimmed
        project.checklistTasks[index].kind = kind
        project.checklistTasks[index].sceneID = sceneID
        touchProject()
        refreshProductionChecklist()
        return true
    }

    @discardableResult
    func toggleProductionTask(id: UUID) -> Bool {
        guard let index = project.checklistTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        project.checklistTasks[index].isDone.toggle()
        touchProject()
        refreshProductionChecklist()
        return true
    }

    @discardableResult
    func deleteProductionTask(id: UUID) -> Bool {
        guard let index = project.checklistTasks.firstIndex(where: { $0.id == id }) else {
            return false
        }
        project.checklistTasks.remove(at: index)
        touchProject()
        refreshProductionChecklist()
        return true
    }
}


extension ChecklistTaskKind {
    /// App-model equivalent of the core mapping so the panel and task editor
    /// share one label source.
    var productionKind: ProductionItemKind {
        switch self {
        case .record: .record
        case .acquire: .acquire
        case .edit: .edit
        case .research: .research
        case .other: .other
        }
    }
}
