import Foundation

/// A single child process invocation.
public struct AgentProcessRequest: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    /// Written to the child's stdin, then stdin is closed.
    public var standardInput: Data
    /// Extra environment variables layered over the inherited environment.
    /// `nil` inherits the current environment unchanged.
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    /// `nil` or a non-positive value means "no timeout".
    public var timeout: TimeInterval?
    /// Per-stream capture cap in bytes.
    public var outputByteLimit: Int

    public init(
        executableURL: URL,
        arguments: [String] = [],
        standardInput: Data = Data(),
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = 180,
        outputByteLimit: Int = 1_048_576
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }
}

/// Captured process result. Text accessors decode invalid UTF-8 lossily.
public struct AgentProcessOutput: Sendable, Equatable {
    public var standardOutput: Data
    public var standardError: Data
    public var exitCode: Int32
    public var standardOutputTruncated: Bool
    public var standardErrorTruncated: Bool

    public init(
        standardOutput: Data,
        standardError: Data,
        exitCode: Int32,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }

    public var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }

    /// Trimmed stderr, suitable for an error message.
    public var standardErrorSummary: String {
        standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// The seam used by every runner. Tests replace it with a deterministic fake.
public protocol AgentProcessLaunching: Sendable {
    func launch(_ request: AgentProcessRequest) async throws -> AgentProcessOutput
}

/// Keeps the first `limit` bytes of a stream and drains the rest.
public struct BoundedOutputBuffer: Sendable, Equatable {
    public let limit: Int
    public private(set) var data: Data
    public private(set) var isTruncated: Bool

    public init(limit: Int) {
        self.limit = max(0, limit)
        self.data = Data()
        self.isTruncated = false
    }

    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let remaining = limit - data.count
        if remaining > 0 {
            data.append(contentsOf: chunk.prefix(remaining))
        }
        if chunk.count > max(0, remaining) {
            isTruncated = true
        }
    }
}

/// Runs a real child process with stdin, bounded stdout/stderr capture, a
/// timeout and cooperative cancellation.
///
/// Cancelling the Swift task sends `SIGTERM`. If the child is still alive two
/// seconds later it is sent `SIGKILL`. A timeout escalates the same way.
public struct SystemAgentProcessLauncher: AgentProcessLaunching {
    public init() {}

    public func launch(_ request: AgentProcessRequest) async throws -> AgentProcessOutput {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        if let directory = request.currentDirectoryURL {
            process.currentDirectoryURL = directory
        }
        if let overrides = request.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(overrides) { _, new in new }
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let controller = ChildProcessController(process: process)

        do {
            try process.run()
        } catch {
            throw AgentCLIError.launchFailed(error.localizedDescription)
        }

        let stdoutReader = Self.read(
            stdoutPipe.fileHandleForReading,
            limit: request.outputByteLimit
        )
        let stderrReader = Self.read(
            stderrPipe.fileHandleForReading,
            limit: request.outputByteLimit
        )
        let stdinWriter = Self.write(request.standardInput, to: stdinPipe.fileHandleForWriting)

        return try await withTaskCancellationHandler {
            let timeout = request.timeout
            let deadline = timeout.flatMap { $0 > 0 ? ContinuousClock.now + .seconds($0) : nil }

            while process.isRunning {
                if Task.isCancelled {
                    controller.terminate()
                    _ = await Self.waitForExit(process, upTo: 3)
                    throw AgentCLIError.cancelled
                }
                if let deadline, ContinuousClock.now >= deadline {
                    controller.terminate()
                    _ = await Self.waitForExit(process, upTo: 3)
                    // Do not await the detached readers here: a child that
                    // ignores SIGTERM must not keep the caller blocked.
                    throw AgentCLIError.timedOut(seconds: timeout ?? 0)
                }
                try? await Task.sleep(for: .milliseconds(20))
            }

            // The readers see EOF when the child and any descendants close the
            // write ends; awaiting them here preserves output ordering.
            let stdout = await stdoutReader.value
            let stderr = await stderrReader.value
            await stdinWriter.value

            return AgentProcessOutput(
                standardOutput: stdout.data,
                standardError: stderr.data,
                exitCode: process.terminationStatus,
                standardOutputTruncated: stdout.isTruncated,
                standardErrorTruncated: stderr.isTruncated
            )
        } onCancel: {
            controller.terminate()
        }
    }

    private static func waitForExit(_ process: Process, upTo seconds: TimeInterval) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0, seconds))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !process.isRunning
    }

    private static func read(_ handle: FileHandle, limit: Int) -> Task<BoundedOutputBuffer, Never> {
        let box = SendableFileHandle(handle: handle)
        return Task.detached(priority: .userInitiated) {
            var buffer = BoundedOutputBuffer(limit: limit)
            while true {
                let chunk: Data?
                do {
                    chunk = try box.handle.read(upToCount: 64 * 1024)
                } catch {
                    break
                }
                guard let chunk, !chunk.isEmpty else { break }
                buffer.append(chunk)
            }
            try? box.handle.close()
            return buffer
        }
    }

    private static func write(_ data: Data, to handle: FileHandle) -> Task<Void, Never> {
        let box = SendableFileHandle(handle: handle)
        // Without this, a child that exits before reading its prompt makes the
        // writer raise SIGPIPE, which would terminate FrameScript itself.
        var noSignal: Int32 = 1
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, &noSignal)
        return Task.detached(priority: .userInitiated) {
            if !data.isEmpty {
                try? box.handle.write(contentsOf: data)
            }
            try? box.handle.close()
        }
    }
}

/// `FileHandle` is thread-safe for the blocking read/write loop above but is
/// not marked `Sendable` on every SDK FrameScript builds against.
private struct SendableFileHandle: @unchecked Sendable {
    let handle: FileHandle
}

/// Owns the `Process` across the cancellation handler and the async wait loop.
private final class ChildProcessController: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminationRequested = false

    init(process: Process) {
        self.process = process
    }

    /// `SIGTERM` now, `SIGKILL` after a two second grace period.
    func terminate() {
        lock.lock()
        if terminationRequested {
            lock.unlock()
            return
        }
        terminationRequested = true
        lock.unlock()

        if process.isRunning {
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.forceKillIfRunning()
        }
    }

    private func forceKillIfRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
