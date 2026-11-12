import Foundation

/// Response of `GetVersion`.
public struct OBSVersionInfo: Sendable, Equatable {
    public let obsVersion: String
    public let obsWebSocketVersion: String
    public let rpcVersion: Int
    public let availableRequests: [String]
    public let supportedImageFormats: [String]
    public let platform: String
    public let platformDescription: String

    public init(
        obsVersion: String,
        obsWebSocketVersion: String,
        rpcVersion: Int,
        availableRequests: [String],
        supportedImageFormats: [String],
        platform: String,
        platformDescription: String
    ) {
        self.obsVersion = obsVersion
        self.obsWebSocketVersion = obsWebSocketVersion
        self.rpcVersion = rpcVersion
        self.availableRequests = availableRequests
        self.supportedImageFormats = supportedImageFormats
        self.platform = platform
        self.platformDescription = platformDescription
    }

    public init(json: OBSJSONValue) throws {
        guard let rpcVersion = json["rpcVersion"]?.intValue else {
            throw OBSProtocolError.malformedMessage("GetVersion is missing `rpcVersion`.")
        }
        self.init(
            obsVersion: json["obsVersion"]?.stringValue ?? "",
            obsWebSocketVersion: json["obsWebSocketVersion"]?.stringValue ?? "",
            rpcVersion: rpcVersion,
            availableRequests: json["availableRequests"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            supportedImageFormats: json["supportedImageFormats"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            platform: json["platform"]?.stringValue ?? "",
            platformDescription: json["platformDescription"]?.stringValue ?? ""
        )
    }

    public func supports(_ requestType: String) -> Bool {
        availableRequests.contains(requestType)
    }
}

/// Response of `GetRecordStatus`.
public struct OBSRecordStatus: Sendable, Equatable {
    public let outputActive: Bool
    public let outputPaused: Bool
    /// Formatted timecode, for example `00:01:23.456`.
    public let outputTimecode: String
    /// Duration in milliseconds.
    public let outputDuration: Int
    /// Number of bytes written so far.
    public let outputBytes: Int

    public init(
        outputActive: Bool,
        outputPaused: Bool,
        outputTimecode: String,
        outputDuration: Int,
        outputBytes: Int
    ) {
        self.outputActive = outputActive
        self.outputPaused = outputPaused
        self.outputTimecode = outputTimecode
        self.outputDuration = outputDuration
        self.outputBytes = outputBytes
    }

    public init(json: OBSJSONValue) throws {
        guard let outputActive = json["outputActive"]?.boolValue,
              let outputPaused = json["outputPaused"]?.boolValue
        else {
            throw OBSProtocolError.malformedMessage(
                "GetRecordStatus is missing `outputActive` or `outputPaused`."
            )
        }
        self.init(
            outputActive: outputActive,
            outputPaused: outputPaused,
            outputTimecode: json["outputTimecode"]?.stringValue ?? "",
            outputDuration: json["outputDuration"]?.intValue ?? 0,
            outputBytes: json["outputBytes"]?.intValue ?? 0
        )
    }
}

/// One entry of `GetSceneList`'s `scenes` array.
public struct OBSScene: Sendable, Equatable {
    public let name: String
    public let index: Int?
    public let uuid: String?

    public init(name: String, index: Int?, uuid: String?) {
        self.name = name
        self.index = index
        self.uuid = uuid
    }

    public init(json: OBSJSONValue) throws {
        guard let name = json["sceneName"]?.stringValue else {
            throw OBSProtocolError.malformedMessage("A scene is missing `sceneName`.")
        }
        self.init(
            name: name,
            index: json["sceneIndex"]?.intValue,
            uuid: json["sceneUuid"]?.stringValue
        )
    }
}

/// Response of `GetSceneList`.
public struct OBSSceneList: Sendable, Equatable {
    public let currentProgramSceneName: String?
    public let currentProgramSceneUuid: String?
    public let currentPreviewSceneName: String?
    public let currentPreviewSceneUuid: String?
    public let scenes: [OBSScene]

    public init(
        currentProgramSceneName: String?,
        currentProgramSceneUuid: String?,
        currentPreviewSceneName: String?,
        currentPreviewSceneUuid: String?,
        scenes: [OBSScene]
    ) {
        self.currentProgramSceneName = currentProgramSceneName
        self.currentProgramSceneUuid = currentProgramSceneUuid
        self.currentPreviewSceneName = currentPreviewSceneName
        self.currentPreviewSceneUuid = currentPreviewSceneUuid
        self.scenes = scenes
    }

    public init(json: OBSJSONValue) throws {
        guard let sceneValues = json["scenes"]?.arrayValue else {
            throw OBSProtocolError.malformedMessage("GetSceneList is missing `scenes`.")
        }
        let scenes = try sceneValues.map { value -> OBSScene in
            guard let object = value.objectValue else {
                throw OBSProtocolError.malformedMessage(
                    "GetSceneList contains a non-object scene entry."
                )
            }
            return try OBSScene(json: .object(object))
        }
        self.init(
            currentProgramSceneName: json["currentProgramSceneName"]?.stringValue,
            currentProgramSceneUuid: json["currentProgramSceneUuid"]?.stringValue,
            currentPreviewSceneName: json["currentPreviewSceneName"]?.stringValue,
            currentPreviewSceneUuid: json["currentPreviewSceneUuid"]?.stringValue,
            scenes: scenes
        )
    }

    public var sceneNames: [String] {
        scenes.map(\.name)
    }
}

/// Response of `GetCurrentProgramScene`.
public struct OBSProgramScene: Sendable, Equatable {
    public let name: String
    public let uuid: String?

    public init(name: String, uuid: String?) {
        self.name = name
        self.uuid = uuid
    }

    public init(json: OBSJSONValue) throws {
        // `sceneName` is current; `currentProgramSceneName` is the deprecated
        // field that older obs-websocket builds still send.
        guard let name = json["sceneName"]?.stringValue
                ?? json["currentProgramSceneName"]?.stringValue
        else {
            throw OBSProtocolError.malformedMessage(
                "GetCurrentProgramScene is missing `sceneName`."
            )
        }
        self.init(
            name: name,
            uuid: json["sceneUuid"]?.stringValue ?? json["currentProgramSceneUuid"]?.stringValue
        )
    }
}
