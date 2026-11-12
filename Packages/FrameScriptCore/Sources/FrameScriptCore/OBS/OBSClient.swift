import Foundation

/// A native obs-websocket v5 client.
///
/// The actor serializes connection state, request correlation and event
/// delivery. Pure framing lives in `OBSMessageCodec`; the socket lives behind
/// `OBSTransport`, so tests can script a fake server entirely in memory.
public actor OBSClient {
    public private(set) var connectionState: OBSConnectionState = .disconnected

    private struct PendingRequest {
        let requestType: String
        let continuation: CheckedContinuation<OBSJSONValue, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private var config: OBSConnectionConfig
    private let transportFactory: OBSTransportFactory
    private let eventHub = OBSStreamHub<OBSEvent>()
    private let stateHub = OBSStreamHub<OBSConnectionState>(
        bufferingPolicy: .bufferingNewest(32)
    )

    private var transport: (any OBSTransport)?
    private var inFlightTransport: (any OBSTransport)?
    private var readTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectionID = UUID()
    private var connectionEpoch = UUID()
    private var reconnectGeneration = UUID()
    private var pending: [String: PendingRequest] = [:]
    private var isManuallyDisconnected = true
    private var isShutDown = false

    public init(
        config: OBSConnectionConfig = OBSConnectionConfig(),
        transportFactory: @escaping OBSTransportFactory = { url in
            OBSWebSocketTransport(url: url)
        }
    ) {
        self.config = config
        self.transportFactory = transportFactory
    }

    // MARK: - Streams

    /// A new stream of decoded events. Each access creates an independent consumer.
    /// All streams finish when `shutdown()` is called.
    public nonisolated var events: AsyncStream<OBSEvent> {
        eventHub.makeStream()
    }

    /// A new stream of connection state changes.
    ///
    /// The stream reports changes made after it is created. Read
    /// `connectionState` once for the current value before subscribing.
    /// All streams finish when `shutdown()` is called.
    public nonisolated var connectionStates: AsyncStream<OBSConnectionState> {
        stateHub.makeStream()
    }

    public var configuration: OBSConnectionConfig {
        config
    }

    public var isConnected: Bool {
        connectionState.isConnected
    }

    // MARK: - Connection

    /// Connects using explicit host, port and optional password.
    public func connect(
        host: String,
        port: Int = OBSConnectionConfig.defaultPort,
        password: String? = nil
    ) async throws {
        var updated = config
        updated.host = host
        updated.port = port
        updated.password = password
        try await connect(config: updated)
    }

    /// Replaces the current connection (if any) with a fresh one.
    public func connect(config newConfig: OBSConnectionConfig) async throws {
        guard !isShutDown else { throw OBSError.clientShutdown }
        await disconnect()
        config = newConfig
        isManuallyDisconnected = false
        let epoch = UUID()
        connectionEpoch = epoch
        try await establishConnection(epoch: epoch)
    }

    /// Closes the connection and disables automatic reconnection for this cycle.
    ///
    /// This also aborts a connect that is still in its handshake.
    public func disconnect() async {
        isManuallyDisconnected = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectGeneration = UUID()
        connectionEpoch = UUID()

        await closeConnectionResources()
        setState(.disconnected)
        failAllPending(with: .disconnected)
    }

    /// Permanently stops the client: disconnects and finishes the event and state
    /// streams. Subsequent `connect` calls throw `OBSError.clientShutdown`.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await disconnect()
        eventHub.finish()
        stateHub.finish()
    }

    // MARK: - Requests

    /// Sends any request type and returns its `responseData` (an empty object when
    /// OBS sends none).
    public func send(
        requestType: String,
        data: [String: OBSJSONValue] = [:],
        timeout: Duration? = nil
    ) async throws -> OBSJSONValue {
        guard case .connected = connectionState, let transport else {
            throw OBSError.notConnected
        }

        let connectionID = self.connectionID
        let requestID = UUID().uuidString
        let payload = try OBSMessageCodec.encodeRequest(
            requestType: requestType,
            requestID: requestID,
            requestData: data
        )
        let effectiveTimeout = timeout ?? config.requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: effectiveTimeout)
                    } catch {
                        return
                    }
                    await self?.failTimedOutRequest(
                        requestID: requestID,
                        timeout: effectiveTimeout
                    )
                }
                pending[requestID] = PendingRequest(
                    requestType: requestType,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )

                if Task.isCancelled {
                    cancelRequest(requestID: requestID)
                    return
                }

                Task { [weak self] in
                    do {
                        try await transport.send(payload)
                    } catch {
                        await self?.handleSendFailure(
                            connectionID: connectionID,
                            error: error
                        )
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelRequest(requestID: requestID)
            }
        }
    }

    public func getVersion() async throws -> OBSVersionInfo {
        let data = try await send(requestType: "GetVersion")
        return try decodeModel(requestType: "GetVersion") { try OBSVersionInfo(json: data) }
    }

    public func getRecordStatus() async throws -> OBSRecordStatus {
        let data = try await send(requestType: "GetRecordStatus")
        return try decodeModel(requestType: "GetRecordStatus") {
            try OBSRecordStatus(json: data)
        }
    }

    public func startRecord() async throws {
        _ = try await send(requestType: "StartRecord")
    }

    /// Stops recording and returns the file OBS reports in `outputPath`.
    public func stopRecord() async throws -> String {
        let data = try await send(requestType: "StopRecord")
        guard let outputPath = data["outputPath"]?.stringValue, !outputPath.isEmpty else {
            throw OBSError.protocolViolation("StopRecord did not return an outputPath.")
        }
        return outputPath
    }

    public func toggleRecordPause() async throws {
        _ = try await send(requestType: "ToggleRecordPause")
    }

    public func pauseRecord() async throws {
        _ = try await send(requestType: "PauseRecord")
    }

    public func resumeRecord() async throws {
        _ = try await send(requestType: "ResumeRecord")
    }

    public func getSceneList() async throws -> OBSSceneList {
        let data = try await send(requestType: "GetSceneList")
        return try decodeModel(requestType: "GetSceneList") { try OBSSceneList(json: data) }
    }

    public func getCurrentProgramScene() async throws -> OBSProgramScene {
        let data = try await send(requestType: "GetCurrentProgramScene")
        return try decodeModel(requestType: "GetCurrentProgramScene") {
            try OBSProgramScene(json: data)
        }
    }

    public func setCurrentProgramScene(name: String) async throws {
        _ = try await send(
            requestType: "SetCurrentProgramScene",
            data: ["sceneName": .string(name)]
        )
    }

    public func setCurrentProgramScene(uuid: String) async throws {
        _ = try await send(
            requestType: "SetCurrentProgramScene",
            data: ["sceneUuid": .string(uuid)]
        )
    }

    // MARK: - Handshake

    private func establishConnection(epoch: UUID) async throws {
        guard epoch == connectionEpoch, !isManuallyDisconnected, !isShutDown, !Task.isCancelled else {
            throw OBSError.disconnected
        }
        setState(.connecting)

        // Never install a new socket on top of an old read loop or keepalive.
        await closeConnectionResources()
        guard epoch == connectionEpoch, !Task.isCancelled else {
            throw OBSError.disconnected
        }

        guard let url = config.url else {
            let error = OBSError.connectionFailed("The OBS host or port is not a valid URL.")
            setState(.failed(reason: error.localizedDescription))
            throw error
        }

        let newTransport: any OBSTransport
        do {
            newTransport = try await transportFactory(url)
        } catch {
            if Task.isCancelled || epoch != connectionEpoch {
                if epoch == connectionEpoch { setState(.disconnected) }
                throw OBSError.disconnected
            }
            let mapped = mapConnectionError(error)
            setState(.failed(reason: mapped.localizedDescription))
            startReconnectLoopIfNeeded(after: mapped, epoch: epoch)
            throw mapped
        }

        // The client owns the socket from this point, so `disconnect()` and task
        // cancellation can close it while the handshake is suspended.
        inFlightTransport = newTransport

        do {
            try await withTaskCancellationHandler {
                try await newTransport.connect()
                let hello = try await receiveHello(using: newTransport)
                let authentication = try authenticationString(for: hello)
                let identify = try OBSMessageCodec.encodeIdentify(
                    authentication: authentication,
                    eventSubscriptions: config.eventSubscriptions.rawValue
                )
                try await newTransport.send(identify)
                let identified = try await receiveIdentified(using: newTransport)

                // A newer connect/disconnect may have replaced this attempt while
                // the handshake was suspended.
                guard epoch == connectionEpoch, !Task.isCancelled else {
                    throw OBSError.disconnected
                }
                guard transport == nil else {
                    throw OBSError.disconnected
                }

                let session = OBSSessionInfo(
                    obsStudioVersion: hello.obsStudioVersion,
                    obsWebSocketVersion: hello.obsWebSocketVersion,
                    rpcVersion: hello.rpcVersion,
                    negotiatedRpcVersion: identified.negotiatedRpcVersion
                )
                let connectionID = UUID()
                self.connectionID = connectionID
                self.transport = newTransport
                self.inFlightTransport = nil
                self.readTask = Task { [weak self] in
                    await self?.readLoop(transport: newTransport, connectionID: connectionID)
                }
                setState(.connected(session))
                startKeepalive(connectionID: connectionID)
            } onCancel: {
                Task { await newTransport.close() }
            }
        } catch {
            await newTransport.close()
            if epoch == connectionEpoch {
                inFlightTransport = nil
            }
            if Task.isCancelled || epoch != connectionEpoch {
                if epoch == connectionEpoch { setState(.disconnected) }
                throw OBSError.disconnected
            }
            let mapped = mapConnectionError(error)
            if mapped == .disconnected {
                setState(.disconnected)
                throw mapped
            }
            setState(.failed(reason: mapped.localizedDescription))
            startReconnectLoopIfNeeded(after: mapped, epoch: epoch)
            throw mapped
        }
    }

    /// Closes both the live and in-flight sockets and cancels their tasks.
    private func closeConnectionResources() async {
        readTask?.cancel()
        readTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        connectionID = UUID()

        let installed = transport
        transport = nil
        let inFlight = inFlightTransport
        inFlightTransport = nil

        await installed?.close()
        await inFlight?.close()
    }

    private func authenticationString(for hello: OBSHello) throws -> String? {
        guard let challenge = hello.authentication else { return nil }
        guard let password = config.password, !password.isEmpty else {
            throw OBSError.authenticationRequired
        }
        return OBSAuthentication.authenticationString(
            password: password,
            challenge: challenge.challenge,
            salt: challenge.salt
        )
    }

    private func receiveHello(using transport: any OBSTransport) async throws -> OBSHello {
        while true {
            let event = try await receiveWithTimeout(using: transport)
            switch event {
            case .closed(let close):
                throw closeError(close)
            case .text(let text):
                let message = try OBSMessageCodec.decode(text)
                switch message {
                case .hello(let hello):
                    return hello
                case .event(let eventType, let eventIntent, let eventData):
                    yieldEvent(eventType: eventType, eventIntent: eventIntent, eventData: eventData)
                default:
                    throw OBSError.handshakeFailed(
                        "Expected Hello but received \(Self.describe(message))."
                    )
                }
            }
        }
    }

    private func receiveIdentified(using transport: any OBSTransport) async throws -> OBSIdentified {
        while true {
            let event = try await receiveWithTimeout(using: transport)
            switch event {
            case .closed(let close):
                throw closeError(close)
            case .text(let text):
                let message = try OBSMessageCodec.decode(text)
                switch message {
                case .identified(let identified):
                    return identified
                case .event(let eventType, let eventIntent, let eventData):
                    yieldEvent(eventType: eventType, eventIntent: eventIntent, eventData: eventData)
                default:
                    throw OBSError.handshakeFailed(
                        "Expected Identified but received \(Self.describe(message))."
                    )
                }
            }
        }
    }

    /// Waits for one frame, closing the transport if the handshake stalls or the
    /// caller is cancelled. `URLSessionWebSocketTask.receive()` does not observe
    /// task cancellation on its own, so the close is what unblocks it.
    private func receiveWithTimeout(
        using transport: any OBSTransport
    ) async throws -> OBSTransportEvent {
        let timeout = config.connectTimeout
        let timeoutFlag = OBSTimeoutFlag()
        return try await withTaskCancellationHandler {
            let event = try await withThrowingTaskGroup(of: OBSTransportEvent.self) { group in
                group.addTask {
                    try await transport.receive()
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    timeoutFlag.markFired()
                    await transport.close()
                    throw OBSError.connectionTimeout(timeout)
                }
                defer { group.cancelAll() }
                guard let event = try await group.next() else {
                    throw OBSError.connectionTimeout(timeout)
                }
                return event
            }
            // Closing the transport wakes the pending receive with `.closed`. When our
            // own timer caused that close, report the timeout instead of a peer close.
            if timeoutFlag.isFired {
                throw OBSError.connectionTimeout(timeout)
            }
            return event
        } onCancel: {
            Task { await transport.close() }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive(connectionID: UUID) {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        guard let interval = config.keepaliveInterval, interval > .zero else { return }
        keepaliveTask = Task { [weak self] in
            await self?.runKeepalive(connectionID: connectionID, interval: interval)
        }
    }

    /// Pings while this connection is the live one. A failed ping is treated as a
    /// dead socket and goes through the normal disconnect/reconnect path.
    private func runKeepalive(connectionID: UUID, interval: Duration) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard connectionID == self.connectionID, connectionState.isConnected else {
                return
            }
            guard let transport else { return }
            do {
                try await transport.ping()
            } catch {
                guard connectionID == self.connectionID else { return }
                await handleConnectionEnded(
                    connectionID: connectionID,
                    error: mapConnectionError(error)
                )
                return
            }
        }
    }

    // MARK: - Read loop

    private func readLoop(transport: any OBSTransport, connectionID: UUID) async {
        while true {
            do {
                let event = try await transport.receive()
                guard connectionID == self.connectionID else { return }
                switch event {
                case .text(let text):
                    let message: OBSIncomingMessage
                    do {
                        message = try OBSMessageCodec.decode(text)
                    } catch {
                        await handleConnectionEnded(
                            connectionID: connectionID,
                            error: .protocolViolation(error.localizedDescription)
                        )
                        return
                    }
                    handle(message)
                case .closed(let close):
                    await handleConnectionEnded(
                        connectionID: connectionID,
                        error: closeError(close)
                    )
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                guard connectionID == self.connectionID else { return }
                await handleConnectionEnded(
                    connectionID: connectionID,
                    error: mapConnectionError(error)
                )
                return
            }
        }
    }

    private func handle(_ message: OBSIncomingMessage) {
        switch message {
        case .event(let eventType, let eventIntent, let eventData):
            yieldEvent(eventType: eventType, eventIntent: eventIntent, eventData: eventData)
        case .requestResponse(let response):
            complete(response)
        case .requestBatchResponse, .hello, .identified, .unknown:
            break
        }
    }

    private func yieldEvent(eventType: String, eventIntent: Int, eventData: OBSJSONValue) {
        eventHub.yield(OBSEventDecoder.decode(
            eventType: eventType,
            eventIntent: eventIntent,
            eventData: eventData
        ))
    }

    private func complete(_ response: OBSRequestResponse) {
        guard let request = pending.removeValue(forKey: response.requestID) else { return }
        request.timeoutTask.cancel()
        if response.status.result {
            request.continuation.resume(returning: response.responseData ?? .object([:]))
        } else {
            request.continuation.resume(throwing: OBSError.requestFailed(
                requestType: response.requestType,
                statusCode: response.status.code,
                comment: response.status.comment
            ))
        }
    }

    private func failTimedOutRequest(requestID: String, timeout: Duration) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: OBSError.requestTimeout(
            requestType: request.requestType,
            after: timeout
        ))
    }

    private func cancelRequest(requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: CancellationError())
    }

    private func handleSendFailure(
        connectionID: UUID,
        error: Error
    ) async {
        guard connectionID == self.connectionID else { return }
        await handleConnectionEnded(
            connectionID: connectionID,
            error: mapConnectionError(error)
        )
    }

    private func handleConnectionEnded(connectionID: UUID, error: OBSError) async {
        let epoch = connectionEpoch
        guard connectionID == self.connectionID, epoch == connectionEpoch else { return }

        let previousTransport = transport
        transport = nil
        let tombstone = UUID()
        self.connectionID = tombstone
        readTask?.cancel()
        readTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil

        if error.isRetryable {
            setState(.disconnected)
        } else {
            setState(.failed(reason: error.localizedDescription))
        }
        failAllPending(with: error)
        await previousTransport?.close()

        // A manual connect may have completed while the old socket was closing.
        // Never touch (or reconnect over) that newer connection.
        guard epoch == connectionEpoch,
              self.connectionID == tombstone,
              transport == nil,
              inFlightTransport == nil,
              !connectionState.isConnected
        else { return }
        startReconnectLoopIfNeeded(after: error, epoch: epoch)
    }

    private func failAllPending(with error: OBSError) {
        let requests = pending
        pending.removeAll()
        for request in requests.values {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    // MARK: - Reconnection

    private func startReconnectLoopIfNeeded(after error: OBSError, epoch: UUID) {
        guard epoch == connectionEpoch,
              !isManuallyDisconnected,
              !isShutDown,
              config.reconnect.isEnabled,
              error.isRetryable,
              reconnectTask == nil,
              transport == nil,
              inFlightTransport == nil,
              !connectionState.isConnected
        else { return }
        startReconnectLoop(epoch: epoch)
    }

    private func startReconnectLoop(epoch: UUID) {
        let generation = UUID()
        reconnectGeneration = generation
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop(generation: generation, epoch: epoch)
        }
    }

    private func runReconnectLoop(generation: UUID, epoch: UUID) async {
        var attempt = 1
        while !Task.isCancelled,
              !isManuallyDisconnected,
              !isShutDown,
              epoch == connectionEpoch {
            let policy = config.reconnect
            guard policy.isEnabled else { break }
            if let maxAttempts = policy.maxAttempts, attempt > maxAttempts { break }
            guard transport == nil,
                  inFlightTransport == nil,
                  !connectionState.isConnected
            else { break }

            do {
                try await Task.sleep(for: policy.delay(forAttempt: attempt))
            } catch {
                break
            }
            if Task.isCancelled || isManuallyDisconnected || epoch != connectionEpoch {
                break
            }

            do {
                try await establishConnection(epoch: epoch)
                break
            } catch let error as OBSError {
                if !error.isRetryable { break }
                attempt += 1
            } catch {
                attempt += 1
            }
        }
        if reconnectGeneration == generation {
            reconnectTask = nil
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: OBSConnectionState) {
        guard connectionState != newState else { return }
        connectionState = newState
        stateHub.yield(newState)
    }

    private func mapConnectionError(_ error: Error) -> OBSError {
        if let error = error as? OBSError { return error }
        if let error = error as? OBSProtocolError {
            return .protocolViolation(error.localizedDescription)
        }
        if error is CancellationError { return .disconnected }
        if let failure = error as? OBSTransportFailure {
            if failure.urlErrorCode == NSURLErrorCannotConnectToHost
                || failure.posixErrorCode == Int(POSIXErrorCode.ECONNREFUSED.rawValue) {
                return .obsNotRunning(host: config.host, port: config.port)
            }
            if failure.urlErrorCode == NSURLErrorTimedOut {
                return .connectionTimeout(config.connectTimeout)
            }
            if failure.urlErrorCode == NSURLErrorNetworkConnectionLost {
                return .transportClosed(code: nil, reason: failure.message)
            }
            return .connectionFailed(failure.message)
        }
        return .connectionFailed(error.localizedDescription)
    }

    private func closeError(_ close: OBSTransportClose) -> OBSError {
        switch close.code {
        case OBSWebSocketCloseCode.authenticationFailed:
            return .authenticationFailed
        case OBSWebSocketCloseCode.unsupportedRPCVersion:
            return .unsupportedRPCVersion(serverVersion: nil)
        case OBSWebSocketCloseCode.sessionInvalidated:
            return .sessionInvalidated
        default:
            return .transportClosed(code: close.code, reason: close.reason)
        }
    }

    private func decodeModel<T>(
        requestType: String,
        _ decode: () throws -> T
    ) throws -> T {
        do {
            return try decode()
        } catch let error as OBSProtocolError {
            throw OBSError.protocolViolation(error.localizedDescription)
        }
    }

    private static func describe(_ message: OBSIncomingMessage) -> String {
        switch message {
        case .hello: "Hello"
        case .identified: "Identified"
        case .event(let eventType, _, _): "event \(eventType)"
        case .requestResponse(let response): "response to \(response.requestType)"
        case .requestBatchResponse: "RequestBatchResponse"
        case .unknown(let op, _): "opcode \(op)"
        }
    }
}

/// A one-way flag shared with a timeout child task.
private final class OBSTimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func markFired() {
        lock.withLock { fired = true }
    }

    var isFired: Bool {
        lock.withLock { fired }
    }
}
