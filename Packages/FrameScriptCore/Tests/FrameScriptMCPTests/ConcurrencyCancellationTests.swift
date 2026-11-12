import Foundation
import Testing
@testable import FrameScriptMCP

@Suite("Concurrency, cancellation and shutdown")
struct ConcurrencyCancellationTests {
    @Test("a fast call overtakes a slow concurrent call")
    func fastCallOvertakesSlowCall() async throws {
        let registry = try MCPToolRegistry([
            TestTools.slowTool(duration: .milliseconds(600)),
            TestTools.fastTool()
        ])

        try await withHarness(registry) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 1, name: "slow"))
            try harness.send(RPC.toolsCall(id: 2, name: "fast"))

            let first = try await harness.nextResponse()
            let second = try await harness.nextResponse()

            #expect(first["id"]?.intValue == 2)
            #expect(first.firstTextContent == "fast")
            #expect(second["id"]?.intValue == 1)
            #expect(second.firstTextContent == "slow finished")
        }
    }

    @Test("cancellation suppresses the response and stops the handler")
    func cancellationSuppressesResponse() async throws {
        let probe = CancellationProbe()
        let registry = try MCPToolRegistry([
            TestTools.slowTool(duration: .seconds(10), probe: probe)
        ])

        try await withHarness(registry) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.toolsCall(id: 7, name: "slow"))
            try await Task.sleep(for: .milliseconds(100))

            try harness.send(RPC.notification(
                "notifications/cancelled",
                params: .object([
                    "requestId": .int(7),
                    "reason": .string("user cancelled")
                ])
            ))

            let suppressed = try await harness.channel.nextOutboundJSON(timeout: 0.4)
            #expect(suppressed == nil)

            let wasCancelled = await probe.wasCancelled()
            #expect(wasCancelled)

            try harness.send(RPC.request(id: 8, method: "ping"))
            let ping = try await harness.nextResponse()
            #expect(ping["id"]?.intValue == 8)
        }
    }

    @Test("cancelling an unknown request is ignored")
    func unknownCancellationIgnored() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.notification(
                "notifications/cancelled",
                params: .object(["requestId": .int(99)])
            ))
            try harness.send(RPC.request(id: 3, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 3)
        }
    }

    @Test("malformed cancellations are ignored")
    func malformedCancellationIgnored() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            try harness.send(RPC.notification("notifications/cancelled"))
            try harness.send(RPC.notification(
                "notifications/cancelled",
                params: .object(["requestId": .string("not-a-request")])
            ))
            try harness.send(RPC.request(id: 4, method: "ping"))
            let response = try await harness.nextResponse()
            #expect(response["id"]?.intValue == 4)
        }
    }

    @Test("EOF drains in-flight responses before exiting")
    func eofDrainsInFlightResponses() async throws {
        let registry = try MCPToolRegistry([
            TestTools.slowTool(duration: .milliseconds(100))
        ])
        let harness = MCPTestHarness(
            registry: registry,
            shutdownGracePeriod: .seconds(1)
        )

        try harness.send(RPC.initialize(id: 1))
        try harness.send(RPC.toolsCall(id: 2, name: "slow"))
        harness.channel.closeInput()
        await harness.serverTask.value

        let initialize = try await harness.nextResponse()
        let call = try await harness.nextResponse()
        #expect(initialize["id"]?.intValue == 1)
        #expect(call["id"]?.intValue == 2)
        #expect(call.firstTextContent == "slow finished")
    }

    @Test("shutdown cancels in-flight work after a bounded grace period")
    func shutdownCancelsInFlightWork() async throws {
        let probe = CancellationProbe()
        let registry = try MCPToolRegistry([
            TestTools.slowTool(duration: .seconds(10), probe: probe)
        ])
        let harness = MCPTestHarness(
            registry: registry,
            shutdownGracePeriod: .milliseconds(50)
        )

        _ = try await harness.performInitialize()
        try harness.send(RPC.toolsCall(id: 4, name: "slow"))
        try await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let start = clock.now
        harness.channel.closeInput()
        await harness.serverTask.value
        let elapsed = clock.now - start

        #expect(elapsed < .seconds(2))
        let wasCancelled = await probe.wasCancelled()
        #expect(wasCancelled)
    }

    @Test("handles many concurrent calls")
    func manyConcurrentCalls() async throws {
        try await withHarness(try TestTools.standard()) { harness in
            _ = try await harness.performInitialize()
            for id in 1...20 {
                try harness.send(RPC.toolsCall(
                    id: id,
                    name: "echo",
                    arguments: .object(["text": .string("message-\(id)")])
                ))
            }

            var seen: Set<Int> = []
            for _ in 1...20 {
                let response = try await harness.nextResponse()
                if let id = response["id"]?.intValue {
                    seen.insert(id)
                }
            }
            #expect(seen == Set(1...20))
        }
    }
}
