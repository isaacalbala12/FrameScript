import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.frameTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var commandResults: [PaletteResult] {
        [
            PaletteResult(title: appState.localized("command.switchScript"), detail: shortcut(.scriptMode)) {
                appState.selectMode(.script)
            },
            PaletteResult(title: appState.localized("command.switchBRoll"), detail: shortcut(.visualsMode)) {
                appState.selectMode(.bRoll)
            },
            PaletteResult(title: appState.localized("command.switchEditing"), detail: shortcut(.editingMode)) {
                appState.selectMode(.editing)
            },
            PaletteResult(title: appState.localized("menu.teleprompter"), detail: shortcut(.teleprompter)) {
                appState.presentTeleprompter()
            },
            PaletteResult(title: appState.localized("scene.add"), detail: shortcut(.addScene), action: appState.addScene),
            PaletteResult(title: appState.localized("scene.duplicate"), detail: shortcut(.duplicateScene), action: appState.duplicateSelectedScene),
            PaletteResult(title: appState.localized("scene.delete"), detail: shortcut(.deleteScene), action: appState.deleteSelectedScene),
            PaletteResult(title: appState.localized("ai.analyzeCurrentScene"), detail: shortcut(.analyzeCurrentScene)) {
                appState.settings.editorPreferences.showAIReviewPanel = true
                Task { await appState.analyzeSelectedScene() }
            },
            PaletteResult(title: appState.localized("menu.generateHook"), detail: shortcut(.generateHook)) {
                HookSheetPresenter.shared.presentAfterPaletteDismissal(.hook)
            },
            PaletteResult(title: appState.localized("menu.suggestRehooks"), detail: shortcut(.suggestRehooks)) {
                HookSheetPresenter.shared.presentAfterPaletteDismissal(.rehook)
            },
            PaletteResult(title: appState.localized("command.openSettings"), detail: shortcut(.openSettings), action: {
                appState.openSettings(tab: .general)
                openSettings()
            }),
            PaletteResult(title: appState.localized("command.toggleFocus"), detail: shortcut(.toggleFocusMode)) {
                appState.isFocusModeEnabled.toggle()
            },
            PaletteResult(title: appState.localized("command.toggleSidebar"), detail: shortcut(.toggleContentsPanel)) {
                appState.isSidebarVisible.toggle()
            },
            PaletteResult(title: appState.localized("command.toggleAIReview"), detail: shortcut(.toggleAIReview)) {
                appState.settings.editorPreferences.showAIReviewPanel.toggle()
            },
            PaletteResult(title: appState.localized("project.browser"), detail: "") {
                appState.returnToProjectList()
            },
            PaletteResult(title: appState.localized("command.showShortcuts"), detail: shortcut(.showShortcuts)) {
                appState.isShortcutsPresented = true
            }
        ]
    }

    private func shortcut(_ command: ShortcutCommand) -> String {
        appState.shortcutDisplay(for: command)
    }

    private var settingResults: [PaletteResult] {
        [
            settingResult(tab: .general, key: "general.defaultTemplate", titleKey: "settings.defaultTemplate"),
            settingResult(tab: .editor, key: "editor.defaultSplit", titleKey: "settings.defaultSplit"),
            settingResult(tab: .appearance, key: "appearance.theme", titleKey: "settings.theme"),
            settingResult(tab: .appearance, key: "appearance.focusBehavior", titleKey: "settings.focusBehavior"),
            settingResult(tab: .editor, key: "editor.fontSize", titleKey: "settings.fontSize"),
            settingResult(tab: .ai, key: "ai.privacyMode", titleKey: "settings.privacyMode"),
            settingResult(tab: .export, key: "export.defaultFormat", titleKey: "settings.defaultFormat"),
            settingResult(tab: .templates, key: nil, title: appState.localized("settings.templates")),
            settingResult(tab: .advanced, key: nil, title: appState.localized("settings.advanced"))
        ]
    }

    private var sceneResults: [PaletteResult] {
        appState.project.scenes.sortedByOrder.map { scene in
            PaletteResult(id: "scene:\(scene.id.uuidString)", title: scene.title, detail: appState.localized("scene.kind")) {
                appState.selectScene(scene.id)
            }
        }
    }

    private var results: [PaletteResult] {
        let allResults = commandResults + (query.isEmpty ? [] : sceneResults + settingResults)
        guard !query.isEmpty else { return allResults }
        return allResults.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(appState.localized("command.search"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .padding(.horizontal, 18)
                .frame(height: 58)
                .focused($isSearchFocused)
                .onSubmit(runSelected)
                .textCursor()

            Divider()
                .overlay(theme.divider)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            run(result)
                        } label: {
                            HStack {
                                Text(result.title)
                                    .font(.system(size: 14))
                                Spacer()
                                Text(result.detail)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 38)
                            .background {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(index == selectedIndex ? theme.selection : Color.clear)
                            }
                        }
                        .buttonStyle(.cursorPlain)
                        .onHover { hovering in
                            if hovering {
                                selectedIndex = index
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 560, height: 420)
        .background(theme.background)
        .onAppear {
            isSearchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onChange(of: results.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
    }

    private func settingResult(tab: SettingsTab, key: String?, titleKey: String) -> PaletteResult {
        settingResult(tab: tab, key: key, title: appState.localized(titleKey))
    }

    private func settingResult(tab: SettingsTab, key: String?, title: String) -> PaletteResult {
        PaletteResult(id: "setting:\(tab.rawValue):\(key ?? title)", title: title, detail: tab.title(appState: appState)) {
            appState.windowState.pendingSettingsTab = tab
            appState.windowState.pendingSettingsHighlightKey = key
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    private func runSelected() {
        let currentResults = results
        guard currentResults.indices.contains(selectedIndex) else { return }
        run(currentResults[selectedIndex])
    }

    private func run(_ result: PaletteResult) {
        result.action()
        dismiss()
    }
}

private struct PaletteResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let action: () -> Void

    init(id: String? = nil, title: String, detail: String, action: @escaping () -> Void) {
        self.id = id ?? "command:\(title):\(detail)"
        self.title = title
        self.detail = detail
        self.action = action
    }
}
