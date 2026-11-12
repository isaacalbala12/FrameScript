import Foundation

public struct JSONSchemaValidationError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String {
        path.isEmpty ? message : "\(path): \(message)"
    }

    public var errorDescription: String? { description }
}

/// A deliberately small JSON Schema validator covering the subset the MCP
/// tool surface needs: `type` (including integer vs number), `properties`,
/// `required`, `additionalProperties`, `items` / `additionalItems`, and
/// `enum`. Unknown keywords are ignored, as JSON Schema requires.
///
/// The same validator checks schema *structure* at tool registration, so the
/// server can never emit an invalid `inputSchema`/`outputSchema`.
public enum JSONSchemaValidator {
    public static let supportedTypes: Set<String> = [
        "object", "array", "string", "number", "integer", "boolean", "null"
    ]

    // MARK: Validation

    public static func validate(
        _ value: JSONValue,
        against schema: JSONValue,
        path: String = "value"
    ) throws {
        guard let schemaObject = schema.objectValue else {
            throw JSONSchemaValidationError(path: path, message: "schema must be a JSON object")
        }

        if let nonFinite = value.nonFiniteNumberPath {
            let location = nonFinite.isEmpty ? "<root>" : nonFinite
            throw JSONSchemaValidationError(
                path: path,
                message: "contains a non-finite number at \(location)"
            )
        }

        if let enumValue = schemaObject["enum"] {
            guard let allowed = enumValue.arrayValue else {
                throw JSONSchemaValidationError(path: path, message: "schema enum must be an array")
            }
            guard allowed.contains(where: { jsonEquals($0, value) }) else {
                throw JSONSchemaValidationError(
                    path: path,
                    message: "must be one of \(display(allowed))"
                )
            }
        }

        if let typeValue = schemaObject["type"] {
            let types = try parseTypes(typeValue, context: "\(path) schema.type")
            guard types.contains(where: { matches(value, type: $0) }) else {
                throw JSONSchemaValidationError(
                    path: path,
                    message: "must be \(describe(types))"
                )
            }
        }

        if case .object(let dictionary) = value {
            let properties = try propertiesMap(schemaObject["properties"], path: path)

            if let properties {
                for key in properties.keys.sorted() {
                    if let propertyValue = dictionary[key] {
                        try validate(
                            propertyValue,
                            against: properties[key]!,
                            path: join(path, key)
                        )
                    }
                }
            }

            if let requiredValue = schemaObject["required"] {
                guard let required = requiredValue.arrayValue else {
                    throw JSONSchemaValidationError(path: path, message: "schema required must be an array")
                }
                for item in required {
                    guard let key = item.stringValue else {
                        throw JSONSchemaValidationError(path: path, message: "schema required entries must be strings")
                    }
                    if dictionary[key] == nil {
                        throw JSONSchemaValidationError(path: path, message: "missing required property '\(key)'")
                    }
                }
            }

            if let additional = schemaObject["additionalProperties"] {
                let known = Set(properties?.keys ?? Dictionary<String, JSONValue>().keys)
                switch additional {
                case .bool(false):
                    for key in dictionary.keys.sorted() where !known.contains(key) {
                        throw JSONSchemaValidationError(
                            path: path,
                            message: "unexpected property '\(key)'"
                        )
                    }
                case .bool(true):
                    break
                case .object:
                    for key in dictionary.keys.sorted() where !known.contains(key) {
                        try validate(
                            dictionary[key]!,
                            against: additional,
                            path: join(path, key)
                        )
                    }
                default:
                    throw JSONSchemaValidationError(
                        path: path,
                        message: "schema additionalProperties must be a boolean or an object"
                    )
                }
            }
        }

        if case .array(let array) = value, let itemsSchema = schemaObject["items"] {
            switch itemsSchema {
            case .object:
                for (index, item) in array.enumerated() {
                    try validate(item, against: itemsSchema, path: "\(path)[\(index)]")
                }
            case .array(let tuple):
                for (index, item) in array.enumerated() {
                    if index < tuple.count {
                        try validate(item, against: tuple[index], path: "\(path)[\(index)]")
                    } else if schemaObject["additionalItems"] == .bool(false) {
                        throw JSONSchemaValidationError(
                            path: path,
                            message: "must not have more than \(tuple.count) items"
                        )
                    }
                }
            default:
                throw JSONSchemaValidationError(
                    path: path,
                    message: "schema items must be an object or an array of objects"
                )
            }
        }
    }

    // MARK: Schema structure

    /// Validates the shape of a schema (not a value against it). Used when
    /// registering tools so `tools/list` can never expose a malformed schema.
    public static func validateSchema(_ schema: JSONValue, context: String = "schema") throws {
        guard let object = schema.objectValue else {
            throw JSONSchemaValidationError(path: context, message: "must be a JSON object")
        }

        if let nonFinite = schema.nonFiniteNumberPath {
            let location = nonFinite.isEmpty ? "<root>" : nonFinite
            throw JSONSchemaValidationError(
                path: context,
                message: "contains a non-finite number at \(location)"
            )
        }

        if let typeValue = object["type"] {
            _ = try parseTypes(typeValue, context: "\(context).type")
        }

        if let propertiesValue = object["properties"] {
            guard let properties = propertiesValue.objectValue else {
                throw JSONSchemaValidationError(path: context, message: "properties must be an object")
            }
            for key in properties.keys.sorted() {
                try validateSchema(properties[key]!, context: "\(context).properties.\(key)")
            }
        }

        if let requiredValue = object["required"] {
            guard let required = requiredValue.arrayValue else {
                throw JSONSchemaValidationError(path: context, message: "required must be an array")
            }
            for item in required {
                guard item.stringValue != nil else {
                    throw JSONSchemaValidationError(path: context, message: "required entries must be strings")
                }
            }
        }

        if let additional = object["additionalProperties"] {
            switch additional {
            case .bool:
                break
            case .object:
                try validateSchema(additional, context: "\(context).additionalProperties")
            default:
                throw JSONSchemaValidationError(
                    path: context,
                    message: "additionalProperties must be a boolean or an object"
                )
            }
        }

        if let items = object["items"] {
            switch items {
            case .object:
                try validateSchema(items, context: "\(context).items")
            case .array(let tuple):
                for (index, item) in tuple.enumerated() {
                    try validateSchema(item, context: "\(context).items[\(index)]")
                }
            default:
                throw JSONSchemaValidationError(
                    path: context,
                    message: "items must be an object or an array of objects"
                )
            }
        }

        if let additionalItems = object["additionalItems"] {
            guard case .bool = additionalItems else {
                throw JSONSchemaValidationError(
                    path: context,
                    message: "additionalItems must be a boolean"
                )
            }
        }

        if let enumValue = object["enum"] {
            guard let values = enumValue.arrayValue, !values.isEmpty else {
                throw JSONSchemaValidationError(
                    path: context,
                    message: "enum must be a non-empty array"
                )
            }
        }
    }

    // MARK: Helpers

    private static func propertiesMap(
        _ value: JSONValue?,
        path: String
    ) throws -> [String: JSONValue]? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw JSONSchemaValidationError(path: path, message: "schema properties must be an object")
        }
        return object
    }

    private static func parseTypes(_ value: JSONValue, context: String) throws -> [String] {
        switch value {
        case .string(let type):
            guard supportedTypes.contains(type) else {
                throw JSONSchemaValidationError(path: context, message: "unsupported type '\(type)'")
            }
            return [type]
        case .array(let values):
            guard !values.isEmpty else {
                throw JSONSchemaValidationError(path: context, message: "type array must not be empty")
            }
            var types: [String] = []
            for item in values {
                guard let type = item.stringValue else {
                    throw JSONSchemaValidationError(path: context, message: "type entries must be strings")
                }
                guard supportedTypes.contains(type) else {
                    throw JSONSchemaValidationError(path: context, message: "unsupported type '\(type)'")
                }
                types.append(type)
            }
            return types
        default:
            throw JSONSchemaValidationError(
                path: context,
                message: "type must be a string or an array of strings"
            )
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch type {
        case "object": return value.objectValue != nil
        case "array": return value.arrayValue != nil
        case "string": return value.stringValue != nil
        case "boolean": return value.boolValue != nil
        case "null": return value.isNull
        case "integer": return value.integralValue != nil
        case "number":
            guard let number = value.doubleValue else { return false }
            return number.isFinite
        default:
            return false
        }
    }

    private static func jsonEquals(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        if lhs == rhs { return true }
        if let left = lhs.doubleValue, let right = rhs.doubleValue {
            return left == right
        }
        return false
    }

    private static func describe(_ types: [String]) -> String {
        guard types.count == 1 else {
            return "one of: " + types.joined(separator: ", ")
        }
        switch types[0] {
        case "object": return "an object"
        case "array": return "an array"
        case "string": return "a string"
        case "number": return "a number"
        case "integer": return "an integer"
        case "boolean": return "a boolean"
        case "null": return "null"
        default: return types[0]
        }
    }

    private static func display(_ values: [JSONValue]) -> String {
        values.map { value in
            if let data = try? MCPJSON.encode(value),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }.joined(separator: ", ")
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
