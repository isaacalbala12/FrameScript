import SwiftUI

struct SceneSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(appState.project.scenes.sortedByOrder) { scene in
                        SidebarRow(
                            scene: scene,
                            isSelected: scene.id == appState.selectedScene?.id,
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
                .padding(.horizontal, 10)
                .padding(.top, 12)
            }

            Divider()
                .overlay(theme.divider)

            VStack(spacing: 6) {
                SidebarAction(title: appState.localized("scene.add"), shortcut: appState.shortcutDisplay(for: .addScene), action: appState.addScene)
                SidebarAction(title: appState.localized("scene.duplicate"), shortcut: appState.shortcutDisplay(for: .duplicateScene), action: appState.duplicateSelectedScene)
                SidebarAction(title: appState.localized("scene.delete"), shortcut: appState.shortcutDisplay(for: .deleteScene), action: appState.deleteSelectedScene)
            }
            .padding(10)
        }
        .background(theme.sidebar)
    }
}

struct SidebarRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let isSelected: Bool
    let renameAction: () -> Void
    let duplicateAction: () -> Void
    let addAfterAction: () -> Void
    let moveUpAction: () -> Void
    let moveDownAction: () -> Void
    let deleteAction: () -> Void
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? theme.accent.color : Color.clear)
                    .frame(width: 2, height: 34)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", scene.order + 1))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                        Text(scene.title)
                            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
                            .lineLimit(1)
                    }

                    Text(DurationEstimator.formatted(scene.estimatedDuration))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText.opacity(0.82))
                        .monospacedDigit()
                }

                RhythmSidebarBadge(sceneID: scene.id)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            }
        }
        .buttonStyle(.cursorPlain)
        .onHover { isHovering = $0 }
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
        .buttonStyle(.cursorPlain)
    }
}
