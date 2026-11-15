import Foundation

/// Pure enablement matrix for the application menu, the command palette and the
/// welcome screen.
///
/// Every surface asks the same value instead of re-deriving `hasOpenProject`
/// checks, so a menu item can never disagree with the palette entry for the
/// same command. The recording rules come from the lifecycle review: while a
/// take is active the project must not be replaced or deleted, but stopping the
/// recording is always possible (even if the project was closed underneath).
struct CommandAvailability: Equatable {
    var hasOpenProject: Bool
    var hasScenes: Bool
    var hasSelectedScene: Bool
    /// `recording.phase.isActive`: countdown, starting, recording or stopping.
    var isRecordingActive: Bool
    /// `recording.hasActiveTake`: the controller still owns a take on a scene.
    var hasActiveTake: Bool

    init(
        hasOpenProject: Bool = false,
        hasScenes: Bool = false,
        hasSelectedScene: Bool = false,
        isRecordingActive: Bool = false,
        hasActiveTake: Bool = false
    ) {
        self.hasOpenProject = hasOpenProject
        self.hasScenes = hasScenes
        self.hasSelectedScene = hasSelectedScene
        self.isRecordingActive = isRecordingActive
        self.hasActiveTake = hasActiveTake
    }

    // MARK: - Project lifecycle (blocked while a take is being recorded)

    /// New project, new from template and open recent replace the open project.
    var canReplaceProject: Bool { !hasActiveTake }
    var canOpenProject: Bool { !hasActiveTake }
    var canCloseProject: Bool { hasOpenProject && !hasActiveTake }
    var canDeleteProject: Bool { hasOpenProject && !hasActiveTake }
    var canRevealProjectInFinder: Bool { hasOpenProject }
    var canSaveProject: Bool { hasOpenProject }
    var canSaveProjectAs: Bool { hasOpenProject }
    var canExportProject: Bool { hasOpenProject }
    var canExportAVScript: Bool { hasOpenProject }
    var canRevertToSaved: Bool { hasOpenProject && hasSavedFile && !hasActiveTake }

    /// Set by `CommandAvailability(appState:)`; kept out of the initializer so
    /// the matrix stays easy to build in tests.
    var hasSavedFile: Bool = false
    var isTimelineMode: Bool = false

    // MARK: - Backups and app-level windows

    /// WP1 makes the Backups window list the failed project without an open
    /// file, so the menu item must be reachable from the welcome screen too.
    /// Restoring a backup replaces the project, so it is blocked mid-take.
    var canShowBackups: Bool { !hasActiveTake }
    /// OBS is an application-level integration: configurable before any project.
    var canOpenOBSSettings: Bool { true }
    var canOpenSettings: Bool { true }
    var canShowCommandPalette: Bool { true }
    var canShowShortcuts: Bool { true }

    // MARK: - Scenes

    var canAddScene: Bool { hasOpenProject }
    var canDuplicateScene: Bool { hasOpenProject && hasSelectedScene }
    var canDeleteScene: Bool { hasOpenProject && hasSelectedScene && !hasActiveTake }
    var canMoveScene: Bool { hasOpenProject && hasSelectedScene }
    var canRenameScene: Bool { hasOpenProject && hasSelectedScene }
    var canNavigateScenes: Bool { hasOpenProject && hasScenes }

    // MARK: - Tools

    var canAnalyzeScene: Bool { hasOpenProject && hasSelectedScene }
    var canAnalyzeFullScript: Bool { hasOpenProject && hasScenes }
    var canGenerateForScene: Bool { hasOpenProject && hasSelectedScene }
    var canOpenTeleprompter: Bool { hasOpenProject && hasScenes }
    var canToggleRecordingPanel: Bool { hasOpenProject }
    /// The production checklist is derived from the open document, so it needs
    /// a project but no selected scene.
    var canShowProductionChecklist: Bool { hasOpenProject }
    var canShowPublishing: Bool { hasOpenProject }

    /// Recording can always be stopped, even when the project vanished while
    /// OBS was writing the take; starting one needs a scene.
    var canToggleRecording: Bool { (hasOpenProject && hasSelectedScene) || isRecordingActive }

    // MARK: - Mode switches

    var canSwitchMode: Bool { hasOpenProject }
    /// A clip starts from the selected scene or the current editor selection.
    var canCreateClip: Bool { hasOpenProject && hasSelectedScene }
    /// Timeline zoom only applies while the timeline workspace is on screen.
    var canZoomTimeline: Bool { isTimelineMode }
    var canToggleContentsPanel: Bool { hasOpenProject }
    var canToggleAIReview: Bool { hasOpenProject }
    var canToggleFocusMode: Bool { hasOpenProject }
    var canShowAssets: Bool { hasOpenProject }
    var canShowResearch: Bool { hasOpenProject }

    func isEnabled(_ command: ShortcutCommand) -> Bool {
        switch command {
        case .newProject, .newProjectFromTemplate, .openProject, .import:
            canReplaceProject
        case .save:
            canSaveProject
        case .saveAs:
            canSaveProjectAs
        case .export, .exportEscaleta, .exportAVScript:
            canExportProject
        case .importEscaleta:
            canReplaceProject
        case .showBackups:
            canShowBackups
        case .addScene:
            canAddScene
        case .duplicateScene:
            canDuplicateScene
        case .deleteScene:
            canDeleteScene
        case .moveSceneUp, .moveSceneDown:
            canMoveScene
        case .previousScene, .nextScene:
            canNavigateScenes
        case .scriptMode, .visualsMode, .editingMode, .clipsMode, .timelineMode, .avScriptMode:
            canSwitchMode
        case .createClip:
            canCreateClip
        case .timelineZoomIn, .timelineZoomOut:
            canZoomTimeline
        case .commandPalette:
            canShowCommandPalette
        case .toggleContentsPanel:
            canToggleContentsPanel
        case .toggleAIReview:
            canToggleAIReview
        case .toggleFocusMode:
            canToggleFocusMode
        case .assets:
            canShowAssets
        case .researchPanel:
            canShowResearch
        case .teleprompter:
            canOpenTeleprompter
        case .recordTake:
            canToggleRecording
        case .toggleRecordingPanel:
            canToggleRecordingPanel
        case .productionChecklist:
            canShowProductionChecklist
        case .publishingPack:
            canShowPublishing
        case .analyzeCurrentScene, .generateHook, .suggestRehooks:
            canAnalyzeScene
        case .openSettings:
            canOpenSettings
        case .showShortcuts:
            canShowShortcuts
        }
    }
}

@MainActor
extension CommandAvailability {
    init(appState: AppState) {
        self.init(
            hasOpenProject: appState.hasOpenProject,
            hasScenes: !appState.project.scenes.isEmpty,
            hasSelectedScene: appState.selectedScene != nil,
            isRecordingActive: appState.recording.phase.isActive,
            hasActiveTake: appState.recording.hasActiveTake
        )
        hasSavedFile = appState.projectStore.currentFileURL != nil
        isTimelineMode = appState.selectedMode == .timeline
    }
}

/// What a drop of files on the app window should do.
enum ProjectDropAction: Equatable {
    case openProject(URL)
    case importEscaleta(URL)
    case ignore

    static func resolve(_ urls: [URL]) -> ProjectDropAction {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "fscr", "framescript":
                return .openProject(url)
            case "md":
                return .importEscaleta(url)
            default:
                continue
            }
        }
        return .ignore
    }
}
