import Foundation

/// Details of an established obs-websocket session.
public struct OBSSessionInfo: Sendable, Equatable {
    public let obsStudioVersion: String?
    public let obsWebSocketVersion: String?
    /// The RPC version offered by the server in `Hello`.
    public let rpcVersion: Int
    /// The RPC version the server agreed to in `Identified`.
    public let negotiatedRpcVersion: Int

    public init(
        obsStudioVersion: String?,
        obsWebSocketVersion: String?,
        rpcVersion: Int,
        negotiatedRpcVersion: Int
    ) {
        self.obsStudioVersion = obsStudioVersion
        self.obsWebSocketVersion = obsWebSocketVersion
        self.rpcVersion = rpcVersion
        self.negotiatedRpcVersion = negotiatedRpcVersion
    }
}

/// Observable connection state of an `OBSClient`.
public enum OBSConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected(OBSSessionInfo)
    case failed(reason: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var sessionInfo: OBSSessionInfo? {
        if case .connected(let info) = self { return info }
        return nil
    }
}

/// Exponential backoff settings for automatic reconnection.
public struct OBSReconnectPolicy: Sendable, Equatable {
    public var isEnabled: Bool
    public var initialDelay: Duration
    /// Multiplier applied after each failed attempt. Values below 1 are treated as 1.
    public var multiplier: Double
    public var maxDelay: Duration
    /// Maximum number of retries after a failure. `nil` means retry forever.
    public var maxAttempts: Int?

    public init(
        isEnabled: Bool = true,
        initialDelay: Duration = .milliseconds(500),
        multiplier: Double = 2,
        maxDelay: Duration = .seconds(10),
        maxAttempts: Int? = 5
    ) {
        self.isEnabled = isEnabled
        self.initialDelay = initialDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    public static let disabled = OBSReconnectPolicy(isEnabled: false)

    /// Delay before retry number `attempt` (1 is the first retry).
    public func delay(forAttempt attempt: Int) -> Duration {
        guard isEnabled else { return .zero }
        let normalizedAttempt = max(1, attempt)
        let multiplier = max(1, self.multiplier)
        let initialSeconds = Self.seconds(of: initialDelay)
        let maxSeconds = Self.seconds(of: maxDelay)
        let exponent = Double(normalizedAttempt - 1)
        let raw = initialSeconds * pow(multiplier, exponent)
        return .seconds(min(raw, maxSeconds))
    }

    private static func seconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Connection parameters for `OBSClient`.
public struct OBSConnectionConfig: Sendable, Equatable {
    public static let defaultPort = 4455

    public var host: String
    public var port: Int
    public var password: String?
    /// Covers the WebSocket upgrade and the Hello/Identified handshake.
    public var connectTimeout: Duration
    /// Default timeout for requests that do not override it.
    public var requestTimeout: Duration
    /// Interval between WebSocket pings while connected. `nil` disables keepalive.
    public var keepaliveInterval: Duration?
    public var eventSubscriptions: OBSEventSubscriptions
    public var reconnect: OBSReconnectPolicy

    public init(
        host: String = "localhost",
        port: Int = OBSConnectionConfig.defaultPort,
        password: String? = nil,
        connectTimeout: Duration = .seconds(10),
        requestTimeout: Duration = .seconds(10),
        keepaliveInterval: Duration? = .seconds(10),
        eventSubscriptions: OBSEventSubscriptions = .all,
        reconnect: OBSReconnectPolicy = .disabled
    ) {
        self.host = host
        self.port = port
        self.password = password
        self.connectTimeout = connectTimeout
        self.requestTimeout = requestTimeout
        self.keepaliveInterval = keepaliveInterval
        self.eventSubscriptions = eventSubscriptions
        self.reconnect = reconnect
    }

    /// `ws://host:port`; `nil` only when the host or port cannot form a URL.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        return components.url
    }
}
