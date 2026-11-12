import Foundation
import FrameScriptCore

public struct MCPServerConfiguration: Sendable {
    public var serverInfo: MCPImplementation
    public var instructions: String?
    /// Newest first. The first entry is used whenever the client requests a
    /// revision this server does not implement.
    public var supportedProtocolVersions: [String]
    /// On stdin EOF the server lets in-flight requests finish for this long
    /// before cancelling them. Bounds shutdown latency for hung tools while
    /// preserving responses for normal pipe workflows.
    public var shutdownGracePeriod: Duration
    public var log: MCPLogHandler

    public init(
        serverInfo: MCPImplementation = MCPImplementation(
            name: "framescript",
            version: FrameScriptCore.version,
            title: "FrameScript",
            description: "FrameScript project tools over the Model Context Protocol"
        ),
        instructions: String? = nil,
        supportedProtocolVersions: [String] = MCPProtocolVersion.supported,
        shutdownGracePeriod: Duration = .seconds(2),
        log: @escaping MCPLogHandler = MCPLog.stderr
    ) {
        self.serverInfo = serverInfo
        self.instructions = instructions
        self.supportedProtocolVersions = supportedProtocolVersions
        self.shutdownGracePeriod = shutdownGracePeriod
        self.log = log
    }
}
