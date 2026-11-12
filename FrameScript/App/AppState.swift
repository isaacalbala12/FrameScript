import Foundation
import AppKit
import Observation
import OSLog
import SwiftUI

private struct GeneratedBRollSuggestion: Decodable {
    let source: String
    let description: String
    let notes: String
}

private struct GeneratedEditingSuggestion: Decodable {
    let description: String
    let notes: String
}

enum GenerationError: LocalizedError {
    case invalidJSON
    case emptyDescription

    var errorDescription: String? {
        switch self {
        case .invalidJSON: "The provider did not return valid structured JSON."
        case .emptyDescription: "The provider returned an empty description."
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable, Codable, Hashable {
    case general
    case appearance
    case editor
    case templates
    case ai
    case export
    case keyboardShortcuts
    case advanced

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "switch.2"
        case .appearance: "paintpalette"
        case .editor: "text.alignleft"
        case .templates: "doc.on.doc"
        case .ai: "sparkles"
        case .export: "square.and.arrow.up"
        case .keyboardShortcuts: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    @MainActor
    func title(appState: AppState) -> String {
        switch self {
        case .general: appState.localized("settings.general")
        case .appearance: appState.localized("settings.appearance")
        case .editor: appState.localized("settings.editor")
        case .templates: appState.localized("settings.templates")
        case .ai: appState.localized("settings.ai")
        case .export: appState.localized("settings.export")
        case .keyboardShortcuts: appState.localized("settings.keyboardShortcuts")
        case .advanced: appState.localized("settings.advanced")
        }
    }
}

struct NewProjectRequest: Identifiable, Equatable {
    let id = UUID()
    var templateID: UUID?
    var locksTemplate: Bool
    var showsTemplateBrowser = false
}

/// What the user chose when the project file changed outside FrameScript.
enum ExternalProjectChangeResolution {
    case reload
    case keepMine
    case saveCopy
    case cancel
}

/// Result of the pre-write check. `.handled` means the conflict workflow
/// already reloaded or wrote the file, so the caller must not write again.
enum ProjectFileWriteAuthorization {
    case proceed
    case handled
    case failed
}

@MainActor
@Observable
final class AppState {
    static let projectFilesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "ProjectFiles")
    private static let exportLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Export")
#if DEBUG
    private static let autocompleteLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Autocomplete")
#endif
    typealias ExportFolderBookmarkCreator = @MainActor @Sendable (URL) throws -> Data
    typealias ExportFolderBookmarkResolver = @MainActor @Sendable (Data, inout Bool) throws -> URL
    typealias CloseConfirmation = @MainActor () -> CloseConfirmationResult
    typealias ExternalProjectChangeConfirmation = @MainActor () -> ExternalProjectChangeResolution

    enum CloseConfirmationResult {
        case save, discard, cancel
    }

    let projectStore: ProjectStore
    let recentProjectStore: RecentProjectStore
    let editorState: EditorState
    let settingsStore: SettingsStore
    let aiState: AIState
    let windowState: WindowState
    let errorCenter: ErrorCenter
    let themeManager: ResolvedThemeManager
    let dependencies: AppDependencies
    private let aiProviderConfigurationStore: AIProviderConfigurationStore
    let securityScope: SecurityScopedResourceAccess
    private let exportFolderBookmarkCreator: ExportFolderBookmarkCreator
    private let exportFolderBookmarkResolver: ExportFolderBookmarkResolver
    private let closeConfirmation: CloseConfirmation?
    let externalChangeConfirmation: ExternalProjectChangeConfirmation?
    let saveProjectCopyHandler: (@MainActor () -> Bool)?

    var templates: [FrameTemplate]
    private let builtInTemplates: [FrameTemplate]
    private var autosaveTask: Task<Void, Never>?
    var trackedProjectFileURL: URL?
    var trackedProjectFileSnapshot: ProjectFileSnapshot?
    var declinedExternalProjectSnapshot: ProjectFileSnapshot?
    var projectFileMonitor: ProjectFileMonitor?
    var externalChangePromptIsActive = false
    private var segmentRebuildTasks: [UUID: Task<Void, Never>] = [:]
    private var autocompleteCooldowns: [AIProviderKind: Date] = [:]
    var autocompleteIssue: AutocompleteProviderIssue?
    var autocompleteConfigurationVersion = 0
    var autocompleteCompletionDelay: Duration = .milliseconds(280)
    var autocompleteNow: () -> Date = Date.init
#if DEBUG
    private var didApplyUITestLaunchArguments = false
#endif
    private var appActivationObserver: NSObjectProtocol?
    private var appResignationObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?

    init(
        projectStore: ProjectStore = ProjectStore(),
        recentProjectStore: RecentProjectStore = RecentProjectStore(),
        editorState: EditorState = EditorState(),
        settingsStore: SettingsStore = SettingsStore(),
        aiState: AIState = AIState(),
        windowState: WindowState = WindowState(),
        errorCenter: ErrorCenter = ErrorCenter(),
        themeManager: ResolvedThemeManager = ResolvedThemeManager(),
        dependencies: AppDependencies = .live,
        aiProviderConfigurationStore: AIProviderConfigurationStore = AIProviderConfigurationStore(),
        securityScope: SecurityScopedResourceAccess = .live,
        closeConfirmation: CloseConfirmation? = nil,
        externalChangeConfirmation: ExternalProjectChangeConfirmation? = nil,
        saveProjectCopyHandler: (@MainActor () -> Bool)? = nil,
        exportFolderBookmarkCreator: @escaping ExportFolderBookmarkCreator = { url in
            try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        },
        exportFolderBookmarkResolver: @escaping ExportFolderBookmarkResolver = { data, isStale in
            try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        },
        templates: [FrameTemplate] = SampleData.templates
    ) {
        self.projectStore = projectStore
        self.recentProjectStore = recentProjectStore
        self.editorState = editorState
        self.settingsStore = settingsStore
        self.aiState = aiState
        self.windowState = windowState
        self.errorCenter = errorCenter
        self.themeManager = themeManager
        self.dependencies = dependencies
        self.aiProviderConfigurationStore = aiProviderConfigurationStore
        self.securityScope = securityScope
        self.closeConfirmation = closeConfirmation
        self.externalChangeConfirmation = externalChangeConfirmation
        self.saveProjectCopyHandler = saveProjectCopyHandler
        self.exportFolderBookmarkCreator = exportFolderBookmarkCreator
        self.exportFolderBookmarkResolver = exportFolderBookmarkResolver
        self.builtInTemplates = templates.filter(\.builtIn)
        self.templates = Self.mergedTemplates(builtIns: templates.filter(\.builtIn), customTemplates: Self.loadCustomTemplates())
        self.windowState.isSidebarVisible = settingsStore.settings.windowPreferences.sidebarDefaultVisible
        self.projectStore.setSegmentSplitMode(settingsStore.settings.generalPreferences.defaultSplitMode)
        settingsStore.setErrorReporter { [weak errorCenter] error in
            errorCenter?.present(error)
        }
    }

    func configure() {
        let arguments = ProcessInfo.processInfo.arguments
        recentProjectStore.load()
#if DEBUG
        if let flagIndex = arguments.firstIndex(of: "--framescript-ui-test-recent-path"),
           arguments.indices.contains(flagIndex + 1) {
            let requestedURL = URL(fileURLWithPath: arguments[flagIndex + 1])
            do {
                try recentProjectStore.addUITestEntry(url: requestedURL)
            } catch {
                showNotice(.recentBookmarkWarning)
            }
        } else {
            let result = recentProjectStore.validateEntriesNow()
            presentAutomaticRecentRemovalNotice(count: result.removedMissingCount)
        }
#else
        let result = recentProjectStore.validateEntriesNow()
        presentAutomaticRecentRemovalNotice(count: result.removedMissingCount)
#endif
        consumeRecentProjectStoreError()
        installAppActivationObserverIfNeeded()
        projectStore.configure(
            wordsPerMinute: settings.editorPreferences.wordsPerMinute
        )
#if DEBUG
        if arguments.contains("--framescript-ui-test-language-english") {
            settings.generalPreferences.language = .english
        } else if arguments.contains("--framescript-ui-test-language-russian") {
            settings.generalPreferences.language = .russian
        }
        if arguments.contains("--framescript-ui-test-show-browser") {
            settings.generalPreferences.launchBehavior = .showProjectBrowser
        }
#endif
        if let entry = recentProjectStore.entries.first,
           settings.generalPreferences.launchBehavior.shouldRestoreLastProject(
               hasOpenProject: hasOpenProject,
               hasRecentProject: true
           ) {
            openRecentProject(entry, reportsMissingNotice: false, presentsErrors: false)
        }
#if DEBUG
        if !didApplyUITestLaunchArguments,
           arguments.contains("--framescript-ui-test-open-demo") {
            didApplyUITestLaunchArguments = true
            openDemoProject()
        }
#endif
        projectStore.setSegmentSplitMode(settings.generalPreferences.defaultSplitMode)
        if editorState.selectedSceneID == nil {
            editorState.selectedSceneID = project.scenes.first?.id
        }
    }

    var project: FrameProject {
        projectStore.project
    }

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    var selectedMode: WorkspaceMode {
        get { editorState.selectedMode }
        set { selectMode(newValue) }
    }

    var selectedScene: Scene? {
        projectStore.selectedScene(id: editorState.selectedSceneID)
    }

    var hasOpenProject: Bool {
        projectStore.hasOpenProject
    }

    var recentProjectEntries: [RecentProjectEntry] {
        recentProjectStore.entries
    }

    var selectedSceneIndex: Int? {
        projectStore.selectedSceneIndex(id: editorState.selectedSceneID)
    }

    var totalDuration: TimeInterval {
        projectStore.totalDuration
    }

    var isSidebarVisible: Bool {
        get { windowState.isSidebarVisible }
        set { windowState.isSidebarVisible = newValue }
    }

    var isFocusModeEnabled: Bool {
        get { editorState.isFocusModeEnabled }
        set { editorState.isFocusModeEnabled = newValue }
    }

    var isCommandPalettePresented: Bool {
        get { windowState.isCommandPalettePresented }
        set { windowState.isCommandPalettePresented = newValue }
    }

    var isSettingsPresented: Bool {
        get { windowState.isSettingsPresented }
        set { windowState.isSettingsPresented = newValue }
    }

    var isShortcutsPresented: Bool {
        get { windowState.isShortcutsPresented }
        set { windowState.isShortcutsPresented = newValue }
    }

    var saveState: SaveState {
        projectStore.saveState
    }

    var currentLanguage: AppLanguage {
        settings.generalPreferences.language
    }

    var autocompleteConfigurationEligibility: AutocompleteConfigurationEligibility {
        guard settings.aiPreferences.enableInlineAutocomplete else { return .blockedPreferenceDisabled }
        let provider = settings.aiPreferences.provider
        guard provider != .disabled else { return .blockedProviderDisabled }
        guard aiProviderConfigurationStore.hasStoredKey(for: provider) else { return .blockedMissingKeyMetadata }
        return .eligible
    }

    var autocompleteConfigurationIsEligible: Bool {
        autocompleteConfigurationEligibility.isEligible
    }

    func localized(_ key: String) -> String {
        L10n.tr(key, language: currentLanguage)
    }

    func shortcutDisplay(for command: ShortcutCommand) -> String {
        ShortcutDisplayFormatter.display(
            for: command,
            settings: settings,
            notAssigned: localized("shortcuts.notAssigned")
        )
    }

    func shortcutBinding(for command: ShortcutCommand) -> ShortcutBinding? {
        settings.activeShortcut(for: command)
    }

    func selectMode(_ mode: WorkspaceMode) {
        guard editorState.selectedMode != mode else { return }
        transitionEditorContext(mode: mode)
    }

    @discardableResult
    func returnToProjectList() -> Bool {
        guard closeProject() else { return false }
        return true
    }

    func newProject(template: FrameTemplate? = nil) {
        createNewProject(named: localized("project.untitled"), template: template)
    }

    func requestNewProject(
        template: FrameTemplate? = nil,
        locksTemplate: Bool = false,
        showsTemplateBrowser: Bool = false
    ) {
        let selectedTemplate = template ?? templates.first { $0.name == settings.generalPreferences.defaultNewProjectTemplate } ?? templates.first
        windowState.newProjectRequest = NewProjectRequest(
            templateID: selectedTemplate?.id,
            locksTemplate: locksTemplate,
            showsTemplateBrowser: showsTemplateBrowser
        )
    }

    func createNewProject(named name: String, template: FrameTemplate? = nil) {
        guard prepareForProjectReplacement() else { return }
        let selectedTemplate = template ?? templates.first { $0.name == settings.generalPreferences.defaultNewProjectTemplate } ?? templates.first
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? localized("project.untitled") : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = SampleData.project(
            named: title,
            template: selectedTemplate,
            blankProjectStart: settings.generalPreferences.blankProjectStart,
            defaultSceneName: localized("templates.defaultScene"),
            exportPresetName: localized("export.editorHandoff"),
            sceneNameResolver: { [weak self] name in self?.localizedTemplateSceneName(name) ?? name }
        )
        projectStore.openProject(project, fileURL: nil, wordsPerMinute: settings.editorPreferences.wordsPerMinute, markUnsaved: true)
        resetProjectFileTracking()
        projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
        setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id), mode: .script)
        editorState.isFocusModeEnabled = false
        windowState.newProjectRequest = nil
    }

    func openDemoProject() {
        guard prepareForProjectReplacement() else { return }
        let project = SampleData.demoProject(language: currentLanguage)
        projectStore.openProject(
            project,
            fileURL: nil,
            wordsPerMinute: settings.editorPreferences.wordsPerMinute,
            markUnsaved: false,
            origin: .builtInDemo
        )
        resetProjectFileTracking()
        projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
        projectStore.clearDemoDirtyState()
        setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id), mode: .script)
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.frameScript, .frameScriptLegacy]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = localized("dialog.openProject.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        guard prepareForProjectReplacement() else { return }
        do {
            let project = try securityScope.withAccess(to: url) {
                try FrameScriptFileStore.read(from: url)
            }
            projectStore.openProject(project, fileURL: url, wordsPerMinute: settings.editorPreferences.wordsPerMinute, markUnsaved: false)
            rememberRecentProject(url)
            projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: settings.editorPreferences.wordsPerMinute, markUnsaved: false)
            setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id))
            startTrackingProjectFile(at: url)
        } catch {
            Self.projectFilesLogger.error("Operation project-open failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: url, operation: .read))
        }
    }

    func openRecentProject(
        _ entry: RecentProjectEntry,
        reportsMissingNotice: Bool = true,
        presentsErrors: Bool = true
    ) {
        guard prepareForProjectReplacement() else { return }
#if DEBUG
        if recentProjectStore.isUITestEntry(entry),
           ProcessInfo.processInfo.arguments.contains("--framescript-ui-test-recent-path") {
            return
        }
#endif
        do {
            let url = try recentProjectStore.validatedURL(for: entry)
            try securityScope.withAccess(to: url) {
                let project = try FrameScriptFileStore.read(from: url)
                projectStore.openProject(project, fileURL: url, wordsPerMinute: settings.editorPreferences.wordsPerMinute, markUnsaved: false)
                rememberRecentProject(url)
                projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: settings.editorPreferences.wordsPerMinute, markUnsaved: false)
                setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id))
                startTrackingProjectFile(at: url)
            }
        } catch RecentProjectStoreError.missingFile {
            recentProjectStore.remove(id: entry.id)
            consumeRecentProjectStoreError()
            if reportsMissingNotice { showNotice(.recentMissingRemoved) }
        } catch let error as RecentProjectStoreError {
            if presentsErrors { errorCenter.present(AppError.recent(error, recentID: entry.id)) }
        } catch {
            if presentsErrors {
                errorCenter.present(AppError.project(error, fileURL: URL(fileURLWithPath: entry.lastKnownPath), operation: .read))
            }
        }
    }

    func importProject() {
        openProject()
    }

    @discardableResult
    func saveProject() -> Bool {
        guard hasOpenProject else { return false }
        flushActiveEditorBoundary(saveImmediately: false)
        guard let url = projectStore.currentFileURL else { return saveProjectAs() }
        switch prepareProjectFileForWrite() {
        case .proceed:
            break
        case .handled:
            return true
        case .failed:
            return false
        }
        do {
            try securityScope.withAccess(to: url) {
                try projectStore.saveCurrentProject(wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            }
            recordProjectFileSnapshot(at: url)
            errorCenter.clearAutosaveFailureSuppression()
            rememberRecentProject(url)
            return true
        } catch {
            Self.projectFilesLogger.error("Operation project-save failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: projectStore.currentFileURL, operation: .write))
            return false
        }
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard hasOpenProject else { return false }
        flushActiveEditorBoundary(saveImmediately: false)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.frameScript]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(project.title).fscr"
        panel.message = localized("dialog.saveProject.message")
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try projectStore.saveCurrentProject(to: url, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            startTrackingProjectFile(at: url)
            errorCenter.clearAutosaveFailureSuppression()
            rememberRecentProject(url)
            return true
        } catch {
            Self.projectFilesLogger.error("Operation project-save-as failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError.project(error, fileURL: url, operation: .write))
            return false
        }
    }

    func exportProject() {
        guard hasOpenProject else { return }
        windowState.isExportPresented = true
    }

    func saveExport(format: ExportFormat, preferences: ExportPreferences, to url: URL) {
        guard hasOpenProject else { return }
        do {
            let rendered = dependencies.exportService.render(project: project, format: format, preferences: preferences, language: currentLanguage)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.exportLogger.error("Operation export-write failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError(
                kind: .export,
                context: AppErrorContext(fileName: url.lastPathComponent, diagnosticCode: diagnosticCode(for: error)),
                recoveryAction: .chooseExportFolder
            ))
        }
    }

    func copyExportToClipboard(format: ExportFormat, preferences: ExportPreferences) {
        guard hasOpenProject else { return }
        let rendered = dependencies.exportService.render(project: project, format: format, preferences: preferences, language: currentLanguage)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(rendered, forType: .string) else {
            Self.exportLogger.error("Operation export-clipboard-write failed. Code: clipboard-write")
            errorCenter.present(AppError(kind: .export, context: AppErrorContext(diagnosticCode: "clipboard-write")))
            return
        }
    }

    func duplicateProject() {
        guard hasOpenProject else { return }
        var copy: FrameProject?
        transitionEditorContext {
            copy = projectStore.duplicateProject(copySuffix: localized("templates.copySuffix"))
        }
        resetProjectFileTracking()
        setEditorContextAfterFlush(sceneID: .some(copy?.scenes.sortedByOrder.first?.id))
    }

    @discardableResult
    func closeProject() -> Bool {
        guard hasOpenProject else { return true }
        flushActiveEditorBoundary()
        guard confirmCloseProjectIfNeeded() else { return false }
        projectStore.closeProject()
        resetProjectFileTracking()
        setEditorContextAfterFlush(sceneID: .some(nil))
        return true
    }

    func revealProjectInFinder() {
        guard let url = projectStore.currentFileURL else { return }
        securityScope.withAccess(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func revealRecentProjectInFinder(_ entry: RecentProjectEntry) {
        do {
            let url = try recentProjectStore.validatedURL(for: entry)
            securityScope.withAccess(to: url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch RecentProjectStoreError.missingFile {
            recentProjectStore.remove(id: entry.id)
            consumeRecentProjectStoreError()
            showNotice(.recentMissingRemoved)
        } catch let error as RecentProjectStoreError {
            errorCenter.present(AppError.recent(error, recentID: entry.id))
        } catch {
            errorCenter.present(AppError.recent(error, recentID: entry.id))
        }
    }

    func canRevealRecentProject(_ entry: RecentProjectEntry) -> Bool {
        recentProjectStore.availability(for: entry)
    }

    func renameProject() {
        guard hasOpenProject,
              let newName = prompt(title: localized("project.rename"), message: localized("dialog.renameProject.message"), defaultValue: project.title),
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        project.title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        touchProject()
    }

    func deleteProject() {
        guard hasOpenProject else { return }
        if settings.generalPreferences.confirmBeforeDeleting,
           !confirm(title: localized("dialog.deleteProject.title"), message: localized("dialog.deleteProject.message")) {
            return
        }
        transitionEditorContext(sceneID: .some(nil)) {
            projectStore.deleteCurrentProject()
        }
        resetProjectFileTracking()
    }

    func selectScene(_ sceneID: UUID) {
        guard editorState.selectedSceneID != sceneID else { return }
        transitionEditorContext(sceneID: .some(sceneID))
    }

    private func transitionEditorContext(
        sceneID: UUID?? = nil,
        mode: WorkspaceMode? = nil,
        preservingProductionSelection: Bool = false,
        mutation: () -> Void = {}
    ) {
        flushActiveEditorBoundary()
        mutation()
        setEditorContextAfterFlush(sceneID: sceneID, mode: mode, preservingProductionSelection: preservingProductionSelection)
    }

    func setEditorContextAfterFlush(
        sceneID: UUID?? = nil,
        mode: WorkspaceMode? = nil,
        preservingProductionSelection: Bool = false
    ) {
        let sceneChanged = sceneID.map { $0 != editorState.selectedSceneID } ?? false
        let modeChanged = mode.map { $0 != editorState.selectedMode } ?? false
        if (sceneChanged || modeChanged) && !preservingProductionSelection {
            clearProductionSelection()
        }
        if let sceneID { editorState.selectedSceneID = sceneID }
        if let mode { editorState.selectedMode = mode }
    }

    private func prepareForProjectReplacement() -> Bool {
        flushActiveEditorBoundary()
        return !hasOpenProject || confirmCloseProjectIfNeeded()
    }

    func touchProject() {
        projectStore.markProjectDirty()
        scheduleAutosaveIfNeeded()
    }

    func touchCurrentSceneText() {
        guard let sceneID = selectedScene?.id else {
            touchProject()
            return
        }
        commitScriptTextChange(sceneID: sceneID)
    }

    func commitScriptTextChange(sceneID: UUID, previousText: String? = nil, text: String? = nil) {
        projectStore.setSegmentSplitMode(settings.generalPreferences.defaultSplitMode)
        let oldText = previousText ?? project.scenes.first(where: { $0.id == sceneID })?.scriptText
        if let text {
            projectStore.commitScriptText(text, sceneID: sceneID, previousText: oldText)
        }
        projectStore.updateCurrentSceneMetrics(sceneID: sceneID, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
        validateProductionSelection()
        projectStore.markProjectDirty()
        scheduleSegmentRebuild(for: sceneID)
        scheduleAutosaveIfNeeded()
    }

    func autocompleteScript(context: AutocompleteContext) async -> AutocompleteResult {
        let provider = settings.aiPreferences.provider
        switch autocompleteConfigurationEligibility {
        case .eligible, .blockedCooldown:
            break
        case .blockedProviderDisabled:
            autocompleteIssue = nil
            logAutocompleteBlockedOutcome(.blockedProviderDisabled, provider: provider)
            return .none
        case .blockedPreferenceDisabled:
            autocompleteIssue = nil
            logAutocompleteBlockedOutcome(.blockedPreferenceDisabled, provider: provider)
            return .none
        case .blockedMissingKeyMetadata:
            if autocompleteIssue?.provider == provider { autocompleteIssue = nil }
            logAutocompleteBlockedOutcome(.blockedMissingKeyMetadata, provider: provider)
            return .none
        }
        guard !context.prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
        let now = autocompleteNow()
        if let cooldown = autocompleteCooldowns[provider], cooldown > now {
            recordAutocompleteIssue(for: provider, reason: .rateLimited, cooldownDeadline: cooldown)
            logAutocompleteBlockedOutcome(.blockedCooldown, provider: provider, remainingCooldown: cooldown.timeIntervalSince(now))
            return .temporarilyUnavailable(.rateLimited)
        }
        autocompleteCooldowns.removeValue(forKey: provider)
        do {
            let promptBuilder = PromptBuilder()
            let apiKey = try dependencies.providerCredentials.apiKey(for: provider)
            let request = LLMRequest(
                task: .autocomplete,
                provider: provider,
                baseURL: settings.aiPreferences.baseURL,
                systemPrompt: promptBuilder.systemPrompt(for: .autocomplete, language: context.language),
                userPrompt: context.prompt,
                model: settings.aiPreferences.model,
                temperature: settings.aiPreferences.temperature,
                maxTokens: 96
            )
            let firstResponse = try await dependencies.llmProvider.complete(request: request, apiKey: apiKey)
            let completion: String
            switch AutocompleteCompletion.sanitizeResult(firstResponse, context: context) {
            case .completion(let value):
                completion = value
                logAutocompleteOutcome(
                    firstResponse.stoppedAtTokenLimit
                        ? "acceptedCompleteSentenceFromTokenLimitedResponse"
                        : "acceptedFirstAttempt",
                    provider: provider,
                    model: request.model,
                    finishReason: firstResponse.finishReason,
                    characterCount: firstResponse.text.count,
                    attempt: "initial"
                )
            case .noCompleteSentence where firstResponse.stoppedAtTokenLimit:
                logAutocompleteOutcome("retryAfterTokenLimit", provider: provider, model: request.model, finishReason: firstResponse.finishReason, characterCount: firstResponse.text.count, attempt: "initial")
                try Task.checkCancellation()
                var retryRequest = request
                retryRequest.maxTokens = 160
                let retryResponse = try await dependencies.llmProvider.complete(request: retryRequest, apiKey: apiKey)
                switch AutocompleteCompletion.sanitizeResult(retryResponse, context: context) {
                case .completion(let value):
                    completion = value
                    logAutocompleteOutcome("acceptedRetry", provider: provider, model: retryRequest.model, finishReason: retryResponse.finishReason, characterCount: retryResponse.text.count, attempt: "retry")
                case .noCompleteSentence:
                    logAutocompleteOutcome("rejectedNoCompleteSentence", provider: provider, model: retryRequest.model, finishReason: retryResponse.finishReason, characterCount: retryResponse.text.count, attempt: "retry")
                    return .none
                case .rejected:
                    logAutocompleteOutcome("rejectedSanitizer", provider: provider, model: retryRequest.model, finishReason: retryResponse.finishReason, characterCount: retryResponse.text.count, attempt: "retry")
                    return .none
                }
            case .noCompleteSentence:
                logAutocompleteOutcome("rejectedNoCompleteSentence", provider: provider, model: request.model, finishReason: firstResponse.finishReason, characterCount: firstResponse.text.count, attempt: "initial")
                return .none
            case .rejected:
                logAutocompleteOutcome("rejectedSanitizer", provider: provider, model: request.model, finishReason: firstResponse.finishReason, characterCount: firstResponse.text.count, attempt: "initial")
                return .none
            }
            if settings.aiPreferences.provider == provider {
                autocompleteIssue = nil
            }
            return .suggestion(completion)
        } catch is CancellationError {
            return .none
        } catch let error as LLMProviderError where error == .network(String(URLError.Code.cancelled.rawValue)) {
            return .none
        } catch {
            let reason = AutocompleteUnavailableReason.from(error)
            var cooldownDeadline: Date?
            if reason == .rateLimited {
                let requestedDelay = AutocompleteRetryAfterCache.take(for: provider) ?? 30
                cooldownDeadline = autocompleteNow().addingTimeInterval(min(max(requestedDelay, 5), 300))
                autocompleteCooldowns[provider] = cooldownDeadline
            }
            if settings.aiPreferences.provider == provider {
                recordAutocompleteIssue(for: provider, reason: reason, cooldownDeadline: cooldownDeadline)
            }
            return .temporarilyUnavailable(reason)
        }
    }

    private func logAutocompleteOutcome(
        _ outcome: String,
        provider: AIProviderKind,
        model: String,
        finishReason: String?,
        characterCount: Int,
        attempt: String
    ) {
#if DEBUG
        Self.autocompleteLogger.debug("Autocomplete outcome=\(outcome, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
#endif
    }

    private func logAutocompleteBlockedOutcome(
        _ reason: AutocompleteConfigurationEligibility,
        provider: AIProviderKind,
        remainingCooldown: TimeInterval? = nil
    ) {
#if DEBUG
        if let remainingCooldown {
            Self.autocompleteLogger.debug("Autocomplete outcome=\(reason.rawValue, privacy: .public) provider=\(provider.rawValue, privacy: .public) cooldownSeconds=\(Int(remainingCooldown.rounded()), privacy: .public)")
        } else {
            Self.autocompleteLogger.debug("Autocomplete outcome=\(reason.rawValue, privacy: .public) provider=\(provider.rawValue, privacy: .public)")
        }
#endif
    }

    func autocompleteProviderDidChange(from oldProvider: AIProviderKind, to newProvider: AIProviderKind) {
        autocompleteCooldowns.removeValue(forKey: oldProvider)
        autocompleteIssue = nil
        autocompleteConfigurationVersion += 1
    }

    func autocompleteProviderConfigurationDidChange(for provider: AIProviderKind) {
        autocompleteCooldowns.removeValue(forKey: provider)
        if autocompleteIssue?.provider == provider {
            autocompleteIssue = nil
        }
        autocompleteConfigurationVersion += 1
    }

    func inlineAutocompletePreferenceDidChange() {
        autocompleteIssue = nil
        autocompleteConfigurationVersion += 1
        ActiveScriptEditorSession.shared.cancelAllAutocomplete()
    }

    private func recordAutocompleteIssue(
        for provider: AIProviderKind,
        reason: AutocompleteUnavailableReason,
        cooldownDeadline: Date?
    ) {
        autocompleteIssue = AutocompleteProviderIssue(
            provider: provider,
            reason: reason,
            cooldownDeadline: cooldownDeadline
        )
    }

    func flushActiveEditorBoundary(
        saveImmediately: Bool = true,
        allEditors: Bool = false,
        flushEditor: Bool = true
    ) {
        let hadActiveScriptEditor: Bool
        if allEditors {
            hadActiveScriptEditor = ActiveScriptEditorSession.shared.flushAllForAppResignation()
        } else if flushEditor {
            hadActiveScriptEditor = ActiveScriptEditorSession.shared.flush()
        } else {
            hadActiveScriptEditor = false
        }
        guard hasOpenProject else { return }
        if hadActiveScriptEditor {
            projectStore.markProjectDirty()
        }
        if let sceneID = editorState.selectedSceneID ?? selectedScene?.id {
            flushSegmentRebuild(for: sceneID)
        }
        if saveImmediately {
            autosaveTask?.cancel()
            autosaveTask = nil
            performAutosave()
        } else {
            scheduleAutosaveIfNeeded()
        }
    }

    func rebuildProductionSegments(markUnsaved: Bool = true) {
        projectStore.synchronizeTextSegments(
            splitMode: settings.generalPreferences.defaultSplitMode,
            wordsPerMinute: settings.editorPreferences.wordsPerMinute,
            markUnsaved: markUnsaved
        )
        scheduleAutosaveIfNeeded()
    }

    func addBRollItem(sceneID: UUID, anchor: TextAnchor) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        transitionEditorContext(mode: .bRoll) {
            scene.bRollItems.append(BRollItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", sourceType: .custom, descriptionText: anchor.selectedText))
            touchProject()
        }
    }

    func addEditingItem(sceneID: UUID, anchor: TextAnchor) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        transitionEditorContext(mode: .editing) {
            scene.editingItems.append(EditingItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", cutStyle: anchor.selectedText, transition: "", subtitleStyle: ""))
            touchProject()
        }
    }

    func selectProductionItem(_ itemID: UUID, mode: WorkspaceMode) {
        selectProductionItems([itemID], mode: mode)
    }

    func selectProductionItems(_ itemIDs: [UUID], mode: WorkspaceMode) {
        guard mode == .bRoll || mode == .editing,
              let scene = selectedScene else { return }
        let items: [(UUID, TextAnchor?)] = switch mode {
        case .bRoll: scene.bRollItems.map { ($0.id, $0.textAnchor) }
        case .editing: scene.editingItems.map { ($0.id, $0.textAnchor) }
        case .script: []
        }
        let anchorsByID = Dictionary(uniqueKeysWithValues: items)
        let selectedIDs = itemIDs.reduce(into: [UUID]()) { result, itemID in
            guard !result.contains(itemID),
                  let anchor = anchorsByID[itemID],
                  TextAnchorRepair.current(anchor, in: scene.scriptText) != nil else { return }
            result.append(itemID)
        }
        guard let selectedID = selectedIDs.first,
              let group = productionMarkerGroups(in: scene, mode: mode).first(where: { $0.itemIDs.contains(selectedID) }) else { return }
        transitionEditorContext(mode: mode, preservingProductionSelection: true) {
            editorState.selectedProductionItemIDs = group.itemIDs
        }
    }

    func isProductionItemSelected(_ itemID: UUID) -> Bool {
        editorState.selectedProductionItemIDs.contains(itemID)
    }

    func clearProductionSelection(containing itemID: UUID? = nil) {
        if let itemID, !editorState.selectedProductionItemIDs.contains(itemID) { return }
        editorState.selectedProductionItemIDs = []
    }

    func normalizeProductionSelection(preferredItemID: UUID? = nil) {
        validateProductionSelection(preferredItemID: preferredItemID)
    }

    private func validateProductionSelection(preferredItemID: UUID? = nil) {
        guard !editorState.selectedProductionItemIDs.isEmpty,
              let scene = selectedScene else {
            return
        }
        let groups = productionMarkerGroups(in: scene, mode: editorState.selectedMode)
        let preferredGroup = preferredItemID.flatMap { preferredID in
            groups.first { $0.itemIDs.contains(preferredID) }
        }
        guard let group = preferredGroup ?? groups.first(where: { group in
            editorState.selectedProductionItemIDs.contains { group.itemIDs.contains($0) }
        }) else {
            clearProductionSelection()
            return
        }
        editorState.selectedProductionItemIDs = group.itemIDs
    }

    private func productionMarkerGroups(in scene: Scene, mode: WorkspaceMode) -> [ProductionMarkerGroup] {
        let anchors: [(id: UUID, anchor: TextAnchor, itemOrder: Int)] = switch mode {
        case .bRoll:
            scene.bRollItems.enumerated().compactMap { index, item in
                TextAnchorRepair.current(item.textAnchor, in: scene.scriptText).map { (item.id, $0, index) }
            }
        case .editing:
            scene.editingItems.enumerated().compactMap { index, item in
                TextAnchorRepair.current(item.textAnchor, in: scene.scriptText).map { (item.id, $0, index) }
            }
        case .script:
            []
        }
        let sorted = anchors.sorted {
            if $0.anchor.startUTF16 != $1.anchor.startUTF16 { return $0.anchor.startUTF16 < $1.anchor.startUTF16 }
            if $0.anchor.lengthUTF16 != $1.anchor.lengthUTF16 { return $0.anchor.lengthUTF16 < $1.anchor.lengthUTF16 }
            return $0.itemOrder < $1.itemOrder
        }
        guard let first = sorted.first else { return [] }
        var groups: [ProductionMarkerGroup] = []
        var group = ProductionMarkerGroup(range: first.anchor.nsRange, itemIDs: [first.id])
        for entry in sorted.dropFirst() {
            let range = entry.anchor.nsRange
            let groupEnd = NSMaxRange(group.range)
            if range.location <= groupEnd {
                group.range.length = max(groupEnd, NSMaxRange(range)) - group.range.location
                group.itemIDs.append(entry.id)
            } else {
                groups.append(group)
                group = ProductionMarkerGroup(range: range, itemIDs: [entry.id])
            }
        }
        groups.append(group)
        return groups
    }

    private func productionSuggestionTarget(in scene: Scene) -> TextAnchor? {
        let selectedAnchor: TextAnchor? = switch editorState.selectedMode {
        case .bRoll:
            editorState.selectedProductionItemIDs.lazy.compactMap { selectedID in
                scene.bRollItems.first(where: { $0.id == selectedID }).flatMap { TextAnchorRepair.current($0.textAnchor, in: scene.scriptText) }
            }.first
        case .editing:
            editorState.selectedProductionItemIDs.lazy.compactMap { selectedID in
                scene.editingItems.first(where: { $0.id == selectedID }).flatMap { TextAnchorRepair.current($0.textAnchor, in: scene.scriptText) }
            }.first
        case .script:
            nil
        }
        return selectedAnchor ?? TextAnchorRepair.anchor(
            in: scene.scriptText,
            range: NSRange(location: 0, length: (scene.scriptText as NSString).length)
        )
    }

    func addScene() {
        guard hasOpenProject else { return }
        let scene = projectStore.makeScene(order: project.scenes.count, title: localized("templates.defaultScene"))
        transitionEditorContext(sceneID: .some(scene.id), mode: .script) {
            projectStore.addScene(scene, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func addScene(after sceneID: UUID) {
        guard hasOpenProject else { return }
        let ordered = project.scenes.sortedByOrder
        let targetIndex = ordered.firstIndex { $0.id == sceneID } ?? max(0, ordered.count - 1)
        let scene = projectStore.makeScene(order: targetIndex + 1, title: localized("templates.defaultScene"))
        transitionEditorContext(sceneID: .some(scene.id), mode: .script) {
            projectStore.addScene(scene, afterSortedIndex: targetIndex, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func duplicateSelectedScene() {
        guard let scene = selectedScene else { return }
        let copy = projectStore.duplicate(scene, copySuffix: localized("templates.copySuffix"))
        transitionEditorContext(sceneID: .some(copy.id)) {
            projectStore.addScene(copy, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func deleteSelectedScene() {
        if settings.generalPreferences.confirmBeforeDeleting,
           !confirm(title: localized("dialog.deleteScene.title"), message: localized("dialog.deleteScene.message")) {
            return
        }
        guard let selectedSceneIndex else { return }
        // `selectedSceneIndex` is an index into visual (sorted) order, while
        // `project.scenes` keeps insertion order. Subscripting storage with it
        // selects an unrelated scene after "Add Scene After".
        let orderedScenes = project.scenes.sortedByOrder
        let nextID = orderedScenes.indices.contains(selectedSceneIndex + 1)
            ? orderedScenes[selectedSceneIndex + 1].id
            : orderedScenes.indices.contains(selectedSceneIndex - 1)
                ? orderedScenes[selectedSceneIndex - 1].id
                : orderedScenes.indices.contains(selectedSceneIndex) ? orderedScenes[selectedSceneIndex].id : nil
        transitionEditorContext(sceneID: .some(nextID)) {
            projectStore.deleteScene(at: selectedSceneIndex, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func moveSelectedSceneUp() {
        moveSelectedScene(by: -1)
    }

    func moveSelectedSceneDown() {
        moveSelectedScene(by: 1)
    }

    private func moveSelectedScene(by delta: Int) {
        guard let selectedSceneIndex else { return }
        projectStore.moveScene(at: selectedSceneIndex, by: delta, wordsPerMinute: settings.editorPreferences.wordsPerMinute)
        scheduleAutosaveIfNeeded()
    }

    func renameSelectedScene() {
        guard let scene = selectedScene,
              let newName = prompt(title: localized("scene.rename"), message: localized("dialog.renameScene.message"), defaultValue: scene.title),
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        scene.title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        touchProject()
    }

    func generateBRollForSelectedScene() {
        Task { await generateProductionSuggestion(kind: .bRollGeneration) }
    }

    func generateEditingNotesForSelectedScene() {
        Task { await generateProductionSuggestion(kind: .editingGeneration) }
    }

    private func generateProductionSuggestion(kind: AITask) async {
        guard settings.aiPreferences.provider != .disabled else {
            errorCenter.present(AppError(kind: .aiConfiguration, recoveryAction: .openAISettings))
            return
        }
        guard let scene = selectedScene else { return }
        guard let target = productionSuggestionTarget(in: scene) else {
            errorCenter.present(AppError(kind: .invalidProjectData))
            return
        }

        let schema = kind == .bRollGeneration
            ? "Return only one JSON object with string fields: source, description, notes. Source must be one of: \(BRollSourceType.allCases.map(\.rawValue).joined(separator: ", "))."
            : "Return only one JSON object with string fields: description, notes."
        let context = settings.aiPreferences.privacyMode
            ? target.selectedText
            : "Scene: \(scene.title)\nFull scene: \(scene.scriptText)\nTarget anchor: \(target.selectedText)"
        do {
            let provider = settings.aiPreferences.provider
            let apiKey = try dependencies.providerCredentials.apiKey(for: provider)
            let response = try await dependencies.llmProvider.complete(request: LLMRequest(
                task: kind,
                provider: provider,
                baseURL: settings.aiPreferences.baseURL,
                systemPrompt: "\(PromptBuilder().systemPrompt(for: kind, language: PromptBuilder().responseLanguage(for: scene.scriptText, fallback: currentLanguage))) \(schema) Do not use Markdown fences.",
                userPrompt: context,
                model: settings.aiPreferences.model,
                temperature: settings.aiPreferences.temperature,
                maxTokens: settings.aiPreferences.maxTokens
            ), apiKey: apiKey)
            let data = try Self.structuredJSONData(from: response.text)
            switch kind {
            case .bRollGeneration:
                let value = try JSONDecoder().decode(GeneratedBRollSuggestion.self, from: data)
                guard !value.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyDescription }
                let source = BRollSourceType.allCases.first { $0.rawValue.caseInsensitiveCompare(value.source) == .orderedSame } ?? .custom
                scene.bRollItems.append(BRollItem(textAnchor: target, linkedSegmentID: nil, templateType: "", sourceType: source, descriptionText: value.description, notes: value.notes))
                selectMode(.bRoll)
            case .editingGeneration:
                let value = try JSONDecoder().decode(GeneratedEditingSuggestion.self, from: data)
                guard !value.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyDescription }
                scene.editingItems.append(EditingItem(textAnchor: target, linkedSegmentID: nil, templateType: "", cutStyle: value.description, transition: "", subtitleStyle: "", notes: value.notes))
                selectMode(.editing)
            default: return
            }
            touchProject()
        } catch {
            errorCenter.present(AppError.ai(error))
        }
    }

    private static func structuredJSONData(from response: String) throws -> Data {
        guard let start = response.firstIndex(of: "{"), let end = response.lastIndex(of: "}"), start <= end,
              let data = String(response[start...end]).data(using: .utf8) else { throw GenerationError.invalidJSON }
        return data
    }

    func moveSelection(_ delta: Int) {
        guard let selectedSceneIndex else { return }
        let orderedScenes = project.scenes.sortedByOrder
        guard !orderedScenes.isEmpty else { return }
        let nextIndex = max(0, min(orderedScenes.count - 1, selectedSceneIndex + delta))
        selectScene(orderedScenes[nextIndex].id)
    }

    func analyzeSelectedScene() async {
        guard !aiState.isAnalyzing else { return }
        guard let scene = selectedScene else { return }
        aiState.isAnalyzing = true
        aiState.didFailMostRecentAnalysis = false
        defer { aiState.isAnalyzing = false }
        do {
            let apiKey = try providerAPIKeyIfNeeded()
            let comments = settings.aiPreferences.provider == .disabled
                ? disabledAIComments(for: scene)
                : try await dependencies.analysisService.analyze(scene: scene, project: project, settings: settings.aiPreferences, interfaceLanguage: currentLanguage, apiKey: apiKey)
            scene.aiComments = comments
            touchProject()
        } catch {
            aiState.didFailMostRecentAnalysis = true
            errorCenter.present(AppError.ai(error))
        }
    }

    func analyzeFullScript() async {
        guard !aiState.isAnalyzing else { return }
        aiState.isAnalyzing = true
        defer { aiState.isAnalyzing = false }
        do {
            let apiKey = try providerAPIKeyIfNeeded()
            for scene in project.scenes.sortedByOrder {
                let comments = settings.aiPreferences.provider == .disabled
                    ? disabledAIComments(for: scene)
                    : try await dependencies.analysisService.analyze(scene: scene, project: project, settings: settings.aiPreferences, interfaceLanguage: currentLanguage, apiKey: apiKey)
                scene.aiComments = comments
            }
            touchProject()
        } catch {
            errorCenter.present(AppError.ai(error))
        }
    }

    func clearRecentProjects() {
        recentProjectStore.removeAll()
        showNotice(.recentsCleared)
    }

    func removeRecentProject(_ entry: RecentProjectEntry) {
        recentProjectStore.remove(id: entry.id)
        consumeRecentProjectStoreError()
        showNotice(.recentRemoved)
    }

    func removeRecentProject(id: UUID) {
        recentProjectStore.remove(id: id)
        consumeRecentProjectStoreError()
        showNotice(.recentRemoved)
    }

    func compactParentFolder(for entry: RecentProjectEntry) -> String {
        recentProjectStore.compactParentFolder(for: entry)
    }

    func openSettings(tab: SettingsTab = .general, highlightKey: String? = nil) {
        windowState.requestedSettingsTab = tab
        windowState.requestedSettingsHighlightKey = highlightKey
        windowState.settingsRequestID = UUID()
    }

    func providerAPIKey(for provider: AIProviderKind) throws -> String {
        try dependencies.providerCredentials.apiKey(for: provider)
    }

    func invalidateProviderAPIKey(for provider: AIProviderKind) {
        dependencies.providerCredentials.invalidate(for: provider)
        autocompleteProviderConfigurationDidChange(for: provider)
    }

    private func providerAPIKeyIfNeeded() throws -> String {
        settings.aiPreferences.provider == .disabled ? "" : try providerAPIKey(for: settings.aiPreferences.provider)
    }

    func performRecovery(_ action: AppRecoveryAction) {
        switch action {
        case .retry:
            break // No retry is offered unless a future typed retry descriptor can execute safely.
        case .saveAs:
            _ = saveProjectAs()
        case .chooseExportFolder:
            chooseDefaultExportFolder()
        case .openAISettings:
            openSettings(tab: .ai)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .removeRecent(let id):
            removeRecentProject(id: id)
        }
    }

    func resetSidebarWidth() {
        settings.windowPreferences.sidebarWidth = AppSettings.defaults.windowPreferences.sidebarWidth
    }

    func chooseDefaultExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = localized("dialog.exportFolder.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            settings.exportPreferences.defaultExportFolderBookmarkData = try securityScope.withAccess(to: url) {
                try exportFolderBookmarkCreator(url)
            }
            settings.exportPreferences.defaultExportFolder = url.path
        } catch {
            clearDefaultExportFolder()
            showNotice(.exportFolderPermissionLost)
            errorCenter.present(AppError(kind: .bookmark, recoveryAction: .chooseExportFolder))
        }
    }

    func clearDefaultExportFolder() {
        settings.exportPreferences.defaultExportFolder = ""
        settings.exportPreferences.defaultExportFolderBookmarkData = nil
    }

    func resolvedDefaultExportFolder() -> URL? {
        if let bookmarkData = settings.exportPreferences.defaultExportFolderBookmarkData {
            do {
                var isStale = false
                let url = try exportFolderBookmarkResolver(bookmarkData, &isStale).standardizedFileURL
                let refreshedBookmark = try securityScope.withAccess(to: url) { () throws -> Data? in
                    guard isReadableDirectory(url) else {
                        throw RecentProjectStoreError.unreadableFile(url)
                    }
                    return isStale ? try exportFolderBookmarkCreator(url) : nil
                }
                if let refreshedBookmark {
                    settings.exportPreferences.defaultExportFolderBookmarkData = refreshedBookmark
                }
                if settings.exportPreferences.defaultExportFolder != url.path {
                    settings.exportPreferences.defaultExportFolder = url.path
                }
                return url
            } catch {
                clearDefaultExportFolder()
                showNotice(.exportFolderPermissionLost)
                return nil
            }
        }

        guard !settings.exportPreferences.defaultExportFolder.isEmpty else { return nil }
        let url = URL(fileURLWithPath: settings.exportPreferences.defaultExportFolder).standardizedFileURL
        do {
            let bookmark = try securityScope.withAccess(to: url) { () throws -> Data in
                guard isReadableDirectory(url) else {
                    throw RecentProjectStoreError.unreadableFile(url)
                }
                return try exportFolderBookmarkCreator(url)
            }
            settings.exportPreferences.defaultExportFolderBookmarkData = bookmark
            settings.exportPreferences.defaultExportFolder = url.path
            return url
        } catch {
            clearDefaultExportFolder()
            showNotice(.exportFolderPermissionLost)
            return nil
        }
    }

    func consumeRecentProjectStoreError() {
        let error = recentProjectStore.storeError
        guard let error else { return }
        switch error {
        case .persistenceFailed:
            showNotice(.recentPersistenceWarning)
        case .corruptedStorage:
            showNotice(.recentStorageWarning)
        default:
            errorCenter.present(AppError.recent(error))
        }
        recentProjectStore.acknowledgeStoreError()
    }

    private func confirmCloseProjectIfNeeded() -> Bool {
        guard projectStore.needsCloseConfirmation else { return true }
        if let closeConfirmation {
            switch closeConfirmation() {
            case .save: return saveProject()
            case .discard: return true
            case .cancel: return false
            }
        }
        let alert = NSAlert()
        alert.messageText = localized("project.unsaved.title")
        alert.informativeText = projectStore.currentFileURL == nil
            ? localized("project.unsaved.untitled")
            : localized("project.unsaved.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("project.unsaved.save"))
        alert.addButton(withTitle: localized("project.unsaved.discard"))
        alert.addButton(withTitle: localized("project.unsaved.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    private func disabledAIComments(for scene: Scene) -> [AIComment] {
        [
            AIComment(
                sceneID: scene.id,
                segmentID: scene.textSegments.sortedByOrder.first?.id,
                type: localized("ai.disabled.type"),
                severity: .note,
                message: localized("ai.disabled.message"),
                suggestion: localized("ai.disabled.suggestion")
            )
        ]
    }

    private func scheduleAutosaveIfNeeded() {
        // One pending write per interval: the first unsaved change arms the
        // timer and further edits coalesce into it instead of postponing it
        // forever. Editor text and live metrics were already committed by the
        // caller; only this disk write is delayed.
        guard autosaveTask == nil else { return }
        guard settings.generalPreferences.autosaveEnabled,
              !projectStore.isBuiltInDemo,
              projectStore.currentFileURL != nil,
              projectStore.hasUnsavedFileChanges else {
            return
        }
        let interval = AutosaveInterval.duration(forSeconds: settings.generalPreferences.autosaveIntervalSeconds)
        autosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.autosaveTask = nil
            self.performAutosave()
        }
    }

    private func scheduleSegmentRebuild(for sceneID: UUID) {
        segmentRebuildTasks[sceneID]?.cancel()
        segmentRebuildTasks[sceneID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 320_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.projectStore.synchronizeTextSegments(
                forSceneID: sceneID,
                splitMode: self.settings.generalPreferences.defaultSplitMode,
                wordsPerMinute: self.settings.editorPreferences.wordsPerMinute,
                markUnsaved: false
            )
            self.segmentRebuildTasks[sceneID] = nil
        }
    }

    private func flushSegmentRebuild(for sceneID: UUID) {
        segmentRebuildTasks[sceneID]?.cancel()
        segmentRebuildTasks[sceneID] = nil
        projectStore.synchronizeTextSegments(
            forSceneID: sceneID,
            splitMode: settings.generalPreferences.defaultSplitMode,
            wordsPerMinute: settings.editorPreferences.wordsPerMinute,
            markUnsaved: false
        )
    }

    private func performAutosave() {
        guard settings.generalPreferences.autosaveEnabled,
              !projectStore.isBuiltInDemo,
              let url = projectStore.currentFileURL,
              projectStore.hasUnsavedFileChanges else {
            return
        }
        switch prepareProjectFileForWrite() {
        case .proceed:
            break
        case .handled, .failed:
            return
        }
        do {
            try securityScope.withAccess(to: url) {
                try projectStore.saveCurrentProject(wordsPerMinute: settings.editorPreferences.wordsPerMinute)
            }
            recordProjectFileSnapshot(at: url)
            errorCenter.clearAutosaveFailureSuppression()
        } catch {
            Self.projectFilesLogger.error("Operation autosave failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.presentAutosave(AppError.project(error, fileURL: projectStore.currentFileURL, operation: .autosave))
        }
    }

    private func showNotice(_ kind: AppNoticeKind, count: Int? = nil) {
        errorCenter.showNotice(AppNotice(kind: kind, count: count))
    }

    private func rememberRecentProject(_ url: URL) {
        do {
            try recentProjectStore.add(url: url)
        } catch {
            showNotice(.recentBookmarkWarning)
        }
        consumeRecentProjectStoreError()
    }

    private func installAppActivationObserverIfNeeded() {
        if appActivationObserver == nil {
            appActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let result = await self.recentProjectStore.validateEntries()
                    self.presentAutomaticRecentRemovalNotice(count: result.removedMissingCount)
                    self.consumeRecentProjectStoreError()
                    self.checkForExternalProjectChanges()
                }
            }
        }
        if appResignationObserver == nil {
            appResignationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flushForApplicationResignation()
                }
            }
        }
        if appTerminationObserver == nil {
            appTerminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flushForApplicationTermination()
                }
            }
        }
        if windowCloseObserver == nil {
            windowCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.flushForWindowClose()
                }
            }
        }
    }

    /// Writes unsaved changes before the app stops being frontmost. Kept
    /// separate from the notification plumbing so it is directly testable.
    func flushForApplicationResignation() {
        flushActiveEditorBoundary(allEditors: true)
    }

    func flushForApplicationTermination() {
        flushActiveEditorBoundary(allEditors: true)
    }

    func flushForWindowClose() {
        flushActiveEditorBoundary(allEditors: true)
    }

    private func presentAutomaticRecentRemovalNotice(count: Int) {
        guard count > 0 else { return }
        showNotice(.recentMissingRemoved, count: count == 1 ? nil : count)
    }

    private func diagnosticCode(for error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        return true
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        return true
    }

    private func confirm(title: String, message: String, confirmButtonTitle: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle ?? localized("dialog.delete"))
        alert.addButton(withTitle: localized("project.unsaved.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func prompt(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: localized("dialog.ok"))
        alert.addButton(withTitle: localized("project.unsaved.cancel"))
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.stringValue = defaultValue
        alert.accessoryView = textField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue
    }

    func scriptTemplates() -> [FrameTemplate] {
        templates.filter { $0.category == .script }
    }

    func displayName(_ template: FrameTemplate) -> String {
        guard template.builtIn else { return template.name }
        return localized("template.\(templateKey(for: template.name))")
    }

    func localizedTemplateSceneName(_ name: String) -> String {
        localized("template.scene.\(templateSceneKey(for: name))")
    }

    func createCustomTemplate() {
        let template = FrameTemplate(
            id: UUID(),
            category: .script,
            name: uniqueTemplateName(base: localized("templates.untitled")),
            builtIn: false,
            structureDefinition: [localized("templates.defaultScene")],
            customFields: []
        )
        templates.append(template)
        persistCustomTemplates()
    }

    func duplicateTemplate(_ template: FrameTemplate) {
        var copy = template
        copy.id = UUID()
        copy.builtIn = false
        copy.builtInSourceName = nil
        copy.name = uniqueTemplateName(base: "\(template.name) \(localized("templates.copySuffix"))")
        templates.append(copy)
        persistCustomTemplates()
    }

    @discardableResult
    func customizeBuiltInTemplate(_ template: FrameTemplate) -> FrameTemplate? {
        guard template.builtIn else { return template }
        var override = template
        override.builtIn = false
        override.builtInSourceName = template.name
        override.name = displayName(template)
        override.structureDefinition = template.structureDefinition.map(localizedTemplateSceneName)

        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return nil }
        templates[index] = override
        if settings.generalPreferences.defaultNewProjectTemplate == template.name {
            settings.generalPreferences.defaultNewProjectTemplate = override.name
        }
        persistCustomTemplates()
        return override
    }

    @discardableResult
    func restoreOriginalTemplate(_ template: FrameTemplate) -> FrameTemplate? {
        guard let sourceName = template.builtInSourceName,
              var original = builtInTemplates.first(where: { $0.name == sourceName }) else {
            return nil
        }
        guard confirm(
            title: localized("dialog.restoreTemplate.title"),
            message: localized("dialog.restoreTemplate.message"),
            confirmButtonTitle: localized("templates.restoreOriginal")
        ) else {
            return nil
        }

        guard let index = templates.firstIndex(where: { $0.id == template.id }) else { return nil }
        original.id = template.id
        templates[index] = original
        if settings.generalPreferences.defaultNewProjectTemplate == template.name {
            settings.generalPreferences.defaultNewProjectTemplate = original.name
        }
        persistCustomTemplates()
        return original
    }

    func updateTemplate(_ template: FrameTemplate) {
        guard !template.builtIn, let index = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[index] = template
        persistCustomTemplates()
    }

    func deleteTemplate(_ template: FrameTemplate) {
        guard !template.builtIn else { return }
        guard confirm(
            title: localized("dialog.deleteTemplate.title"),
            message: localized("dialog.deleteTemplate.message")
        ) else {
            return
        }
        templates.removeAll { $0.id == template.id }
        if settings.generalPreferences.defaultNewProjectTemplate == template.name {
            settings.generalPreferences.defaultNewProjectTemplate = scriptTemplates().first?.name ?? "Blank"
        }
        persistCustomTemplates()
    }

    func resetSettingsWithConfirmation() {
        guard confirm(
            title: localized("dialog.resetSettings.title"),
            message: localized("dialog.resetSettings.message"),
            confirmButtonTitle: localized("settings.reset")
        ) else {
            return
        }
        settingsStore.reset()
    }

    func clearAPIKeysWithConfirmation() {
        guard confirm(
            title: localized("dialog.clearKeys.title"),
            message: localized("dialog.clearKeys.message"),
            confirmButtonTitle: localized("settings.clearKeys")
        ) else {
            return
        }
        for provider in AIProviderKind.allCases {
            do {
                try KeychainStore.deleteAPIKey(account: provider.keychainAccount)
                aiProviderConfigurationStore.setHasStoredKey(false, for: provider)
                invalidateProviderAPIKey(for: provider)
            } catch {
                errorCenter.present(AppError.keychain(error, operation: .delete))
            }
        }
    }

    private func templateKey(for name: String) -> String {
        switch name {
        case "Blank": "blank"
        case "Standard YouTube": "standardYouTube"
        case "Educational": "educational"
        case "Storytelling": "storytelling"
        case "Product Review": "productReview"
        case "Commentary / Essay": "commentaryEssay"
        case "Tutorial": "tutorial"
        default: name
        }
    }

    private func templateSceneKey(for name: String) -> String {
        switch name {
        case "Hook": "hook"
        case "Problem": "problem"
        case "Why this matters": "whyThisMatters"
        case "Explanation": "explanation"
        case "Example": "example"
        case "Takeaway": "takeaway"
        case "CTA": "cta"
        case "Context": "context"
        case "Core explanation": "coreExplanation"
        case "Summary": "summary"
        case "Setup": "setup"
        case "Conflict": "conflict"
        case "Turning point": "turningPoint"
        case "Resolution": "resolution"
        case "Lesson": "lesson"
        case "Product context": "productContext"
        case "What works": "whatWorks"
        case "What does not": "whatDoesNot"
        case "Verdict": "verdict"
        case "Thesis": "thesis"
        case "Argument": "argument"
        case "Counterpoint": "counterpoint"
        case "Implication": "implication"
        case "Closing": "closing"
        case "Goal": "goal"
        case "Requirements": "requirements"
        case "Step 1": "step1"
        case "Step 2": "step2"
        case "Common mistake": "commonMistake"
        case "Recap": "recap"
        default: name
        }
    }

    private func uniqueTemplateName(base: String) -> String {
        let names = Set(templates.map(\.name))
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") {
            counter += 1
        }
        return "\(base) \(counter)"
    }

    private func persistCustomTemplates() {
        Self.saveCustomTemplates(templates.filter { !$0.builtIn })
    }

    private static func mergedTemplates(builtIns: [FrameTemplate], customTemplates: [FrameTemplate]) -> [FrameTemplate] {
        let customized = Dictionary(
            customTemplates.compactMap { template in
                template.builtInSourceName.map { ($0, template) }
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let resolvedBuiltIns = builtIns.map { customized[$0.name] ?? $0 }
        let customOnly = customTemplates.filter { template in
            template.builtInSourceName == nil
                && !builtIns.contains { $0.name == template.name && $0.category == template.category }
        }
        return resolvedBuiltIns + customOnly
    }

    private static let customTemplatesKey = "FrameScript.customTemplates.v1"

    private static func loadCustomTemplates() -> [FrameTemplate] {
        guard let data = UserDefaults.standard.data(forKey: customTemplatesKey) else { return [] }
        return (try? JSONDecoder().decode([FrameTemplate].self, from: data)) ?? []
    }

    private static func saveCustomTemplates(_ templates: [FrameTemplate]) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: customTemplatesKey)
    }
}

enum ProjectStoreOrigin: Equatable {
    case normal
    case builtInDemo
}

@MainActor
@Observable
final class ProjectStore {
    enum ProjectFileError: Error {
        case missingFileURL
    }

    private var isConfigured = false
    private(set) var project: FrameProject
    private(set) var hasOpenProject = false
    private(set) var currentFileURL: URL?
    private(set) var saveState: SaveState = .saved
    private(set) var hasUnsavedFileChanges = false
    private(set) var origin: ProjectStoreOrigin = .normal
    private var segmentSplitMode: SegmentType = AppSettings.defaults.generalPreferences.defaultSplitMode
    private let projectWriter: (FrameProject, URL) throws -> Void

    init(
        project: FrameProject = SampleData.defaultProject,
        projectWriter: @escaping (FrameProject, URL) throws -> Void = FrameScriptFileStore.write
    ) {
        self.project = project
        self.projectWriter = projectWriter
        recalculateDurations(wordsPerMinute: AppSettings.defaults.editorPreferences.wordsPerMinute)
    }

    func setSegmentSplitMode(_ splitMode: SegmentType) {
        segmentSplitMode = splitMode
    }

    func configure(wordsPerMinute: Int) {
        isConfigured = true
        recalculateDurations(wordsPerMinute: wordsPerMinute)
    }

    var isBuiltInDemo: Bool { origin == .builtInDemo }

    func openProject(
        _ project: FrameProject,
        fileURL: URL?,
        wordsPerMinute: Int,
        markUnsaved: Bool,
        origin: ProjectStoreOrigin = .normal
    ) {
        self.project = project
        currentFileURL = fileURL
        self.origin = origin
        hasOpenProject = true
        recalculateDurations(wordsPerMinute: wordsPerMinute)
        hasUnsavedFileChanges = origin == .builtInDemo ? false : markUnsaved || fileURL == nil
        saveState = hasUnsavedFileChanges ? .edited : .saved
    }

    func closeProject() {
        hasOpenProject = false
        currentFileURL = nil
        hasUnsavedFileChanges = false
        saveState = .saved
        origin = .normal
    }

    var needsCloseConfirmation: Bool {
        hasOpenProject && !isBuiltInDemo && (hasUnsavedFileChanges || currentFileURL == nil)
    }

    func clearDemoDirtyState() {
        guard isBuiltInDemo else { return }
        hasUnsavedFileChanges = false
        saveState = .saved
    }

    func saveCurrentProject(wordsPerMinute: Int) throws {
        guard let currentFileURL else { throw ProjectFileError.missingFileURL }
        try saveCurrentProject(to: currentFileURL, wordsPerMinute: wordsPerMinute)
    }

    func saveCurrentProject(to url: URL, wordsPerMinute: Int) throws {
        prepareForSave(wordsPerMinute: wordsPerMinute)
        do {
            try projectWriter(project, url)
        } catch {
            hasUnsavedFileChanges = true
            saveState = .edited
            throw error
        }
        currentFileURL = url
        origin = .normal
        hasUnsavedFileChanges = false
        saveState = .saved
    }

    func duplicateProject(copySuffix: String) -> FrameProject {
        let copy = FrameProject(
            title: "\(project.title) \(copySuffix)",
            templateID: project.templateID,
            scenes: project.scenes.sortedByOrder.enumerated().map { index, scene in
                let sceneID = UUID()
                var oldToNewSegmentIDs: [UUID: UUID] = [:]
                let oldSegments = scene.textSegments.sortedByOrder
                let segments = oldSegments.enumerated().map { offset, segment in
                    let copy = TextSegment(
                        sceneID: sceneID,
                        order: offset,
                        sourceText: segment.sourceText,
                        segmentType: segment.segmentType,
                        timingEstimate: segment.timingEstimate
                    )
                    oldToNewSegmentIDs[segment.id] = copy.id
                    return copy
                }
                return Scene(
                    id: sceneID,
                    order: index,
                    sectionType: scene.sectionType,
                    title: scene.title,
                    scriptText: scene.scriptText,
                    notes: scene.notes,
                    estimatedDuration: scene.estimatedDuration,
                    textSegments: segments,
                    aiComments: scene.aiComments.map {
                        AIComment(
                            sceneID: sceneID,
                            segmentID: mappedSegmentID($0.segmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                            type: $0.type,
                            severity: $0.severity,
                            message: $0.message,
                            suggestion: $0.suggestion,
                            status: $0.status
                        )
                    },
                    bRollItems: scene.bRollItems.map {
                        BRollItem(
                            textAnchor: $0.textAnchor,
                            linkedSegmentID: mappedSegmentID($0.linkedSegmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                            templateType: $0.templateType,
                            sourceType: $0.sourceType,
                            descriptionText: $0.descriptionText,
                            mood: $0.mood,
                            framing: $0.framing,
                            motion: $0.motion,
                            duration: $0.duration,
                            notes: $0.notes,
                            status: $0.status
                        )
                    },
                    editingItems: scene.editingItems.map {
                        EditingItem(
                            textAnchor: $0.textAnchor,
                            linkedSegmentID: mappedSegmentID($0.linkedSegmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                            templateType: $0.templateType,
                            cutStyle: $0.cutStyle,
                            transition: $0.transition,
                            subtitleStyle: $0.subtitleStyle,
                            emphasis: $0.emphasis,
                            zoom: $0.zoom,
                            sfx: $0.sfx,
                            musicCue: $0.musicCue,
                            graphics: $0.graphics,
                            notes: $0.notes
                        )
                    }
                )
            },
            settingsOverride: project.settingsOverride,
            exportPresets: project.exportPresets
        )
        project = copy
        currentFileURL = nil
        hasOpenProject = true
        hasUnsavedFileChanges = true
        saveState = .edited
        return copy
    }

    func deleteCurrentProject() {
        project = SampleData.defaultProject
        currentFileURL = nil
        hasOpenProject = false
        hasUnsavedFileChanges = false
        saveState = .saved
    }

    var totalDuration: TimeInterval {
        project.scenes.reduce(0) { $0 + $1.estimatedDuration }
    }

    func selectedScene(id: UUID?) -> Scene? {
        guard let id else { return project.scenes.sortedByOrder.first }
        return project.scenes.first(where: { $0.id == id }) ?? project.scenes.sortedByOrder.first
    }

    func selectedSceneIndex(id: UUID?) -> Int? {
        guard let id else { return nil }
        return project.scenes.sortedByOrder.firstIndex(where: { $0.id == id })
    }

    func makeScene(order: Int, title: String) -> Scene {
        let id = UUID()
        return Scene(
            id: id,
            order: order,
            sectionType: .custom,
            title: title,
            scriptText: "",
            textSegments: []
        )
    }

    func addScene(_ scene: Scene, wordsPerMinute: Int) {
        project.scenes.append(scene)
        normalizeSceneOrder()
        updateCurrentSceneMetrics(sceneID: scene.id, wordsPerMinute: wordsPerMinute)
        markProjectDirty()
    }

    func addScene(_ scene: Scene, afterSortedIndex index: Int, wordsPerMinute: Int) {
        for existing in project.scenes where existing.order > index {
            existing.order += 1
        }
        scene.order = index + 1
        project.scenes.append(scene)
        normalizeSceneOrder()
        updateCurrentSceneMetrics(sceneID: scene.id, wordsPerMinute: wordsPerMinute)
        markProjectDirty()
    }

    func duplicate(_ scene: Scene, copySuffix: String) -> Scene {
        let copyID = UUID()
        var oldToNewSegmentIDs: [UUID: UUID] = [:]
        let oldSegments = scene.textSegments.sortedByOrder
        let segments = oldSegments.enumerated().map { offset, segment in
            let copy = TextSegment(
                sceneID: copyID,
                order: offset,
                sourceText: segment.sourceText,
                segmentType: segment.segmentType,
                timingEstimate: segment.timingEstimate
            )
            oldToNewSegmentIDs[segment.id] = copy.id
            return copy
        }
        return Scene(
            id: copyID,
            order: project.scenes.count,
            sectionType: scene.sectionType,
            title: "\(scene.title) \(copySuffix)",
            scriptText: scene.scriptText,
            notes: scene.notes,
            estimatedDuration: scene.estimatedDuration,
            textSegments: segments,
            aiComments: scene.aiComments.map {
                AIComment(
                    sceneID: copyID,
                    segmentID: mappedSegmentID($0.segmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                    type: $0.type,
                    severity: $0.severity,
                    message: $0.message,
                    suggestion: $0.suggestion,
                    status: $0.status
                )
            },
            bRollItems: scene.bRollItems.map {
                BRollItem(
                    textAnchor: $0.textAnchor,
                    linkedSegmentID: mappedSegmentID($0.linkedSegmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                    templateType: $0.templateType,
                    sourceType: $0.sourceType,
                    descriptionText: $0.descriptionText,
                    mood: $0.mood,
                    framing: $0.framing,
                    motion: $0.motion,
                    duration: $0.duration,
                    notes: $0.notes,
                    status: $0.status
                )
            },
            editingItems: scene.editingItems.map {
                EditingItem(
                    textAnchor: $0.textAnchor,
                    linkedSegmentID: mappedSegmentID($0.linkedSegmentID, oldSegments: oldSegments, newSegments: segments, oldToNewSegmentIDs: oldToNewSegmentIDs),
                    templateType: $0.templateType,
                    cutStyle: $0.cutStyle,
                    transition: $0.transition,
                    subtitleStyle: $0.subtitleStyle,
                    emphasis: $0.emphasis,
                    zoom: $0.zoom,
                    sfx: $0.sfx,
                    musicCue: $0.musicCue,
                    graphics: $0.graphics,
                    notes: $0.notes
                )
            }
        )
    }

    private func mappedSegmentID(
        _ oldID: UUID?,
        oldSegments: [TextSegment],
        newSegments: [TextSegment],
        oldToNewSegmentIDs: [UUID: UUID]
    ) -> UUID? {
        guard let oldID else { return nil }
        if let newID = oldToNewSegmentIDs[oldID] {
            return newID
        }
        guard let oldOrder = oldSegments.first(where: { $0.id == oldID })?.order else {
            return nil
        }
        return newSegments.min { abs($0.order - oldOrder) < abs($1.order - oldOrder) }?.id
    }

    func deleteScene(at sortedIndex: Int, wordsPerMinute: Int) {
        guard project.scenes.count > 1 else { return }
        let ordered = project.scenes.sortedByOrder
        guard let scene = ordered[safe: sortedIndex],
              let storageIndex = project.scenes.firstIndex(where: { $0.id == scene.id }) else {
            return
        }
        project.scenes.remove(at: storageIndex)
        normalizeSceneOrder()
        markProjectDirty()
    }

    func moveScene(at sortedIndex: Int, by delta: Int, wordsPerMinute: Int) {
        let ordered = project.scenes.sortedByOrder
        let destination = max(0, min(ordered.count - 1, sortedIndex + delta))
        guard sortedIndex != destination,
              let sourceScene = ordered[safe: sortedIndex],
              let destinationScene = ordered[safe: destination] else {
            return
        }
        swap(&sourceScene.order, &destinationScene.order)
        normalizeSceneOrder()
        markProjectDirty()
    }

    func markProjectDirty() {
        project.updatedAt = Date()
        hasUnsavedFileChanges = true
        saveState = .edited
    }

    func commitScriptText(_ text: String, sceneID: UUID, previousText: String? = nil) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        let oldText = previousText ?? scene.scriptText
        scene.scriptText = text
        refreshProductionAnchors(in: scene, previousText: oldText)
    }

    func updateCurrentSceneMetrics(sceneID: UUID, wordsPerMinute: Int) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        scene.estimatedDuration = DurationEstimator.estimate(text: scene.scriptText, wordsPerMinute: wordsPerMinute)
    }

    private func prepareForSave(wordsPerMinute: Int) {
        synchronizeTextSegments(splitMode: segmentSplitMode, wordsPerMinute: wordsPerMinute, markUnsaved: false)
        recalculateDurations(wordsPerMinute: wordsPerMinute)
        project.updatedAt = Date()
        saveState = .autosaving
    }

    func synchronizeTextSegments(splitMode: SegmentType, wordsPerMinute: Int, markUnsaved: Bool = true) {
        segmentSplitMode = splitMode
        for scene in project.scenes {
            synchronizeTextSegments(for: scene, splitMode: splitMode, wordsPerMinute: wordsPerMinute)
        }
        recalculateDurations(wordsPerMinute: wordsPerMinute)
        project.updatedAt = Date()
        if markUnsaved {
            hasUnsavedFileChanges = true
            saveState = .edited
        }
    }

    func synchronizeTextSegments(forSceneID sceneID: UUID, splitMode: SegmentType, wordsPerMinute: Int, markUnsaved: Bool = true) {
        segmentSplitMode = splitMode
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        synchronizeTextSegments(for: scene, splitMode: splitMode, wordsPerMinute: wordsPerMinute)
        scene.estimatedDuration = DurationEstimator.estimate(text: scene.scriptText, wordsPerMinute: wordsPerMinute)
        project.updatedAt = Date()
        if markUnsaved {
            hasUnsavedFileChanges = true
            saveState = .edited
        }
    }

    private func synchronizeTextSegments(for scene: Scene, splitMode: SegmentType, wordsPerMinute: Int) {
        let texts = TextSegmenter.segmentTexts(in: scene.scriptText, splitMode: splitMode)
        let oldSegments = scene.textSegments.sortedByOrder
        var unusedOldSegments = oldSegments
        var nextSegments: [TextSegment] = []

        for (index, text) in texts.enumerated() {
            let normalizedText = TextSegmenter.normalized(text)
            let exactIndex = unusedOldSegments.firstIndex {
                $0.segmentType == splitMode && TextSegmenter.normalized($0.sourceText) == normalizedText
            }
            let fallbackIndex = exactIndex ?? unusedOldSegments.firstIndex { $0.order == index }
            let segment = fallbackIndex.flatMap { unusedOldSegments.remove(at: $0) }
                ?? TextSegment(sceneID: scene.id, order: index, sourceText: text, segmentType: splitMode)

            segment.sceneID = scene.id
            segment.order = index
            segment.sourceText = text
            segment.segmentType = splitMode
            segment.timingEstimate = DurationEstimator.estimate(text: text, wordsPerMinute: wordsPerMinute)
            nextSegments.append(segment)
        }

        for item in scene.bRollItems { migrateLegacyLink(item, segments: oldSegments, text: scene.scriptText) }
        for item in scene.editingItems { migrateLegacyLink(item, segments: oldSegments, text: scene.scriptText) }
        refreshProductionAnchors(in: scene)

        scene.textSegments = nextSegments
    }

    private func refreshProductionAnchors(in scene: Scene, previousText: String? = nil) {
        for item in scene.bRollItems {
            guard item.textAnchor != nil else { continue }
            let repaired = previousText == nil
                ? TextAnchorRepair.repair(item.textAnchor, in: scene.scriptText)
                : TextAnchorRepair.repair(item.textAnchor, from: previousText!, to: scene.scriptText)
            guard let repaired else {
                item.textAnchor = nil
                item.linkedSegmentID = nil
                continue
            }
            item.textAnchor = repaired
        }
        for item in scene.editingItems {
            guard item.textAnchor != nil else { continue }
            let repaired = previousText == nil
                ? TextAnchorRepair.repair(item.textAnchor, in: scene.scriptText)
                : TextAnchorRepair.repair(item.textAnchor, from: previousText!, to: scene.scriptText)
            guard let repaired else {
                item.textAnchor = nil
                item.linkedSegmentID = nil
                continue
            }
            item.textAnchor = repaired
        }
    }

    func anchor(for segmentID: UUID, in scene: Scene) -> TextAnchor? {
        guard let segment = scene.textSegments.first(where: { $0.id == segmentID }) else { return nil }
        return TextAnchorRepair.anchor(for: segment, in: scene.scriptText)
    }

    func link(_ item: BRollItem, to segment: TextSegment, in scene: Scene) {
        guard let anchor = TextAnchorRepair.anchor(for: segment, in: scene.scriptText) else { return }
        item.textAnchor = anchor
        item.linkedSegmentID = segment.id
    }

    func link(_ item: EditingItem, to segment: TextSegment, in scene: Scene) {
        guard let anchor = TextAnchorRepair.anchor(for: segment, in: scene.scriptText) else { return }
        item.textAnchor = anchor
        item.linkedSegmentID = segment.id
    }

    func unlink(_ item: BRollItem) {
        item.textAnchor = nil
        item.linkedSegmentID = nil
    }

    func unlink(_ item: EditingItem) {
        item.textAnchor = nil
        item.linkedSegmentID = nil
    }

    private func migrateLegacyLink(_ item: BRollItem, segments: [TextSegment], text: String) {
        guard item.textAnchor == nil else { return }
        guard let linkedID = item.linkedSegmentID,
              let segment = segments.first(where: { $0.id == linkedID }),
              let anchor = TextAnchorRepair.anchor(for: segment, in: text) else {
            item.linkedSegmentID = nil
            return
        }
        item.textAnchor = anchor
    }

    private func migrateLegacyLink(_ item: EditingItem, segments: [TextSegment], text: String) {
        guard item.textAnchor == nil else { return }
        guard let linkedID = item.linkedSegmentID,
              let segment = segments.first(where: { $0.id == linkedID }),
              let anchor = TextAnchorRepair.anchor(for: segment, in: text) else {
            item.linkedSegmentID = nil
            return
        }
        item.textAnchor = anchor
    }


    private func recalculateDurations(wordsPerMinute: Int) {
        for scene in project.scenes {
            scene.estimatedDuration = DurationEstimator.estimate(
                text: scene.scriptText,
                wordsPerMinute: wordsPerMinute
            )
        }
    }

    private func normalizeSceneOrder() {
        for (index, scene) in project.scenes.sortedByOrder.enumerated() {
            scene.order = index
        }
    }

}

struct ProductionAnchorRange: Hashable {
    let startUTF16: Int
    let lengthUTF16: Int

    init(_ anchor: TextAnchor) {
        startUTF16 = anchor.startUTF16
        lengthUTF16 = anchor.lengthUTF16
    }
}

private struct ProductionMarkerGroup {
    var range: NSRange
    var itemIDs: [UUID]
}

struct ProductionAnchorSection<Item: Identifiable>: Identifiable {
    let anchor: TextAnchor
    let items: [Item]
    let firstItemOrder: Int

    var id: ProductionAnchorRange { ProductionAnchorRange(anchor) }
    var excerpt: String { anchor.selectedText }
}

private struct ProductionAnchorSectionAccumulator<Item: Identifiable> {
    let anchor: TextAnchor
    let firstItemOrder: Int
    var items: [Item]
}

enum ProductionAnchorGrouping {
    static func sections<Item: Identifiable>(
        for items: [Item],
        in text: String,
        anchor: (Item) -> TextAnchor?
    ) -> [ProductionAnchorSection<Item>] {
        var groups: [ProductionAnchorRange: ProductionAnchorSectionAccumulator<Item>] = [:]

        for (index, item) in items.enumerated() {
            guard let currentAnchor = TextAnchorRepair.current(anchor(item), in: text) else { continue }
            let range = ProductionAnchorRange(currentAnchor)
            if var group = groups[range] {
                group.items.append(item)
                groups[range] = group
            } else {
                groups[range] = ProductionAnchorSectionAccumulator(
                    anchor: currentAnchor,
                    firstItemOrder: index,
                    items: [item]
                )
            }
        }

        return groups.values
            .map { ProductionAnchorSection(anchor: $0.anchor, items: $0.items, firstItemOrder: $0.firstItemOrder) }
            .sorted {
                let lhsRange = $0.id
                let rhsRange = $1.id
                if lhsRange.startUTF16 != rhsRange.startUTF16 {
                    return lhsRange.startUTF16 < rhsRange.startUTF16
                }
                if lhsRange.lengthUTF16 != rhsRange.lengthUTF16 {
                    return lhsRange.lengthUTF16 < rhsRange.lengthUTF16
                }
                return $0.firstItemOrder < $1.firstItemOrder
            }
    }

    static func unlinkedItems<Item>(
        from items: [Item],
        in text: String,
        anchor: (Item) -> TextAnchor?
    ) -> [Item] {
        items.filter { TextAnchorRepair.current(anchor($0), in: text) == nil }
    }
}

@Observable
final class EditorState {
    var selectedMode: WorkspaceMode = .script
    var selectedSceneID: UUID?
    var selectedProductionItemIDs: [UUID] = []
    var isFocusModeEnabled = false
    private var scriptEditorStates: [ScriptEditorRestorationKey: ScriptEditorRestorationState] = [:]

    func scriptEditorState(sceneID: UUID, editorIdentity: UUID) -> ScriptEditorRestorationState? {
        scriptEditorStates[ScriptEditorRestorationKey(sceneID: sceneID, editorIdentity: editorIdentity)]
    }

    func setScriptEditorState(_ state: ScriptEditorRestorationState, sceneID: UUID, editorIdentity: UUID) {
        scriptEditorStates[ScriptEditorRestorationKey(sceneID: sceneID, editorIdentity: editorIdentity)] = state
    }
}

struct ScriptEditorRestorationKey: Hashable {
    let sceneID: UUID
    let editorIdentity: UUID
}

struct ScriptEditorRestorationState: Equatable {
    var selectedRange: NSRange
    var visibleOrigin: NSPoint
}

enum TextAnchorRepair {
    private static let contextLength = 48

    static func anchor(for segment: TextSegment, in text: String) -> TextAnchor? {
        let full = text as NSString
        guard full.length > 0, !segment.sourceText.isEmpty else { return nil }
        var searchStart = 0
        let candidates = TextSegmenter.segmentTexts(in: text, splitMode: segment.segmentType)
        for (index, candidate) in candidates.enumerated() {
            let searchRange = NSRange(location: searchStart, length: max(0, full.length - searchStart))
            let found = full.range(of: candidate, options: [], range: searchRange)
            guard found.location != NSNotFound else { return nil }
            if index == segment.order,
               TextSegmenter.normalized(candidate) == TextSegmenter.normalized(segment.sourceText) {
                return anchor(in: text, range: found)
            }
            searchStart = NSMaxRange(found)
        }
        return nil
    }

    static func anchor(in text: String, range: NSRange) -> TextAnchor? {
        let full = text as NSString
        let bounded = clamp(range, toLength: full.length)
        guard bounded.length > 0, NSMaxRange(bounded) <= full.length else { return nil }
        let selected = full.substring(with: bounded)
        return TextAnchor(
            startUTF16: bounded.location,
            lengthUTF16: bounded.length,
            selectedText: selected,
            prefixContext: full.substring(with: NSRange(location: max(0, bounded.location - contextLength), length: bounded.location - max(0, bounded.location - contextLength))),
            suffixContext: full.substring(with: NSRange(location: NSMaxRange(bounded), length: min(contextLength, full.length - NSMaxRange(bounded))))
        )
    }

    static func repair(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
        guard let anchor else { return nil }
        let full = text as NSString
        guard anchor.lengthUTF16 >= 0, anchor.startUTF16 >= 0, !anchor.selectedText.isEmpty else { return nil }
        if let current = current(anchor, in: text) {
            return self.anchor(in: text, range: current.nsRange)
        }
        let matchingRanges = occurrences(of: anchor.selectedText, in: full)
        let exactCandidates = matchingRanges
            .filter { hasAdjacentBoundary(anchor: anchor, text: full, range: $0) }
        if exactCandidates.count == 1, let exact = exactCandidates.first {
            return self.anchor(in: text, range: exact)
        }
        guard matchingRanges.isEmpty,
              let repairedRange = uniqueBoundaryRange(for: anchor, in: full) else {
            return nil
        }
        return self.anchor(in: text, range: repairedRange)
    }

    static func repair(_ anchor: TextAnchor?, from previousText: String, to text: String) -> TextAnchor? {
        guard let anchor,
              let current = current(anchor, in: previousText) else { return nil }
        guard previousText != text else { return self.anchor(in: text, range: current.nsRange) }
        let previous = previousText as NSString
        let updated = text as NSString
        let edit = contiguousEdit(from: previous, to: updated)
        let start = current.startUTF16
        let end = start + current.lengthUTF16
        let oldStart = edit.oldRange.location
        let oldEnd = NSMaxRange(edit.oldRange)
        let newEnd = NSMaxRange(edit.newRange)
        let delta = edit.newRange.length - edit.oldRange.length

        let repairedRange: NSRange?
        if oldEnd <= start {
            repairedRange = NSRange(location: start + delta, length: current.lengthUTF16)
        } else if oldStart >= end {
            repairedRange = current.nsRange
        } else if oldStart > start, oldEnd < end {
            repairedRange = NSRange(location: start, length: current.lengthUTF16 + delta)
        } else if oldStart <= start, oldEnd < end {
            repairedRange = NSRange(location: oldStart, length: end + delta - oldStart)
        } else if oldStart > start, oldEnd >= end {
            repairedRange = NSRange(location: start, length: newEnd - start)
        } else {
            repairedRange = nil
        }
        guard let repairedRange,
              repairedRange.location >= 0,
              repairedRange.length > 0,
              NSMaxRange(repairedRange) <= updated.length else { return nil }
        return self.anchor(in: text, range: repairedRange)
    }

    static func current(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
        guard let anchor, anchor.lengthUTF16 > 0, !anchor.selectedText.isEmpty else { return nil }
        let full = text as NSString
        let range = anchor.nsRange
        guard range.location >= 0,
              NSMaxRange(range) <= full.length,
              full.substring(with: range) == anchor.selectedText else {
            return nil
        }
        return anchor
    }

    static func isAnchor(_ anchor: TextAnchor, in segment: TextSegment, text: String) -> Bool {
        guard let segmentAnchor = self.anchor(for: segment, in: text) else { return false }
        return NSLocationInRange(anchor.startUTF16, segmentAnchor.nsRange)
    }

    private static func occurrences(of value: String, in text: NSString) -> [NSRange] {
        let searchRange = NSRange(location: 0, length: text.length)
        var matches: [NSRange] = []
        var searchStart = searchRange.location
        let searchEnd = NSMaxRange(searchRange)
        guard !value.isEmpty else { return matches }
        while searchStart < searchEnd {
            let found = text.range(of: value, options: [], range: NSRange(location: searchStart, length: searchEnd - searchStart))
            guard found.location != NSNotFound else { break }
            matches.append(found)
            searchStart = max(NSMaxRange(found), found.location + 1)
        }
        return matches
    }

    private static func contiguousEdit(from old: NSString, to new: NSString) -> (oldRange: NSRange, newRange: NSRange) {
        let commonLimit = min(old.length, new.length)
        var prefix = 0
        while prefix < commonLimit, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.length - prefix,
              suffix < new.length - prefix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        return (
            NSRange(location: prefix, length: old.length - prefix - suffix),
            NSRange(location: prefix, length: new.length - prefix - suffix)
        )
    }

    private static func hasAdjacentBoundary(anchor: TextAnchor, text: NSString, range: NSRange) -> Bool {
        hasPrefixBoundary(anchor, text: text, before: range.location)
            || hasSuffixBoundary(anchor, text: text, after: NSMaxRange(range))
    }

    private static func uniqueBoundaryRange(for anchor: TextAnchor, in text: NSString) -> NSRange? {
        let prefixes: [Int]
        if anchor.prefixContext.isEmpty {
            prefixes = [0]
        } else {
            prefixes = occurrences(of: anchor.prefixContext, in: text).map(NSMaxRange)
        }
        let suffixes: [Int]
        if anchor.suffixContext.isEmpty {
            suffixes = [text.length]
        } else {
            suffixes = occurrences(of: anchor.suffixContext, in: text).map(\.location)
        }
        let candidates: [NSRange] = prefixes.flatMap { prefixEnd in
            suffixes.compactMap { suffixStart in
                guard prefixEnd < suffixStart else { return nil }
                return NSRange(location: prefixEnd, length: suffixStart - prefixEnd)
            }
        }
        guard candidates.count == 1, let range = candidates.first else { return nil }
        return range
    }

    private static func hasPrefixBoundary(_ anchor: TextAnchor, text: NSString, before location: Int) -> Bool {
        guard !anchor.prefixContext.isEmpty else { return location == 0 }
        let length = (anchor.prefixContext as NSString).length
        guard location >= length else { return false }
        return text.substring(with: NSRange(location: location - length, length: length)) == anchor.prefixContext
    }

    private static func hasSuffixBoundary(_ anchor: TextAnchor, text: NSString, after location: Int) -> Bool {
        guard !anchor.suffixContext.isEmpty else { return location == text.length }
        let length = (anchor.suffixContext as NSString).length
        guard location + length <= text.length else { return false }
        return text.substring(with: NSRange(location: location, length: length)) == anchor.suffixContext
    }

    private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        let maxLength = max(0, length - location)
        return NSRange(location: location, length: min(max(0, range.length), maxLength))
    }
}

@MainActor
@Observable
final class SettingsStore {
    typealias SettingsEncoder = (AppSettings) throws -> Data
    typealias SettingsDecoder = (Data) throws -> AppSettings

    var settings: AppSettings {
        didSet { save() }
    }

    private(set) var errorEvent: AppError?
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder: SettingsEncoder
    private var errorReporter: ((AppError) -> Void)?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Settings")

    init(
        settings: AppSettings? = nil,
        userDefaults: UserDefaults = .standard,
        key: String = "FrameScript.settings.v1",
        encoder: @escaping SettingsEncoder = { try JSONEncoder().encode($0) },
        decoder: SettingsDecoder = { try JSONDecoder().decode(AppSettings.self, from: $0) }
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.encoder = encoder
        if let settings {
            self.settings = settings
        } else if let data = userDefaults.data(forKey: key) {
            do {
                self.settings = try decoder(data)
            } catch {
                self.settings = .defaults
                self.errorEvent = AppError(
                    kind: .settingsRead,
                    context: AppErrorContext(diagnosticCode: Self.diagnosticCode(error))
                )
                logger.error("Settings read failed. Diagnostic: \(Self.diagnosticCode(error), privacy: .private)")
            }
        } else {
            self.settings = .defaults
        }
    }

    func reset() {
        settings = .defaults
    }

    func setErrorReporter(_ reporter: @escaping (AppError) -> Void) {
        errorReporter = reporter
        if let errorEvent { reporter(errorEvent) }
    }

    private func save() {
        do {
            let data = try encoder(settings)
            userDefaults.set(data, forKey: key)
            errorEvent = nil
        } catch {
            let appError = AppError(
                kind: .settingsWrite,
                context: AppErrorContext(diagnosticCode: Self.diagnosticCode(error))
            )
            errorEvent = appError
            errorReporter?(appError)
            logger.error("Settings write failed. Diagnostic: \(Self.diagnosticCode(error), privacy: .private)")
        }
    }

    private static func diagnosticCode(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

@Observable
final class AIState {
    var isAnalyzing = false
    var didFailMostRecentAnalysis = false
}

@Observable
final class WindowState {
    var isSidebarVisible = true
    var isCommandPalettePresented = false
    var isSettingsPresented = false
    var isShortcutsPresented = false
    var requestedSettingsTab: SettingsTab = .general
    var requestedSettingsHighlightKey: String?
    var settingsRequestID = UUID()
    var newProjectRequest: NewProjectRequest?
    var isExportPresented = false
    var pendingSettingsTab: SettingsTab?
    var pendingSettingsHighlightKey: String?
}

enum SaveState: String {
    case saved = "Saved"
    case edited = "Edited"
    case autosaving = "Saving..."
}

enum TextSegmenter {
    static func segmentTexts(in text: String, splitMode: SegmentType) -> [String] {
        switch splitMode {
        case .scene:
            let trimmed = trimmed(text)
            return trimmed.isEmpty ? [] : [trimmed]
        case .paragraph:
            return text
                .components(separatedBy: CharacterSet.newlines)
                .map(trimmed)
                .filter { !$0.isEmpty }
        case .sentence:
            return sentenceTexts(in: text)
        }
    }

    static func normalized(_ text: String) -> String {
        trimmed(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func sentenceTexts(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previousWasTerminator = false
        let terminators = CharacterSet(charactersIn: ".!?…")
        let closers = CharacterSet(charactersIn: "\"'»”’)]}")

        for scalar in text.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                previousWasTerminator = true
                continue
            }
            if previousWasTerminator, closers.contains(scalar) {
                continue
            }
            if previousWasTerminator, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                appendTrimmed(current, to: &sentences)
                current = ""
                previousWasTerminator = false
                continue
            }
            previousWasTerminator = false
        }

        appendTrimmed(current, to: &sentences)
        return sentences
    }

    private static func appendTrimmed(_ text: String, to sentences: inout [String]) {
        let value = trimmed(text)
        if !value.isEmpty {
            sentences.append(value)
        }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Array where Element == Scene {
    var sortedByOrder: [Scene] {
        sorted { $0.order < $1.order }
    }
}

extension Array where Element == TextSegment {
    var sortedByOrder: [TextSegment] {
        sorted { $0.order < $1.order }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
