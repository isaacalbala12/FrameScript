import Foundation

/// The asset library's filter state. Kept as a value type so filtering is a
/// pure function that can be unit-tested without SwiftUI.
public struct AssetFilter: Sendable, Equatable {
    public var kind: FrameScriptDocument.AssetKind?
    public var tag: String?
    public var sceneID: UUID?
    public var searchText: String
    public var missingOnly: Bool

    public init(
        kind: FrameScriptDocument.AssetKind? = nil,
        tag: String? = nil,
        sceneID: UUID? = nil,
        searchText: String = "",
        missingOnly: Bool = false
    ) {
        self.kind = kind
        self.tag = tag
        self.sceneID = sceneID
        self.searchText = searchText
        self.missingOnly = missingOnly
    }

    public var isActive: Bool {
        kind != nil || tag != nil || sceneID != nil || missingOnly || !searchText.trimmed.isEmpty
    }
}

public enum AssetSortOrder: String, Codable, CaseIterable, Sendable, Identifiable {
    case name
    case kind
    case recentlyModified

    public var id: String { rawValue }
}

public enum AssetQuery {
    public static func apply(
        _ assets: [FrameScriptDocument.ProjectAsset],
        filter: AssetFilter = AssetFilter(),
        sort: AssetSortOrder = .name
    ) -> [FrameScriptDocument.ProjectAsset] {
        let filtered = assets.filter { matches($0, filter: filter) }
        return sorted(filtered, by: sort)
    }

    public static func matches(
        _ asset: FrameScriptDocument.ProjectAsset,
        filter: AssetFilter
    ) -> Bool {
        if let kind = filter.kind, asset.kind != kind { return false }
        if let tag = filter.tag, !AssetTags.contains(tag, in: asset.tags) { return false }
        if let sceneID = filter.sceneID, !asset.linkedSceneIDs.contains(sceneID) { return false }
        if filter.missingOnly, !asset.isLastKnownMissing { return false }

        let search = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        return searchableFields(of: asset).contains {
            $0.localizedStandardContains(search)
        }
    }

    public static func sorted(
        _ assets: [FrameScriptDocument.ProjectAsset],
        by order: AssetSortOrder
    ) -> [FrameScriptDocument.ProjectAsset] {
        switch order {
        case .name:
            return assets.sorted { lhs, rhs in
                compareNames(lhs, rhs) == .orderedAscending
            }
        case .kind:
            return assets.sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue.localizedStandardCompare(rhs.kind.rawValue) == .orderedAscending
                }
                return compareNames(lhs, rhs) == .orderedAscending
            }
        case .recentlyModified:
            return assets.sorted { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                default:
                    return compareNames(lhs, rhs) == .orderedAscending
                }
            }
        }
    }

    /// Every free tag in use, one entry per spelling, ordered for menus.
    public static func tags(in assets: [FrameScriptDocument.ProjectAsset]) -> [String] {
        AssetTags.normalized(assets.flatMap(\.tags))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every kind present in the library, in the canonical `AssetKind` order.
    public static func kinds(in assets: [FrameScriptDocument.ProjectAsset]) -> [FrameScriptDocument.AssetKind] {
        FrameScriptDocument.AssetKind.allCases.filter { kind in
            assets.contains { $0.kind == kind }
        }
    }

    public static func linkCount(_ asset: FrameScriptDocument.ProjectAsset) -> Int {
        asset.linkedSceneIDs.count + asset.linkedBRollItemIDs.count + asset.linkedTakeIDs.count
    }

    private static func searchableFields(of asset: FrameScriptDocument.ProjectAsset) -> [String] {
        [
            AssetPath.fileName(asset.path),
            AssetPath.baseName(asset.path),
            asset.path,
            asset.kind.rawValue,
            asset.tags.joined(separator: " ")
        ].filter { !$0.isEmpty }
    }

    private static func compareNames(
        _ lhs: FrameScriptDocument.ProjectAsset,
        _ rhs: FrameScriptDocument.ProjectAsset
    ) -> ComparisonResult {
        let left = AssetPath.fileName(lhs.path)
        let right = AssetPath.fileName(rhs.path)
        let result = left.localizedStandardCompare(right)
        if result != .orderedSame { return result }
        return lhs.path.localizedStandardCompare(rhs.path)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
