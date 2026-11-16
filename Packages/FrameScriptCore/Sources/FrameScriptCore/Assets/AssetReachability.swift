import Foundation

/// Whether an asset's referenced file can still be found.
public enum AssetReachability: String, Codable, Sendable, Hashable {
    case reachable
    case missing

    public var isMissing: Bool { self == .missing }
}

/// One asset's filesystem status after a check.
public struct AssetReachabilityResult: Sendable, Equatable {
    public let assetID: UUID
    /// Best known path. For a file the bookmark tracked to a new location this
    /// is the new path, so the caller can update the stale entry.
    public let path: String
    public let reachability: AssetReachability

    public init(assetID: UUID, path: String, reachability: AssetReachability) {
        self.assetID = assetID
        self.path = path
        self.reachability = reachability
    }

    public var isMissing: Bool { reachability.isMissing }
}

/// Checks every asset against the file system.
///
/// The stored path is tried first. When it is gone, the security-scoped
/// bookmark is resolved: macOS bookmarks follow moves, so a renamed or moved
/// file stays linked instead of being reported missing.
public enum AssetReachabilityChecker {
    public static func check(
        _ assets: [FrameScriptDocument.ProjectAsset],
        projectDirectory: URL? = nil,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [AssetReachabilityResult] {
        assets.map { asset in
            check(asset, projectDirectory: projectDirectory, fileExists: fileExists)
        }
    }

    public static func check(
        _ asset: FrameScriptDocument.ProjectAsset,
        projectDirectory: URL? = nil,
        fileExists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AssetReachabilityResult {
        let storedPath = AssetPath.resolved(asset.path, relativeTo: projectDirectory)
        if !storedPath.isEmpty, fileExists(storedPath) {
            return AssetReachabilityResult(assetID: asset.id, path: storedPath, reachability: .reachable)
        }
        if let bookmarkData = asset.bookmarkData,
           let resolved = AssetBookmark.withAccess(bookmarkData, { url in
               let path = AssetPath.normalized(url.path)
               return fileExists(path) ? path : nil
           }) {
            return AssetReachabilityResult(assetID: asset.id, path: resolved, reachability: .reachable)
        }
        return AssetReachabilityResult(assetID: asset.id, path: storedPath, reachability: .missing)
    }

    /// Applies a report to the library. Returns `true` when anything changed so
    /// the caller can avoid pointless observation churn.
    @discardableResult
    public static func apply(
        _ results: [AssetReachabilityResult],
        to assets: inout [FrameScriptDocument.ProjectAsset]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.assetID, $0) })
        var changed = false
        for index in assets.indices {
            guard let result = byID[assets[index].id] else { continue }
            if !result.path.isEmpty, assets[index].path != result.path {
                assets[index].path = result.path
                changed = true
            }
            if assets[index].isLastKnownMissing != result.isMissing {
                assets[index].isLastKnownMissing = result.isMissing
                changed = true
            }
        }
        return changed
    }
}
