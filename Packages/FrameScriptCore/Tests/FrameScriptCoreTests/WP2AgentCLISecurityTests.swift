import Foundation
import Testing
@testable import FrameScriptCore

/// WP2 regressions for the agent-CLI security and correctness fixes.
@Suite("WP2 agent CLI security")
struct WP2AgentCLISecurityTests {
    // MARK: Codex sandbox and turn status

    @Test("codex always pins the read-only sandbox")
    func codexPinsReadOnlySandbox() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("codex-exec.jsonl"))])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .codex, model: "gpt-5.1-codex-mini"))

        let recorded = await launcher.recordedRequests()
        let arguments = try #require(recorded.first?.arguments)
        let sandbox = try #require(arguments.firstIndex(of: "-s"))
        #expect(arguments[sandbox + 1] == "read-only")
        // The prompt still travels on stdin, after the `-` terminator.
        #expect(arguments.last == "-")
        #expect(recorded.first?.standardInput == Data("Reply with exactly: OK".utf8))
    }

    @Test("a turn.failed event fails the run even with exit code 0")
    func codexTurnFailedWithExitZeroThrows() async {
        let transcript = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"item.completed","item":{"type":"agent_message","text":"partial"}}
        {"type":"turn.failed","error":{"message":"context window exceeded"}}
        """
        let launcher = FakeProcessLauncher([.json(transcript, exit: 0)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .codex))
        }

        #expect(error == .runFailed(threadID: nil, message: "context window exceeded", exitCode: 0))
    }

    @Test("a recoverable error event before a completed turn still succeeds")
    func codexRecoverableErrorEventSucceeds() async throws {
        let transcript = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"error","message":"stream disconnected, reconnecting"}
        {"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
        {"type":"turn.completed","usage":{}}
        """
        let launcher = FakeProcessLauncher([.json(transcript, exit: 0)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let result = try await runner.run(makeRequest(kind: .codex))
        let reply = try #require(result.reply)

        #expect(reply.text == "OK")
    }

    @Test("an agent message without turn.completed is not a success")
    func codexMissingTurnCompletedFails() async {
        let transcript = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"item.completed","item":{"type":"agent_message","text":"cut off"}}
        """
        let launcher = FakeProcessLauncher([.json(transcript, exit: 0)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .codex))
        }

        #expect(error == .runFailed(threadID: nil, message: "codex did not complete the turn.", exitCode: 0))
    }

    // MARK: Claude restrictions

    @Test("claude runs without prompts and with its dangerous tools denied")
    func claudePinsNonInteractiveModeAndDeniesTools() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("claude-result.json"))])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .claude, model: "sonnet"))

        let recorded = await launcher.recordedRequests()
        let arguments = try #require(recorded.first?.arguments)
        let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[mode + 1] == "dontAsk")
        #expect(arguments.contains("--strict-mcp-config"))
        let denied = try #require(arguments.firstIndex(of: "--disallowedTools"))
        let deniedList = try #require(arguments[safe: denied + 1])
        for tool in ["Bash", "Write", "Edit", "Read", "WebFetch", "WebSearch", "Agent", "ExitPlanMode"] {
            #expect(deniedList.contains(tool), "\(tool) must be denied")
        }
    }

    // MARK: Thread id injection

    @Test("a thread id that looks like a CLI option never reaches t3")
    func t3RejectsOptionLikeThreadID() async {
        let launcher = FakeProcessLauncher([])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(threadID: "--base-dir=/tmp/injected"))
        }

        #expect(error == .invalidConfiguration("The T3 thread id in this project is not valid."))
        #expect(await launcher.recordedRequests().isEmpty)
    }

    @Test("a thread id with shell-ish characters never reaches t3")
    func t3RejectsUnsafeThreadIDCharacters() async {
        let launcher = FakeProcessLauncher([])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(threadID: "thread-1; rm -rf /"))
        }

        #expect(error == .invalidConfiguration("The T3 thread id in this project is not valid."))
        #expect(await launcher.recordedRequests().isEmpty)
    }

    @Test("a valid thread id is passed as a plain operand")
    func t3AcceptsValidThreadID() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("t3-thread-start.json"))])
        let runner = makeT3Runner(launcher: launcher)

        _ = try await runner.run(makeRequest(threadID: fakeThreadID))

        let recorded = await launcher.recordedRequests()
        let arguments = try #require(recorded.first?.arguments)
        #expect(Array(arguments.prefix(3)) == ["thread", "send", fakeThreadID])
    }

    @Test("the thread id validator accepts CLI ids and rejects options")
    func threadIdentifierValidation() {
        #expect(T3ThreadIdentifier.normalized("mcp:11111111-1111-4111-8111-111111111111")
            == "mcp:11111111-1111-4111-8111-111111111111")
        #expect(T3ThreadIdentifier.normalized(" 11111111-1111-4111-8111-111111111111 ")
            == "11111111-1111-4111-8111-111111111111")
        #expect(T3ThreadIdentifier.normalized("--help") == nil)
        #expect(T3ThreadIdentifier.normalized("-s") == nil)
        #expect(T3ThreadIdentifier.normalized("thread one") == nil)
        #expect(T3ThreadIdentifier.normalized("") == nil)
        #expect(T3ThreadIdentifier.normalized(String(repeating: "a", count: 129)) == nil)
    }

    // MARK: T3 project creation

    @Test("creating a project that already exists resolves it instead of failing")
    func t3ResolveOrCreateRecoversFromAlreadyExists() async throws {
        let launcher = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No T3 Code project matches '/tmp/wp2-project'."),
            .json("", exit: 1, stderr: "A T3 Code project already exists for '/tmp/wp2-project'."),
            .json(#"[{"threadId":"t","projectId":"11111111-1111-4111-8111-111111111111"}]"#)
        ])
        let resolver = T3ProjectResolver(
            configuration: T3ProjectResolver.Configuration(
                executable: fakeT3Executable,
                launcher: launcher
            )
        )

        let project = try await resolver.resolveOrCreate(
            T3ProjectReference(path: "/tmp/wp2-project"),
            createIfMissing: true
        )

        #expect(project.id == "11111111-1111-4111-8111-111111111111")
        #expect(await launcher.recordedRequests().count == 3)
    }

    @Test("a missing project is still created when asked")
    func t3ResolveOrCreateCreatesMissingProject() async throws {
        let launcher = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No T3 Code project matches '/tmp/wp2-project'."),
            .json("Added project 22222222-2222-4222-8222-222222222222 (WP2) at /tmp/wp2-project.")
        ])
        let resolver = T3ProjectResolver(
            configuration: T3ProjectResolver.Configuration(
                executable: fakeT3Executable,
                launcher: launcher
            )
        )

        let project = try await resolver.resolveOrCreate(
            T3ProjectReference(path: "/tmp/wp2-project"),
            createIfMissing: true
        )

        #expect(project.id == "22222222-2222-4222-8222-222222222222")
    }

    // MARK: Process isolation

    @Test("a spawned CLI does not inherit unrelated file descriptors")
    func spawnedChildDoesNotInheritDescriptors() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wp2-fd-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let opened = open(fileURL.path, O_RDONLY)
        #expect(opened >= 0)
        // Move it out of the low range the shell uses for its own plumbing.
        let descriptor = fcntl(opened, F_DUPFD, 40)
        close(opened)
        #expect(descriptor >= 40)
        defer { close(descriptor) }

        let launcher = SystemAgentProcessLauncher()
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "ls /dev/fd"],
                timeout: 10,
                outputByteLimit: 65_536
            )
        )

        #expect(output.exitCode == 0)
        let listed = output.standardOutputText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(!listed.contains(String(descriptor)), "the child inherited fd \(descriptor)")
    }

    @Test("the drain budget never collapses to zero at the deadline")
    func drainBudgetKeepsFloor() {
        let deadline = Date()
        #expect(SystemAgentProcessLauncher.drainBudget(for: deadline, now: deadline) == 0.25)
        #expect(SystemAgentProcessLauncher.drainBudget(for: deadline, now: deadline.addingTimeInterval(5)) == 0.25)
        #expect(SystemAgentProcessLauncher.drainBudget(for: deadline, now: deadline.addingTimeInterval(-1)) == 1.0)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
