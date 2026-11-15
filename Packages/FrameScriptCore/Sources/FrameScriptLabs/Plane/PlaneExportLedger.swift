import Foundation

/// The caller-owned mapping from FrameScript task external id to Plane work-item id.
///
/// The core module never persists this value. The app stores it (for example in
/// its project file or settings) and passes it back on the next export, so a
/// `404` from Plane can be distinguished from "not exported yet".
///
/// A `404` on a ledger id can leave the entry in place when recreation is
/// disabled, so a later export does not silently create a replacement. Use
/// `remove(taskExternalID:)` to clear it deliberately.
///
/// JSON encoding is a flat object: `{ "framescript:...": "<plane uuid>", ... }`.
public struct PlaneExportLedger: Sendable, Equatable, Codable {
    public private(set) var workItemIDsByTaskExternalID: [String: String]

    public init(workItemIDsByTaskExternalID: [String: String] = [:]) {
        self.workItemIDsByTaskExternalID = workItemIDsByTaskExternalID
    }

    public subscript(taskExternalID: String) -> String? {
        get { workItemIDsByTaskExternalID[taskExternalID] }
        set {
            if let newValue {
                workItemIDsByTaskExternalID[taskExternalID] = newValue
            } else {
                workItemIDsByTaskExternalID.removeValue(forKey: taskExternalID)
            }
        }
    }

    public mutating func record(workItemID: String, forTaskExternalID taskExternalID: String) {
        workItemIDsByTaskExternalID[taskExternalID] = workItemID
    }

    public mutating func remove(taskExternalID: String) {
        workItemIDsByTaskExternalID.removeValue(forKey: taskExternalID)
    }

    public var isEmpty: Bool {
        workItemIDsByTaskExternalID.isEmpty
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.workItemIDsByTaskExternalID = try container.decode([String: String].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(workItemIDsByTaskExternalID)
    }
}

/// Controls what an export does when the ledger points at a work item Plane no
/// longer has.
public struct PlaneExportPolicy: Sendable, Equatable {
    /// When `false` (the default), a `404` on a ledger id is reported as
    /// `deleted`. The ledger entry is kept, so a later export cannot silently
    /// take the "never exported" path and create a replacement. The caller can
    /// remove the entry or retry with recreation enabled.
    public var recreateDeletedWorkItems: Bool

    public init(recreateDeletedWorkItems: Bool = false) {
        self.recreateDeletedWorkItems = recreateDeletedWorkItems
    }
}

/// The result of exporting one planned task.
public enum PlaneExportOutcome: Sendable, Equatable {
    /// Plane had no matching work item and one was created.
    case created(taskExternalID: String, workItemID: String)
    /// A ledger id was verified, or the filtered list produced a unique match.
    case verified(taskExternalID: String, workItemID: String)
    /// The ledger id returned `404` and the caller allowed a replacement.
    case recreated(taskExternalID: String, workItemID: String)
    /// The ledger id returned `404` and recreation was not allowed. The ledger
    /// entry is kept so the caller decides when to clear it.
    case deleted(taskExternalID: String)
    /// The task failed without aborting the rest of the export.
    case failed(taskExternalID: String, error: PlaneError)

    public var taskExternalID: String {
        switch self {
        case .created(let id, _),
             .verified(let id, _),
             .recreated(let id, _),
             .deleted(let id),
             .failed(let id, _):
            return id
        }
    }

    public var workItemID: String? {
        switch self {
        case .created(_, let id),
             .verified(_, let id),
             .recreated(_, let id):
            return id
        case .deleted, .failed:
            return nil
        }
    }
}

/// A non-blocking observation from an export.
public struct PlaneExportWarning: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The filtered list returned rows with the planned name but no exact
        /// `external_id` echo. The export creates a new work item because the
        /// caller-owned ledger is authoritative.
        case possibleDuplicateByName
    }

    public let taskExternalID: String
    public let kind: Kind
    public let candidates: [PlaneWorkItem]

    public init(taskExternalID: String, kind: Kind, candidates: [PlaneWorkItem]) {
        self.taskExternalID = taskExternalID
        self.kind = kind
        self.candidates = candidates
    }
}

/// The complete result of an export, including the ledger the caller should
/// persist and any names that had to be shortened.
public struct PlaneExportReport: Sendable, Equatable {
    public let outcomes: [PlaneExportOutcome]
    /// Non-blocking warnings about possible duplicates. They never prevent a
    /// create; only an exact echoed `external_id` reuses an existing item.
    public let warnings: [PlaneExportWarning]
    /// Ledger the caller should persist. It may retain a stale id when a
    /// `deleted` outcome was returned, so a later export cannot bypass the
    /// recreation policy.
    public let ledger: PlaneExportLedger
    /// External ids whose planned name exceeded Plane's 255-character limit.
    public let truncatedNameTaskExternalIDs: [String]

    public init(
        outcomes: [PlaneExportOutcome],
        warnings: [PlaneExportWarning] = [],
        ledger: PlaneExportLedger,
        truncatedNameTaskExternalIDs: [String]
    ) {
        self.outcomes = outcomes
        self.warnings = warnings
        self.ledger = ledger
        self.truncatedNameTaskExternalIDs = truncatedNameTaskExternalIDs
    }

    /// Created/verified/recreated work-item ids keyed by task external id.
    public var workItemIDsByTaskExternalID: [String: String] {
        var result: [String: String] = [:]
        for outcome in outcomes {
            if let workItemID = outcome.workItemID {
                result[outcome.taskExternalID] = workItemID
            }
        }
        return result
    }
}
