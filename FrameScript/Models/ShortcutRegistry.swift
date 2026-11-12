import SwiftUI

/// A persisted, layout-independent description of an application shortcut.
enum ShortcutKey: String, Codable, CaseIterable, Hashable {
    case character
    case upArrow, downArrow, leftArrow, rightArrow
    case delete, forwardDelete

    var display: String {
        switch self {
        case .character: ""
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .delete: "⌫"
        case .forwardDelete: "⌦"
        }
    }
}

enum ShortcutModifier: String, Codable, CaseIterable, Hashable {
    case control, option, shift, command

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }
}

struct ShortcutBinding: Codable, Hashable {
    var key: ShortcutKey
    /// Used only when `key == .character`; supports letters, digits, and punctuation.
    var character: String?
    var modifiers: Set<ShortcutModifier>

    init(_ character: String, modifiers: Set<ShortcutModifier>) {
        self.key = .character
        self.character = Self.canonicalCharacter(from: character)
        self.modifiers = modifiers
    }

    init(key: ShortcutKey, modifiers: Set<ShortcutModifier>) {
        self.key = key
        self.character = nil
        self.modifiers = modifiers
    }

    var display: String {
        ShortcutModifier.allCases.filter(modifiers.contains).map(\.symbol).joined() + (key == .character ? (character ?? "").uppercased() : key.display)
    }

    var isValid: Bool {
        if key == .character {
            guard let character, Self.canonicalCharacter(from: character) == character else { return false }
            return !modifiers.isEmpty
        }
        return true
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: swiftUIModifiers)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case .character: KeyEquivalent(Character(character ?? " "))
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .delete: .delete
        case .forwardDelete: .deleteForward
        }
    }

    private var swiftUIModifiers: EventModifiers {
        modifiers.reduce(into: EventModifiers()) { result, modifier in
            switch modifier {
            case .control: result.insert(.control)
            case .option: result.insert(.option)
            case .shift: result.insert(.shift)
            case .command: result.insert(.command)
            }
        }
    }

    /// Converts persisted character bindings to their ANSI-US physical-key
    /// equivalent. This is deliberately independent of the active input source.
    private static func canonicalCharacter(from value: String) -> String? {
        guard value.count == 1, let character = value.lowercased().first else { return nil }
        if let mapped = legacyRussianCharacters[character] { return mapped }
        return ansiUSCharacters.contains(character) ? String(character) : nil
    }

    private static let ansiUSCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;'`,./")

    /// ЙЦУКЕН bindings written by earlier releases were derived from the active
    /// layout. These are the deterministic key-position equivalents.
    private static let legacyRussianCharacters: [Character: String] = [
        "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i", "щ": "o", "з": "p", "х": "[", "ъ": "]",
        "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k", "д": "l", "ж": ";", "э": "'",
        "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m", "б": ",", "ю": ".", "ё": "`"
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ShortcutKey.self, forKey: .key)
        modifiers = try container.decode(Set<ShortcutModifier>.self, forKey: .modifiers)
        if key == .character {
            character = Self.canonicalCharacter(from: try container.decodeIfPresent(String.self, forKey: .character) ?? "")
        } else {
            character = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(modifiers, forKey: .modifiers)
        if key == .character {
            try container.encode(Self.canonicalCharacter(from: character ?? "") ?? "", forKey: .character)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case key, character, modifiers
    }
}

/// The application’s canonical map from macOS virtual key codes to ANSI-US
/// shortcut keys. It intentionally never asks the active input source to
/// translate a key position.
enum ShortcutPhysicalKeyMapper {
    static func binding(for keyCode: UInt16, modifiers: Set<ShortcutModifier>) -> ShortcutBinding? {
        switch keyCode {
        case 51: return .init(key: .delete, modifiers: modifiers)
        case 117: return .init(key: .forwardDelete, modifiers: modifiers)
        case 123: return .init(key: .leftArrow, modifiers: modifiers)
        case 124: return .init(key: .rightArrow, modifiers: modifiers)
        case 125: return .init(key: .downArrow, modifiers: modifiers)
        case 126: return .init(key: .upArrow, modifiers: modifiers)
        default:
            guard let character = ansiUSCharacters[keyCode] else { return nil }
            return .init(character, modifiers: modifiers)
        }
    }

    private static let ansiUSCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`"
    ]
}

/// The persisted override for a command. Encoding assignments as their binding
/// keeps the existing preferences format compatible; `null` is reserved for an
/// explicit unassigned command.
enum ShortcutOverride: Codable, Hashable {
    case assigned(ShortcutBinding)
    case unassigned

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .unassigned
        } else {
            let binding = try container.decode(ShortcutBinding.self)
            self = binding.isValid ? .assigned(binding) : .unassigned
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .assigned(binding) where binding.isValid:
            try container.encode(binding)
        case .assigned, .unassigned:
            try container.encodeNil()
        }
    }
}

enum ShortcutCategory: String, CaseIterable, Hashable {
    case project, scenes, workspace, ai, application

    var localizationKey: String { "shortcuts.category.\(rawValue)" }
}

enum ShortcutCommand: String, Codable, CaseIterable, Identifiable, Hashable {
    case newProject, newProjectFromTemplate, openProject, save, saveAs, `import`, export
    case addScene, duplicateScene, deleteScene, moveSceneUp, moveSceneDown
    case scriptMode, visualsMode, editingMode, commandPalette, toggleContentsPanel, toggleAIReview, toggleFocusMode
    case analyzeCurrentScene, openSettings, showShortcuts, showBackups
    case generateHook, suggestRehooks

    var id: String { rawValue }

    var definition: ShortcutDefinition { ShortcutRegistry.definition(for: self) }
}

struct ShortcutDefinition: Identifiable {
    let command: ShortcutCommand
    let localizationKey: String
    let category: ShortcutCategory
    let factoryDefault: ShortcutBinding
    let order: Int

    var id: ShortcutCommand { command }
}

/// The sole formatter for shortcut labels outside the shortcut recorder.
/// It always reflects the current binding, including an explicit unassignment.
enum ShortcutDisplayFormatter {
    static func display(
        for command: ShortcutCommand,
        settings: AppSettings,
        notAssigned: String
    ) -> String {
        settings.activeShortcut(for: command)?.display ?? notAssigned
    }
}

enum ShortcutRegistry {
    /// Bindings owned by macOS, the application menu, or standard text editing.
    /// They are intentionally outside the configurable FrameScript command registry.
    /// Keeping them here leaves native menu handling authoritative.
    static let nonAssignableBindings: Set<ShortcutBinding> = [
        .init("q", modifiers: [.command]),
        .init("w", modifiers: [.command]),
        .init("h", modifiers: [.command]),
        .init("h", modifiers: [.command, .option]),
        .init("m", modifiers: [.command]),
        .init("z", modifiers: [.command]),
        .init("z", modifiers: [.command, .shift]),
        .init("x", modifiers: [.command]),
        .init("c", modifiers: [.command]),
        .init("v", modifiers: [.command]),
        .init("a", modifiers: [.command])
    ]

    static func isAssignable(_ binding: ShortcutBinding) -> Bool {
        binding.isValid && !nonAssignableBindings.contains(binding)
    }

    static let definitions: [ShortcutDefinition] = [
        .init(command: .newProject, localizationKey: "menu.newProject", category: .project, factoryDefault: .init("n", modifiers: [.command]), order: 0),
        .init(command: .newProjectFromTemplate, localizationKey: "menu.newProjectFromTemplate", category: .project, factoryDefault: .init("n", modifiers: [.command, .shift]), order: 1),
        .init(command: .openProject, localizationKey: "menu.open", category: .project, factoryDefault: .init("o", modifiers: [.command]), order: 2),
        .init(command: .save, localizationKey: "project.save", category: .project, factoryDefault: .init("s", modifiers: [.command]), order: 3),
        .init(command: .saveAs, localizationKey: "project.saveAs", category: .project, factoryDefault: .init("s", modifiers: [.command, .shift]), order: 4),
        .init(command: .import, localizationKey: "menu.import", category: .project, factoryDefault: .init("i", modifiers: [.command, .shift]), order: 5),
        .init(command: .export, localizationKey: "project.export", category: .project, factoryDefault: .init("e", modifiers: [.command]), order: 6),
        .init(command: .showBackups, localizationKey: "backups.menu", category: .project, factoryDefault: .init("b", modifiers: [.command, .shift]), order: 7),
        .init(command: .addScene, localizationKey: "scene.add", category: .scenes, factoryDefault: .init("n", modifiers: [.command, .option]), order: 0),
        .init(command: .duplicateScene, localizationKey: "scene.duplicate", category: .scenes, factoryDefault: .init("d", modifiers: [.command]), order: 1),
        .init(command: .deleteScene, localizationKey: "scene.delete", category: .scenes, factoryDefault: .init(key: .delete, modifiers: [.command]), order: 2),
        .init(command: .moveSceneUp, localizationKey: "scene.moveUp", category: .scenes, factoryDefault: .init(key: .upArrow, modifiers: [.command, .option]), order: 3),
        .init(command: .moveSceneDown, localizationKey: "scene.moveDown", category: .scenes, factoryDefault: .init(key: .downArrow, modifiers: [.command, .option]), order: 4),
        .init(command: .scriptMode, localizationKey: "mode.script", category: .workspace, factoryDefault: .init("1", modifiers: [.command]), order: 0),
        .init(command: .visualsMode, localizationKey: "mode.bRoll", category: .workspace, factoryDefault: .init("2", modifiers: [.command]), order: 1),
        .init(command: .editingMode, localizationKey: "mode.editing", category: .workspace, factoryDefault: .init("3", modifiers: [.command]), order: 2),
        .init(command: .commandPalette, localizationKey: "toolbar.commandPalette", category: .workspace, factoryDefault: .init("k", modifiers: [.command]), order: 3),
        .init(command: .toggleContentsPanel, localizationKey: "command.toggleSidebar", category: .workspace, factoryDefault: .init("\\", modifiers: [.command]), order: 4),
        .init(command: .toggleAIReview, localizationKey: "command.toggleAIReview", category: .workspace, factoryDefault: .init("r", modifiers: [.command, .shift]), order: 5),
        .init(command: .toggleFocusMode, localizationKey: "command.toggleFocus", category: .workspace, factoryDefault: .init("'", modifiers: [.command]), order: 6),
        .init(command: .analyzeCurrentScene, localizationKey: "ai.analyzeCurrentScene", category: .ai, factoryDefault: .init("a", modifiers: [.command, .shift]), order: 0),
        .init(command: .generateHook, localizationKey: "menu.generateHook", category: .ai, factoryDefault: .init("g", modifiers: [.command, .shift]), order: 1),
        .init(command: .suggestRehooks, localizationKey: "menu.suggestRehooks", category: .ai, factoryDefault: .init("h", modifiers: [.command, .shift]), order: 2),
        .init(command: .openSettings, localizationKey: "command.openSettings", category: .application, factoryDefault: .init(",", modifiers: [.command]), order: 0),
        .init(command: .showShortcuts, localizationKey: "command.showShortcuts", category: .application, factoryDefault: .init("/", modifiers: [.command, .shift]), order: 1)
    ]

    static func definition(for command: ShortcutCommand) -> ShortcutDefinition {
        if let definition = definitions.first(where: { $0.command == command }) {
            return definition
        }
        // The registry is static and intentionally complete; fail fast during
        // development if it drifts. In release builds, keep displaying the
        // command with an unassigned-style fallback instead of crashing.
        assertionFailure("Missing ShortcutDefinition for \(command.rawValue)")
        return fallbackDefinition(for: command)
    }

    static func fallbackDefinition(for command: ShortcutCommand) -> ShortcutDefinition {
        ShortcutDefinition(
            command: command,
            localizationKey: "command.\(command.rawValue)",
            category: .application,
            factoryDefault: .init("0", modifiers: [.command, .option, .control, .shift]),
            order: Int.max
        )
    }

    static func binding(for command: ShortcutCommand, overrides: [ShortcutCommand: ShortcutOverride]) -> ShortcutBinding? {
        switch overrides[command] {
        case let .assigned(binding) where isAssignable(binding): binding
        case .assigned: nil
        case .unassigned: nil
        case nil: definition(for: command).factoryDefault
        }
    }

    static func conflict(for binding: ShortcutBinding, excluding command: ShortcutCommand, overrides: [ShortcutCommand: ShortcutOverride]) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { candidate in
            candidate != command && self.binding(for: candidate, overrides: overrides) == binding
        }
    }

    /// Settings decoding is the one-time migration boundary for legacy
    /// layout-derived values. Explicit valid assignments take precedence over
    /// factory defaults; any ambiguous duplicate is made explicitly unassigned.
    static func normalizedOverrides(_ overrides: [ShortcutCommand: ShortcutOverride]) -> [ShortcutCommand: ShortcutOverride] {
        var normalized: [ShortcutCommand: ShortcutOverride] = [:]
        var usedBindings = Set<ShortcutBinding>()

        for command in ShortcutCommand.allCases {
            switch overrides[command] {
            case let .assigned(binding) where isAssignable(binding) && !usedBindings.contains(binding):
                normalized[command] = .assigned(binding)
                usedBindings.insert(binding)
            case .assigned:
                normalized[command] = .unassigned
            case .unassigned:
                normalized[command] = .unassigned
            case nil:
                break
            }
        }

        for command in ShortcutCommand.allCases where overrides[command] == nil {
            let defaultBinding = definition(for: command).factoryDefault
            if usedBindings.contains(defaultBinding) {
                normalized[command] = .unassigned
            } else {
                usedBindings.insert(defaultBinding)
            }
        }
        return normalized
    }
}

extension AppSettings {
    func activeShortcut(for command: ShortcutCommand) -> ShortcutBinding? {
        ShortcutRegistry.binding(for: command, overrides: shortcutOverrides)
    }

    mutating func setShortcut(_ binding: ShortcutBinding, for command: ShortcutCommand) -> ShortcutCommand? {
        guard ShortcutRegistry.isAssignable(binding) else { return command }
        if let conflict = ShortcutRegistry.conflict(for: binding, excluding: command, overrides: shortcutOverrides) {
            return conflict
        }
        applyShortcut(binding, for: command)
        return nil
    }

    mutating func reassignShortcut(_ binding: ShortcutBinding, for command: ShortcutCommand) -> ShortcutCommand? {
        guard ShortcutRegistry.isAssignable(binding) else { return command }
        let displacedCommand = ShortcutRegistry.conflict(for: binding, excluding: command, overrides: shortcutOverrides)
        applyShortcut(binding, for: command)
        if let displacedCommand {
            shortcutOverrides[displacedCommand] = .unassigned
        }
        return displacedCommand
    }

    func resetConflict(for command: ShortcutCommand) -> ShortcutCommand? {
        ShortcutRegistry.conflict(
            for: command.definition.factoryDefault,
            excluding: command,
            overrides: shortcutOverrides
        )
    }

    mutating func resetShortcut(_ command: ShortcutCommand) -> ShortcutCommand? {
        if let conflict = resetConflict(for: command) { return conflict }
        shortcutOverrides.removeValue(forKey: command)
        return nil
    }

    mutating func reassignFactoryDefault(to command: ShortcutCommand) -> ShortcutCommand? {
        reassignShortcut(command.definition.factoryDefault, for: command)
    }

    mutating func resetAllShortcuts() {
        // Factory defaults are registry-validated as unique, so this is an
        // atomic restoration of the complete active shortcut set.
        shortcutOverrides.removeAll()
    }

    private mutating func applyShortcut(_ binding: ShortcutBinding, for command: ShortcutCommand) {
        if binding == command.definition.factoryDefault {
            shortcutOverrides.removeValue(forKey: command)
        } else {
            shortcutOverrides[command] = .assigned(binding)
        }
    }
}
