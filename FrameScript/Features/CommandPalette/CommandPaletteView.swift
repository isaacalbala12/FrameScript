import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(EscaletaImportCoordinator.self) private var escaletaImport
    @Environment(\.dismiss) private var dismiss
    @Environment(\.frameTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var query: String
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    /// Seeds the search field so the empty-result state can be rendered in a
    /// snapshot. Production always starts empty.
    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
    }

    private var commandResults: [PaletteResult] {
        let availability = CommandAvailability(appState: appState)
        var results = PaletteCatalog.commands
            .filter { PaletteCatalog.isAvailable($0, availability: availability) }
            .map { command in
                PaletteResult(
                    id: "command:\(command.rawValue)",
                    title: appState.localized(command.definition.localizationKey),
                    detail: appState.shortcutDisplay(for: command)
                ) {
                    perform(command)
                }
            }

        if availability.canOpenOBSSettings {
            results.append(PaletteResult(title: appState.localized("recording.obs.settings"), detail: "") {
                appState.recording.isSettingsPresented = true
            })
        }
        if availability.canCloseProject {
            results.append(PaletteResult(title: appState.localized("project.browser"), detail: "") {
                appState.returnToProjectList()
            })
        }
        return results
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

            if results.isEmpty {
                emptyResults
            } else {
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

    /// An empty query always matches at least one command, so this is the
    /// "nothing matches your search" state (uiux 8).
    private var emptyResults: some View {
        VStack(spacing: 10) {
            Spacer()
            Text(String(format: appState.localized("command.noResults"), query))
                .font(.system(size: 14))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(appState.localized("command.clearSearch")) {
                query = ""
            }
            .buttonStyle(.bordered)
            .clickableCursor()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// One action per `ShortcutCommand`. Exhaustive on purpose: adding a command
    /// without a palette action becomes a compile error.
    private func perform(_ command: ShortcutCommand) {
        switch command {
        case .newProject:
            appState.requestNewProject()
        case .newProjectFromTemplate:
            appState.requestNewProject(showsTemplateBrowser: true)
        case .openProject:
            appState.openProject()
        case .import:
            appState.openDemoProject()
        case .save:
            appState.saveProject()
        case .saveAs:
            appState.saveProjectAs()
        case .export:
            PaletteActionHandoff.shared.opensExport = true
        case .importEscaleta:
            escaletaImport.chooseFile(appState: appState)
        case .exportEscaleta:
            appState.exportEscaletaMarkdown()
        case .showBackups:
            appState.showBackupsWindow()
        case .addScene:
            appState.addScene()
        case .duplicateScene:
            appState.duplicateSelectedScene()
        case .deleteScene:
            appState.deleteSelectedScene()
        case .moveSceneUp:
            appState.moveSelectedSceneUp()
        case .moveSceneDown:
            appState.moveSelectedSceneDown()
        case .previousScene:
            appState.selectAdjacentScene(.previous)
        case .nextScene:
            appState.selectAdjacentScene(.next)
        case .scriptMode:
            appState.selectMode(.script)
        case .visualsMode:
            appState.selectMode(.bRoll)
        case .editingMode:
            appState.selectMode(.editing)
        case .clipsMode:
            appState.selectMode(.clips)
        case .createClip:
            appState.createClipFromEditorSelection()
        case .timelineMode:
            appState.selectMode(.timeline)
        case .timelineZoomIn:
            appState.timelineZoomIn()
        case .timelineZoomOut:
            appState.timelineZoomOut()
        case .avScriptMode:
            appState.selectMode(.avScript)
        case .exportAVScript:
            appState.exportAVScript(format: .markdown)
        case .assets:
            appState.isAssetsPresented = true
        case .publishingPack:
            appState.showPublishingPanel()
        case .researchPanel:
            appState.openResearchPanel()
        case .showBoard:
            appState.showBoardWindow()
        case .resolvePack:
            ResolvePackPresenter.shared.presentAfterPaletteDismissal(
                languageCode: appState.resolvePackDefaultLanguageCode
            )
        case .commandPalette:
            break
        case .toggleContentsPanel:
            appState.isSidebarVisible.toggle()
        case .toggleAIReview:
            appState.settings.editorPreferences.showAIReviewPanel.toggle()
        case .toggleFocusMode:
            appState.isFocusModeEnabled.toggle()
        case .teleprompter:
            appState.presentTeleprompter()
        case .recordTake:
            appState.toggleRecordingTake()
        case .toggleRecordingPanel:
            appState.recording.isPanelVisible.toggle()
        case .productionChecklist:
            ProductionPresentation.shared.presentAfterPaletteDismissal()
        case .analyzeCurrentScene:
            appState.settings.editorPreferences.showAIReviewPanel = true
            Task { await appState.analyzeSelectedScene() }
        case .openSettings:
            appState.openSettings(tab: .general)
            openSettings()
        case .showShortcuts:
            appState.isShortcutsPresented = true
        case .generateHook:
            HookSheetPresenter.shared.presentAfterPaletteDismissal(.hook)
        case .suggestRehooks:
            HookSheetPresenter.shared.presentAfterPaletteDismissal(.rehook)
        }
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
