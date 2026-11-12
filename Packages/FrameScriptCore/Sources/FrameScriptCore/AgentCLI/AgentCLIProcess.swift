import Darwin
import Dispatch
import Foundation

/// Where the bounded output buffer keeps bytes when a stream exceeds its cap.
///
/// JSON documents and JSONL streams put the useful final line at the end, so
/// stdout defaults to `.keepTail`. Stderr diagnostics usually start with the
/// useful line, so it defaults to `.keepHead`.
public enum AgentOutputTruncation: String, Sendable, Equatable, Codable {
    case keepHead
    case keepTail
}

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
    public var standardOutputTruncation: AgentOutputTruncation
    public var standardErrorTruncation: AgentOutputTruncation

    public init(
        executableURL: URL,
        arguments: [String] = [],
        standardInput: Data = Data(),
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval? = 180,
        outputByteLimit: Int = 8 * 1024 * 1024,
        standardOutputTruncation: AgentOutputTruncation = .keepTail,
        standardErrorTruncation: AgentOutputTruncation = .keepHead
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
        self.standardOutputTruncation = standardOutputTruncation
        self.standardErrorTruncation = standardErrorTruncation
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

/// Keeps at most `limit` bytes of a stream. The truncation mode decides whether
/// the head or the tail survives; either way the rest is drained and discarded.
public struct BoundedOutputBuffer: Sendable, Equatable {
    public let limit: Int
    public let truncation: AgentOutputTruncation
    public private(set) var data: Data
    public private(set) var isTruncated: Bool

    public init(limit: Int, truncation: AgentOutputTruncation = .keepHead) {
        self.limit = max(0, limit)
        self.truncation = truncation
        self.data = Data()
        self.isTruncated = false
    }

    public mutating func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        guard limit > 0 else {
            isTruncated = true
            return
        }

        switch truncation {
        case .keepHead:
            let remaining = limit - data.count
            if remaining > 0 {
                data.append(contentsOf: chunk.prefix(remaining))
            }
            if chunk.count > max(0, remaining) {
                isTruncated = true
            }

        case .keepTail:
            if chunk.count >= limit {
                if data.count + chunk.count > limit {
                    isTruncated = true
                }
                data = Data(chunk.suffix(limit))
                return
            }
            let overflow = data.count + chunk.count - limit
            if overflow > 0 {
                data.removeFirst(overflow)
                isTruncated = true
            }
            data.append(chunk)
        }
    }
}

/// Runs a real child process with stdin, bounded stdout/stderr capture, a
/// timeout and cooperative cancellation.
///
/// The child is spawned with `posix_spawn` in its own process group, so a
/// timeout or cancellation sends `SIGTERM` to the whole group and `SIGKILL`
/// to the group two seconds later. Pipe reads use `DispatchIO` and waits use a
/// dedicated thread: no blocking work ever runs on Swift's cooperative pool.
public struct SystemAgentProcessLauncher: AgentProcessLaunching {
    /// How long a normal exit may take to finish draining pipes before the
    /// remaining process group is terminated and the output is marked as
    /// truncated.
    private static let drainGrace: TimeInterval = 2

    public init() {}

    public func launch(_ request: AgentProcessRequest) async throws -> AgentProcessOutput {
        let startedAt = Date()
        let pipes = try ProcessPipes()
        var spawned = false
        defer {
            if !spawned {
                pipes.closeAll()
            }
        }

        let pid = try Self.spawn(
            request,
            stdinFD: pipes.stdinRead,
            stdoutFD: pipes.stdoutWrite,
            stderrFD: pipes.stderrWrite
        )
        spawned = true
        pipes.closeChildEnds()

        let stdout = StreamCapture(
            fileDescriptor: pipes.stdoutRead,
            limit: request.outputByteLimit,
            truncation: request.standardOutputTruncation,
            name: "stdout"
        )
        let stderr = StreamCapture(
            fileDescriptor: pipes.stderrRead,
            limit: request.outputByteLimit,
            truncation: request.standardErrorTruncation,
            name: "stderr"
        )
        let stdin = StdinWriter(fileDescriptor: pipes.stdinWrite)
        let outcome = AsyncOneShot<ProcessWaitOutcome>()
        let controller = ProcessGroupController(pid: pid)

        stdout.start()
        stderr.start()
        stdin.start(request.standardInput)
        ProcessReaper(pid: pid) { code in
            outcome.resolve(.exited(code))
        }.start()

        let timeoutTask = Self.startTimeout(
            request.timeout,
            controller: controller,
            outcome: outcome
        )

        return try await withTaskCancellationHandler {
            let waitOutcome = await outcome.wait()
            timeoutTask?.cancel()

            switch waitOutcome {
            case .cancelled:
                stdout.cancel()
                stderr.cancel()
                throw AgentCLIError.cancelled

            case .timedOut:
                stdout.cancel()
                stderr.cancel()
                throw AgentCLIError.timedOut(seconds: request.timeout ?? 0)

            case let .exited(code):
                if Task.isCancelled {
                    controller.terminate()
                    stdout.cancel()
                    stderr.cancel()
                    throw AgentCLIError.cancelled
                }

                // The direct child is gone. A background grandchild may still
                // hold the pipes, so the drain is bounded and the group is
                // terminated if it does not finish in time.
                // The drain shares one deadline and never extends past the
                // request timeout, so a background grandchild holding a pipe
                // cannot keep the caller waiting.
                var drainDeadline = Date().addingTimeInterval(Self.drainGrace)
                if let timeout = request.timeout, timeout > 0 {
                    let requestDeadline = startedAt.addingTimeInterval(timeout)
                    drainDeadline = min(drainDeadline, requestDeadline)
                }
                let capturedStdout = await Self.capture(
                    stdout,
                    boundedBy: max(0, drainDeadline.timeIntervalSinceNow)
                )
                let capturedStderr = await Self.capture(
                    stderr,
                    boundedBy: max(0, drainDeadline.timeIntervalSinceNow)
                )
                if Task.isCancelled {
                    controller.terminate()
                    throw AgentCLIError.cancelled
                }
                let stdinFinished = await Self.waitForStdin(stdin)
                if !capturedStdout.finished || !capturedStderr.finished || !stdinFinished {
                    controller.terminate()
                }
                if Task.isCancelled {
                    controller.terminate()
                    throw AgentCLIError.cancelled
                }

                return AgentProcessOutput(
                    standardOutput: capturedStdout.data,
                    standardError: capturedStderr.data,
                    exitCode: code,
                    standardOutputTruncated: capturedStdout.isTruncated,
                    standardErrorTruncated: capturedStderr.isTruncated
                )
            }
        } onCancel: {
            controller.terminate()
            outcome.resolve(.cancelled)
            // Also abort a drain that already started after the child exited.
            stdout.cancel()
            stderr.cancel()
        }
    }

    // MARK: - Spawn

    private static func spawn(
        _ request: AgentProcessRequest,
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw AgentCLIError.launchFailed("Could not initialise posix_spawn file actions.")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AgentCLIError.launchFailed("Could not initialise posix_spawn attributes.")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        guard posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO) == 0
        else {
            throw AgentCLIError.launchFailed("Could not configure the child's standard streams.")
        }
        for descriptor in [stdinFD, stdoutFD, stderrFD] where descriptor > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, descriptor)
        }
        if let directory = request.currentDirectoryURL {
            addChdir(&actions, directory.path)
        }

        // POSIX_SPAWN_SETPGROUP with pgroup 0 makes the child a new process
        // group leader whose pgid is its pid. kill(-pid) then reaches every
        // descendant that did not create its own session.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw AgentCLIError.launchFailed("Could not create a process group for the child.")
        }

        let environment = ProcessInfo.processInfo.environment
            .merging(request.environment ?? [:]) { _, new in new }
        let argv = [request.executableURL.path] + request.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let result = withSpawnArguments(argv) { argvPointer in
            withSpawnArguments(envp) { envPointer in
                posix_spawn(
                    &pid,
                    request.executableURL.path,
                    &actions,
                    &attributes,
                    argvPointer,
                    envPointer
                )
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(result))
            throw AgentCLIError.launchFailed(
                "Could not launch \(request.executableURL.path): \(reason)"
            )
        }
        return pid
    }

    private static func withSpawnArguments<R>(
        _ arguments: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers = arguments.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    @available(macOS, deprecated: 26.0, message: "Pre-macOS 26 chdir shim")
    private static func addChdirFallback(
        _ actions: inout posix_spawn_file_actions_t?,
        _ path: String
    ) {
        posix_spawn_file_actions_addchdir_np(&actions, path)
    }

    private static func addChdir(
        _ actions: inout posix_spawn_file_actions_t?,
        _ path: String
    ) {
        if #available(macOS 26.0, *) {
            posix_spawn_file_actions_addchdir(&actions, path)
        } else {
            addChdirFallback(&actions, path)
        }
    }

    // MARK: - Deadlines

    private static func startTimeout(
        _ timeout: TimeInterval?,
        controller: ProcessGroupController,
        outcome: AsyncOneShot<ProcessWaitOutcome>
    ) -> Task<Void, Never>? {
        guard let timeout, timeout > 0 else { return nil }
        return Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            controller.terminate()
            outcome.resolve(.timedOut)
        }
    }

    private static func waitForStdin(_ writer: StdinWriter) async -> Bool {
        let box = AsyncOneShot<Bool>()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1)
        timer.setEventHandler {
            box.resolve(false)
        }
        timer.resume()
        Task.detached(priority: .userInitiated) {
            await writer.wait()
            box.resolve(true)
        }
        let result = await box.wait()
        timer.setEventHandler {}
        timer.cancel()
        return result
    }

    private static func capture(
        _ capture: StreamCapture,
        boundedBy seconds: TimeInterval
    ) async -> CaptureSnapshot {
        let box = AsyncOneShot<CaptureSnapshot>()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler {
            // Snapshot at deadline time, not before the wait starts: a small
            // amount of output may arrive while the timer is being armed.
            box.resolve(capture.partialSnapshot)
        }
        timer.resume()

        Task.detached(priority: .userInitiated) {
            box.resolve(await capture.wait())
        }

        let result = await box.wait()
        timer.setEventHandler {}
        timer.cancel()
        if !result.finished {
            capture.cancel()
        }
        return result
    }
}

// MARK: - Process groups

private enum ProcessWaitOutcome: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}

/// Terminates the direct child and every descendant sharing its process group.
private final class ProcessGroupController: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var terminationRequested = false

    init(pid: pid_t) {
        self.pid = pid
    }

    func terminate() {
        lock.lock()
        if terminationRequested {
            lock.unlock()
            return
        }
        terminationRequested = true
        lock.unlock()

        let groupID = pid
        kill(-groupID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
            kill(-groupID, SIGKILL)
        }
    }
}

/// Reaps the child on a dedicated thread so the cooperative pool never blocks.
private final class ProcessReaper: @unchecked Sendable {
    private let pid: pid_t
    private let onExit: @Sendable (Int32) -> Void

    init(pid: pid_t, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        self.onExit = onExit
    }

    func start() {
        let thread = Thread { [pid, onExit] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR

            let code = Self.exitCode(fromWaitStatus: status, reaped: result == pid)
            onExit(code)
        }
        thread.name = "FrameScript.AgentCLI.wait"
        thread.start()
    }

    /// Darwin's status macros are not imported into Swift, so decode the wait
    /// status explicitly.
    private static func exitCode(fromWaitStatus status: Int32, reaped: Bool) -> Int32 {
        guard reaped else { return -1 }
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        if signal == 0x7f {
            return -1
        }
        return 128 + signal
    }
}

// MARK: - Pipes

private struct ProcessPipes {
    let stdinRead: Int32
    let stdinWrite: Int32
    let stdoutRead: Int32
    let stdoutWrite: Int32
    let stderrRead: Int32
    let stderrWrite: Int32

    init() throws {
        let stdin = try Self.makePipe()
        do {
            let stdout = try Self.makePipe()
            do {
                let stderr = try Self.makePipe()
                stdinRead = stdin.read
                stdinWrite = stdin.write
                stdoutRead = stdout.read
                stdoutWrite = stdout.write
                stderrRead = stderr.read
                stderrWrite = stderr.write
            } catch {
                close(stdout.read)
                close(stdout.write)
                throw error
            }
        } catch {
            close(stdin.read)
            close(stdin.write)
            throw error
        }
    }

    func closeChildEnds() {
        close(stdinRead)
        close(stdoutWrite)
        close(stderrWrite)
    }

    func closeAll() {
        close(stdinRead)
        close(stdinWrite)
        close(stdoutRead)
        close(stdoutWrite)
        close(stderrRead)
        close(stderrWrite)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw AgentCLIError.launchFailed(
                "Could not create a pipe: \(String(cString: strerror(errno)))"
            )
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (descriptors[0], descriptors[1])
    }
}

// MARK: - Stream capture

private struct CaptureSnapshot: Sendable, Equatable {
    var data: Data
    var isTruncated: Bool
    var finished: Bool
}

/// Reads a pipe with `DispatchIO`: the only work on a Dispatch queue is a
/// non-blocking read, so the cooperative pool is never occupied by pipe I/O.
private final class StreamCapture: @unchecked Sendable {
    private let io: DispatchIO
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var buffer: BoundedOutputBuffer
    private var finished = false
    private let completion = AsyncOneShot<CaptureSnapshot>()

    init(
        fileDescriptor: Int32,
        limit: Int,
        truncation: AgentOutputTruncation,
        name: String
    ) {
        queue = DispatchQueue(label: "FrameScript.AgentCLI.\(name).\(UUID().uuidString)")
        buffer = BoundedOutputBuffer(limit: limit, truncation: truncation)
        io = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in }
        io.setLimit(lowWater: 1)
        io.setLimit(highWater: 1024 * 1024)
    }

    func start() {
        readNext()
    }

    func wait() async -> CaptureSnapshot {
        await completion.wait()
    }

    var partialSnapshot: CaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureSnapshot(data: buffer.data, isTruncated: true, finished: false)
    }

    func cancel() {
        finish()
    }

    private func readNext() {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { return }

        io.read(offset: 0, length: 64 * 1024, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.append(Data(data))
            }
            if error != 0 {
                self.finish()
                return
            }
            // A stream read may deliver several callbacks for one operation.
            // `done` means that operation finished, not that the pipe closed;
            // only an empty final buffer is EOF.
            if done {
                if data?.isEmpty ?? true {
                    self.finish()
                } else {
                    self.readNext()
                }
            }
        }
    }

    private func append(_ data: Data) {
        lock.lock()
        if !finished {
            buffer.append(data)
        }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let snapshot = CaptureSnapshot(
            data: buffer.data,
            isTruncated: buffer.isTruncated,
            finished: true
        )
        lock.unlock()
        io.close()
        completion.resolve(snapshot)
    }
}

/// Writes the prompt on a dedicated thread, then closes stdin. A thread is
/// used instead of `DispatchIO.write` because the latter is not available for
/// every pipe state, while a dedicated writer still keeps blocking I/O off the
/// cooperative pool.
private final class StdinWriter: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let completion = AsyncOneShot<Void>()

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        // A child can exit before reading its prompt; without this the writer
        // would receive SIGPIPE and terminate the host app.
        var noSignal: Int32 = 1
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, &noSignal)
    }

    func start(_ data: Data) {
        let descriptor = fileDescriptor
        let completion = completion
        let thread = Thread {
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = write(
                        descriptor,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if written > 0 {
                        offset += written
                    } else if written == -1 && errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
            }
            close(descriptor)
            completion.resolve(())
        }
        thread.name = "FrameScript.AgentCLI.stdin"
        thread.start()
    }

    func wait() async {
        await completion.wait()
    }
}

// MARK: - Async one-shot

/// A small Sendable one-shot continuation used to race independent callbacks.
private final class AsyncOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var value: Value?
    private var resolved = false

    func resolve(_ value: Value) {
        lock.lock()
        if resolved {
            lock.unlock()
            return
        }
        resolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.value = value
            lock.unlock()
        }
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if resolved, let value {
                lock.unlock()
                continuation.resume(returning: value)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
