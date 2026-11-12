import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("MCP argument helpers")
struct MCPArgumentsTests {
    private let sample = JSONValue.object([
        "text": .string("hello"),
        "count": .int(3),
        "ratio": .double(1.5),
        "flag": .bool(true),
        "items": .array([.string("a"), .string("b")]),
        "meta": .object(["key": .string("value")]),
        "nothing": .null
    ])

    @Test("reads required values")
    func readsRequiredValues() throws {
        let arguments = try MCPArguments(sample)
        #expect(try arguments.requiredString("text") == "hello")
        #expect(try arguments.requiredInt("count") == 3)
        #expect(try arguments.requiredDouble("ratio") == 1.5)
        #expect(try arguments.requiredBool("flag") == true)
        #expect(try arguments.requiredArray("items").count == 2)
        #expect(try arguments.requiredObject("meta")["key"]?.stringValue == "value")
    }

    @Test("accepts integral doubles as integers")
    func acceptsIntegralDoubles() throws {
        let arguments = try MCPArguments(.object(["count": .double(4.0)]))
        #expect(try arguments.requiredInt("count") == 4)
    }

    @Test("treats null and absent alike for optional values")
    func optionalValues() throws {
        let arguments = try MCPArguments(sample)
        #expect(try arguments.optionalString("text") == "hello")
        #expect(try arguments.optionalString("nothing") == nil)
        #expect(try arguments.optionalString("missing") == nil)
        #expect(try arguments.optionalInt("missing") == nil)
        #expect(try arguments.optionalBool("nothing") == nil)
        #expect(arguments.contains("text"))
        #expect(arguments.contains("nothing") == false)
        #expect(arguments.keys.contains("text"))
    }

    @Test("missing required values produce clear messages")
    func missingRequiredValue() throws {
        let arguments = try MCPArguments(.object([:]))
        do {
            _ = try arguments.requiredString("text")
            Issue.record("expected MCPArgumentError")
        } catch let error as MCPArgumentError {
            #expect(error.argument == "text")
            #expect(error.message == "Missing required argument 'text' (expected a string).")
        }
    }

    @Test("wrong types produce clear messages")
    func wrongType() throws {
        let arguments = try MCPArguments(.object(["count": .string("three")]))
        do {
            _ = try arguments.requiredInt("count")
            Issue.record("expected MCPArgumentError")
        } catch let error as MCPArgumentError {
            #expect(error.argument == "count")
            #expect(error.message == "Argument 'count' must be an integer (got a string).")
        }
    }

    @Test("optional values with a wrong type still fail")
    func optionalWrongType() throws {
        let arguments = try MCPArguments(.object(["flag": .string("yes")]))
        do {
            _ = try arguments.optionalBool("flag")
            Issue.record("expected MCPArgumentError")
        } catch let error as MCPArgumentError {
            #expect(error.message.contains("must be a boolean"))
        }
    }

    @Test("non-object arguments are rejected")
    func rejectsNonObject() {
        do {
            _ = try MCPArguments(.array([]))
            Issue.record("expected MCPArgumentError")
        } catch let error as MCPArgumentError {
            #expect(error.message.contains("must be a JSON object"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("non-finite and fractional numbers are not integers")
    func rejectsNonIntegralNumbers() throws {
        let arguments = try MCPArguments(.object([
            "fractional": .double(1.25),
            "huge": .double(1e300)
        ]))
        #expect(throws: MCPArgumentError.self) {
            _ = try arguments.requiredInt("fractional")
        }
        #expect(throws: MCPArgumentError.self) {
            _ = try arguments.requiredInt("huge")
        }
    }
}
