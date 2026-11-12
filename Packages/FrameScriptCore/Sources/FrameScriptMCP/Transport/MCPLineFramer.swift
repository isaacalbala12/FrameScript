import Foundation

public enum MCPFramingError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A single JSON-RPC message exceeded the configured limit. This bounds
    /// memory and protects the server from oversized-input denial of service.
    case messageTooLarge(limit: Int)

    public var description: String {
        switch self {
        case .messageTooLarge(let limit):
            return "MCP message exceeds the \(limit)-byte limit"
        }
    }
}

/// Splits a byte stream into newline-delimited messages.
///
/// MCP's stdio binding requires one JSON-RPC message per line and forbids
/// embedded newlines. A trailing CR (CRLF input) is stripped for robustness.
///
/// Scanning is linear: a persistent offset means each appended byte is examined
/// at most once, even when a very long line arrives in many chunks. Consumed
/// bytes are compacted once per append.
public struct MCPLineFramer: Sendable {
    public static let defaultMaximumMessageSize = 8 * 1024 * 1024

    private var buffer = Data()
    /// Offset from `buffer.startIndex` where the next newline search begins.
    private var scanOffset = 0
    /// Offset from `buffer.startIndex` of the first byte not yet emitted.
    private var consumedOffset = 0
    private let maximumMessageSize: Int

    /// Total bytes examined by newline scans. Internal, used by regression
    /// tests to prove the scan is linear rather than quadratic.
    private(set) var scannedByteCount = 0

    public init(maximumMessageSize: Int = MCPLineFramer.defaultMaximumMessageSize) {
        precondition(maximumMessageSize > 0, "maximumMessageSize must be positive")
        self.maximumMessageSize = maximumMessageSize
    }

    /// Appends a chunk and returns every complete line it contains (without
    /// the trailing newline). Empty lines are preserved; the server skips them.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []

        while scanOffset < buffer.count {
            let searchStart = buffer.index(buffer.startIndex, offsetBy: scanOffset)
            guard let newline = buffer[searchStart...].firstIndex(of: 0x0A) else {
                scannedByteCount += buffer.count - scanOffset
                scanOffset = buffer.count
                break
            }

            let newlineOffset = buffer.distance(from: buffer.startIndex, to: newline)
            scannedByteCount += newlineOffset - scanOffset + 1

            let lineLength = newlineOffset - consumedOffset
            if lineLength > maximumMessageSize {
                throw MCPFramingError.messageTooLarge(limit: maximumMessageSize)
            }

            let lineStart = buffer.index(buffer.startIndex, offsetBy: consumedOffset)
            var line = Data(buffer[lineStart..<newline])
            if line.last == 0x0D { line.removeLast() }
            lines.append(line)

            consumedOffset = newlineOffset + 1
            scanOffset = consumedOffset
        }

        if consumedOffset > 0 {
            let tailStart = buffer.index(buffer.startIndex, offsetBy: consumedOffset)
            buffer = Data(buffer[tailStart...])
            scanOffset -= consumedOffset
            consumedOffset = 0
        }

        if buffer.count > maximumMessageSize {
            throw MCPFramingError.messageTooLarge(limit: maximumMessageSize)
        }
        return lines
    }

    /// Returns and clears a final unterminated line at end of stream.
    public mutating func flush() throws -> Data? {
        guard !buffer.isEmpty else { return nil }
        if buffer.count > maximumMessageSize {
            throw MCPFramingError.messageTooLarge(limit: maximumMessageSize)
        }
        var line = buffer
        buffer.removeAll(keepingCapacity: false)
        scanOffset = 0
        consumedOffset = 0
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }
}
