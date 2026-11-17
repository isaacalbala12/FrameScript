import SwiftUI

/// Keyboard navigation for the scene list. Arrow keys move the selection only
/// while a scene row (or the list) owns focus, so the script editor keeps its
/// own arrow-key behaviour.
enum SceneListNavigation {
    /// The scene that an arrow key should select, or `nil` at the ends.
    static func destination(
        in sceneIDs: [UUID],
        current: UUID?,
        direction: MoveCommandDirection
    ) -> UUID? {
        guard !sceneIDs.isEmpty else { return nil }
        guard let current, let index = sceneIDs.firstIndex(of: current) else {
            return direction == .down || direction == .right ? sceneIDs.first : sceneIDs.last
        }
        let step = direction == .down || direction == .right ? 1 : -1
        let next = index + step
        guard sceneIDs.indices.contains(next) else { return nil }
        return sceneIDs[next]
    }
}

/// Delete enablement for the scene sidebar's Delete button.
///
/// One rule for every surface that removes a scene: the menu and the command
/// palette use `CommandAvailability.canDeleteScene`, and an active take blocks
/// all of them. The old sidebar rule only looked at the selected scene, so it
/// allowed deleting a different scene while OBS was still recording.
enum SceneSidebarDeleteRule {
    static func isDisabled(hasSelection: Bool, hasActiveTake: Bool) -> Bool {
        !hasSelection || hasActiveTake
    }
}

struct SceneSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    private var orderedSceneIDs: [UUID] {
        appState.project.scenes.sortedByOrder.map(\.id)
    }

    private var deleteDisabled: Bool {
        SceneSidebarDeleteRule.isDisabled(
            hasSelection: appState.selectedScene != nil,
            hasActiveTake: appState.recording.hasActiveTake
        )
    }

    var body: some View {
        let unconfirmedCounts = appState.researchUnconfirmedCountsByScene()
        return VStack(spacing: 0) {
            ProductionSidebarEntry()
                .padding(.horizontal, FrameLayout.sidebarOuterInset)
                .padding(.vertical, FrameSpacing.s)

            Divider()
                .overlay(theme.divider)

            ScrollView {
                LazyVStack(spacing: 2) {
                    FullScriptSidebarRow(isSelected: appState.isFullScriptSelected) {
                        appState.selectFullScript()
                    }

                    ForEach(appState.project.scenes.sortedByOrder) { scene in
                        SidebarRow(
                            scene: scene,
                            isSelected: !appState.isFullScriptSelected && scene.id == appState.selectedScene?.id,
                            researchUnconfirmedCount: unconfirmedCounts[scene.id, default: 0],
                            renameAction: appState.renameSelectedScene,
                            duplicateAction: appState.duplicateSelectedScene,
                            addAfterAction: { appState.addScene(after: scene.id) },
                            moveUpAction: appState.moveSelectedSceneUp,
                            moveDownAction: appState.moveSelectedSceneDown,
                            deleteAction: appState.deleteSelectedScene
                        ) {
                            appState.selectScene(scene.id)
                        }
                    }
                }
                .padding(.horizontal, FrameLayout.sidebarOuterInset)
                .padding(.vertical, FrameSpacing.s)
            }
            // The move-command handler only fires when the scroll view owns
            // focus; a lazy stack of buttons does not make its container
            // focusable on macOS (uiux: arrow keys were dead code).
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                guard let destination = SceneListNavigation.destination(
                    in: orderedSceneIDs,
                    current: appState.selectedScene?.id,
                    direction: direction
                ) else { return }
                appState.selectScene(destination)
            }

            Divider()
                .overlay(theme.divider)

            VStack(spacing: FrameSpacing.xxs) {
                SidebarAction(
                    title: appState.localized("scene.add"),
                    shortcut: appState.shortcutDisplay(for: .addScene),
                    action: appState.addScene
                )
                SidebarAction(
                    title: appState.localized("scene.duplicate"),
                    shortcut: appState.shortcutDisplay(for: .duplicateScene),
                    enabled: appState.selectedScene != nil,
                    action: appState.duplicateSelectedScene
                )
                SidebarAction(
                    title: appState.localized("scene.delete"),
                    shortcut: appState.shortcutDisplay(for: .deleteScene),
                    enabled: !deleteDisabled,
                    action: appState.deleteSelectedScene
                )
            }
            .padding(.horizontal, FrameLayout.sidebarOuterInset)
            .padding(.vertical, FrameSpacing.s)
        }
        .background(theme.sidebar)
    }
}

/// Fixed entry above scene 01. It selects the continuous presentation; it is
/// not a scene and never participates in scene ordering, duplication or delete.
struct FullScriptSidebarRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            SidebarRowLayout(isSelected: isSelected, trailingInset: FrameLayout.sidebarRowInset, fill: rowFill) {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.accent.color : theme.secondaryText)
            } title: {
                Text(appState.localized("fullScript.sidebarEntry"))
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
            } detail: {
                Text(L10n.plural(
                    "fullScript.sceneCount",
                    count: appState.project.scenes.count,
                    language: appState.currentLanguage
                ))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            } trailing: {
                EmptyView()
            }
        }
        .buttonStyle(.cursorPlain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(appState.localized("fullScript.title"))
    }

    private var rowFill: Color {
        if isSelected {
            return theme.softAccent.opacity(0.58)
        }
        if isHovering {
            return theme.hover
        }
        return .clear
    }
}

struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let isSelected: Bool
    let researchUnconfirmedCount: Int
    let renameAction: () -> Void
    let duplicateAction: () -> Void
    let addAfterAction: () -> Void
    let moveUpAction: () -> Void
    let moveDownAction: () -> Void
    let deleteAction: () -> Void
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button(action: action) {
                SidebarRowLayout(
                    isSelected: isSelected,
                    trailingInset: FrameLayout.sidebarRowInset,
                    fill: rowFill
                ) {
                    Text(String(format: "%02d", scene.order + 1))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                } title: {
                    // Two lines before truncating: at the default 195 pt width a
                    // single line cut most Spanish scene titles to two words.
                    Text(scene.title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } detail: {
                    // Badges live on the second line, after the duration, so the
                    // title keeps the full row width.
                    HStack(spacing: FrameSpacing.xs) {
                        SceneDurationInlineText(summary: appState.sceneDurationSummary(for: scene))
                            .layoutProbe("sidebar.duration")
                        Spacer(minLength: 0)
                        RhythmSidebarBadge(sceneID: scene.id)
                    }
                    // Room for the research badge, which is a sibling button.
                    .padding(.trailing, researchUnconfirmedCount > 0 ? 34 : 0)
                } trailing: {
                    EmptyView()
                }
            }
            .buttonStyle(.cursorPlain)

            // Sibling button, not nested inside the row button, so the badge
            // opens the research panel instead of only selecting the scene.
            ResearchSidebarBadge(sceneID: scene.id, count: researchUnconfirmedCount)
                .padding(.bottom, FrameSpacing.s - 1) // centers it on the duration line
                .padding(.trailing, FrameLayout.sidebarRowInset)
        }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(scene.title)
        .contextMenu {
            Button(appState.localized("scene.rename")) {
                action()
                renameAction()
            }
            Button(appState.localized("scene.duplicate")) {
                action()
                duplicateAction()
            }
            Button(appState.localized("scene.addAfter")) {
                action()
                addAfterAction()
            }
            Divider()
            Button(appState.localized("scene.moveUp")) {
                action()
                moveUpAction()
            }
            Button(appState.localized("scene.moveDown")) {
                action()
                moveDownAction()
            }
            Divider()
            Button(appState.localized("scene.delete"), role: .destructive) {
                action()
                deleteAction()
            }
            .disabled(appState.recording.hasActiveTake && appState.recording.activeSceneID == scene.id)
        }
    }

    private var rowFill: Color {
        if isSelected {
            return theme.softAccent.opacity(0.58)
        }
        if isHovering {
            return theme.hover
        }
        return .clear
    }
}

private struct SidebarAction: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let shortcut: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .layoutProbe("sidebar.leading")
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, FrameLayout.sidebarRowInset)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.cursorPlain)
        .disabled(!enabled)
    }
}

/// Shared geometry for every sidebar row: a fixed leading slot (icon or scene
/// number), the title column, a trailing badge pinned to the right edge, and
/// the selection stripe drawn inside the fill instead of taking layout space.
/// Production, "Guion completo" and the scene rows all start their first glyph
/// at `FrameLayout.sidebarContentLeading` and their titles at
/// `FrameLayout.sidebarTitleLeading`.
struct SidebarRowLayout<Leading: View, Title: View, Detail: View, Trailing: View>: View {
    @Environment(\.frameTheme) private var theme
    let isSelected: Bool
    let trailingInset: CGFloat
    let fill: Color
    @ViewBuilder var leading: Leading
    @ViewBuilder var title: Title
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FrameLayout.sidebarSlotSpacing) {
            leading
                .frame(width: FrameLayout.sidebarLeadingSlot, alignment: .leading)
                .layoutProbe("sidebar.leading")

            VStack(alignment: .leading, spacing: FrameSpacing.xs) {
                title
                detail
            }
            .layoutProbe("sidebar.title")
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.leading, FrameLayout.sidebarRowInset)
        .padding(.trailing, trailingInset)
        .padding(.vertical, FrameSpacing.s)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.card, style: .continuous)
                .fill(fill)
        }
        .overlay(alignment: .leading) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.accent.color)
                    .frame(width: 2)
                    .padding(.vertical, FrameSpacing.s)
            }
        }
    }
}
