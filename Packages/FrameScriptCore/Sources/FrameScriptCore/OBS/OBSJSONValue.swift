import Foundation

/// A minimal, `Sendable` JSON tree used for obs-websocket payloads.
///
/// obs-websocket payloads are loosely typed JSON objects. Keeping them in a value
/// type lets protocol handling stay inside the actor model without passing `Any`
/// across concurrency domains.
public enum OBSJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OBSJSONValue])
    case object([String: OBSJSONValue])
}

// MARK: - Codable

extension OBSJSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int64.self) {
            self = .number(Double(value))
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([OBSJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: OBSJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            if value.isFinite, let integer = Int64(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - Accessors

public extension OBSJSONValue {
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// The value as an `Int` when the number is finite and integral.
    var intValue: Int? {
        guard case .number(let value) = self,
              value.isFinite,
              value.rounded(.towardZero) == value
        else { return nil }
        return Int(exactly: value)
    }

    var arrayValue: [OBSJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: OBSJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> OBSJSONValue? {
        objectValue?[key]
    }

    /// Decodes a JSON document into an `OBSJSONValue`.
    static func parse(_ text: String) throws -> OBSJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw OBSProtocolError.malformedMessage("The message is not valid UTF-8.")
        }
        do {
            return try JSONDecoder().decode(OBSJSONValue.self, from: data)
        } catch {
            throw OBSProtocolError.invalidJSON(String(describing: error))
        }
    }

    /// Serializes the value to compact JSON. Sorted keys make payloads deterministic.
    func jsonString(sortedKeys: Bool = true) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = sortedKeys ? [.sortedKeys] : []
            let data = try encoder.encode(self)
            guard let text = String(data: data, encoding: .utf8) else {
                throw OBSProtocolError.encodingFailed("The encoded JSON was not valid UTF-8.")
            }
            return text
        } catch let error as OBSProtocolError {
            throw error
        } catch {
            throw OBSProtocolError.encodingFailed(String(describing: error))
        }
    }
}

// MARK: - Protocol errors

/// Errors raised while framing or parsing obs-websocket messages.
public enum OBSProtocolError: Error, Sendable, Equatable, LocalizedError {
    case invalidJSON(String)
    case encodingFailed(String)
    case malformedMessage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            "Invalid JSON in the obs-websocket message: \(detail)"
        case .encodingFailed(let detail):
            "Could not encode an obs-websocket message: \(detail)"
        case .malformedMessage(let detail):
            "Malformed obs-websocket message: \(detail)"
        }
    }
}
