import SwiftUI

struct TopToolbar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 14) {
            Menu {
                Button(appState.localized("project.rename")) { appState.renameProject() }
                projectMenuButton(appState.localized("project.save"), shortcut: .save) { appState.saveProject() }
                projectMenuButton(appState.localized("project.saveAs"), shortcut: .saveAs) { appState.saveProjectAs() }
                Button(appState.localized("project.reveal")) { appState.revealProjectInFinder() }
                    .disabled(appState.projectStore.currentFileURL == nil)
                Divider()
                projectMenuButton(appState.localized("project.export"), shortcut: .export) { appState.exportProject() }
                Divider()
                Button(appState.localized("project.browser")) { appState.returnToProjectList() }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.project.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Text(appState.displayName(appState.saveState))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.cursorPlain)
            .frame(width: 210, alignment: .leading)

            Spacer(minLength: 8)

            ModeSwitcher(selection: Binding(
                get: { appState.selectedMode },
                set: { appState.selectMode($0) }
            ))

            Spacer(minLength: 8)

            Text(DurationEstimator.formatted(appState.totalDuration))
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()

            Button {
                appState.recording.isPanelVisible.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(recordingStatusColor)
                        .frame(width: 6, height: 6)
                    Text(recordingStatusText)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .frame(height: 30)
                .padding(.horizontal, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(appState.recording.isPanelVisible ? theme.accentSoft : Color.clear)
                }
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help("\(appState.localized("recording.toolbar.help")) · \(recordingStatusText)")

            HStack(spacing: 5) {
                toolbarButton(
                    systemName: "square.and.arrow.up",
                    help: appState.localized("project.export"),
                    action: appState.exportProject
                )

                toolbarDivider

                Button {
                    appState.isFocusModeEnabled.toggle()
                } label: {
                    Image(systemName: appState.isFocusModeEnabled ? "viewfinder.circle.fill" : "viewfinder")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 30, height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(appState.isFocusModeEnabled ? theme.accentSoft : Color.clear)
                        }
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(appState.isFocusModeEnabled ? theme.accent.color : theme.secondaryText)
                .help(appState.localized("toolbar.focusMode"))

                toolbarDivider

                Button {
                    appState.isCommandPalettePresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                        Text(appState.shortcutDisplay(for: .commandPalette))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.horizontal, 4)
                            .frame(height: 17)
                            .background {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(theme.hover)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(theme.divider, lineWidth: 1)
                                    }
                            }
                    }
                    .frame(height: 30)
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.secondaryText)
                .help("\(appState.localized("toolbar.commandPalette")) (\(appState.shortcutDisplay(for: .commandPalette)))")

                toolbarDivider

                toolbarButton(systemName: "gearshape", help: appState.localized("toolbar.settings")) {
                    appState.openSettings(tab: .general)
                    openSettings()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(theme.background)
        .task {
            await appState.recording.connectAutomaticallyIfNeeded()
        }
    }

    private var recordingStatusColor: Color {
        if appState.recording.phase.isActive { return theme.destructive }
        switch appState.recording.connectionState {
        case .connected: return theme.success
        case .connecting: return theme.warning
        case .failed: return theme.destructive
        case .disconnected: return theme.tertiaryText
        }
    }

    private var recordingStatusText: String {
        switch appState.recording.phase {
        case .countdown(let value):
            return "\(value)…"
        case .starting:
            return appState.localized("recording.starting")
        case .stopping:
            return appState.localized("recording.stopping")
        case .recording:
            return String(
                format: appState.localized("recording.status.recording"),
                DurationEstimator.formatted(appState.recording.elapsed)
            )
        case .idle:
            break
        }
        switch appState.recording.connectionState {
        case .connected:
            return appState.localized("recording.obs.connected")
        case .connecting:
            return appState.localized("recording.obs.connecting")
        case .failed:
            return appState.localized("recording.obs.failed")
        case .disconnected:
            return appState.localized("recording.obs.disconnected")
        }
    }

    private func toolbarButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(theme.secondaryText)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }

    /// This is a display-only hint. The application command menu owns the
    /// actual key equivalent, avoiding duplicate execution paths.
    private func projectMenuButton(
        _ title: String,
        shortcut: ShortcutCommand,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let binding = ProjectTitleMenuShortcutHints.binding(for: shortcut, settings: appState.settings) {
                    Text(binding.display)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }
}

enum ProjectTitleMenuShortcutHints {
    static func binding(for command: ShortcutCommand, settings: AppSettings) -> ShortcutBinding? {
        guard [.save, .saveAs, .export].contains(command) else { return nil }
        return settings.activeShortcut(for: command)
    }
}
