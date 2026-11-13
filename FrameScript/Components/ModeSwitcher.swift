import SwiftUI

struct ModeSwitcher: View {
    /// Four modes no longer fit the 980 pt minimum window at the original
    /// width; the compact width still leaves room for the shortcut badges.
    private var buttonWidth: CGFloat {
        WorkspaceMode.allCases.count >= 4 ? 88 : 112
    }
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var selection: WorkspaceMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    ZStack {
                        Color.clear

                        HStack(spacing: 5) {
                            Text(title(for: mode))
                                .lineLimit(1)
                                .minimumScaleFactor(0.88)
                            Text(appState.shortcutDisplay(for: shortcutCommand(for: mode)))
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 4)
                                .frame(height: 16)
                                .background {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(theme.hover)
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.divider))
                                }
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selection == mode ? theme.primaryText : theme.secondaryText)
                    .frame(width: buttonWidth, height: 28)
                    .contentShape(Rectangle())
                    .background {
                        if selection == mode {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.softAccent)
                        }
                    }
                }
                .buttonStyle(.cursorPlain)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title(for: mode))
                .accessibilityValue(
                    "\(appState.localized(selection == mode ? "accessibility.selected" : "accessibility.notSelected")), \(appState.shortcutDisplay(for: shortcutCommand(for: mode)))"
                )
                .accessibilityAddTraits(selection == mode ? [.isSelected] : [])
                .accessibilityIdentifier(accessibilityIdentifier(for: mode))
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.sidebar.opacity(0.82))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mode-switcher")
    }

    private func title(for mode: WorkspaceMode) -> String {
        switch mode {
        case .script: appState.localized("mode.script")
        case .bRoll: appState.localized("mode.bRoll")
        case .editing: appState.localized("mode.editing")
        case .timeline: appState.localized("mode.timeline")
        }
    }

    private func accessibilityIdentifier(for mode: WorkspaceMode) -> String {
        switch mode {
        case .script: "mode-switcher-script"
        case .bRoll: "mode-switcher-broll"
        case .editing: "mode-switcher-editing"
        case .timeline: "mode-switcher-timeline"
        }
    }

    private func shortcutCommand(for mode: WorkspaceMode) -> ShortcutCommand {
        switch mode {
        case .script: .scriptMode
        case .bRoll: .visualsMode
        case .editing: .editingMode
        case .timeline: .timelineMode
        }
    }
}
