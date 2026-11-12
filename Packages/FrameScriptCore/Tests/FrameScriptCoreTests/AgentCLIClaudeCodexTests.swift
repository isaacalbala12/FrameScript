import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Claude CLI runner")
struct ClaudeCLIRunnerTests {
    @Test("parses the real claude -p JSON result")
    func success() async throws {
        let fixture = try AgentCLIFixtures.text("claude-result.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        let result = try await runner.run(makeRequest(kind: .claude, model: "sonnet"))

        let reply = try #require(result.reply)
        #expect(reply.provider == .claude)
        #expect(reply.text == "OK")
        #expect(reply.sessionID == "44444444-4444-4444-8444-444444444444")

        let recorded = await launcher.recordedRequests()
        let processRequest = try #require(recorded.first)
        #expect(processRequest.arguments == [
            "-p", "--output-format", "json", "--no-session-persistence",
            "--model", "sonnet"
        ])
        #expect(processRequest.standardInput == Data("Reply with exactly: OK".utf8))
    }

    @Test("uses Claude's default model when none is configured")
    func defaultModel() async throws {
        let fixture = try AgentCLIFixtures.text("claude-result.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .claude, model: nil))

        let recorded = await launcher.recordedRequests()
        #expect(recorded.first?.arguments.contains("--model") == false)
    }

    @Test("is_error true is a failed run")
    func errorFlag() async {
        let envelope = """
        {"type":"result","subtype":"error_during_execution","is_error":true,"result":"credit exhausted","session_id":"s"}
        """
        let launcher = FakeProcessLauncher([.json(envelope, exit: 1)])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .claude))
        }

        #expect(error == .runFailed(threadID: nil, message: "credit exhausted", exitCode: 1))
    }

    @Test("malformed JSON is reported")
    func malformed() async {
        let launcher = FakeProcessLauncher([.json("claude said hi")])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .claude))
        }

        #expect(error == .malformedOutput(
            exitCode: 0,
            detail: "Expected one JSON object from claude -p."
        ))
    }

    @Test("a process failure without JSON keeps stderr")
    func failureWithoutJSON() async {
        let launcher = FakeProcessLauncher([
            .json("", exit: 2, stderr: "not logged in")
        ])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .claude))
        }

        #expect(error == .runFailed(threadID: nil, message: "not logged in", exitCode: 2))
    }

    @Test("an empty prompt does not launch")
    func emptyPrompt() async {
        let launcher = FakeProcessLauncher([])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(prompt: "\n", kind: .claude))
        }

        #expect(error == .invalidConfiguration("The AI prompt is empty."))
        let recorded = await launcher.recordedRequests()
        #expect(recorded.isEmpty)
    }
}

@Suite("Codex CLI runner")
struct CodexCLIRunnerTests {
    @Test("parses the real codex exec JSONL stream")
    func success() async throws {
        let fixture = try AgentCLIFixtures.text("codex-exec.jsonl")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let result = try await runner.run(makeRequest(kind: .codex, model: "gpt-5.1-codex-mini"))

        let reply = try #require(result.reply)
        #expect(reply.provider == .codex)
        #expect(reply.text == "OK")
        #expect(reply.sessionID == "66666666-6666-4666-8666-666666666666")

        let recorded = await launcher.recordedRequests()
        let processRequest = try #require(recorded.first)
        #expect(processRequest.arguments == [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral",
            "-m", "gpt-5.1-codex-mini", "-"
        ])
        #expect(processRequest.standardInput == Data("Reply with exactly: OK".utf8))
    }

    @Test("uses Codex's default model when none is configured")
    func defaultModel() async throws {
        let fixture = try AgentCLIFixtures.text("codex-exec.jsonl")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .codex, model: nil))

        let recorded = await launcher.recordedRequests()
        #expect(recorded.first?.arguments.contains("-m") == false)
        #expect(recorded.first?.arguments.last == "-")
    }

    @Test("a malformed line does not discard the final agent message")
    func toleratesMalformedLine() async throws {
        let fixture = """
        {"type":"thread.started","thread_id":"t"}
        this is not json
        {"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
        {"type":"turn.completed","usage":{}}
        """
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let result = try await runner.run(makeRequest(kind: .codex))
        let reply = try #require(result.reply)

        #expect(reply.text == "OK")
        #expect(reply.sessionID == "t")
    }

    @Test("no agent message is malformed output")
    func noAgentMessage() async {
        let launcher = FakeProcessLauncher([
            .json(#"{"type":"thread.started","thread_id":"t"}"#)
        ])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .codex))
        }

        #expect(error == .malformedOutput(exitCode: 0, detail: "codex printed no agent message."))
    }

    @Test("an error event is surfaced on a failed exit")
    func errorEvent() async {
        let events = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"error","message":"sandbox denied"}
        """
        let launcher = FakeProcessLauncher([.json(events, exit: 1)])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(kind: .codex))
        }

        #expect(error == .runFailed(threadID: nil, message: "sandbox denied", exitCode: 1))
    }

    @Test("an empty prompt does not launch")
    func emptyPrompt() async {
        let launcher = FakeProcessLauncher([])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(prompt: " ", kind: .codex))
        }

        #expect(error == .invalidConfiguration("The AI prompt is empty."))
        let recorded = await launcher.recordedRequests()
        #expect(recorded.isEmpty)
    }
}
