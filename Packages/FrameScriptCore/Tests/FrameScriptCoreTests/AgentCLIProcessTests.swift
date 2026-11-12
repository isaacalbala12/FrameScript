import Darwin
import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Bounded output buffer")
struct BoundedOutputBufferTests {
    @Test("keeps bytes under the limit untouched")
    func underLimit() {
        var buffer = BoundedOutputBuffer(limit: 10)
        buffer.append(Data("hello".utf8))
        #expect(buffer.data == Data("hello".utf8))
        #expect(buffer.isTruncated == false)
    }

    @Test("keeps the first N bytes and drains the rest")
    func truncates() {
        var buffer = BoundedOutputBuffer(limit: 5)
        buffer.append(Data("abc".utf8))
        buffer.append(Data("defgh".utf8))
        #expect(buffer.data == Data("abcde".utf8))
        #expect(buffer.isTruncated)
    }

    @Test("tail mode keeps the end of the stream")
    func tailTruncation() {
        var buffer = BoundedOutputBuffer(limit: 5, truncation: .keepTail)
        buffer.append(Data("abc".utf8))
        buffer.append(Data("def".utf8))
        #expect(buffer.data == Data("bcdef".utf8))
        #expect(buffer.isTruncated)
    }

    @Test("tail mode keeps the last N bytes of a large chunk")
    func tailLargeChunk() {
        var buffer = BoundedOutputBuffer(limit: 5, truncation: .keepTail)
        buffer.append(Data("0123456789".utf8))
        #expect(buffer.data == Data("56789".utf8))
        #expect(buffer.isTruncated)
    }

    @Test("an exact fit is not reported as truncated")
    func exactFit() {
        var buffer = BoundedOutputBuffer(limit: 5, truncation: .keepTail)
        buffer.append(Data("abcde".utf8))
        #expect(buffer.data == Data("abcde".utf8))
        #expect(!buffer.isTruncated)
    }

    @Test("a zero limit stores nothing")
    func zeroLimit() {
        var buffer = BoundedOutputBuffer(limit: 0)
        buffer.append(Data("x".utf8))
        #expect(buffer.data.isEmpty)
        #expect(buffer.isTruncated)
    }

    @Test("a negative limit is clamped to zero")
    func negativeLimit() {
        let buffer = BoundedOutputBuffer(limit: -4)
        #expect(buffer.limit == 0)
    }
}

@Suite("System process launcher")
struct SystemAgentProcessLauncherTests {
    private let launcher = SystemAgentProcessLauncher()

    @Test("captures stdout, stderr and stdin")
    func capturesStreams() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "cat; printf 'problem' >&2"],
                standardInput: Data("hello\n".utf8),
                timeout: 10
            )
        )

        #expect(output.exitCode == 0)
        #expect(output.succeeded)
        #expect(output.standardOutputText == "hello\n")
        #expect(output.standardErrorText == "problem")
        #expect(output.standardOutputTruncated == false)
    }

    @Test("a large prompt does not deadlock the stdin writer")
    func largeStdin() async throws {
        let payload = Data(repeating: 0x61, count: 256 * 1024)
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "cat"],
                standardInput: payload,
                timeout: 10
            )
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput == payload)
    }

    @Test("a child that exits without reading stdin does not raise SIGPIPE")
    func earlyExitWithLargeStdin() async throws {
        let payload = Data(repeating: 0x62, count: 256 * 1024)
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                standardInput: payload,
                timeout: 10
            )
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.isEmpty)
    }

    @Test("reports the child exit code")
    func exitCode() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 7"],
                timeout: 10
            )
        )

        #expect(output.exitCode == 7)
        #expect(output.succeeded == false)
    }

    @Test("passes environment overrides")
    func environment() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf %s \"$FRAMESCRIPT_TEST_VALUE\""],
                environment: ["FRAMESCRIPT_TEST_VALUE": "abc123"],
                timeout: 10
            )
        )

        #expect(output.standardOutputText == "abc123")
    }

    @Test("runs in the requested directory")
    func workingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("framescript-agentcli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "pwd"],
                currentDirectoryURL: directory,
                timeout: 10
            )
        )

        #expect(output.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(directory.lastPathComponent))
    }

    @Test("times out and terminates the child")
    func timeout() async {
        let error = await captureAgentCLIError {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["5"],
                    timeout: 0.25
                )
            )
        }

        guard case let .timedOut(seconds) = error else {
            Issue.record("Expected .timedOut, got \(String(describing: error))")
            return
        }
        #expect(seconds == 0.25)
    }

    @Test("cancelling the task kills the child")
    func cancellation() async {
        let task = Task {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 5; printf done"],
                    timeout: 30
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let error = await captureAgentCLIError {
            try await task.value
        }
        #expect(error == .cancelled)
    }

    @Test("truncates huge stdout without keeping it all")
    func truncatesStdout() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null"],
                timeout: 20,
                outputByteLimit: 1024
            )
        )

        #expect(output.exitCode == 0)
        #expect(output.standardOutput.count == 1024)
        #expect(output.standardOutputTruncated)
    }

    @Test("truncates huge stderr too")
    func truncatesStderr() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "dd if=/dev/zero bs=1024 count=100 1>&2 2>/dev/null"],
                timeout: 20,
                outputByteLimit: 512
            )
        )

        #expect(output.standardError.count == 512)
        #expect(output.standardErrorTruncated)
    }

    @Test("a non-positive timeout means no timeout")
    func noTimeout() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ok"],
                timeout: 0
            )
        )

        #expect(output.standardOutputText == "ok")
    }

    @Test("a missing executable is a launch failure")
    func missingExecutable() async {
        let error = await captureAgentCLIError {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/nonexistent/framescript-agentcli"),
                    timeout: 5
                )
            )
        }

        guard case .launchFailed = error else {
            Issue.record("Expected .launchFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("stdout truncation keeps the tail")
    func stdoutTruncationKeepsTail() async throws {
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf HEAD; dd if=/dev/zero bs=1024 count=100 2>/dev/null; printf TAIL"
                ],
                timeout: 20,
                outputByteLimit: 4_096
            )
        )

        #expect(output.standardOutput.count == 4_096)
        #expect(output.standardOutputTruncated)
        #expect(output.standardOutputText.hasSuffix("TAIL"))
        #expect(output.standardOutputText.contains("HEAD") == false)
    }

    @Test("a background child holding the pipe cannot outlive the request timeout")
    func boundedDrainAfterExit() async throws {
        let start = ContinuousClock.now
        let output = try await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 6 & echo parent-done"],
                timeout: 0.6
            )
        )
        let elapsed = start.duration(to: .now)

        #expect(output.standardOutputText.contains("parent-done"))
        #expect(output.standardOutputTruncated)
        #expect(elapsed < .seconds(1.5))
    }

    @Test("cancellation returns promptly even when the child ignores SIGTERM")
    func cancellationIsBounded() async {
        let task = Task {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; while true; do sleep 0.1; done"],
                    timeout: 30
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        task.cancel()
        let error = await captureAgentCLIError {
            try await task.value
        }
        let elapsed = start.duration(to: .now)

        #expect(error == .cancelled)
        #expect(elapsed < .seconds(1))
    }

    @Test("cancelling during pipe drain returns promptly")
    func cancellationDuringDrain() async {
        let task = Task {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 6 & echo parent-done"],
                    timeout: 30
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        task.cancel()
        let error = await captureAgentCLIError {
            try await task.value
        }
        let elapsed = start.duration(to: .now)

        #expect(error == .cancelled)
        #expect(elapsed < .seconds(1))
    }

    @Test("timeout kills the whole process group")
    func timeoutKillsGrandchildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("framescript-agentcli-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let error = await captureAgentCLIError {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 20 & echo $! > \"$FRAMESCRIPT_PID_FILE\"; wait"],
                    environment: ["FRAMESCRIPT_PID_FILE": pidFile.path],
                    timeout: 1
                )
            )
        }

        #expect(error == .timedOut(seconds: 1))
        let pid = try #require(await waitForPID(in: pidFile))
        defer { kill(pid, SIGKILL) }
        #expect(await waitUntilDead(pid))
    }

    @Test("cancellation kills the whole process group")
    func cancellationKillsGrandchildren() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("framescript-agentcli-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = Task {
            try await launcher.launch(
                AgentProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "sleep 20 & echo $! > \"$FRAMESCRIPT_PID_FILE\"; wait"],
                    environment: ["FRAMESCRIPT_PID_FILE": pidFile.path],
                    timeout: 30
                )
            )
        }
        try? await Task.sleep(for: .milliseconds(400))
        task.cancel()

        let error = await captureAgentCLIError {
            try await task.value
        }
        #expect(error == .cancelled)

        let pid = try #require(await waitForPID(in: pidFile))
        defer { kill(pid, SIGKILL) }
        #expect(await waitUntilDead(pid))
    }

    @Test("concurrent blocked children do not starve the cooperative pool")
    func concurrentLaunchesDoNotStarve() async {
        let launcher = SystemAgentProcessLauncher()
        let tasks = (0..<10).map { _ in
            Task {
                _ = try? await launcher.launch(
                    AgentProcessRequest(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: ["1.5"],
                        timeout: 10
                    )
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(150))

        let start = ContinuousClock.now
        _ = try? await launcher.launch(
            AgentProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["ok"],
                timeout: 10
            )
        )
        let elapsed = start.duration(to: .now)

        #expect(elapsed < .seconds(1))
        for task in tasks {
            _ = await task.value
        }
    }
}

private func waitForPID(in file: URL, timeout: TimeInterval = 2) async -> pid_t? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let data = try? Data(contentsOf: file),
           let pid = pid_t(String(decoding: data, as: UTF8.self)
               .trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

private func waitUntilDead(_ pid: pid_t, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if !processIsRunning(pid) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// `kill(pid, 0)` succeeds for zombies too; treat a zombie as dead because it
/// has released the CPU and its pipes.
private func processIsRunning(_ pid: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    guard result == size else { return false }
    return info.pbi_status != 5 // SZOMB
}
