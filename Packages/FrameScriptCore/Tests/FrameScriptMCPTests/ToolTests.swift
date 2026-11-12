import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("Tool calls")
struct ToolTests {
    @Test("a successful call returns text and structured content")
    func successfulCall() async throws {
        try await withHarness(TestTools.standard()) { harness in
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

    @Test("the uppercase option works")
    func uppercaseOption() async throws {
        try await withHarness(TestTools.standard()) { harness in
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

    @Test("missing arguments are tool execution errors")
    func missingArgumentIsToolError() async throws {
        try await withHarness(TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 4, name: "echo"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == nil)
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("Missing required argument 'text'") == true)
        }
    }

    @Test("wrong argument types are tool execution errors")
    func wrongArgumentTypeIsToolError() async throws {
        try await withHarness(TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(
                id: 4,
                name: "echo",
                arguments: .object(["text": .int(1)])
            ))

            let response = try await harness.nextResponse()
            #expect(response.resultIsError == true)
            #expect(response.firstTextContent?.contains("must be a string") == true)
        }
    }

    @Test("generic handler errors become tool execution errors")
    func genericHandlerError() async throws {
        try await withHarness(TestTools.standard()) { harness in
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
        try await withHarness(TestTools.standard()) { harness in
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
        try await withHarness(TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 6, name: "fail_invalid_params"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage == "bad request shape")
        }
    }

    @Test("MCPToolError.internalError becomes -32603")
    func internalError() async throws {
        try await withHarness(TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 6, name: "fail_internal"))

            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.internalError.rawValue)
            #expect(response.errorMessage == "internal boom")
        }
    }

    @Test("the registry preserves order and deduplicates names")
    func registryOrderAndDeduplication() {
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

        let registry = MCPToolRegistry([first, second, other])
        #expect(registry.count == 2)
        #expect(registry.tools.map(\.name) == ["same", "other"])
        #expect(registry.tool(named: "same")?.description == "first")
        #expect(registry.tool(named: "missing") == nil)
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
