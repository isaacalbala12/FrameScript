import Foundation
import Observation

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case script = "Script"
    case bRoll = "B-Roll"
    case editing = "Editing"

    var id: String { rawValue }

}

enum SectionType: String, Codable, CaseIterable, Identifiable {
    case hook = "Hook"
    case problem = "Problem"
    case whyThisMatters = "Why this matters"
    case explanation = "Explanation"
    case example = "Example"
    case takeaway = "Takeaway"
    case cta = "CTA"
    case custom = "Custom"

    var id: String { rawValue }
}

enum SegmentType: String, Codable, CaseIterable, Identifiable {
    case scene
    case paragraph
    case sentence

    var id: String { rawValue }
}

enum BRollSourceType: String, Codable, CaseIterable, Identifiable {
    case stockFootage = "Stock footage"
    case talkingHead = "Talking head"
    case screenRecording = "Screen recording"
    case animation = "Animation"
    case infographic = "Infographic"
    case textOnScreen = "Text on screen"
    case memeInsert = "Meme / insert"
    case productShot = "Product shot"
    case screenshot = "Screenshot"
    case custom = "Custom"

    var id: String { rawValue }
}

enum BRollStatus: String, Codable, CaseIterable, Identifiable {
    case idea = "Idea"
    case planned = "Planned"
    case sourced = "Sourced"
    case done = "Done"

    var id: String { rawValue }
}

enum AICommentStatus: String, Codable, CaseIterable {
    case new
    case dismissed
    case applied
}

enum AICommentSeverity: String, Codable, CaseIterable {
    case note
    case suggestion
    case important
}

enum TemplateCategory: String, Codable, CaseIterable, Identifiable {
    case script
    case bRoll
    case editing

    var id: String { rawValue }
}

struct TextAnchor: Codable, Hashable {
    var startUTF16: Int
    var lengthUTF16: Int
    var selectedText: String
    var prefixContext: String
    var suffixContext: String

    var nsRange: NSRange {
        NSRange(location: startUTF16, length: lengthUTF16)
    }

    init(startUTF16: Int, lengthUTF16: Int, selectedText: String, prefixContext: String = "", suffixContext: String = "") {
        self.startUTF16 = max(0, startUTF16)
        self.lengthUTF16 = max(0, lengthUTF16)
        self.selectedText = selectedText
        self.prefixContext = prefixContext
        self.suffixContext = suffixContext
    }
}

@Observable
final class FrameProject: Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var templateID: UUID?
    var settingsOverride: ProjectSettingsOverride?
    var exportPresets: [ExportPreset]
    var scenes: [Scene]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        templateID: UUID? = nil,
        scenes: [Scene] = [],
        settingsOverride: ProjectSettingsOverride? = nil,
        exportPresets: [ExportPreset] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.templateID = templateID
        self.scenes = scenes
        self.settingsOverride = settingsOverride
        self.exportPresets = exportPresets
    }
}

@Observable
final class Scene: Identifiable {
    var id: UUID
    var order: Int
    var sectionType: SectionType
    var title: String
    var scriptText: String
    var notes: String
    var estimatedDuration: TimeInterval
    var textSegments: [TextSegment]
    var aiComments: [AIComment]
    var bRollItems: [BRollItem]
    var editingItems: [EditingItem]

    init(
        id: UUID = UUID(),
        order: Int,
        sectionType: SectionType,
        title: String,
        scriptText: String,
        notes: String = "",
        estimatedDuration: TimeInterval = 0,
        textSegments: [TextSegment] = [],
        aiComments: [AIComment] = [],
        bRollItems: [BRollItem] = [],
        editingItems: [EditingItem] = []
    ) {
        self.id = id
        self.order = order
        self.sectionType = sectionType
        self.title = title
        self.scriptText = scriptText
        self.notes = notes
        self.estimatedDuration = estimatedDuration
        self.textSegments = textSegments
        self.aiComments = aiComments
        self.bRollItems = bRollItems
        self.editingItems = editingItems
    }
}

@Observable
final class TextSegment: Identifiable {
    var id: UUID
    var sceneID: UUID
    var order: Int
    var sourceText: String
    var segmentType: SegmentType
    var timingEstimate: TimeInterval

    init(
        id: UUID = UUID(),
        sceneID: UUID,
        order: Int,
        sourceText: String,
        segmentType: SegmentType,
        timingEstimate: TimeInterval = 0
    ) {
        self.id = id
        self.sceneID = sceneID
        self.order = order
        self.sourceText = sourceText
        self.segmentType = segmentType
        self.timingEstimate = timingEstimate
    }
}

@Observable
final class BRollItem: Identifiable {
    var id: UUID
    var textAnchor: TextAnchor?
    var linkedSegmentID: UUID?
    var templateType: String
    var sourceType: BRollSourceType
    var descriptionText: String
    var mood: String
    var framing: String
    var motion: String
    var duration: TimeInterval
    var notes: String
    var status: BRollStatus

    init(
        id: UUID = UUID(),
        textAnchor: TextAnchor? = nil,
        linkedSegmentID: UUID? = nil,
        templateType: String,
        sourceType: BRollSourceType,
        descriptionText: String,
        mood: String = "",
        framing: String = "",
        motion: String = "",
        duration: TimeInterval = 0,
        notes: String = "",
        status: BRollStatus = .idea
    ) {
        self.id = id
        self.textAnchor = textAnchor
        self.linkedSegmentID = linkedSegmentID
        self.templateType = templateType
        self.sourceType = sourceType
        self.descriptionText = descriptionText
        self.mood = mood
        self.framing = framing
        self.motion = motion
        self.duration = duration
        self.notes = notes
        self.status = status
    }
}

@Observable
final class EditingItem: Identifiable {
    var id: UUID
    var textAnchor: TextAnchor?
    var linkedSegmentID: UUID?
    var templateType: String
    var cutStyle: String
    var transition: String
    var subtitleStyle: String
    var emphasis: String
    var zoom: String
    var sfx: String
    var musicCue: String
    var graphics: String
    var notes: String

    init(
        id: UUID = UUID(),
        textAnchor: TextAnchor? = nil,
        linkedSegmentID: UUID? = nil,
        templateType: String,
        cutStyle: String,
        transition: String,
        subtitleStyle: String,
        emphasis: String = "",
        zoom: String = "",
        sfx: String = "",
        musicCue: String = "",
        graphics: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.textAnchor = textAnchor
        self.linkedSegmentID = linkedSegmentID
        self.templateType = templateType
        self.cutStyle = cutStyle
        self.transition = transition
        self.subtitleStyle = subtitleStyle
        self.emphasis = emphasis
        self.zoom = zoom
        self.sfx = sfx
        self.musicCue = musicCue
        self.graphics = graphics
        self.notes = notes
    }
}

@Observable
final class AIComment: Identifiable {
    var id: UUID
    var sceneID: UUID?
    var segmentID: UUID?
    var type: String
    var severity: AICommentSeverity
    var message: String
    var suggestion: String
    var status: AICommentStatus

    init(
        id: UUID = UUID(),
        sceneID: UUID? = nil,
        segmentID: UUID? = nil,
        type: String,
        severity: AICommentSeverity,
        message: String,
        suggestion: String = "",
        status: AICommentStatus = .new
    ) {
        self.id = id
        self.sceneID = sceneID
        self.segmentID = segmentID
        self.type = type
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
        self.status = status
    }
}

struct FrameTemplate: Identifiable, Codable, Hashable {
    var id: UUID
    var category: TemplateCategory
    var name: String
    var builtIn: Bool
    var structureDefinition: [String]
    var customFields: [String]
    var builtInSourceName: String? = nil

    var isCustomizedBuiltIn: Bool {
        builtInSourceName != nil
    }

    var isBlank: Bool {
        category == .script && (builtInSourceName ?? name) == "Blank"
    }
}

struct AppSettings: Codable, Hashable {
    var generalPreferences: GeneralPreferences
    var theme: AppearanceTheme
    var accentColor: AccentPalette
    var editorPreferences: EditorPreferences
    var aiPreferences: AIPreferences
    var voicePreferences: VoicePreferences
    var exportPreferences: ExportPreferences
    var windowPreferences: WindowPreferences
    /// User bindings are application preferences and never belong in project files.
    var shortcutOverrides: [ShortcutCommand: ShortcutOverride] = [:]

    enum CodingKeys: String, CodingKey {
        case generalPreferences, theme, accentColor, editorPreferences, aiPreferences
        case voicePreferences, exportPreferences, windowPreferences, shortcutOverrides
    }

    init(
        generalPreferences: GeneralPreferences,
        theme: AppearanceTheme,
        accentColor: AccentPalette,
        editorPreferences: EditorPreferences,
        aiPreferences: AIPreferences,
        voicePreferences: VoicePreferences,
        exportPreferences: ExportPreferences,
        windowPreferences: WindowPreferences,
        shortcutOverrides: [ShortcutCommand: ShortcutOverride] = [:]
    ) {
        self.generalPreferences = generalPreferences
        self.theme = theme
        self.accentColor = accentColor
        self.editorPreferences = editorPreferences
        self.aiPreferences = aiPreferences
        self.voicePreferences = voicePreferences
        self.exportPreferences = exportPreferences
        self.windowPreferences = windowPreferences
        self.shortcutOverrides = shortcutOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generalPreferences = try container.decode(GeneralPreferences.self, forKey: .generalPreferences)
        theme = try container.decode(AppearanceTheme.self, forKey: .theme)
        accentColor = try container.decode(AccentPalette.self, forKey: .accentColor)
        editorPreferences = try container.decode(EditorPreferences.self, forKey: .editorPreferences)
        aiPreferences = try container.decode(AIPreferences.self, forKey: .aiPreferences)
        voicePreferences = try container.decode(VoicePreferences.self, forKey: .voicePreferences)
        exportPreferences = try container.decode(ExportPreferences.self, forKey: .exportPreferences)
        windowPreferences = try container.decode(WindowPreferences.self, forKey: .windowPreferences)
        // Existing installations did not encode shortcut preferences.
        let decodedOverrides = try container.decodeIfPresent([ShortcutCommand: ShortcutOverride].self, forKey: .shortcutOverrides) ?? [:]
        shortcutOverrides = ShortcutRegistry.normalizedOverrides(decodedOverrides)
    }
}

struct GeneralPreferences: Codable, Hashable {
    var launchBehavior: LaunchBehavior
    var language: AppLanguage
    var autosaveEnabled: Bool
    var autosaveIntervalSeconds: Int
    var defaultNewProjectTemplate: String
    var blankProjectStart: BlankProjectStart
    var defaultSplitMode: SegmentType
    var confirmBeforeDeleting: Bool

    init(
        launchBehavior: LaunchBehavior,
        language: AppLanguage = .system,
        autosaveEnabled: Bool,
        autosaveIntervalSeconds: Int,
        defaultNewProjectTemplate: String,
        blankProjectStart: BlankProjectStart = .oneEmptyScene,
        defaultSplitMode: SegmentType,
        confirmBeforeDeleting: Bool
    ) {
        self.launchBehavior = launchBehavior
        self.language = language
        self.autosaveEnabled = autosaveEnabled
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
        self.defaultNewProjectTemplate = defaultNewProjectTemplate
        self.blankProjectStart = blankProjectStart
        self.defaultSplitMode = defaultSplitMode
        self.confirmBeforeDeleting = confirmBeforeDeleting
    }

    enum CodingKeys: String, CodingKey {
        case launchBehavior
        // Legacy keys are read only to migrate existing settings files.
        case showProjectBrowserOnLaunch
        case restoreLastProjectOnLaunch
        case language
        case autosaveEnabled
        case autosaveIntervalSeconds
        case defaultNewProjectTemplate
        case blankProjectStart
        case defaultSplitMode
        case confirmBeforeDeleting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let behavior = try container.decodeIfPresent(LaunchBehavior.self, forKey: .launchBehavior) {
            launchBehavior = behavior
        } else {
            let restoreLastProject = try container.decodeIfPresent(Bool.self, forKey: .restoreLastProjectOnLaunch) ?? false
            let showProjectBrowser = try container.decodeIfPresent(Bool.self, forKey: .showProjectBrowserOnLaunch) ?? true
            launchBehavior = restoreLastProject && !showProjectBrowser ? .restoreLastProject : .showProjectBrowser
        }
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
        autosaveEnabled = try container.decode(Bool.self, forKey: .autosaveEnabled)
        autosaveIntervalSeconds = try container.decode(Int.self, forKey: .autosaveIntervalSeconds)
        defaultNewProjectTemplate = try container.decode(String.self, forKey: .defaultNewProjectTemplate)
        blankProjectStart = try container.decodeIfPresent(BlankProjectStart.self, forKey: .blankProjectStart) ?? .oneEmptyScene
        defaultSplitMode = try container.decode(SegmentType.self, forKey: .defaultSplitMode)
        confirmBeforeDeleting = try container.decode(Bool.self, forKey: .confirmBeforeDeleting)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchBehavior, forKey: .launchBehavior)
        try container.encode(language, forKey: .language)
        try container.encode(autosaveEnabled, forKey: .autosaveEnabled)
        try container.encode(autosaveIntervalSeconds, forKey: .autosaveIntervalSeconds)
        try container.encode(defaultNewProjectTemplate, forKey: .defaultNewProjectTemplate)
        try container.encode(blankProjectStart, forKey: .blankProjectStart)
        try container.encode(defaultSplitMode, forKey: .defaultSplitMode)
        try container.encode(confirmBeforeDeleting, forKey: .confirmBeforeDeleting)
    }
}

enum LaunchBehavior: String, Codable, CaseIterable, Identifiable {
    case showProjectBrowser
    case restoreLastProject

    var id: String { rawValue }

    func shouldRestoreLastProject(hasOpenProject: Bool, hasRecentProject: Bool) -> Bool {
        self == .restoreLastProject && !hasOpenProject && hasRecentProject
    }
}

enum BlankProjectStart: String, Codable, CaseIterable, Identifiable {
    case noScenes = "No scenes"
    case oneEmptyScene = "One empty scene"

    var id: String { rawValue }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case russian

    var id: String { rawValue }

    /// Native name of the language. `.system` has no native name and is
    /// localized through `displayName(in:)` in the language picker.
    var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .spanish: "Español"
        case .russian: "Русский"
        }
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        guard self == .system else { return displayName }
        return L10n.tr("language.system", language: interfaceLanguage)
    }
}

struct ProjectSettingsOverride: Codable, Hashable {
    var wordsPerMinute: Int?
    var defaultSplitMode: SegmentType?
}

struct EditorPreferences: Codable, Hashable {
    var wordsPerMinute: Int
    var fontSize: Double
    var spellcheck: Bool
    var smartQuotes: Bool
    var showWordCount: Bool
    var showSceneDuration: Bool
    var showAIReviewPanel: Bool
    var defaultNotesVisibility: NotesDefaultVisibility

    init(
        wordsPerMinute: Int,
        fontSize: Double,
        spellcheck: Bool,
        smartQuotes: Bool,
        showWordCount: Bool,
        showSceneDuration: Bool,
        showAIReviewPanel: Bool,
        defaultNotesVisibility: NotesDefaultVisibility = .collapsed
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.fontSize = fontSize
        self.spellcheck = spellcheck
        self.smartQuotes = smartQuotes
        self.showWordCount = showWordCount
        self.showSceneDuration = showSceneDuration
        self.showAIReviewPanel = showAIReviewPanel
        self.defaultNotesVisibility = defaultNotesVisibility
    }

    enum CodingKeys: String, CodingKey {
        case wordsPerMinute
        case fontSize
        case spellcheck
        case smartQuotes
        case showWordCount
        case showSceneDuration
        case showAIReviewPanel
        case defaultNotesVisibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wordsPerMinute = try container.decode(Int.self, forKey: .wordsPerMinute)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        spellcheck = try container.decode(Bool.self, forKey: .spellcheck)
        smartQuotes = try container.decode(Bool.self, forKey: .smartQuotes)
        showWordCount = try container.decode(Bool.self, forKey: .showWordCount)
        showSceneDuration = try container.decode(Bool.self, forKey: .showSceneDuration)
        showAIReviewPanel = try container.decodeIfPresent(Bool.self, forKey: .showAIReviewPanel) ?? true
        defaultNotesVisibility = try container.decodeIfPresent(NotesDefaultVisibility.self, forKey: .defaultNotesVisibility) ?? .collapsed
    }
}

enum NotesDefaultVisibility: String, Codable, CaseIterable, Identifiable {
    case collapsed = "Collapsed"
    case expanded = "Expanded"

    var id: String { rawValue }
}

struct AIPreferences: Codable, Hashable {
    var provider: AIProviderKind
    var model: String
    var baseURL: String
    var temperature: Double
    var maxTokens: Int
    var privacyMode: Bool
    var enableInlineAutocomplete: Bool

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case baseURL
        case temperature
        case maxTokens
        case privacyMode
        case enableInlineAutocomplete
    }

    init(
        provider: AIProviderKind,
        model: String,
        baseURL: String,
        temperature: Double,
        maxTokens: Int,
        privacyMode: Bool,
        enableInlineAutocomplete: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.privacyMode = privacyMode
        self.enableInlineAutocomplete = enableInlineAutocomplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AIProviderKind.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        temperature = try container.decode(Double.self, forKey: .temperature)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        privacyMode = try container.decode(Bool.self, forKey: .privacyMode)
        enableInlineAutocomplete = try container.decodeIfPresent(Bool.self, forKey: .enableInlineAutocomplete) ?? true
    }
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case openAICompatible = "OpenAI-compatible"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case googleAIStudio = "Google AI Studio"

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .googleAIStudio: "FrameScript.GoogleAIStudio"
        default: rawValue
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AIProviderKind(rawValue: value) ?? .disabled
    }
}

struct VoicePreferences: Codable, Hashable {
    var provider: VoiceProviderKind
    var voiceIdentifier: String
    var speed: Double
    var pitch: Double
    var pausesEnabled: Bool
    var exportFormat: String
}

enum VoiceProviderKind: String, Codable, CaseIterable, Identifiable {
    case system = "macOS System Voice"
    case ai = "AI TTS Provider"

    var id: String { rawValue }
}

struct ExportPreferences: Codable, Hashable {
    var defaultFormat: ExportFormat
    var includeTimestamps: Bool
    var includeSectionNames: Bool
    var includeBRoll: Bool
    var includeEditingNotes: Bool
    var includeAINotes: Bool
    var teleprompterFormatting: Bool
    var defaultExportFolder: String
    var defaultExportFolderBookmarkData: Data?
}

struct WindowPreferences: Codable, Hashable {
    var sidebarDefaultVisible: Bool
    var sidebarWidth: Double
    var focusModeBehavior: FocusModeBehavior
}

enum FocusModeBehavior: String, Codable, CaseIterable, Identifiable {
    case hidePanels = "Hide panels"
    case keepSidebar = "Keep sidebar"

    var id: String { rawValue }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case plainText = "Plain text"
    case markdown = "Markdown"
    case csv = "CSV"
    case productionOutline = "Production outline"

    var id: String { rawValue }
}

struct ExportPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var format: ExportFormat
}

extension AppSettings {
    static let defaults = AppSettings(
        generalPreferences: GeneralPreferences(
            launchBehavior: .showProjectBrowser,
            language: .system,
            autosaveEnabled: true,
            autosaveIntervalSeconds: 10,
            defaultNewProjectTemplate: "Blank",
            blankProjectStart: .oneEmptyScene,
            defaultSplitMode: .paragraph,
            confirmBeforeDeleting: true
        ),
        theme: .system,
        accentColor: .sage,
        editorPreferences: EditorPreferences(
            wordsPerMinute: 150,
            fontSize: 22,
            spellcheck: true,
            smartQuotes: true,
            showWordCount: true,
            showSceneDuration: true,
            showAIReviewPanel: true,
            defaultNotesVisibility: .collapsed
        ),
        aiPreferences: AIPreferences(
            provider: .disabled,
            model: "gpt-4.1-mini",
            baseURL: "",
            temperature: 0.4,
            maxTokens: 420,
            privacyMode: true,
            enableInlineAutocomplete: true
        ),
        voicePreferences: VoicePreferences(
            provider: .system,
            voiceIdentifier: "",
            speed: 1.0,
            pitch: 1.0,
            pausesEnabled: true,
            exportFormat: "m4a"
        ),
        exportPreferences: ExportPreferences(
            defaultFormat: .productionOutline,
            includeTimestamps: true,
            includeSectionNames: true,
            includeBRoll: true,
            includeEditingNotes: true,
            includeAINotes: false,
            teleprompterFormatting: false,
            defaultExportFolder: "",
            defaultExportFolderBookmarkData: nil
        ),
        windowPreferences: WindowPreferences(
            sidebarDefaultVisible: true,
            sidebarWidth: 195,
            focusModeBehavior: .hidePanels
        )
    )
}
