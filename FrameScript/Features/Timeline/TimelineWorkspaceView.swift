import AppKit
import FrameScriptCore
import SwiftUI

/// F18: a horizontal, read-only map of the script. The document model is
/// snapshotted on the main actor, the geometry is built off the main actor, and
/// the canvas only draws the resulting blocks.
struct TimelineWorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.undoManager) private var undoManager
    @State private var zoom = TimelineViewState.shared
    @State private var layout = TimelineLayout.empty
    @State private var isPending = true
    @State private var selectedBlockID: String?
    @State private var selectedSceneID: UUID?
    @State private var canvasWidth: CGFloat = 0

    /// Width the timeline canvas gets: the pane minus the track-label column
    /// (112 + divider) and a small right margin.
    static let canvasInset: CGFloat = 113 + 12

    private var fitWidth: Double {
        max(320, Double(canvasWidth) - Double(Self.canvasInset))
    }

    var body: some View {
        GeometryReader { proxy in
            TimelinePanelView(
                layout: layout,
                language: appState.currentLanguage,
                theme: theme,
                pointsPerSecond: zoom.pointsPerSecond,
                zoomFraction: Binding(
                    get: { zoom.zoomFraction },
                    set: { zoom.zoomFraction = $0 }
                ),
                selectedBlockID: selectedBlockID,
                selectedSceneID: selectedSceneID,
                isPending: isPending,
                onSelectBlock: select,
                onMoveScene: moveScene,
                onZoomIn: zoom.zoomIn,
                onZoomOut: zoom.zoomOut,
                onZoomChange: { zoom.setPointsPerSecond($0) },
                onFit: fitToWidth,
                isFitted: TimelineZoom.isFitted(
                    pointsPerSecond: zoom.pointsPerSecond,
                    totalDuration: layout.totalDuration,
                    availableWidth: fitWidth
                ),
                onGoToScript: { appState.selectMode(.script) }
            )
            .task(id: refreshKey) {
                canvasWidth = proxy.size.width
                await rebuild()
            }
            .onChange(of: proxy.size.width, initial: true) { _, width in
                canvasWidth = width
                refitIfFollowing()
            }
        }
        .onAppear {
            selectedSceneID = appState.selectedScene?.id
        }
        .onChange(of: appState.selectedScene?.id) { _, newValue in
            selectedSceneID = newValue
        }
        .background(theme.editorSurface)
    }

    // MARK: Refresh

    private var refreshKey: TimelineRefreshKey {
        TimelineRefreshKey(
            updatedAt: appState.project.updatedAt,
            rhythmRevision: RhythmReviewCenter.shared.revision,
            wordsPerMinute: appState.currentDurationWordsPerMinute,
            pauseDefaults: appState.settings.editorPreferences.markupPauseDefaults,
            sceneCount: appState.project.scenes.count
        )
    }

    @MainActor
    private func rebuild() async {
        if !layout.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        isPending = true
        let input = appState.timelineInput()
        let built = await Task.detached(priority: .userInitiated) {
            TimelineLayoutBuilder.build(input)
        }.value
        guard !Task.isCancelled else { return }
        layout = built
        isPending = false

        // The default zoom fits the whole video to the canvas; it keeps
        // doing so until the writer zooms by hand.
        refitIfFollowing()
    }

    /// Explicit «Ajustar»: fit now and resume following the canvas.
    private func fitToWidth() {
        zoom.fitAndFollow(totalDuration: layout.totalDuration, availableWidth: fitWidth)
    }

    private func refitIfFollowing() {
        zoom.refitIfFollowing(totalDuration: layout.totalDuration, availableWidth: fitWidth)
    }

    // MARK: Actions

    private func select(_ block: TimelineBlock) {
        selectedBlockID = block.id
        selectedSceneID = block.sceneID

        switch block.track {
        case .scenes, .takes:
            appState.openTimelineScene(block.sceneID)
        case .narration, .pauses, .warnings:
            let range = block.sourceRange.map { NSRange(location: $0.location, length: $0.length) }
            appState.openTimelineScene(block.sceneID, sourceRange: range)
        case .bRoll:
            guard let itemID = block.itemID else {
                appState.openTimelineScene(block.sceneID)
                return
            }
            appState.openTimelineProductionItem(itemID, sceneID: block.sceneID, mode: .bRoll)
        case .editing:
            guard let itemID = block.itemID else {
                appState.openTimelineScene(block.sceneID)
                return
            }
            appState.openTimelineProductionItem(itemID, sceneID: block.sceneID, mode: .editing)
        }
    }

    private func moveScene(_ sceneID: UUID, _ destination: Int) {
        appState.moveTimelineScene(
            sceneID,
            toSortedIndex: destination,
            undoManager: undoManager
        )
    }
}

private struct TimelineRefreshKey: Equatable {
    let updatedAt: Date
    let rhythmRevision: Int
    let wordsPerMinute: Int
    let pauseDefaults: PauseDefaults
    let sceneCount: Int
}
