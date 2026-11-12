import Foundation

public enum MCPJSONError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case nonFiniteNumber(path: String)

    public var description: String {
        switch self {
        case .nonFiniteNumber(let path):
            return "JSON cannot encode a non-finite number at \(path)"
        }
    }

    public var errorDescription: String? { description }
}

/// JSON coding shared by the MCP transports and the server.
public enum MCPJSON {
    /// Compact, deterministic JSON. No pretty printing: the stdio transport is
    /// newline-delimited and a message must not contain embedded newlines.
    public static func encode(_ value: JSONValue) throws -> Data {
        if let path = value.nonFiniteNumberPath {
            throw MCPJSONError.nonFiniteNumber(path: path.isEmpty ? "<root>" : path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encodes a single stdio message, including its trailing newline.
    public static func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try encode(value)
        precondition(!data.contains(0x0A), "encoded MCP message must not contain a raw newline")
        precondition(!data.contains(0x0D), "encoded MCP message must not contain a raw carriage return")
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ line: Data) throws -> JSONValue {
        try decode(line)
    }
}
