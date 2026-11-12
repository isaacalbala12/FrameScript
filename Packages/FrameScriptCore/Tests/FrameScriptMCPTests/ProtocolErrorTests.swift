import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("JSON-RPC protocol errors")
struct ProtocolErrorTests {
    @Test("malformed JSON returns -32700 without decoder internals")
    func parseError() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine("{not json")
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.parseError.rawValue)
            #expect(response["id"]?.isNull == true)
            #expect(response.rpcError?["data"] == nil)
            #expect(response.errorMessage == "Parse error: invalid JSON")
        }
    }

    @Test("empty lines are ignored")
    func emptyLinesIgnored() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine("")
            harness.sendLine("   ")
            try harness.send(RPC.request(id: 1, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 1)
        }
    }

    @Test("a wrong jsonrpc version returns -32600")
    func wrongJSONRPCVersion() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
        }
    }

    @Test("a missing method returns -32600")
    func missingMethod() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine(#"{"jsonrpc":"2.0","id":2}"#)
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
        }
    }

    @Test("batch arrays return -32600")
    func batchUnsupported() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
            #expect(response.errorMessage?.contains("batching") == true)
        }
    }

    @Test("null ids return -32600")
    func nullID() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            harness.sendLine(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
            #expect(response["id"]?.isNull == true)
        }
    }

    @Test("unknown methods return -32601")
    func unknownMethod() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.request(id: 3, method: "does/not/exist"))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.methodNotFound.rawValue)
            #expect(response.errorMessage?.contains("does/not/exist") == true)
        }
    }

    @Test("tools/call validates the request shape")
    func toolsCallValidatesShape() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()

            try harness.send(RPC.request(id: 1, method: "tools/call"))
            let noParams = try await harness.nextResponse()
            #expect(noParams.errorCode == JSONRPCErrorCode.invalidParams.rawValue)

            try harness.send(RPC.request(id: 2, method: "tools/call", params: .array([])))
            let arrayParams = try await harness.nextResponse()
            #expect(arrayParams.errorCode == JSONRPCErrorCode.invalidParams.rawValue)

            try harness.send(RPC.request(id: 3, method: "tools/call", params: .object([
                "arguments": .object([:])
            ])))
            let noName = try await harness.nextResponse()
            #expect(noName.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(noName.errorMessage?.contains("params.name") == true)

            try harness.send(RPC.request(id: 4, method: "tools/call", params: .object([
                "name": .int(3)
            ])))
            let nameNotString = try await harness.nextResponse()
            #expect(nameNotString.errorCode == JSONRPCErrorCode.invalidParams.rawValue)

            try harness.send(RPC.request(id: 5, method: "tools/call", params: .object([
                "name": .string("echo"),
                "arguments": .string("not an object")
            ])))
            let badArguments = try await harness.nextResponse()
            #expect(badArguments.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
        }
    }

    @Test("unknown tools return -32602 with the tool name")
    func unknownTool() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 4, name: "no_such_tool"))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
            #expect(response.errorMessage?.contains("no_such_tool") == true)
        }
    }

    @Test("client responses are ignored")
    func clientResponsesIgnored() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(.object([
                "jsonrpc": .string("2.0"),
                "id": .int(4),
                "result": .object([:])
            ]))
            try harness.send(RPC.request(id: 7, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 7)
        }
    }

    @Test("unknown notifications are ignored")
    func unknownNotificationsIgnored() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.notification("notifications/whatever", params: .object([:])))
            try harness.send(RPC.request(id: 5, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 5)
        }
    }

    @Test("duplicate in-flight ids are rejected")
    func duplicateInFlightID() async throws {
        let registry = try MCPToolRegistry([
            TestTools.slowTool(duration: .seconds(5))
        ])
        try await withHarness(registry) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 5, name: "slow"))
            try await Task.sleep(for: .milliseconds(100))
            try harness.send(RPC.request(id: 5, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
            #expect(response.errorMessage?.contains("already in flight") == true)
        }
    }
}
