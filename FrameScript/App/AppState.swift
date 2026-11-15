import Foundation
import AppKit
import FrameScriptCore
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
/// `.declined` means the user already declined this exact on-disk hash and a
/// background autosave must skip it without prompting again.
enum ProjectFileWriteAuthorization {
    case proceed
    case handled
    case declined
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
    typealias ConfirmationHandler = @MainActor (_ title: String, _ message: String) -> Bool
    typealias SaveAsDestinationProvider = @MainActor () -> URL?

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
    /// F10 recording state and the obs-websocket client.
    let recording: RecordingController
    /// Seam for recording -> teleprompter (F8/F9); tests replace it with a fake.
    var recordingTeleprompter: any RecordingTeleprompterPresenting = LiveRecordingTeleprompter()
    /// Last accepted teleprompter learning sample, used to drop duplicate
    /// reports of the same reading.
    var lastTeleprompterLearningSignature: TeleprompterLearningSignature?
    private let aiProviderConfigurationStore: AIProviderConfigurationStore
    let securityScope: SecurityScopedResourceAccess
    private let exportFolderBookmarkCreator: ExportFolderBookmarkCreator
    private let exportFolderBookmarkResolver: ExportFolderBookmarkResolver
    private let closeConfirmation: CloseConfirmation?
    let externalChangeConfirmation: ExternalProjectChangeConfirmation?
    /// Test/QA seam for the generic yes/no alert. Production leaves it `nil` and
    /// the alert runs modally.
    private let confirmationHandler: ConfirmationHandler?
    let saveProjectCopyHandler: (@MainActor () -> Bool)?
    let saveAsDestinationProvider: SaveAsDestinationProvider?

    var templates: [FrameTemplate]
    private let builtInTemplates: [FrameTemplate]
    /// True when the persisted custom templates blob could not be decoded. The
    /// blob is preserved under `<key>.unreadable-backup` and saving stays
    /// disabled until the user makes an explicit template change.
    private var didFailToLoadCustomTemplates = false
    private static var customTemplatesSavingIsBlocked = false
    private var autosaveTask: Task<Void, Never>?
    var trackedProjectFileURL: URL?
    var trackedProjectFileSnapshot: ProjectFileSnapshot?
    var declinedExternalProjectSnapshot: ProjectFileSnapshot?
    /// URL whose unreadable-file prompt the user already cancelled. There is no
    /// on-disk hash to remember for an unreadable file, so the URL stands in for
    /// it and only background autosaves honour it; a manual save asks again.
    var declinedUnreadableProjectFileURL: URL?
    /// URL of a file whose "missing" error was already shown, so the one-shot
    /// notice is not repeated on every autosave.
    var reportedMissingProjectFileURL: URL?
    /// Last project file that failed to open. The backups window lists its
    /// backups even when no project is open.
    var failedOpenProjectFileURL: URL?
    var projectFileMonitor: ProjectFileMonitor?
    var externalChangePromptIsActive = false
    var isConfirmingTermination = false
    var isTerminatingApplication = false
    weak var projectWindow: NSWindow?
    var projectWindowCloseObserver: NSObjectProtocol?
    private var segmentRebuildTasks: [UUID: Task<Void, Never>] = [:]
    private var autocompleteCooldowns: [AIProviderKind: Date] = [:]
    var autocompleteIssue: AutocompleteProviderIssue?
    var autocompleteConfigurationVersion = 0
    var autocompleteCompletionDelay: Duration = .milliseconds(280)
    var autocompleteNow: () -> Date = Date.init
#if DEBUG
    private var didApplyUITestLaunchArguments = false
    /// UI-test-only interface language. Kept out of `settings` so launching a
    /// test never rewrites the user's persisted app language.
    private var uiTestLanguageOverride: AppLanguage?
#endif
    private var appResignationObserver: NSObjectProtocol?

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
        recording: RecordingController? = nil,
        aiProviderConfigurationStore: AIProviderConfigurationStore = AIProviderConfigurationStore(),
        securityScope: SecurityScopedResourceAccess = .live,
        closeConfirmation: CloseConfirmation? = nil,
        externalChangeConfirmation: ExternalProjectChangeConfirmation? = nil,
        confirmationHandler: ConfirmationHandler? = nil,
        saveProjectCopyHandler: (@MainActor () -> Bool)? = nil,
        saveAsDestinationProvider: SaveAsDestinationProvider? = nil,
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
        self.recording = recording ?? RecordingController()
        self.aiProviderConfigurationStore = aiProviderConfigurationStore
        self.securityScope = securityScope
        self.closeConfirmation = closeConfirmation
        self.externalChangeConfirmation = externalChangeConfirmation
        self.confirmationHandler = confirmationHandler
        self.saveProjectCopyHandler = saveProjectCopyHandler
        self.saveAsDestinationProvider = saveAsDestinationProvider
        self.exportFolderBookmarkCreator = exportFolderBookmarkCreator
        self.exportFolderBookmarkResolver = exportFolderBookmarkResolver
        self.builtInTemplates = templates.filter(\.builtIn)
        let loadedCustomTemplates = Self.loadCustomTemplates()
        self.templates = Self.mergedTemplates(builtIns: templates.filter(\.builtIn), customTemplates: loadedCustomTemplates.templates)
        self.didFailToLoadCustomTemplates = loadedCustomTemplates.failed
        self.windowState.isSidebarVisible = settingsStore.settings.windowPreferences.sidebarDefaultVisible
        self.projectStore.setSegmentSplitMode(settingsStore.settings.generalPreferences.defaultSplitMode)
        self.projectStore.durationConfigurationProvider = { [weak self] scene in
            self?.durationConfiguration(for: scene) ?? .standard
        }
        self.projectStore.markAllDurationsDirty()
        self.projectStore.markupReviewRefreshHandler = { [weak self] in
            self?.scheduleRhythmReview()
        }
        settingsStore.setErrorReporter { [weak errorCenter] error in
            errorCenter?.present(error)
        }
        SubscriptionAIRuntime.shared.attach(appState: self)
        attachRecordingContext()
        self.recording.teleprompterHook = self
        TeleprompterPresenter.shared.readingSessionReporter = self
    }

    func configure() {
        let arguments = ProcessInfo.processInfo.arguments
        recentProjectStore.load()
        if didFailToLoadCustomTemplates {
            showNotice(.customTemplatesUnreadable)
            didFailToLoadCustomTemplates = false
        }
        if SandboxDataMigration.consumePendingReadFailureNotice() {
            showNotice(.sandboxMigrationReadFailed)
        }
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
            wordsPerMinute: currentDurationWordsPerMinute
        )
#if DEBUG
        if arguments.contains("--framescript-ui-test-language-english") {
            uiTestLanguageOverride = .english
        } else if arguments.contains("--framescript-ui-test-language-spanish") {
            uiTestLanguageOverride = .spanish
        } else if arguments.contains("--framescript-ui-test-language-russian") {
            uiTestLanguageOverride = .russian
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
            openRecentProject(entry, reportsMissingNotice: false, presentsErrors: true)
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

    var isShortcutsPresented: Bool {
        get { windowState.isShortcutsPresented }
        set { windowState.isShortcutsPresented = newValue }
    }

    var saveState: SaveState {
        projectStore.saveState
    }

    var currentLanguage: AppLanguage {
#if DEBUG
        if let uiTestLanguageOverride { return uiTestLanguageOverride }
#endif
        return settings.generalPreferences.language
    }

    /// `.system` resolved to a concrete language. Use this for content, prompts
    /// and durations; a raw `.system` value must never leak into them.
    var resolvedCurrentLanguage: AppLanguage {
        L10n.resolve(currentLanguage)
    }

    var autocompleteConfigurationEligibility: AutocompleteConfigurationEligibility {
        guard settings.aiPreferences.enableInlineAutocomplete else { return .blockedPreferenceDisabled }
        let provider = settings.aiPreferences.provider
        guard provider != .disabled else { return .blockedProviderDisabled }
        // Inline autocomplete stays on the API providers. Subscription CLIs
        // take seconds and must never run while typing.
        guard !provider.isSubscriptionBacked else { return .blockedProviderDisabled }
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
            language: resolvedCurrentLanguage,
            sceneNameResolver: { [weak self] name in self?.localizedTemplateSceneName(name) ?? name }
        )
        willReplaceOpenProject()
        projectStore.openProject(project, fileURL: nil, wordsPerMinute: durationWordsPerMinute(for: project), markUnsaved: true, recalculateDurations: false)
        resetProjectFileTracking()
        projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: currentDurationWordsPerMinute)
        setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id), mode: .script)
        editorState.isFocusModeEnabled = false
        windowState.newProjectRequest = nil
    }

    func openDemoProject() {
        guard prepareForProjectReplacement() else { return }
        let project = SampleData.demoProject(language: resolvedCurrentLanguage)
        willReplaceOpenProject()
        projectStore.openProject(
            project,
            fileURL: nil,
            wordsPerMinute: durationWordsPerMinute(for: project),
            markUnsaved: false,
            origin: .builtInDemo,
            recalculateDurations: false
        )
        resetProjectFileTracking()
        projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: currentDurationWordsPerMinute)
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
            let opened = try securityScope.withAccess(to: url) {
                try FrameScriptFileStore.readWithData(from: url)
            }
            let project = opened.project
            // The file was read and decoded: only now may the open project and
            // its teleprompter/AI state be dropped.
            willReplaceOpenProject()
            projectStore.openProject(
                project,
                fileURL: url,
                wordsPerMinute: durationWordsPerMinute(for: project),
                markUnsaved: false,
                recalculateDurations: false
            )
            rememberRecentProject(url)
            projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: currentDurationWordsPerMinute, markUnsaved: false)
            setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id))
            startTrackingProjectFile(at: url, data: opened.data)
            failedOpenProjectFileURL = nil
        } catch {
            Self.projectFilesLogger.error("Operation project-open failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            failedOpenProjectFileURL = url
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
                let opened = try FrameScriptFileStore.readWithData(from: url)
                let project = opened.project
                willReplaceOpenProject()
                projectStore.openProject(
                    project,
                    fileURL: url,
                    wordsPerMinute: durationWordsPerMinute(for: project),
                    markUnsaved: false,
                    recalculateDurations: false
                )
                rememberRecentProject(url)
                projectStore.synchronizeTextSegments(splitMode: settings.generalPreferences.defaultSplitMode, wordsPerMinute: currentDurationWordsPerMinute, markUnsaved: false)
                setEditorContextAfterFlush(sceneID: .some(project.scenes.sortedByOrder.first?.id))
                startTrackingProjectFile(at: url, data: opened.data)
                failedOpenProjectFileURL = nil
            }
        } catch RecentProjectStoreError.missingFile {
            Self.projectFilesLogger.notice("Recent project file is missing; removing the entry.")
            recentProjectStore.remove(id: entry.id)
            consumeRecentProjectStoreError()
            if reportsMissingNotice { showNotice(.recentMissingRemoved) }
        } catch let error as RecentProjectStoreError {
            Self.projectFilesLogger.error("Operation recent-project-open failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            failedOpenProjectFileURL = URL(fileURLWithPath: entry.lastKnownPath)
            if presentsErrors { errorCenter.present(AppError.recent(error, recentID: entry.id)) }
        } catch {
            Self.projectFilesLogger.error("Operation project-open failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            failedOpenProjectFileURL = URL(fileURLWithPath: entry.lastKnownPath)
            if presentsErrors {
                errorCenter.present(AppError.project(error, fileURL: URL(fileURLWithPath: entry.lastKnownPath), operation: .read))
            }
        }
    }

    func importProject() {
        openProject()
    }

    /// Waits for a background autosave and adopts its bytes as the new
    /// external-change baseline, so the pre-write check does not mistake our own
    /// write for an external edit.
    func syncPendingBackgroundSave() {
        guard projectStore.waitForBackgroundWrite() else { return }
        if let url = projectStore.currentFileURL, let data = projectStore.lastSavedFileData {
            recordProjectFileSnapshot(data: data, at: url)
        }
    }

    @discardableResult
    func saveProject() -> Bool {
        guard hasOpenProject else { return false }
        flushActiveEditorBoundary(saveImmediately: false)
        syncPendingBackgroundSave()
        guard let url = projectStore.currentFileURL else { return saveProjectAs() }
        switch prepareProjectFileForWrite() {
        case .proceed:
            break
        case .handled:
            return true
        case .declined, .failed:
            return false
        }
        do {
            try securityScope.withAccess(to: url) {
                try projectStore.saveCurrentProject(wordsPerMinute: currentDurationWordsPerMinute)
            }
            recordProjectFileSnapshotAfterSave(at: url)
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
        syncPendingBackgroundSave()
        let url: URL
        if let saveAsDestinationProvider {
            guard let chosenURL = saveAsDestinationProvider() else { return false }
            url = chosenURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.frameScript]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = "\(project.title).fscr"
            panel.message = localized("dialog.saveProject.message")
            guard panel.runModal() == .OK, let chosenURL = panel.url else { return false }
            url = chosenURL
        }
        do {
            try projectStore.saveCurrentProject(to: url, wordsPerMinute: currentDurationWordsPerMinute)
            startTrackingProjectFileAfterSave(at: url)
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

    @discardableResult
    func saveExport(format: ExportFormat, preferences: ExportPreferences, to url: URL) -> Bool {
        guard hasOpenProject else { return false }
        // The export reads the project's text, so commit the editor's pending
        // characters first without triggering a disk save.
        flushActiveEditorBoundary(saveImmediately: false)
        // Exports read `scene.estimatedDuration`; refresh it with the learned
        // pace and pause defaults so a recent edit cannot export a stale number.
        refreshDurationEstimates()
        do {
            let rendered = dependencies.exportService.render(project: project, format: format, preferences: preferences, language: resolvedCurrentLanguage)
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            Self.exportLogger.error("Operation export-write failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.present(AppError(
                kind: .export,
                context: AppErrorContext(fileName: url.lastPathComponent, diagnosticCode: diagnosticCode(for: error)),
                recoveryAction: .chooseExportFolder
            ))
            return false
        }
    }

    @discardableResult
    func copyExportToClipboard(format: ExportFormat, preferences: ExportPreferences) -> Bool {
        guard hasOpenProject else { return false }
        flushActiveEditorBoundary(saveImmediately: false)
        // Same guarantee as `saveExport`: the copied text uses the same
        // fresh, learned-pace estimate the UI shows.
        refreshDurationEstimates()
        let rendered = dependencies.exportService.render(project: project, format: format, preferences: preferences, language: resolvedCurrentLanguage)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(rendered, forType: .string) else {
            Self.exportLogger.error("Operation export-clipboard-write failed. Code: clipboard-write")
            errorCenter.present(AppError(kind: .export, context: AppErrorContext(diagnosticCode: "clipboard-write")))
            return false
        }
        return true
    }

    /// Discards local edits after confirmation and re-reads the file from disk.
    @discardableResult
    func revertToSaved() -> Bool {
        guard hasOpenProject else { return false }
        flushActiveEditorBoundary(saveImmediately: false)
        // Revert reads the file again; a pending write must land (or be
        // consumed) before that read or memory/disk can diverge silently.
        syncPendingBackgroundSave()
        guard confirm(title: localized("dialog.revertToSaved.title"), message: localized("dialog.revertToSaved.message")) else {
            return false
        }
        return reloadProjectFromDisk()
    }

    func duplicateProject() {
        guard hasOpenProject else { return }
        // Commit editor text and settle the write the flush starts before the
        // copy replaces the document id/url.
        flushActiveEditorBoundary()
        syncPendingBackgroundSave()
        let copy = projectStore.duplicateProject(copySuffix: localized("templates.copySuffix"))
        editorState.resetScriptEditorStates()
        resetProjectFileTracking()
        setEditorContextAfterFlush(sceneID: .some(copy.scenes.sortedByOrder.first?.id))
    }

    func selectPreviousScene() {
        let ordered = project.scenes.sortedByOrder
        guard let index = selectedSceneIndex, ordered.indices.contains(index - 1) else { return }
        selectScene(ordered[index - 1].id)
    }

    @discardableResult
    func closeProject() -> Bool {
        guard hasOpenProject else { return true }
        guard !refuseProjectChangeWhileRecording() else { return false }
        flushActiveEditorBoundary()
        // Autosave is asynchronous: settle it before asking Save/Don't Save so
        // the prompt reflects the true dirty state and no write outlives close.
        syncPendingBackgroundSave()
        guard confirmCloseProjectIfNeeded() else { return false }
        NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: self)
        if let url = projectStore.currentFileURL {
            BackupsCenter.forget(projectID: BackupsCenter.projectID(for: projectStore.project, fileURL: url))
        }
        projectStore.closeProject()
        editorState.resetScriptEditorStates()
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
        guard !refuseProjectChangeWhileRecording() else { return }
        flushActiveEditorBoundary()
        syncPendingBackgroundSave()
        if projectStore.needsCloseConfirmation {
            // Delete discards the open project, so unsaved edits need the same
            // Save / Don't Save / Cancel decision as closing it, even when the
            // delete-confirmation preference is off.
            guard confirmCloseProjectIfNeeded() else { return }
        } else if settings.generalPreferences.confirmBeforeDeleting,
                  !confirm(title: localized("dialog.deleteProject.title"), message: localized("dialog.deleteProject.message")) {
            return
        }
        NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: self)
        if let url = projectStore.currentFileURL {
            BackupsCenter.forget(projectID: BackupsCenter.projectID(for: projectStore.project, fileURL: url))
        }
        transitionEditorContext(sceneID: .some(nil)) {
            projectStore.deleteCurrentProject()
        }
        editorState.resetScriptEditorStates()
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
        guard !refuseProjectChangeWhileRecording() else { return false }
        flushActiveEditorBoundary()
        syncPendingBackgroundSave()
        guard !hasOpenProject || confirmCloseProjectIfNeeded() else { return false }
        return true
    }

    /// Drops per-project runtime state and tells observers (AI runtime,
    /// teleprompter) that the open document is about to be replaced.
    ///
    /// Call it only after the replacement document has been read or built, just
    /// before `projectStore.openProject(...)`. Posting it in
    /// `prepareForProjectReplacement` would tear down the current project's
    /// teleprompter and AI run even when the open then fails and the old
    /// project stays open.
    private func willReplaceOpenProject() {
        aiState.isAnalyzing = false
        editorState.resetScriptEditorStates()
        NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: self)
    }

    func touchProject() {
        projectStore.markProjectDirty()
        scheduleAutosaveIfNeeded()
    }

    /// Refuses to close, replace or delete a project while a take is being
    /// recorded: finalising the take would write it into the wrong project.
    /// Returns true when the change must be refused.
    @discardableResult
    func refuseProjectChangeWhileRecording() -> Bool {
        guard recording.hasActiveTake else { return false }
        errorCenter.present(AppError(kind: .recordingActive))
        return true
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
        // Typing must not parse the whole script: one debounced pass computes
        // word count and duration off the main actor once the user stops, using
        // the learned pace for the project language (F11).
        scheduleSceneMetricsUpdate(sceneID: sceneID)
        RhythmReviewCenter.shared.invalidate(sceneID: sceneID)
        scheduleRhythmReview()
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
            wordsPerMinute: currentDurationWordsPerMinute,
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
            projectStore.addScene(scene, wordsPerMinute: currentDurationWordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func addScene(after sceneID: UUID) {
        guard hasOpenProject else { return }
        let ordered = project.scenes.sortedByOrder
        let targetIndex = ordered.firstIndex { $0.id == sceneID } ?? max(0, ordered.count - 1)
        let scene = projectStore.makeScene(order: targetIndex + 1, title: localized("templates.defaultScene"))
        transitionEditorContext(sceneID: .some(scene.id), mode: .script) {
            projectStore.addScene(scene, afterSortedIndex: targetIndex, wordsPerMinute: currentDurationWordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func duplicateSelectedScene() {
        guard let scene = selectedScene else { return }
        let copy = projectStore.duplicate(scene, copySuffix: localized("templates.copySuffix"))
        transitionEditorContext(sceneID: .some(copy.id)) {
            projectStore.addScene(copy, wordsPerMinute: currentDurationWordsPerMinute)
            scheduleAutosaveIfNeeded()
        }
    }

    func deleteSelectedScene() {
        if recording.activeSceneID == selectedScene?.id,
           refuseProjectChangeWhileRecording() {
            return
        }
        // Nothing to delete: do not ask for confirmation for a no-op.
        guard let selectedSceneIndex else { return }
        if settings.generalPreferences.confirmBeforeDeleting,
           !confirm(title: localized("dialog.deleteScene.title"), message: localized("dialog.deleteScene.message")) {
            return
        }
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
            projectStore.deleteScene(at: selectedSceneIndex, wordsPerMinute: currentDurationWordsPerMinute)
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
        projectStore.moveScene(at: selectedSceneIndex, by: delta, wordsPerMinute: currentDurationWordsPerMinute)
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
        let projectID = project.id
        let sceneID = scene.id
        guard let target = productionSuggestionTarget(in: scene) else {
            errorCenter.present(AppError(kind: .invalidProjectData))
            return
        }
        // The suggestion is appended to the scene that was current when the
        // request started; a project switch or a text edit invalidates it.
        let sourceText = scene.scriptText

        let schema = kind == .bRollGeneration
            ? "Return only one JSON object with string fields: source, description, notes. Source must be one of: \(BRollSourceType.allCases.map(\.rawValue).joined(separator: ", "))."
            : "Return only one JSON object with string fields: description, notes."
        let context = settings.aiPreferences.privacyMode
            ? target.selectedText
            : "Scene: \(scene.title)\nFull scene: \(sourceText)\nTarget anchor: \(target.selectedText)"
        do {
            let provider = settings.aiPreferences.provider
            let apiKey = provider.isSubscriptionBacked
                ? ""
                : try dependencies.providerCredentials.apiKey(for: provider)
            let response = try await dependencies.llmProvider.complete(request: LLMRequest(
                task: kind,
                provider: provider,
                baseURL: settings.aiPreferences.baseURL,
                systemPrompt: "\(PromptBuilder().systemPrompt(for: kind, language: PromptBuilder().responseLanguage(for: sourceText, fallback: resolvedCurrentLanguage))) \(schema) Do not use Markdown fences.",
                userPrompt: context,
                model: settings.aiPreferences.model,
                temperature: settings.aiPreferences.temperature,
                maxTokens: settings.aiPreferences.maxTokens
            ), apiKey: apiKey)
            let data = try Self.structuredJSONData(from: response.text)
            guard project.id == projectID else { return }
            guard let currentScene = project.scenes.first(where: { $0.id == sceneID }) else { return }
            // The anchor was computed against the text that was sent. If the
            // script changed meanwhile, appending it would point at the wrong
            // words.
            guard let currentAnchor = TextAnchorRepair.current(target, in: currentScene.scriptText) else {
                errorCenter.present(AppError(kind: .invalidProjectData))
                return
            }
            switch kind {
            case .bRollGeneration:
                let value = try JSONDecoder().decode(GeneratedBRollSuggestion.self, from: data)
                guard !value.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyDescription }
                let source = BRollSourceType.allCases.first { $0.rawValue.caseInsensitiveCompare(value.source) == .orderedSame } ?? .custom
                currentScene.bRollItems.append(BRollItem(textAnchor: currentAnchor, linkedSegmentID: nil, templateType: "", sourceType: source, descriptionText: value.description, notes: value.notes))
                selectMode(.bRoll)
            case .editingGeneration:
                let value = try JSONDecoder().decode(GeneratedEditingSuggestion.self, from: data)
                guard !value.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GenerationError.emptyDescription }
                currentScene.editingItems.append(EditingItem(textAnchor: currentAnchor, linkedSegmentID: nil, templateType: "", cutStyle: value.description, transition: "", subtitleStyle: "", notes: value.notes))
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
        let projectID = project.id
        let sceneID = scene.id
        aiState.isAnalyzing = true
        aiState.didFailMostRecentAnalysis = false
        defer { aiState.isAnalyzing = false }
        do {
            let apiKey = try providerAPIKeyIfNeeded()
            let comments = settings.aiPreferences.provider == .disabled
                ? disabledAIComments(for: scene)
                : try await dependencies.analysisService.analyze(scene: scene, project: project, settings: settings.aiPreferences, interfaceLanguage: resolvedCurrentLanguage, apiKey: apiKey)
            // The project may have been replaced while the request was running.
            guard project.id == projectID,
                  let currentScene = project.scenes.first(where: { $0.id == sceneID }) else { return }
            currentScene.aiComments = comments
            touchProject()
        } catch {
            guard project.id == projectID else { return }
            aiState.didFailMostRecentAnalysis = true
            errorCenter.present(AppError.ai(error))
        }
    }

    func analyzeFullScript() async {
        guard !aiState.isAnalyzing else { return }
        let projectID = project.id
        // Work on the snapshot that was sent, and never touch the open project
        // after an await if it changed in the meantime.
        let snapshot = project
        aiState.isAnalyzing = true
        aiState.didFailMostRecentAnalysis = false
        defer { aiState.isAnalyzing = false }
        do {
            let apiKey = try providerAPIKeyIfNeeded()
            for scene in snapshot.scenes.sortedByOrder {
                guard project.id == projectID else { return }
                let comments = settings.aiPreferences.provider == .disabled
                    ? disabledAIComments(for: scene)
                    : try await dependencies.analysisService.analyze(scene: scene, project: snapshot, settings: settings.aiPreferences, interfaceLanguage: resolvedCurrentLanguage, apiKey: apiKey)
                guard project.id == projectID,
                      let currentScene = project.scenes.first(where: { $0.id == scene.id }) else { return }
                currentScene.aiComments = comments
            }
            guard project.id == projectID else { return }
            touchProject()
        } catch {
            guard project.id == projectID else { return }
            aiState.didFailMostRecentAnalysis = true
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
        let provider = settings.aiPreferences.provider
        guard provider != .disabled else { return "" }
        // Subscription-backed providers authenticate through the local CLI.
        guard !provider.isSubscriptionBacked else { return "" }
        return try providerAPIKey(for: provider)
    }

    func performRecovery(_ action: AppRecoveryAction) {
        switch action {
        case .saveAs:
            _ = saveProjectAs()
        case .chooseExportFolder:
            chooseDefaultExportFolder()
        case .openAISettings:
            openSettings(tab: .ai)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .removeRecent(let id):
            removeRecentProject(id: id)
        case .openBackups(let url):
            showBackupsWindow(for: url)
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
                wordsPerMinute: self.currentDurationWordsPerMinute,
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
            wordsPerMinute: currentDurationWordsPerMinute,
            markUnsaved: false
        )
    }

    func performAutosave() {
        guard !isTerminatingApplication, !isConfirmingTermination,
              settings.generalPreferences.autosaveEnabled,
              !projectStore.isBuiltInDemo,
              let url = projectStore.currentFileURL,
              projectStore.hasUnsavedFileChanges else {
            return
        }
        // A write that is already running carries the edits up to its snapshot.
        // Starting a second one would queue behind it; the next edit or the next
        // interval starts a new save with the newer text.
        guard !projectStore.hasPendingBackgroundWrite else { return }
        switch prepareProjectFileForWrite(honoringDeclinedConflict: true, reportsMissingFile: false) {
        case .proceed:
            break
        case .handled, .declined, .failed:
            return
        }
        if projectStore.canSaveInBackground {
            startBackgroundAutosave(at: url)
            return
        }
        do {
            try securityScope.withAccess(to: url) {
                try projectStore.saveCurrentProject(wordsPerMinute: currentDurationWordsPerMinute)
            }
            recordProjectFileSnapshotAfterSave(at: url)
            errorCenter.clearAutosaveFailureSuppression()
        } catch {
            Self.projectFilesLogger.error("Operation autosave failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.presentAutosave(AppError.project(error, fileURL: projectStore.currentFileURL, operation: .autosave))
        }
    }

    /// Snapshot and write off the main actor. The write is atomic and serialized
    /// with every other write; `completeBackgroundSave` keeps the project dirty
    /// when an edit landed while the bytes were being written.
    private func startBackgroundAutosave(at url: URL) {
        let didAccess = securityScope.start(url)
        let pending: ProjectStore.BackgroundSave
        do {
            pending = try projectStore.startBackgroundSave(wordsPerMinute: currentDurationWordsPerMinute)
        } catch {
            if didAccess {
                securityScope.stop(url)
            }
            Self.projectFilesLogger.error("Operation autosave start failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
            errorCenter.presentAutosave(AppError.project(error, fileURL: url, operation: .autosave))
            return
        }
        Task { @MainActor [weak self] in
            let result = await pending.task.result
            if didAccess {
                self?.securityScope.stop(url)
            }
            guard let self else { return }
            // A manual save or a new document consumed this write: its bytes
            // are already replaced on disk. Do not clobber the baseline or
            // report a stale error for it.
            guard self.projectStore.completeBackgroundSave(pending, result: result) else {
                return
            }
            switch result {
            case .success:
                self.recordProjectFileSnapshotAfterSave(at: url)
                self.errorCenter.clearAutosaveFailureSuppression()
                if self.projectStore.hasUnsavedFileChanges {
                    self.scheduleAutosaveIfNeeded()
                }
            case .failure(let error):
                Self.projectFilesLogger.error("Operation autosave failed. Code: \(self.diagnosticCode(for: error), privacy: .public)")
                self.errorCenter.presentAutosave(
                    AppError.project(error, fileURL: url, operation: .autosave)
                )
            }
        }
    }

    func showNotice(_ kind: AppNoticeKind, count: Int? = nil) {
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
        // Recents and external changes are validated by the file monitor and by
        // `prepareProjectFileForWrite` before every write. Polling them again on
        // every activation re-resolved every bookmark synchronously on the main
        // actor, which stalled the UI when a network volume disappeared.
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
    }

    /// Writes unsaved changes before the app stops being frontmost. Kept
    /// separate from the notification plumbing so it is directly testable.
    func flushForApplicationResignation() {
        guard !isTerminatingApplication, !isConfirmingTermination else { return }
        flushActiveEditorBoundary(allEditors: true)
        // Base wrote synchronously here; settle the asynchronous write so the
        // app is not left with bytes still in flight when it loses focus.
        syncPendingBackgroundSave()
    }

    /// Runs the same Save / Don't Save / Cancel decision as closing a project.
    /// Untitled projects go through Save As. Returns false when the user
    /// cancels or the save fails, which must cancel app termination.
    func confirmApplicationTermination() -> Bool {
        flushActiveEditorBoundary(saveImmediately: false)
        // The autosave task must not win a race against the modal decision.
        autosaveTask?.cancel()
        autosaveTask = nil
        // "Don't Save" used to kill a write that was still running. Settle it
        // before the decision; the dirty flag then reflects reality.
        syncPendingBackgroundSave()

        isConfirmingTermination = true
        let shouldTerminate = confirmCloseProjectIfNeeded()
        isConfirmingTermination = false

        if shouldTerminate {
            isTerminatingApplication = true
        } else {
            scheduleAutosaveIfNeeded()
        }
        return shouldTerminate
    }

    /// Closing any other window must not run the project save/conflict flow.
    func setProjectWindow(_ window: NSWindow?) {
        guard projectWindow !== window else { return }
        if let projectWindowCloseObserver {
            NotificationCenter.default.removeObserver(projectWindowCloseObserver)
            self.projectWindowCloseObserver = nil
        }
        projectWindow = window
        guard let window else { return }
        projectWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushForWindowClose()
            }
        }
    }

    func flushForWindowClose() {
        guard !isTerminatingApplication, !isConfirmingTermination else { return }
        flushActiveEditorBoundary(allEditors: true)
        syncPendingBackgroundSave()
    }

    private func presentAutomaticRecentRemovalNotice(count: Int) {
        guard count > 0 else { return }
        showNotice(.recentMissingRemoved, count: count == 1 ? nil : count)
    }

    private func diagnosticCode(for error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }

    private static func diagnosticCode(_ error: Error) -> String {
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
        if let confirmationHandler {
            return confirmationHandler(title, message)
        }
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
        // Every caller is a user-initiated template change; that is the explicit
        // signal that may replace a previously unreadable blob.
        Self.customTemplatesSavingIsBlocked = false
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

    private static func loadCustomTemplates() -> (templates: [FrameTemplate], failed: Bool) {
        guard let data = AppEnvironment.defaults.data(forKey: customTemplatesKey) else {
            return ([], false)
        }
        do {
            return (try JSONDecoder().decode([FrameTemplate].self, from: data), false)
        } catch {
            // Keep the unreadable blob so a later build or a manual rescue can
            // recover the templates instead of losing them to an empty list.
            AppEnvironment.defaults.set(data, forKey: customTemplatesKey + ".unreadable-backup")
            customTemplatesSavingIsBlocked = true
            projectFilesLogger.error("Custom templates could not be read; blob preserved. Code: \(Self.diagnosticCode(error), privacy: .private)")
            return ([], true)
        }
    }

    private static func saveCustomTemplates(_ templates: [FrameTemplate]) {
        guard !customTemplatesSavingIsBlocked else { return }
        guard let data = try? JSONEncoder().encode(templates) else { return }
        AppEnvironment.defaults.set(data, forKey: customTemplatesKey)
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

    enum ProjectFileBackgroundSaveError: Error {
        case unavailable
    }

    private var isConfigured = false
    private(set) var project: FrameProject
    private(set) var hasOpenProject = false
    private(set) var currentFileURL: URL?
    private(set) var saveState: SaveState = .saved
    private(set) var hasUnsavedFileChanges = false
    private(set) var origin: ProjectStoreOrigin = .normal
    /// Exact bytes the last successful save wrote. `AppState` records this as the
    /// external-change baseline instead of re-reading a file an external writer
    /// may already have replaced.
    private(set) var lastSavedFileData: Data?
    private var segmentSplitMode: SegmentType = AppSettings.defaults.generalPreferences.defaultSplitMode
    /// Text hash per scene at the last full segmentation. Unchanged scenes keep
    /// their segments, so a save does not re-split the whole script.
    private var segmentedTextHashes: [UUID: String] = [:]
    /// Scenes whose stored duration must be recomputed on the next duration
    /// pass. Typing a character dirties one scene, not the whole project.
    private var durationDirtySceneIDs: Set<UUID> = []
    /// Bumped on every document mutation. A background save only clears the
    /// dirty flag when nothing changed after its snapshot.
    private var contentRevision = 0
    /// Last background write, used to serialize writes and to let close/quit
    /// wait for a pending save. The whole descriptor is kept so a consumed
    /// write can apply its own revision logic exactly once.
    private var pendingBackgroundSave: BackgroundSave?
    /// Bumped whenever the open document is replaced or reloaded. A completion
    /// from a previous document must never touch the new one.
    private var documentGeneration = 0
    /// True while bytes written off the main actor are not reflected in the
    /// external-change baseline yet.
    var hasPendingBackgroundWrite: Bool { pendingBackgroundSave != nil }
    private var textRevisions: [UUID: Int] = [:]
    private var textHashCache: [UUID: (revision: Int, hash: String)] = [:]
    /// Configuration used by the last duration pass. A settings change without
    /// a text edit still forces one full pass, exactly like the old save path.
    private var lastDurationConfiguration: DurationConfiguration?
    private let projectWriter: ((FrameProject, URL) throws -> Void)?
    /// Resolves the markup-aware duration configuration for a scene. Set by
    /// `AppState`; a closure keeps this store independent from settings.
    var durationConfigurationProvider: ((Scene) -> DurationConfiguration)?
    /// Re-runs the rhythm review after anchor mutations. Set by `AppState`.
    var markupReviewRefreshHandler: (() -> Void)?

    init(
        project: FrameProject = SampleData.defaultProject,
        projectWriter: ((FrameProject, URL) throws -> Void)? = nil
    ) {
        self.project = project
        self.projectWriter = projectWriter
        recalculateAllDurations(wordsPerMinute: AppSettings.defaults.editorPreferences.wordsPerMinute)
    }

    func setSegmentSplitMode(_ splitMode: SegmentType) {
        segmentSplitMode = splitMode
    }

    func configure(wordsPerMinute: Int) {
        isConfigured = true
        recalculateAllDurations(wordsPerMinute: wordsPerMinute)
    }

    var isBuiltInDemo: Bool { origin == .builtInDemo }

    /// The injected writer seam is synchronous by contract (tests, diagnostics
    /// and the CLI rely on the bytes being on disk when the call returns).
    /// Production has no writer and can encode/write off the main actor.
    var canSaveInBackground: Bool { projectWriter == nil }

    /// Cached SHA-256 of a scene's script text. Scenes without takes never ask
    /// for it; scenes with takes asked for it on every keystroke before.
    func textHash(for scene: Scene) -> String {
        let revision = textRevisions[scene.id, default: 0]
        if let cached = textHashCache[scene.id], cached.revision == revision {
            return cached.hash
        }
        let hash = FrameScriptDocument.TextHash.hash(scene.scriptText)
        textHashCache[scene.id] = (revision, hash)
        return hash
    }

    private func bumpTextRevision(for sceneID: UUID) {
        textRevisions[sceneID, default: 0] &+= 1
    }

    private func resetTextCaches() {
        textRevisions.removeAll()
        textHashCache.removeAll()
        segmentedTextHashes.removeAll()
    }

    func openProject(
        _ project: FrameProject,
        fileURL: URL?,
        wordsPerMinute: Int,
        markUnsaved: Bool,
        origin: ProjectStoreOrigin = .normal,
        recalculateDurations: Bool = true
    ) {
        self.project = project
        currentFileURL = fileURL
        self.origin = origin
        hasOpenProject = true
        lastSavedFileData = nil
        documentGeneration &+= 1
        resetTextCaches()
        durationDirtySceneIDs.removeAll()
        lastDurationConfiguration = nil
        EditorMarkupSessionCaches.reset()
        if recalculateDurations {
            recalculateAllDurations(wordsPerMinute: wordsPerMinute)
        } else {
            // One pass is still required on open: the stored estimates may come
            // from a different pace, an older estimator or a hand edit. The
            // regression fixed here was doing that pass twice.
            durationDirtySceneIDs = Set(project.scenes.map(\.id))
        }
        hasUnsavedFileChanges = origin == .builtInDemo ? false : markUnsaved || fileURL == nil
        saveState = hasUnsavedFileChanges ? .edited : .saved
    }

    func closeProject() {
        hasOpenProject = false
        currentFileURL = nil
        hasUnsavedFileChanges = false
        saveState = .saved
        origin = .normal
        project = SampleData.defaultProject
        lastSavedFileData = nil
        documentGeneration &+= 1
        resetTextCaches()
        durationDirtySceneIDs.removeAll()
        lastDurationConfiguration = nil
        EditorMarkupSessionCaches.reset()
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

    /// Result of a write that runs off the main actor.
    struct BackgroundSave: Sendable {
        let id: UUID
        let url: URL
        let projectID: UUID
        let documentGeneration: Int
        let revision: Int
        let task: Task<Data, Error>
    }

    private final class BackgroundWriteBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<Data, Error>?

        func store(_ result: Result<Data, Error>) {
            lock.lock()
            stored = result
            lock.unlock()
        }

        func read() -> Result<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func saveCurrentProject(to url: URL, wordsPerMinute: Int) throws {
        // A pending background write must land before this one so an older
        // snapshot can never overwrite the newer bytes.
        waitForBackgroundWrite()
        prepareForSave(wordsPerMinute: wordsPerMinute)
        if currentFileURL != url {
            // Save As: the destination may belong to another project. Back it up
            // under its own path identity, forcibly, before replacing it.
            BackupsCenter.backUpBeforeSaveAs(to: url)
        } else {
            BackupsCenter.backUpBeforeOverwrite(project: project, fileURL: url)
        }
        do {
            if let projectWriter {
                try projectWriter(project, url)
                // A test/injected writer may write different bytes. Remember
                // what we believe the file now holds so a mismatch is detected
                // instead of being adopted as an external version.
                lastSavedFileData = try? FrameScriptFileStore.encode(project: project)
            } else {
                lastSavedFileData = try FrameScriptFileStore.writeWithData(project: project, to: url)
            }
        } catch {
            lastSavedFileData = nil
            markDirtyWithoutTimestamp()
            throw error
        }
        currentFileURL = url
        origin = .normal
        hasUnsavedFileChanges = false
        saveState = .saved
    }

    /// Snapshots the model on the main actor, then encodes and writes it on a
    /// detached task. The next save chains after this one, so writes to the same
    /// URL can never complete out of order.
    func startBackgroundSave(wordsPerMinute: Int) throws -> BackgroundSave {
        guard projectWriter == nil else {
            throw ProjectFileBackgroundSaveError.unavailable
        }
        guard let url = currentFileURL else { throw ProjectFileError.missingFileURL }
        prepareForSave(wordsPerMinute: wordsPerMinute)
        BackupsCenter.backUpBeforeOverwrite(project: project, fileURL: url)
        let document = FrameScriptDocument(project: project)
        let projectID = project.id
        let generation = documentGeneration
        let revision = contentRevision
        let previous = pendingBackgroundSave?.task
        saveState = .autosaving
        let task = Task.detached(priority: .userInitiated) {
            if let previous {
                _ = try? await previous.value
            }
            let data = try FrameScriptDocumentCodec.encode(document)
            try FrameScriptDocumentCodec.writeEncoded(data, to: url)
            return data
        }
        let save = BackgroundSave(
            id: UUID(),
            url: url,
            projectID: projectID,
            documentGeneration: generation,
            revision: revision,
            task: task
        )
        pendingBackgroundSave = save
        return save
    }

    /// Applies a completed background write and reports whether it still
    /// described the open document. A late completion of a write that was
    /// already consumed by a manual save (or belongs to a previous document)
    /// returns `false` and must not touch state, the baseline or error UI.
    ///
    /// An edit that landed while the write was running keeps the project dirty
    /// instead of being marked saved.
    @discardableResult
    func completeBackgroundSave(_ save: BackgroundSave, result: Result<Data, Error>) -> Bool {
        guard pendingBackgroundSave?.id == save.id else { return false }
        pendingBackgroundSave = nil
        guard project.id == save.projectID,
              currentFileURL == save.url,
              documentGeneration == save.documentGeneration else {
            return false
        }
        switch result {
        case .success(let data):
            lastSavedFileData = data
            if contentRevision == save.revision {
                hasUnsavedFileChanges = false
                saveState = .saved
            } else {
                markDirtyWithoutTimestamp()
            }
        case .failure:
            lastSavedFileData = nil
            markDirtyWithoutTimestamp()
        }
        return true
    }

    /// Blocks until the last background write finished, applies its revision
    /// logic and returns whether it described the current document. Used by the
    /// synchronous save paths and by close/open/quit/revert, which must not
    /// race a write.
    @discardableResult
    func waitForBackgroundWrite() -> Bool {
        guard let save = pendingBackgroundSave else { return false }
        pendingBackgroundSave = nil
        let box = BackgroundWriteBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.store(await save.task.result)
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.read() else { return false }
        guard project.id == save.projectID,
              currentFileURL == save.url,
              documentGeneration == save.documentGeneration else {
            return false
        }
        switch result {
        case .success(let data):
            lastSavedFileData = data
            if contentRevision == save.revision {
                hasUnsavedFileChanges = false
                saveState = .saved
            } else {
                markDirtyWithoutTimestamp()
            }
        case .failure:
            lastSavedFileData = nil
            markDirtyWithoutTimestamp()
        }
        return true
    }

    func duplicateProject(copySuffix: String) -> FrameProject {
        let copy = project.copied(title: "\(project.title) \(copySuffix)")
        project = copy
        currentFileURL = nil
        hasOpenProject = true
        markDirtyWithoutTimestamp()
        lastSavedFileData = nil
        documentGeneration &+= 1
        resetTextCaches()
        durationDirtySceneIDs.removeAll()
        lastDurationConfiguration = nil
        EditorMarkupSessionCaches.reset()
        return copy
    }

    func deleteCurrentProject() {
        project = SampleData.defaultProject
        currentFileURL = nil
        hasOpenProject = false
        hasUnsavedFileChanges = false
        saveState = .saved
        lastSavedFileData = nil
        documentGeneration &+= 1
        resetTextCaches()
        durationDirtySceneIDs.removeAll()
        lastDurationConfiguration = nil
        EditorMarkupSessionCaches.reset()
    }

    var totalDuration: TimeInterval {
        project.scenes.reduce(0) { $0 + $1.estimatedDuration }
    }

    func selectedScene(id: UUID?) -> Scene? {
        guard let id else { return project.scenes.sortedByOrder.first }
        return project.scenes.first(where: { $0.id == id }) ?? project.scenes.sortedByOrder.first
    }

    func selectedSceneIndex(id: UUID?) -> Int? {
        let ordered = project.scenes.sortedByOrder
        guard let id else { return ordered.isEmpty ? nil : 0 }
        return ordered.firstIndex(where: { $0.id == id }) ?? (ordered.isEmpty ? nil : 0)
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
        scene.copied(
            order: project.scenes.count,
            title: "\(scene.title) \(copySuffix)"
        )
    }

    func deleteScene(at sortedIndex: Int, wordsPerMinute: Int) {
        guard project.scenes.count > 1 else { return }
        let ordered = project.scenes.sortedByOrder
        guard let scene = ordered[safe: sortedIndex],
              let storageIndex = project.scenes.firstIndex(where: { $0.id == scene.id }) else {
            return
        }
        project.scenes.remove(at: storageIndex)
        segmentedTextHashes[scene.id] = nil
        textRevisions[scene.id] = nil
        textHashCache[scene.id] = nil
        durationDirtySceneIDs.remove(scene.id)
        EditorMarkupSessionCaches.removeScene(scene.id)
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
        markDirtyWithoutTimestamp()
    }

    /// Every "the document changed" path funnels through here so
    /// `contentRevision` always covers the change. A background save captures
    /// this revision and only clears the dirty flag when it still matches.
    private func markDirtyWithoutTimestamp() {
        contentRevision &+= 1
        hasUnsavedFileChanges = true
        saveState = .edited
    }

    /// Marks every scene for one duration pass. Used when the resolved pace can
    /// differ from the stored estimates without any text edit.
    func markAllDurationsDirty() {
        durationDirtySceneIDs = Set(project.scenes.map(\.id))
    }

    /// Records that a caller just recomputed every estimate with this
    /// configuration, so the next save does not repeat the pass.
    func adoptDurationConfiguration(_ configuration: DurationConfiguration) {
        lastDurationConfiguration = configuration
        durationDirtySceneIDs.removeAll()
    }

    func commitScriptText(_ text: String, sceneID: UUID, previousText: String? = nil) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        let oldText = previousText ?? scene.scriptText
        let changed = scene.scriptText != text
        scene.scriptText = text
        if changed {
            bumpTextRevision(for: sceneID)
            durationDirtySceneIDs.insert(sceneID)
            contentRevision &+= 1
        }
        refreshProductionAnchors(in: scene, previousText: oldText)
    }

    func updateCurrentSceneMetrics(sceneID: UUID, wordsPerMinute: Int) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        scene.estimatedDuration = estimatedDuration(for: scene, fallbackWordsPerMinute: wordsPerMinute)
        durationDirtySceneIDs.remove(sceneID)
    }

    private func prepareForSave(wordsPerMinute: Int) {
        synchronizeTextSegments(splitMode: segmentSplitMode, wordsPerMinute: wordsPerMinute, markUnsaved: false)
        project.updatedAt = Date()
        saveState = .autosaving
    }

    func synchronizeTextSegments(splitMode: SegmentType, wordsPerMinute: Int, markUnsaved: Bool = true) {
        refreshDurationsIfConfigurationChanged(wordsPerMinute: wordsPerMinute)
        let splitModeChanged = segmentSplitMode != splitMode
        segmentSplitMode = splitMode
        for scene in project.scenes {
            let hash = textHash(for: scene)
            guard splitModeChanged || segmentedTextHashes[scene.id] != hash else { continue }
            synchronizeTextSegments(for: scene, splitMode: splitMode, wordsPerMinute: wordsPerMinute)
            segmentedTextHashes[scene.id] = hash
        }
        recalculateDurations(wordsPerMinute: wordsPerMinute)
        project.updatedAt = Date()
        if markUnsaved {
            markDirtyWithoutTimestamp()
        }
    }

    func synchronizeTextSegments(forSceneID sceneID: UUID, splitMode: SegmentType, wordsPerMinute: Int, markUnsaved: Bool = true) {
        segmentSplitMode = splitMode
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        synchronizeTextSegments(for: scene, splitMode: splitMode, wordsPerMinute: wordsPerMinute)
        segmentedTextHashes[sceneID] = textHash(for: scene)
        // The scene-level estimate is owned by `SceneMetricsDebouncer`: one
        // off-main parse per settled edit. Recomputing it here would parse the
        // same script a second time on the main actor, just before the debounced
        // pass lands. Saves, restores and exports still refresh it synchronously.
        project.updatedAt = Date()
        if markUnsaved {
            markDirtyWithoutTimestamp()
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
        let edit = previousText.map {
            TextAnchorRepair.contiguousEdit(from: $0, to: scene.scriptText)
        }
        for item in scene.bRollItems {
            guard item.textAnchor != nil else { continue }
            let repaired = if let previousText, let edit {
                TextAnchorRepair.repair(item.textAnchor, from: previousText, to: scene.scriptText, edit: edit)
            } else {
                TextAnchorRepair.repair(item.textAnchor, in: scene.scriptText)
            }
            guard let repaired else {
                item.textAnchor = nil
                item.linkedSegmentID = nil
                continue
            }
            item.textAnchor = repaired
        }
        for item in scene.editingItems {
            guard item.textAnchor != nil else { continue }
            let repaired = if let previousText, let edit {
                TextAnchorRepair.repair(item.textAnchor, from: previousText, to: scene.scriptText, edit: edit)
            } else {
                TextAnchorRepair.repair(item.textAnchor, in: scene.scriptText)
            }
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
        RhythmReviewCenter.shared.invalidate(sceneID: scene.id)
        markupReviewRefreshHandler?()
    }

    func link(_ item: EditingItem, to segment: TextSegment, in scene: Scene) {
        guard let anchor = TextAnchorRepair.anchor(for: segment, in: scene.scriptText) else { return }
        item.textAnchor = anchor
        item.linkedSegmentID = segment.id
        RhythmReviewCenter.shared.invalidate(sceneID: scene.id)
        markupReviewRefreshHandler?()
    }

    func unlink(_ item: BRollItem) {
        item.textAnchor = nil
        item.linkedSegmentID = nil
        invalidateRhythm(forItemID: item.id)
    }

    func unlink(_ item: EditingItem) {
        item.textAnchor = nil
        item.linkedSegmentID = nil
        invalidateRhythm(forItemID: item.id)
    }

    /// Drops cached warnings for the scene that owns an unlinked item.
    private func invalidateRhythm(forItemID itemID: UUID) {
        guard let scene = project.scenes.first(where: { scene in
            scene.bRollItems.contains { $0.id == itemID }
                || scene.editingItems.contains { $0.id == itemID }
        }) else { return }
        RhythmReviewCenter.shared.invalidate(sceneID: scene.id)
        markupReviewRefreshHandler?()
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
        guard !durationDirtySceneIDs.isEmpty else { return }
        for scene in project.scenes where durationDirtySceneIDs.contains(scene.id) {
            scene.estimatedDuration = estimatedDuration(for: scene, fallbackWordsPerMinute: wordsPerMinute)
        }
        durationDirtySceneIDs.removeAll()
    }

    private func recalculateAllDurations(wordsPerMinute: Int) {
        for scene in project.scenes {
            scene.estimatedDuration = estimatedDuration(for: scene, fallbackWordsPerMinute: wordsPerMinute)
        }
        durationDirtySceneIDs.removeAll()
        lastDurationConfiguration = currentDurationConfiguration(wordsPerMinute: wordsPerMinute)
    }

    /// A provider or a settings change can imply a different pace without any
    /// text edit. Detecting it here keeps stored estimates in sync with the
    /// current configuration, which is what the old every-save pass did.
    private func refreshDurationsIfConfigurationChanged(wordsPerMinute: Int) {
        guard !project.scenes.isEmpty else { return }
        let configuration = currentDurationConfiguration(wordsPerMinute: wordsPerMinute)
        guard let lastConfiguration = lastDurationConfiguration else {
            lastDurationConfiguration = configuration
            return
        }
        guard configuration != lastConfiguration else { return }
        lastDurationConfiguration = configuration
        durationDirtySceneIDs = Set(project.scenes.map(\.id))
    }

    private func currentDurationConfiguration(wordsPerMinute: Int) -> DurationConfiguration {
        if let durationConfigurationProvider,
           let scene = project.scenes.first {
            return durationConfigurationProvider(scene)
        }
        return DurationConfiguration(wordsPerMinute: Double(wordsPerMinute))
    }

    /// A stored estimate is trusted on open (the app used to parse the whole
    /// project twice to rebuild it). Only files with a missing or impossible
    /// value pay for a pass.
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

    /// Drops every per-scene caret/scroll restoration entry. Called when the
    /// project closes or is replaced so a new project cannot inherit stale
    /// ranges from the previous one.
    func resetScriptEditorStates() {
        scriptEditorStates.removeAll()
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
    static var contextLength: Int { FrameScriptDocument.TextAnchorRepair.contextLength }

    static func anchor(for segment: TextSegment, in text: String) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair
            .anchor(for: coreSegment(segment), in: text)
            .map(appAnchor)
    }

    static func anchor(in text: String, range: NSRange) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: range).map(appAnchor)
    }

    static func repair(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair.repair(coreAnchor(anchor), in: text).map(appAnchor)
    }

    static func repair(_ anchor: TextAnchor?, from previousText: String, to text: String) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair
            .repair(coreAnchor(anchor), from: previousText, to: text)
            .map(appAnchor)
    }

    static func repair(
        _ anchor: TextAnchor?,
        from previousText: String,
        to text: String,
        edit: FrameScriptDocument.TextAnchorRepair.ContiguousEdit
    ) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair
            .repair(coreAnchor(anchor), from: previousText, to: text, edit: edit)
            .map(appAnchor)
    }

    static func contiguousEdit(
        from previousText: String,
        to text: String
    ) -> FrameScriptDocument.TextAnchorRepair.ContiguousEdit {
        FrameScriptDocument.TextAnchorRepair.contiguousEdit(from: previousText, to: text)
    }

    static func current(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
        FrameScriptDocument.TextAnchorRepair.current(coreAnchor(anchor), in: text).map(appAnchor)
    }

    static func isAnchor(_ anchor: TextAnchor, in segment: TextSegment, text: String) -> Bool {
        FrameScriptDocument.TextAnchorRepair.isAnchor(
            coreAnchor(anchor),
            in: coreSegment(segment),
            text: text
        )
    }

    private static func coreAnchor(_ anchor: TextAnchor?) -> FrameScriptDocument.TextAnchor? {
        guard let anchor else { return nil }
        return FrameScriptDocument.TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
    }

    private static func coreAnchor(_ anchor: TextAnchor) -> FrameScriptDocument.TextAnchor {
        FrameScriptDocument.TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
    }

    private static func appAnchor(_ anchor: FrameScriptDocument.TextAnchor) -> TextAnchor {
        TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
    }

    private static func coreSegment(_ segment: TextSegment) -> FrameScriptDocument.TextSegment {
        FrameScriptDocument.TextSegment(
            id: segment.id,
            sceneID: segment.sceneID,
            order: segment.order,
            sourceText: segment.sourceText,
            segmentType: FrameScriptDocument.SegmentType(rawValue: segment.segmentType.rawValue) ?? .scene,
            timingEstimate: segment.timingEstimate
        )
    }
}

@MainActor
@Observable
final class SettingsStore {
    typealias SettingsEncoder = (AppSettings) throws -> Data
    typealias SettingsDecoder = (Data) throws -> AppSettings

    var settings: AppSettings {
        didSet {
            let languageChanged = oldValue.generalPreferences.language
                != settings.generalPreferences.language
            save()
            if languageChanged {
                NotificationCenter.default.post(
                    name: .frameScriptInterfaceLanguageDidChange,
                    object: self
                )
            }
        }
    }

    private(set) var errorEvent: AppError?
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder: SettingsEncoder
    private var errorReporter: ((AppError) -> Void)?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Settings")

    init(
        settings: AppSettings? = nil,
        userDefaults: UserDefaults = AppEnvironment.defaults,
        key: String = "FrameScript.settings.v1",
        encoder: @escaping SettingsEncoder = { try JSONEncoder().encode($0) },
        decoder: SettingsDecoder = { try JSONDecoder().decode(AppSettings.self, from: $0) }
    ) {
        let resolvedDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.userDefaults = resolvedDefaults
        self.key = key
        self.encoder = encoder
        if let settings {
            self.settings = settings
        } else if let data = resolvedDefaults.data(forKey: key) {
            do {
                self.settings = try decoder(data)
            } catch {
                // Keep the unreadable blob so a later build or a manual rescue
                // can recover preferences instead of losing them to defaults.
                resolvedDefaults.set(data, forKey: key + ".unreadable-backup")
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
        FrameScriptDocument.TextSegmenter.segmentTexts(
            in: text,
            splitMode: FrameScriptDocument.SegmentType(rawValue: splitMode.rawValue) ?? .scene
        )
    }

    static func normalized(_ text: String) -> String {
        FrameScriptDocument.TextSegmenter.normalized(text)
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
