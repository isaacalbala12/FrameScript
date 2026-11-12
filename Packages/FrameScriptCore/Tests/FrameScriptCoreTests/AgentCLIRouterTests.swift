import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Provider routing")
struct AgentCLIRouterTests {
    @Test("prefers T3 when the server responds")
    func prefersT3() async throws {
        let t3 = RunnerRecorder()
        let claude = RunnerRecorder()
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: t3),
            claude: RecordingRunner(kind: .claude, recorder: claude),
            t3Probe: StubAvailabilityProbe(available: true)
        )

        let result = try await router.run(makeRequest())

        #expect(result.provider == .t3)
        #expect(await t3.recordedRequests().count == 1)
        #expect(await claude.recordedRequests().isEmpty)
    }

    @Test("falls back to Claude when T3 is not running")
    func fallsBackToClaude() async throws {
        let t3 = RunnerRecorder()
        let claude = RunnerRecorder()
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: t3),
            claude: RecordingRunner(kind: .claude, recorder: claude),
            t3Probe: StubAvailabilityProbe(available: false)
        )

        let result = try await router.run(makeRequest())

        #expect(result.provider == .claude)
        #expect(await t3.recordedRequests().isEmpty)
        #expect(await claude.recordedRequests().count == 1)
    }

    @Test("an explicit T3 choice still falls back when the server is down")
    func explicitT3FallsBack() async throws {
        let claude = RunnerRecorder()
        let router = AgentCLIRouter(
            configuredProvider: .t3,
            t3: RecordingRunner(kind: .t3, recorder: RunnerRecorder()),
            claude: RecordingRunner(kind: .claude, recorder: claude),
            t3Probe: StubAvailabilityProbe(available: false)
        )

        let result = try await router.run(makeRequest())

        #expect(result.provider == .claude)
        #expect(await claude.recordedRequests().count == 1)
    }

    @Test("an explicit Codex choice wins even when T3 is available")
    func explicitCodex() async throws {
        let codex = RunnerRecorder()
        let router = AgentCLIRouter(
            configuredProvider: .codex,
            t3: RecordingRunner(kind: .t3, recorder: RunnerRecorder()),
            claude: RecordingRunner(kind: .claude, recorder: RunnerRecorder()),
            codex: RecordingRunner(kind: .codex, recorder: codex),
            t3Probe: StubAvailabilityProbe(available: true)
        )

        let result = try await router.run(makeRequest())

        #expect(result.provider == .codex)
        #expect(await codex.recordedRequests().count == 1)
    }

    @Test("Claude falls back to Codex when Claude is not installed")
    func claudeFallsBackToCodex() async throws {
        let codex = RunnerRecorder()
        let router = AgentCLIRouter(
            configuredProvider: .claude,
            codex: RecordingRunner(kind: .codex, recorder: codex)
        )

        let result = try await router.run(makeRequest(kind: .claude))

        #expect(result.provider == .codex)
        #expect(await codex.recordedRequests().count == 1)
    }

    @Test("no installed CLI is a clear error")
    func noProvider() async {
        let router = AgentCLIRouter(t3Probe: StubAvailabilityProbe(available: false))

        let error = await captureAgentCLIError {
            try await router.run(makeRequest())
        }

        #expect(error == .noProviderAvailable)
        #expect(await router.resolvedProvider() == nil)
    }

    @Test("fallback clears the T3 thread id and swaps the model")
    func fallbackAdaptsRequest() async throws {
        let claude = RunnerRecorder()
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: RunnerRecorder()),
            claude: RecordingRunner(kind: .claude, recorder: claude),
            t3Probe: StubAvailabilityProbe(available: false),
            claudeModelSlug: "sonnet"
        )

        _ = try await router.run(makeRequest(threadID: fakeThreadID))

        let captured = await claude.recordedRequests()
        let received = try #require(captured.first)
        #expect(received.threadID == nil)
        #expect(received.model.kind == .claude)
        #expect(received.model.modelSlug == "sonnet")
        #expect(received.model.providerInstanceID == nil)
    }

    @Test("a task configured for Claude uses the T3 model when routed to T3")
    func t3ModelAdaptation() async throws {
        let t3 = RunnerRecorder()
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: t3),
            t3Probe: StubAvailabilityProbe(available: true),
            t3Model: AgentCLIModelSelection(
                kind: .t3,
                providerInstanceID: "opencode",
                modelSlug: "opencode-go/deepseek-v4.1-flash"
            )
        )

        _ = try await router.run(makeRequest(kind: .claude, provider: nil, model: nil))

        let captured = await t3.recordedRequests()
        let received = try #require(captured.first)
        #expect(received.model.kind == .t3)
        #expect(received.model.providerInstanceID == "opencode")
        #expect(received.model.modelSlug == "opencode-go/deepseek-v4.1-flash")
    }

    @Test("a complete T3 selection is passed through untouched")
    func t3SelectionPassThrough() async throws {
        let t3 = RunnerRecorder()
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: t3),
            t3Probe: StubAvailabilityProbe(available: true),
            t3Model: AgentCLIModelSelection(kind: .t3, providerInstanceID: "other", modelSlug: "other/model")
        )

        _ = try await router.run(makeRequest())

        let captured = await t3.recordedRequests()
        let received = try #require(captured.first)
        #expect(received.model.providerInstanceID == fakeProvider)
        #expect(received.model.modelSlug == fakeModelSlug)
    }

    @Test("resolvedProvider reports the winner")
    func resolvedProvider() async {
        let router = AgentCLIRouter(
            t3: RecordingRunner(kind: .t3, recorder: RunnerRecorder()),
            t3Probe: StubAvailabilityProbe(available: true)
        )

        #expect(await router.resolvedProvider() == .t3)
    }
}
