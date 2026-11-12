import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("JSON Schema subset validator")
struct JSONSchemaValidatorTests {
    private func expectInvalid(
        _ value: JSONValue,
        _ schema: JSONValue,
        contains: String
    ) {
        do {
            try JSONSchemaValidator.validate(value, against: schema, path: "arguments")
            Issue.record("expected a validation error")
        } catch let error as JSONSchemaValidationError {
            #expect(
                error.description.contains(contains),
                "unexpected message: \(error.description)"
            )
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("validates primitive types")
    func validatesPrimitiveTypes() throws {
        try JSONSchemaValidator.validate(.string("x"), against: .object(["type": .string("string")]))
        try JSONSchemaValidator.validate(.bool(true), against: .object(["type": .string("boolean")]))
        try JSONSchemaValidator.validate(.null, against: .object(["type": .string("null")]))
        try JSONSchemaValidator.validate(.int(1), against: .object(["type": .string("integer")]))
        try JSONSchemaValidator.validate(.double(2.0), against: .object(["type": .string("integer")]))
        try JSONSchemaValidator.validate(.int(2), against: .object(["type": .string("number")]))
        try JSONSchemaValidator.validate(.double(1.5), against: .object(["type": .string("number")]))

        expectInvalid(.double(1.5), .object(["type": .string("integer")]), contains: "must be an integer")
        expectInvalid(.string("x"), .object(["type": .string("number")]), contains: "must be a number")
        expectInvalid(.bool(true), .object(["type": .string("object")]), contains: "must be an object")
    }

    @Test("supports a union of types")
    func supportsTypeArrays() throws {
        let schema = JSONValue.object(["type": .array([.string("string"), .string("null")])])
        try JSONSchemaValidator.validate(.string("x"), against: schema)
        try JSONSchemaValidator.validate(.null, against: schema)
        expectInvalid(.int(1), schema, contains: "one of")
    }

    @Test("validates properties, required and closed objects")
    func validatesObjects() throws {
        let schema = JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "name": .object(["type": .string("string")]),
                "age": .object(["type": .string("integer")])
            ]),
            "required": .array([.string("name")]),
            "additionalProperties": .bool(false)
        ])

        try JSONSchemaValidator.validate(
            .object(["name": .string("Ada"), "age": .int(36)]),
            against: schema
        )
        expectInvalid(
            .object(["age": .int(36)]),
            schema,
            contains: "missing required property 'name'"
        )
        expectInvalid(
            .object(["name": .string("Ada"), "age": .string("old")]),
            schema,
            contains: "arguments.age"
        )
        expectInvalid(
            .object(["name": .string("Ada"), "extra": .int(1)]),
            schema,
            contains: "unexpected property 'extra'"
        )
    }

    @Test("additionalProperties may be true or a schema")
    func additionalProperties() throws {
        let open = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
            "additionalProperties": .bool(true)
        ])
        try JSONSchemaValidator.validate(
            .object(["name": .string("Ada"), "extra": .int(1)]),
            against: open
        )

        let typed = JSONValue.object([
            "type": .string("object"),
            "properties": .object(["name": .object(["type": .string("string")])]),
            "additionalProperties": .object(["type": .string("integer")])
        ])
        try JSONSchemaValidator.validate(
            .object(["name": .string("Ada"), "count": .int(3)]),
            against: typed
        )
        expectInvalid(
            .object(["name": .string("Ada"), "count": .string("three")]),
            typed,
            contains: "arguments.count"
        )
    }

    @Test("validates array items")
    func validatesArrayItems() throws {
        let schema = JSONValue.object([
            "type": .string("array"),
            "items": .object(["type": .string("integer")])
        ])
        try JSONSchemaValidator.validate(.array([.int(1), .double(2.0)]), against: schema)
        expectInvalid(.array([.int(1), .string("two")]), schema, contains: "arguments[1]")
    }

    @Test("validates tuple items and additionalItems")
    func validatesTupleItems() throws {
        let schema = JSONValue.object([
            "type": .string("array"),
            "items": .array([
                .object(["type": .string("string")]),
                .object(["type": .string("integer")])
            ]),
            "additionalItems": .bool(false)
        ])
        try JSONSchemaValidator.validate(.array([.string("a"), .int(1)]), against: schema)
        expectInvalid(
            .array([.string("a"), .int(1), .bool(true)]),
            schema,
            contains: "must not have more than 2 items"
        )
    }

    @Test("validates enum values")
    func validatesEnum() throws {
        let schema = JSONValue.object([
            "type": .string("string"),
            "enum": .array([.string("draft"), .string("published")])
        ])
        try JSONSchemaValidator.validate(.string("draft"), against: schema)
        expectInvalid(.string("archived"), schema, contains: "must be one of")
    }

    @Test("rejects non-finite numbers")
    func rejectsNonFiniteNumbers() {
        expectInvalid(
            .double(.infinity),
            .object(["type": .string("number")]),
            contains: "non-finite"
        )
        expectInvalid(
            .object(["n": .double(.nan)]),
            .object(["type": .string("object")]),
            contains: "non-finite"
        )
    }

    @Test("rejects malformed schema structures")
    func rejectsMalformedSchemas() throws {
        let invalid: [JSONValue] = [
            .null,
            .string("nope"),
            .object(["type": .string("nope")]),
            .object(["type": .string("object"), "properties": .string("nope")]),
            .object(["type": .string("object"), "required": .string("name")]),
            .object(["type": .string("object"), "additionalProperties": .string("nope")]),
            .object(["type": .string("object"), "items": .string("nope")]),
            .object(["type": .string("object"), "enum": .string("nope")]),
            .object(["type": .string("object"), "enum": .array([])])
        ]

        for schema in invalid {
            do {
                try JSONSchemaValidator.validateSchema(schema)
                Issue.record("expected schema validation to fail: \(schema)")
            } catch is JSONSchemaValidationError {
                // expected
            }
        }

        try JSONSchemaValidator.validateSchema(TestTools.echoTool().inputSchema)
        try JSONSchemaValidator.validateSchema(TestTools.echoTool().outputSchema ?? .null)
    }
}
