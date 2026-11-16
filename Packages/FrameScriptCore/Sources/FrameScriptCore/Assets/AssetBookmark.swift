import Foundation

/// Security-scoped bookmark helpers for asset references.
///
/// FrameScript is not sandboxed, but bookmarks keep the library resilient when
/// a file is moved or when the app is run inside a sandbox again. Every helper
/// tolerates failure: an asset can always fall back to its stored path.
public enum AssetBookmark {
    public static func make(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves a bookmark, preferring the security-scoped flavour and falling
    /// back to a plain bookmark for entries created by older builds.
    public static func resolve(_ data: Data) -> URL? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    /// Resolves the bookmark and runs `body` while the security scope is open
    /// for the duration of the call. Returns `nil` when the bookmark cannot be
    /// resolved at all.
    public static func withAccess<T>(_ data: Data, _ body: (URL) throws -> T?) rethrows -> T? {
        guard let url = resolve(data) else { return nil }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        return try body(url)
    }
}
