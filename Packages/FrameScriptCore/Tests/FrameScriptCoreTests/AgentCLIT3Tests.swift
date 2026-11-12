import Foundation
import Testing
@testable import FrameScriptCore

@Suite("T3 runner")
struct T3RunnerTests {
    @Test("start sends the prompt on stdin and parses the real CLI envelope")
    func startSuccess() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-start.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = makeT3Runner(launcher: launcher)
        let request = makeRequest()

        let result = try await runner.run(request)

        let reply = try #require(result.reply)
        #expect(reply.provider == .t3)
        #expect(reply.text == "OK")
        #expect(reply.threadID == fakeThreadID)
        #expect(reply.runID == "run:thread:mcp%3A11111111-1111-4111-8111-111111111111:ordinal:1")
        #expect(result.pendingQuestion == nil)

        let recorded = await launcher.recordedRequests()
        let processRequest = try #require(recorded.first)
        #expect(processRequest.executableURL == fakeT3Executable)
        #expect(processRequest.arguments == [
            "thread", "start", fakeProjectID, "-",
            "--provider", fakeProvider,
            "--model", fakeModelSlug,
            "--title", "FrameScript runner probe",
            "--wait", "--json"
        ])
        #expect(processRequest.standardInput == Data("Reply with exactly: OK".utf8))
        #expect(processRequest.timeout == 180)
    }

    @Test("send reuses the thread and never passes provider or model")
    func sendSuccess() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-start.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = makeT3Runner(launcher: launcher)

        let result = try await runner.run(makeRequest(threadID: fakeThreadID))

        #expect(result.reply?.threadID == fakeThreadID)
        let recorded = await launcher.recordedRequests()
        let processRequest = try #require(recorded.first)
        #expect(processRequest.arguments == [
            "thread", "send", fakeThreadID, "-", "--wait", "--json"
        ])
        #expect(!processRequest.arguments.contains("--provider"))
        #expect(!processRequest.arguments.contains("--model"))
    }

    @Test("omit --title when no title was supplied")
    func startWithoutTitle() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-start.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = makeT3Runner(launcher: launcher)

        _ = try await runner.run(makeRequest(title: nil))

        let recorded = await launcher.recordedRequests()
        let arguments = try #require(recorded.first?.arguments)
        #expect(!arguments.contains("--title"))
    }

    @Test("exit 1 is a failed run with the thread id and CLI error")
    func exitOneIsRunFailed() async throws {
        let envelope = """
        {"threadId":"\(fakeThreadID)","runId":"run:1","status":"failed","reply":null,"error":"provider crashed"}
        """
        let launcher = FakeProcessLauncher([
            .json(envelope, exit: 1, stderr: "Thread \(fakeThreadID) stopped with status failed: provider crashed")
        ])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error == .runFailed(
            threadID: fakeThreadID,
            message: "provider crashed",
            exitCode: 1
        ))
    }

    @Test("exit 1 without JSON falls back to stderr")
    func exitOneWithoutJSON() async {
        let launcher = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No running T3 Code server uses /tmp/t3")
        ])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error == .serverUnavailable("No running T3 Code server uses /tmp/t3"))
    }

    @Test("exit 2 returns the pending question and the open-in-T3 link")
    func exitTwoReturnsPendingQuestion() async throws {
        let waiting = """
        {"threadId":"\(fakeThreadID)","runId":"run:1","status":"waiting","reply":null,"error":null}
        """
        let show = """
        {
          "thread": {
            "threadId": "\(fakeThreadID)",
            "link": "https://app.t3.codes/threads/33333333-3333-4333-8333-333333333333/mcp%3A11111111-1111-4111-8111-111111111111"
          },
          "messages": [
            {"role": "user", "runId": "run:1", "text": "Write titles"},
            {"role": "assistant", "runId": "run:1", "text": "Do you want the short or the long title?"}
          ]
        }
        """
        let launcher = FakeProcessLauncher([
            .json(waiting, exit: 2, stderr: "Thread \(fakeThreadID) is waiting for an answer."),
            .json(show)
        ])
        let runner = makeT3Runner(launcher: launcher)

        let result = try await runner.run(makeRequest())

        let pending = try #require(result.pendingQuestion)
        #expect(pending.threadID == fakeThreadID)
        #expect(pending.question == "Do you want the short or the long title?")
        #expect(pending.openInT3URL?.absoluteString.hasPrefix("https://app.t3.codes/threads/") == true)
        #expect(pending.provider == .t3)

        let recorded = await launcher.recordedRequests()
        #expect(recorded.count == 2)
        #expect(recorded.last?.arguments == [
            "thread", "show", fakeThreadID, "--messages", "1", "--json"
        ])
    }

    @Test("exit 2 still reports the thread when thread show fails")
    func exitTwoWithoutShow() async throws {
        let waiting = """
        {"threadId":"\(fakeThreadID)","runId":"run:1","status":"waiting","reply":null,"error":null}
        """
        let launcher = FakeProcessLauncher([
            .json(waiting, exit: 2, stderr: "Thread \(fakeThreadID) is waiting for an answer. Open it in T3 Code to respond."),
            .json("", exit: 1, stderr: "show failed")
        ])
        let runner = makeT3Runner(launcher: launcher)

        let result = try await runner.run(makeRequest())
        let pending = try #require(result.pendingQuestion)

        #expect(pending.threadID == fakeThreadID)
        #expect(pending.question.contains("waiting for an answer"))
        #expect(pending.openInT3URL == nil)
    }

    @Test("a completed envelope without reply text is rejected")
    func completedWithoutReply() async {
        let envelope = """
        {"threadId":"\(fakeThreadID)","runId":"run:1","status":"completed","reply":null,"error":null}
        """
        let launcher = FakeProcessLauncher([.json(envelope)])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error == .malformedOutput(exitCode: 0, detail: "The run completed without a reply."))
    }

    @Test("malformed JSON is reported, not silently treated as empty text")
    func malformedJSON() async {
        let launcher = FakeProcessLauncher([.json("not json at all")])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error == .malformedOutput(
            exitCode: 0,
            detail: "Expected a JSON object with threadId/status/reply."
        ))
    }

    @Test("an empty prompt never launches a process")
    func emptyPrompt() async {
        let launcher = FakeProcessLauncher([])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(prompt: "   \n"))
        }

        #expect(error == .invalidConfiguration("The AI prompt is empty."))
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("missing provider or model is rejected before launch")
    func missingModelSelection() async {
        let launcher = FakeProcessLauncher([])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest(provider: nil))
        }

        #expect(error == .invalidConfiguration("T3 needs both a provider instance id and a model slug."))
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("missing project is rejected before launch")
    func missingProject() async {
        let launcher = FakeProcessLauncher([])
        let runner = makeT3Runner(launcher: launcher, projectID: nil)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error?.errorDescription?.contains("No T3 project is configured") == true)
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("custom timeout and output cap reach the process layer")
    func timeoutAndOutputCap() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-start.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let runner = makeT3Runner(launcher: launcher)
        var request = makeRequest()
        request.timeout = 42
        request.outputByteLimit = 4_096

        _ = try await runner.run(request)

        let recorded = await launcher.recordedRequests()
        #expect(recorded.first?.timeout == 42)
        #expect(recorded.first?.outputByteLimit == 4_096)
    }

    @Test("parses the sanitized thread show fixture")
    func showFixture() throws {
        let show = try #require(
            T3Runner.decodeShowEnvelope(try AgentCLIFixtures.text("t3-thread-show.json"))
        )

        #expect(show.thread?.threadId == fakeThreadID)
        #expect(show.thread?.projectId == fakeProjectID)
        #expect(show.thread?.link?.hasPrefix("https://app.t3.codes/threads/") == true)
        #expect(show.messages?.count == 2)
        #expect(show.messages?.last?.role == "assistant")
        #expect(show.messages?.last?.text == "OK")
    }

    @Test("start maps missing projects and stopped servers to the right errors")
    func startInfrastructureErrors() async {
        let missing = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No T3 Code project matches '\(fakeProjectID)'. Pass a project id or a path inside a project.")
        ])
        let missingError = await captureAgentCLIError {
            try await makeT3Runner(launcher: missing).run(makeRequest())
        }
        #expect(missingError == .projectNotFound(fakeProjectID))

        let stopped = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No running T3 Code server uses /tmp/t3. Start T3 Code, then retry.")
        ])
        let stoppedError = await captureAgentCLIError {
            try await makeT3Runner(launcher: stopped).run(makeRequest())
        }
        #expect(stoppedError?.errorDescription?.contains("not reachable") == true)
    }

    @Test("a launcher timeout surfaces unchanged")
    func launcherTimeout() async {
        let launcher = FakeProcessLauncher([.failure(.timedOut(seconds: 2))])
        let runner = makeT3Runner(launcher: launcher)

        let error = await captureAgentCLIError {
            try await runner.run(makeRequest())
        }

        #expect(error == .timedOut(seconds: 2))
    }

    @Test("cancelling the run cancels the process work")
    func cancellationPropagates() async {
        let launcher = FakeProcessLauncher([
            .failure(.cancelled, delay: .seconds(5))
        ])
        let runner = makeT3Runner(launcher: launcher)

        let task = Task {
            try await runner.run(makeRequest())
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let error = await captureAgentCLIError {
            try await task.value
        }
        #expect(error == .cancelled)
    }

    @Test("the pending-question timeout is capped at 20 seconds")
    func showTimeoutCap() async throws {
        let waiting = """
        {"threadId":"\(fakeThreadID)","runId":"run:1","status":"waiting","reply":null,"error":null}
        """
        let launcher = FakeProcessLauncher([
            .json(waiting, exit: 2),
            .json("", exit: 1)
        ])
        let runner = makeT3Runner(launcher: launcher)
        var request = makeRequest()
        request.timeout = 600

        _ = try await runner.run(request)

        let recorded = await launcher.recordedRequests()
        #expect(recorded.last?.timeout == 20)
    }
}
