import Foundation

/// A small multicast `AsyncStream` hub.
///
/// Each call to `makeStream()` registers a fresh consumer. Elements yielded while
/// a consumer is attached are delivered to all attached consumers with the chosen
/// buffering policy. This lets the UI and a test observe `OBSClient` streams at
/// the same time.
public final class OBSStreamHub<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy

    public init(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .bufferingNewest(256)
    ) {
        self.bufferingPolicy = bufferingPolicy
    }

    public func makeStream() -> AsyncStream<Element> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Element>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func yield(_ element: Element) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(element)
        }
    }

    /// Completes every attached stream. The hub can still be reused afterwards.
    public func finish() {
        lock.lock()
        let current = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in current {
            continuation.finish()
        }
    }
}
