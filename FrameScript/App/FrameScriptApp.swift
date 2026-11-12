import AppKit
import SwiftUI

@main
struct FrameScriptApp: App {
    @NSApplicationDelegateAdaptor(FrameScriptAppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @Environment(\.openSettings) private var openSettings

    var body: some SwiftUI.Scene {
        WindowGroup {
            ThemedSceneRoot {
                AppRootView()
            }
            .environment(appState)
            .onAppear {
                shortcutRouter.start(using: appState)
                appDelegate.attach(appState)
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
                .environment(appState)
        }
    }

    @State private var shortcutRouter = AppKitPhysicalShortcutCommandRouter()

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(appState.localized("menu.newProject")) { appState.requestNewProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .newProject))
            Button(appState.localized("menu.newProjectFromTemplate")) {
                appState.requestNewProject(showsTemplateBrowser: true)
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .newProjectFromTemplate))
            Menu(appState.localized("welcome.newFromTemplate")) {
                ForEach(appState.scriptTemplates()) { template in
                    Button(appState.displayName(template)) {
                        appState.requestNewProject(template: template, locksTemplate: true)
                    }
                }
            }
            Divider()
            Button(appState.localized("menu.open")) { appState.openProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .openProject))
            Menu(appState.localized("menu.openRecent")) {
                if appState.recentProjectEntries.isEmpty {
                    Text(appState.localized("menu.noRecentProjects"))
                } else {
                    ForEach(appState.recentProjectEntries) { entry in
                        Button(entry.displayName) {
                            appState.openRecentProject(entry)
                        }
                    }
                    Divider()
                    Menu(appState.localized("recent.manage")) {
                        ForEach(appState.recentProjectEntries) { entry in
                            Menu(entry.displayName) {
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
                    Button(appState.localized("menu.clearMenu")) { appState.clearRecentProjects() }
                }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button(appState.localized("project.save")) { appState.saveProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .save))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("project.saveAs")) { appState.saveProjectAs() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .saveAs))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("menu.duplicateProject")) { appState.duplicateProject() }
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("project.rename")) { appState.renameProject() }
                .disabled(!appState.hasOpenProject)
            Divider()
            Button(appState.localized("project.browser")) { appState.returnToProjectList() }
                .disabled(!appState.hasOpenProject)
            Divider()
            Button(appState.localized("menu.deleteProject")) { appState.deleteProject() }
                .disabled(!appState.hasOpenProject)
        }

        CommandGroup(replacing: .importExport) {
            Button(appState.localized("menu.import")) { appState.importProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .import))
            Button(appState.localized("project.export")) { appState.exportProject() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .export))
                .disabled(!appState.hasOpenProject)
        }

        CommandGroup(replacing: .appSettings) {
            Button(appState.localized("command.openSettings")) {
                appState.openSettings(tab: .general)
                openSettings()
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .openSettings))
        }

        CommandMenu(appState.localized("menu.view")) {
            Button(appState.localized("mode.script")) { appState.selectMode(.script) }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .scriptMode))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("mode.bRoll")) { appState.selectMode(.bRoll) }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .visualsMode))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("mode.editing")) { appState.selectMode(.editing) }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .editingMode))
                .disabled(!appState.hasOpenProject)
            Divider()
            Button(appState.localized("command.toggleSidebar")) { appState.isSidebarVisible.toggle() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleContentsPanel))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("command.toggleAIReview")) {
                appState.settings.editorPreferences.showAIReviewPanel.toggle()
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleAIReview))
            .disabled(!appState.hasOpenProject)
            Button(appState.localized("command.toggleFocus")) { appState.isFocusModeEnabled.toggle() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .toggleFocusMode))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("toolbar.commandPalette")) { appState.isCommandPalettePresented = true }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .commandPalette))
            Button(appState.localized("command.showShortcuts")) { appState.isShortcutsPresented = true }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .showShortcuts))
        }

        CommandMenu(appState.localized("menu.scene")) {
            Button(appState.localized("scene.add")) { appState.addScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .addScene))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("scene.duplicate")) { appState.duplicateSelectedScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .duplicateScene))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("scene.delete")) { appState.deleteSelectedScene() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .deleteScene))
                .disabled(!appState.hasOpenProject)
            Divider()
            Button(appState.localized("scene.moveUp")) { appState.moveSelectedSceneUp() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .moveSceneUp))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("scene.moveDown")) { appState.moveSelectedSceneDown() }
                .configuredKeyboardShortcut(appState.shortcutBinding(for: .moveSceneDown))
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("scene.rename")) { appState.renameSelectedScene() }
                .disabled(!appState.hasOpenProject)
        }

        CommandMenu(appState.localized("menu.tools")) {
            Button(appState.localized("ai.analyzeCurrentScene")) {
                appState.settings.editorPreferences.showAIReviewPanel = true
                Task { await appState.analyzeSelectedScene() }
            }
            .configuredKeyboardShortcut(appState.shortcutBinding(for: .analyzeCurrentScene))
            .disabled(!appState.hasOpenProject)
            Button(appState.localized("menu.analyzeFullScript")) {
                appState.settings.editorPreferences.showAIReviewPanel = true
                Task { await appState.analyzeFullScript() }
            }
            .disabled(!appState.hasOpenProject)
            Button(appState.localized("menu.generateBRoll")) { appState.generateBRollForSelectedScene() }
                .disabled(!appState.hasOpenProject)
            Button(appState.localized("menu.generateEditing")) { appState.generateEditingNotesForSelectedScene() }
                .disabled(!appState.hasOpenProject)
        }
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

private struct ThemedSceneRoot<Content: View>: View {
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
