import Foundation

/// Errors surfaced by `OBSClient`.
public enum OBSError: Error, Sendable, Equatable, LocalizedError {
    /// A request was attempted before the handshake completed.
    case notConnected
    /// The WebSocket connection could not be established for an unclassified reason.
    case connectionFailed(String)
    /// The connection was refused; OBS is not running or the WebSocket server is off.
    case obsNotRunning(host: String, port: Int)
    /// The connection or handshake exceeded the configured timeout.
    case connectionTimeout(Duration)
    /// The server asked for a password but none was configured.
    case authenticationRequired
    /// The server rejected the authentication string (close code 4009).
    case authenticationFailed
    /// The server refused the RPC version (close code 4010).
    case unsupportedRPCVersion(serverVersion: Int?)
    /// The first message was not a valid `Hello`, or the handshake was interrupted.
    case handshakeFailed(String)
    /// OBS answered a request with `result: false`.
    case requestFailed(requestType: String, statusCode: Int, comment: String?)
    /// The request did not receive a response before its timeout.
    case requestTimeout(requestType: String, after: Duration)
    /// The socket closed with an optional obs-websocket close code.
    case transportClosed(code: Int?, reason: String?)
    /// A response did not match the shape required by the protocol.
    case protocolViolation(String)
    /// The client was explicitly disconnected while an operation was in flight.
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to OBS."
        case .connectionFailed(let detail):
            "Could not connect to OBS: \(detail)"
        case .obsNotRunning(let host, let port):
            "OBS is not running or obs-websocket is not enabled at \(host):\(port)."
        case .connectionTimeout:
            "Timed out connecting to OBS."
        case .authenticationRequired:
            "OBS requires a password but none was configured."
        case .authenticationFailed:
            "OBS rejected the WebSocket password."
        case .unsupportedRPCVersion(let serverVersion):
            if let serverVersion {
                "OBS does not support obs-websocket RPC version \(OBSMessageCodec.rpcVersion) (server version \(serverVersion))."
            } else {
                "OBS does not support obs-websocket RPC version \(OBSMessageCodec.rpcVersion)."
            }
        case .handshakeFailed(let detail):
            "The obs-websocket handshake failed: \(detail)"
        case .requestFailed(let requestType, let statusCode, let comment):
            if let comment, !comment.isEmpty {
                "OBS rejected \(requestType) (code \(statusCode)): \(comment)"
            } else {
                "OBS rejected \(requestType) (code \(statusCode))."
            }
        case .requestTimeout(let requestType, _):
            "The \(requestType) request timed out."
        case .transportClosed(let code, let reason):
            if let code, let reason, !reason.isEmpty {
                "The obs-websocket connection closed (code \(code)): \(reason)"
            } else if let code {
                "The obs-websocket connection closed (code \(code))."
            } else {
                "The obs-websocket connection closed."
            }
        case .protocolViolation(let detail):
            "Unexpected obs-websocket response: \(detail)"
        case .disconnected:
            "The client was disconnected."
        }
    }

    /// Whether an automatic reconnect could plausibly succeed without user action.
    public var isRetryable: Bool {
        switch self {
        case .obsNotRunning, .connectionFailed, .connectionTimeout, .transportClosed, .disconnected:
            true
        case .notConnected, .authenticationRequired, .authenticationFailed,
             .unsupportedRPCVersion, .handshakeFailed, .requestFailed,
             .requestTimeout, .protocolViolation:
            false
        }
    }
}
