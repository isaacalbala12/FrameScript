import Foundation

/// Behavioural hints for a tool. Clients must treat these as untrusted unless
/// the server is trusted (MCP security guidance).
public struct MCPToolAnnotations: Sendable, Equatable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let title { object["title"] = .string(title) }
        if let readOnlyHint { object["readOnlyHint"] = .bool(readOnlyHint) }
        if let destructiveHint { object["destructiveHint"] = .bool(destructiveHint) }
        if let idempotentHint { object["idempotentHint"] = .bool(idempotentHint) }
        if let openWorldHint { object["openWorldHint"] = .bool(openWorldHint) }
        return .object(object)
    }
}

/// A single item in a tool result's `content` array. Only text is needed for
/// the protocol foundation; more content kinds can be added later.
public enum MCPToolContent: Sendable, Equatable {
    case text(String)

    public var jsonValue: JSONValue {
        switch self {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text)
            ])
        }
    }
}

/// The result of a successful `tools/call` transport-wise. `isError == true`
/// represents a *tool execution error*, which is deliberately different from a
/// JSON-RPC protocol error.
public struct MCPToolResult: Sendable, Equatable {
    public var content: [MCPToolContent]
    public var isError: Bool
    /// Structured results are objects by definition. Tools with an
    /// `outputSchema` must provide one when the call succeeds; the server
    /// validates it before writing the response.
    public var structuredContent: [String: JSONValue]?

    public init(
        content: [MCPToolContent],
        isError: Bool = false,
        structuredContent: [String: JSONValue]? = nil
    ) {
        self.content = content
        self.isError = isError
        self.structuredContent = structuredContent
    }

    public static func text(_ text: String, isError: Bool = false) -> MCPToolResult {
        MCPToolResult(content: [.text(text)], isError: isError)
    }

    /// Builds a result with human-readable text plus the serialized JSON as a
    /// second text block, as MCP recommends for structured results.
    public static func structured(
        text: String,
        structuredContent: [String: JSONValue],
        isError: Bool = false
    ) -> MCPToolResult {
        var content: [MCPToolContent] = [.text(text)]
        if let data = try? MCPJSON.encode(.object(structuredContent)),
           let serialized = String(data: data, encoding: .utf8),
           serialized != text {
            content.append(.text(serialized))
        }
        return MCPToolResult(
            content: content,
            isError: isError,
            structuredContent: structuredContent
        )
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "content": .array(content.map(\.jsonValue)),
            "isError": .bool(isError)
        ]
        if let structuredContent { object["structuredContent"] = .object(structuredContent) }
        return .object(object)
    }
}

public typealias MCPToolHandler = @Sendable (JSONValue) async throws -> MCPToolResult

/// A tool exposed through `tools/list` and invoked through `tools/call`.
public struct MCPTool: Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let inputSchema: JSONValue
    public let outputSchema: JSONValue?
    public let annotations: MCPToolAnnotations?
    public let handler: MCPToolHandler

    public init(
        name: String,
        title: String? = nil,
        description: String? = nil,
        inputSchema: JSONValue,
        outputSchema: JSONValue? = nil,
        annotations: MCPToolAnnotations? = nil,
        handler: @escaping MCPToolHandler
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
        self.handler = handler
    }

    /// The JSON object returned by `tools/list`. `inputSchema` is mandatory
    /// and MUST be a JSON Schema object (never null).
    public var definition: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "inputSchema": inputSchema
        ]
        if let title { object["title"] = .string(title) }
        if let description { object["description"] = .string(description) }
        if let outputSchema { object["outputSchema"] = outputSchema }
        if let annotations { object["annotations"] = annotations.jsonValue }
        return .object(object)
    }
}

/// Errors a tool can throw to choose a specific reporting channel.
public enum MCPToolError: Error, Sendable, Equatable {
    /// A tool execution error: returned to the model with `isError: true`.
    case execution(String)
    /// A malformed request: returned as JSON-RPC -32602.
    case invalidParams(String)
    /// A server-side failure: returned as JSON-RPC -32603.
    case internalError(String)
}

extension MCPToolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .execution(let message), .invalidParams(let message), .internalError(let message):
            return message
        }
    }
}
