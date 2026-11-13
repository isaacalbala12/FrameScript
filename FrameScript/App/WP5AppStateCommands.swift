import AppKit
import Foundation

/// Direction for the Next/Previous Scene commands.
enum SceneNavigationDirection: Equatable {
    case next
    case previous
}

/// The three commands WP5 needs from `AppState` that WP1 item 24 adds:
/// `saveExport(...) -> Bool`, `selectNextScene()`/`selectPreviousScene()` and
/// `revertToSaved()`.
///
/// WP5 does not own `AppState.swift`, so this file holds a *seam*: the names are
/// WP5-specific and the default implementations below keep today's behaviour.
/// When WP1 lands, delete the `AppState: AppStateCommandSeam` extension and call
/// the WP1 methods from `FrameScriptApp.swift` / `AppShellView.swift` directly.
@MainActor
protocol AppStateCommandSeam {
    /// Writes the rendered export. `true` means the sheet can dismiss, `false`
    /// means the write failed and the user must keep the sheet (and its chosen
    /// format/preview) open.
    func saveExportReportingStatus(
        format: ExportFormat,
        preferences: ExportPreferences,
        to url: URL
    ) -> Bool

    /// Selects the neighbouring scene in visual order. Returns `true` when the
    /// selection changed, so the caller can decide whether to scroll.
    @discardableResult
    func selectAdjacentScene(_ direction: SceneNavigationDirection) -> Bool

    /// Discards unsaved edits after confirmation by reloading the file.
    @discardableResult
    func revertProjectToSaved() -> Bool
}

// MARK: - Default implementations (pre-WP1 behaviour)

@MainActor
extension AppState: AppStateCommandSeam {
    func saveExportReportingStatus(
        format: ExportFormat,
        preferences: ExportPreferences,
        to url: URL
    ) -> Bool {
        // Today's `saveExport` reports failures through `ErrorCenter` only.
        // Keeping the sheet open on failure needs WP1's `Bool` return.
        saveExport(format: format, preferences: preferences, to: url)
        return true
    }

    @discardableResult
    func selectAdjacentScene(_ direction: SceneNavigationDirection) -> Bool {
        let scenes = project.scenes.sortedByOrder
        guard !scenes.isEmpty else { return false }
        let currentIndex = scenes.firstIndex { $0.id == editorState.selectedSceneID }
        let targetIndex: Int
        switch (direction, currentIndex) {
        case let (.next, index?):
            targetIndex = min(index + 1, scenes.count - 1)
        case let (.previous, index?):
            targetIndex = max(index - 1, 0)
        case (.next, nil), (.previous, nil):
            targetIndex = 0
        }
        guard scenes[targetIndex].id != editorState.selectedSceneID else { return false }
        selectScene(scenes[targetIndex].id)
        return true
    }

    @discardableResult
    func revertProjectToSaved() -> Bool {
        guard hasOpenProject, projectStore.currentFileURL != nil else { return false }
        if projectStore.hasUnsavedFileChanges {
            let alert = NSAlert()
            alert.messageText = localized("dialog.revertToSaved.title")
            alert.informativeText = localized("dialog.revertToSaved.message")
            alert.alertStyle = .warning
            alert.addButton(withTitle: localized("dialog.revertToSaved.revert"))
            alert.addButton(withTitle: localized("project.unsaved.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        return reloadProjectFromDisk()
    }
}
