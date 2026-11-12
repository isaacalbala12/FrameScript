import Foundation

/// A log sink. The stdio transport reserves stdout for protocol messages, so
/// every default sink writes to stderr.
public typealias MCPLogHandler = @Sendable (String) -> Void

public enum MCPLog {
    private static let stderrLock = NSLock()

    /// Writes a single line to stderr. stdout is never touched.
    public static let stderr: MCPLogHandler = { message in
        let data = Data(("framescript-mcp: \(message)\n").utf8)
        stderrLock.lock()
        defer { stderrLock.unlock() }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    /// For tests and embedders that do not want stderr noise.
    public static let disabled: MCPLogHandler = { _ in }
}
