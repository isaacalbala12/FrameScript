import Foundation
@testable import FrameScriptCore

enum OBSTestFailure: Error, CustomStringConvertible {
    case timeout(String)
    case unexpected(String)

    var description: String {
        switch self {
        case .timeout(let what): "Timed out waiting for \(what)."
        case .unexpected(let detail): "Unexpected test state: \(detail)"
        }
    }
}

/// An in-memory obs-websocket server for one WebSocket session.
///
/// Tests push server frames explicitly, so the client is exercised against
/// scripted Hello/Identified/responses/events instead of a live OBS instance.
actor FakeOBSSession {
    private let helloText: String?
    private var outgoing: [String] = []
    private var incoming: [String] = []
    private var readWaiters: [CheckedContinuation<OBSTransportEvent, Never>] = []
    private var closedEvent: OBSTransportClose?
    private var isClosed = false

    private(set) var connectionCount = 0

    init(helloText: String?) {
        self.helloText = helloText
    }

    static func hello(
        rpcVersion: Int = 1,
        obsStudioVersion: String = "30.2.2",
        obsWebSocketVersion: String = "5.5.2",
        challenge: String? = nil,
        salt: String? = nil
    ) throws -> String {
        var data: [String: OBSJSONValue] = [
            "obsStudioVersion": .string(obsStudioVersion),
            "obsWebSocketVersion": .string(obsWebSocketVersion),
            "rpcVersion": .number(Double(rpcVersion)),
        ]
        if let challenge, let salt {
            data["authentication"] = .object([
                "challenge": .string(challenge),
                "salt": .string(salt),
            ])
        }
        let message: OBSJSONValue = .object([
            "op": .number(Double(OBSOpCode.hello.rawValue)),
            "d": .object(data),
        ])
        return try message.jsonString()
    }

    // MARK: Transport side

    func registerConnection() {
        connectionCount += 1
        if let helloText {
            outgoing.append(helloText)
        }
    }

    func read() async -> OBSTransportEvent {
        if !outgoing.isEmpty {
            return .text(outgoing.removeFirst())
        }
        if isClosed {
            return .closed(closedEvent ?? OBSTransportClose(code: nil))
        }
        return await withCheckedContinuation { continuation in
            readWaiters.append(continuation)
        }
    }

    func write(_ text: String) {
        incoming.append(text)
    }

    func closeFromClient() {
        close(code: nil, reason: nil)
    }

    // MARK: Server side

    func push(_ text: String) {
        guard !isClosed else { return }
        if readWaiters.isEmpty {
            outgoing.append(text)
        } else {
            let waiter = readWaiters.removeFirst()
            waiter.resume(returning: .text(text))
        }
    }

    func close(code: Int? = nil, reason: String? = nil) {
        guard !isClosed else { return }
        isClosed = true
        let event = OBSTransportClose(code: code, reason: reason)
        closedEvent = event
        let waiters = readWaiters
        readWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: .closed(event))
        }
    }

    func pushIdentified(negotiatedRpcVersion: Int = 1) throws {
        let message: OBSJSONValue = .object([
            "op": .number(Double(OBSOpCode.identified.rawValue)),
            "d": .object([
                "negotiatedRpcVersion": .number(Double(negotiatedRpcVersion)),
            ]),
        ])
        push(try message.jsonString())
    }

    func pushResponse(
        requestType: String,
        requestID: String,
        responseData: [String: OBSJSONValue]? = nil,
        result: Bool = true,
        code: Int = 100,
        comment: String? = nil
    ) throws {
        var status: [String: OBSJSONValue] = [
            "result": .bool(result),
            "code": .number(Double(code)),
        ]
        if let comment {
            status["comment"] = .string(comment)
        }
        var data: [String: OBSJSONValue] = [
            "requestType": .string(requestType),
            "requestId": .string(requestID),
            "requestStatus": .object(status),
        ]
        if let responseData {
            data["responseData"] = .object(responseData)
        }
        let message: OBSJSONValue = .object([
            "op": .number(Double(OBSOpCode.requestResponse.rawValue)),
            "d": .object(data),
        ])
        push(try message.jsonString())
    }

    func pushEvent(
        _ eventType: String,
        eventIntent: Int = 64,
        eventData: [String: OBSJSONValue] = [:]
    ) throws {
        let message: OBSJSONValue = .object([
            "op": .number(Double(OBSOpCode.event.rawValue)),
            "d": .object([
                "eventType": .string(eventType),
                "eventIntent": .number(Double(eventIntent)),
                "eventData": .object(eventData),
            ]),
        ])
        push(try message.jsonString())
    }

    // MARK: Test helpers

    func nextIncoming(timeout: Duration = .seconds(5)) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while incoming.isEmpty {
            if ContinuousClock.now >= deadline {
                throw OBSTestFailure.timeout("a message from the client")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return incoming.removeFirst()
    }

    func incomingMessages(count: Int, timeout: Duration = .seconds(5)) async throws -> [String] {
        let deadline = ContinuousClock.now + timeout
        while incoming.count < count {
            if ContinuousClock.now >= deadline {
                throw OBSTestFailure.timeout("\(count) messages from the client")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let messages = Array(incoming.prefix(count))
        incoming.removeFirst(count)
        return messages
    }
}

struct FakeOBSTransport: OBSTransport {
    let session: FakeOBSSession

    func connect() async throws {
        await session.registerConnection()
    }

    func send(_ text: String) async throws {
        await session.write(text)
    }

    func receive() async throws -> OBSTransportEvent {
        await session.read()
    }

    func close() async {
        await session.closeFromClient()
    }
}

/// Hands out one scripted session per connection attempt, so reconnect tests can
/// observe distinct WebSocket sessions.
actor FakeSessionProvider {
    private var sessions: [FakeOBSSession]
    private(set) var factoryCalls = 0

    init(_ sessions: [FakeOBSSession]) {
        self.sessions = sessions
    }

    func next() throws -> FakeOBSSession {
        factoryCalls += 1
        guard !sessions.isEmpty else {
            throw OBSTestFailure.unexpected("No scripted session left for this connection.")
        }
        return sessions.removeFirst()
    }
}

func fakeFactory(for session: FakeOBSSession) -> OBSTransportFactory {
    { _ in FakeOBSTransport(session: session) }
}

func fakeFactory(for provider: FakeSessionProvider) -> OBSTransportFactory {
    { _ in FakeOBSTransport(session: try await provider.next()) }
}

// MARK: - Message helpers

struct DecodedRequest {
    let type: String
    let id: String
    let data: OBSJSONValue?
}

func decodeRequest(_ text: String) throws -> DecodedRequest {
    let json = try OBSJSONValue.parse(text)
    guard json["op"]?.intValue == OBSOpCode.request.rawValue,
          let data = json["d"],
          let type = data["requestType"]?.stringValue,
          let id = data["requestId"]?.stringValue
    else {
        throw OBSTestFailure.unexpected("Expected a Request message, got \(text)")
    }
    return DecodedRequest(type: type, id: id, data: data["requestData"])
}

func decodeEnvelope(_ text: String) throws -> (op: Int, data: OBSJSONValue) {
    let json = try OBSJSONValue.parse(text)
    guard let op = json["op"]?.intValue else {
        throw OBSTestFailure.unexpected("Message has no op: \(text)")
    }
    return (op, json["d"] ?? .object([:]))
}

/// Connects, consumes the client's Identify, answers with Identified and returns
/// the Identify data for assertions.
@discardableResult
func connectAndIdentify(
    client: OBSClient,
    session: FakeOBSSession,
    password: String? = nil
) async throws -> OBSJSONValue {
    let connectTask = Task {
        try await client.connect(host: "localhost", port: 4455, password: password)
    }
    let identifyText = try await session.nextIncoming()
    let envelope = try decodeEnvelope(identifyText)
    guard envelope.op == OBSOpCode.identify.rawValue else {
        connectTask.cancel()
        throw OBSTestFailure.unexpected("Expected Identify, got op \(envelope.op)")
    }
    try await session.pushIdentified()
    try await connectTask.value
    return envelope.data
}

func captureError(_ operation: () async throws -> Void) async -> Error? {
    do {
        try await operation()
        return nil
    } catch {
        return error
    }
}

// MARK: - Async stream helpers

func collectEvents(
    _ stream: AsyncStream<OBSEvent>,
    count: Int,
    timeout: Duration = .seconds(3)
) async -> [OBSEvent] {
    await withTaskGroup(of: [OBSEvent].self) { group in
        group.addTask {
            var collected: [OBSEvent] = []
            for await event in stream {
                collected.append(event)
                if collected.count >= count { return collected }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }
        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}

func collectStates(
    _ stream: AsyncStream<OBSConnectionState>,
    until predicate: @escaping @Sendable ([OBSConnectionState]) -> Bool,
    timeout: Duration = .seconds(3)
) async -> [OBSConnectionState] {
    await withTaskGroup(of: [OBSConnectionState].self) { group in
        group.addTask {
            var collected: [OBSConnectionState] = []
            for await state in stream {
                collected.append(state)
                if predicate(collected) { return collected }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }
        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}

func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: () async -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(2))
    }
    return false
}
