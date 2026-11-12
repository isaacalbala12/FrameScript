import Foundation
import FrameScriptCore

// MARK: - Provider kinds

extension AIProviderKind {
    /// The local CLI behind a subscription-backed provider kind.
    var agentCLIKind: AgentCLIKind? {
        switch self {
        case .t3Code: .t3
        case .claudeCode: .claude
        case .codex: .codex
        case .disabled, .openAICompatible, .openRouter, .groq, .googleAIStudio: nil
        }
    }

    var isSubscriptionBacked: Bool {
        agentCLIKind != nil
    }
}

/// The AI actions FrameScript can hand to a subscription. The last three are
/// reserved for F15 (titles/SEO), F22 (translation) and F13 (hooks); settings
/// already carry their selection so those features do not need a migration.
enum SubscriptionAITask: String, CaseIterable, Codable, Identifiable, Sendable {
    case review
    case rewrite
    case bRoll
    case editing
    case titlesSEO
    case translation
    case hooks

    var id: String { rawValue }

    init(_ task: AITask) {
        // Deliberately keyed by raw value so a future `AITask` case, such as
        // F13's hooks, maps without changing this file and without breaking
        // the build on another branch that adds it.
        switch task.rawValue.lowercased() {
        case "rewrite": self = .rewrite
        case "brollgeneration", "broll": self = .bRoll
        case "editinggeneration", "editing": self = .editing
        case "titles", "titlesseo", "seo": self = .titlesSEO
        case "translation", "translate": self = .translation
        case "hooks", "hook": self = .hooks
        default: self = .review
        }
    }

    /// Stable English name used in T3 thread titles, never in the UI.
    var threadTitle: String {
        switch self {
        case .review: "Review"
        case .rewrite: "Rewrite"
        case .bRoll: "B-roll"
        case .editing: "Editing"
        case .titlesSEO: "Titles and SEO"
        case .translation: "Translation"
        case .hooks: "Hooks"
        }
    }
}

// MARK: - Selection

/// Provider instance + model for one task. For T3 both fields are required;
/// the other CLIs accept an empty model, which asks them for their default.
struct SubscriptionAISelection: Codable, Hashable, Sendable, Equatable {
    var kind: AgentCLIKind
    var providerInstanceID: String
    var modelSlug: String

    init(kind: AgentCLIKind, providerInstanceID: String = "", modelSlug: String = "") {
        self.kind = kind
        self.providerInstanceID = providerInstanceID
        self.modelSlug = modelSlug
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case providerInstanceID
        case modelSlug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(AgentCLIKind.self, forKey: .kind)) ?? .t3
        providerInstanceID = try container.decodeIfPresent(String.self, forKey: .providerInstanceID) ?? ""
        modelSlug = try container.decodeIfPresent(String.self, forKey: .modelSlug) ?? ""
    }

    var trimmedProviderInstanceID: String {
        providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModelSlug: String {
        modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nil when the selection is usable. T3 rejects a provider without a model
    /// and a model without a provider.
    var validationMessage: String? {
        switch kind {
        case .t3:
            guard !trimmedProviderInstanceID.isEmpty, !trimmedModelSlug.isEmpty else {
                return "T3 Code needs both a provider instance id and a model slug."
            }
            return nil
        case .claude:
            guard !trimmedModelSlug.isEmpty else {
                return "Choose a Claude model alias, for example sonnet or opus."
            }
            return nil
        case .codex:
            guard !trimmedModelSlug.isEmpty else {
                return "Choose a Codex model, for example gpt-5.3-codex."
            }
            return nil
        }
    }

    var agentModel: AgentCLIModelSelection {
        AgentCLIModelSelection(
            kind: kind,
            providerInstanceID: kind == .t3 ? trimmedProviderInstanceID : nil,
            modelSlug: trimmedModelSlug.isEmpty ? nil : trimmedModelSlug
        )
    }

    static let defaultT3 = SubscriptionAISelection(
        kind: .t3,
        providerInstanceID: "opencode",
        modelSlug: "opencode-go/deepseek-v4.1-flash"
    )

    static let defaultClaude = SubscriptionAISelection(
        kind: .claude,
        modelSlug: "sonnet"
    )

    static let defaultCodex = SubscriptionAISelection(
        kind: .codex,
        modelSlug: "gpt-5.3-codex"
    )

    static func defaultSelection(for kind: AgentCLIKind) -> SubscriptionAISelection {
        switch kind {
        case .t3: defaultT3
        case .claude: defaultClaude
        case .codex: defaultCodex
        }
    }
}

// MARK: - Settings

struct SubscriptionAISettings: Codable, Equatable, Sendable {
    /// When true the default selection is used for every task and per-task
    /// overrides are ignored. Turning it back off keeps the overrides.
    var useForAllTasks: Bool
    var defaultSelection: SubscriptionAISelection
    /// Keyed by `SubscriptionAITask.rawValue`, so the JSON stays readable and
    /// adding a future task never breaks decoding.
    var taskSelections: [String: SubscriptionAISelection]
    /// The T3 project every FrameScript thread lives in. It is shared by all
    /// FrameScript projects, exactly as F12 describes.
    var t3Project: T3ProjectReference
    /// Wall-clock budget for one CLI invocation. D2 wants long waits.
    var defaultTimeout: TimeInterval

    init(
        useForAllTasks: Bool = true,
        defaultSelection: SubscriptionAISelection = .defaultT3,
        taskSelections: [String: SubscriptionAISelection] = [:],
        t3Project: T3ProjectReference = T3ProjectReference(name: "FrameScript IA"),
        defaultTimeout: TimeInterval = 180
    ) {
        self.useForAllTasks = useForAllTasks
        self.defaultSelection = defaultSelection
        self.taskSelections = taskSelections
        self.t3Project = t3Project
        self.defaultTimeout = defaultTimeout
    }

    enum CodingKeys: String, CodingKey {
        case useForAllTasks
        case defaultSelection
        case taskSelections
        case t3Project
        case defaultTimeout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useForAllTasks = try container.decodeIfPresent(Bool.self, forKey: .useForAllTasks) ?? true
        defaultSelection = try container.decodeIfPresent(SubscriptionAISelection.self, forKey: .defaultSelection) ?? .defaultT3
        taskSelections = try container.decodeIfPresent([String: SubscriptionAISelection].self, forKey: .taskSelections) ?? [:]
        t3Project = try container.decodeIfPresent(T3ProjectReference.self, forKey: .t3Project)
            ?? T3ProjectReference(name: "FrameScript IA")
        let storedTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .defaultTimeout) ?? 180
        defaultTimeout = min(max(storedTimeout, 30), 900)
    }

    func selection(for task: SubscriptionAITask) -> SubscriptionAISelection {
        guard !useForAllTasks else { return defaultSelection }
        return taskSelections[task.rawValue] ?? defaultSelection
    }

    func hasOverride(for task: SubscriptionAITask) -> Bool {
        !useForAllTasks && taskSelections[task.rawValue] != nil
    }

    mutating func setSelection(_ selection: SubscriptionAISelection, for task: SubscriptionAITask) {
        taskSelections[task.rawValue] = selection
    }

    mutating func useDefault(for task: SubscriptionAITask) {
        taskSelections.removeValue(forKey: task.rawValue)
    }

    mutating func setUseForAllTasks(_ value: Bool) {
        useForAllTasks = value
        if value {
            taskSelections.removeAll()
        }
    }

    /// Every task/selection pair the UI should offer thread controls for.
    func selectionsInUse() -> [(task: SubscriptionAITask, selection: SubscriptionAISelection)] {
        SubscriptionAITask.allCases.map { ($0, selection(for: $0)) }
    }

    var t3ProjectIdentifier: String? {
        Self.nonBlank(t3Project.id) ?? Self.nonBlank(t3Project.path)
    }

    var t3ProjectIDForStorage: String {
        Self.nonBlank(t3Project.id) ?? Self.nonBlank(t3Project.path) ?? ""
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let defaults = SubscriptionAISettings()
}

// MARK: - Thread map keys

enum SubscriptionAIThreadKey {
    /// One string key for the v4 `aiThreadMap`. The model slug itself contains
    /// slashes, so a double colon is the delimiter.
    static let separator = "::"

    static func storageKey(providerInstanceID: String, modelSlug: String) -> String {
        let provider = providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !model.isEmpty else { return "" }
        return provider + separator + model
    }

    static func storageKey(_ key: T3ThreadKey) -> String {
        storageKey(providerInstanceID: key.providerInstanceID, modelSlug: key.modelSlug)
    }

    static func storageKey(for selection: SubscriptionAISelection) -> String? {
        let key = storageKey(
            providerInstanceID: selection.trimmedProviderInstanceID,
            modelSlug: selection.trimmedModelSlug
        )
        return key.isEmpty ? nil : key
    }

    static func parse(_ raw: String) -> T3ThreadKey? {
        guard let range = raw.range(of: separator) else { return nil }
        let provider = String(raw[..<range.lowerBound])
        let model = String(raw[range.upperBound...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return T3ThreadKey(providerInstanceID: provider, modelSlug: model)
    }
}

// MARK: - Suggestions

enum SubscriptionAIModelCatalog {
    static let t3ProviderInstances = ["claudeAgent", "codex", "opencode"]

    static func providerInstances(for kind: AgentCLIKind) -> [String] {
        switch kind {
        case .t3: t3ProviderInstances
        case .claude, .codex: []
        }
    }

    static func models(for kind: AgentCLIKind, providerInstanceID: String) -> [String] {
        switch kind {
        case .t3:
            switch providerInstanceID.lowercased() {
            case "claudeagent", "claude":
                ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
            case "codex":
                ["gpt-5.3-codex", "gpt-5.2-codex"]
            case "opencode":
                ["opencode-go/deepseek-v4.1-flash", "opencode-go/claude-sonnet-4-5", "opencode-go/gpt-5.3-codex"]
            default:
                ["opencode-go/deepseek-v4.1-flash"]
            }
        case .claude:
            ["sonnet", "opus", "haiku"]
        case .codex:
            ["gpt-5.3-codex", "gpt-5.2-codex"]
        }
    }
}

// MARK: - Formatting

enum SubscriptionAIElapsedFormat {
    /// `m:ss`, useful for the long D2 waits.
    static func string(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start).rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func string(seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

// MARK: - Errors

enum SubscriptionAIError: Error, Equatable, LocalizedError, Sendable {
    /// Inline autocomplete never uses a subscription: CLIs take seconds.
    case autocompleteNotSupported
    /// Exit code 2: the agent asked a question. The thread keeps running in T3.
    case pendingQuestion(AgentCLIPendingQuestion)
    case notConfigured(String)

    var errorDescription: String? {
        switch self {
        case .autocompleteNotSupported:
            return "Inline autocomplete stays on API providers and never uses a subscription."
        case let .pendingQuestion(question):
            return "The AI agent is waiting for an answer in T3 Code: \(question.question)"
        case let .notConfigured(detail):
            return detail
        }
    }
}

// MARK: - Runtime context

struct SubscriptionAIContext: Sendable {
    var projectTitle: String
    var workingDirectory: URL?
    var threadMapping: any T3ThreadMapping

    init(
        projectTitle: String = "",
        workingDirectory: URL? = nil,
        threadMapping: any T3ThreadMapping = T3ThreadMapStore()
    ) {
        self.projectTitle = projectTitle
        self.workingDirectory = workingDirectory
        self.threadMapping = threadMapping
    }

    static func standalone() -> SubscriptionAIContext {
        SubscriptionAIContext()
    }

    func threadTitle(for task: SubscriptionAITask) -> String {
        let base = "FrameScript · \(task.threadTitle)"
        let title = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return base }
        return String("\(base) · \(title)".prefix(120))
    }
}
