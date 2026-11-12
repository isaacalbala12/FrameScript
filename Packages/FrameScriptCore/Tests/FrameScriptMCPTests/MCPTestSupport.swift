import Foundation
import Testing
@testable import FrameScriptMCP

// MARK: - Message builders

enum RPC {
    static func request(id: Int, method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func notification(_ method: String, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method)
        ]
        if let params { object["params"] = params }
        return .object(object)
    }

    static func initialize(
        id: Int = 1,
        version: String = MCPProtocolVersion.latest,
        capabilities: JSONValue = .object([:]),
        clientName: String = "TestClient",
        clientVersion: String = "1.0.0"
    ) -> JSONValue {
        request(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .string(version),
                "capabilities": capabilities,
                "clientInfo": .object([
                    "name": .string(clientName),
                    "version": .string(clientVersion)
                ])
            ])
        )
    }

    static func toolsCall(
        id: Int,
        name: String,
        arguments: JSONValue = .object([:])
    ) -> JSONValue {
        request(
            id: id,
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": arguments
            ])
        )
    }
}

// MARK: - Response helpers

extension JSONValue {
    var rpcResult: JSONValue? { self["result"] }
    var rpcError: JSONValue? { self["error"] }
    var errorCode: Int? { self["error"]?["code"]?.intValue }
    var errorMessage: String? { self["error"]?["message"]?.stringValue }
    var resultIsError: Bool? { self["result"]?["isError"]?.boolValue }

    var firstTextContent: String? {
        guard let content = self["result"]?["content"]?.arrayValue,
              let first = content.first else { return nil }
        return first["text"]?.stringValue
    }

    var toolNames: [String] {
        guard let tools = self["result"]?["tools"]?.arrayValue else { return [] }
        return tools.compactMap { $0["name"]?.stringValue }
    }
}

// MARK: - Harness

final class MCPTestHarness {
    let channel: MCPInMemoryChannel
    let serverTask: Task<Void, Never>

    init(
        registry: MCPToolRegistry,
        supportedVersions: [String] = MCPProtocolVersion.supported,
        shutdownGracePeriod: Duration = .seconds(1)
    ) {
        let channel = MCPInMemoryChannel()
        self.channel = channel
        let configuration = MCPServerConfiguration(
            supportedProtocolVersions: supportedVersions,
            shutdownGracePeriod: shutdownGracePeriod,
            log: MCPLog.disabled
        )
        let server = MCPServer(registry: registry, channel: channel, configuration: configuration)
        self.serverTask = Task { await server.run() }
    }

    func send(_ value: JSONValue) throws {
        try channel.sendJSON(value)
    }

    func sendLine(_ line: String) {
        channel.sendLine(line)
    }

    func nextResponse(timeout: TimeInterval = 2) async throws -> JSONValue {
        let value = try await channel.nextOutboundJSON(timeout: timeout)
        return try #require(value, "timed out waiting for a server response")
    }

    /// Initializes the session. The caller decides whether to send
    /// `notifications/initialized` (a couple of tests assert that it produces
    /// no response).
    func performInitialize(
        version: String = MCPProtocolVersion.latest,
        id: Int = 1
    ) async throws -> JSONValue {
        try send(RPC.initialize(id: id, version: version))
        return try await nextResponse()
    }

    func close() async {
        channel.closeInput()
        await serverTask.value
    }

    func shutdownNow() {
        channel.closeInput()
        serverTask.cancel()
    }
}

@discardableResult
func withHarness<T>(
    _ registry: MCPToolRegistry,
    supportedVersions: [String] = MCPProtocolVersion.supported,
    shutdownGracePeriod: Duration = .seconds(1),
    _ body: (MCPTestHarness) async throws -> T
) async rethrows -> T {
    let harness = MCPTestHarness(
        registry: registry,
        supportedVersions: supportedVersions,
        shutdownGracePeriod: shutdownGracePeriod
    )
    defer { harness.shutdownNow() }
    return try await body(harness)
}

// MARK: - Probes and tools

actor CancellationProbe {
    private var didCancel = false

    func recordCancellation() { didCancel = true }
    func wasCancelled() -> Bool { didCancel }
}

struct BoomError: Error, Sendable {}

enum TestTools {
    static func standard() throws -> MCPToolRegistry {
        try MCPToolRegistry([
            echoTool(),
            MCPTool(
                name: "framescript_version",
                title: "FrameScript version",
                description: "Return a version string.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                    "additionalProperties": .bool(false)
                ]),
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "version": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("version")])
                ]),
                annotations: MCPToolAnnotations(title: "Version", readOnlyHint: true),
                handler: { _ in
                    MCPToolResult.structured(
                        text: "test-version",
                        structuredContent: ["version": .string("test-version")]
                    )
                }
            ),
            MCPTool(
                name: "needs_text",
                description: "Validates its own arguments with the helper API.",
                inputSchema: .object(["type": .string("object")]),
                handler: { arguments in
                    let args = try MCPArguments(arguments)
                    return .text(try args.requiredString("text"))
                }
            ),
            MCPTool(
                name: "fail_generic",
                description: "Throws a plain Swift error.",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in throw BoomError() }
            ),
            MCPTool(
                name: "fail_execution",
                description: "Throws a tool execution error.",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in throw MCPToolError.execution("tool execution failed on purpose") }
            ),
            MCPTool(
                name: "fail_invalid_params",
                description: "Throws a protocol invalid-params error.",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in throw MCPToolError.invalidParams("bad request shape") }
            ),
            MCPTool(
                name: "fail_internal",
                description: "Throws an internal error.",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in throw MCPToolError.internalError("internal boom") }
            ),
            MCPTool(
                name: "bad_output_infinity",
                description: "Returns a non-finite number in structuredContent.",
                inputSchema: .object(["type": .string("object")]),
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "value": .object(["type": .string("number")])
                    ]),
                    "required": .array([.string("value")])
                ]),
                handler: { _ in
                    MCPToolResult(
                        content: [.text("bad")],
                        structuredContent: ["value": .double(.infinity)]
                    )
                }
            ),
            MCPTool(
                name: "bad_output_schema",
                description: "Returns structuredContent that violates outputSchema.",
                inputSchema: .object(["type": .string("object")]),
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "n": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("n")]),
                    "additionalProperties": .bool(false)
                ]),
                handler: { _ in
                    MCPToolResult(
                        content: [.text("bad")],
                        structuredContent: ["n": .string("not-an-integer")]
                    )
                }
            ),
            MCPTool(
                name: "missing_structured",
                description: "Declares outputSchema but omits structuredContent.",
                inputSchema: .object(["type": .string("object")]),
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "n": .object(["type": .string("integer")])
                    ]),
                    "required": .array([.string("n")])
                ]),
                handler: { _ in .text("no structured content") }
            )
        ])
    }

    static func echoTool() -> MCPTool {
        MCPTool(
            name: "echo",
            title: "Echo",
            description: "Echo text back. Optionally uppercase it.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to echo back.")
                    ]),
                    "uppercase": .object([
                        "type": .string("boolean"),
                        "description": .string("Uppercase the echoed text.")
                    ])
                ]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false)
            ]),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")])
                ]),
                "required": .array([.string("text")])
            ]),
            annotations: MCPToolAnnotations(
                title: "Echo",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            handler: { arguments in
                let args = try MCPArguments(arguments)
                let text = try args.requiredString("text")
                let uppercase = try args.optionalBool("uppercase") ?? false
                let output = uppercase ? text.uppercased() : text
                return MCPToolResult.structured(
                    text: output,
                    structuredContent: ["text": .string(output)]
                )
            }
        )
    }

    static func slowTool(
        name: String = "slow",
        duration: Duration = .seconds(5),
        probe: CancellationProbe? = nil
    ) -> MCPTool {
        MCPTool(
            name: name,
            description: "Sleeps for a while, honouring cancellation.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    if let probe { await probe.recordCancellation() }
                    throw error
                }
                return .text("slow finished")
            }
        )
    }

    static func fastTool(name: String = "fast") -> MCPTool {
        MCPTool(
            name: name,
            description: "Returns immediately.",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .text("fast") }
        )
    }
}
