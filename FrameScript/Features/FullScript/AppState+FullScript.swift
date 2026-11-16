import Foundation

/// Selection and window-title plumbing for the continuous full-script editor.
///
/// The project model is untouched: every scene keeps its own `scriptText` and
/// the file format does not change. This extension only remembers which
/// presentation the sidebar selected and which scene owns the caret.
extension AppState {
    var isFullScriptSelected: Bool {
        editorState.isFullScriptSelected
    }

    /// Scene that contains the caret in the full-script editor.
    var fullScriptCaretScene: Scene? {
        guard let sceneID = editorState.fullScriptCaretSceneID else { return nil }
        return project.scenes.first { $0.id == sceneID }
    }

    /// The scene every editor-scoped surface must act on: the caret scene in
    /// full-script mode, the normal selection everywhere else.
    var activeEditorScene: Scene? {
        guard hasOpenProject else { return nil }
        if isFullScriptSelected {
            return fullScriptCaretScene ?? selectedScene
        }
        return selectedScene
    }

    /// Fixed sidebar entry: show every scene on one continuous page.
    func selectFullScript() {
        guard hasOpenProject else { return }
        let ordered = project.scenes.sortedByOrder
        let remembered = editorState.fullScriptCaretSceneID.flatMap { id in
            ordered.first { $0.id == id }?.id
        }
        let targetSceneID = remembered
            ?? editorState.selectedSceneID
            ?? ordered.first?.id

        if editorState.isFullScriptSelected && editorState.selectedMode == .script {
            if editorState.fullScriptCaretSceneID == nil {
                editorState.fullScriptCaretSceneID = targetSceneID
            }
            return
        }

        transitionEditorContext(mode: .script) {
            editorState.isFullScriptSelected = true
            editorState.fullScriptCaretSceneID = targetSceneID
        }
    }

    /// Called by the full-script text system as the caret crosses scene
    /// boundaries. This must not touch the project or mark it dirty.
    func setFullScriptCaretScene(_ sceneID: UUID?) {
        guard isFullScriptSelected else { return }
        let validSceneID = sceneID.flatMap { id in
            project.scenes.contains { $0.id == id } ? id : nil
        }
        guard editorState.fullScriptCaretSceneID != validSceneID else { return }
        editorState.fullScriptCaretSceneID = validSceneID
    }

    /// Second line of the toolbar-title area. While the full script is open it
    /// names the scene that owns the caret; otherwise it keeps the save state.
    var toolbarContextTitle: String {
        guard isFullScriptSelected else {
            return displayName(saveState)
        }
        guard let scene = fullScriptCaretScene ?? selectedScene else {
            return localized("fullScript.sidebarEntry")
        }
        let number = String(format: "%02d", scene.order + 1)
        // Scene first: at the 980 pt minimum the menu label truncates, and the
        // scene identity must survive the truncation.
        return "\(number) \(scene.title) · \(localized("fullScript.sidebarEntry"))"
    }
}
