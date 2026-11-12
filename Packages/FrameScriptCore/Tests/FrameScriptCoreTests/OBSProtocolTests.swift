import CryptoKit
import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Authentication

@Suite("OBS authentication")
struct OBSAuthenticationTests {
    // Vector computed independently (Python hashlib) from the protocol document's
    // example challenge and salt:
    //   password = "supersecretpassword"
    //   salt     = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
    //   challenge= "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="
    // The document's Identify example uses a different challenge, so its
    // "Dj6c..." value is intentionally not asserted here.
    @Test func matchesIndependentlyComputedSpecVector() {
        let password = "supersecretpassword"
        let salt = "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI="
        let challenge = "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="

        let actual = OBSAuthentication.authenticationString(
            password: password,
            challenge: challenge,
            salt: salt
        )

        #expect(actual == "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    @Test func matchesFormulaRecomputedInTheTest() {
        let password = "correct horse battery staple"
        let salt = "c2FsdHktdmVjdG9yLTIwMjY="
        let challenge = "Y2hhbGxlbmdlLXZlY3Rvci0yMDI2"

        // Deliberately reimplement the formula with CryptoKit instead of calling
        // the production helper, so a bug there cannot hide behind itself.
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8)))
            .base64EncodedString()
        let expected = Data(SHA256.hash(data: Data((secret + challenge).utf8)))
            .base64EncodedString()

        let actual = OBSAuthentication.authenticationString(
            password: password,
            challenge: challenge,
            salt: salt
        )

        #expect(actual == expected)
        #expect(actual == "zlwpvm/p6oHyWI4ed8c3wodn9Xvo6tk8msPbxejpdhQ=")
    }

    @Test func emptyPasswordStillProducesDeterministicString() {
        let first = OBSAuthentication.authenticationString(
            password: "", challenge: "challenge", salt: "salt"
        )
        let second = OBSAuthentication.authenticationString(
            password: "", challenge: "challenge", salt: "salt"
        )
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}

// MARK: - JSON

@Suite("OBS JSON value")
struct OBSJSONValueTests {
    @Test func roundTripsMixedJSON() throws {
        let text = #"{"active":true,"count":3,"duration":1.5,"name":"Camera","list":[1,null,"x"],"nested":{"k":"v"}}"#
        let value = try OBSJSONValue.parse(text)

        #expect(value["active"]?.boolValue == true)
        #expect(value["count"]?.intValue == 3)
        #expect(value["duration"]?.doubleValue == 1.5)
        #expect(value["name"]?.stringValue == "Camera")
        #expect(value["list"]?.arrayValue?.count == 3)
        #expect(value["list"]?.arrayValue?[1] == .null)
        #expect(value["nested"]?["k"]?.stringValue == "v")

        let encoded = try value.jsonString()
        #expect(try OBSJSONValue.parse(encoded) == value)
    }

    @Test func encodesIntegralNumbersWithoutDecimalPoint() throws {
        let value = OBSJSONValue.object([
            "port": .number(4455),
            "ratio": .number(0.5),
        ])
        let encoded = try value.jsonString()
        #expect(encoded.contains("\"port\":4455"))
        #expect(encoded.contains("\"ratio\":0.5"))
    }

    @Test func reportsBoundedIntegerAccess() {
        #expect(OBSJSONValue.number(2.0).intValue == 2)
        #expect(OBSJSONValue.number(2.5).intValue == nil)
        #expect(OBSJSONValue.string("2").intValue == nil)
        #expect(OBSJSONValue.number(.infinity).intValue == nil)
    }
}

// MARK: - Codec

@Suite("OBS message codec")
struct OBSMessageCodecTests {
    @Test func decodesHelloWithAuthentication() throws {
        let text = #"""
        {"op":0,"d":{"obsStudioVersion":"30.2.2","obsWebSocketVersion":"5.5.2","rpcVersion":1,"authentication":{"challenge":"c1","salt":"s1"}}}
        """#
        let message = try OBSMessageCodec.decode(text)

        #expect(message == .hello(OBSHello(
            obsStudioVersion: "30.2.2",
            obsWebSocketVersion: "5.5.2",
            rpcVersion: 1,
            authentication: OBSAuthenticationChallenge(challenge: "c1", salt: "s1")
        )))
    }

    @Test func decodesHelloWithoutAuthentication() throws {
        let text = #"{"op":0,"d":{"obsStudioVersion":"31.0.0","obsWebSocketVersion":"5.7.0","rpcVersion":1}}"#
        let message = try OBSMessageCodec.decode(text)

        guard case .hello(let hello) = message else {
            Issue.record("Expected Hello")
            return
        }
        #expect(hello.authentication == nil)
        #expect(hello.rpcVersion == 1)
        #expect(hello.obsStudioVersion == "31.0.0")
    }

    @Test func decodesIdentified() throws {
        let message = try OBSMessageCodec.decode(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#)
        #expect(message == .identified(OBSIdentified(negotiatedRpcVersion: 1)))
    }

    @Test func decodesSuccessfulRequestResponse() throws {
        let text = #"""
        {"op":7,"d":{"requestType":"StopRecord","requestId":"req-9","requestStatus":{"result":true,"code":100},"responseData":{"outputPath":"/tmp/take.mkv"}}}
        """#
        let message = try OBSMessageCodec.decode(text)

        guard case .requestResponse(let response) = message else {
            Issue.record("Expected RequestResponse")
            return
        }
        #expect(response.requestType == "StopRecord")
        #expect(response.requestID == "req-9")
        #expect(response.status == OBSRequestStatus(result: true, code: 100, comment: nil))
        #expect(response.responseData?["outputPath"]?.stringValue == "/tmp/take.mkv")
    }

    @Test func decodesFailedRequestResponseWithComment() throws {
        let text = #"""
        {"op":7,"d":{"requestType":"SetCurrentProgramScene","requestId":"req-1","requestStatus":{"result":false,"code":608,"comment":"Parameter: sceneName"}}}
        """#
        let message = try OBSMessageCodec.decode(text)

        guard case .requestResponse(let response) = message else {
            Issue.record("Expected RequestResponse")
            return
        }
        #expect(response.status.result == false)
        #expect(response.status.code == 608)
        #expect(response.status.comment == "Parameter: sceneName")
        #expect(response.responseData == nil)
    }

    @Test func decodesRequestBatchResponse() throws {
        let text = #"""
        {"op":9,"d":{"requestId":"batch-1","results":[{"requestType":"GetVersion","requestId":"r1","requestStatus":{"result":true,"code":100},"responseData":{"rpcVersion":1}},{"requestType":"StartRecord","requestId":"r2","requestStatus":{"result":false,"code":500,"comment":"busy"}}]}}
        """#
        let message = try OBSMessageCodec.decode(text)

        guard case .requestBatchResponse(let requestID, let results) = message else {
            Issue.record("Expected RequestBatchResponse")
            return
        }
        #expect(requestID == "batch-1")
        #expect(results.count == 2)
        #expect(results[0].status.result == true)
        #expect(results[1].status.code == 500)
        #expect(results[1].status.comment == "busy")
    }

    @Test func decodesEventEnvelope() throws {
        let text = #"""
        {"op":5,"d":{"eventType":"CurrentProgramSceneChanged","eventIntent":4,"eventData":{"sceneName":"Camera"}}}
        """#
        let message = try OBSMessageCodec.decode(text)
        #expect(message == .event(
            eventType: "CurrentProgramSceneChanged",
            eventIntent: 4,
            eventData: .object(["sceneName": .string("Camera")])
        ))
    }

    @Test func preservesUnknownOpcodes() throws {
        let message = try OBSMessageCodec.decode(#"{"op":42,"d":{"hello":"world"}}"#)
        #expect(message == .unknown(op: 42, data: .object(["hello": .string("world")])))
    }

    @Test func rejectsMissingOpcode() {
        #expect(throws: OBSProtocolError.self) {
            try OBSMessageCodec.decode(#"{"d":{}}"#)
        }
    }

    @Test func rejectsHelloWithoutRpcVersion() {
        #expect(throws: OBSProtocolError.self) {
            try OBSMessageCodec.decode(#"{"op":0,"d":{"obsStudioVersion":"30"}}"#)
        }
    }

    @Test func rejectsRequestResponseWithoutStatus() {
        #expect(throws: OBSProtocolError.self) {
            try OBSMessageCodec.decode(
                #"{"op":7,"d":{"requestType":"GetVersion","requestId":"r1"}}"#
            )
        }
    }

    @Test func encodesIdentifyWithoutAuthentication() throws {
        let text = try OBSMessageCodec.encodeIdentify()
        let envelope = try decodeEnvelope(text)

        #expect(envelope.op == OBSOpCode.identify.rawValue)
        #expect(envelope.data["rpcVersion"]?.intValue == 1)
        #expect(envelope.data["eventSubscriptions"]?.intValue == 4095)
        #expect(envelope.data["authentication"] == nil)
    }

    @Test func encodesIdentifyWithAuthenticationAndSubscriptions() throws {
        let text = try OBSMessageCodec.encodeIdentify(
            authentication: "auth-value",
            eventSubscriptions: 33
        )
        let envelope = try decodeEnvelope(text)

        #expect(envelope.data["authentication"]?.stringValue == "auth-value")
        #expect(envelope.data["eventSubscriptions"]?.intValue == 33)
    }

    @Test func encodesReidentify() throws {
        let text = try OBSMessageCodec.encodeReidentify(eventSubscriptions: 1 << 6)
        let envelope = try decodeEnvelope(text)

        #expect(envelope.op == OBSOpCode.reidentify.rawValue)
        #expect(envelope.data == .object(["eventSubscriptions": .number(64)]))
    }

    @Test func encodesRequestWithAndWithoutData() throws {
        let withData = try decodeEnvelope(try OBSMessageCodec.encodeRequest(
            requestType: "SetCurrentProgramScene",
            requestID: "req-1",
            requestData: ["sceneName": .string("Camera")]
        ))
        #expect(withData.op == OBSOpCode.request.rawValue)
        #expect(withData.data["requestType"]?.stringValue == "SetCurrentProgramScene")
        #expect(withData.data["requestId"]?.stringValue == "req-1")
        #expect(withData.data["requestData"]?["sceneName"]?.stringValue == "Camera")

        let withoutData = try decodeEnvelope(try OBSMessageCodec.encodeRequest(
            requestType: "StartRecord",
            requestID: "req-2"
        ))
        #expect(withoutData.data["requestData"] == nil)
    }

    @Test func encodesRequestBatch() throws {
        let text = try OBSMessageCodec.encodeRequestBatch(
            requestID: "batch-1",
            requests: [
                OBSBatchRequest(requestType: "GetVersion", requestID: "r1"),
                OBSBatchRequest(
                    requestType: "SetCurrentProgramScene",
                    requestID: "r2",
                    requestData: ["sceneName": .string("Camera")]
                ),
            ],
            haltOnFailure: true
        )
        let envelope = try decodeEnvelope(text)

        #expect(envelope.op == OBSOpCode.requestBatch.rawValue)
        #expect(envelope.data["requestId"]?.stringValue == "batch-1")
        #expect(envelope.data["haltOnFailure"]?.boolValue == true)
        let requests = try #require(envelope.data["requests"]?.arrayValue)
        #expect(requests.count == 2)
        #expect(requests[1]["requestData"]?["sceneName"]?.stringValue == "Camera")
    }
}

// MARK: - Events

@Suite("OBS events")
struct OBSEventTests {
    @Test func decodesRecordStarted() {
        let event = OBSEventDecoder.decode(
            eventType: "RecordStateChanged",
            eventIntent: 64,
            eventData: .object([
                "outputActive": .bool(true),
                "outputState": .string("OBS_WEBSOCKET_OUTPUT_STARTED"),
            ])
        )

        #expect(event == .recordStateChanged(OBSRecordStateChanged(
            outputActive: true,
            outputState: .started,
            outputPath: nil
        )))
        #expect(event.eventType == "RecordStateChanged")
    }

    @Test func decodesRecordStoppedWithOutputPath() {
        let event = OBSEventDecoder.decode(
            eventType: "RecordStateChanged",
            eventIntent: 64,
            eventData: .object([
                "outputActive": .bool(false),
                "outputState": .string("OBS_WEBSOCKET_OUTPUT_STOPPED"),
                "outputPath": .string("/Movies/take-01.mkv"),
            ])
        )

        #expect(event == .recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: "/Movies/take-01.mkv"
        )))
    }

    @Test func decodesRecordStoppedWithNullPath() {
        let event = OBSEventDecoder.decode(
            eventType: "RecordStateChanged",
            eventIntent: 64,
            eventData: .object([
                "outputActive": .bool(false),
                "outputState": .string("OBS_WEBSOCKET_OUTPUT_STOPPED"),
                "outputPath": .null,
            ])
        )

        guard case .recordStateChanged(let payload) = event else {
            Issue.record("Expected RecordStateChanged")
            return
        }
        #expect(payload.outputPath == nil)
    }

    @Test func decodesCurrentProgramSceneChanged() {
        let event = OBSEventDecoder.decode(
            eventType: "CurrentProgramSceneChanged",
            eventIntent: 4,
            eventData: .object([
                "sceneName": .string("Gameplay"),
                "sceneUuid": .string("scene-uuid-1"),
            ])
        )

        #expect(event == .currentProgramSceneChanged(OBSCurrentProgramSceneChanged(
            sceneName: "Gameplay",
            sceneUuid: "scene-uuid-1"
        )))
    }

    @Test func decodesExitStarted() {
        let event = OBSEventDecoder.decode(
            eventType: "ExitStarted",
            eventIntent: 1,
            eventData: .object([:])
        )
        #expect(event == .exitStarted)
    }

    @Test func keepsUnknownEvents() {
        let data = OBSJSONValue.object(["vendorName": .string("acme")])
        let event = OBSEventDecoder.decode(
            eventType: "VendorEvent",
            eventIntent: 512,
            eventData: data
        )

        #expect(event == .other(OBSOtherEvent(
            eventType: "VendorEvent",
            eventIntent: 512,
            eventData: data
        )))
    }

    @Test func malformedKnownEventFallsBackToOther() {
        let event = OBSEventDecoder.decode(
            eventType: "RecordStateChanged",
            eventIntent: 64,
            eventData: .object(["outputState": .string("started")])
        )
        guard case .other(let other) = event else {
            Issue.record("Expected fallback .other")
            return
        }
        #expect(other.eventType == "RecordStateChanged")
    }

    @Test func outputStateConstantsMatchTheSpec() {
        #expect(OBSOutputState.started.rawValue == "OBS_WEBSOCKET_OUTPUT_STARTED")
        #expect(OBSOutputState.paused.rawValue == "OBS_WEBSOCKET_OUTPUT_PAUSED")
        #expect(OBSOutputState.stopped.rawValue == "OBS_WEBSOCKET_OUTPUT_STOPPED")
        #expect(OBSOutputState(rawValue: "FUTURE_STATE").rawValue == "FUTURE_STATE")
    }
}

// MARK: - Subscriptions

@Suite("OBS event subscriptions")
struct OBSEventSubscriptionsTests {
    @Test func allMatchesTheSpecBitmask() {
        // General | Config | Scenes | Inputs | Transitions | Filters | Outputs |
        // SceneItems | MediaInputs | Vendors | Ui | Canvases = 4095.
        #expect(OBSEventSubscriptions.all.rawValue == 4095)
        #expect(OBSEventSubscriptions.scenes.rawValue == 1 << 2)
        #expect(OBSEventSubscriptions.outputs.rawValue == 1 << 6)
    }

    @Test func highVolumeIsNotPartOfAll() {
        #expect(OBSEventSubscriptions.all.isDisjoint(with: .highVolume))
        #expect(OBSEventSubscriptions.highVolume.rawValue == 983_040)
        #expect(OBSEventSubscriptions.inputVolumeMeters.rawValue == 1 << 16)
        #expect(OBSEventSubscriptions.sceneItemTransformChanged.rawValue == 1 << 19)
    }
}

// MARK: - Models

@Suite("OBS response models")
struct OBSModelTests {
    @Test func decodesGetVersion() throws {
        let json = try OBSJSONValue.parse(#"""
        {"obsVersion":"31.0.1","obsWebSocketVersion":"5.7.0","rpcVersion":1,"availableRequests":["GetVersion","GetRecordStatus"],"supportedImageFormats":["jpg","png"],"platform":"macos","platformDescription":"macOS 14.0"}
        """#)
        let version = try OBSVersionInfo(json: json)

        #expect(version.obsVersion == "31.0.1")
        #expect(version.rpcVersion == 1)
        #expect(version.availableRequests == ["GetVersion", "GetRecordStatus"])
        #expect(version.supports("GetVersion"))
        #expect(!version.supports("StartRecord"))
        #expect(version.platform == "macos")
    }

    @Test func getVersionRequiresRpcVersion() {
        #expect(throws: OBSProtocolError.self) {
            try OBSVersionInfo(json: .object(["obsVersion": .string("31.0.0")]))
        }
    }

    @Test func decodesRecordStatus() throws {
        let json = try OBSJSONValue.parse(#"""
        {"outputActive":true,"outputPaused":false,"outputTimecode":"00:01:02.500","outputDuration":62500,"outputBytes":1048576}
        """#)
        let status = try OBSRecordStatus(json: json)

        #expect(status.outputActive == true)
        #expect(status.outputPaused == false)
        #expect(status.outputTimecode == "00:01:02.500")
        #expect(status.outputDuration == 62_500)
        #expect(status.outputBytes == 1_048_576)
    }

    @Test func decodesSceneList() throws {
        let json = try OBSJSONValue.parse(#"""
        {"currentProgramSceneName":"Camera","currentProgramSceneUuid":"u1","currentPreviewSceneName":null,"currentPreviewSceneUuid":null,"scenes":[{"sceneName":"Camera","sceneIndex":0,"sceneUuid":"u1"},{"sceneName":"Gameplay","sceneIndex":1,"sceneUuid":"u2"}]}
        """#)
        let list = try OBSSceneList(json: json)

        #expect(list.currentProgramSceneName == "Camera")
        #expect(list.currentPreviewSceneName == nil)
        #expect(list.scenes.count == 2)
        #expect(list.sceneNames == ["Camera", "Gameplay"])
        #expect(list.scenes[1].index == 1)
        #expect(list.scenes[1].uuid == "u2")
    }

    @Test func decodesProgramSceneWithCurrentField() throws {
        let scene = try OBSProgramScene(json: .object([
            "sceneName": .string("Camera"),
            "sceneUuid": .string("u1"),
        ]))
        #expect(scene.name == "Camera")
        #expect(scene.uuid == "u1")
    }

    @Test func decodesProgramSceneWithDeprecatedField() throws {
        let scene = try OBSProgramScene(json: .object([
            "currentProgramSceneName": .string("Legacy"),
            "currentProgramSceneUuid": .string("u-old"),
        ]))
        #expect(scene.name == "Legacy")
        #expect(scene.uuid == "u-old")
    }
}

// MARK: - Reconnect policy

@Suite("OBS reconnect policy")
struct OBSReconnectPolicyTests {
    @Test func appliesExponentialBackoffUpToMaxDelay() {
        let policy = OBSReconnectPolicy(
            isEnabled: true,
            initialDelay: .seconds(1),
            multiplier: 2,
            maxDelay: .seconds(10),
            maxAttempts: nil
        )

        #expect(policy.delay(forAttempt: 1) == .seconds(1))
        #expect(policy.delay(forAttempt: 2) == .seconds(2))
        #expect(policy.delay(forAttempt: 3) == .seconds(4))
        #expect(policy.delay(forAttempt: 4) == .seconds(8))
        #expect(policy.delay(forAttempt: 5) == .seconds(10))
        #expect(policy.delay(forAttempt: 50) == .seconds(10))
    }

    @Test func treatsAttemptZeroAsFirstRetry() {
        let policy = OBSReconnectPolicy(
            isEnabled: true,
            initialDelay: .milliseconds(250),
            multiplier: 3,
            maxDelay: .seconds(1)
        )
        #expect(policy.delay(forAttempt: 0) == .milliseconds(250))
        #expect(policy.delay(forAttempt: 2) == .milliseconds(750))
        #expect(policy.delay(forAttempt: 3) == .seconds(1))
    }

    @Test func disabledPolicyHasNoDelay() {
        #expect(OBSReconnectPolicy.disabled.delay(forAttempt: 1) == .zero)
    }
}

// MARK: - Config and errors

@Suite("OBS configuration and errors")
struct OBSConfigurationTests {
    @Test func buildsWebSocketURL() {
        let config = OBSConnectionConfig(host: "127.0.0.1", port: 4455)
        #expect(config.url?.absoluteString == "ws://127.0.0.1:4455")
    }

    @Test func defaultsUsePort4455() {
        #expect(OBSConnectionConfig.defaultPort == 4455)
        #expect(OBSConnectionConfig().port == 4455)
    }

    @Test func retryabilityMatchesErrorKind() {
        #expect(OBSError.obsNotRunning(host: "localhost", port: 4455).isRetryable)
        #expect(OBSError.connectionTimeout(.seconds(1)).isRetryable)
        #expect(OBSError.transportClosed(code: 1006, reason: nil).isRetryable)
        #expect(!OBSError.authenticationFailed.isRetryable)
        #expect(!OBSError.authenticationRequired.isRetryable)
        #expect(!OBSError.requestTimeout(requestType: "GetVersion", after: .seconds(1)).isRetryable)
    }

    @Test func requestFailureDescribesStatusCodeAndComment() {
        let error = OBSError.requestFailed(
            requestType: "SetCurrentProgramScene",
            statusCode: 608,
            comment: "Parameter: sceneName"
        )
        let description = error.localizedDescription
        #expect(description.contains("SetCurrentProgramScene"))
        #expect(description.contains("608"))
        #expect(description.contains("Parameter: sceneName"))
    }
}
