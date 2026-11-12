import Foundation

/// A minimal MCP server for the initialization-based protocol lifecycle
/// (2025-11-25): newline-delimited JSON-RPC 2.0 over stdio, `initialize` /
/// `notifications/initialized`, `ping`, `tools/list`, `tools/call`, and
/// `notifications/cancelled`.
///
/// The server never writes to stdout directly; all protocol output goes
/// through the channel, and logging goes to stderr by default.
public final class MCPServer: Sendable {
    private let channel: any MCPMessageChannel
    private let configuration: MCPServerConfiguration
    private let session: MCPSession

    public init(
        registry: MCPToolRegistry,
        channel: any MCPMessageChannel,
        configuration: MCPServerConfiguration = MCPServerConfiguration()
    ) {
        self.channel = channel
        self.configuration = configuration
        self.session = MCPSession(
            registry: registry,
            channel: channel,
            configuration: configuration
        )
    }

    /// Reads messages until stdin reaches EOF, then cancels in-flight work and
    /// returns. This is the graceful stdio shutdown signal from the spec.
    public func run() async {
        configuration.log(
            "server \(configuration.serverInfo.name) \(configuration.serverInfo.version) "
                + "listening on stdio (protocol \(MCPProtocolVersion.latest))"
        )
        while true {
            let data: Data?
            do {
                data = try await channel.receive()
            } catch {
                configuration.log("transport read failed: \(error)")
                break
            }
            guard let data else { break }
            await session.handleIncoming(data)
        }
        await session.shutdown()
        configuration.log("server stopped")
    }
}

// MARK: - Session

private actor MCPSession {
    private enum Phase {
        case awaitingInitialize
        case initialized(protocolVersion: String)
        case ready(protocolVersion: String)

        var isInitialized: Bool {
            if case .awaitingInitialize = self { return false }
            return true
        }
    }

    private let registry: MCPToolRegistry
    private let channel: any MCPMessageChannel
    private let configuration: MCPServerConfiguration
    private var phase: Phase = .awaitingInitialize
    private var inFlight: [JSONRPCID: InFlightRequest] = [:]

    init(
        registry: MCPToolRegistry,
        channel: any MCPMessageChannel,
        configuration: MCPServerConfiguration
    ) {
        self.registry = registry
        self.channel = channel
        self.configuration = configuration
    }

    // MARK: Inbound

    func handleIncoming(_ data: Data) async {
        guard !isWhitespaceOnly(data) else { return }

        switch JSONRPCIncoming.parse(data) {
        case .invalid(let id, let error):
            configuration.log("invalid message: \(error.message)")
            await send(.error(id: id, error: error))

        case .response(let id):
            let description = id.map { String(describing: $0) } ?? "null"
            configuration.log("ignoring unexpected client response (id \(description))")

        case .notification(let notification):
            await handle(notification)

        case .request(let request):
            await dispatch(request)
        }
    }

    private func handle(_ notification: JSONRPCNotification) async {
        switch notification.method {
        case "notifications/initialized":
            switch phase {
            case .initialized(let version):
                phase = .ready(protocolVersion: version)
                configuration.log("client sent notifications/initialized")
            case .ready:
                configuration.log("ignoring duplicate notifications/initialized")
            case .awaitingInitialize:
                configuration.log("ignoring notifications/initialized before initialize")
            }

        case "notifications/cancelled":
            handleCancellation(notification.params)

        default:
            configuration.log("ignoring notification \(notification.method)")
        }
    }

    private func handleCancellation(_ params: JSONValue?) {
        guard let object = params?.objectValue else {
            configuration.log("ignoring malformed notifications/cancelled (params must be an object)")
            return
        }
        guard let rawID = object["requestId"], let id = JSONRPCID(jsonValue: rawID) else {
            configuration.log("ignoring malformed notifications/cancelled (missing requestId)")
            return
        }
        guard let slot = inFlight[id] else {
            configuration.log("ignoring cancellation for unknown request \(id)")
            return
        }
        let reason = object["reason"]?.stringValue
        configuration.log(
            "cancelling request \(id)\(reason.map { " (\($0))" } ?? "")"
        )
        slot.cancel()
    }

    // MARK: Dispatch

    private func dispatch(_ request: JSONRPCRequest) async {
        guard inFlight[request.id] == nil else {
            configuration.log("rejecting duplicate in-flight id \(request.id)")
            await send(.error(
                id: request.id,
                error: JSONRPCErrorObject(
                    code: .invalidRequest,
                    message: "Invalid Request: request id \(request.id) is already in flight"
                )
            ))
            return
        }

        let slot = InFlightRequest()
        inFlight[request.id] = slot
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(request, slot: slot)
            await self.finish(request.id, slot: slot)
        }
        slot.attach(task)
    }

    private func finish(_ id: JSONRPCID, slot: InFlightRequest) {
        if inFlight[id] === slot {
            inFlight.removeValue(forKey: id)
        }
    }

    private func execute(_ request: JSONRPCRequest, slot: InFlightRequest) async {
        if slot.isCancellationRequested { return }

        do {
            let result = try await respond(to: request)
            if slot.isCancellationRequested || Task.isCancelled {
                configuration.log("suppressing response for cancelled request \(request.id)")
                return
            }
            await send(.result(id: request.id, value: result))
        } catch is CancellationError {
            configuration.log("request \(request.id) cancelled")
        } catch let error as MCPProtocolError {
            if slot.isCancellationRequested || Task.isCancelled { return }
            await send(.error(id: request.id, error: error.errorObject))
        } catch {
            if slot.isCancellationRequested || Task.isCancelled { return }
            await send(.error(
                id: request.id,
                error: JSONRPCErrorObject(
                    code: .internalError,
                    message: "Internal error: \(error.localizedDescription)"
                )
            ))
        }
    }

    // MARK: Methods

    private func respond(to request: JSONRPCRequest) async throws -> JSONValue {
        switch request.method {
        case "initialize":
            return try handleInitialize(request)
        case "ping":
            return .object([:])
        case "tools/list":
            try requireInitialized(for: request.method)
            return try handleToolsList(request.params)
        case "tools/call":
            try requireInitialized(for: request.method)
            return try await handleToolsCall(request.params)
        default:
            throw MCPProtocolError.methodNotFound("Method not found: \(request.method)")
        }
    }

    private func requireInitialized(for method: String) throws {
        guard phase.isInitialized else {
            throw MCPProtocolError.invalidRequest(
                "Invalid Request: server is not initialized; send initialize before \(method)"
            )
        }
    }

    private func handleInitialize(_ request: JSONRPCRequest) throws -> JSONValue {
        guard case .awaitingInitialize = phase else {
            throw MCPProtocolError.invalidRequest("Invalid Request: server is already initialized")
        }
        guard let params = request.params?.objectValue else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: initialize requires an object params payload"
            )
        }
        guard let requestedVersion = params["protocolVersion"]?.stringValue,
              !requestedVersion.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: initialize requires string params.protocolVersion"
            )
        }
        guard params["capabilities"]?.objectValue != nil else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: initialize requires object params.capabilities"
            )
        }
        guard let clientInfo = params["clientInfo"]?.objectValue,
              let clientName = clientInfo["name"]?.stringValue,
              let clientVersion = clientInfo["version"]?.stringValue else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: initialize requires params.clientInfo with name and version"
            )
        }

        let supported = configuration.supportedProtocolVersions
        let negotiated = supported.contains(requestedVersion)
            ? requestedVersion
            : (supported.first ?? MCPProtocolVersion.latest)
        phase = .initialized(protocolVersion: negotiated)
        configuration.log(
            "initialized by \(clientName) \(clientVersion); requested \(requestedVersion), negotiated \(negotiated)"
        )

        var result: [String: JSONValue] = [
            "protocolVersion": .string(negotiated),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": configuration.serverInfo.jsonValue
        ]
        if let instructions = configuration.instructions {
            result["instructions"] = .string(instructions)
        }
        return .object(result)
    }

    private func handleToolsList(_ params: JSONValue?) throws -> JSONValue {
        if let params {
            guard let object = params.objectValue else {
                throw MCPProtocolError.invalidParams(
                    "Invalid params: tools/list params must be an object"
                )
            }
            if let cursor = object["cursor"], !cursor.isNull {
                throw MCPProtocolError.invalidParams(
                    "Invalid params: unknown cursor; this server does not paginate"
                )
            }
        }
        return .object(["tools": .array(registry.definitions)])
    }

    private func handleToolsCall(_ params: JSONValue?) async throws -> JSONValue {
        guard let object = params?.objectValue else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: tools/call requires an object params payload"
            )
        }
        guard let name = object["name"]?.stringValue, !name.isEmpty else {
            throw MCPProtocolError.invalidParams(
                "Invalid params: tools/call requires string params.name"
            )
        }

        let arguments: JSONValue
        if let rawArguments = object["arguments"] {
            guard rawArguments.objectValue != nil else {
                throw MCPProtocolError.invalidParams(
                    "Invalid params: tools/call params.arguments must be an object"
                )
            }
            arguments = rawArguments
        } else {
            arguments = .object([:])
        }

        guard let tool = registry.tool(named: name) else {
            throw MCPProtocolError.invalidParams("Invalid params: unknown tool '\(name)'")
        }

        do {
            let toolResult = try await tool.handler(arguments)
            return toolResult.jsonValue
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MCPToolError {
            switch error {
            case .execution(let message):
                return MCPToolResult.text(message, isError: true).jsonValue
            case .invalidParams(let message):
                throw MCPProtocolError.invalidParams(message)
            case .internalError(let message):
                throw MCPProtocolError.internalError(message)
            }
        } catch let error as MCPArgumentError {
            return MCPToolResult.text(
                "Invalid arguments: \(error.message)",
                isError: true
            ).jsonValue
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return MCPToolResult.text(
                "Tool execution failed: \(error.localizedDescription)",
                isError: true
            ).jsonValue
        }
    }

    // MARK: Outbound

    private func send(_ response: JSONRPCResponse) async {
        do {
            let data = try MCPJSON.encode(response.jsonValue)
            try await channel.send(data)
        } catch {
            configuration.log("failed to send response: \(error)")
        }
    }

    func shutdown() async {
        let slots = Array(inFlight.values)
        inFlight.removeAll()
        for slot in slots { slot.cancel() }
        for slot in slots {
            if let task = slot.task {
                await task.value
            }
        }
        if !slots.isEmpty {
            configuration.log("cancelled \(slots.count) in-flight request(s) at shutdown")
        }
    }

    private func isWhitespaceOnly(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }
}

// MARK: - In-flight bookkeeping

/// Bridges the gap between creating a task and storing its handle: a
/// cancellation notification can arrive before the task body starts.
private final class InFlightRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: Task<Void, Never>?
    private var cancellationRequested = false

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        storedTask = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = storedTask
        lock.unlock()
        task?.cancel()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    var task: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return storedTask
    }
}
