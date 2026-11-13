import Foundation

/// File-system identity helpers for `ProjectAsset` paths.
///
/// Assets only *reference* files, so every comparison, lookup and duplicate
/// check goes through these helpers. They are lexical on purpose: a path can be
/// normalised even when the file is missing, which is what the asset library
/// needs to keep stale entries visible.
public enum AssetPath {
    /// Expands a leading `~`, removes `.`/`..` components and drops trailing
    /// slashes. Spaces and casing are preserved.
    public static func normalized(_ path: String) -> String {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    /// Stable key used to decide whether two paths point at the same file.
    ///
    /// macOS volumes are case-insensitive by default, so the key lowercases the
    /// normalised path and applies Unicode canonical composition. That makes
    /// `~/Movies/Toma.MOV` and `$HOME/Movies/toma.mov` one asset instead of two.
    public static func identityKey(_ path: String) -> String {
        normalized(path).precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func url(for path: String) -> URL {
        URL(fileURLWithPath: normalized(path))
    }

    /// Last path component, or an empty string for a missing path.
    public static func fileName(_ path: String) -> String {
        let normalized = normalized(path)
        guard !normalized.isEmpty else { return "" }
        return (normalized as NSString).lastPathComponent
    }

    /// File name without its extension, used for search and display fallbacks.
    public static func baseName(_ path: String) -> String {
        (fileName(path) as NSString).deletingPathExtension
    }

    /// File extension, lowercased and without the dot.
    public static func fileExtension(_ path: String) -> String {
        (fileName(path) as NSString).pathExtension.lowercased()
    }

    public static func isSameFile(_ lhs: String, _ rhs: String) -> Bool {
        let left = identityKey(lhs)
        return !left.isEmpty && left == identityKey(rhs)
    }
}
