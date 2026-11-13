import Foundation

/// Filter applied to the board index. Empty sets mean "all".
public struct BoardFilter: Sendable, Equatable {
    public var searchText: String
    public var statuses: Set<FrameScriptDocument.ProductionStatus>
    public var topics: Set<String>
    public var videoTypes: Set<String>
    /// Only projects with at least one pending task.
    public var unfinishedOnly: Bool

    public init(
        searchText: String = "",
        statuses: Set<FrameScriptDocument.ProductionStatus> = [],
        topics: Set<String> = [],
        videoTypes: Set<String> = [],
        unfinishedOnly: Bool = false
    ) {
        self.searchText = searchText
        self.statuses = statuses
        self.topics = topics
        self.videoTypes = videoTypes
        self.unfinishedOnly = unfinishedOnly
    }

    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !statuses.isEmpty
            || !topics.isEmpty
            || !videoTypes.isEmpty
            || unfinishedOnly
    }

    public func matches(_ summary: BoardProjectSummary) -> Bool {
        if !statuses.isEmpty, !statuses.contains(summary.productionStatus) {
            return false
        }
        if !topics.isEmpty, !topics.contains(where: { BoardCatalog.matches($0, summary.topic) }) {
            return false
        }
        if !videoTypes.isEmpty, !videoTypes.contains(where: { BoardCatalog.matches($0, summary.videoType) }) {
            return false
        }
        if unfinishedOnly, summary.pending.isEmpty {
            return false
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = [
            summary.title,
            summary.topic,
            summary.videoType,
            summary.fileName,
            summary.fileURL.deletingLastPathComponent().lastPathComponent
        ]
        return haystack.contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

public enum BoardGrouping: String, Sendable, CaseIterable, Equatable {
    case status
    case topic
    case videoType
    case none
}

public enum BoardSortKey: String, Sendable, CaseIterable, Equatable {
    case updatedAt
    case title
    case status
    case targetDate
    case publishDate
    case duration
    case pending
}

public struct BoardSort: Sendable, Equatable {
    public var key: BoardSortKey
    public var ascending: Bool

    public init(key: BoardSortKey = .updatedAt, ascending: Bool = false) {
        self.key = key
        self.ascending = ascending
    }

    public func sorted(_ summaries: [BoardProjectSummary]) -> [BoardProjectSummary] {
        summaries.sorted { lhs, rhs in
            if let decision = orderedBefore(lhs, rhs) {
                return decision
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Returns `nil` when both values compare equal so the caller falls back to
    /// the title tie-breaker in a stable direction.
    private func orderedBefore(_ lhs: BoardProjectSummary, _ rhs: BoardProjectSummary) -> Bool? {
        switch key {
        case .updatedAt:
            return compareValues(lhs.updatedAt, rhs.updatedAt)
        case .title:
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if comparison == .orderedSame { return nil }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        case .status:
            return compareValues(
                BoardProductionStatus.index(of: lhs.productionStatus),
                BoardProductionStatus.index(of: rhs.productionStatus)
            )
        case .targetDate:
            return compareOptionalDates(lhs.targetDate, rhs.targetDate)
        case .publishDate:
            return compareOptionalDates(lhs.publishDate, rhs.publishDate)
        case .duration:
            return compareValues(lhs.duration.seconds, rhs.duration.seconds)
        case .pending:
            return compareValues(lhs.pending.total, rhs.pending.total)
        }
    }

    /// Dates without a value always sort last, in both directions, so an
    /// unscheduled project does not lead a descending deadline list.
    private func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (nil, _):
            return false
        case (_, nil):
            return true
        case let (left?, right?):
            return compareValues(left, right)
        }
    }

    private func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
        if lhs == rhs { return nil }
        return ascending ? lhs < rhs : lhs > rhs
    }
}

public struct BoardGroup: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case all
        case status(FrameScriptDocument.ProductionStatus)
        case topic(String)
        case videoType(String)
    }

    public let kind: Kind
    public let summaries: [BoardProjectSummary]

    public init(kind: Kind, summaries: [BoardProjectSummary]) {
        self.kind = kind
        self.summaries = summaries
    }

    public var id: String {
        switch kind {
        case .all: "all"
        case .status(let status): "status:\(status.rawValue)"
        case .topic(let topic): "topic:\(BoardCatalog.folded(topic))"
        case .videoType(let type): "type:\(BoardCatalog.folded(type))"
        }
    }

    public var isEmpty: Bool {
        summaries.isEmpty
    }
}

/// Filters, groups and sorts a board index in one pure step. The UI calls this
/// with the current filter/sort state; tests call it directly.
public enum BoardQuery {
    public static func groups(
        summaries: [BoardProjectSummary],
        filter: BoardFilter,
        grouping: BoardGrouping,
        sort: BoardSort
    ) -> [BoardGroup] {
        let matching = summaries.filter(filter.matches)
        switch grouping {
        case .none:
            return [BoardGroup(kind: .all, summaries: sort.sorted(matching))]
        case .status:
            return BoardProductionStatus.order.compactMap { status in
                let group = matching.filter { $0.productionStatus == status }
                guard !group.isEmpty else { return nil }
                return BoardGroup(kind: .status(status), summaries: sort.sorted(group))
            }
        case .topic:
            return grouped(matching, sort: sort) { summary in
                GroupKey(kind: .topic(summary.topic), title: summary.topic)
            }
        case .videoType:
            return grouped(matching, sort: sort) { summary in
                GroupKey(kind: .videoType(summary.videoType), title: summary.videoType)
            }
        }
    }

    /// Groups without a value are shown last and use an empty title; the UI
    /// replaces it with its localized "Unclassified" label.
    private struct GroupKey {
        let kind: BoardGroup.Kind
        let title: String
    }

    private static func grouped(
        _ summaries: [BoardProjectSummary],
        sort: BoardSort,
        key: (BoardProjectSummary) -> GroupKey
    ) -> [BoardGroup] {
        var buckets: [String: (title: String, kind: BoardGroup.Kind, items: [BoardProjectSummary])] = [:]
        for summary in summaries {
            let groupKey = key(summary)
            let id = BoardGroup(kind: groupKey.kind, summaries: []).id
            buckets[id, default: (groupKey.title, groupKey.kind, [])].items.append(summary)
        }
        return buckets.values
            .sorted { lhs, rhs in
                if lhs.title.isEmpty != rhs.title.isEmpty {
                    return !lhs.title.isEmpty
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .map { BoardGroup(kind: $0.kind, summaries: sort.sorted($0.items)) }
    }

    /// Distinct topic/type values from a catalog and the current projects, so
    /// filters offer new values written by another app even before the user
    /// edits the catalog.
    public static func availableTopics(
        catalog: BoardCatalog,
        summaries: [BoardProjectSummary]
    ) -> [String] {
        merged(catalog.topics, summaries.map(\.topic))
    }

    public static func availableVideoTypes(
        catalog: BoardCatalog,
        summaries: [BoardProjectSummary]
    ) -> [String] {
        merged(catalog.videoTypes, summaries.map(\.videoType))
    }

    private static func merged(_ first: [String], _ second: [String]) -> [String] {
        var result: [String] = []
        for value in first + second {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !result.contains(where: { BoardCatalog.matches($0, trimmed) }) else {
                continue
            }
            result.append(trimmed)
        }
        return result.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }
}
