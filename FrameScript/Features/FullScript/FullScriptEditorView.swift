import AppKit
import FrameScriptCore
import SwiftUI

/// Continuous, editable view of every scene.
///
/// The model stays untouched: each scene keeps its own `scriptText`, and every
/// keystroke is committed through `AppState.commitScriptTextChange` for the
/// scene that owns the caret. Scene headers are protected separators rendered
/// by the single NSTextView, never separate text inputs.
struct FullScriptEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var collapsedSceneIDs: Set<UUID> = []

    private var orderedScenes: [Scene] {
        appState.project.scenes.sortedByOrder
    }

    private var activeScene: Scene? {
        appState.fullScriptCaretScene ?? orderedScenes.first
    }

    private var snapshots: [FullScriptSceneSnapshot] {
        orderedScenes.map { scene in
            snapshot(for: scene)
        }
    }

    private var summaryText: String {
        let countText = L10n.plural(
            "fullScript.sceneCount",
            count: orderedScenes.count,
            language: appState.currentLanguage
        )
        let duration = DurationEstimator.formatted(
            orderedScenes.reduce(0) { $0 + max(0, $1.estimatedDuration) }
        )
        return "\(countText) · \(duration)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Same header → action bar gap as the single-scene editor.
            header
                .padding(.bottom, FrameLayout.editorMetaToBar - 14)

            if let activeScene {
                UXEditorActionBar(sceneID: activeScene.id)
            }

            if orderedScenes.isEmpty {
                Text(appState.localized("fullScript.empty"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 24)
            } else {
                FullScriptTextView(
                    scenes: snapshots,
                    appearance: appearance,
                    spellcheck: appState.settings.editorPreferences.spellcheck,
                    smartQuotes: appState.settings.editorPreferences.smartQuotes,
                    pauseDefaults: appState.settings.editorPreferences.markupPauseDefaults,
                    placeholder: appState.localized("script.placeholder"),
                    accessibilityLabel: appState.localized("fullScript.accessibilityLabel"),
                    accessibilityHint: appState.localized("fullScript.accessibilityHint"),
                    loadRestorationState: {
                        appState.editorState.fullScriptEditorState()
                    },
                    saveRestorationState: { state in
                        appState.editorState.setFullScriptEditorState(state)
                    },
                    currentSceneText: { @MainActor @Sendable [weak appState] sceneID in
                        appState?.project.scenes.first { $0.id == sceneID }?.scriptText
                    },
                    onSceneTextCommitted: { @MainActor @Sendable [weak appState] sceneID, previousText, text in
                        appState?.commitScriptTextChange(
                            sceneID: sceneID,
                            previousText: previousText,
                            text: text
                        )
                    },
                    onCaretSceneChanged: { [weak appState] sceneID in
                        appState?.setFullScriptCaretScene(sceneID)
                    },
                    onToggleCollapse: { sceneID in
                        if collapsedSceneIDs.contains(sceneID) {
                            collapsedSceneIDs.remove(sceneID)
                        } else {
                            collapsedSceneIDs.insert(sceneID)
                        }
                    },
                    onTeardown: { [weak appState] in
                        appState?.flushActiveEditorBoundary(flushEditor: false)
                    },
                    undoActionName: appState.localized("fullScript.undoTyping")
                )
                .frame(minHeight: appState.isFocusModeEnabled ? 430 : 390, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: ScriptEditorLayout.maximumTextColumnWidth, alignment: .leading)
        .padding(WorkspaceLayout.contentInset(isFocusModeEnabled: appState.isFocusModeEnabled))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.editorSurface)
        .onAppear {
            let target = appState.fullScriptCaretScene?.id
                ?? appState.selectedScene?.id
                ?? orderedScenes.first?.id
            appState.setFullScriptCaretScene(target)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("fullScript.title"))
                    .font(.system(size: appState.isFocusModeEnabled ? 32 : 27, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(appState.localized("fullScript.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 12)
            Text(summaryText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var appearance: FullScriptEditorAppearance {
        FullScriptEditorAppearance(
            fontSize: appState.settings.editorPreferences.fontSize,
            textColor: NSColor(theme.primaryText),
            secondaryTextColor: NSColor(theme.secondaryText),
            accentColor: NSColor(theme.accentText),
            backgroundColor: NSColor(theme.editorSurface),
            dividerColor: NSColor(theme.divider)
        )
    }

    private func snapshot(for scene: Scene) -> FullScriptSceneSnapshot {
        let number = String(format: "%02d", scene.order + 1)
        let duration = DurationEstimator.formatted(max(0, scene.estimatedDuration))
        let title = scene.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? appState.localized("fullScript.untitledScene")
            : scene.title
        let collapsed = collapsedSceneIDs.contains(scene.id)
        let chevron = collapsed ? "▸" : "▾"
        let headerText = "\(chevron)  \(appState.localized("fullScript.scenePrefix")) \(number)  ·  \(title)  ·  \(duration)"
        return FullScriptSceneSnapshot(
            id: scene.id,
            order: scene.order,
            headerText: headerText,
            numberText: number,
            durationText: duration,
            scriptText: scene.scriptText,
            isCollapsed: collapsed
        )
    }
}
