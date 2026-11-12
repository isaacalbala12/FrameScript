import Foundation

/// obs-websocket v5 WebSocket opcodes.
public enum OBSOpCode: Int, Sendable, CaseIterable {
    case hello = 0
    case identify = 1
    case identified = 2
    case reidentify = 3
    case event = 5
    case request = 6
    case requestResponse = 7
    case requestBatch = 8
    case requestBatchResponse = 9
}

/// Close codes obs-websocket uses on top of the standard WebSocket codes.
public enum OBSWebSocketCloseCode {
    public static let dontClose = 0
    public static let unknownReason = 4000
    public static let messageDecodeError = 4002
    public static let missingDataField = 4003
    public static let invalidDataFieldType = 4004
    public static let invalidDataFieldValue = 4005
    public static let unknownOpCode = 4006
    public static let notIdentified = 4007
    public static let alreadyIdentified = 4008
    public static let authenticationFailed = 4009
    public static let unsupportedRPCVersion = 4010
    public static let sessionInvalidated = 4011
    public static let unsupportedFeature = 4012
}

/// The authentication challenge sent in `Hello` when the server requires a password.
public struct OBSAuthenticationChallenge: Sendable, Equatable {
    public let challenge: String
    public let salt: String

    public init(challenge: String, salt: String) {
        self.challenge = challenge
        self.salt = salt
    }
}

/// OpCode 0, sent by the server immediately after the WebSocket upgrade.
public struct OBSHello: Sendable, Equatable {
    public let obsStudioVersion: String?
    public let obsWebSocketVersion: String?
    public let rpcVersion: Int
    public let authentication: OBSAuthenticationChallenge?

    public init(
        obsStudioVersion: String?,
        obsWebSocketVersion: String?,
        rpcVersion: Int,
        authentication: OBSAuthenticationChallenge?
    ) {
        self.obsStudioVersion = obsStudioVersion
        self.obsWebSocketVersion = obsWebSocketVersion
        self.rpcVersion = rpcVersion
        self.authentication = authentication
    }
}

/// OpCode 2, confirming that the client is identified and may use the session.
public struct OBSIdentified: Sendable, Equatable {
    public let negotiatedRpcVersion: Int

    public init(negotiatedRpcVersion: Int) {
        self.negotiatedRpcVersion = negotiatedRpcVersion
    }
}

/// The `requestStatus` object of a `RequestResponse`.
public struct OBSRequestStatus: Sendable, Equatable {
    public let result: Bool
    public let code: Int
    public let comment: String?

    public init(result: Bool, code: Int, comment: String?) {
        self.result = result
        self.code = code
        self.comment = comment
    }
}

/// OpCode 7, the server's answer to one request.
public struct OBSRequestResponse: Sendable, Equatable {
    public let requestType: String
    public let requestID: String
    public let status: OBSRequestStatus
    public let responseData: OBSJSONValue?

    public init(
        requestType: String,
        requestID: String,
        status: OBSRequestStatus,
        responseData: OBSJSONValue?
    ) {
        self.requestType = requestType
        self.requestID = requestID
        self.status = status
        self.responseData = responseData
    }
}

/// A request to send inside a `RequestBatch`.
public struct OBSBatchRequest: Sendable, Equatable {
    public let requestType: String
    public let requestID: String?
    public let requestData: [String: OBSJSONValue]?

    public init(
        requestType: String,
        requestID: String? = nil,
        requestData: [String: OBSJSONValue]? = nil
    ) {
        self.requestType = requestType
        self.requestID = requestID
        self.requestData = requestData
    }
}

/// A decoded message received from the server.
///
/// Opcodes that only travel from client to server are surfaced as `.unknown`
/// so a test or a future server extension can still inspect them.
public enum OBSIncomingMessage: Sendable, Equatable {
    case hello(OBSHello)
    case identified(OBSIdentified)
    case event(eventType: String, eventIntent: Int, eventData: OBSJSONValue)
    case requestResponse(OBSRequestResponse)
    case requestBatchResponse(requestID: String, results: [OBSRequestResponse])
    case unknown(op: Int, data: OBSJSONValue)
}

/// Encodes and decodes the JSON framing of obs-websocket v5.
///
/// This type is pure logic: it never touches a socket and is safe to test directly.
public enum OBSMessageCodec {
    /// The only RPC version this client speaks.
    public static let rpcVersion = 1

    // MARK: Encoding

    public static func encodeIdentify(
        authentication: String? = nil,
        eventSubscriptions: Int = OBSEventSubscriptions.all.rawValue,
        rpcVersion: Int = OBSMessageCodec.rpcVersion
    ) throws -> String {
        var data: [String: OBSJSONValue] = [
            "rpcVersion": .number(Double(rpcVersion)),
            "eventSubscriptions": .number(Double(eventSubscriptions)),
        ]
        if let authentication {
            data["authentication"] = .string(authentication)
        }
        return try encode(op: .identify, data: .object(data))
    }

    public static func encodeReidentify(
        eventSubscriptions: Int = OBSEventSubscriptions.all.rawValue
    ) throws -> String {
        let data: [String: OBSJSONValue] = [
            "eventSubscriptions": .number(Double(eventSubscriptions)),
        ]
        return try encode(op: .reidentify, data: .object(data))
    }

    public static func encodeRequest(
        requestType: String,
        requestID: String,
        requestData: [String: OBSJSONValue]? = nil
    ) throws -> String {
        var data: [String: OBSJSONValue] = [
            "requestType": .string(requestType),
            "requestId": .string(requestID),
        ]
        if let requestData, !requestData.isEmpty {
            data["requestData"] = .object(requestData)
        }
        return try encode(op: .request, data: .object(data))
    }

    public static func encodeRequestBatch(
        requestID: String,
        requests: [OBSBatchRequest],
        haltOnFailure: Bool = false,
        executionType: Int = 0
    ) throws -> String {
        var data: [String: OBSJSONValue] = [
            "requestId": .string(requestID),
            "haltOnFailure": .bool(haltOnFailure),
            "requests": .array(requests.map { request in
                var fields: [String: OBSJSONValue] = [
                    "requestType": .string(request.requestType),
                ]
                if let requestID = request.requestID {
                    fields["requestId"] = .string(requestID)
                }
                if let requestData = request.requestData, !requestData.isEmpty {
                    fields["requestData"] = .object(requestData)
                }
                return .object(fields)
            }),
        ]
        if executionType != 0 {
            data["executionType"] = .number(Double(executionType))
        }
        return try encode(op: .requestBatch, data: .object(data))
    }

    // MARK: Decoding

    public static func decode(_ text: String) throws -> OBSIncomingMessage {
        let json = try OBSJSONValue.parse(text)
        guard let opValue = json["op"]?.intValue else {
            throw OBSProtocolError.malformedMessage("The message is missing an integer `op`.")
        }
        let data = json["d"] ?? .object([:])
        guard let op = OBSOpCode(rawValue: opValue) else {
            return .unknown(op: opValue, data: data)
        }

        switch op {
        case .hello:
            return .hello(try decodeHello(data))
        case .identified:
            return .identified(try decodeIdentified(data))
        case .event:
            return .event(
                eventType: try requireString("eventType", in: data, message: "Event"),
                eventIntent: data["eventIntent"]?.intValue ?? 0,
                eventData: data["eventData"] ?? .object([:])
            )
        case .requestResponse:
            return .requestResponse(try decodeRequestResponse(data))
        case .requestBatchResponse:
            guard let requestID = data["requestId"]?.stringValue else {
                throw OBSProtocolError.malformedMessage(
                    "RequestBatchResponse is missing `requestId`."
                )
            }
            guard let resultValues = data["results"]?.arrayValue else {
                throw OBSProtocolError.malformedMessage(
                    "RequestBatchResponse is missing `results`."
                )
            }
            let results = try resultValues.map { value -> OBSRequestResponse in
                guard let object = value.objectValue else {
                    throw OBSProtocolError.malformedMessage(
                        "RequestBatchResponse contains a non-object result."
                    )
                }
                return try decodeRequestResponse(.object(object))
            }
            return .requestBatchResponse(requestID: requestID, results: results)
        case .identify, .reidentify, .request, .requestBatch:
            return .unknown(op: op.rawValue, data: data)
        }
    }

    // MARK: Private

    private struct OBSEnvelope: Encodable {
        let op: Int
        let d: OBSJSONValue
    }

    private static func encode(op: OBSOpCode, data: OBSJSONValue) throws -> String {
        let envelope = OBSEnvelope(op: op.rawValue, d: data)
        do {
            let encoded = try JSONEncoder().encode(envelope)
            guard let text = String(data: encoded, encoding: .utf8) else {
                throw OBSProtocolError.encodingFailed("The encoded message was not valid UTF-8.")
            }
            return text
        } catch let error as OBSProtocolError {
            throw error
        } catch {
            throw OBSProtocolError.encodingFailed(String(describing: error))
        }
    }

    private static func decodeHello(_ data: OBSJSONValue) throws -> OBSHello {
        guard let rpcVersion = data["rpcVersion"]?.intValue else {
            throw OBSProtocolError.malformedMessage("Hello is missing `rpcVersion`.")
        }
        let authentication: OBSAuthenticationChallenge?
        if let authenticationValue = data["authentication"] {
            guard let object = authenticationValue.objectValue,
                  let challenge = object["challenge"]?.stringValue,
                  let salt = object["salt"]?.stringValue
            else {
                throw OBSProtocolError.malformedMessage(
                    "Hello has an invalid `authentication` object."
                )
            }
            authentication = OBSAuthenticationChallenge(challenge: challenge, salt: salt)
        } else {
            authentication = nil
        }
        return OBSHello(
            obsStudioVersion: data["obsStudioVersion"]?.stringValue,
            obsWebSocketVersion: data["obsWebSocketVersion"]?.stringValue,
            rpcVersion: rpcVersion,
            authentication: authentication
        )
    }

    private static func decodeIdentified(_ data: OBSJSONValue) throws -> OBSIdentified {
        guard let negotiated = data["negotiatedRpcVersion"]?.intValue else {
            throw OBSProtocolError.malformedMessage(
                "Identified is missing `negotiatedRpcVersion`."
            )
        }
        return OBSIdentified(negotiatedRpcVersion: negotiated)
    }

    private static func decodeRequestResponse(_ data: OBSJSONValue) throws -> OBSRequestResponse {
        let requestType = try requireString(
            "requestType", in: data, message: "RequestResponse"
        )
        let requestID = try requireString("requestId", in: data, message: "RequestResponse")
        guard let statusObject = data["requestStatus"]?.objectValue,
              let result = statusObject["result"]?.boolValue,
              let code = statusObject["code"]?.intValue
        else {
            throw OBSProtocolError.malformedMessage(
                "RequestResponse is missing a valid `requestStatus`."
            )
        }
        let status = OBSRequestStatus(
            result: result,
            code: code,
            comment: statusObject["comment"]?.stringValue
        )
        let responseData = data["responseData"] == .null ? nil : data["responseData"]
        return OBSRequestResponse(
            requestType: requestType,
            requestID: requestID,
            status: status,
            responseData: responseData
        )
    }

    private static func requireString(
        _ key: String,
        in data: OBSJSONValue,
        message: String
    ) throws -> String {
        guard let value = data[key]?.stringValue else {
            throw OBSProtocolError.malformedMessage(
                "\(message) is missing the string field `\(key)`."
            )
        }
        return value
    }
}
