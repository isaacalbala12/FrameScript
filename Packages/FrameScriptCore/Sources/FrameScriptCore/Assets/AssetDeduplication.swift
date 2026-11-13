import Foundation

/// Tag normalisation and duplicate detection for the project asset library.
///
/// Adding the same file twice must not create two entries, and re-adding a file
/// should enrich the existing one (tags, links, metadata) instead of dropping
/// what the user already organised.
public enum AssetTags {
    /// Trims tags, drops empties and removes case-insensitive duplicates while
    /// preserving the first spelling and order.
    public static func normalized(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func contains(_ tag: String, in tags: [String]) -> Bool {
        let key = normalizedKey(tag)
        guard !key.isEmpty else { return false }
        return tags.contains { normalizedKey($0) == key }
    }

    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        normalized(tags + [tag])
    }

    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        let key = normalizedKey(tag)
        return tags.filter { normalizedKey($0) != key }
    }

    private static func normalizedKey(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

public enum AssetDeduplication {
    /// Index of the existing asset that references the same file, if any.
    public static func index(of url: URL, in assets: [FrameScriptDocument.ProjectAsset]) -> Int? {
        index(ofPath: url.path, in: assets)
    }

    public static func index(ofPath path: String, in assets: [FrameScriptDocument.ProjectAsset]) -> Int? {
        let key = AssetPath.identityKey(path)
        guard !key.isEmpty else { return nil }
        return assets.firstIndex { AssetPath.identityKey($0.path) == key }
    }

    /// Folds an incoming duplicate into an existing entry. User-owned data
    /// wins: the existing kind, tags and links are kept, while missing metadata
    /// and links are filled in from the incoming reference.
    public static func merge(
        _ incoming: FrameScriptDocument.ProjectAsset,
        into existing: inout FrameScriptDocument.ProjectAsset
    ) {
        existing.tags = AssetTags.normalized(existing.tags + incoming.tags)
        existing.linkedSceneIDs = unique(existing.linkedSceneIDs + incoming.linkedSceneIDs)
        existing.linkedBRollItemIDs = unique(existing.linkedBRollItemIDs + incoming.linkedBRollItemIDs)
        existing.linkedTakeIDs = unique(existing.linkedTakeIDs + incoming.linkedTakeIDs)
        if existing.path.isEmpty { existing.path = incoming.path }
        if existing.bookmarkData == nil { existing.bookmarkData = incoming.bookmarkData }
        if existing.duration == nil { existing.duration = incoming.duration }
        if existing.fileSize == nil { existing.fileSize = incoming.fileSize }
        if existing.modifiedAt == nil { existing.modifiedAt = incoming.modifiedAt }
        existing.isCopiedIntoProject = existing.isCopiedIntoProject || incoming.isCopiedIntoProject
    }

    public static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
