import Foundation

/// View filter for the production checklist.
///
/// An empty `kinds` set means "all kinds"; a nil `sceneID` means "all scenes".
/// Project-level items (claims without a scene, publishing packs, manual tasks
/// with no scene) only appear when no scene filter is active.
public struct ProductionFilter: Sendable, Equatable {
    public var kinds: Set<ProductionItemKind>
    public var sceneID: UUID?
    public var showsDone: Bool

    public init(
        kinds: Set<ProductionItemKind> = [],
        sceneID: UUID? = nil,
        showsDone: Bool = true
    ) {
        self.kinds = kinds
        self.sceneID = sceneID
        self.showsDone = showsDone
    }

    public func matches(_ item: ProductionItem) -> Bool {
        if !showsDone && item.isDone { return false }
        if let sceneID, item.sceneID != sceneID { return false }
        if !kinds.isEmpty && !kinds.contains(item.kind) { return false }
        return true
    }

    public func apply(to items: [ProductionItem]) -> [ProductionItem] {
        items.filter(matches)
    }
}

public enum ProductionGrouping: String, Sendable, CaseIterable, Identifiable, Hashable {
    case scene
    case kind

    public var id: String { rawValue }
}

/// One rendered section of the checklist. `kind` is set when grouping by kind;
/// `sceneID`/`sceneOrder`/`sceneTitle` are set when grouping by scene.
public struct ProductionSection: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: ProductionItemKind?
    public let sceneID: UUID?
    public let sceneOrder: Int?
    public let sceneTitle: String
    public let items: [ProductionItem]

    public init(
        id: String,
        kind: ProductionItemKind? = nil,
        sceneID: UUID? = nil,
        sceneOrder: Int? = nil,
        sceneTitle: String = "",
        items: [ProductionItem]
    ) {
        self.id = id
        self.kind = kind
        self.sceneID = sceneID
        self.sceneOrder = sceneOrder
        self.sceneTitle = sceneTitle
        self.items = items
    }
}

/// Deterministic grouping used by the panel and by tests.
public enum ProductionGrouper {
    public static func sections(
        from items: [ProductionItem],
        grouping: ProductionGrouping
    ) -> [ProductionSection] {
        switch grouping {
        case .kind:
            return ProductionItemKind.allCases.compactMap { kind in
                let matching = items.filter { $0.kind == kind }.sorted(by: itemSort)
                guard !matching.isEmpty else { return nil }
                return ProductionSection(
                    id: "kind:\(kind.rawValue)",
                    kind: kind,
                    items: matching
                )
            }

        case .scene:
            var byScene: [UUID: [ProductionItem]] = [:]
            var projectItems: [ProductionItem] = []
            for item in items {
                if let sceneID = item.sceneID {
                    byScene[sceneID, default: []].append(item)
                } else {
                    projectItems.append(item)
                }
            }

            let sceneSections = byScene.compactMap { sceneID, sceneItems -> ProductionSection? in
                let sorted = sceneItems.sorted(by: itemSort)
                guard let first = sorted.first else { return nil }
                return ProductionSection(
                    id: "scene:\(sceneID.uuidString)",
                    sceneID: sceneID,
                    sceneOrder: first.sceneOrder,
                    sceneTitle: first.sceneTitle,
                    items: sorted
                )
            }
            .sorted { lhs, rhs in
                let leftOrder = lhs.sceneOrder ?? Int.max
                let rightOrder = rhs.sceneOrder ?? Int.max
                if leftOrder != rightOrder { return leftOrder < rightOrder }
                return lhs.id < rhs.id
            }

            var sections = sceneSections
            if !projectItems.isEmpty {
                sections.append(
                    ProductionSection(
                        id: "scene:project",
                        items: projectItems.sorted(by: itemSort)
                    )
                )
            }
            return sections
        }
    }

    /// Pending rows first, then the checklist's own kind order, then document
    /// order. Manual rows without a source index follow derived rows.
    public static func itemSort(_ lhs: ProductionItem, _ rhs: ProductionItem) -> Bool {
        if lhs.isDone != rhs.isDone { return !lhs.isDone }

        let leftKind = ProductionItemKind.allCases.firstIndex(of: lhs.kind) ?? Int.max
        let rightKind = ProductionItemKind.allCases.firstIndex(of: rhs.kind) ?? Int.max
        if leftKind != rightKind { return leftKind < rightKind }

        // Automatic work comes before free-form notes of the same kind.
        let leftManual = lhs.reason == .manualTask
        let rightManual = rhs.reason == .manualTask
        if leftManual != rightManual { return !leftManual }

        let leftIndex = lhs.sourceIndex ?? Int.max
        let rightIndex = rhs.sourceIndex ?? Int.max
        if leftIndex != rightIndex { return leftIndex < rightIndex }

        return lhs.id < rhs.id
    }
}
