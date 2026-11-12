import Foundation

/// An in-memory `MCPMessageChannel` for scripted protocol conversations and
/// tests. It supports one receiver (the server loop) and one test reader at a
/// time; messages are buffered so producers may run ahead.
public final class MCPInMemoryChannel: MCPMessageChannel, @unchecked Sendable {
    private struct OutboundWaiter {
        let token: UInt64
        let continuation: CheckedContinuation<Data?, Never>
    }

    private enum InboundDecision {
        case value(Data?)
        case wait
    }

    private enum OutboundDecision {
        case value(Data)
        case wait
    }

    private let lock = NSLock()
    private var inbox: [Data?] = []
    private var inboxWaiter: CheckedContinuation<Data?, Never>?
    private var outbox: [Data] = []
    private var outboundWaiter: OutboundWaiter?
    private var nextToken: UInt64 = 0
    private var inputClosed = false

    public init() {}

    // MARK: Scripting

    /// Queues one newline-delimited message from the client.
    public func sendLine(_ line: String) {
        enqueueInbound(Data(line.utf8))
    }

    /// Queues an already-encoded JSON message.
    public func sendJSON(_ value: JSONValue) throws {
        enqueueInbound(try MCPJSON.encode(value))
    }

    /// Simulates the client closing stdin. Buffered messages are still
    /// delivered before end-of-stream.
    public func closeInput() {
        lock.lock()
        if inputClosed {
            lock.unlock()
            return
        }
        inputClosed = true
        let waiter = inboxWaiter
        inboxWaiter = nil
        if waiter == nil {
            inbox.append(nil)
        }
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    private func enqueueInbound(_ data: Data) {
        lock.lock()
        if inputClosed {
            lock.unlock()
            return
        }
        if let waiter = inboxWaiter {
            inboxWaiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }

    // MARK: MCPMessageChannel

    public func receive() async throws -> Data? {
        switch dequeueInbound() {
        case .value(let value):
            return value
        case .wait:
            return await withCheckedContinuation { continuation in
                installInboxWaiter(continuation)
            }
        }
    }

    private func dequeueInbound() -> InboundDecision {
        lock.lock()
        defer { lock.unlock() }
        if !inbox.isEmpty {
            return .value(inbox.removeFirst())
        }
        if inputClosed {
            return .value(nil)
        }
        return .wait
    }

    private func installInboxWaiter(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        if !inbox.isEmpty {
            let value = inbox.removeFirst()
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        if inputClosed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        precondition(inboxWaiter == nil, "MCPInMemoryChannel supports a single receiver")
        inboxWaiter = continuation
        lock.unlock()
    }

    public func send(_ message: Data) async throws {
        guard !message.contains(0x0A), !message.contains(0x0D) else {
            throw MCPTransportError.embeddedNewline
        }
        let waiter = enqueueOutbound(message)
        waiter?.resume(returning: message)
    }

    private func enqueueOutbound(_ message: Data) -> CheckedContinuation<Data?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        if let waiter = outboundWaiter {
            outboundWaiter = nil
            return waiter.continuation
        }
        outbox.append(message)
        return nil
    }

    // MARK: Test observation

    /// Waits for the next server message, or returns `nil` after `timeout`.
    public func nextOutbound(timeout: TimeInterval = 2) async -> Data? {
        switch dequeueOutbound() {
        case .value(let data):
            return data
        case .wait:
            return await withCheckedContinuation { continuation in
                installOutboundWaiter(continuation, timeout: timeout)
            }
        }
    }

    /// Convenience for tests: decodes the next server message.
    public func nextOutboundJSON(timeout: TimeInterval = 2) async throws -> JSONValue? {
        guard let data = await nextOutbound(timeout: timeout) else { return nil }
        return try MCPJSON.decode(data)
    }

    private func dequeueOutbound() -> OutboundDecision {
        lock.lock()
        defer { lock.unlock() }
        if !outbox.isEmpty {
            return .value(outbox.removeFirst())
        }
        return .wait
    }

    private func installOutboundWaiter(
        _ continuation: CheckedContinuation<Data?, Never>,
        timeout: TimeInterval
    ) {
        lock.lock()
        if !outbox.isEmpty {
            let value = outbox.removeFirst()
            lock.unlock()
            continuation.resume(returning: value)
            return
        }
        let token = nextToken
        nextToken &+= 1
        precondition(outboundWaiter == nil, "MCPInMemoryChannel supports a single outbound reader")
        outboundWaiter = OutboundWaiter(token: token, continuation: continuation)
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.expireOutboundWaiter(token: token)
        }
    }

    private func expireOutboundWaiter(token: UInt64) {
        lock.lock()
        guard let waiter = outboundWaiter, waiter.token == token else {
            lock.unlock()
            return
        }
        outboundWaiter = nil
        lock.unlock()
        waiter.continuation.resume(returning: nil)
    }
}
