import Foundation

/// Stable, file-system-safe identifier for a project's backup folder.
///
/// The `.fscr` file stores a project UUID. When a project has never been saved
/// (or a caller only has a path) a deterministic hash of the standardized path
/// takes its place, so backups survive moves only when the UUID is available —
/// which is the normal case for saved projects.
///
/// Copies that keep the same UUID (Save As, a Finder duplicate) intentionally
/// share one history: F29 keys backups by project, not by file path, and a
/// rename/move must not orphan them. The backups sheet shows each entry's
/// original path so the user can tell which file a snapshot came from. "Open
/// as Copy" regenerates the UUID and therefore starts an independent history.
public enum BackupProjectIdentity {
    /// Returns a directory-safe identifier. Never empty.
    public static func identifier(projectUUID: UUID?, fileURL: URL?) -> String {
        if let projectUUID {
            return projectUUID.uuidString.lowercased()
        }
        guard let fileURL else { return "unfiled" }
        let path = fileURL.standardizedFileURL.path
        return "path-" + pathHash(path)
    }

    /// FNV-1a 64-bit. Deliberately not Swift's `Hasher`, whose seed changes
    /// between launches, and not CryptoKit, so the id is stable across builds.
    static func pathHash(_ path: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
