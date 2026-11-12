import Foundation

/// The specific state of an OBS output (`ObsOutputState` in the protocol docs).
///
/// A raw-value wrapper instead of a closed enum keeps unknown future states
/// intact and comparable.
public struct OBSOutputState: RawRepresentable, Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let unknown = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_UNKNOWN")
    public static let starting = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_STARTING")
    public static let started = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_STARTED")
    public static let stopping = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_STOPPING")
    public static let stopped = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_STOPPED")
    public static let reconnecting = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_RECONNECTING")
    public static let reconnected = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_RECONNECTED")
    public static let paused = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_PAUSED")
    public static let resumed = OBSOutputState(rawValue: "OBS_WEBSOCKET_OUTPUT_RESUMED")
}

/// `RecordStateChanged` event payload.
public struct OBSRecordStateChanged: Sendable, Equatable {
    public let outputActive: Bool
    public let outputState: OBSOutputState
    /// File name for the saved recording when the output stopped; `nil` otherwise.
    public let outputPath: String?

    public init(outputActive: Bool, outputState: OBSOutputState, outputPath: String?) {
        self.outputActive = outputActive
        self.outputState = outputState
        self.outputPath = outputPath
    }

    public var isRecording: Bool { outputActive && outputState != .stopped }
}

/// `CurrentProgramSceneChanged` event payload.
public struct OBSCurrentProgramSceneChanged: Sendable, Equatable {
    public let sceneName: String
    public let sceneUuid: String?

    public init(sceneName: String, sceneUuid: String?) {
        self.sceneName = sceneName
        self.sceneUuid = sceneUuid
    }
}

/// Any event this client does not model yet (or a future event type).
public struct OBSOtherEvent: Sendable, Equatable {
    public let eventType: String
    public let eventIntent: Int
    public let eventData: OBSJSONValue

    public init(eventType: String, eventIntent: Int, eventData: OBSJSONValue) {
        self.eventType = eventType
        self.eventIntent = eventIntent
        self.eventData = eventData
    }
}

/// A decoded obs-websocket event.
public enum OBSEvent: Sendable, Equatable {
    case recordStateChanged(OBSRecordStateChanged)
    case currentProgramSceneChanged(OBSCurrentProgramSceneChanged)
    case exitStarted
    case other(OBSOtherEvent)

    public var eventType: String {
        switch self {
        case .recordStateChanged: "RecordStateChanged"
        case .currentProgramSceneChanged: "CurrentProgramSceneChanged"
        case .exitStarted: "ExitStarted"
        case .other(let event): event.eventType
        }
    }
}

/// Converts the loosely typed `eventData` object into a typed `OBSEvent`.
///
/// A known event whose payload is malformed is delivered as `.other` rather
/// than terminating the connection: events are advisory, requests are not.
public enum OBSEventDecoder {
    public static func decode(
        eventType: String,
        eventIntent: Int,
        eventData: OBSJSONValue
    ) -> OBSEvent {
        switch eventType {
        case "RecordStateChanged":
            guard let outputActive = eventData["outputActive"]?.boolValue else {
                return .other(OBSOtherEvent(
                    eventType: eventType,
                    eventIntent: eventIntent,
                    eventData: eventData
                ))
            }
            let outputState = OBSOutputState(
                rawValue: eventData["outputState"]?.stringValue
                    ?? OBSOutputState.unknown.rawValue
            )
            return .recordStateChanged(OBSRecordStateChanged(
                outputActive: outputActive,
                outputState: outputState,
                outputPath: eventData["outputPath"]?.stringValue
            ))
        case "CurrentProgramSceneChanged":
            guard let sceneName = eventData["sceneName"]?.stringValue else {
                return .other(OBSOtherEvent(
                    eventType: eventType,
                    eventIntent: eventIntent,
                    eventData: eventData
                ))
            }
            return .currentProgramSceneChanged(OBSCurrentProgramSceneChanged(
                sceneName: sceneName,
                sceneUuid: eventData["sceneUuid"]?.stringValue
            ))
        case "ExitStarted":
            return .exitStarted
        default:
            return .other(OBSOtherEvent(
                eventType: eventType,
                eventIntent: eventIntent,
                eventData: eventData
            ))
        }
    }
}
