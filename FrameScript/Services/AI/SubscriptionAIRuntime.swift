import AppKit
import Foundation
import FrameScriptCore
import Observation

// MARK: - Observable activity

struct SubscriptionAIActivity: Identifiable, Equatable {
    enum Mode: Equatable {
        case completion(SubscriptionAITask)
        case probe
    }

    let id = UUID()
    let mode: Mode
    let kind: AgentCLIKind
    let startedAt: Date
}

enum SubscriptionAIOutcome: Equatable {
    case cancelled
    case waitingForAnswer
    case timedOut
}

struct SubscriptionAIPendingPrompt: Identifiable, Equatable {
    let id = UUID()
    let question: AgentCLIPendingQuestion
}

enum SubscriptionAIProbeResult: Equatable {
    case reply(String)
    /// Exit code 2. `pending` already lives in the runtime for the sheet.
    case pending
    case failure(String)
}

enum SubscriptionAIOpenResult: Equatable {
    case opened
    case noThread
    case failed(String)
}

// MARK: - Runtime

/// App-wide coordinator for subscription requests. It is the only place that
/// knows the currently open FrameScript project, which lets the provider keep
/// the `LLMProviderProtocol` shape unchanged.
@MainActor
@Observable
final class SubscriptionAIRuntime {
    static let shared = SubscriptionAIRuntime()

    private(set) var activity: SubscriptionAIActivity?
    private(set) var lastOutcome: SubscriptionAIOutcome?
    private(set) var openError: String?
    /// Mutated by the sheet binding.
    var pendingPrompt: SubscriptionAIPendingPrompt?

    private weak var appState: AppState?
    private let store: SubscriptionAISettingsStore
    private let routerFactory: SubscriptionAIRouterFactory
    private let inspector: SubscriptionAIT3ThreadInspector
    private var cancelCurrentWork: (() -> Void)?
    private var didRequestCancellation = false

    init(
        store: SubscriptionAISettingsStore = .shared,
        routerFactory: SubscriptionAIRouterFactory = SubscriptionAIRouterFactory(),
        inspector: SubscriptionAIT3ThreadInspector = SubscriptionAIT3ThreadInspector()
    ) {
        self.store = store
        self.routerFactory = routerFactory
        self.inspector = inspector
    }

    func attach(appState: AppState) {
        self.appState = appState
    }

    // MARK: Completion

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let settings = store.settings
        let task = SubscriptionAITask(request.task)
        let selection = settings.selection(for: task)
        let context = appState?.subscriptionAIContext ?? .standalone()
        let provider = SubscriptionAIProvider(
            settings: settings,
            context: context,
            routerProvider: { [routerFactory] selection in
                try await routerFactory.makeRouter(
                    selection: selection,
                    settings: settings,
                    threadMapping: context.threadMapping
                )
            }
        )
        let activity = SubscriptionAIActivity(
            mode: .completion(task),
            kind: selection.kind,
            startedAt: Date()
        )
        return try await perform(activity: activity) {
            try await provider.complete(request: request, apiKey: "")
        }
    }

    // MARK: Probe

    func probe(selection: SubscriptionAISelection? = nil) async -> SubscriptionAIProbeResult {
        let settings = store.settings
        let chosen = selection ?? settings.defaultSelection
        let context = appState?.subscriptionAIContext ?? .standalone()
        let prober = SubscriptionAIProber(
            settings: settings,
            context: context,
            routerProvider: { [routerFactory] selection in
                try await routerFactory.makeRouter(
                    selection: selection,
                    settings: settings,
                    threadMapping: context.threadMapping
                )
            }
        )
        let activity = SubscriptionAIActivity(mode: .probe, kind: chosen.kind, startedAt: Date())
        do {
            let reply = try await perform(activity: activity) {
                try await prober.probe(selection: chosen)
            }
            return .reply(reply)
        } catch SubscriptionAIError.pendingQuestion {
            return .pending
        } catch is CancellationError {
            return .failure("The AI request was cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: Cancellation

    func cancel() {
        didRequestCancellation = true
        cancelCurrentWork?()
    }

    var isRunning: Bool { activity != nil }

    func clearOutcome() {
        lastOutcome = nil
    }

    func clearOpenError() {
        openError = nil
    }

    // MARK: Threads

    func threadID(for selection: SubscriptionAISelection) -> String? {
        appState?.subscriptionAIThreadID(for: selection)
    }

    func resetThread(for selection: SubscriptionAISelection) {
        appState?.subscriptionAIResetThread(for: selection)
    }

    func openThreadInT3(selection: SubscriptionAISelection) async -> SubscriptionAIOpenResult {
        guard let threadID = threadID(for: selection) else {
            return .noThread
        }
        return await openThread(threadID: threadID)
    }

    func openThread(threadID: String) async -> SubscriptionAIOpenResult {
        openError = nil
        let settings = store.settings
        let binaries = await SubscriptionAIToolchain.shared.binaries()
        guard let executable = binaries.t3 else {
            let message = AgentCLIError.binaryNotFound(.t3).localizedDescription
            openError = message
            return .failed(message)
        }
        if let url = await inspector.link(threadID: threadID, executable: executable) {
            NSWorkspace.shared.open(url)
            return .opened
        }
        if await inspector.openApplication(projectPath: settings.t3Project.path, executable: executable) {
            return .opened
        }
        let message = "Could not open the T3 thread \(threadID). Open T3 Code and find it manually."
        openError = message
        return .failed(message)
    }

    func openPendingInT3() async {
        guard let pending = pendingPrompt else { return }
        openError = nil
        if let url = pending.question.openInT3URL {
            NSWorkspace.shared.open(url)
            pendingPrompt = nil
            return
        }
        switch await openThread(threadID: pending.question.threadID) {
        case .opened:
            pendingPrompt = nil
        case .noThread:
            openError = nil
        case let .failed(message):
            openError = message
        }
    }

    // MARK: Work wrapper

    private func perform<T: Sendable>(
        activity: SubscriptionAIActivity,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        self.activity = activity
        lastOutcome = nil
        didRequestCancellation = false

        let work = Task { @MainActor in
            try await operation()
        }
        cancelCurrentWork = { work.cancel() }
        defer {
            cancelCurrentWork = nil
            self.activity = nil
        }

        do {
            let value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            return value
        } catch let error as SubscriptionAIError {
            if case let .pendingQuestion(question) = error {
                pendingPrompt = SubscriptionAIPendingPrompt(question: question)
                lastOutcome = .waitingForAnswer
            }
            throw error
        } catch is CancellationError {
            if didRequestCancellation {
                lastOutcome = .cancelled
            }
            throw CancellationError()
        } catch let error as AgentCLIError {
            if case .timedOut = error {
                lastOutcome = .timedOut
            }
            throw error
        } catch {
            throw error
        }
    }
}
