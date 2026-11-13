import Foundation
import FrameScriptCore

// MARK: - Provider

/// `LLMProviderProtocol` implementation for the three subscription-backed
/// kinds. It keeps the protocol shape untouched so hooks and future features
/// get the CLIs for free: the request's task chooses the configured selection
/// and the router decides which local CLI answers.
@MainActor
struct SubscriptionAIProvider: LLMProviderProtocol {
    typealias RouterProvider = @MainActor (SubscriptionAISelection) async throws -> AgentCLIRouter

    var settings: SubscriptionAISettings
    var context: SubscriptionAIContext
    var routerProvider: RouterProvider
    var onPendingQuestion: (@MainActor (AgentCLIPendingQuestion) -> Void)?

    static let probePrompt = "Reply with exactly: OK"

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        guard request.task != .autocomplete else {
            throw SubscriptionAIError.autocompleteNotSupported
        }

        let task = SubscriptionAITask(request.task)
        let selection = settings.selection(for: task)
        if let issue = selection.validationIssue {
            throw SubscriptionAIError.notConfigured(issue)
        }

        let router = try await routerProvider(selection)
        let agentRequest = AgentCLIRequest(
            prompt: Self.prompt(system: request.systemPrompt, user: request.userPrompt),
            model: selection.agentModel,
            title: context.threadTitle(for: task),
            workingDirectory: context.workingDirectory,
            timeout: max(1, settings.defaultTimeout)
        )

        let result: AgentCLIResult
        do {
            result = try await router.run(agentRequest)
        } catch AgentCLIError.cancelled {
            throw CancellationError()
        }

        switch result {
        case let .completed(reply):
            let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw SubscriptionAIError.emptyReply
            }
            return LLMResponse(text: text)
        case let .awaitingAnswer(question):
            onPendingQuestion?(question)
            throw SubscriptionAIError.pendingQuestion(question)
        }
    }

    /// The system and user prompts travel as one stdin payload. Keeping the
    /// labels makes the T3 thread readable when Isaac opens it later.
    static func prompt(system: String, user: String) -> String {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (system.isEmpty, user.isEmpty) {
        case (true, true): return ""
        case (true, false): return user
        case (false, true): return system
        case (false, false): return "\(system)\n\n\(user)"
        }
    }
}

// MARK: - Connection probe

@MainActor
struct SubscriptionAIProber {
    typealias RouterProvider = @MainActor (
        SubscriptionAISelection,
        any T3ThreadMapping
    ) async throws -> AgentCLIRouter

    var settings: SubscriptionAISettings
    var context: SubscriptionAIContext
    var routerProvider: RouterProvider

    func probe(selection: SubscriptionAISelection) async throws -> String {
        if let issue = selection.validationIssue {
            throw SubscriptionAIError.notConfigured(issue)
        }
        // A probe is a throwaway conversation. It must never send "OK" into the
        // project's review thread or store a test thread in `aiThreadMap`.
        let probeMapping = T3ThreadMapStore()
        let router = try await routerProvider(selection, probeMapping)
        let request = AgentCLIRequest(
            prompt: SubscriptionAIProvider.probePrompt,
            model: selection.agentModel,
            title: "FrameScript · connection test",
            workingDirectory: context.workingDirectory,
            timeout: max(30, settings.defaultTimeout)
        )
        let result: AgentCLIResult
        do {
            result = try await router.run(request)
        } catch AgentCLIError.cancelled {
            throw CancellationError()
        }

        switch result {
        case let .completed(reply):
            return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let .awaitingAnswer(question):
            throw SubscriptionAIError.pendingQuestion(question)
        }
    }
}

// MARK: - Router factory

@MainActor
protocol SubscriptionAIRouterProviding {
    func makeRouter(
        selection: SubscriptionAISelection,
        settings: SubscriptionAISettings,
        threadMapping: any T3ThreadMapping
    ) async throws -> AgentCLIRouter
}

/// Builds a router per request from the configured selection. Binary discovery
/// runs off the main thread and is cached; a missing selected binary triggers
/// one refresh so installing a CLI does not need an app restart.
@MainActor
final class SubscriptionAIRouterFactory: SubscriptionAIRouterProviding {
    typealias BinariesProvider = @MainActor (_ refresh: Bool) async -> AgentCLIBinaries

    private let binariesProvider: BinariesProvider
    private let launcher: any AgentProcessLaunching

    init(
        toolchain: SubscriptionAIToolchain = .shared,
        launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
    ) {
        self.binariesProvider = { refresh in
            await toolchain.binaries(refresh: refresh)
        }
        self.launcher = launcher
    }

    /// Test seam: fixed or scripted binaries without touching the filesystem.
    init(
        binariesProvider: @escaping BinariesProvider,
        launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
    ) {
        self.binariesProvider = binariesProvider
        self.launcher = launcher
    }

    func makeRouter(
        selection: SubscriptionAISelection,
        settings: SubscriptionAISettings,
        threadMapping: any T3ThreadMapping
    ) async throws -> AgentCLIRouter {
        if let issue = selection.validationIssue {
            throw SubscriptionAIError.notConfigured(issue)
        }

        var binaries = await binariesProvider(false)
        if binaries.url(for: selection.kind) == nil {
            // One refresh catches a CLI installed after launch.
            binaries = await binariesProvider(true)
        }

        let projectConfigured = settings.t3ProjectIdentifier != nil
        let t3Runner: T3Runner? = {
            guard let executable = binaries.t3, projectConfigured else { return nil }
            return T3Runner(
                configuration: T3Configuration(
                    executable: executable,
                    project: settings.t3Project,
                    defaultTimeout: settings.defaultTimeout
                ),
                launcher: launcher
            )
        }()
        let claudeRunner = binaries.claude.map { ClaudeCLIRunner(executable: $0, launcher: launcher) }
        let codexRunner = binaries.codex.map { CodexCLIRunner(executable: $0, launcher: launcher) }
        let probe: T3ServerProbe? = {
            guard let executable = binaries.t3, projectConfigured else { return nil }
            return T3ServerProbe(executable: executable, project: settings.t3Project)
        }()

        let available: [AgentCLIKind: Bool] = [
            .t3: t3Runner != nil,
            .claude: claudeRunner != nil,
            .codex: codexRunner != nil
        ]
        let configuredProvider: AgentCLIKind
        if available[selection.kind] == true {
            configuredProvider = selection.kind
        } else if let fallback = [AgentCLIKind.t3, .claude, .codex].first(where: { available[$0] == true }) {
            // The selected CLI is missing: let the router use another installed
            // subscription instead of failing before it can fall back.
            configuredProvider = fallback
        } else {
            guard !(selection.kind == .t3 && binaries.t3 != nil && !projectConfigured) else {
                throw SubscriptionAIError.notConfigured(.t3ProjectMissing)
            }
            configuredProvider = selection.kind
        }

        let t3Model: AgentCLIModelSelection? = {
            let base: SubscriptionAISelection = {
                if selection.kind == .t3 { return selection }
                if settings.defaultSelection.kind == .t3 { return settings.defaultSelection }
                return .defaultT3
            }()
            return base.agentModel
        }()

        let claudeSlug = selection.kind == .claude
            ? selection.trimmedModelSlug
            : claudeModelSlug(settings: settings)
        let codexSlug = selection.kind == .codex
            ? selection.trimmedModelSlug
            : codexModelSlug(settings: settings)

        let fallbackOrder: [AgentCLIKind] = {
            switch configuredProvider {
            case .claude: [.claude, .codex]
            case .codex: [.codex, .claude]
            case .t3: [.claude, .codex]
            }
        }()

        return AgentCLIRouter(
            configuredProvider: configuredProvider,
            t3: t3Runner,
            claude: claudeRunner,
            codex: codexRunner,
            t3Probe: probe,
            t3ThreadMap: configuredProvider == .t3 ? threadMapping : nil,
            t3Model: t3Model,
            claudeModelSlug: claudeSlug,
            codexModelSlug: codexSlug,
            fallbackOrder: fallbackOrder
        )
    }

    private func claudeModelSlug(settings: SubscriptionAISettings) -> String? {
        guard settings.defaultSelection.kind == .claude else { return nil }
        let slug = settings.defaultSelection.trimmedModelSlug
        return slug.isEmpty ? nil : slug
    }

    private func codexModelSlug(settings: SubscriptionAISettings) -> String? {
        guard settings.defaultSelection.kind == .codex else { return nil }
        let slug = settings.defaultSelection.trimmedModelSlug
        return slug.isEmpty ? nil : slug
    }
}

// MARK: - Toolchain

/// Locates `t3`, `claude` and `codex` once. A Finder-launched app does not
/// inherit the shell PATH, so the core locator checks the usual folders and
/// then a login shell.
@MainActor
final class SubscriptionAIToolchain {
    static let shared = SubscriptionAIToolchain()

    private let locator: AgentCLIBinaryLocator
    private var cachedBinaries: AgentCLIBinaries?

    init(locator: AgentCLIBinaryLocator = AgentCLIBinaryLocator()) {
        self.locator = locator
    }

    func binaries(refresh: Bool = false) async -> AgentCLIBinaries {
        if !refresh, let cachedBinaries {
            return cachedBinaries
        }
        let located = await locator.locateAll()
        cachedBinaries = located
        return located
    }

    func requireT3(refresh: Bool = true) async throws -> URL {
        guard let executable = await binaries(refresh: refresh).t3 else {
            throw AgentCLIError.binaryNotFound(.t3)
        }
        return executable
    }
}

// MARK: - T3 project helpers

extension SubscriptionAIToolchain {
    func t3ProjectResolver(timeout: TimeInterval = 30) async throws -> T3ProjectResolver {
        T3ProjectResolver(
            configuration: T3ProjectResolver.Configuration(
                executable: try await requireT3(),
                timeout: timeout
            )
        )
    }
}

// MARK: - Thread link

/// Reads the deep link T3 prints for a thread. Used by "Abrir hilo en T3" and
/// by the exit-2 sheet when the pending question did not include one.
struct SubscriptionAIT3ThreadInspector: Sendable {
    private let launcher: any AgentProcessLaunching

    init(launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()) {
        self.launcher = launcher
    }

    func link(threadID: String, executable: URL) async -> URL? {
        let trimmed = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let request = AgentProcessRequest(
            executableURL: executable,
            arguments: ["thread", "show", trimmed, "--json"],
            timeout: 20,
            outputByteLimit: 262_144
        )
        guard let output = try? await launcher.launch(request),
              output.exitCode == 0,
              let envelope = Self.decodeShow(output.standardOutputText),
              let raw = envelope.thread?.link,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return url
    }

    /// Falls back to opening the T3 desktop app on the FrameScript project.
    func openApplication(projectPath: String?, executable: URL) async -> Bool {
        var arguments = ["app"]
        if let projectPath, !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(projectPath)
        }
        let request = AgentProcessRequest(
            executableURL: executable,
            arguments: arguments,
            timeout: 15,
            outputByteLimit: 65_536
        )
        guard let output = try? await launcher.launch(request) else { return false }
        return output.exitCode == 0
    }

    struct ShowEnvelope: Decodable, Equatable {
        struct Thread: Decodable, Equatable {
            var link: String?
        }

        var thread: Thread?
    }

    static func decodeShow(_ json: String) -> ShowEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ShowEnvelope.self, from: data)
    }
}

// MARK: - Project thread map bridge

/// Adapts the project's `aiThreadMap` (stored inside the `.fscr`) to the
/// router's `T3ThreadMapping` seam. The closures run on the main actor because
/// they mutate the observable project model.
@MainActor
final class SubscriptionAIThreadMapping: T3ThreadMapping {
    typealias Read = @MainActor (T3ThreadKey) -> String?
    typealias Write = @MainActor (String, T3ThreadKey) -> Void

    private let read: Read
    private let write: Write

    init(read: @escaping Read, write: @escaping Write) {
        self.read = read
        self.write = write
    }

    nonisolated func threadID(for key: T3ThreadKey) async -> String? {
        await MainActor.run { self.read(key) }
    }

    nonisolated func record(threadID: String, for key: T3ThreadKey) async {
        await MainActor.run { self.write(threadID, key) }
    }
}
