import Foundation

/// One user-visible change made from the board or the project info popover.
///
/// `nil` optional fields mean "leave unchanged"; clearing a date has its own
/// flag so "no date" can be distinguished from "not edited".
public struct BoardProjectEdit: Sendable, Equatable {
    public var topic: String?
    public var videoType: String?
    public var productionStatus: FrameScriptDocument.ProductionStatus?
    public var targetDate: Date?
    public var publishDate: Date?
    public var clearsTargetDate: Bool
    public var clearsPublishDate: Bool

    public init(
        topic: String? = nil,
        videoType: String? = nil,
        productionStatus: FrameScriptDocument.ProductionStatus? = nil,
        targetDate: Date? = nil,
        publishDate: Date? = nil,
        clearsTargetDate: Bool = false,
        clearsPublishDate: Bool = false
    ) {
        self.topic = topic
        self.videoType = videoType
        self.productionStatus = productionStatus
        self.targetDate = targetDate
        self.publishDate = publishDate
        self.clearsTargetDate = clearsTargetDate
        self.clearsPublishDate = clearsPublishDate
    }

    public var isEmpty: Bool {
        topic == nil
            && videoType == nil
            && productionStatus == nil
            && targetDate == nil
            && publishDate == nil
            && !clearsTargetDate
            && !clearsPublishDate
    }

    /// True when `summary` reflects every field this edit asked for.
    ///
    /// Re-reading the file after a write is how the board notices that the
    /// app's external-change prompt resolved by reloading instead of saving.
    public func isSatisfied(by summary: BoardProjectSummary) -> Bool {
        if let topic,
           summary.topic != topic.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }
        if let videoType,
           summary.videoType != videoType.trimmingCharacters(in: .whitespacesAndNewlines) {
            return false
        }
        if let productionStatus,
           summary.productionStatus != productionStatus {
            return false
        }
        if clearsTargetDate {
            if summary.targetDate != nil { return false }
        } else if let targetDate,
                  !Self.matches(summary.targetDate, targetDate) {
            return false
        }
        if clearsPublishDate {
            if summary.publishDate != nil { return false }
        } else if let publishDate,
                  !Self.matches(summary.publishDate, publishDate) {
            return false
        }
        return true
    }

    private static func matches(_ stored: Date?, _ requested: Date) -> Bool {
        guard let stored else { return false }
        return abs(stored.timeIntervalSince1970 - requested.timeIntervalSince1970) < 0.001
    }
}

/// Pure document mutation shared by the board writer and its tests.
public enum BoardDocumentEditor {
    /// Applies an edit to a document. Only classification fields change; scene
    /// content, anchors and history are left untouched. `updatedAt` moves to
    /// `now` so the list can order by the last real edit.
    public static func apply(
        _ edit: BoardProjectEdit,
        to document: inout FrameScriptDocument,
        now: Date = Date()
    ) {
        if let topic = edit.topic {
            document.project.topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let videoType = edit.videoType {
            document.project.videoType = videoType.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let status = edit.productionStatus {
            document.project.productionStatus = status
        }
        if edit.clearsTargetDate {
            document.project.targetDate = nil
        } else if let targetDate = edit.targetDate {
            document.project.targetDate = targetDate
        }
        if edit.clearsPublishDate {
            document.project.publishDate = nil
        } else if let publishDate = edit.publishDate {
            document.project.publishDate = publishDate
        }
        guard !edit.isEmpty else { return }
        document.project.updatedAt = now
    }
}

/// Ordering and transition helpers for the six production states.
public enum BoardProductionStatus {
    public static let order: [FrameScriptDocument.ProductionStatus] = [
        .idea, .outline, .script, .recorded, .edited, .published
    ]

    public static func index(of status: FrameScriptDocument.ProductionStatus) -> Int {
        order.firstIndex(of: status) ?? 0
    }

    public static func next(after status: FrameScriptDocument.ProductionStatus) -> FrameScriptDocument.ProductionStatus? {
        let index = index(of: status)
        guard index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    public static func previous(before status: FrameScriptDocument.ProductionStatus) -> FrameScriptDocument.ProductionStatus? {
        let index = index(of: status)
        guard index > 0 else { return nil }
        return order[index - 1]
    }

    public static func transition(
        from: FrameScriptDocument.ProductionStatus,
        to: FrameScriptDocument.ProductionStatus
    ) -> BoardStatusTransition {
        let fromIndex = index(of: from)
        let toIndex = index(of: to)
        if fromIndex == toIndex { return .unchanged }
        return fromIndex < toIndex ? .forward : .backward
    }
}

public enum BoardStatusTransition: Sendable, Equatable {
    case unchanged
    case forward
    case backward

    public var isChanging: Bool {
        self != .unchanged
    }
}

/// Seeded classification vocabulary and the template → video-type defaults.
///
/// The lists are only seeds: the user can edit the catalog in Settings. No
/// server, account or project id is implied by them.
public enum BoardTemplateDefaults {
    /// Common simracing games/topics plus the user's own project.
    public static let topics: [String] = [
        "Assetto Corsa",
        "Assetto Corsa Competizione",
        "Assetto Corsa EVO",
        "iRacing",
        "Le Mans Ultimate",
        "EA Sports WRC",
        "Gran Turismo 7",
        "Automobilista 2",
        "rFactor 2",
        "RaceRoom",
        "Vantare"
    ]

    /// The video types named by the board brief.
    public static let videoTypes: [String] = [
        "análisis",
        "gameplay",
        "review de mod/coche",
        "comparativa",
        "noticia",
        "crónica",
        "tutorial",
        "Vantare"
    ]

    /// Built-in template names are stable English identifiers, independent of
    /// the interface language.
    public static func videoType(forTemplateNamed name: String) -> String? {
        switch name {
        case "Simracing Update Analysis":
            "análisis"
        case "Simracing Mod or Car Review", "Product Review":
            "review de mod/coche"
        case "Simracing Comparison":
            "comparativa"
        case "Simracing News and Reaction":
            "noticia"
        case "Simracing Race Chronicle":
            "crónica"
        case "Tutorial":
            "tutorial"
        default:
            nil
        }
    }
}

/// Editable, normalized list of topics and video types.
public struct BoardCatalog: Sendable, Equatable, Codable {
    public private(set) var topics: [String]
    public private(set) var videoTypes: [String]

    public init(topics: [String] = [], videoTypes: [String] = []) {
        self.topics = Self.normalized(topics)
        self.videoTypes = Self.normalized(videoTypes)
    }

    public static let seeded = BoardCatalog(
        topics: BoardTemplateDefaults.topics,
        videoTypes: BoardTemplateDefaults.videoTypes
    )

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            topics: try container.decodeIfPresent([String].self, forKey: .topics) ?? [],
            videoTypes: try container.decodeIfPresent([String].self, forKey: .videoTypes) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topics, forKey: .topics)
        try container.encode(videoTypes, forKey: .videoTypes)
    }

    private enum CodingKeys: String, CodingKey {
        case topics
        case videoTypes
    }

    // MARK: Editing

    @discardableResult
    public mutating func addTopic(_ value: String) -> Bool {
        guard let normalized = Self.normalizedValue(value),
              !topics.contains(where: { Self.matches($0, normalized) }) else {
            return false
        }
        topics.append(normalized)
        return true
    }

    @discardableResult
    public mutating func addVideoType(_ value: String) -> Bool {
        guard let normalized = Self.normalizedValue(value),
              !videoTypes.contains(where: { Self.matches($0, normalized) }) else {
            return false
        }
        videoTypes.append(normalized)
        return true
    }

    public mutating func removeTopic(_ value: String) {
        topics.removeAll { Self.matches($0, value) }
    }

    public mutating func removeVideoType(_ value: String) {
        videoTypes.removeAll { Self.matches($0, value) }
    }

    /// Restores the seeded vocabulary without deleting values the user added.
    public mutating func restoreSeeds() {
        for value in BoardTemplateDefaults.topics where !topics.contains(where: { Self.matches($0, value) }) {
            topics.append(value)
        }
        for value in BoardTemplateDefaults.videoTypes where !videoTypes.contains(where: { Self.matches($0, value) }) {
            videoTypes.append(value)
        }
        topics = Self.normalized(topics)
        videoTypes = Self.normalized(videoTypes)
    }

    // MARK: Suggestions

    public func topicSuggestions(for query: String, limit: Int = 6) -> [String] {
        Self.suggestions(in: topics, for: query, limit: limit)
    }

    public func videoTypeSuggestions(for query: String, limit: Int = 6) -> [String] {
        Self.suggestions(in: videoTypes, for: query, limit: limit)
    }

    public static func suggestions(in values: [String], for query: String, limit: Int = 6) -> [String] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = Self.folded(trimmed)
        guard !normalizedQuery.isEmpty else {
            return Array(values.prefix(limit))
        }

        var prefixMatches: [String] = []
        var containsMatches: [String] = []
        for value in values {
            let folded = Self.folded(value)
            if folded == normalizedQuery { continue }
            if folded.hasPrefix(normalizedQuery) {
                prefixMatches.append(value)
            } else if folded.contains(normalizedQuery) {
                containsMatches.append(value)
            }
        }
        prefixMatches.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        containsMatches.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Array((prefixMatches + containsMatches).prefix(limit))
    }

    // MARK: Normalization

    private static func normalized(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            guard let normalized = normalizedValue(value),
                  !result.contains(where: { matches($0, normalized) }) else {
                continue
            }
            result.append(normalized)
        }
        return result
    }

    private static func normalizedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }

    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        folded(lhs) == folded(rhs)
    }

    static func folded(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Converts a calendar day to the `YYYY-MM-DD` value Plane expects.
public enum BoardPlaneDate {
    public static func make(
        from date: Date?,
        calendar: Calendar = Calendar(identifier: .gregorian),
        timeZone: TimeZone = .current
    ) -> PlaneDate? {
        guard let date else { return nil }
        var calendar = calendar
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return nil
        }
        return PlaneDate(year: year, month: month, day: day)
    }
}
