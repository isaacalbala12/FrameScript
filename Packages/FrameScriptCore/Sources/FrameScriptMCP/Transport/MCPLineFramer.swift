import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// MCP's stdio binding requires one JSON-RPC message per line and forbids
/// embedded newlines. A trailing CR (CRLF input) is stripped for robustness.
public struct MCPLineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Appends a chunk and returns every complete line it contains (without
    /// the trailing newline). Empty lines are preserved; the server skips them.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newlineIndex])
            if line.last == 0x0D { line.removeLast() }
            lines.append(line)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }

    /// Returns and clears a final unterminated line at end of stream.
    public mutating func flush() -> Data? {
        guard !buffer.isEmpty else { return nil }
        var line = buffer
        buffer.removeAll(keepingCapacity: false)
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    public var hasBufferedBytes: Bool { !buffer.isEmpty }
}
