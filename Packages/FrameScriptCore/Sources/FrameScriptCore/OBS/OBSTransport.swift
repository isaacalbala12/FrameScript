import Foundation

/// Details of a WebSocket close frame.
public struct OBSTransportClose: Sendable, Equatable {
    /// The close code, or `nil` when no close frame was received.
    public let code: Int?
    public let reason: String?

    public init(code: Int?, reason: String? = nil) {
        self.code = code
        self.reason = reason
    }
}

/// One frame received from the transport.
public enum OBSTransportEvent: Sendable, Equatable {
    case text(String)
    case closed(OBSTransportClose)
}

/// A transport-level failure, kept free of platform error objects so it can cross
/// concurrency domains and be compared in tests.
public struct OBSTransportFailure: Error, Sendable, Equatable, LocalizedError {
    public enum Phase: String, Sendable, Equatable {
        case connect
        case send
        case receive
        case ping
    }

    public let phase: Phase
    public let message: String
    public let urlErrorCode: Int?
    public let posixErrorCode: Int?

    public init(
        phase: Phase,
        message: String,
        urlErrorCode: Int? = nil,
        posixErrorCode: Int? = nil
    ) {
        self.phase = phase
        self.message = message
        self.urlErrorCode = urlErrorCode
        self.posixErrorCode = posixErrorCode
    }

    public init(error: Error, phase: Phase) {
        let nsError = error as NSError
        var urlCode: Int?
        var posixCode: Int?

        func inspect(_ error: NSError) {
            if error.domain == NSURLErrorDomain, urlCode == nil {
                urlCode = error.code
            } else if error.domain == NSPOSIXErrorDomain, posixCode == nil {
                posixCode = error.code
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                inspect(underlying)
            }
        }
        inspect(nsError)

        self.init(
            phase: phase,
            message: nsError.localizedDescription,
            urlErrorCode: urlCode,
            posixErrorCode: posixCode
        )
    }

    public var errorDescription: String? { message }
}

/// Abstraction over the WebSocket connection.
///
/// Production code uses `OBSWebSocketTransport`; tests script a fake in memory.
public protocol OBSTransport: Sendable {
    /// Starts the WebSocket upgrade. Wait for the server's `Hello` via `receive()`.
    func connect() async throws
    func send(_ text: String) async throws
    /// Returns `.text` for a data frame and `.closed` when the peer closed the socket.
    func receive() async throws -> OBSTransportEvent
    /// Sends a WebSocket ping and waits for the pong. Used as a keepalive.
    func ping() async throws
    /// Closes the socket and releases its resources. Safe to call more than once.
    func close() async
}

/// Creates a transport for a connection attempt.
public typealias OBSTransportFactory = @Sendable (URL) async throws -> any OBSTransport

/// The `URLSessionWebSocketTask` implementation of `OBSTransport`.
///
/// JSON over text frames is obs-websocket's default encoding, so no subprotocol
/// header needs to be negotiated.
public final class OBSWebSocketTransport: OBSTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let lock = NSLock()
    private var closed = false

    public init(url: URL, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.session = URLSession(configuration: sessionConfiguration)
        self.task = session.webSocketTask(with: url)
    }

    public func connect() async throws {
        task.resume()
    }

    public func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw OBSTransportFailure(error: error, phase: .send)
        }
    }

    public func ping() async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: OBSTransportFailure(
                            error: error,
                            phase: .ping
                        ))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch let failure as OBSTransportFailure {
            throw failure
        } catch {
            throw OBSTransportFailure(error: error, phase: .ping)
        }
    }

    public func receive() async throws -> OBSTransportEvent {
        do {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                return .text(text)
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    throw OBSTransportFailure(
                        phase: .receive,
                        message: "Received a binary frame that was not valid UTF-8."
                    )
                }
                return .text(text)
            @unknown default:
                throw OBSTransportFailure(
                    phase: .receive,
                    message: "Received an unsupported WebSocket frame."
                )
            }
        } catch let failure as OBSTransportFailure {
            throw failure
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if task.closeCode.rawValue != 0 {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
                return .closed(OBSTransportClose(code: task.closeCode.rawValue, reason: reason))
            }
            throw OBSTransportFailure(error: error, phase: .receive)
        }
    }

    public func close() async {
        let shouldClose = lock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }

        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
