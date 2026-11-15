import AppKit
import SwiftUI

/// Runtime entry point.
///
/// XCTest injects its bundle into the host app, and a `WindowGroup` there would
/// create a window, steal focus and write window-frame keys into the user's
/// real preferences. The test host therefore runs a scene with no windows.
@main
enum FrameScriptApp {
    static func main() {
        if AppEnvironment.isRunningTests {
            FrameScriptTestHostApp.main()
        } else {
            FrameScriptProductionApp.main()
        }
    }
}

struct FrameScriptTestHostApp: App {
    init() {
        AppEnvironment.prepareForLaunch()
        TestIsolationBaseline.captureIfNeeded()
    }

    var body: some SwiftUI.Scene {
        Settings<EmptyView> { EmptyView() }
    }
}

struct FrameScriptProductionApp: App {
    @NSApplicationDelegateAdaptor(FrameScriptAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @Environment(\.openSettings) private var openSettings

    init() {
        // Must run before AppState creates its settings and recents stores.
        AppEnvironment.prepareForLaunch()
        TestIsolationBaseline.captureIfNeeded()
        if !AppEnvironment.isRunningTests {
            SandboxDataMigration.migrateIfNeeded()
            // Stale per-launch `NSWindow Frame …` keys from the private root
            // view type; removal is idempotent and runs once (tests P2-3).
            LegacyWindowFrameKeys.purgeIfNeeded(defaults: AppEnvironment.defaults)
        }
        _appState = State(initialValue: AppState())
        // This is a process-wide AppKit setting, so enable automatic spelling
        // language detection once at launch instead of mutating it from the
        // script editor's updateNSView (which also owns notes text views).
        NSSpellChecker.shared.automaticallyIdentifiesLanguages = true
    }

    var body: some SwiftUI.Scene {
        // A stable identifier keeps AppKit's frame autosave key from embedding
        // the reflected root view type. `ThemedSceneRoot` is internal for the
        // same reason: a private generic type prints a per-launch heap address.
        WindowGroup(id: "main") {
            ThemedSceneRoot {
                AppRootView()
            }
            .escaletaImportSheet()
            .environment(appState)
            .environment(escaletaImport)
            .backupsSheet(appState)
            .productionSheet(appState)
            .onAppear {
                shortcutRouter.start(using: appState)
                appDelegate.attach(appState)
#if DEBUG
                appState.presentTeleprompterForUITestingIfRequested()
#endif
            }
            .onDisappear { shortcutRouter.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            appCommands
        }

        Settings {
            ThemedSceneRoot {
                SettingsRootView()
            }
                .errorAlert()
                .environment(appState)
        }
    }

    @State private var shortcutRouter = AppKitPhysicalShortcutCommandRouter()
    @State private var escaletaImport = EscaletaImportCoordinator()

    @CommandsBuilder
    private var appCommands: some Commands {
        let commands = CommandAvailability(appState: appState)

        CommandGroup(replacing: .newItem) {
            Button(appState.localized("menu.newProject")) { appState.requestNewProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .newProject))
                .disabled(!commands.canReplaceProject)
            Button(appState.localized("menu.newProjectFromTemplate")) {
                appState.requestNewProject(showsTemplateBrowser: true)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .newProjectFromTemplate))
            .disabled(!commands.canReplaceProject)
            Menu(appState.localized("welcome.newFromTemplate")) {
                ForEach(appState.scriptTemplates()) { template in
                    Button(appState.displayName(template)) {
                        appState.requestNewProject(template: template, locksTemplate: true)
                    }
                }
            }
            .disabled(!commands.canReplaceProject)
            Divider()
            Button(appState.localized("menu.open")) { appState.openProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .openProject))
                .disabled(!commands.canOpenProject)
            Menu(appState.localized("menu.openRecent")) {
                if appState.recentProjectEntries.isEmpty {
                    Text(appState.localized("menu.noRecentProjects"))
                } else {
                    ForEach(appState.recentProjectEntries) { entry in
                        Button(entry.displayName) {
                            appState.openRecentProject(entry)
                        }
                        .disabled(!commands.canOpenProject)
                    }
                    Divider()
                    Menu(appState.localized("recent.manage")) {
                        ForEach(appState.recentProjectEntries) { entry in
                            Menu(entry.displayName) {
                                Button(appState.localized("recent.open")) {
                                    appState.openRecentProject(entry)
                                }
                                .disabled(!commands.canOpenProject)
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
                    Button(appState.localized("menu.clearMenu")) { appState.clearRecentProjects() }
                }
            }
            // File > Import duplicated File > Open. The item now opens the
            // built-in demo project, and keeps the customised ⇧⌘I binding.
            Button(appState.localized("menu.openDemo")) { appState.openDemoProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .import))
                .disabled(!commands.canReplaceProject)
        }

        CommandGroup(replacing: .saveItem) {
            Button(appState.localized("project.save")) { appState.saveProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .save))
                .disabled(!commands.canSaveProject)
            Button(appState.localized("project.saveAs")) { appState.saveProjectAs() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .saveAs))
                .disabled(!commands.canSaveProjectAs)
            Button(appState.localized("menu.revertToSaved")) { appState.revertProjectToSaved() }
                .disabled(!commands.canRevertToSaved)
            Divider()
            Button(appState.localized("menu.duplicateProject")) { appState.duplicateProject() }
                .disabled(!commands.canSaveProject)
            Button(appState.localized("project.rename")) { appState.renameProject() }
                .disabled(!commands.canSaveProject)
            Divider()
            Button(appState.localized("project.browser")) { appState.returnToProjectList() }
                .disabled(!commands.canCloseProject)
            Divider()
            Button(appState.localized("menu.deleteProject")) { appState.deleteProject() }
                .disabled(!commands.canDeleteProject)
        }

        CommandGroup(replacing: .importExport) {
            Button(appState.localized("project.export")) { appState.exportProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .export))
                .disabled(!commands.canExportProject)
            Divider()
            Button(appState.localized("menu.importEscaleta")) {
                escaletaImport.chooseFile(appState: appState)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .importEscaleta))
            .disabled(!commands.canReplaceProject)
            Button(appState.localized("menu.exportEscaleta")) {
                appState.exportEscaletaMarkdown()
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .exportEscaleta))
            .disabled(!commands.canExportProject)
        }

        CommandGroup(replacing: .appSettings) {
            Button(appState.localized("command.openSettings")) {
                appState.openSettings(tab: .general)
                openSettings()
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .openSettings))
        }

        CommandMenu(appState.localized("menu.view")) {
            Toggle(appState.localized("mode.script"), isOn: modeBinding(.script))
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .scriptMode))
                .disabled(!commands.canSwitchMode)
            Toggle(appState.localized("mode.bRoll"), isOn: modeBinding(.bRoll))
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .visualsMode))
                .disabled(!commands.canSwitchMode)
            Toggle(appState.localized("mode.editing"), isOn: modeBinding(.editing))
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .editingMode))
            Toggle(appState.localized("mode.editing"), isOn: modeBinding(.editing))
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .editingMode))
                .disabled(!commands.canSwitchMode)
            Toggle(appState.localized("mode.clips"), isOn: modeBinding(.clips))
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .clipsMode))
                .disabled(!commands.canSwitchMode)
            Button(appState.localized("clips.command.create")) { appState.createClipFromEditorSelection() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .createClip))
                .disabled(!commands.canCreateClip)
            Divider()
            Button(appState.localized("menu.teleprompter")) { appState.presentTeleprompter() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .teleprompter))
                .disabled(!commands.canOpenTeleprompter)
            Divider()
            Toggle(appState.localized("command.toggleSidebar"), isOn: $appState.isSidebarVisible)
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleContentsPanel))
                .disabled(!commands.canToggleContentsPanel)
            Toggle(appState.localized("command.toggleAIReview"), isOn: aiReviewPanelBinding)
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleAIReview))
                .disabled(!commands.canToggleAIReview)
            Toggle(appState.localized("command.toggleFocus"), isOn: $appState.isFocusModeEnabled)
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleFocusMode))
                .disabled(!commands.canToggleFocusMode)
            Button(appState.localized("toolbar.commandPalette")) { appState.isCommandPalettePresented = true }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .commandPalette))
            Button(appState.localized("command.showShortcuts")) { appState.isShortcutsPresented = true }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .showShortcuts))
        }

        CommandMenu(appState.localized("menu.scene")) {
            Button(appState.localized("scene.add")) { appState.addScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .addScene))
                .disabled(!commands.canAddScene)
            Button(appState.localized("scene.duplicate")) { appState.duplicateSelectedScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .duplicateScene))
                .disabled(!commands.canDuplicateScene)
            Button(appState.localized("scene.delete")) { appState.deleteSelectedScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .deleteScene))
                .disabled(!commands.canDeleteScene)
            Divider()
            Button(appState.localized("menu.previousScene")) {
                appState.selectAdjacentScene(.previous)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .previousScene))
            .disabled(!commands.canNavigateScenes)
            Button(appState.localized("menu.nextScene")) {
                appState.selectAdjacentScene(.next)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .nextScene))
            .disabled(!commands.canNavigateScenes)
            Divider()
            Button(appState.localized("scene.moveUp")) { appState.moveSelectedSceneUp() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .moveSceneUp))
                .disabled(!commands.canMoveScene)
            Button(appState.localized("scene.moveDown")) { appState.moveSelectedSceneDown() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .moveSceneDown))
                .disabled(!commands.canMoveScene)
            Button(appState.localized("scene.rename")) { appState.renameSelectedScene() }
                .disabled(!commands.canRenameScene)
        }

        CommandMenu(appState.localized("menu.tools")) {
            Button(appState.localized("ai.analyzeCurrentScene")) {
                appState.settings.editorPreferences.showAIReviewPanel = true
                Task { await appState.analyzeSelectedScene() }
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .analyzeCurrentScene))
            .disabled(!commands.canAnalyzeScene)
            Button(appState.localized("menu.analyzeFullScript")) {
                appState.settings.editorPreferences.showAIReviewPanel = true
                Task { await appState.analyzeFullScript() }
            }
            .disabled(!commands.canAnalyzeFullScript)
            Divider()
            Button(appState.localized("menu.generateHook")) {
                HookSheetPresenter.shared.present(.hook)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .generateHook))
            .disabled(!commands.canAnalyzeScene)
            Button(appState.localized("menu.suggestRehooks")) {
                HookSheetPresenter.shared.present(.rehook)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .suggestRehooks))
            .disabled(!commands.canAnalyzeScene)
            Divider()
            Button(appState.localized("menu.generateBRoll")) { appState.generateBRollForSelectedScene() }
                .disabled(!commands.canGenerateForScene)
            Button(appState.localized("menu.generateEditing")) { appState.generateEditingNotesForSelectedScene() }
                .disabled(!commands.canGenerateForScene)
            Divider()
            // A take must always be stoppable, even when the project was closed
            // while OBS was still writing (lifecycle P1-1).
            Button(appState.localized("recording.menu.recordTake")) { appState.toggleRecordingTake() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .recordTake))
                .disabled(!commands.canToggleRecording)
            Toggle(appState.localized("recording.menu.togglePanel"), isOn: recordingPanelBinding)
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleRecordingPanel))
                .disabled(!commands.canToggleRecordingPanel)
            Button(appState.localized("production.menu")) {
                ProductionPresentation.shared.present()
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .productionChecklist))
            .disabled(!commands.canShowProductionChecklist)
            Button(appState.localized("recording.obs.settings")) {
                appState.recording.isSettingsPresented = true
            }
            .disabled(!commands.canOpenOBSSettings)
            Divider()
            // WP1 makes the Backups window list the project that failed to
            // open, so the item is reachable without an open project (E2).
            Button(appState.localized("backups.menu")) { appState.showBackupsWindow() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .showBackups))
                .disabled(!commands.canShowBackups)
        }
    }

    private func modeBinding(_ mode: WorkspaceMode) -> Binding<Bool> {
        Binding(
            get: { appState.selectedMode == mode },
            set: { isSelected in
                guard isSelected else { return }
                appState.selectMode(mode)
            }
        )
    }

    private var aiReviewPanelBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.editorPreferences.showAIReviewPanel },
            set: { appState.settings.editorPreferences.showAIReviewPanel = $0 }
        )
    }

    private var recordingPanelBinding: Binding<Bool> {
        Binding(
            get: { appState.recording.isPanelVisible },
            set: { appState.recording.isPanelVisible = $0 }
        )
    }
}

/// Routes configurable commands by their physical ANSI key while leaving the
/// actual command invocation to AppKit's existing menu key-equivalent path.
@MainActor
final class AppKitPhysicalShortcutCommandRouter {
    private weak var appState: AppState?
    private var monitor: Any?

    func start(using appState: AppState) {
        self.appState = appState
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  !ShortcutCaptureSession.isAnySessionActive,
                  let appState = self.appState,
                  let menu = NSApp.mainMenu
            else { return event }
            return PhysicalShortcutMenuDispatcher.dispatch(event, settings: appState.settings, menu: menu) ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        appState = nil
    }

}

/// Normalizes the physical key before asking AppKit to perform its normal menu
/// key-equivalent dispatch. Keeping this separate from the event monitor makes
/// the command layer directly integration-testable.
enum PhysicalShortcutMenuDispatcher {
    static func dispatch(_ event: NSEvent, settings: AppSettings, menu: NSMenu) -> Bool {
        let modifiers = shortcutModifiers(from: event.modifierFlags)
        guard !modifiers.isEmpty,
              let binding = ShortcutPhysicalKeyMapper.binding(for: event.keyCode, modifiers: modifiers),
              binding.isValid,
              ShortcutRegistry.isAssignable(binding),
              ShortcutCommand.allCases.contains(where: { settings.activeShortcut(for: $0) == binding }),
              let canonicalEvent = canonicalEvent(from: event, binding: binding)
        else { return false }
        guard hasEnabledMatchingMenuItem(for: canonicalEvent, in: menu) else { return false }
        return menu.performKeyEquivalent(with: canonicalEvent)
    }

    private static func hasEnabledMatchingMenuItem(for event: NSEvent, in menu: NSMenu) -> Bool {
        menu.items.contains { item in
            if item.keyEquivalent == event.charactersIgnoringModifiers,
               canonicalModifierFlags(from: shortcutModifiers(from: item.keyEquivalentModifierMask)) == event.modifierFlags {
                return item.isEnabled && !item.isHidden
            }
            return item.submenu.map { hasEnabledMatchingMenuItem(for: event, in: $0) } ?? false
        }
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
        var modifiers: Set<ShortcutModifier> = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func canonicalModifierFlags(from modifiers: Set<ShortcutModifier>) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }

    private static func canonicalEvent(from event: NSEvent, binding: ShortcutBinding) -> NSEvent? {
        guard let characters = canonicalCharacters(for: binding) else { return nil }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: canonicalModifierFlags(from: binding.modifiers),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )
    }

    private static func canonicalCharacters(for binding: ShortcutBinding) -> String? {
        switch binding.key {
        case .character: binding.character
        case .upArrow: String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case .downArrow: String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case .leftArrow: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case .rightArrow: String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case .delete: "\u{08}"
        case .forwardDelete: String(UnicodeScalar(NSDeleteFunctionKey)!)
        }
    }
}

private extension View {
    @ViewBuilder
    func configuredKeyboardShortcut(_ binding: ShortcutBinding?) -> some View {
        if let binding {
            keyboardShortcut(binding.keyboardShortcut)
        } else {
            self
        }
    }
}

/// Internal on purpose: AppKit derives the `NSWindow Frame …` autosave key from
/// `String(reflecting:)` of this type. A `private` generic type prints a heap
/// address ("unknown context at $1…"), so every launch wrote a new key instead
/// of updating one (tests P2-3). Do not make it private again.
struct ThemedSceneRoot<Content: View>: View {
    @Environment(AppState.self) private var appState
    @ViewBuilder var content: Content

    var body: some View {
        content
            .environment(\.frameTheme, appState.themeManager.frameTheme)
            .preferredColorScheme(appState.themeManager.preferredColorScheme)
            .onAppear(perform: updateTheme)
            .onChange(of: appState.settings.theme) { _, _ in updateTheme() }
            .onChange(of: appState.settings.accentColor) { _, _ in updateTheme() }
    }

    private func updateTheme() {
        appState.themeManager.update(
            selectedTheme: appState.settings.theme,
            accentColor: appState.settings.accentColor
        )
    }
}
