import Darwin
import Foundation

/// stdio transport: newline-delimited JSON-RPC on the process's standard
/// streams. stdout carries protocol messages only; logging belongs on stderr.
///
/// The channel is an actor so the framer, pending lines and end-of-file state
/// are serialized. Reads use `poll(2)` with a short timeout so task
/// cancellation stops the reader instead of leaving a detached thread blocked
/// on the pipe until EOF.
public actor MCPStdioChannel: MCPMessageChannel {
    private let input: FileHandle
    private let output: FileHandle
    private var framer = MCPLineFramer()
    private var pendingLines: [Data] = []
    private var pendingFramingError: MCPFramingError?
    private var endOfFile = false

    public init(
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.input = input
        self.output = output
    }

    public func receive() async throws -> Data? {
        while true {
            if !pendingLines.isEmpty {
                // Lines framed before an oversized chunk are delivered first;
                // the stored framing error is thrown once they are drained.
                return pendingLines.removeFirst()
            }
            if let error = pendingFramingError {
                pendingFramingError = nil
                throw error
            }
            if endOfFile {
                return nil
            }

            let chunk = try await readChunk()
            guard let chunk, !chunk.isEmpty else {
                endOfFile = true
                let finalLine = try framer.flush()
                if let finalLine {
                    pendingLines.append(finalLine)
                    continue
                }
                return nil
            }

            var lines: [Data] = []
            do {
                try framer.append(chunk, framedLines: &lines)
            } catch let error as MCPFramingError {
                pendingLines.append(contentsOf: lines)
                pendingFramingError = error
                if pendingLines.isEmpty { throw error }
                continue
            }
            pendingLines.append(contentsOf: lines)
        }
    }

    public func send(_ message: Data) async throws {
        guard !message.contains(0x0A), !message.contains(0x0D) else {
            throw MCPTransportError.embeddedNewline
        }
        var line = message
        line.append(0x0A)
        try output.write(contentsOf: line)
    }

    /// Reads whatever is currently available. `FileHandle.read(upToCount:)`
    /// blocks until the requested count or EOF on a pipe, which would stall an
    /// interactive MCP client, so poll the descriptor and use `read(2)`.
    private func readChunk() async throws -> Data? {
        let cancellation = ReadCancellation()
        let fileDescriptor = input.fileDescriptor
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    if cancellation.isCancelled {
                        throw CancellationError()
                    }

                    var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&descriptor, 1, 100)
                    if ready == 0 { continue }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }

                    let count = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if count > 0 {
                        return Data(buffer[0..<count])
                    }
                    if count == 0 {
                        return nil
                    }
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class ReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
