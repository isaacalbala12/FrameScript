import Foundation

/// `serverInfo` / `clientInfo` payload from the MCP schema.
public struct MCPImplementation: Sendable, Equatable {
    public var name: String
    public var title: String?
    public var version: String
    public var description: String?

    public init(
        name: String,
        version: String,
        title: String? = nil,
        description: String? = nil
    ) {
        self.name = name
        self.version = version
        self.title = title
        self.description = description
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "version": .string(version)
        ]
        if let title { object["title"] = .string(title) }
        if let description { object["description"] = .string(description) }
        return .object(object)
    }
}

/// Protocol errors raised by the server before/around a tool execution.
/// Tool execution failures use `MCPToolResult.isError` instead.
enum MCPProtocolError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)

    var code: JSONRPCErrorCode {
        switch self {
        case .invalidRequest: return .invalidRequest
        case .methodNotFound: return .methodNotFound
        case .invalidParams: return .invalidParams
        case .internalError: return .internalError
        }
    }

    var message: String {
        switch self {
        case .invalidRequest(let message),
             .methodNotFound(let message),
             .invalidParams(let message),
             .internalError(let message):
            return message
        }
    }

    var errorObject: JSONRPCErrorObject {
        JSONRPCErrorObject(code: code, message: message)
    }
}
