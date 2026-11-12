import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("Tool calls")
struct ToolTests {
    @Test("a successful call returns text and structured content")
    func successfulCall() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 3,
                name: "echo",
                arguments: .object(["text": .string("hello")])
            ))

            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 3)
            #expect(response.resultIsError == false)
            #expect(response.firstTextContent == "hello")
            #expect(response.rpcResult?["structuredContent"]?["text"]?.stringValue == "hello")
        }
    }

    @Test("structured results also include the serialized JSON")
    func structuredResultText() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 3,
                name: "echo",
                arguments: .object(["text": .string("hello")])
            ))
            let response = try await harness.nextResponse()
            let content = try #require(response.rpcResult?["content"]?.arrayValue)
            #expect(content.count == 2)
            #expect(content[0]["text"]?.stringValue == "hello")
            #expect(content[1]["text"]?.stringValue == #"{"text":"hello"}"#)
        }
    }

    @Test("the uppercase option works")
    func uppercaseOption() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 3,
                name: "echo",
                arguments: .object([
                    "text": .string("hello"),
                    "uppercase": .bool(true)
                ])
            ))
            let response = try await harness.nextResponse()
            #expect(response.firstTextContent == "HELLO")
        }
    }

    @Test("missing required arguments fail inputSchema validation with -32602")
    func missingRequiredArgumentFailsSchema() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 4, name: "echo"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage?.contains("missing required property 'text'") == true)
        }
    }

    @Test("wrong argument types fail inputSchema validation with -32602")
    func wrongArgumentTypeFailsSchema() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 4,
                name: "echo",
                arguments: .object(["text": .int(1)])
            ))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage?.contains("must be a string") == true)
        }
    }

    @Test("unknown properties fail closed schemas with -32602")
    func unexpectedPropertyFailsSchema() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 4,
                name: "echo",
                arguments: .object([
                    "text": .string("hi"),
                    "bogus": .int(1)
                ])
            ))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage?.contains("unexpected property 'bogus'") == true)
        }
    }

    @Test("argument-helper errors are tool execution errors")
    func argumentHelperErrorIsToolError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 4, name: "needs_text"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("Missing required argument 'text'") == true)
        }
    }

    @Test("generic handler errors become tool execution errors")
    func genericHandlerError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 5, name: "fail_generic"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.hasPrefix("Tool execution failed:") == true)
        }
    }

    @Test("MCPToolError.execution becomes a tool execution error")
    func executionError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 5, name: "fail_execution"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent == "tool execution failed on purpose")
        }
    }

    @Test("MCPToolError.invalidParams becomes -32602")
    func invalidParamsError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 6, name: "fail_invalid_params"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage == "bad request shape")
        }
    }

    @Test("MCPToolError.internalError becomes -32603")
    func internalError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 6, name: "fail_internal"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.internalError.rawValue)
            #expect(response.errorMessage == "internal boom")
        }
    }

    @Test("non-finite structured content becomes a tool execution error")
    func nonFiniteStructuredContent() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 7, name: "bad_output_infinity"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("non-finite number") == true)
        }
    }

    @Test("structured content must match outputSchema")
    func structuredContentMustMatchOutputSchema() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 7, name: "bad_output_schema"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("structuredContent.n") == true)
            #expect(response.firstTextContent?.contains("integer") == true)
        }
    }

    @Test("missing structured content is rejected when outputSchema exists")
    func missingStructuredContent() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 7, name: "missing_structured"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("structuredContent is missing") == true)
        }
    }

    @Test("the registry preserves order and deduplicates names")
    func registryOrderAndDeduplication() throws {
        let first = MCPTool(
            name: "same",
            description: "first",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .text("first") }
        )
        let second = MCPTool(
            name: "same",
            description: "second",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .text("second") }
        )
        let other = MCPTool(
            name: "other",
            inputSchema: .object(["type": .string("object")]),
            handler: { _ in .text("other") }
        )

        let registry = try MCPToolRegistry([first, second, other])
        #expect(registry.count == 2)
        #expect(registry.tools.map(\.name) == ["same", "other"])
        #expect(registry.tool(named: "same")?.description == "first")
        #expect(registry.tool(named: "missing") == nil)
    }

    @Test("registration rejects malformed tool schemas")
    func registrationRejectsMalformedSchemas() {
        let tools: [(String, JSONValue, JSONValue?)] = [
            ("null_input", .null, nil),
            ("string_input", .string("nope"), nil),
            ("array_input", .object(["type": .string("array")]), nil),
            ("null_output", .object(["type": .string("object")]), .null),
            ("string_output", .object(["type": .string("object")]), .string("nope")),
            (
                "bad_properties",
                .object([
                    "type": .string("object"),
                    "properties": .string("nope")
                ]),
                nil
            )
        ]

        for (name, inputSchema, outputSchema) in tools {
            let tool = MCPTool(
                name: name,
                inputSchema: inputSchema,
                outputSchema: outputSchema,
                handler: { _ in .text("x") }
            )
            do {
                _ = try MCPToolRegistry([tool])
                Issue.record("expected \(name) registration to fail")
            } catch let error as MCPToolDefinitionError {
                #expect(error.description.contains(name))
            } catch {
                Issue.record("unexpected error for \(name): \(error)")
            }
        }
    }

    @Test("registration accepts valid schemas")
    func registrationAcceptsValidSchemas() throws {
        let registry = try TestTools.standard()
        #expect(registry.count == 10)
        #expect(registry.tool(named: "echo") != nil)
        #expect(registry.tool(named: "framescript_version") != nil)
    }

    @Test("a tool definition carries optional metadata")
    func toolDefinitionMetadata() {
        let tool = TestTools.echoTool()
        let definition = tool.definition

        #expect(definition["name"]?.stringValue == "echo")
        #expect(definition["title"]?.stringValue == "Echo")
        #expect(definition["inputSchema"]?["additionalProperties"]?.boolValue == false)
        #expect(definition["outputSchema"]?["required"]?.arrayValue == [.string("text")])
        #expect(definition["annotations"]?["idempotentHint"]?.boolValue == true)
        #expect(definition["annotations"]?["destructiveHint"]?.boolValue == false)
        #expect(definition["icons"] == nil)
    }

    @Test("tool results default to non-error")
    func toolResultDefaults() {
        let result = MCPToolResult.text("ok")
        #expect(result.isError == false)
        #expect(result.content == [.text("ok")])
        #expect(result.structuredContent == nil)
        #expect(result.jsonValue["isError"]?.boolValue == false)
        #expect(result.jsonValue["content"]?.arrayValue?.count == 1)
    }
}
