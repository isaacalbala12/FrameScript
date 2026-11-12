import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Helpers

@discardableResult
private func expectRequest(
    client: OBSClient,
    session: FakeOBSSession,
    type: String,
    responseData: [String: OBSJSONValue]? = nil,
    operation: @escaping @Sendable () async throws -> Void
) async throws -> DecodedRequest {
    let task = Task { try await operation() }
    let request = try decodeRequest(try await session.nextIncoming())
    #expect(request.type == type)
    try await session.pushResponse(
        requestType: type,
        requestID: request.id,
        responseData: responseData
    )
    try await task.value
    return request
}

private func makeClient(
    session: FakeOBSSession,
    connectTimeout: Duration = .seconds(1),
    requestTimeout: Duration = .seconds(1),
    reconnect: OBSReconnectPolicy = .disabled
) -> OBSClient {
    OBSClient(
        config: OBSConnectionConfig(
            connectTimeout: connectTimeout,
            requestTimeout: requestTimeout,
            reconnect: reconnect
        ),
        transportFactory: fakeFactory(for: session)
    )
}

private func connect(
    _ client: OBSClient,
    to session: FakeOBSSession,
    password: String? = nil
) async throws -> OBSJSONValue {
    try await connectAndIdentify(client: client, session: session, password: password)
}

// MARK: - Handshake

@Suite("OBS client handshake")
struct OBSClientHandshakeTests {
    @Test func connectsWithoutAuthenticationAndPublishesState() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        let statesStream = client.connectionStates
        let collector = Task {
            await collectStates(statesStream, until: { states in
                states.contains(where: { $0.isConnected })
            })
        }

        let identify = try await connect(client, to: session)

        #expect(identify["rpcVersion"]?.intValue == 1)
        #expect(identify["authentication"] == nil)
        #expect(identify["eventSubscriptions"]?.intValue == 4095)

        let states = await collector.value
        #expect(states.contains(.connecting))
        #expect(states.last?.isConnected == true)

        let state = await client.connectionState
        let info = state.sessionInfo
        #expect(info?.obsStudioVersion == "30.2.2")
        #expect(info?.obsWebSocketVersion == "5.5.2")
        #expect(info?.rpcVersion == 1)
        #expect(info?.negotiatedRpcVersion == 1)
        #expect(await client.isConnected)

        await client.disconnect()
    }

    @Test func sendsTheSpecAuthenticationString() async throws {
        let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
        let challenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello(
            challenge: challenge,
            salt: salt
        ))
        let client = makeClient(session: session)

        let identify = try await connect(
            client,
            to: session,
            password: "supersecretpassword"
        )

        #expect(identify["authentication"]?.stringValue
            == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")

        await client.disconnect()
    }

    @Test func reportsAuthenticationRequiredWhenNoPasswordIsConfigured() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello(
            challenge: "challenge",
            salt: "salt"
        ))
        let client = makeClient(session: session)

        let error = await captureError {
            try await client.connect(host: "localhost")
        }

        #expect(error as? OBSError == .authenticationRequired)
        let state = await client.connectionState
        guard case .failed(let reason) = state else {
            Issue.record("Expected a failed state, got \(state)")
            return
        }
        #expect(reason == OBSError.authenticationRequired.localizedDescription)
    }

    @Test func reportsAuthenticationFailedOnCloseCode4009() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello(
            challenge: "challenge",
            salt: "salt"
        ))
        let client = makeClient(session: session)

        let connectTask = Task {
            try await client.connect(host: "localhost", password: "wrong-password")
        }
        let identify = try decodeEnvelope(try await session.nextIncoming())
        #expect(identify.op == OBSOpCode.identify.rawValue)
        #expect(identify.data["authentication"]?.stringValue != nil)

        await session.close(
            code: OBSWebSocketCloseCode.authenticationFailed,
            reason: "Authentication failed."
        )

        let error = await captureError { try await connectTask.value }
        #expect(error as? OBSError == .authenticationFailed)
    }

    @Test func mapsConnectionRefusedToObsNotRunning() async {
        let client = OBSClient(transportFactory: { _ in
            throw OBSTransportFailure(
                phase: .connect,
                message: "Connection refused",
                posixErrorCode: Int(POSIXErrorCode.ECONNREFUSED.rawValue)
            )
        })

        let error = await captureError {
            try await client.connect(host: "127.0.0.1", port: 4455)
        }

        #expect(error as? OBSError == .obsNotRunning(host: "127.0.0.1", port: 4455))
    }

    @Test func timesOutWhenHelloNeverArrives() async throws {
        let session = FakeOBSSession(helloText: nil)
        let client = makeClient(session: session, connectTimeout: .milliseconds(50))

        let error = await captureError {
            try await client.connect(host: "localhost")
        }

        #expect(error as? OBSError == .connectionTimeout(.milliseconds(50)))
        let state = await client.connectionState
        #expect(!state.isConnected)

        await client.disconnect()
    }
}

// MARK: - Requests

@Suite("OBS client requests")
struct OBSClientRequestTests {
    @Test func correlatesOutOfOrderResponses() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let versionTask = Task { try await client.getVersion() }
        let versionRequest = try decodeRequest(try await session.nextIncoming())
        #expect(versionRequest.type == "GetVersion")

        let statsTask = Task { try await client.send(requestType: "GetStats") }
        let statsRequest = try decodeRequest(try await session.nextIncoming())
        #expect(statsRequest.type == "GetStats")

        // Answer the newer request first.
        try await session.pushResponse(
            requestType: "GetStats",
            requestID: statsRequest.id,
            responseData: ["cpuUsage": .number(12.5)]
        )
        try await session.pushResponse(
            requestType: "GetVersion",
            requestID: versionRequest.id,
            responseData: [
                "obsVersion": .string("31.0.1"),
                "obsWebSocketVersion": .string("5.7.0"),
                "rpcVersion": .number(1),
            ]
        )

        let version = try await versionTask.value
        let stats = try await statsTask.value

        #expect(version.obsVersion == "31.0.1")
        #expect(stats["cpuUsage"]?.doubleValue == 12.5)

        await client.disconnect()
    }

    @Test func surfacesRequestFailureCodeAndComment() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let task = Task { try await client.startRecord() }
        let request = try decodeRequest(try await session.nextIncoming())
        #expect(request.type == "StartRecord")

        try await session.pushResponse(
            requestType: "StartRecord",
            requestID: request.id,
            result: false,
            code: 500,
            comment: "Recording already running"
        )

        let error = await captureError { try await task.value }
        #expect(error as? OBSError == .requestFailed(
            requestType: "StartRecord",
            statusCode: 500,
            comment: "Recording already running"
        ))

        await client.disconnect()
    }

    @Test func timesOutARequestWithoutAResponse() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(
            session: session,
            requestTimeout: .milliseconds(60)
        )
        try await connect(client, to: session)

        let error = await captureError {
            _ = try await client.send(requestType: "GetStats")
        }

        #expect(error as? OBSError == .requestTimeout(
            requestType: "GetStats",
            after: .milliseconds(60)
        ))

        await client.disconnect()
    }

    @Test func stopRecordReturnsOutputPath() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let task = Task { try await client.stopRecord() }
        let request = try decodeRequest(try await session.nextIncoming())
        #expect(request.type == "StopRecord")

        try await session.pushResponse(
            requestType: "StopRecord",
            requestID: request.id,
            responseData: ["outputPath": .string("/Movies/take-01.mkv")]
        )

        #expect(try await task.value == "/Movies/take-01.mkv")

        await client.disconnect()
    }

    @Test func stopRecordRejectsMissingOutputPath() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let task = Task { try await client.stopRecord() }
        let request = try decodeRequest(try await session.nextIncoming())
        try await session.pushResponse(
            requestType: "StopRecord",
            requestID: request.id
        )

        let error = await captureError { _ = try await task.value }
        guard case .protocolViolation = error as? OBSError else {
            Issue.record("Expected protocolViolation, got \(String(describing: error))")
            return
        }

        await client.disconnect()
    }

    @Test func sendsRecordControlRequests() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        try await expectRequest(
            client: client,
            session: session,
            type: "StartRecord"
        ) { try await client.startRecord() }

        try await expectRequest(
            client: client,
            session: session,
            type: "ToggleRecordPause"
        ) { try await client.toggleRecordPause() }

        try await expectRequest(
            client: client,
            session: session,
            type: "PauseRecord"
        ) { try await client.pauseRecord() }

        try await expectRequest(
            client: client,
            session: session,
            type: "ResumeRecord"
        ) { try await client.resumeRecord() }

        await client.disconnect()
    }

    @Test func decodesVersionAndRecordStatus() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let versionTask = Task { try await client.getVersion() }
        let versionRequest = try decodeRequest(try await session.nextIncoming())
        #expect(versionRequest.type == "GetVersion")
        try await session.pushResponse(
            requestType: "GetVersion",
            requestID: versionRequest.id,
            responseData: [
                "obsVersion": .string("31.0.1"),
                "obsWebSocketVersion": .string("5.7.0"),
                "rpcVersion": .number(1),
                "availableRequests": .array([.string("GetVersion"), .string("StartRecord")]),
                "supportedImageFormats": .array([.string("jpg")]),
                "platform": .string("macos"),
                "platformDescription": .string("macOS 14.0"),
            ]
        )
        let version = try await versionTask.value
        #expect(version.obsVersion == "31.0.1")
        #expect(version.availableRequests.contains("StartRecord"))
        #expect(version.platform == "macos")

        let statusTask = Task { try await client.getRecordStatus() }
        let statusRequest = try decodeRequest(try await session.nextIncoming())
        #expect(statusRequest.type == "GetRecordStatus")
        try await session.pushResponse(
            requestType: "GetRecordStatus",
            requestID: statusRequest.id,
            responseData: [
                "outputActive": .bool(true),
                "outputPaused": .bool(false),
                "outputTimecode": .string("00:00:10.000"),
                "outputDuration": .number(10_000),
                "outputBytes": .number(524_288),
            ]
        )
        let status = try await statusTask.value
        #expect(status.outputActive)
        #expect(!status.outputPaused)
        #expect(status.outputTimecode == "00:00:10.000")
        #expect(status.outputDuration == 10_000)
        #expect(status.outputBytes == 524_288)

        await client.disconnect()
    }

    @Test func sendsAndDecodesSceneRequests() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let listTask = Task { try await client.getSceneList() }
        let listRequest = try decodeRequest(try await session.nextIncoming())
        #expect(listRequest.type == "GetSceneList")
        try await session.pushResponse(
            requestType: "GetSceneList",
            requestID: listRequest.id,
            responseData: [
                "currentProgramSceneName": .string("Camera"),
                "currentProgramSceneUuid": .string("u1"),
                "scenes": .array([
                    .object([
                        "sceneName": .string("Camera"),
                        "sceneIndex": .number(0),
                        "sceneUuid": .string("u1"),
                    ]),
                    .object([
                        "sceneName": .string("Gameplay"),
                        "sceneIndex": .number(1),
                        "sceneUuid": .string("u2"),
                    ]),
                ]),
            ]
        )
        let list = try await listTask.value
        #expect(list.sceneNames == ["Camera", "Gameplay"])
        #expect(list.currentProgramSceneName == "Camera")

        let currentTask = Task { try await client.getCurrentProgramScene() }
        let currentRequest = try decodeRequest(try await session.nextIncoming())
        #expect(currentRequest.type == "GetCurrentProgramScene")
        try await session.pushResponse(
            requestType: "GetCurrentProgramScene",
            requestID: currentRequest.id,
            responseData: [
                "sceneName": .string("Camera"),
                "sceneUuid": .string("u1"),
            ]
        )
        let current = try await currentTask.value
        #expect(current.name == "Camera")

        let setTask = Task { try await client.setCurrentProgramScene(name: "Gameplay") }
        let setRequest = try decodeRequest(try await session.nextIncoming())
        #expect(setRequest.type == "SetCurrentProgramScene")
        #expect(setRequest.data?["sceneName"]?.stringValue == "Gameplay")
        try await session.pushResponse(
            requestType: "SetCurrentProgramScene",
            requestID: setRequest.id
        )
        try await setTask.value

        await client.disconnect()
    }

    @Test func failsWhenNotConnected() async {
        let client = OBSClient()
        let error = await captureError {
            _ = try await client.getVersion()
        }
        #expect(error as? OBSError == .notConnected)
    }

    @Test func disconnectFailsInFlightRequests() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let task = Task { try await client.send(requestType: "GetStats") }
        _ = try decodeRequest(try await session.nextIncoming())

        await client.disconnect()

        let error = await captureError { _ = try await task.value }
        #expect(error as? OBSError == .disconnected)
    }
}

// MARK: - Events

@Suite("OBS client events")
struct OBSClientEventTests {
    @Test func deliversTypedAndUnknownEvents() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let stream = client.events
        let collector = Task { await collectEvents(stream, count: 4) }

        try await session.pushEvent(
            "RecordStateChanged",
            eventIntent: 64,
            eventData: [
                "outputActive": .bool(false),
                "outputState": .string("OBS_WEBSOCKET_OUTPUT_STOPPED"),
                "outputPath": .string("/Movies/take-02.mkv"),
            ]
        )
        try await session.pushEvent(
            "CurrentProgramSceneChanged",
            eventIntent: 4,
            eventData: [
                "sceneName": .string("Gameplay"),
                "sceneUuid": .string("scene-uuid-1"),
            ]
        )
        try await session.pushEvent("ExitStarted", eventIntent: 1)
        try await session.pushEvent(
            "VendorEvent",
            eventIntent: 512,
            eventData: ["vendorName": .string("acme")]
        )

        let events = await collector.value
        #expect(events.count == 4)
        #expect(events[0] == .recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: "/Movies/take-02.mkv"
        )))
        #expect(events[1] == .currentProgramSceneChanged(OBSCurrentProgramSceneChanged(
            sceneName: "Gameplay",
            sceneUuid: "scene-uuid-1"
        )))
        #expect(events[2] == .exitStarted)
        guard case .other(let vendor) = events[3] else {
            Issue.record("Expected an .other event")
            return
        }
        #expect(vendor.eventType == "VendorEvent")

        await client.disconnect()
    }

    @Test func supportsMultipleEventConsumers() async throws {
        let session = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let client = makeClient(session: session)
        try await connect(client, to: session)

        let firstStream = client.events
        let secondStream = client.events
        let first = Task { await collectEvents(firstStream, count: 1) }
        let second = Task { await collectEvents(secondStream, count: 1) }

        try await session.pushEvent("ExitStarted", eventIntent: 1)

        let firstEvents = await first.value
        let secondEvents = await second.value
        #expect(firstEvents == [.exitStarted])
        #expect(secondEvents == [.exitStarted])

        await client.disconnect()
    }
}

// MARK: - Reconnection

@Suite("OBS client reconnection")
struct OBSClientReconnectTests {
    @Test func reconnectsAfterUnexpectedClose() async throws {
        let firstSession = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let secondSession = FakeOBSSession(helloText: try FakeOBSSession.hello())
        let provider = FakeSessionProvider([firstSession, secondSession])
        let policy = OBSReconnectPolicy(
            isEnabled: true,
            initialDelay: .milliseconds(10),
            multiplier: 1,
            maxDelay: .milliseconds(10),
            maxAttempts: 3
        )
        let client = OBSClient(
            config: OBSConnectionConfig(
                connectTimeout: .seconds(1),
                requestTimeout: .seconds(1),
                reconnect: policy
            ),
            transportFactory: fakeFactory(for: provider)
        )

        let statesStream = client.connectionStates
        let collector = Task {
            await collectStates(statesStream, until: { states in
                states.filter { $0.isConnected }.count >= 2
            })
        }

        let connectTask = Task { try await client.connect(host: "localhost") }
        let firstIdentify = try decodeEnvelope(try await firstSession.nextIncoming())
        #expect(firstIdentify.op == OBSOpCode.identify.rawValue)
        try await firstSession.pushIdentified()
        try await connectTask.value

        await firstSession.close(code: 1006, reason: "Network lost")

        let secondIdentify = try decodeEnvelope(try await secondSession.nextIncoming())
        #expect(secondIdentify.op == OBSOpCode.identify.rawValue)
        try await secondSession.pushIdentified()

        let states = await collector.value
        #expect(states.filter { $0.isConnected }.count == 2)
        #expect(states.contains(.disconnected))
        #expect(await provider.factoryCalls == 2)
        #expect(await client.isConnected)

        await client.disconnect()
    }

    @Test func stopsAfterMaxAttempts() async throws {
        let provider = FakeSessionProvider([])
        let policy = OBSReconnectPolicy(
            isEnabled: true,
            initialDelay: .milliseconds(1),
            multiplier: 1,
            maxDelay: .milliseconds(1),
            maxAttempts: 3
        )
        let client = OBSClient(
            config: OBSConnectionConfig(reconnect: policy),
            transportFactory: fakeFactory(for: provider)
        )

        let error = await captureError {
            try await client.connect(host: "localhost")
        }
        #expect(error is OBSError)

        let reachedExpectedCount = try await waitUntil {
            await provider.factoryCalls >= 4
        }
        #expect(reachedExpectedCount)

        try await Task.sleep(for: .milliseconds(40))
        #expect(await provider.factoryCalls == 4)
        let state = await client.connectionState
        #expect(!state.isConnected)

        await client.disconnect()
    }
}
