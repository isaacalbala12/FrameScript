import Foundation

/// A JSON-RPC 2.0 request id. MCP restricts ids to strings or integers and
/// explicitly forbids `null`.
public enum JSONRPCID: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)

    public init?(jsonValue: JSONValue) {
        switch jsonValue {
        case .string(let value): self = .string(value)
        case .int(let value): self = .int(value)
        default: return nil
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSON-RPC id must be a string or integer"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

extension JSONRPCID: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        }
    }
}

/// The `error` member of a JSON-RPC error response.
public struct JSONRPCErrorObject: Sendable, Equatable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(code: JSONRPCErrorCode, message: String? = nil, data: JSONValue? = nil) {
        self.init(code: code.rawValue, message: message ?? code.defaultMessage, data: data)
    }

    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = [
            "code": .int(code),
            "message": .string(message)
        ]
        if let data { object["data"] = data }
        return .object(object)
    }
}

public struct JSONRPCRequest: Sendable, Equatable {
    public let id: JSONRPCID
    public let method: String
    public let params: JSONValue?

    public init(id: JSONRPCID, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

/// Outgoing JSON-RPC message produced by the server.
public enum JSONRPCResponse: Sendable, Equatable {
    case result(id: JSONRPCID, value: JSONValue)
    case error(id: JSONRPCID?, error: JSONRPCErrorObject)

    public var jsonValue: JSONValue {
        switch self {
        case .result(let id, let value):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id.jsonValue,
                "result": value
            ])
        case .error(let id, let error):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id?.jsonValue ?? .null,
                "error": error.jsonValue
            ])
        }
    }
}

/// A parsed inbound stdio message.
public enum JSONRPCIncoming: Sendable, Equatable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    /// A response sent by the client. This server never issues requests, so
    /// such messages are ignored (and logged).
    case response(id: JSONRPCID?)
    case invalid(id: JSONRPCID?, error: JSONRPCErrorObject)

    public static func parse(_ data: Data) -> JSONRPCIncoming {
        do {
            return parse(try MCPJSON.decode(data))
        } catch {
            return .invalid(
                id: nil,
                error: JSONRPCErrorObject(
                    code: .parseError,
                    message: "Parse error: invalid JSON",
                    data: .string(String(describing: error))
                )
            )
        }
    }

    public static func parse(_ value: JSONValue) -> JSONRPCIncoming {
        guard case .object(let object) = value else {
            if case .array = value {
                return invalid(
                    id: nil,
                    code: .invalidRequest,
                    message: "Invalid Request: JSON-RPC batching is not supported by MCP"
                )
            }
            return invalid(id: nil, code: .invalidRequest, message: "Invalid Request: expected a JSON object")
        }

        let idValue = object["id"]
        let parsedID: JSONRPCID?
        if let idValue {
            guard let id = JSONRPCID(jsonValue: idValue) else {
                let reason: String
                if idValue.isNull {
                    reason = "Invalid Request: JSON-RPC id must not be null"
                } else {
                    reason = "Invalid Request: JSON-RPC id must be a string or integer"
                }
                return invalid(id: nil, code: .invalidRequest, message: reason)
            }
            parsedID = id
        } else {
            parsedID = nil
        }

        guard object["jsonrpc"] == .string("2.0") else {
            return invalid(
                id: parsedID,
                code: .invalidRequest,
                message: "Invalid Request: expected jsonrpc version \"2.0\""
            )
        }

        // Receiving a response is legal only in the reverse direction. Ignore
        // it rather than treating it as a request.
        if object["method"] == nil,
           object["result"] != nil || object["error"] != nil {
            return .response(id: parsedID)
        }

        guard let methodValue = object["method"] else {
            return invalid(
                id: parsedID,
                code: .invalidRequest,
                message: "Invalid Request: missing method"
            )
        }
        guard case .string(let method) = methodValue, !method.isEmpty else {
            return invalid(
                id: parsedID,
                code: .invalidRequest,
                message: "Invalid Request: method must be a non-empty string"
            )
        }

        let params = object["params"].flatMap { $0.isNull ? nil : $0 }
        if let id = parsedID {
            return .request(JSONRPCRequest(id: id, method: method, params: params))
        }
        return .notification(JSONRPCNotification(method: method, params: params))
    }

    private static func invalid(
        id: JSONRPCID?,
        code: JSONRPCErrorCode,
        message: String
    ) -> JSONRPCIncoming {
        .invalid(id: id, error: JSONRPCErrorObject(code: code, message: message))
    }
}
