import Foundation
import Testing
@testable import FrameScriptMCP

// MARK: - Binary discovery

enum FrameScriptBinary {
    /// Resolves the executable built by SwiftPM. Returns nil when tests run
    /// without a prior `swift build`, in which case the end-to-end test is
    /// skipped instead of failing.
    static func locate() -> URL? {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["FRAMESCRIPT_BINARY"],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        // .../Packages/FrameScriptCore/Tests/FrameScriptMCPTests/StdioEndToEndTests.swift
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        var candidates: [URL] = [
            packageRoot.appendingPathComponent(".build/debug/framescript"),
            packageRoot.appendingPathComponent(".build/release/framescript")
        ]

        let buildDirectory = packageRoot.appendingPathComponent(".build")
        if let entries = try? fileManager.contentsOfDirectory(
            at: buildDirectory,
            includingPropertiesForKeys: nil
        ) {
            for entry in entries {
                candidates.append(entry.appendingPathComponent("debug/framescript"))
                candidates.append(entry.appendingPathComponent("release/framescript"))
            }
        }

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Subprocess session

final class SubprocessSession: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var lines: [String] = []
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private let lineAvailable = DispatchSemaphore(value: 0)

    init(binary: URL) throws {
        process.executableURL = binary
        process.arguments = ["mcp"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consumeStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stderrBuffer.append(data)
            self.lock.unlock()
        }

        try process.run()
    }

    func send(_ value: JSONValue) throws {
        var data = try MCPJSON.encode(value)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    func nextLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            lock.unlock()

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            if lineAvailable.wait(timeout: .now() + remaining) == .timedOut {
                lock.lock()
                if !lines.isEmpty {
                    let line = lines.removeFirst()
                    lock.unlock()
                    return line
                }
                lock.unlock()
                return nil
            }
        }
    }

    var stderr: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    func closeInput() throws {
        try stdinPipe.fileHandleForWriting.close()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    func stop() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func consumeStdout(_ data: Data) {
        lock.lock()
        stdoutBuffer.append(data)
        var completeLines = 0
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            var line = Data(stdoutBuffer[stdoutBuffer.startIndex..<newline])
            if line.last == 0x0D { line.removeLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            completeLines += 1
        }
        lock.unlock()

        for _ in 0..<completeLines {
            lineAvailable.signal()
        }
    }
}

private func decodeLine(_ line: String) throws -> JSONValue {
    try MCPJSON.decode(Data(line.utf8))
}

// MARK: - Tests

@Suite("End-to-end stdio subprocess")
struct StdioEndToEndTests {
    @Test(
        "initialize, tools/list and tools/call over a real subprocess",
        .enabled(
            if: FrameScriptBinary.locate() != nil,
            "build the executable first: swift build --product framescript"
        )
    )
    func endToEndConversation() throws {
        let binary = try #require(FrameScriptBinary.locate())
        let session = try SubprocessSession(binary: binary)
        defer { session.stop() }

        try session.send(RPC.initialize(id: 1))
        let initializeLine = try #require(
            session.nextLine(timeout: 10),
            "no initialize response; stderr: \(session.stderr)"
        )
        let initialize = try decodeLine(initializeLine)
        #expect(initialize["result"]?["protocolVersion"]?.stringValue == MCPProtocolVersion.latest)
        #expect(initialize["result"]?["capabilities"]?["tools"] != nil)
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "framescript")

        try session.send(RPC.notification("notifications/initialized"))

        try session.send(RPC.request(id: 2, method: "tools/list"))
        let listLine = try #require(
            session.nextLine(timeout: 10),
            "no tools/list response; stderr: \(session.stderr)"
        )
        let list = try decodeLine(listLine)
        let names = list.toolNames
        #expect(names.contains("echo"))
        #expect(names.contains("framescript_version"))
        let echo = try #require(
            list["result"]?["tools"]?.arrayValue?.first { $0["name"]?.stringValue == "echo" }
        )
        #expect(echo["inputSchema"]?["required"]?.arrayValue?.contains(.string("text")) == true)
        #expect(echo["annotations"]?["readOnlyHint"]?.boolValue == true)

        try session.send(RPC.toolsCall(
            id: 3,
            name: "echo",
            arguments: .object([
                "text": .string("hello from a subprocess"),
                "uppercase": .bool(true)
            ])
        ))
        let callLine = try #require(
            session.nextLine(timeout: 10),
            "no tools/call response; stderr: \(session.stderr)"
        )
        let call = try decodeLine(callLine)
        #expect(call["id"]?.intValue == 3)
        #expect(call.resultIsError == false)
        #expect(call.firstTextContent == "HELLO FROM A SUBPROCESS")
        #expect(call.rpcResult?["structuredContent"]?["text"]?.stringValue == "HELLO FROM A SUBPROCESS")

        try session.send(RPC.toolsCall(id: 4, name: "echo", arguments: .object([:])))
        let toolErrorLine = try #require(session.nextLine(timeout: 10))
        let toolError = try decodeLine(toolErrorLine)
        #expect(toolError.resultIsError == true)
        #expect(toolError.firstTextContent?.contains("Missing required argument 'text'") == true)

        try session.send(RPC.toolsCall(id: 5, name: "unknown_tool"))
        let protocolErrorLine = try #require(session.nextLine(timeout: 10))
        let protocolError = try decodeLine(protocolErrorLine)
        #expect(protocolError.errorCode == JSONRPCErrorCode.invalidParams.rawValue)

        try session.send(RPC.request(id: 6, method: "ping"))
        let pingLine = try #require(session.nextLine(timeout: 10))
        let ping = try decodeLine(pingLine)
        #expect(ping["id"]?.intValue == 6)
        #expect(ping.rpcResult?.objectValue?.isEmpty == true)

        try session.closeInput()
        #expect(
            session.waitForExit(timeout: 5),
            "server did not exit after stdin EOF; stderr: \(session.stderr)"
        )
    }

    @Test(
        "--version prints a version and exits zero",
        .enabled(if: FrameScriptBinary.locate() != nil, "build framescript first")
    )
    func versionFlag() throws {
        let binary = try #require(FrameScriptBinary.locate())
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let output = String(decoding: data, as: UTF8.self)
        #expect(output.hasPrefix("framescript "))
        #expect(output.contains("\n"))
    }
}
