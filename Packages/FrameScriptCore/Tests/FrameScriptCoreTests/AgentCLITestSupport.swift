import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Fixtures

enum AgentCLIFixtures {
    static func text(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: nil,
                subdirectory: "Fixtures/AgentCLI"
            ),
            "Missing fixture \(name)"
        )
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

// MARK: - Fake process launcher

/// Deterministic replacement for `SystemAgentProcessLauncher`.
///
/// Each queued step may return output, throw an error, and/or delay. A delay
/// that observes task cancellation throws `.cancelled`, mirroring the real
/// launcher's cooperative behaviour.
actor FakeProcessLauncher: AgentProcessLaunching {
    struct Step: Sendable {
        var output: AgentProcessOutput?
        var error: AgentCLIError?
        var delay: Duration?

        init(output: AgentProcessOutput? = nil, error: AgentCLIError? = nil, delay: Duration? = nil) {
            self.output = output
            self.error = error
            self.delay = delay
        }

        static func json(
            _ json: String,
            exit: Int32 = 0,
            stderr: String = "",
            stdoutTruncated: Bool = false
        ) -> Step {
            Step(
                output: AgentProcessOutput(
                    standardOutput: Data(json.utf8),
                    standardError: Data(stderr.utf8),
                    exitCode: exit,
                    standardOutputTruncated: stdoutTruncated
                )
            )
        }

        static func result(_ output: AgentProcessOutput) -> Step {
            Step(output: output)
        }

        static func failure(_ error: AgentCLIError, delay: Duration? = nil) -> Step {
            Step(error: error, delay: delay)
        }
    }

    private var steps: [Step]
    private(set) var requests: [AgentProcessRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func launch(_ request: AgentProcessRequest) async throws -> AgentProcessOutput {
        requests.append(request)
        guard !steps.isEmpty else {
            throw AgentCLIError.launchFailed("FakeProcessLauncher has no queued step")
        }
        let step = steps.removeFirst()
        if let delay = step.delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw AgentCLIError.cancelled
            }
        }
        if let error = step.error {
            throw error
        }
        guard let output = step.output else {
            throw AgentCLIError.launchFailed("FakeProcessLauncher step has no output")
        }
        return output
    }

    func recordedRequests() -> [AgentProcessRequest] {
        requests
    }
}

// MARK: - Shared test helpers

let fakeT3Executable = URL(fileURLWithPath: "/usr/bin/t3")
let fakeClaudeExecutable = URL(fileURLWithPath: "/usr/bin/claude")
let fakeCodexExecutable = URL(fileURLWithPath: "/usr/bin/codex")
let fakeProjectID = "22222222-2222-4222-8222-222222222222"
let fakeThreadID = "mcp:11111111-1111-4111-8111-111111111111"
let fakeProvider = "opencode"
let fakeModelSlug = "opencode-go/deepseek-v4.1-flash"

func makeT3Runner(
    launcher: FakeProcessLauncher,
    projectID: String? = fakeProjectID
) -> T3Runner {
    T3Runner(
        configuration: T3Configuration(
            executable: fakeT3Executable,
            project: T3ProjectReference(id: projectID, name: "FrameScript IA")
        ),
        launcher: launcher
    )
}

func makeRequest(
    prompt: String = "Reply with exactly: OK",
    kind: AgentCLIKind = .t3,
    provider: String? = fakeProvider,
    model: String? = fakeModelSlug,
    title: String? = "FrameScript runner probe",
    threadID: String? = nil,
    timeout: TimeInterval = 180
) -> AgentCLIRequest {
    AgentCLIRequest(
        prompt: prompt,
        model: AgentCLIModelSelection(
            kind: kind,
            providerInstanceID: kind == .t3 ? provider : nil,
            modelSlug: model
        ),
        title: title,
        threadID: threadID,
        timeout: timeout
    )
}

func captureAgentCLIError<T>(_ body: () async throws -> T) async -> AgentCLIError? {
    do {
        _ = try await body()
        return nil
    } catch let error as AgentCLIError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Fake runner for router tests

actor RunnerRecorder {
    private(set) var requests: [AgentCLIRequest] = []

    func record(_ request: AgentCLIRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [AgentCLIRequest] {
        requests
    }
}

struct RecordingRunner: AgentCLIRunner {
    let kind: AgentCLIKind
    let recorder: RunnerRecorder

    func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        await recorder.record(request)
        return .completed(AgentCLIReply(provider: kind, text: "from \(kind.rawValue)"))
    }
}

struct StubAvailabilityProbe: T3AvailabilityChecking {
    let available: Bool
    func isAvailable() async -> Bool { available }
}
