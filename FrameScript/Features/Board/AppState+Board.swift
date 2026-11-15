import AppKit
import Foundation
import FrameScriptCore

@MainActor
extension AppState {
    // MARK: Window

    func showBoardWindow() {
        BoardPresenter.shared.show(appState: self)
    }

    // MARK: Opening a project from the board

    /// Opens the board's project in the main window. Returns false when the
    /// user cancelled or the file can no longer be read.
    @discardableResult
    func openBoardProject(
        _ summary: BoardProjectSummary,
        activatesApplication: Bool = true
    ) -> Bool {
        let target = summary.fileURL.standardizedFileURL
        if hasOpenProject,
           projectStore.currentFileURL?.standardizedFileURL == target {
            bringProjectWindowForward(activatesApplication: activatesApplication)
            return true
        }
        openProject(at: target)
        guard projectStore.currentFileURL?.standardizedFileURL == target else {
            return false
        }
        bringProjectWindowForward(activatesApplication: activatesApplication)
        return true
    }

    private func bringProjectWindowForward(activatesApplication: Bool) {
        if activatesApplication {
            NSApp.activate()
        }
        if let window = projectWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Project info editing
    //
    // These setters are used by the project-info popover. They mark the
    // project dirty, so the normal autosave and external-change detection path
    // writes the file exactly like any other edit.

    func setProjectTopic(_ topic: String) {
        let merged = BoardProjectTopic.merging(topic, into: project.topic)
        guard project.topic != merged else { return }
        project.topic = merged
        touchProject()
    }

    func setProjectVideoType(_ videoType: String) {
        guard project.videoType != videoType else { return }
        project.videoType = videoType
        touchProject()
    }

    func setProjectProductionStatus(_ status: ProductionStatus) {
        guard project.productionStatus != status else { return }
        project.productionStatus = status
        touchProject()
    }

    func setProjectTargetDate(_ date: Date?) {
        guard project.targetDate != date else { return }
        project.targetDate = date
        touchProject()
    }

    func setProjectPublishDate(_ date: Date?) {
        guard project.publishDate != date else { return }
        project.publishDate = date
        touchProject()
    }

    /// Templates give a new project its default video type. Values that the
    /// user later edits in the board are never overwritten.
    func applyBoardTemplateDefault(to project: FrameProject, template: FrameTemplate?) {
        guard project.videoType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let template,
              let type = BoardTemplateDefaults.videoType(forTemplateNamed: template.name) else {
            return
        }
        project.videoType = type
    }
}
