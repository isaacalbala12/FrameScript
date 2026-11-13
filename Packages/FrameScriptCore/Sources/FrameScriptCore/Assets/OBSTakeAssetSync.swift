import Foundation

/// Keeps the asset library in step with OBS recordings.
///
/// A finished take is a real file the user will need in editing, so it becomes
/// an `OBS` asset the first time it appears. Upserts match by take ID first and
/// by normalised path second, which means recovering an interrupted take
/// updates the same entry instead of adding a second one. Deleting a take never
/// removes the asset or the file.
public enum OBSTakeAssetSync {
    /// Creates the library entry for a take. The take must have a file path.
    public static func makeAsset(
        for take: FrameScriptDocument.Take,
        sceneID: UUID
    ) -> FrameScriptDocument.ProjectAsset? {
        let path = AssetPath.normalized(take.filePath)
        guard !path.isEmpty else { return nil }
        return FrameScriptDocument.ProjectAsset(
            path: path,
            bookmarkData: take.bookmarkData,
            kind: .obs,
            tags: [],
            linkedSceneIDs: [sceneID],
            linkedBRollItemIDs: [],
            linkedTakeIDs: [take.id],
            isCopiedIntoProject: false,
            duration: take.duration > 0 ? take.duration : nil
        )
    }

    /// Inserts or updates the asset for a finished take and returns its index.
    @discardableResult
    public static func upsert(
        take: FrameScriptDocument.Take,
        sceneID: UUID,
        into assets: inout [FrameScriptDocument.ProjectAsset]
    ) -> Int? {
        guard let incoming = makeAsset(for: take, sceneID: sceneID) else { return nil }

        let index = assets.firstIndex { $0.linkedTakeIDs.contains(take.id) }
            ?? AssetDeduplication.index(ofPath: incoming.path, in: assets)

        guard let index else {
            assets.append(incoming)
            return assets.count - 1
        }

        var existing = assets[index]
        existing.path = incoming.path
        existing.kind = .obs
        existing.linkedTakeIDs = AssetDeduplication.unique(existing.linkedTakeIDs + [take.id])
        existing.linkedSceneIDs = AssetDeduplication.unique(existing.linkedSceneIDs + [sceneID])
        if let bookmarkData = incoming.bookmarkData, existing.bookmarkData == nil {
            existing.bookmarkData = bookmarkData
        }
        if let duration = incoming.duration {
            existing.duration = duration
        }
        existing.isLastKnownMissing = false
        assets[index] = existing
        return index
    }
}

/// Small mutating helpers behind the inspector's link menus.
public enum AssetLinks {
    @discardableResult
    public static func toggle(sceneID: UUID, in asset: inout FrameScriptDocument.ProjectAsset) -> Bool {
        toggle(sceneID, values: &asset.linkedSceneIDs)
    }

    @discardableResult
    public static func toggle(bRollItemID: UUID, in asset: inout FrameScriptDocument.ProjectAsset) -> Bool {
        toggle(bRollItemID, values: &asset.linkedBRollItemIDs)
    }

    @discardableResult
    public static func toggle(takeID: UUID, in asset: inout FrameScriptDocument.ProjectAsset) -> Bool {
        toggle(takeID, values: &asset.linkedTakeIDs)
    }

    /// Returns `true` when the link was added, `false` when it was removed.
    @discardableResult
    private static func toggle(_ id: UUID, values: inout [UUID]) -> Bool {
        if let index = values.firstIndex(of: id) {
            values.remove(at: index)
            return false
        }
        values.append(id)
        return true
    }
}
