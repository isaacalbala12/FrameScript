import SwiftUI
import UniformTypeIdentifiers

struct AppRootView: View {
    @Environment(AppState.self) private var appState
    @State private var subscriptionRuntime = SubscriptionAIRuntime.shared

    var body: some View {
        @Bindable var windowState = appState.windowState
        // Read the observable property in the body so a pending question
        // invalidates this view and presents the sheet.
        let pendingPrompt = subscriptionRuntime.pendingPrompt
        let presentedError = Binding<AppError?>(
            get: { appState.errorCenter.presentedError },
            set: { if $0 == nil { appState.errorCenter.dismissCurrent() } }
        )
        Group {
            if appState.hasOpenProject {
                AppShellView()
            } else {
                WelcomeView()
            }
        }
            .overlay(alignment: .bottom) {
                if let notice = appState.errorCenter.notice {
                    Text(notice.message(language: appState.currentLanguage))
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: appState.errorCenter.notice)
            .task {
                appState.configure()
            }
            .alert(item: presentedError) { error in
                let presentation = error.presentation(language: appState.currentLanguage)
                let message = [presentation.message, presentation.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                if let action = error.recoveryAction {
                    return Alert(
                        title: Text(presentation.title),
                        message: Text(message),
                        primaryButton: .default(Text(appState.localized("recovery.\(action.localizationKey).button"))) {
                            appState.performRecovery(action)
                        },
                        secondaryButton: .cancel(Text(appState.localized("error.dismiss")))
                    )
                }
                return Alert(
                    title: Text(presentation.title),
                    message: Text(message),
                    dismissButton: .default(Text(appState.localized("error.dismiss")))
                )
            }
            .sheet(item: $windowState.newProjectRequest) { request in
                Group {
                    if request.showsTemplateBrowser {
                        TemplatePickerView()
                    } else {
                        NewProjectSheet(request: request)
                    }
                }
                .environment(appState)
                .environment(\.frameTheme, appState.themeManager.frameTheme)
            }
            .sheet(isPresented: $windowState.isExportPresented) {
                ExportSheetView()
                    .environment(appState)
                    .environment(\.frameTheme, appState.themeManager.frameTheme)
            }
            .overlay(alignment: .topTrailing) {
                SubscriptionAIActivityOverlay()
            }
            .sheet(item: Binding(
                get: { pendingPrompt },
                set: { newValue in
                    subscriptionRuntime.pendingPrompt = newValue
                    if newValue == nil {
                        subscriptionRuntime.clearOpenError()
                    }
                }
            )) { prompt in
                SubscriptionAIPendingQuestionSheet(prompt: prompt)
                    .environment(appState)
                    .environment(\.frameTheme, appState.themeManager.frameTheme)
            }
            .background(ProjectWindowReader { appState.setProjectWindow($0) })
    }
}

struct AppShellView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @State private var sidebarDragStartWidth: Double?
    @State private var editorSessionID = UUID()

    var body: some View {
        @Bindable var windowState = appState.windowState
        @Bindable var settingsStore = appState.settingsStore
        let sidebarWidth = settingsStore.settings.windowPreferences.sidebarWidth
        let hidesSidebarForFocus = appState.isFocusModeEnabled
            && appState.settings.windowPreferences.focusModeBehavior == .hidePanels

        VStack(spacing: 0) {
            TopToolbar()

            HStack(spacing: 0) {
                if appState.isSidebarVisible && !hidesSidebarForFocus {
                    SceneSidebar()
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    SidebarResizeHandle(width: $settingsStore.settings.windowPreferences.sidebarWidth, dragStartWidth: $sidebarDragStartWidth)
                }

                HStack(spacing: 0) {
                    editorContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if appState.settings.editorPreferences.showAIReviewPanel && !appState.isFocusModeEnabled {
                        Divider()
                            .overlay(theme.divider)

                        AIReviewPanel()
                            .frame(width: 292)
                    }
                }
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .background(theme.background)
        .foregroundStyle(theme.primaryText)
        .frame(minWidth: 980, minHeight: 680)
        .sheet(isPresented: $windowState.isCommandPalettePresented, onDismiss: performPendingPaletteAction) {
            CommandPaletteView()
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .sheet(isPresented: $windowState.isShortcutsPresented) {
            ShortcutsOverlay()
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .onDisappear {
            appState.flushActiveEditorBoundary()
        }
    }

    private func performPendingPaletteAction() {
        guard let tab = appState.windowState.pendingSettingsTab else { return }
        let key = appState.windowState.pendingSettingsHighlightKey
        appState.windowState.pendingSettingsTab = nil
        appState.windowState.pendingSettingsHighlightKey = nil
        appState.openSettings(tab: tab, highlightKey: key)
        openSettings()
    }

    @ViewBuilder
    private var editorContent: some View {
        if let scene = appState.selectedScene {
            switch appState.selectedMode {
            case .script:
                ScriptEditorView(scene: scene, editorSessionID: editorSessionID)
            case .bRoll:
                BRollEditorView(scene: scene)
            case .editing:
                EditingEditorView(scene: scene)
            }
        } else {
            EmptyProjectView()
        }
    }
}

private struct SidebarResizeHandle: View {
    @Environment(\.frameTheme) private var theme
    @Binding var width: Double
    @Binding var dragStartWidth: Double?

    var body: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: 1)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartWidth ?? width
                                dragStartWidth = start
                                width = min(360, max(170, start + value.translation.width))
                            }
                            .onEnded { _ in
                                dragStartWidth = nil
                            }
                    )
            }
            .cursor(.resizeLeftRight)
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var isTemplatePickerPresented = false
    @FocusState private var focusedRecentID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(appState.localized("app.name"))
                        .font(.system(size: 34, weight: .semibold))
                    Text(appState.localized("welcome.subtitle"))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    WelcomeAction(title: appState.localized("welcome.newBlankProject"), systemImage: "plus", accessibilityIdentifier: "welcome-new-blank-project", action: {
                        appState.requestNewProject(template: appState.scriptTemplates().first { $0.isBlank }, locksTemplate: true)
                    })
                    WelcomeAction(title: appState.localized("welcome.newFromTemplate"), systemImage: "doc.badge.plus", accessibilityIdentifier: "welcome-new-from-template", action: {
                        isTemplatePickerPresented = true
                    })
                    WelcomeAction(title: appState.localized("welcome.openProject"), systemImage: "folder", accessibilityIdentifier: "welcome-open-project", action: appState.openProject)
                    WelcomeAction(title: appState.localized("welcome.openDemo"), systemImage: "play.rectangle", accessibilityIdentifier: "welcome-open-demo", action: appState.openDemoProject)
                }
                .frame(width: 260)

                Spacer()
            }
            .padding(52)
            .frame(width: 420, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(theme.sidebarBackground)

            VStack(alignment: .leading, spacing: 18) {
                Text(appState.localized("welcome.recent"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                if appState.recentProjectEntries.isEmpty {
                    Text(appState.localized("welcome.noRecent"))
                        .font(.system(size: 14))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: 420, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(appState.recentProjectEntries) { entry in
                                RecentProjectRow(entry: entry, focusedRecentID: $focusedRecentID)
                            }
                        }
                    }
                    .onDeleteCommand {
                        guard let focusedRecentID else { return }
                        appState.removeRecentProject(id: focusedRecentID)
                    }
                }

                Spacer()
            }
            .padding(52)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.appBackground)
        }
        .foregroundStyle(theme.primaryText)
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $isTemplatePickerPresented) {
            TemplatePickerView()
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .task {
            await appState.recentProjectStore.validateEntries()
        }
    }
}

private struct RecentProjectRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let entry: RecentProjectEntry
    @FocusState.Binding var focusedRecentID: UUID?
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                focusedRecentID = entry.id
                appState.openRecentProject(entry)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(theme.accent.color)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                        Text(appState.compactParentFolder(for: entry))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.cursorPlain)
            .focusable()
            .focused($focusedRecentID, equals: entry.id)
            .accessibilityLabel(entry.displayName)
            .accessibilityIdentifier("recent-row-\(entry.displayName)")
            .accessibilityAction(named: Text(appState.localized("recent.remove"))) {
                appState.removeRecentProject(entry)
            }

            Button {
                appState.removeRecentProject(entry)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.cursorPlain)
            .focusable(false)
            .foregroundStyle(theme.secondaryText)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .help(appState.localized("recent.remove"))
            .accessibilityLabel(appState.localized("recent.remove"))
            .accessibilityIdentifier("recent-remove-\(entry.displayName)")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.hover)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(appState.localized("recent.open")) {
                appState.openRecentProject(entry)
            }
            Button(appState.localized("project.reveal")) {
                appState.revealRecentProjectInFinder(entry)
            }
            .disabled(!appState.canRevealRecentProject(entry))
            Divider()
            Button(appState.localized("recent.remove")) {
                appState.removeRecentProject(entry)
            }
        }
    }
}

private struct WelcomeAction: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .clickableCursor()
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct TemplatePickerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplateID: UUID?
    @State private var projectName = ""
    @FocusState private var isNameFocused: Bool

    private var templates: [FrameTemplate] {
        appState.scriptTemplates()
    }

    private var selectedTemplate: FrameTemplate? {
        templates.first { $0.id == selectedTemplateID } ?? templates.first
    }

    private var defaultTemplateID: UUID? {
        templates.first { $0.name == appState.settings.generalPreferences.defaultNewProjectTemplate }?.id ?? templates.first?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(appState.localized("templates.newFromTemplate"))
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(templates) { template in
                            Button {
                                selectedTemplateID = template.id
                            } label: {
                                HStack {
                                    Text(appState.displayName(template))
                                        .font(.system(size: 13, weight: selectedTemplate?.id == template.id ? .semibold : .regular))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                                .foregroundStyle(selectedTemplate?.id == template.id ? theme.primaryText : theme.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selectedTemplate?.id == template.id ? theme.accentSoft.opacity(0.62) : Color.clear)
                                }
                            }
                            .buttonStyle(.cursorPlain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button(appState.localized("templates.manage")) {
                    appState.openSettings(tab: .templates)
                    dismiss()
                    Task { @MainActor in
                        await Task.yield()
                        openSettings()
                    }
                }
                .buttonStyle(.cursorPlain)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(width: 260)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(theme.panelBackground)

            Divider()
                .overlay(theme.divider)

            VStack(alignment: .leading, spacing: 0) {
                if let selectedTemplate {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(appState.displayName(selectedTemplate))
                                .font(.system(size: 24, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            QuietField(appState.localized("newProject.name")) {
                                TextField(appState.localized("project.untitled"), text: $projectName)
                                    .textFieldStyle(QuietTextFieldStyle())
                                    .focused($isNameFocused)
                                    .onSubmit(createProject)
                            }

                            Text(appState.localized("templates.structure"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.secondaryText)

                            if selectedTemplate.structureDefinition.isEmpty {
                                Text(appState.localized("templates.blankStructure"))
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.secondaryText)
                            } else {
                                ForEach(Array(selectedTemplate.structureDefinition.enumerated()), id: \.offset) { index, sceneName in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(String(format: "%02d", index + 1))
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(theme.tertiaryText)
                                            .frame(width: 28, alignment: .leading)
                                        Text(selectedTemplate.builtIn ? appState.localizedTemplateSceneName(sceneName) : sceneName)
                                            .font(.system(size: 14))
                                            .foregroundStyle(theme.primaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 5)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .overlay(theme.divider)

                    HStack {
                        Button(appState.localized("project.unsaved.cancel")) {
                            dismiss()
                        }
                        .keyboardShortcut(.cancelAction)
                        .clickableCursor()

                        Spacer()

                        Button(appState.localized("templates.createProject"), action: createProject)
                        .keyboardShortcut(.defaultAction)
                        .clickableCursor()
                    }
                    .padding(.horizontal, 24)
                    .frame(height: 64)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.windowBackground)
        }
        .foregroundStyle(theme.primaryText)
        .frame(width: 800, height: 560)
        .background(theme.windowBackground)
        .onAppear {
            selectedTemplateID = selectedTemplateID ?? defaultTemplateID
            projectName = projectName.isEmpty ? appState.localized("project.untitled") : projectName
            Task { @MainActor in
                isNameFocused = true
            }
        }
    }

    private var resolvedProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appState.localized("project.untitled") : trimmed
    }

    private func createProject() {
        guard let selectedTemplate else { return }
        appState.createNewProject(named: resolvedProjectName, template: selectedTemplate)
        dismiss()
    }
}

private struct NewProjectSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let request: NewProjectRequest
    @State private var projectName = ""
    @State private var selectedTemplateID: UUID?
    @FocusState private var isNameFocused: Bool

    private var templates: [FrameTemplate] {
        appState.scriptTemplates()
    }

    private var selectedTemplate: FrameTemplate? {
        templates.first { $0.id == selectedTemplateID } ?? templates.first
    }

    private var isLockedBlankProject: Bool {
        request.locksTemplate && selectedTemplate?.isBlank == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(appState.localized(isLockedBlankProject ? "newProject.blankTitle" : "newProject.title"))
                .font(.system(size: 20, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            if isLockedBlankProject {
                Text(appState.localized("newProject.blankDescription"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            QuietField(appState.localized("newProject.name")) {
                TextField(appState.localized("project.untitled"), text: $projectName)
                    .textFieldStyle(QuietTextFieldStyle())
                    .focused($isNameFocused)
                    .onSubmit(createProject)
            }

            if !isLockedBlankProject {
                QuietField(appState.localized("newProject.template")) {
                    Picker("", selection: $selectedTemplateID) {
                        ForEach(templates) { template in
                            Text(appState.displayName(template)).tag(Optional(template.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(request.locksTemplate)
                }

                if let selectedTemplate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.localized("templates.structure"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryText)

                        if selectedTemplate.structureDefinition.isEmpty {
                            Text(appState.localized("templates.blankStructure"))
                                .font(.system(size: 13))
                                .foregroundStyle(theme.secondaryText)
                        } else {
                            ForEach(Array(selectedTemplate.structureDefinition.prefix(6).enumerated()), id: \.offset) { index, sceneName in
                                Text("\(index + 1). \(selectedTemplate.builtIn ? appState.localizedTemplateSceneName(sceneName) : sceneName)")
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

            HStack {
                Button(appState.localized("project.unsaved.cancel")) {
                    appState.windowState.newProjectRequest = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .clickableCursor()

                Spacer()

                Button(appState.localized("newProject.create"), action: createProject)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTemplate == nil)
                .clickableCursor()
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            selectedTemplateID = request.templateID ?? templates.first?.id
            projectName = appState.localized("project.untitled")
            Task { @MainActor in
                isNameFocused = true
            }
        }
    }

    private var resolvedProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appState.localized("project.untitled") : trimmed
    }

    private func createProject() {
        guard let selectedTemplate else { return }
        appState.createNewProject(named: resolvedProjectName, template: selectedTemplate)
        dismiss()
    }
}

private struct ExportSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: ExportPreferences
    @State private var format: ExportFormat

    init() {
        let defaults = AppSettings.defaults.exportPreferences
        _preferences = State(initialValue: defaults)
        _format = State(initialValue: defaults.defaultFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appState.localized("export.title"))
                .font(.system(size: 20, weight: .semibold))

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(appState.localized("settings.defaultFormat"), selection: $format) {
                        ForEach(ExportFormat.allCases) { option in
                            Text(appState.displayName(option)).tag(option)
                        }
                    }
                    .frame(width: 260)

                    Toggle(appState.localized("settings.timestamps"), isOn: $preferences.includeTimestamps)
                    Toggle(appState.localized("settings.sectionNames"), isOn: $preferences.includeSectionNames)
                    Toggle(appState.localized("settings.includeBRoll"), isOn: $preferences.includeBRoll)
                    Toggle(appState.localized("settings.includeEditing"), isOn: $preferences.includeEditingNotes)
                    Toggle(appState.localized("settings.includeAI"), isOn: $preferences.includeAINotes)
                    Toggle(appState.localized("settings.teleprompter"), isOn: $preferences.teleprompterFormatting)
                }
                .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.localized("export.preview"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)

                    ScrollView {
                        Text(previewText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                    .frame(width: 430, height: 300)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.editorSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(theme.divider, lineWidth: 1)
                            )
                    }
                }
            }

            HStack {
                Button(appState.localized("project.unsaved.cancel")) {
                    appState.windowState.isExportPresented = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .clickableCursor()

                Spacer()

                Button(appState.localized("export.copy")) {
                    appState.copyExportToClipboard(format: format, preferences: effectivePreferences)
                }
                .clickableCursor()

                Button(appState.localized("export.saveFile")) {
                    saveFile()
                }
                .keyboardShortcut(.defaultAction)
                .clickableCursor()
            }
        }
        .padding(24)
        .frame(width: 760)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            preferences = appState.settings.exportPreferences
            format = appState.settings.exportPreferences.defaultFormat
        }
    }

    private var effectivePreferences: ExportPreferences {
        var copy = preferences
        copy.defaultFormat = format
        return copy
    }

    private var previewText: String {
        appState.dependencies.exportService.render(project: appState.project, format: format, preferences: effectivePreferences, language: appState.currentLanguage)
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(appState.project.title).\(format.fileExtension)"
        panel.message = appState.localized("dialog.exportProject.message")
        if let folder = appState.resolvedDefaultExportFolder() {
            let didStartAccessing = folder.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.saveExport(format: format, preferences: effectivePreferences, to: url)
        appState.windowState.isExportPresented = false
        dismiss()
    }
}

private struct EmptyProjectView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Text(appState.localized("scene.emptyTitle"))
                .font(.system(size: 24, weight: .medium))
            Text(appState.localized("scene.emptyMessage"))
                .font(.system(size: 14))
                .foregroundStyle(theme.secondaryText)
            Button(appState.localized("scene.add")) {
                appState.addScene()
            }
            .buttonStyle(.cursorPlain)
            .keyboardShortcut(.defaultAction)
            .clickableCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
