import AppKit

/// The application menus that carry a configurable keyboard shortcut.
///
/// `FrameScriptApp.appCommands` builds the SwiftUI commands scene; this
/// description is the same list in data form so tests can build a real
/// `NSMenu` and assert that every `ShortcutCommand` has exactly one item with
/// the active key equivalent (commands P3-11, which also settles the
/// unverifiable "menu items do not update" claim).
enum ApplicationMenuID: String, CaseIterable, Equatable {
    case file, view, scene, tools, application
}

struct ApplicationMenuItem: Identifiable, Equatable {
    let command: ShortcutCommand
    let menu: ApplicationMenuID

    var id: ShortcutCommand { command }
    var titleKey: String { command.definition.localizationKey }
}

enum ApplicationMenuSpec {
    /// Every configurable command, in menu order. `ShortcutCommand.allCases`
    /// must map one-to-one onto this list.
    static let items: [ApplicationMenuItem] = [
        .init(command: .newProject, menu: .file),
        .init(command: .newProjectFromTemplate, menu: .file),
        .init(command: .openProject, menu: .file),
        // The former File > Import item now opens the demo project; its raw
        // value still carries the user's customised ⇧⌘I binding.
        .init(command: .import, menu: .file),
        .init(command: .save, menu: .file),
        .init(command: .saveAs, menu: .file),
        .init(command: .export, menu: .file),
        .init(command: .importEscaleta, menu: .file),
        .init(command: .exportEscaleta, menu: .file),
        .init(command: .exportAVScript, menu: .file),
        .init(command: .showBackups, menu: .file),

        .init(command: .scriptMode, menu: .view),
        .init(command: .visualsMode, menu: .view),
        .init(command: .editingMode, menu: .view),
        .init(command: .clipsMode, menu: .view),
        .init(command: .timelineMode, menu: .view),
        .init(command: .avScriptMode, menu: .view),
        .init(command: .createClip, menu: .view),
        .init(command: .timelineZoomIn, menu: .view),
        .init(command: .timelineZoomOut, menu: .view),
        .init(command: .teleprompter, menu: .view),
        .init(command: .toggleContentsPanel, menu: .view),
        .init(command: .toggleAIReview, menu: .view),
        .init(command: .toggleFocusMode, menu: .view),
        .init(command: .researchPanel, menu: .view),
        .init(command: .assets, menu: .view),
        .init(command: .commandPalette, menu: .view),
        .init(command: .showShortcuts, menu: .view),

        .init(command: .addScene, menu: .scene),
        .init(command: .duplicateScene, menu: .scene),
        .init(command: .deleteScene, menu: .scene),
        .init(command: .moveSceneUp, menu: .scene),
        .init(command: .moveSceneDown, menu: .scene),
        .init(command: .previousScene, menu: .scene),
        .init(command: .nextScene, menu: .scene),

        .init(command: .analyzeCurrentScene, menu: .tools),
        .init(command: .generateHook, menu: .tools),
        .init(command: .suggestRehooks, menu: .tools),
        .init(command: .recordTake, menu: .tools),
        .init(command: .toggleRecordingPanel, menu: .tools),
        .init(command: .productionChecklist, menu: .tools),
        .init(command: .publishingPack, menu: .tools),

        .init(command: .openSettings, menu: .application)
    ]

    static func items(in menu: ApplicationMenuID) -> [ApplicationMenuItem] {
        items.filter { $0.menu == menu }
    }
}

/// Builds an `NSMenu` that mirrors the SwiftUI commands scene.
@MainActor
enum ApplicationMenuBuilder {
    /// - Parameters:
    ///   - settings: source of the active binding (including explicit
    ///     unassignments).
    ///   - isEnabled: enablement matrix entry for the command.
    ///   - localized: resolves a localization key for the menu title.
    static func makeMenu(
        _ menu: ApplicationMenuID,
        title: String,
        settings: AppSettings,
        availability: CommandAvailability,
        localized: (String) -> String
    ) -> NSMenu {
        let result = NSMenu(title: title)
        for item in ApplicationMenuSpec.items(in: menu) {
            let menuItem = NSMenuItem(title: localized(item.titleKey), action: nil, keyEquivalent: "")
            if let binding = settings.activeShortcut(for: item.command) {
                menuItem.keyEquivalent = binding.appKitKeyEquivalent
                menuItem.keyEquivalentModifierMask = binding.appKitModifierMask
            }
            menuItem.isEnabled = availability.isEnabled(item.command)
            menuItem.representedObject = item.command.rawValue
            result.addItem(menuItem)
        }
        return result
    }
}
