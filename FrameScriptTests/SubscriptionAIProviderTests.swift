import Foundation
import FrameScriptCore
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
            routerProvider: { selection in try await builder.make(selection) }
        )

        let reply = try await prober.probe(selection: .defaultT3)
        XCTAssertEqual(reply, "OK")
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.first?.prompt, "Reply with exactly: OK")
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
