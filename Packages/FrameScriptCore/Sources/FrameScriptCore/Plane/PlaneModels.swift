import Foundation

/// Priority values accepted by the Plane work-item API.
///
/// The v1 docs list `urgent`, `high`, `medium`, `low` and `none`.
public enum PlanePriority: String, Sendable, Codable, CaseIterable, Equatable {
    case urgent
    case high
    case medium
    case low
    case none
}

/// A calendar date in the `YYYY-MM-DD` form Plane expects for `target_date`.
///
/// Plane stores due dates without a time zone. Using a `Date` would make the
/// value depend on the caller's calendar, so the exporter keeps the three
/// components explicitly.
public struct PlaneDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Creates a date after validating that the components exist in the
    /// Gregorian calendar (for example, 2026-02-29 is rejected).
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year) else { return nil }
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = utc
        components.year = year
        components.month = month
        components.day = day

        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }

        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses the strict `YYYY-MM-DD` representation Plane returns.
    public init?(iso8601 string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    public var iso8601: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso8601 }

    public static func < (lhs: PlaneDate, rhs: PlaneDate) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = PlaneDate(iso8601: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a date in YYYY-MM-DD format, got \(value)"
            )
        }
        self = date
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso8601)
    }
}

/// The kinds of pending task FrameScript can export.
///
/// Raw values are stable identifiers. User-visible names come from
/// `PlaneExportLabels`, so the core package does not hardcode a language.
public enum PlaneTaskKind: String, Sendable, Codable, CaseIterable, Hashable {
    case grabar
    case conseguirBroll
    case editar
    case investigar
    case manual
}

/// A pending task as seen by the exporter. This is deliberately independent
/// from the app's own task model so the core package stays UI-free.
public struct PlanePendingTask: Sendable, Equatable, Identifiable {
    /// Stable identifier of the task inside its FrameScript project.
    public let id: String
    /// Stable identifier of the FrameScript project the task belongs to.
    public let projectID: String
    public let title: String
    public let kind: PlaneTaskKind
    public let sceneTitle: String
    public let projectTitle: String
    public let dueDate: PlaneDate?

    public init(
        id: String,
        projectID: String,
        title: String,
        kind: PlaneTaskKind,
        sceneTitle: String,
        projectTitle: String,
        dueDate: PlaneDate? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.sceneTitle = sceneTitle
        self.projectTitle = projectTitle
        self.dueDate = dueDate
    }
}

/// A create-work-item request body.
///
/// Property names map to the JSON keys documented for
/// `POST /api/v1/workspaces/{slug}/projects/{project_id}/work-items/`.
/// `state` and `labels` carry Plane UUIDs, as the v1 endpoint expects.
public struct PlaneWorkItemDraft: Sendable, Equatable, Encodable {
    public var name: String
    public var descriptionHTML: String
    public var priority: PlanePriority
    public var stateID: String?
    public var labelIDs: [String]?
    public var targetDate: PlaneDate?
    public var externalID: String
    public var externalSource: String

    public init(
        name: String,
        descriptionHTML: String,
        priority: PlanePriority = .none,
        stateID: String? = nil,
        labelIDs: [String]? = nil,
        targetDate: PlaneDate? = nil,
        externalID: String,
        externalSource: String
    ) {
        self.name = name
        self.descriptionHTML = descriptionHTML
        self.priority = priority
        self.stateID = stateID
        self.labelIDs = labelIDs
        self.targetDate = targetDate
        self.externalID = externalID
        self.externalSource = externalSource
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case descriptionHTML = "description_html"
        case priority
        case stateID = "state"
        case labelIDs = "labels"
        case targetDate = "target_date"
        case externalID = "external_id"
        case externalSource = "external_source"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(descriptionHTML, forKey: .descriptionHTML)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(stateID, forKey: .stateID)
        try container.encodeIfPresent(labelIDs, forKey: .labelIDs)
        try container.encodeIfPresent(targetDate, forKey: .targetDate)
        try container.encode(externalID, forKey: .externalID)
        try container.encode(externalSource, forKey: .externalSource)
    }
}

/// A project returned by `GET /api/v1/workspaces/{slug}/projects/`.
public struct PlaneProject: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
    public let identifier: String?

    public init(id: String, name: String, identifier: String? = nil) {
        self.id = id
        self.name = name
        self.identifier = identifier
    }
}

/// A workflow state returned by `GET .../projects/{project_id}/states/`.
public struct PlaneState: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
    public let group: String?
    public let color: String?
    public let sequence: Int?

    public init(id: String, name: String, group: String? = nil, color: String? = nil, sequence: Int? = nil) {
        self.id = id
        self.name = name
        self.group = group
        self.color = color
        self.sequence = sequence
    }
}

/// A label returned by `GET .../projects/{project_id}/labels/`.
public struct PlaneLabel: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
    public let color: String?

    public init(id: String, name: String, color: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// The subset of a Plane work item FrameScript needs for idempotent export.
public struct PlaneWorkItem: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let name: String
    public let sequenceID: Int?
    public let externalID: String?
    public let externalSource: String?
    public let targetDate: PlaneDate?

    public init(
        id: String,
        name: String,
        sequenceID: Int? = nil,
        externalID: String? = nil,
        externalSource: String? = nil,
        targetDate: PlaneDate? = nil
    ) {
        self.id = id
        self.name = name
        self.sequenceID = sequenceID
        self.externalID = externalID
        self.externalSource = externalSource
        self.targetDate = targetDate
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sequenceID = "sequence_id"
        case externalID = "external_id"
        case externalSource = "external_source"
        case targetDate = "target_date"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.sequenceID = try container.decodeIfPresent(Int.self, forKey: .sequenceID)
        self.externalID = try container.decodeIfPresent(String.self, forKey: .externalID)
        self.externalSource = try container.decodeIfPresent(String.self, forKey: .externalSource)
        if let rawDate = try container.decodeIfPresent(String.self, forKey: .targetDate) {
            // Some self-hosted versions return an empty string for "no date".
            self.targetDate = PlaneDate(iso8601: rawDate)
        } else {
            self.targetDate = nil
        }
    }
}

/// Plane limits work-item names to 255 characters.
///
/// `String.prefix` counts characters (extended grapheme clusters), so composed
/// sequences and emoji are never split in the middle.
public enum PlaneWorkItemName {
    public static let maximumLength = 255

    public static func truncated(_ name: String) -> String {
        guard name.count > maximumLength else { return name }
        return String(name.prefix(maximumLength))
    }

    public static func isTruncated(_ name: String) -> Bool {
        name.count > maximumLength
    }
}

/// Outcome of a single filtered lookup for an existing work item.
///
/// The documented v1 list rows do not include `external_id`, and self-hosted
/// versions may ignore the filter. A single page is therefore not always
/// enough to prove that a work item does not exist; `cannotVerify` carries the
/// candidates so the caller can resolve the ambiguity instead of creating a
/// duplicate.
public enum PlaneWorkItemLookup: Sendable, Equatable {
    case found(PlaneWorkItem)
    case notFound
    case cannotVerify(candidates: [PlaneWorkItem])

    public var workItem: PlaneWorkItem? {
        if case .found(let item) = self { return item }
        return nil
    }

    public var candidates: [PlaneWorkItem] {
        if case .cannotVerify(let candidates) = self { return candidates }
        return []
    }
}

/// Rate-limit information reported by Plane on every response.
public struct PlaneRateLimit: Sendable, Equatable {
    /// Value of `X-RateLimit-Remaining`.
    public let remaining: Int?
    /// `X-RateLimit-Reset` converted from UTC epoch seconds.
    public let resetAt: Date?

    public init(remaining: Int?, resetAt: Date?) {
        self.remaining = remaining
        self.resetAt = resetAt
    }
}

/// A transport-independent HTTP response.
public struct PlaneHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    /// Header names are stored lowercased so lookups are case-insensitive.
    public let headers: [String: String]
    public let data: Data

    public init(statusCode: Int, headers: [String: String], data: Data) {
        self.statusCode = statusCode
        self.data = data
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (name, value) in headers {
            normalized[name.lowercased()] = value
        }
        self.headers = normalized
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}
