import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("Handshake and discovery")
struct HandshakeTests {
    @Test("initialize negotiates the latest supported version")
    func initializeNegotiatesLatest() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            let response = try await harness.performInitialize()
            let result = try #require(response.rpcResult)

            #expect(response["id"]?.intValue == 1)
            #expect(result["protocolVersion"]?.stringValue == MCPProtocolVersion.latest)
            #expect(result["capabilities"]?["tools"] != nil)
            #expect(result["serverInfo"]?["name"]?.stringValue == "framescript")
            #expect(result["serverInfo"]?["version"]?.stringValue?.isEmpty == false)
        }
    }

    @Test("only advertises versions whose semantics are implemented")
    func advertisesOnlyImplementedVersions() async throws {
        #expect(MCPProtocolVersion.supported == [
            MCPProtocolVersion.v2025_11_25,
            MCPProtocolVersion.v2025_06_18
        ])

        try await withHarness(try TestTools.standard()) { harness in
            let response = try await harness.performInitialize(version: "2025-03-26")
            #expect(response.rpcResult?["protocolVersion"]?.stringValue == MCPProtocolVersion.v2025_11_25)
        }

        try await withHarness(try TestTools.standard()) { harness in
            let response = try await harness.performInitialize(version: "2024-11-05")
            #expect(response.rpcResult?["protocolVersion"]?.stringValue == MCPProtocolVersion.v2025_11_25)
        }
    }

    @Test("echoes an older supported version")
    func initializeEchoesOlderVersion() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            let response = try await harness.performInitialize(version: "2025-06-18")
            #expect(response.rpcResult?["protocolVersion"]?.stringValue == "2025-06-18")
        }
    }

    @Test("falls back to the newest supported version")
    func initializeFallsBack() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            let response = try await harness.performInitialize(version: "1900-01-01")
            #expect(response.rpcResult?["protocolVersion"]?.stringValue == MCPProtocolVersion.latest)
        }
    }

    @Test("uses the configured newest version when falling back")
    func initializeUsesConfiguredFallback() async throws {
        try await withHarness(
            try TestTools.standard(),
            supportedVersions: ["2025-06-18"]
        ) { harness in
            let response = try await harness.performInitialize(version: "2025-11-25")
            #expect(response.rpcResult?["protocolVersion"]?.stringValue == "2025-06-18")
        }
    }

    @Test("rejects a second initialize")
    func rejectsDuplicateInitialize() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.initialize(id: 2))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
        }
    }

    @Test("rejects tools requests before initialize")
    func rejectsToolsBeforeInitialize() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            try harness.send(RPC.request(id: 1, method: "tools/list"))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidRequest.rawValue)
            #expect(response.errorMessage?.contains("not initialized") == true)
        }
    }

    @Test("ping works before initialize")
    func pingBeforeInitialize() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            try harness.send(RPC.request(id: 8, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 8)
            #expect(response.rpcResult?.objectValue?.isEmpty == true)
        }
    }

    @Test("initialize validates its required params")
    func initializeValidatesParams() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            try harness.send(RPC.request(id: 1, method: "initialize", params: .object([:])))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
        }

        try await withHarness(try TestTools.standard()) { harness in
            try harness.send(RPC.request(id: 1, method: "initialize", params: .array([])))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
        }

        try await withHarness(try TestTools.standard()) { harness in
            try harness.send(RPC.request(id: 1, method: "initialize", params: .object([
                "protocolVersion": .string(MCPProtocolVersion.latest),
                "capabilities": .object([:])
            ])))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
        }
    }

    @Test("initialized notification produces no response")
    func initializedNotificationIsSilent() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.notification("notifications/initialized"))

            let unexpected = try await harness.channel.nextOutboundJSON(timeout: 0.2)
            #expect(unexpected == nil)

            try harness.send(RPC.request(id: 9, method: "ping"))
            let ping = try await harness.nextResponse()
            #expect(ping["id"]?.intValue == 9)
        }
    }

    @Test("tools/list returns schemas, output schemas and annotations")
    func toolsListReturnsSchemas() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.notification("notifications/initialized"))
            try harness.send(RPC.request(id: 2, method: "tools/list"))

            let response = try await harness.nextResponse()
            let result = try #require(response.rpcResult)
            let tools = try #require(result["tools"]?.arrayValue)

            #expect(tools.count == 10)
            #expect(response.toolNames.first == "echo")
            #expect(response.toolNames.contains("framescript_version"))

            for tool in tools {
                #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
                if let outputSchema = tool["outputSchema"] {
                    #expect(outputSchema["type"]?.stringValue == "object")
                }
            }

            let echo = try #require(tools.first)
            #expect(echo["name"]?.stringValue == "echo")
            #expect(echo["title"]?.stringValue == "Echo")
            #expect(echo["description"]?.stringValue?.contains("Echo text") == true)
            #expect(echo["inputSchema"]?["type"]?.stringValue == "object")
            #expect(echo["inputSchema"]?["required"]?.arrayValue?.contains(.string("text")) == true)
            #expect(echo["outputSchema"]?["type"]?.stringValue == "object")
            #expect(echo["annotations"]?["readOnlyHint"]?.boolValue == true)
            #expect(echo["annotations"]?["openWorldHint"]?.boolValue == false)
        }
    }

    @Test("tools/list rejects an unknown cursor")
    func toolsListRejectsCursor() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.request(
                id: 2,
                method: "tools/list",
                params: .object(["cursor": .string("abc")])
            ))
            let response = try await harness.nextResponse()
            #expect(response.errorCode == JSONRPCErrorCode.invalidParams.rawValue)
        }
    }

    @Test("EOF shuts the server down")
    func eofShutsDown() async throws {
        let harness = MCPTestHarness(registry: try TestTools.standard())
        _ = try await harness.performInitialize()
        harness.channel.closeInput()
        await harness.serverTask.value
        #expect(harness.serverTask.isCancelled == false)
    }
}
