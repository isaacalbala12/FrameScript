import Darwin
import Foundation

/// stdio transport: newline-delimited JSON-RPC on the process's standard
/// streams. stdout carries protocol messages only; logging belongs on stderr.
public final class MCPStdioChannel: MCPMessageChannel, @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    private var framer = MCPLineFramer()
    private var pendingLines: [Data] = []
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
                return pendingLines.removeFirst()
            }
            if endOfFile {
                return nil
            }

            let chunk = try await readChunk()
            guard let chunk, !chunk.isEmpty else {
                endOfFile = true
                return framer.flush()
            }

            let lines = framer.append(chunk)
            if !lines.isEmpty {
                pendingLines.append(contentsOf: lines)
                return pendingLines.removeFirst()
            }
        }
    }

    public func send(_ message: Data) async throws {
        guard !message.contains(0x0A), !message.contains(0x0D) else {
            throw MCPTransportError.embeddedNewline
        }
        var line = message
        line.append(0x0A)
        try writeLine(line)
    }

    private func writeLine(_ line: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try output.write(contentsOf: line)
    }

    /// Reads whatever is currently available. `FileHandle.read(upToCount:)`
    /// blocks until the requested count or EOF on a pipe, which would stall an
    /// interactive MCP client, so use a raw `read(2)` instead.
    private func readChunk() async throws -> Data? {
        try await Task.detached(priority: .userInitiated) { [self] in
            let fileDescriptor = self.input.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
                }
                if count > 0 {
                    return Data(buffer[0..<count])
                }
                if count == 0 {
                    return nil
                }
                if errno == EINTR {
                    continue
                }
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(code)
            }
        }.value
    }
}
