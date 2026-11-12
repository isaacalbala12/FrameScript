import Foundation

/// One file inside a project's backup folder.
public struct BackupEntry: Identifiable, Hashable, Codable, Sendable {
    /// Location of the backup copy on disk.
    public let url: URL
    /// When the backup was taken, according to the injected clock.
    public let createdAt: Date
    /// Size of the backed-up copy in bytes.
    public let byteSize: Int
    /// Name of the file that was copied, e.g. `My Video.fscr`.
    public let originalFileName: String
    /// Absolute path of the file that was copied, when it is known.
    public let originalPath: String?

    public var id: URL { url }

    public init(
        url: URL,
        createdAt: Date,
        byteSize: Int,
        originalFileName: String,
        originalPath: String? = nil
    ) {
        self.url = url
        self.createdAt = createdAt
        self.byteSize = byteSize
        self.originalFileName = originalFileName
        self.originalPath = originalPath
    }
}

/// Reasons an automatic backup can be skipped without that being an error.
public enum BackupSkipReason: String, Codable, Hashable, Sendable {
    /// There is no current project file on disk yet.
    case sourceMissing
    /// The policy's minimum interval has not elapsed.
    case intervalNotElapsed
}

/// A non-fatal-or-fatal backup failure, reported instead of thrown so a backup
/// can never take the app down with it.
public struct BackupFailure: Error, Equatable, Sendable, LocalizedError {
    public enum Operation: String, Codable, Hashable, Sendable {
        case createDirectory
        case readSource
        case writeBackup
        case writeMetadata
        case readMetadata
        case listBackups
        case removeBackup
        case readBackup
        case validateBackup
        case writeDestination
        case restore
    }

    public let operation: Operation
    public let path: String
    public let reason: String

    public init(operation: Operation, path: String, reason: String) {
        self.operation = operation
        self.path = path
        self.reason = reason
    }

    public var errorDescription: String? {
        "\(operation.rawValue) failed at \(path): \(reason)"
    }
}

/// Result of an automatic or forced backup.
public enum BackupOutcome: Equatable, Sendable {
    /// A backup was written. `warning` reports a non-fatal problem such as
    /// failing to prune old copies or to persist metadata.
    case created(BackupEntry, warning: BackupFailure?)
    case skipped(BackupSkipReason)
    case failed(BackupFailure)
}

/// Result of a restore operation.
public enum RestoreOutcome: Equatable, Sendable {
    /// The backup replaced the destination. `safeguard` is the forced backup
    /// taken from the destination immediately before the overwrite.
    case restored(safeguard: BackupEntry?)
    case failed(BackupFailure)
}

/// A project's backups, newest first, plus problems found while reading them.
public struct BackupListing: Equatable, Sendable {
    public let entries: [BackupEntry]
    public let failures: [BackupFailure]

    public init(entries: [BackupEntry] = [], failures: [BackupFailure] = []) {
        self.entries = entries
        self.failures = failures
    }
}
