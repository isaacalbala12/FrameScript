import SwiftUI

struct SettingsView: View {
    var body: some View {
        SettingsRootView()
    }
}

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        @Bindable var settingsStore = appState.settingsStore

        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab)
                .frame(width: 190)

            Divider()
                .overlay(theme.divider)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        switch selectedTab {
                        case .general:
                            GeneralSettings(settings: $settingsStore.settings)
                        case .appearance:
                            AppearanceSettings(settings: $settingsStore.settings)
                        case .editor:
                            EditorSettings(settings: $settingsStore.settings)
                            EditorMarkupSettingsSection()
                                .padding(.top, 24)
                        case .templates:
                            TemplateSettings()
                        case .ai:
                            AISettings(settings: $settingsStore.settings)
                        case .export:
                            ExportSettings(settings: $settingsStore.settings)
                        case .keyboardShortcuts:
                            KeyboardShortcutsSettings(settings: $settingsStore.settings)
                        case .advanced:
                            AdvancedSettings(
                                resetAction: appState.resetSettingsWithConfirmation,
                                clearRecentsAction: appState.clearRecentProjects
                            )
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .background(theme.windowBackground)
                .onAppear {
                    handleSettingsRequest(using: proxy)
                }
                .onChange(of: appState.windowState.settingsRequestID) { _, _ in
                    handleSettingsRequest(using: proxy)
                }
            }
        }
        .frame(minWidth: 840, idealWidth: 940, maxWidth: 1120, minHeight: 560, idealHeight: 650, maxHeight: 800)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            selectedTab = appState.windowState.requestedSettingsTab
        }
        .onChange(of: appState.windowState.requestedSettingsTab) { _, newValue in
            selectedTab = newValue
        }
    }

    private func handleSettingsRequest(using proxy: ScrollViewProxy) {
        let requestID = appState.windowState.settingsRequestID
        let highlightKey = appState.windowState.requestedSettingsHighlightKey
        selectedTab = appState.windowState.requestedSettingsTab
        guard let highlightKey else { return }

        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(highlightKey, anchor: .center)
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard appState.windowState.settingsRequestID == requestID else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                appState.windowState.requestedSettingsHighlightKey = nil
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var selectedTab: SettingsTab
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Label(tab.title(appState: appState), systemImage: tab.icon)
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(sidebarFill(for: tab))
                        }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.cursorPlain)
                .help(tab.title(appState: appState))
                .onHover { hoveredTab = $0 ? tab : nil }
            }

            Spacer()
        }
        .padding(12)
        .background(theme.panelBackground)
    }

    private func sidebarFill(for tab: SettingsTab) -> Color {
        if selectedTab == tab {
            return theme.accentSoft.opacity(0.72)
        }
        if hoveredTab == tab {
            return theme.hover
        }
        return .clear
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var appState
    @Binding var settings: AppSettings

    var body: some View {
        SettingsSection(title: appState.localized("settings.general"), resetAction: {
            settings.generalPreferences = AppSettings.defaults.generalPreferences
            appState.rebuildProductionSegments()
        }) {
            SettingsRow(appState.localized("settings.language")) {
                Picker("", selection: $settings.generalPreferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName(in: appState.currentLanguage)).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            SettingsRow(appState.localized("settings.launchBehavior")) {
                Picker("", selection: $settings.generalPreferences.launchBehavior) {
                    Text(appState.localized("launch.showProjectBrowser")).tag(LaunchBehavior.showProjectBrowser)
                    Text(appState.localized("launch.restoreLastProject")).tag(LaunchBehavior.restoreLastProject)
                }
                .labelsHidden()
                .frame(width: 220)
            }

            SettingsRow(appState.localized("settings.autosave")) {
                Toggle("", isOn: $settings.generalPreferences.autosaveEnabled)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.autosaveInterval")) {
                Stepper("\(settings.generalPreferences.autosaveIntervalSeconds)s", value: $settings.generalPreferences.autosaveIntervalSeconds, in: 5...120, step: 5)
                    .disabled(!settings.generalPreferences.autosaveEnabled)
            }

            SettingsRow(appState.localized("settings.defaultTemplate"), highlightKey: "general.defaultTemplate") {
                Picker("", selection: $settings.generalPreferences.defaultNewProjectTemplate) {
                    ForEach(appState.scriptTemplates()) { template in
                        Text(appState.displayName(template)).tag(template.name)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            SettingsRow(appState.localized("settings.blankProjectStart")) {
                Picker("", selection: $settings.generalPreferences.blankProjectStart) {
                    ForEach(BlankProjectStart.allCases) { option in
                        Text(blankProjectStartTitle(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            SettingsRow(appState.localized("settings.confirmDelete")) {
                Toggle("", isOn: $settings.generalPreferences.confirmBeforeDeleting)
                    .labelsHidden()
            }
        }
    }

    private func blankProjectStartTitle(_ option: BlankProjectStart) -> String {
        switch option {
        case .noScenes: appState.localized("blank.noScenes")
        case .oneEmptyScene: appState.localized("blank.oneEmptyScene")
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppState.self) private var appState
    @Binding var settings: AppSettings

    var body: some View {
        SettingsSection(title: appState.localized("settings.appearance"), resetAction: {
            settings.theme = AppSettings.defaults.theme
            settings.accentColor = AppSettings.defaults.accentColor
            settings.windowPreferences.sidebarDefaultVisible = AppSettings.defaults.windowPreferences.sidebarDefaultVisible
            settings.windowPreferences.sidebarWidth = AppSettings.defaults.windowPreferences.sidebarWidth
            settings.windowPreferences.focusModeBehavior = AppSettings.defaults.windowPreferences.focusModeBehavior
            settings.editorPreferences.showAIReviewPanel = AppSettings.defaults.editorPreferences.showAIReviewPanel
        }) {
            SettingsRow(appState.localized("settings.theme"), highlightKey: "appearance.theme") {
                Picker("", selection: $settings.theme) {
                    ForEach(AppearanceTheme.allCases) { option in
                        Text(appState.displayName(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            SettingsRow(appState.localized("settings.accent")) {
                AccentPicker(selection: $settings.accentColor)
                    .frame(width: 190)
            }

            SettingsRow(appState.localized("settings.sidebarDefault")) {
                Toggle("", isOn: $settings.windowPreferences.sidebarDefaultVisible)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.sidebarWidth")) {
                HStack(spacing: 10) {
                    Stepper("\(Int(settings.windowPreferences.sidebarWidth)) pt", value: $settings.windowPreferences.sidebarWidth, in: 170...360, step: 5)
                    Button(appState.localized("settings.resetSidebar")) {
                        settings.windowPreferences.sidebarWidth = AppSettings.defaults.windowPreferences.sidebarWidth
                    }
                    .clickableCursor()
                }
            }

            SettingsRow(appState.localized("settings.aiPanel")) {
                Toggle("", isOn: $settings.editorPreferences.showAIReviewPanel)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.focusBehavior"), highlightKey: "appearance.focusBehavior") {
                Picker("", selection: $settings.windowPreferences.focusModeBehavior) {
                    ForEach(FocusModeBehavior.allCases) { Text(appState.displayName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }
    }

    private func themeTitle(_ option: AppearanceTheme) -> String {
        switch option {
        case .system: appState.localized("theme.system")
        case .light: appState.localized("theme.light")
        case .dark: appState.localized("theme.dark")
        }
    }
}

private struct EditorSettings: View {
    @Environment(AppState.self) private var appState
    @Binding var settings: AppSettings

    var body: some View {
        SettingsSection(title: appState.localized("settings.editor"), resetAction: {
            let defaults = AppSettings.defaults.editorPreferences
            settings.editorPreferences.wordsPerMinute = defaults.wordsPerMinute
            settings.editorPreferences.fontSize = defaults.fontSize
            settings.editorPreferences.spellcheck = defaults.spellcheck
            settings.editorPreferences.smartQuotes = defaults.smartQuotes
            settings.editorPreferences.showWordCount = defaults.showWordCount
            settings.editorPreferences.showSceneDuration = defaults.showSceneDuration
            settings.editorPreferences.defaultNotesVisibility = defaults.defaultNotesVisibility
            settings.generalPreferences.defaultSplitMode = AppSettings.defaults.generalPreferences.defaultSplitMode
            appState.rebuildProductionSegments()
        }) {
            SettingsRow(appState.localized("settings.wordsPerMinute")) {
                Stepper("\(settings.editorPreferences.wordsPerMinute)", value: $settings.editorPreferences.wordsPerMinute, in: 90...230)
            }

            SettingsRow(appState.localized("settings.fontSize"), highlightKey: "editor.fontSize") {
                ValueSlider(value: $settings.editorPreferences.fontSize, range: 16...30, suffix: " pt", precision: 0)
            }

            SettingsRow(appState.localized("settings.spellcheck")) {
                Toggle("", isOn: $settings.editorPreferences.spellcheck)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.smartQuotes"), help: appState.localized("help.smartQuotes")) {
                Toggle("", isOn: $settings.editorPreferences.smartQuotes)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.wordCount")) {
                Toggle("", isOn: $settings.editorPreferences.showWordCount)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.sceneDuration")) {
                Toggle("", isOn: $settings.editorPreferences.showSceneDuration)
                    .labelsHidden()
            }

            SettingsRow(appState.localized("settings.defaultSplit"), help: appState.localized("help.defaultSplit"), highlightKey: "editor.defaultSplit") {
                Picker("", selection: $settings.generalPreferences.defaultSplitMode) {
                    ForEach(SegmentType.allCases) { Text(appState.displayName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: settings.generalPreferences.defaultSplitMode) { _, _ in
                    appState.rebuildProductionSegments()
                }
            }

            SettingsRow(appState.localized("settings.defaultNotesVisibility")) {
                Picker("", selection: $settings.editorPreferences.defaultNotesVisibility) {
                    ForEach(NotesDefaultVisibility.allCases) { option in
                        Text(notesVisibilityTitle(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
        }
    }

    private func notesVisibilityTitle(_ option: NotesDefaultVisibility) -> String {
        switch option {
        case .collapsed: appState.localized("notes.collapsed")
        case .expanded: appState.localized("notes.expanded")
        }
    }
}

private struct TemplateSettings: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var selectedTemplateID: UUID?

    private var selectedTemplate: FrameTemplate? {
        appState.scriptTemplates().first { $0.id == selectedTemplateID } ?? appState.scriptTemplates().first
    }

    var body: some View {
        @Bindable var settingsStore = appState.settingsStore

        SettingsSection(title: appState.localized("settings.templates")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(appState.scriptTemplates()) { template in
                            Button {
                                selectedTemplateID = template.id
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(appState.displayName(template))
                                        .font(.system(size: 13, weight: selectedTemplate?.id == template.id ? .semibold : .regular))
                                        .lineLimit(1)
                                    Text(templateStatus(template))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(theme.tertiaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(selectedTemplate?.id == template.id ? theme.primaryText : theme.secondaryText)
                                .padding(.horizontal, 10)
                                .frame(height: 42)
                                .contentShape(Rectangle())
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selectedTemplate?.id == template.id ? theme.accentSoft.opacity(0.58) : Color.clear)
                                }
                            }
                            .buttonStyle(.cursorPlain)
                        }

                        Button {
                            appState.createCustomTemplate()
                            selectedTemplateID = appState.scriptTemplates().last?.id
                        } label: {
                            Label(appState.localized("templates.create"), systemImage: "plus")
                        }
                        .buttonStyle(.cursorPlain)
                        .padding(.top, 6)
                    }
                    .frame(width: 190, alignment: .topLeading)

                    Divider()
                        .overlay(theme.divider)

                    if let template = selectedTemplate {
                        TemplateDetailEditor(
                            template: template,
                            defaultTemplate: $settingsStore.settings.generalPreferences.defaultNewProjectTemplate
                        )
                        .id(template.id)
                    }
                }
            }
            .padding(14)
        }
        .onAppear {
            selectedTemplateID = selectedTemplateID ?? appState.scriptTemplates().first?.id
        }
    }

    private func templateStatus(_ template: FrameTemplate) -> String {
        if template.builtIn { return appState.localized("templates.builtIn") }
        if template.isCustomizedBuiltIn { return appState.localized("templates.customized") }
        return appState.localized("templates.custom")
    }
}

private struct TemplateDetailEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var draft: FrameTemplate
    @State private var savedDraft: FrameTemplate
    @State private var showsSavedFeedback = false
    @Binding var defaultTemplate: String

    init(template: FrameTemplate, defaultTemplate: Binding<String>) {
        _draft = State(initialValue: template)
        _savedDraft = State(initialValue: template)
        _defaultTemplate = defaultTemplate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if draft.builtIn {
                    Text(appState.displayName(draft))
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(appState.localized("templates.name"), text: $draft.name)
                        .textFieldStyle(QuietTextFieldStyle())
                }

                Text(templateStatus)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background { Capsule().fill(theme.hover) }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { templateActions }
                VStack(alignment: .leading, spacing: 8) { templateActions }
            }

            if !draft.builtIn {
                HStack(spacing: 8) {
                    Button(appState.localized("templates.save")) { saveDraft(showFeedback: true) }
                        .disabled(!hasUnsavedChanges)
                    Button(appState.localized("templates.done")) { saveDraft(showFeedback: false) }
                    if showsSavedFeedback {
                        Text(appState.localized("templates.saved")).font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                    }
                }
            }

            if draft.builtIn {
                Text(appState.localized("templates.readOnlyHint"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("templates.structure"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                if draft.structureDefinition.isEmpty {
                    Text(appState.localized("templates.blankStructure"))
                        .font(.system(size: 13))
                        .foregroundStyle(theme.tertiaryText)
                }

                ForEach(Array(draft.structureDefinition.enumerated()), id: \.offset) { index, _ in
                    HStack(spacing: 8) {
                        if draft.builtIn {
                            Text(appState.localizedTemplateSceneName(draft.structureDefinition[index]))
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                        } else {
                            TextField(appState.localized("templates.sceneName"), text: bindingForScene(at: index))
                                .textFieldStyle(QuietTextFieldStyle())

                            EditorIconButton(
                                systemName: "arrow.up",
                                accessibilityLabel: appState.localized("scene.moveUp"),
                                action: { moveScene(from: index, by: -1) }
                            )
                            .disabled(index == 0)

                            EditorIconButton(
                                systemName: "arrow.down",
                                accessibilityLabel: appState.localized("scene.moveDown"),
                                action: { moveScene(from: index, by: 1) }
                            )
                            .disabled(index == draft.structureDefinition.count - 1)

                            EditorIconButton(
                                systemName: "trash",
                                accessibilityLabel: appState.localized("scene.delete"),
                                role: .destructive,
                                action: { removeScene(at: index) }
                            )
                        }
                    }
                }

                Button {
                    addScene()
                } label: {
                    Label(appState.localized("templates.addScene"), systemImage: "plus")
                }
                .buttonStyle(.cursorPlain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onChange(of: draft.name) { oldValue, newValue in
            if defaultTemplate == oldValue {
                defaultTemplate = newValue
            }
        }
        .onDisappear { if hasUnsavedChanges { saveDraft(showFeedback: false) } }
    }

    @ViewBuilder
    private var templateActions: some View {
        if draft.builtIn {
            Button(appState.localized("templates.customize"), action: customize)
                .clickableCursor()
        }

        Button(appState.localized("templates.setDefault")) {
            defaultTemplate = draft.name
        }
        .disabled(defaultTemplate == draft.name)
        .clickableCursor(enabled: defaultTemplate != draft.name)

        Button(appState.localized("templates.duplicate")) {
            appState.duplicateTemplate(draft)
        }
        .clickableCursor()

        if draft.isCustomizedBuiltIn {
            Button(appState.localized("templates.restoreOriginal"), role: .destructive) {
                guard let restored = appState.restoreOriginalTemplate(draft) else { return }
                draft = restored
            }
            .clickableCursor()
        } else if !draft.builtIn {
            Button(appState.localized("templates.delete"), role: .destructive) {
                appState.deleteTemplate(draft)
            }
            .clickableCursor()
        }
    }

    private var templateStatus: String {
        if draft.builtIn { return appState.localized("templates.builtIn") }
        if draft.isCustomizedBuiltIn { return appState.localized("templates.customized") }
        return appState.localized("templates.custom")
    }

    private func customize() {
        guard let override = appState.customizeBuiltInTemplate(draft) else { return }
        draft = override
        savedDraft = override
    }

    private func addScene() {
        if draft.builtIn {
            customize()
            guard !draft.builtIn else { return }
        }
        draft.structureDefinition.append(appState.localized("templates.defaultScene"))
    }

    private func bindingForScene(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard draft.structureDefinition.indices.contains(index) else { return "" }
                return draft.structureDefinition[index]
            },
            set: { newValue in
                guard draft.structureDefinition.indices.contains(index) else { return }
                draft.structureDefinition[index] = newValue
            }
        )
    }

    private func moveScene(from index: Int, by delta: Int) {
        let nextIndex = index + delta
        guard draft.structureDefinition.indices.contains(index),
              draft.structureDefinition.indices.contains(nextIndex) else { return }
        draft.structureDefinition.swapAt(index, nextIndex)
    }

    private func removeScene(at index: Int) {
        guard draft.structureDefinition.indices.contains(index) else { return }
        draft.structureDefinition.remove(at: index)
    }

    private var hasUnsavedChanges: Bool { draft != savedDraft }

    private func saveDraft(showFeedback: Bool = false) {
        guard !draft.builtIn else { return }
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? appState.localized("templates.untitled")
            : draft.name
        appState.updateTemplate(draft)
        savedDraft = draft
        showsSavedFeedback = showFeedback
        if showFeedback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { showsSavedFeedback = false }
        }
    }
}

private struct AISettings: View {
    @Environment(AppState.self) private var appState
    @Binding var settings: AppSettings
    @State private var apiKey = ""
    @State private var hasStoredKey = false
    @State private var status = ""
    @State private var isTesting = false
    private let configurationStore = AIProviderConfigurationStore()

    private var providerDisabled: Bool {
        settings.aiPreferences.provider == .disabled
    }

    private var providerUsesSubscription: Bool {
        settings.aiPreferences.provider.isSubscriptionBacked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: appState.localized("settings.ai"), resetAction: {
                settings.aiPreferences = AppSettings.defaults.aiPreferences
                SubscriptionAISettingsStore.shared.reset()
                apiKey = ""
                status = ""
                loadKeyMetadata()
            }) {
                SettingsRow(appState.localized("settings.provider"), help: appState.localized("help.provider")) {
                    Picker("", selection: $settings.aiPreferences.provider) {
                        ForEach(AIProviderKind.allCases) { provider in
                            Text(appState.displayName(provider)).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                SettingsRow(appState.localized("settings.model"), help: appState.localized("help.model")) {
                    TextField("", text: $settings.aiPreferences.model)
                        .textFieldStyle(QuietTextFieldStyle())
                        .frame(width: 260)
                        .disabled(providerDisabled || providerUsesSubscription)
                }

                SettingsRow(appState.localized("settings.baseURL"), help: appState.localized("help.baseURL")) {
                    TextField(defaultBaseURL(for: settings.aiPreferences.provider), text: $settings.aiPreferences.baseURL)
                        .textFieldStyle(QuietTextFieldStyle())
                        .frame(width: 300)
                        .disabled(providerDisabled || providerUsesSubscription)
                }

                if providerUsesSubscription {
                    SettingsRow(appState.localized("settings.apiKey"), help: appState.localized("help.apiKey")) {
                        Text(appState.localized("settings.ai.subscription.usesCLI"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 360, alignment: .trailing)
                    }
                } else {
                    SettingsRow(appState.localized("settings.apiKey"), help: appState.localized("help.apiKey")) {
                        VStack(alignment: .trailing, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField(hasStoredKey ? appState.localized("settings.keyStored") : appState.localized("settings.keyMissing"), text: $apiKey)
                                    .textFieldStyle(QuietTextFieldStyle())
                                    .frame(width: 240)
                                    .disabled(providerDisabled)
                                Button(hasStoredKey ? appState.localized("settings.replaceKey") : appState.localized("settings.saveKey")) {
                                    saveAPIKeyFromField()
                                }
                                .disabled(providerDisabled || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .clickableCursor(enabled: !providerDisabled && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button(appState.localized("settings.deleteKey")) {
                                    deleteAPIKey()
                                }
                                .disabled(providerDisabled || !hasStoredKey)
                                .clickableCursor(enabled: !providerDisabled && hasStoredKey)
                            }

                            Text(providerDisabled ? appState.localized("settings.notNeeded") : keyStatusText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsRow("") {
                    HStack(spacing: 10) {
                        Button(appState.localized("settings.testConnection")) {
                            Task {
                                if providerUsesSubscription {
                                    await testSubscriptionConnection()
                                } else {
                                    await testConnection()
                                }
                            }
                        }
                        .disabled(providerDisabled || isTesting)
                        .clickableCursor(enabled: !providerDisabled && !isTesting)

                        if !status.isEmpty {
                            Text(status)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsRow(appState.localized("settings.privacyMode"), help: appState.localized("help.privacyMode"), highlightKey: "ai.privacyMode") {
                    Toggle("", isOn: $settings.aiPreferences.privacyMode)
                        .labelsHidden()
                        .disabled(providerDisabled)
                }
                SettingsRow(appState.localized("settings.inlineAutocomplete")) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Toggle("", isOn: $settings.aiPreferences.enableInlineAutocomplete)
                            .labelsHidden()
                            .disabled(providerUsesSubscription)
                        if providerUsesSubscription {
                            Text(appState.localized("settings.ai.subscription.autocompleteNote"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: 320, alignment: .trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            SubscriptionAISettingsView()
        }
        .task { loadKeyMetadata() }
        .onChange(of: settings.aiPreferences.provider) { oldProvider, newProvider in
            saveProviderConfiguration(oldProvider)
            appState.autocompleteProviderDidChange(from: oldProvider, to: newProvider)
            if let kind = newProvider.agentCLIKind {
                SubscriptionAISettingsStore.shared.settings.setDefaultKind(kind)
            }
            apiKey = ""
            status = ""
            loadKeyMetadata()
            loadProviderConfiguration(newProvider)
        }
        .onChange(of: settings.aiPreferences.model) { _, _ in
            saveProviderConfiguration(settings.aiPreferences.provider)
            appState.autocompleteProviderConfigurationDidChange(for: settings.aiPreferences.provider)
        }
        .onChange(of: settings.aiPreferences.baseURL) { _, _ in
            saveProviderConfiguration(settings.aiPreferences.provider)
            appState.autocompleteProviderConfigurationDidChange(for: settings.aiPreferences.provider)
        }
        .onChange(of: settings.aiPreferences.enableInlineAutocomplete) { _, _ in
            appState.inlineAutocompletePreferenceDidChange()
        }
    }

    private func testSubscriptionConnection() async {
        isTesting = true
        status = appState.localized("settings.ai.subscription.testing")
        defer { isTesting = false }
        let result = await SubscriptionAIRuntime.shared.probe()
        switch result {
        case let .reply(text):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK") {
                status = appState.localized("settings.ai.subscription.probeSuccess")
            } else {
                status = String(
                    format: appState.localized("settings.ai.subscription.probeReply"),
                    String(text.prefix(200))
                )
            }
        case .pending:
            status = appState.localized("settings.ai.subscription.probePending")
        case let .failure(message):
            status = String(
                format: appState.localized("settings.ai.subscription.probeFailure"),
                message
            )
        }
    }

    private var keyStatusText: String {
        hasStoredKey ? appState.localized("settings.keyStored") : appState.localized("settings.keyNotStored")
    }

    private func accountName() -> String {
        settings.aiPreferences.provider.keychainAccount
    }

    private func loadKeyMetadata() {
        hasStoredKey = configurationStore.hasStoredKey(for: settings.aiPreferences.provider)
    }

    private func saveAPIKey(_ value: String) throws {
        let provider = settings.aiPreferences.provider
        try KeychainStore.saveAPIKey(value, account: accountName())
        appState.invalidateProviderAPIKey(for: provider)
        apiKey = ""
        hasStoredKey = true
        configurationStore.setHasStoredKey(true, for: settings.aiPreferences.provider)
        status = appState.localized("settings.keySaved")
        appState.errorCenter.showNotice(AppNotice(kind: .apiKeySaved))
    }

    private func saveAPIKeyFromField() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try saveAPIKey(trimmedKey)
        } catch {
            status = ""
            appState.errorCenter.present(AppError.keychain(error, operation: .write))
        }
    }

    private func deleteAPIKey() {
        let provider = settings.aiPreferences.provider
        do {
            try KeychainStore.deleteAPIKey(account: accountName())
            appState.invalidateProviderAPIKey(for: provider)
            apiKey = ""
            hasStoredKey = false
            configurationStore.setHasStoredKey(false, for: settings.aiPreferences.provider)
            status = appState.localized("settings.keyNotStored")
            appState.errorCenter.showNotice(AppNotice(kind: .apiKeyDeleted))
        } catch {
            appState.errorCenter.present(AppError.keychain(error, operation: .delete))
        }
    }

    private func testConnection() async {
        guard !providerDisabled else {
            status = appState.localized("settings.aiDisabled")
            return
        }
        guard hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = appState.localized("settings.keyMissing")
            return
        }
        isTesting = true
        status = appState.localized("settings.testing")
        defer { isTesting = false }

        let pendingAPIKey = apiKey
        let request = LLMRequest(
            task: .autocomplete,
            provider: settings.aiPreferences.provider,
            baseURL: settings.aiPreferences.baseURL,
            systemPrompt: "Reply with OK.",
            userPrompt: "OK",
            model: settings.aiPreferences.model,
            temperature: 0,
            maxTokens: 128
        )
        do {
            try await AIConnectionTester.saveKeyAndTest(
                pendingAPIKey: pendingAPIKey,
                saveKey: { value in try saveAPIKey(value) },
                acquireKey: { try appState.providerAPIKey(for: settings.aiPreferences.provider) },
                request: request,
                test: { request, savedKey in
                    try await OpenAICompatibleLLMProvider().testConnection(request: request, apiKey: savedKey)
                }
            )
            status = appState.localized("settings.success")
        } catch let error as KeychainError {
            status = ""
            let operation: KeychainOperation = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .read : .write
            appState.errorCenter.present(AppError.keychain(error, operation: operation))
            return
        } catch {
            status = ""
            appState.errorCenter.present(AppError.ai(error))
        }
    }

    private func defaultBaseURL(for provider: AIProviderKind) -> String {
        provider == .disabled ? "" : OpenAICompatibleLLMProvider.defaultBaseURL(for: provider)
    }

    private func saveProviderConfiguration(_ provider: AIProviderKind) {
        guard provider != .disabled else { return }
        configurationStore.save(
            AIProviderConfiguration(model: settings.aiPreferences.model, baseURL: settings.aiPreferences.baseURL),
            for: provider
        )
    }

    private func loadProviderConfiguration(_ provider: AIProviderKind) {
        let configuration = configurationStore.load(for: provider)
        settings.aiPreferences.model = configuration.model
        settings.aiPreferences.baseURL = configuration.baseURL
    }
}

private struct ExportSettings: View {
    @Environment(AppState.self) private var appState
    @Binding var settings: AppSettings

    var body: some View {
        SettingsSection(title: appState.localized("settings.export"), resetAction: {
            settings.exportPreferences = AppSettings.defaults.exportPreferences
        }) {
            SettingsRow(appState.localized("settings.defaultFormat"), highlightKey: "export.defaultFormat") {
                Picker("", selection: $settings.exportPreferences.defaultFormat) {
                    ForEach(ExportFormat.allCases) { Text(appState.displayName($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            SettingsRow(appState.localized("settings.timestamps"), help: appState.localized("help.timestamps")) {
                Toggle("", isOn: $settings.exportPreferences.includeTimestamps).labelsHidden()
            }
            SettingsRow(appState.localized("settings.sectionNames")) {
                Toggle("", isOn: $settings.exportPreferences.includeSectionNames).labelsHidden()
            }
            SettingsRow(appState.localized("settings.includeBRoll")) {
                Toggle("", isOn: $settings.exportPreferences.includeBRoll).labelsHidden()
            }
            SettingsRow(appState.localized("settings.includeEditing")) {
                Toggle("", isOn: $settings.exportPreferences.includeEditingNotes).labelsHidden()
            }
            SettingsRow(appState.localized("settings.includeAI")) {
                Toggle("", isOn: $settings.exportPreferences.includeAINotes).labelsHidden()
            }
            SettingsRow(appState.localized("settings.teleprompter"), help: appState.localized("help.teleprompter")) {
                Toggle("", isOn: $settings.exportPreferences.teleprompterFormatting).labelsHidden()
            }
            SettingsRow(appState.localized("settings.exportFolder"), help: appState.localized("help.exportFolder")) {
                HStack(spacing: 8) {
                    Text(settings.exportPreferences.defaultExportFolder.isEmpty ? appState.localized("settings.noExportFolder") : settings.exportPreferences.defaultExportFolder)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 260, alignment: .trailing)

                    Button(appState.localized("settings.chooseFolder")) {
                        appState.chooseDefaultExportFolder()
                    }
                    .clickableCursor()

                    Button(appState.localized("settings.clearFolder")) {
                        appState.clearDefaultExportFolder()
                    }
                    .disabled(settings.exportPreferences.defaultExportFolder.isEmpty)
                    .clickableCursor(enabled: !settings.exportPreferences.defaultExportFolder.isEmpty)
                }
            }
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppState.self) private var appState
    let resetAction: () -> Void
    let clearRecentsAction: () -> Void

    var body: some View {
        SettingsSection(title: appState.localized("settings.advanced")) {
            SettingsRow(appState.localized("settings.reset")) {
                Button(appState.localized("settings.reset"), action: resetAction)
                    .clickableCursor()
            }
            SettingsRow(appState.localized("settings.clearRecents")) {
                Button(appState.localized("settings.clearRecents"), action: clearRecentsAction)
                    .clickableCursor()
            }
            SettingsRow(appState.localized("settings.clearKeys")) {
                Button(appState.localized("settings.clearKeys"), action: appState.clearAPIKeysWithConfirmation)
                .clickableCursor()
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let title: String
    var resetHelp: String?
    var resetTitle: String?
    var resetAction: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var showsResetFeedback = false

    init(title: String, resetHelp: String? = nil, resetTitle: String? = nil, resetAction: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.resetHelp = resetHelp
        self.resetTitle = resetTitle
        self.resetAction = resetAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                if let resetAction {
                    if showsResetFeedback {
                        Text(appState.localized("settings.resetDone"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.success)
                            .transition(.opacity)
                    }
                    if let resetHelp {
                        SettingsInfoButton(text: resetHelp)
                    }
                    Button(resetTitle ?? appState.localized("settings.resetSection")) {
                        resetAction()
                        withAnimation(.easeOut(duration: 0.15)) {
                            showsResetFeedback = true
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_300_000_000)
                            withAnimation(.easeOut(duration: 0.2)) {
                                showsResetFeedback = false
                            }
                        }
                    }
                        .font(.system(size: 12))
                        .buttonStyle(.borderless)
                        .clickableCursor()
                }
            }

            SettingsCard {
                content
            }
        }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}

struct SettingsRow<Content: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let title: String
    let help: String?
    let highlightKey: String?
    let isHighlighted: Bool
    @ViewBuilder var content: Content

    init(_ title: String, help: String? = nil, highlightKey: String? = nil, isHighlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.highlightKey = highlightKey
        self.isHighlighted = isHighlighted
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(axis: .horizontal)
            row(axis: .vertical)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            if isHighlighted || (highlightKey != nil && appState.windowState.requestedSettingsHighlightKey == highlightKey) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.accentSoft.opacity(0.72))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
            }
        }
        .id(highlightKey ?? "settings-row-\(title)")
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }

    @ViewBuilder
    private func row(axis: Axis) -> some View {
        if axis == .horizontal {
            HStack(alignment: .center, spacing: 16) {
                label
                    .frame(width: 250, alignment: .leading)

                content
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                label
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let help {
                SettingsInfoButton(text: help)
            }
        }
    }
}

struct SettingsInfoButton: View {
    @Environment(\.frameTheme) private var theme
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.cursorPlain)
        .help(text)
        .accessibilityLabel(text)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
                .padding(12)
                .frame(width: 240, alignment: .leading)
                .background(theme.cardBackground)
        }
    }
}

private struct ValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    let precision: Int

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: range)
                .frame(width: 180)
            Text(formattedValue)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var formattedValue: String {
        "\(String(format: "%.\(precision)f", value))\(suffix)"
    }
}

struct AccentPicker: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: AccentPalette

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(AccentPalette.allCases) { accent in
                HStack {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 10, height: 10)
                    Text(appState.displayName(accent))
                }
                .tag(accent)
            }
        }
        .labelsHidden()
    }
}
