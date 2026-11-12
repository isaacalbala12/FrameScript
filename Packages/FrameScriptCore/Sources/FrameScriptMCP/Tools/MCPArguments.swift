import Foundation

/// Raised by the typed argument helpers. The server reports these as tool
/// execution errors (`isError: true`) because they are model-correctable,
/// rather than as JSON-RPC protocol errors.
public struct MCPArgumentError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    public let message: String
    public let argument: String?

    public init(_ message: String, argument: String? = nil) {
        self.message = message
        self.argument = argument
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// Typed access to a `tools/call` `arguments` object.
///
/// Helpers provide clear, model-readable error messages for missing fields and
/// wrong JSON types:
///
/// ```swift
/// let arguments = try MCPArguments(raw)
/// let text = try arguments.requiredString("text")
/// let count = try arguments.optionalInt("count") ?? 1
/// ```
public struct MCPArguments: Sendable {
    public let raw: JSONValue

    public init(_ raw: JSONValue = .object([:])) throws {
        guard raw.objectValue != nil else {
            throw MCPArgumentError(
                "Tool arguments must be a JSON object (got \(raw.typeName))."
            )
        }
        self.raw = raw
    }

    public var keys: [String] {
        raw.objectValue.map { Array($0.keys).sorted() } ?? []
    }

    public func contains(_ name: String) -> Bool {
        guard let value = raw.objectValue?[name] else { return false }
        return !value.isNull
    }

    // MARK: Required

    public func requiredString(_ name: String) throws -> String {
        let value = try requiredValue(name, expected: "a string")
        guard case .string(let string) = value else {
            throw typeError(name, expected: "a string", got: value)
        }
        return string
    }

    public func requiredInt(_ name: String) throws -> Int {
        let value = try requiredValue(name, expected: "an integer")
        guard let integer = value.integralValue else {
            throw typeError(name, expected: "an integer", got: value)
        }
        return integer
    }

    public func requiredDouble(_ name: String) throws -> Double {
        let value = try requiredValue(name, expected: "a number")
        guard let number = value.doubleValue else {
            throw typeError(name, expected: "a number", got: value)
        }
        return number
    }

    public func requiredBool(_ name: String) throws -> Bool {
        let value = try requiredValue(name, expected: "a boolean")
        guard case .bool(let boolean) = value else {
            throw typeError(name, expected: "a boolean", got: value)
        }
        return boolean
    }

    public func requiredArray(_ name: String) throws -> [JSONValue] {
        let value = try requiredValue(name, expected: "an array")
        guard case .array(let array) = value else {
            throw typeError(name, expected: "an array", got: value)
        }
        return array
    }

    public func requiredObject(_ name: String) throws -> [String: JSONValue] {
        let value = try requiredValue(name, expected: "an object")
        guard case .object(let object) = value else {
            throw typeError(name, expected: "an object", got: value)
        }
        return object
    }

    // MARK: Optional

    public func optionalString(_ name: String) throws -> String? {
        guard let value = try optionalValue(name) else { return nil }
        guard case .string(let string) = value else {
            throw typeError(name, expected: "a string", got: value)
        }
        return string
    }

    public func optionalInt(_ name: String) throws -> Int? {
        guard let value = try optionalValue(name) else { return nil }
        guard let integer = value.integralValue else {
            throw typeError(name, expected: "an integer", got: value)
        }
        return integer
    }

    public func optionalDouble(_ name: String) throws -> Double? {
        guard let value = try optionalValue(name) else { return nil }
        guard let number = value.doubleValue else {
            throw typeError(name, expected: "a number", got: value)
        }
        return number
    }

    public func optionalBool(_ name: String) throws -> Bool? {
        guard let value = try optionalValue(name) else { return nil }
        guard case .bool(let boolean) = value else {
            throw typeError(name, expected: "a boolean", got: value)
        }
        return boolean
    }

    public func optionalArray(_ name: String) throws -> [JSONValue]? {
        guard let value = try optionalValue(name) else { return nil }
        guard case .array(let array) = value else {
            throw typeError(name, expected: "an array", got: value)
        }
        return array
    }

    public func optionalObject(_ name: String) throws -> [String: JSONValue]? {
        guard let value = try optionalValue(name) else { return nil }
        guard case .object(let object) = value else {
            throw typeError(name, expected: "an object", got: value)
        }
        return object
    }

    // MARK: Internals

    private func requiredValue(_ name: String, expected: String) throws -> JSONValue {
        guard let value = try optionalValue(name) else {
            throw MCPArgumentError(
                "Missing required argument '\(name)' (expected \(expected)).",
                argument: name
            )
        }
        return value
    }

    private func optionalValue(_ name: String) throws -> JSONValue? {
        guard let object = raw.objectValue else {
            throw MCPArgumentError(
                "Tool arguments must be a JSON object (got \(raw.typeName))."
            )
        }
        guard let value = object[name], !value.isNull else { return nil }
        return value
    }

    private func typeError(_ name: String, expected: String, got: JSONValue) -> MCPArgumentError {
        MCPArgumentError(
            "Argument '\(name)' must be \(expected) (got \(got.typeName)).",
            argument: name
        )
    }
}

extension JSONValue {
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "a boolean"
        case .int, .double: return "a number"
        case .string: return "a string"
        case .array: return "an array"
        case .object: return "an object"
        }
    }
}
