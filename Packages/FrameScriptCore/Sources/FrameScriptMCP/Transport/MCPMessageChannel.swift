import Foundation

public enum MCPTransportError: Error, Sendable, Equatable {
    /// A stdio message contained a raw newline and cannot be framed.
    case embeddedNewline
    /// The channel was used after being closed.
    case closed
}

/// Byte-oriented, bidirectional message channel. The stdio channel uses the
/// process streams; tests use the in-memory channel.
///
/// Implementations must deliver messages intact (one JSON document per
/// message) and serialize concurrent writes.
public protocol MCPMessageChannel: Sendable {
    /// Returns the next message, or `nil` at end of input.
    func receive() async throws -> Data?
    /// Writes one message. Implementations must not add framing beyond a
    /// single trailing newline.
    func send(_ message: Data) async throws
}
