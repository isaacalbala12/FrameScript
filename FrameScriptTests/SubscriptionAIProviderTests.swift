import Foundation
import FrameScriptCore
import Observation
@testable import FrameScript
import XCTest

// MARK: - Fakes

actor SubscriptionRunnerRecorder {
    private(set) var requests: [AgentCLIRequest] = []

    func record(_ request: AgentCLIRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [AgentCLIRequest] {
        requests
    }
}

struct SubscriptionRecordingRunner: AgentCLIRunner {
    let kind: AgentCLIKind
    let recorder: SubscriptionRunnerRecorder
    let handler: @Sendable (AgentCLIRequest) async throws -> AgentCLIResult

    func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        await recorder.record(request)
        return try await handler(request)
    }
}

struct SubscriptionStubProbe: T3AvailabilityChecking {
    let available: Bool
    func isAvailable() async -> Bool { available }
}

@MainActor
final class StaticSubscriptionRouterProvider: SubscriptionAIRouterProviding {
    private let router: AgentCLIRouter

    init(router: AgentCLIRouter) {
        self.router = router
    }

    func makeRouter(
        selection: SubscriptionAISelection,
        settings: SubscriptionAISettings,
        threadMapping: any T3ThreadMapping
    ) async throws -> AgentCLIRouter {
        router
    }
}

actor SubscriptionObservationFlag {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@MainActor
final class BinariesCallCounter {
    var calls: [Bool] = []
}

actor SubscriptionFakeLauncher: AgentProcessLaunching {
    private var steps: [AgentProcessOutput]
    private(set) var requests: [AgentProcessRequest] = []

    init(_ steps: [AgentProcessOutput]) {
        self.steps = steps
    }

    func launch(_ request: AgentProcessRequest) async throws -> AgentProcessOutput {
        requests.append(request)
        guard !steps.isEmpty else {
            throw AgentCLIError.launchFailed("SubscriptionFakeLauncher has no queued step")
        }
        return steps.removeFirst()
    }

    func recordedRequests() -> [AgentProcessRequest] {
        requests
    }
}

@MainActor
final class SubscriptionTestRouterBuilder {
    var selections: [SubscriptionAISelection] = []
    var t3Runner: (any AgentCLIRunner)?
    var claudeRunner: (any AgentCLIRunner)?
    var codexRunner: (any AgentCLIRunner)?
    var threadMapping: (any T3ThreadMapping)?
    var t3Available = true

    func make(_ selection: SubscriptionAISelection) async throws -> AgentCLIRouter {
        selections.append(selection)
        switch selection.kind {
        case .t3:
            guard let t3Runner else { throw AgentCLIError.binaryNotFound(.t3) }
            return AgentCLIRouter(
                configuredProvider: .t3,
                t3: t3Runner,
                claude: claudeRunner,
                codex: codexRunner,
                t3Probe: SubscriptionStubProbe(available: t3Available),
                t3ThreadMap: threadMapping,
                t3Model: selection.agentModel,
                claudeModelSlug: nil,
                codexModelSlug: nil,
                fallbackOrder: [.claude, .codex]
            )
        case .claude:
            guard let claudeRunner else { throw AgentCLIError.binaryNotFound(.claude) }
            return AgentCLIRouter(
                configuredProvider: .claude,
                claude: claudeRunner,
                codex: codexRunner,
                claudeModelSlug: selection.trimmedModelSlug,
                fallbackOrder: [.claude, .codex]
            )
        case .codex:
            guard let codexRunner else { throw AgentCLIError.binaryNotFound(.codex) }
            return AgentCLIRouter(
                configuredProvider: .codex,
                claude: claudeRunner,
                codex: codexRunner,
                codexModelSlug: selection.trimmedModelSlug,
                fallbackOrder: [.codex, .claude]
            )
        }
    }
}

@MainActor
final class SubscriptionAIProviderTests: XCTestCase {
    // MARK: Helpers

    private func llmRequest(
        task: AITask,
        system: String = "System instructions",
        user: String = "Scene text"
    ) -> LLMRequest {
        LLMRequest(
            task: task,
            provider: .t3Code,
            baseURL: "",
            systemPrompt: system,
            userPrompt: user,
            model: "ignored",
            temperature: 0,
            maxTokens: 0
        )
    }

    private func provider(
        settings: SubscriptionAISettings,
        builder: SubscriptionTestRouterBuilder,
        context: SubscriptionAIContext = .standalone(),
        onPending: (@MainActor (AgentCLIPendingQuestion) -> Void)? = nil
    ) -> SubscriptionAIProvider {
        SubscriptionAIProvider(
            settings: settings,
            context: context,
            routerProvider: { selection in
                try await builder.make(selection)
            },
            onPendingQuestion: onPending
        )
    }

    private func t3Reply(_ text: String, threadID: String? = nil) -> AgentCLIResult {
        .completed(AgentCLIReply(provider: .t3, text: text, threadID: threadID))
    }

    // MARK: Routing

    func testTaskSelectionsRouteToTheConfiguredCLI() async throws {
        var settings = SubscriptionAISettings()
        settings.setUseForAllTasks(false)
        settings.defaultSelection = SubscriptionAISelection(kind: .t3, providerInstanceID: "opencode", modelSlug: "model-default")
        settings.setSelection(
            SubscriptionAISelection(kind: .t3, providerInstanceID: "claudeAgent", modelSlug: "claude-sonnet-4-5"),
            for: .review
        )
        settings.setSelection(
            SubscriptionAISelection(kind: .claude, modelSlug: "sonnet"),
            for: .rewrite
        )

        let t3Recorder = SubscriptionRunnerRecorder()
        let claudeRecorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: t3Recorder) { _ in
            .completed(AgentCLIReply(provider: .t3, text: "review reply"))
        }
        builder.claudeRunner = SubscriptionRecordingRunner(kind: .claude, recorder: claudeRecorder) { _ in
            .completed(AgentCLIReply(provider: .claude, text: "rewrite reply"))
        }

        let subject = provider(settings: settings, builder: builder)

        let review = try await subject.complete(
            request: llmRequest(task: .analyze),
            apiKey: ""
        )
        XCTAssertEqual(review.text, "review reply")

        let rewrite = try await subject.complete(
            request: llmRequest(task: .rewrite, system: "Rewrite rules", user: "Selected passage"),
            apiKey: ""
        )
        XCTAssertEqual(rewrite.text, "rewrite reply")

        XCTAssertEqual(builder.selections.map(\.kind), [.t3, .claude])
        let t3Requests = await t3Recorder.recordedRequests()
        let claudeRequests = await claudeRecorder.recordedRequests()
        XCTAssertEqual(t3Requests.count, 1)
        XCTAssertEqual(t3Requests.first?.model.providerInstanceID, "claudeAgent")
        XCTAssertEqual(t3Requests.first?.model.modelSlug, "claude-sonnet-4-5")
        XCTAssertTrue(t3Requests.first?.prompt.contains("System instructions") == true)
        XCTAssertTrue(t3Requests.first?.prompt.contains("Scene text") == true)
        XCTAssertEqual(claudeRequests.first?.model.modelSlug, "sonnet")
        XCTAssertTrue(claudeRequests.first?.prompt.contains("Rewrite rules") == true)
        XCTAssertTrue(claudeRequests.first?.prompt.contains("Selected passage") == true)
    }

    func testUseForAllIgnoresTaskOverrides() async throws {
        var settings = SubscriptionAISettings()
        settings.defaultSelection = SubscriptionAISelection(kind: .t3, providerInstanceID: "opencode", modelSlug: "default-model")
        settings.taskSelections[SubscriptionAITask.review.rawValue] = SubscriptionAISelection(kind: .claude, modelSlug: "opus")
        settings.useForAllTasks = true

        XCTAssertEqual(settings.selection(for: .review).kind, .t3)
        XCTAssertEqual(settings.selection(for: .review).modelSlug, "default-model")
        XCTAssertFalse(settings.hasOverride(for: .review))
    }

    func testUseForAllRoundTripKeepsPerTaskOverrides() {
        var settings = SubscriptionAISettings()
        settings.setUseForAllTasks(false)
        settings.setSelection(SubscriptionAISelection(kind: .claude, modelSlug: "opus"), for: .review)

        settings.setUseForAllTasks(true)
        XCTAssertEqual(settings.selection(for: .review).kind, .t3)

        settings.setUseForAllTasks(false)
        XCTAssertEqual(settings.selection(for: .review).kind, .claude)
        XCTAssertEqual(settings.selection(for: .review).modelSlug, "opus")
        XCTAssertTrue(settings.hasOverride(for: .review))
    }

    func testSwitchingProviderKindReplacesTheForeignModelBeforeLaunching() async throws {
        var settings = SubscriptionAISettings()
        settings.setDefaultKind(.claude)

        XCTAssertEqual(settings.defaultSelection.kind, .claude)
        XCTAssertEqual(settings.defaultSelection.trimmedModelSlug, "sonnet")
        XCTAssertTrue(settings.defaultSelection.trimmedProviderInstanceID.isEmpty)
        XCTAssertNil(settings.defaultSelection.validationIssue)

        let recorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.claudeRunner = SubscriptionRecordingRunner(kind: .claude, recorder: recorder) { _ in
            .completed(AgentCLIReply(provider: .claude, text: "rewrite"))
        }
        let subject = provider(settings: settings, builder: builder)

        _ = try await subject.complete(request: llmRequest(task: .rewrite), apiKey: "")

        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.first?.model.modelSlug, "sonnet")
        XCTAssertNil(requests.first?.model.providerInstanceID)
        XCTAssertFalse(requests.first?.model.modelSlug?.contains("/") == true)
    }

    func testChangingTheT3FolderClearsTheOldProjectIdentity() {
        var settings = SubscriptionAISettings(
            t3Project: T3ProjectReference(
                id: "old-project",
                path: "/tmp/old",
                name: "Old"
            )
        )

        settings.updateProjectPath("/tmp/new")

        XCTAssertNil(settings.t3Project.id)
        XCTAssertNil(settings.t3Project.name)
        XCTAssertEqual(settings.t3Project.path, "/tmp/new")
        XCTAssertEqual(settings.t3ProjectIdentifier, "/tmp/new")
    }

    func testAutocompleteNeverRoutesToACLI() async {
        let settings = SubscriptionAISettings()
        let builder = SubscriptionTestRouterBuilder()
        let subject = provider(settings: settings, builder: builder)

        do {
            _ = try await subject.complete(request: llmRequest(task: .autocomplete), apiKey: "")
            XCTFail("Expected autocomplete to be rejected")
        } catch let error as SubscriptionAIError {
            XCTAssertEqual(error, .autocompleteNotSupported)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(builder.selections.isEmpty)
    }

    func testIncompleteT3SelectionFailsBeforeLaunching() async {
        var settings = SubscriptionAISettings()
        settings.defaultSelection = SubscriptionAISelection(kind: .t3, providerInstanceID: "", modelSlug: "")
        let builder = SubscriptionTestRouterBuilder()
        let subject = provider(settings: settings, builder: builder)

        do {
            _ = try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")
            XCTFail("Expected configuration error")
        } catch SubscriptionAIError.notConfigured {
            XCTAssertTrue(builder.selections.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: D2 thread reuse

    func testSecondRequestReusesTheRecordedThread() async throws {
        let settings = SubscriptionAISettings()
        let key = T3ThreadKey(providerInstanceID: "opencode", modelSlug: "opencode-go/deepseek-v4.1-flash")
        let store = T3ThreadMapStore()
        let recorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.threadMapping = store
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: recorder) { _ in
            .completed(AgentCLIReply(provider: .t3, text: "ok", threadID: "thread-reused"))
        }

        let subject = provider(settings: settings, builder: builder)

        _ = try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")
        _ = try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")

        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].threadID)
        XCTAssertEqual(requests[1].threadID, "thread-reused")
        let storedThread = await store.threadID(for: key)
        XCTAssertEqual(storedThread, "thread-reused")
    }

    func testThreadMapRoundTripsThroughTheFSCRFile() async throws {
        let project = SampleData.defaultProject
        let t3ProjectID = "33333333-3333-4333-8333-333333333333"
        let settings = SubscriptionAISettings(
            t3Project: T3ProjectReference(id: t3ProjectID, name: "FrameScript IA")
        )
        let mapping = makeProjectMapping(project: project, expectedProjectID: t3ProjectID)
        let builder = SubscriptionTestRouterBuilder()
        builder.threadMapping = mapping
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: SubscriptionRunnerRecorder()) { _ in
            .completed(AgentCLIReply(provider: .t3, text: "ok", threadID: "thread-from-fscr"))
        }

        let subject = provider(
            settings: settings,
            builder: builder,
            context: SubscriptionAIContext(projectTitle: project.title, threadMapping: mapping)
        )
        _ = try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")

        XCTAssertEqual(
            project.aiThreadMap.threadIDsByProviderModel[
                SubscriptionAIThreadKey.storageKey(
                    providerInstanceID: "opencode",
                    modelSlug: "opencode-go/deepseek-v4.1-flash"
                )
            ],
            "thread-from-fscr"
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubscriptionThreadMap-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(loaded.aiThreadMap.t3ProjectID, t3ProjectID)

        let loadedMapping = makeProjectMapping(project: loaded, expectedProjectID: t3ProjectID)
        let key = T3ThreadKey(providerInstanceID: "opencode", modelSlug: "opencode-go/deepseek-v4.1-flash")
        let loadedThread = await loadedMapping.threadID(for: key)
        XCTAssertEqual(loadedThread, "thread-from-fscr")
    }

    func testThreadMapIsIgnoredWhenTheT3ProjectChanged() async {
        let project = SampleData.defaultProject
        project.aiThreadMap = AIThreadMap(
            t3ProjectID: "old-project",
            threadIDsByProviderModel: [
                SubscriptionAIThreadKey.storageKey(providerInstanceID: "opencode", modelSlug: "model"): "old-thread"
            ]
        )
        let mapping = makeProjectMapping(project: project, expectedProjectID: "new-project")
        let key = T3ThreadKey(providerInstanceID: "opencode", modelSlug: "model")
        let threadID = await mapping.threadID(for: key)
        XCTAssertNil(threadID)
    }

    // MARK: Cancel and exit 2

    func testCancellationStopsWaitingAndThrowsCancellationError() async throws {
        let settings = SubscriptionAISettings()
        let recorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: recorder) { _ in
            try await Task.sleep(for: .seconds(30))
            return .completed(AgentCLIReply(provider: .t3, text: "late"))
        }
        let subject = provider(settings: settings, builder: builder)

        let task = Task {
            try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")
        }
        await waitForRequestCount(1, recorder: recorder)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the router/process launcher stops the child.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExitTwoSurfacesThePendingQuestionAndLink() async throws {
        let threadID = "mcp:22222222-2222-4222-8222-222222222222"
        let launcher = SubscriptionFakeLauncher([
            AgentProcessOutput(
                standardOutput: Data(#"{"threadId":"\#(threadID)","runId":"run-7","status":"waiting"}"#.utf8),
                standardError: Data(),
                exitCode: 2
            ),
            AgentProcessOutput(
                standardOutput: Data(#"""
                {"thread":{"threadId":"\#(threadID)","link":"https://app.t3.codes/threads/\#(threadID)"},
                 "messages":[{"role":"assistant","runId":"run-7","text":"Should I keep the cold open?"}]}
                """#.utf8),
                standardError: Data(),
                exitCode: 0
            )
        ])
        let runner = T3Runner(
            configuration: T3Configuration(
                executable: URL(fileURLWithPath: "/usr/bin/t3"),
                project: T3ProjectReference(id: "t3-project")
            ),
            launcher: launcher
        )
        let settings = SubscriptionAISettings()
        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = runner

        var pendingQuestion: AgentCLIPendingQuestion?
        let subject = provider(
            settings: settings,
            builder: builder,
            onPending: { pendingQuestion = $0 }
        )

        do {
            _ = try await subject.complete(request: llmRequest(task: .analyze), apiKey: "")
            XCTFail("Expected a pending question")
        } catch let error as SubscriptionAIError {
            guard case let .pendingQuestion(question) = error else {
                return XCTFail("Wrong subscription error: \(error)")
            }
            XCTAssertEqual(question.question, "Should I keep the cold open?")
            XCTAssertEqual(question.threadID, threadID)
            XCTAssertEqual(question.openInT3URL?.absoluteString, "https://app.t3.codes/threads/\(threadID)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(pendingQuestion?.question, "Should I keep the cold open?")
    }

    // MARK: Parsing and probe

    func testReviewUsesTheExistingTolerantJSONParser() async throws {
        let project = SampleData.demoProject(language: .english)
        let scene = try XCTUnwrap(project.scenes.first)
        let fenced = "```json\n{\"title\":\"Hook\",\"severity\":\"suggestion\",\"message\":\"Make the opening concrete.\",\"suggestion\":\"Name the benefit.\",\"extra\":true}\n```"

        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: SubscriptionRunnerRecorder()) { _ in
            .completed(AgentCLIReply(provider: .t3, text: fenced))
        }
        let subject = provider(settings: SubscriptionAISettings(), builder: builder)
        var preferences = AppSettings.defaults.aiPreferences
        preferences.provider = .t3Code

        let comments = try await AnalysisService(provider: subject).analyze(
            scene: scene,
            project: project,
            settings: preferences,
            interfaceLanguage: .english,
            apiKey: ""
        )

        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.type, "Hook")
        XCTAssertEqual(comments.first?.severity, .suggestion)
        XCTAssertEqual(comments.first?.message, "Make the opening concrete.")
        XCTAssertEqual(comments.first?.suggestion, "Name the benefit.")
    }

    func testProbeSendsExactlyTheOKPrompt() async throws {
        let recorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: recorder) { _ in
            .completed(AgentCLIReply(provider: .t3, text: "OK"))
        }
        let prober = SubscriptionAIProber(
            settings: SubscriptionAISettings(),
            context: .standalone(),
            routerProvider: { selection, mapping in
                builder.threadMapping = mapping
                return try await builder.make(selection)
            }
        )

        let reply = try await prober.probe(selection: .defaultT3)
        XCTAssertEqual(reply, "OK")
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.first?.prompt, "Reply with exactly: OK")
    }

    func testProbeUsesAThrowawayThreadAndNeverReusesOrRecordsAProjectThread() async throws {
        let recorder = SubscriptionRunnerRecorder()
        let builder = SubscriptionTestRouterBuilder()
        builder.t3Runner = SubscriptionRecordingRunner(kind: .t3, recorder: recorder) { _ in
            .completed(AgentCLIReply(provider: .t3, text: "OK", threadID: "probe-thread"))
        }
        let project = SampleData.defaultProject
        var reads = 0
        var writes = 0
        let projectMapping = SubscriptionAIThreadMapping(
            read: { _ in
                reads += 1
                return "project-thread"
            },
            write: { _, _ in writes += 1 }
        )
        XCTAssertNotNil(projectMapping)

        var usedMappings: [any T3ThreadMapping] = []
        let prober = SubscriptionAIProber(
            settings: SubscriptionAISettings(),
            context: SubscriptionAIContext(projectTitle: project.title, threadMapping: projectMapping),
            routerProvider: { selection, mapping in
                usedMappings.append(mapping)
                builder.threadMapping = mapping
                return try await builder.make(selection)
            }
        )

        _ = try await prober.probe(selection: .defaultT3)
        _ = try await prober.probe(selection: .defaultT3)

        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].threadID)
        XCTAssertNil(requests[1].threadID, "A probe must never continue the project's review thread")
        XCTAssertEqual(reads, 0, "A probe must not read the project's aiThreadMap")
        XCTAssertEqual(writes, 0, "A probe must not record its test thread in the project")
        XCTAssertEqual(usedMappings.count, 2)
        XCTAssertTrue(usedMappings[0] is T3ThreadMapStore)
        XCTAssertTrue(usedMappings[1] is T3ThreadMapStore)
    }

    func testThreadInspectorDecodesTheDeepLink() async throws {
        let launcher = SubscriptionFakeLauncher([
            AgentProcessOutput(
                standardOutput: Data(#"{"thread":{"threadId":"thread-1","link":"https://app.t3.codes/threads/thread-1"}}"#.utf8),
                standardError: Data(),
                exitCode: 0
            )
        ])
        let inspector = SubscriptionAIT3ThreadInspector(launcher: launcher)
        let url = await inspector.link(
            threadID: "thread-1",
            executable: URL(fileURLWithPath: "/usr/bin/t3")
        )
        XCTAssertEqual(url?.absoluteString, "https://app.t3.codes/threads/thread-1")
    }

    // MARK: Factory fallback

    func testFactoryFallsBackToAnInstalledClaudeWhenT3IsMissing() async throws {
        let launcher = SubscriptionFakeLauncher([Self.claudeSuccess("OK")])
        let factory = SubscriptionAIRouterFactory(
            binariesProvider: { _ in
                AgentCLIBinaries(claude: URL(fileURLWithPath: "/usr/bin/claude"))
            },
            launcher: launcher
        )
        let settings = SubscriptionAISettings(
            t3Project: T3ProjectReference(id: "t3-project", name: "FrameScript IA")
        )

        let router = try await factory.makeRouter(
            selection: .defaultT3,
            settings: settings,
            threadMapping: T3ThreadMapStore()
        )
        let result = try await router.run(AgentCLIRequest(
            prompt: "Reply with exactly: OK",
            model: SubscriptionAISelection.defaultT3.agentModel,
            timeout: 5
        ))

        XCTAssertEqual(result.reply?.text, "OK")
        let requests = await launcher.recordedRequests()
        XCTAssertEqual(requests.first?.arguments.first, "-p")
    }

    func testFactoryRefreshesBinaryDiscoveryOnceWhenTheSelectedCLIIsMissing() async throws {
        let launcher = SubscriptionFakeLauncher([Self.claudeSuccess("OK")])
        let counter = BinariesCallCounter()
        let claudeURL = URL(fileURLWithPath: "/usr/bin/claude")
        let factory = SubscriptionAIRouterFactory(
            binariesProvider: { refresh in
                counter.calls.append(refresh)
                return refresh
                    ? AgentCLIBinaries(claude: claudeURL)
                    : AgentCLIBinaries()
            },
            launcher: launcher
        )

        let router = try await factory.makeRouter(
            selection: .defaultT3,
            settings: SubscriptionAISettings(t3Project: T3ProjectReference(id: "t3-project")),
            threadMapping: T3ThreadMapStore()
        )
        _ = try await router.run(AgentCLIRequest(prompt: "OK", model: SubscriptionAISelection.defaultT3.agentModel, timeout: 5))

        XCTAssertEqual(counter.calls, [false, true])
    }

    func testFactoryFallsBackWhenTheT3ProjectIsMissingButClaudeExists() async throws {
        let launcher = SubscriptionFakeLauncher([Self.claudeSuccess("OK")])
        let factory = SubscriptionAIRouterFactory(
            binariesProvider: { _ in
                AgentCLIBinaries(
                    t3: URL(fileURLWithPath: "/usr/bin/t3"),
                    claude: URL(fileURLWithPath: "/usr/bin/claude")
                )
            },
            launcher: launcher
        )

        let router = try await factory.makeRouter(
            selection: .defaultT3,
            settings: SubscriptionAISettings(),
            threadMapping: T3ThreadMapStore()
        )
        let result = try await router.run(AgentCLIRequest(
            prompt: "OK",
            model: SubscriptionAISelection.defaultT3.agentModel,
            timeout: 5
        ))

        XCTAssertEqual(result.reply?.text, "OK")
        let requests = await launcher.recordedRequests()
        XCTAssertEqual(requests.first?.arguments.first, "-p")
    }

    func testFactoryReportsTheMissingT3ProjectWhenNoFallbackExists() async throws {
        let factory = SubscriptionAIRouterFactory(
            binariesProvider: { _ in
                AgentCLIBinaries(t3: URL(fileURLWithPath: "/usr/bin/t3"))
            },
            launcher: SubscriptionFakeLauncher([])
        )

        do {
            _ = try await factory.makeRouter(
                selection: .defaultT3,
                settings: SubscriptionAISettings(),
                threadMapping: T3ThreadMapStore()
            )
            XCTFail("Expected a configuration error")
        } catch let error as SubscriptionAIError {
            XCTAssertEqual(error, .notConfigured(.t3ProjectMissing))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFactoryWithNoBinariesLetsTheRouterReportNoProvider() async throws {
        let factory = SubscriptionAIRouterFactory(
            binariesProvider: { _ in AgentCLIBinaries() },
            launcher: SubscriptionFakeLauncher([])
        )
        let router = try await factory.makeRouter(
            selection: .defaultT3,
            settings: SubscriptionAISettings(t3Project: T3ProjectReference(id: "t3-project")),
            threadMapping: T3ThreadMapStore()
        )

        do {
            _ = try await router.run(AgentCLIRequest(prompt: "OK", model: SubscriptionAISelection.defaultT3.agentModel, timeout: 5))
            XCTFail("Expected noProviderAvailable")
        } catch let error as AgentCLIError {
            XCTAssertEqual(error, .noProviderAvailable)
        }
    }

    // MARK: Runtime concurrency and exit-2

    func testConcurrentRequestIsRejectedAndTheFirstRunKeepsItsCancelSlot() async throws {
        let suiteName = "SubscriptionRuntime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SubscriptionAISettingsStore(userDefaults: defaults)

        let recorder = SubscriptionRunnerRecorder()
        let runner = SubscriptionRecordingRunner(kind: .t3, recorder: recorder) { _ in
            try await Task.sleep(for: .seconds(30))
            return .completed(AgentCLIReply(provider: .t3, text: "late"))
        }
        let router = AgentCLIRouter(
            configuredProvider: .t3,
            t3: runner,
            t3Probe: SubscriptionStubProbe(available: true),
            t3Model: SubscriptionAISelection.defaultT3.agentModel
        )
        let runtime = SubscriptionAIRuntime(
            store: store,
            routerFactory: StaticSubscriptionRouterProvider(router: router),
            inspector: SubscriptionAIT3ThreadInspector(launcher: SubscriptionFakeLauncher([]))
        )

        let first = Task {
            try await runtime.complete(request: llmRequest(task: .analyze))
        }
        let started = await waitUntil { runtime.isRunning }
        XCTAssertTrue(started)

        do {
            _ = try await runtime.complete(request: llmRequest(task: .bRollGeneration))
            XCTFail("Expected the second run to be refused")
        } catch let error as SubscriptionAIError {
            XCTAssertEqual(error, .busy)
        }
        XCTAssertTrue(runtime.isRunning, "The second run must not clear the first run's progress")

        runtime.cancel()
        do {
            _ = try await first.value
            XCTFail("Expected the first run to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(runtime.isRunning)
        XCTAssertEqual(runtime.lastOutcome, .cancelled)
    }

    func testNewThreadIsRefusedWhileARunIsActive() async throws {
        let suiteName = "SubscriptionRuntime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let project = SampleData.defaultProject
        let selection = SubscriptionAISettings.defaults.defaultSelection
        let key = try XCTUnwrap(SubscriptionAIThreadKey.storageKey(for: selection))
        project.aiThreadMap.threadIDsByProviderModel[key] = "thread-1"
        let projectStore = ProjectStore(project: project)
        projectStore.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let appState = AppState(
            projectStore: projectStore,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )

        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        let runner = SubscriptionRecordingRunner(kind: .t3, recorder: SubscriptionRunnerRecorder()) { _ in
            try await Task.sleep(for: .seconds(30))
            return .completed(AgentCLIReply(provider: .t3, text: "late"))
        }
        let router = AgentCLIRouter(
            configuredProvider: .t3,
            t3: runner,
            t3Probe: SubscriptionStubProbe(available: true),
            t3Model: selection.agentModel
        )
        let runtime = SubscriptionAIRuntime(
            store: store,
            routerFactory: StaticSubscriptionRouterProvider(router: router),
            inspector: SubscriptionAIT3ThreadInspector(launcher: SubscriptionFakeLauncher([]))
        )
        runtime.attach(appState: appState)

        XCTAssertEqual(runtime.threadID(for: selection), "thread-1")
        let run = Task {
            try await runtime.complete(request: llmRequest(task: .analyze))
        }
        let started = await waitUntil { runtime.isRunning }
        XCTAssertTrue(started)

        runtime.resetThread(for: selection)
        XCTAssertEqual(runtime.threadID(for: selection), "thread-1", "The in-flight run would record its thread again")

        runtime.cancel()
        _ = try? await run.value
        XCTAssertFalse(runtime.isRunning)
        runtime.resetThread(for: selection)
        XCTAssertNil(runtime.threadID(for: selection))
    }

    func testExitTwoPopulatesTheObservedPendingPrompt() async throws {
        let suiteName = "SubscriptionRuntime-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SubscriptionAISettingsStore(userDefaults: defaults)

        let question = AgentCLIPendingQuestion(
            threadID: "pending-thread",
            question: "Keep the cold open?"
        )
        let runner = SubscriptionRecordingRunner(kind: .t3, recorder: SubscriptionRunnerRecorder()) { _ in
            .awaitingAnswer(question)
        }
        let router = AgentCLIRouter(
            configuredProvider: .t3,
            t3: runner,
            t3Probe: SubscriptionStubProbe(available: true),
            t3Model: SubscriptionAISelection.defaultT3.agentModel
        )
        let runtime = SubscriptionAIRuntime(
            store: store,
            routerFactory: StaticSubscriptionRouterProvider(router: router),
            inspector: SubscriptionAIT3ThreadInspector(launcher: SubscriptionFakeLauncher([]))
        )

        let flag = SubscriptionObservationFlag()
        withObservationTracking {
            _ = runtime.pendingPrompt
        } onChange: {
            Task { await flag.increment() }
        }

        do {
            _ = try await runtime.complete(request: llmRequest(task: .analyze))
            XCTFail("Expected a pending question")
        } catch SubscriptionAIError.pendingQuestion {
            // Expected.
        }

        XCTAssertEqual(runtime.pendingPrompt?.question.question, "Keep the cold open?")
        let observed = await waitForObservation(flag)
        XCTAssertTrue(observed, "SwiftUI only presents the sheet when pendingPrompt is observable")
    }

    // MARK: Pure helpers

    func testProviderKindsMapToCLIKinds() {
        XCTAssertEqual(AIProviderKind.t3Code.agentCLIKind, .t3)
        XCTAssertEqual(AIProviderKind.claudeCode.agentCLIKind, .claude)
        XCTAssertEqual(AIProviderKind.codex.agentCLIKind, .codex)
        XCTAssertNil(AIProviderKind.groq.agentCLIKind)
        XCTAssertTrue(AIProviderKind.codex.isSubscriptionBacked)
        XCTAssertFalse(AIProviderKind.openRouter.isSubscriptionBacked)
    }

    func testSubscriptionLocalizationCoversAllThreeLanguages() throws {
        let tables = L10n.aiProvidersStrings
        let english = try XCTUnwrap(tables[.english])
        let russian = try XCTUnwrap(tables[.russian])
        let spanish = try XCTUnwrap(tables[.spanish])

        XCTAssertEqual(Set(russian.keys), Set(english.keys))
        XCTAssertEqual(Set(spanish.keys), Set(english.keys))
        XCTAssertTrue(english.values.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(russian.values.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(spanish.values.allSatisfy { !$0.isEmpty })
        XCTAssertFalse(english["settings.ai.subscription.privacy", default: ""].isEmpty)
    }

    func testCLIErrorsAreLocalizedInTheAppLanguage() throws {
        let russian = SubscriptionAIErrorDescription.localized(
            for: AgentCLIError.binaryNotFound(.t3),
            language: .russian
        )
        XCTAssertTrue(russian.contains("Не удалось найти"))
        XCTAssertFalse(russian.contains("Could not find"))

        let appError = try XCTUnwrap(AppError.ai(AgentCLIError.binaryNotFound(.t3)))
        let presentation = appError.presentation(language: .russian)
        XCTAssertTrue(presentation.message.contains("Не удалось найти"))
        XCTAssertFalse(presentation.message.contains("Could not find"))

        let configuration = try XCTUnwrap(AppError.ai(SubscriptionAIError.notConfigured(.t3ProjectMissing)))
        XCTAssertTrue(configuration.presentation(language: .spanish).message.contains("No hay un proyecto"))
        XCTAssertTrue(configuration.presentation(language: .russian).message.contains("Проект T3 Code не настроен"))
    }

    func testThreadStorageKeyRoundTrips() {
        let key = T3ThreadKey(providerInstanceID: "opencode", modelSlug: "opencode-go/deepseek-v4.1-flash")
        let raw = SubscriptionAIThreadKey.storageKey(key)
        XCTAssertEqual(raw, "opencode::opencode-go/deepseek-v4.1-flash")
        XCTAssertEqual(SubscriptionAIThreadKey.parse(raw), key)
        XCTAssertNil(SubscriptionAIThreadKey.parse("missing-separator"))
    }

    func testElapsedFormatting() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SubscriptionAIElapsedFormat.string(since: start, now: start), "0:00")
        XCTAssertEqual(SubscriptionAIElapsedFormat.string(since: start, now: start.addingTimeInterval(65)), "1:05")
        XCTAssertEqual(SubscriptionAIElapsedFormat.string(since: start, now: start.addingTimeInterval(180)), "3:00")
    }

    func testSettingsStorePersistsAndResets() throws {
        let suiteName = "FrameScript.SubscriptionAI.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let store = SubscriptionAISettingsStore(userDefaults: suite)
        XCTAssertEqual(store.settings.defaultTimeout, 180)
        store.settings.defaultTimeout = 240
        store.settings.setUseForAllTasks(false)
        store.settings.setSelection(SubscriptionAISelection(kind: .codex, modelSlug: "gpt-5.3-codex"), for: .hooks)

        let reloaded = SubscriptionAISettingsStore(userDefaults: suite)
        XCTAssertEqual(reloaded.settings.defaultTimeout, 240)
        XCTAssertFalse(reloaded.settings.useForAllTasks)
        XCTAssertEqual(reloaded.settings.selection(for: .hooks).kind, .codex)

        reloaded.reset()
        XCTAssertEqual(reloaded.settings, .defaults)
    }

    // MARK: Utilities

    private func waitForRequestCount(
        _ expected: Int,
        recorder: SubscriptionRunnerRecorder,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await recorder.recordedRequests().count >= expected { return }
            await Task.yield()
        }
        XCTFail("Runner was not called", file: file, line: line)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            await Task.yield()
        }
        return false
    }

    private func waitForObservation(_ flag: SubscriptionObservationFlag) async -> Bool {
        for _ in 0..<200 {
            if await flag.count > 0 { return true }
            await Task.yield()
        }
        return false
    }

    private static func claudeSuccess(_ text: String) -> AgentProcessOutput {
        AgentProcessOutput(
            standardOutput: Data(#"{"type":"result","subtype":"success","is_error":false,"result":"\#(text)","session_id":"session-1"}"#.utf8),
            standardError: Data(),
            exitCode: 0
        )
    }

    private func makeProjectMapping(
        project: FrameProject,
        expectedProjectID: String
    ) -> SubscriptionAIThreadMapping {
        SubscriptionAIThreadMapping(
            read: { key in
                guard project.aiThreadMap.t3ProjectID == expectedProjectID else { return nil }
                return project.aiThreadMap.threadIDsByProviderModel[SubscriptionAIThreadKey.storageKey(key)]
            },
            write: { threadID, key in
                project.aiThreadMap.t3ProjectID = expectedProjectID
                project.aiThreadMap.threadIDsByProviderModel[SubscriptionAIThreadKey.storageKey(key)] = threadID
            }
        )
    }
}
