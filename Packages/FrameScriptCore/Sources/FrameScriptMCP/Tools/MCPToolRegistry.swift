import Foundation

public enum MCPToolDefinitionError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case invalidName(tool: String)
    case invalidInputSchema(tool: String, reason: String)
    case invalidOutputSchema(tool: String, reason: String)

    public var description: String {
        switch self {
        case .invalidName(let tool):
            return "Tool '\(tool)' has an invalid name: names must not be empty"
        case .invalidInputSchema(let tool, let reason):
            return "Tool '\(tool)' has an invalid inputSchema: \(reason)"
        case .invalidOutputSchema(let tool, let reason):
            return "Tool '\(tool)' has an invalid outputSchema: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

/// An immutable, ordered collection of tools. The first registration of a name
/// wins; duplicates are ignored. Declaration order is preserved in
/// `tools/list`.
///
/// Registration validates every `inputSchema` and `outputSchema` as an object
/// schema with `"type": "object"`, so the server can never advertise a
/// malformed schema.
public struct MCPToolRegistry: Sendable {
    private let ordered: [MCPTool]
    private let byName: [String: MCPTool]

    public init() {
        self.ordered = []
        self.byName = [:]
    }

    public init(_ tools: [MCPTool]) throws {
        var ordered: [MCPTool] = []
        var byName: [String: MCPTool] = [:]

        for tool in tools {
            try Self.validate(tool)
            if byName[tool.name] == nil {
                ordered.append(tool)
                byName[tool.name] = tool
            }
        }

        self.ordered = ordered
        self.byName = byName
    }

    public var tools: [MCPTool] { ordered }

    public var definitions: [JSONValue] { ordered.map(\.definition) }

    public func tool(named name: String) -> MCPTool? {
        byName[name]
    }

    public var count: Int { ordered.count }

    public static let empty = MCPToolRegistry()

    private enum SchemaKind {
        case input
        case output

        var label: String {
            switch self {
            case .input: return "inputSchema"
            case .output: return "outputSchema"
            }
        }
    }

    private static func validate(_ tool: MCPTool) throws {
        guard !tool.name.isEmpty else {
            throw MCPToolDefinitionError.invalidName(tool: tool.name)
        }
        try validateSchema(tool.inputSchema, tool: tool, kind: .input)
        if let outputSchema = tool.outputSchema {
            try validateSchema(outputSchema, tool: tool, kind: .output)
        }
    }

    private static func validateSchema(
        _ schema: JSONValue,
        tool: MCPTool,
        kind: SchemaKind
    ) throws {
        do {
            try JSONSchemaValidator.validateSchema(schema, context: kind.label)
            guard schema["type"]?.stringValue == "object" else {
                throw JSONSchemaValidationError(
                    path: kind.label,
                    message: "type must be \"object\" for a tool schema"
                )
            }
        } catch {
            switch kind {
            case .input:
                throw MCPToolDefinitionError.invalidInputSchema(
                    tool: tool.name,
                    reason: String(describing: error)
                )
            case .output:
                throw MCPToolDefinitionError.invalidOutputSchema(
                    tool: tool.name,
                    reason: String(describing: error)
                )
            }
        }
    }
}
