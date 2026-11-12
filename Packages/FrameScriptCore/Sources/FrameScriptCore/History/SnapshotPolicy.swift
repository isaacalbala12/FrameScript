import Foundation

/// Why a snapshot exists.
public enum SnapshotKind: String, Sendable, Codable, CaseIterable {
    /// Periodic autosave snapshot (F21), throttled by `SnapshotPolicy`.
    case automatic
    /// User-created and labelled snapshot. Never deleted by the policy.
    case named
    /// Taken before an agent / CLI / MCP write (D4). Always taken.
    case externalChange

    public var isNamed: Bool { self == .named }
}

/// The metadata the policy needs. Payloads live elsewhere (the `.fscr` file).
public struct SnapshotRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let kind: SnapshotKind
    public let createdAt: Date
    public let contentHash: UInt64

    public init(
        id: UUID = UUID(),
        kind: SnapshotKind,
        createdAt: Date,
        contentHash: UInt64
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.contentHash = contentHash
    }
}

/// Stable, dependency-free content hashing for change detection.
public enum SnapshotHash {
    /// FNV-1a 64-bit. Fast, stable across launches (unlike `Hashable`), and good
    /// enough to answer "is this the same document content?".
    public static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    public static func fnv1a64(_ string: String) -> UInt64 {
        fnv1a64(Data(string.utf8))
    }
}

/// Pure scheduling policy for version-history snapshots.
///
/// Rules (F21 + D4):
/// - Automatic snapshots are taken at most once every `automaticInterval`
///   (5 minutes by default) and only when the content hash differs from the
///   most recent snapshot.
/// - At most `maximumAutomaticSnapshots` (50 by default) automatic snapshots are
///   kept; the oldest are evicted first. Named snapshots are never evicted.
/// - Named snapshots are always taken when requested.
/// - External-change snapshots are always taken, regardless of time or hash.
/// - External-change snapshots are not counted against the automatic budget:
///   they are rare and explicitly required by D4.
///
/// The policy never mutates records; it decides and reports which existing IDs
/// the caller should drop.
public struct SnapshotPolicy: Sendable, Equatable {
    public var automaticInterval: TimeInterval
    public var maximumAutomaticSnapshots: Int

    public init(
        automaticInterval: TimeInterval = 300,
        maximumAutomaticSnapshots: Int = 50
    ) {
        self.automaticInterval = automaticInterval
        self.maximumAutomaticSnapshots = maximumAutomaticSnapshots
    }

    public enum SkipReason: String, Sendable, Codable, Equatable {
        /// The most recent snapshot already has this content hash.
        case unchanged
        /// Less than `automaticInterval` has passed since the last automatic
        /// snapshot.
        case throttled
    }

    public enum Action: Sendable, Equatable {
        case take
        case skip(SkipReason)
    }

    public struct Decision: Sendable, Equatable {
        public let action: Action
        /// Existing snapshots the caller should delete, oldest first.
        public let evictedIDs: [UUID]

        public init(action: Action, evictedIDs: [UUID] = []) {
            self.action = action
            self.evictedIDs = evictedIDs
        }

        public var shouldTake: Bool { action == .take }
    }

    /// Decides whether to take a snapshot of the given kind right now.
    ///
    /// - Parameters:
    ///   - kind: The trigger that wants a snapshot.
    ///   - contentHash: Hash of the current content (see `SnapshotHash`).
    ///   - existing: Metadata for snapshots already stored, in any order.
    ///   - now: Current time. Injected so tests can use a fake clock.
    public func decide(
        kind: SnapshotKind,
        contentHash: UInt64,
        existing: [SnapshotRecord],
        now: Date
    ) -> Decision {
        switch kind {
        case .named, .externalChange:
            return Decision(action: .take)
        case .automatic:
            let latest = existing.max { lhs, rhs in
                isOlder(lhs, than: rhs)
            }
            if let latest, latest.contentHash == contentHash {
                return Decision(action: .skip(.unchanged))
            }

            let automatics = existing
                .filter { $0.kind == .automatic }
                .sorted { isOlder($0, than: $1) }

            if let last = automatics.last,
               now.timeIntervalSince(last.createdAt) < automaticInterval {
                return Decision(action: .skip(.throttled))
            }

            let projectedCount = automatics.count + 1
            let overflow = max(0, projectedCount - maximumAutomaticSnapshots)
            let evicted = Array(automatics.prefix(overflow)).map(\.id)
            return Decision(action: .take, evictedIDs: evicted)
        }
    }

    private func isOlder(_ lhs: SnapshotRecord, than rhs: SnapshotRecord) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
