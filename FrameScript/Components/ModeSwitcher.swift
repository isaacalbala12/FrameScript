import SwiftUI

struct ModeSwitcher: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var selection: WorkspaceMode

    /// The toolbar knows its own width tier, so it asks for the compact row
    /// directly. Standalone callers (snapshots, other hosts) leave this `false`
    /// and `ViewThatFits` drops the shortcut badges when the row cannot fit.
    var prefersCompactButtons = false

    /// Six workspace modes no longer fit the 980 pt minimum window at the
    /// original fixed width, so the compact row tightens the buttons and drops
    /// the shortcut badges instead of clipping.
    var body: some View {
        Group {
            if prefersCompactButtons {
                switcher(compact: true)
            } else {
                ViewThatFits(in: .horizontal) {
                    switcher(compact: false)
                    switcher(compact: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mode-switcher")
    }

    private func switcher(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    HStack(spacing: 5) {
                        Text(title(for: mode))
                            .lineLimit(1)
                            .minimumScaleFactor(compact ? 0.8 : 0.88)
                        if !compact {
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
                    .padding(.horizontal, compact ? 6 : 0)
                    .frame(minWidth: compact ? nil : 96, minHeight: 28)
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                    .foregroundStyle(selection == mode ? theme.primaryText : theme.secondaryText)
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
        .fixedSize(horizontal: true, vertical: false)
    }

    private func title(for mode: WorkspaceMode) -> String {
        switch mode {
        case .script: appState.localized("mode.script")
        case .bRoll: appState.localized("mode.bRoll")
        case .editing: appState.localized("mode.editing")
        case .clips: appState.localized("mode.clips")
        case .timeline: appState.localized("mode.timeline")
        case .avScript: appState.localized("mode.avScript")
        }
    }

    private func accessibilityIdentifier(for mode: WorkspaceMode) -> String {
        switch mode {
        case .script: "mode-switcher-script"
        case .bRoll: "mode-switcher-broll"
        case .editing: "mode-switcher-editing"
        case .clips: "mode-switcher-clips"
        case .timeline: "mode-switcher-timeline"
        case .avScript: "mode-switcher-avscript"
        }
    }

    private func shortcutCommand(for mode: WorkspaceMode) -> ShortcutCommand {
        switch mode {
        case .script: .scriptMode
        case .bRoll: .visualsMode
        case .editing: .editingMode
        case .clips: .clipsMode
        case .timeline: .timelineMode
        case .avScript: .avScriptMode
        }
    }
}
