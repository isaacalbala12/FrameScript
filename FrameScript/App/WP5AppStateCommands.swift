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

// MARK: - Implementation (delegates to the WP1 AppState commands)

@MainActor
extension AppState: AppStateCommandSeam {
    func saveExportReportingStatus(
        format: ExportFormat,
        preferences: ExportPreferences,
        to url: URL
    ) -> Bool {
        saveExport(format: format, preferences: preferences, to: url)
    }

    @discardableResult
    func selectAdjacentScene(_ direction: SceneNavigationDirection) -> Bool {
        let before = editorState.selectedSceneID
        switch direction {
        case .next: selectNextScene()
        case .previous: selectPreviousScene()
        }
        return editorState.selectedSceneID != before
    }

    @discardableResult
    func revertProjectToSaved() -> Bool {
        guard hasOpenProject, projectStore.currentFileURL != nil, !recording.hasActiveTake else { return false }
        return revertToSaved()
    }
}
