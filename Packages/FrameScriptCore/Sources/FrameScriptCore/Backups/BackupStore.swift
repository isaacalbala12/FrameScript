import Foundation

/// Copies the current `.fscr` file into a per-project backup folder before the
/// file is overwritten, then prunes old copies according to `BackupPolicy`.
///
/// The store never throws: every operation returns a result that says whether
/// it was created, skipped, or failed. A failed safeguard backup aborts a
/// restore, so the destination is never replaced without a copy of itself.
public struct BackupStore: Sendable {
    public let rootDirectory: URL
    public let policy: BackupPolicy
    private let fileManager: any BackupFileManaging
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        rootDirectory: URL = BackupStore.defaultRootDirectory,
        policy: BackupPolicy = BackupPolicy(),
        fileManager: any BackupFileManaging = SystemBackupFileManager(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory
        self.policy = policy
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
    }

    /// `~/Library/Application Support/FrameScript/Backups/`
    public static var defaultRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("FrameScript", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    public func projectDirectory(forProjectID projectID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.safeProjectComponent(projectID), isDirectory: true)
    }

    // MARK: - Backup

    /// Copies `fileURL` into the project's backup folder when the policy allows.
    ///
    /// - Parameters:
    ///   - fileURL: the on-disk project file that is about to be overwritten.
    ///   - projectID: stable id from `BackupProjectIdentity`.
    ///   - force: ignores the minimum interval. Used by restore safeguards.
    @discardableResult
    public func backUpIfNeeded(
        fileURL: URL,
        projectID: String,
        force: Bool = false
    ) -> BackupOutcome {
        let source = fileURL.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else {
            return .skipped(.sourceMissing)
        }
        if let attributes = try? fileManager.attributesOfItem(atPath: source.path),
           let type = attributes[.type] as? FileAttributeType,
           type != .typeRegular {
            return .skipped(.sourceMissing)
        }

        let directory = projectDirectory(forProjectID: projectID)
        let existing = listing(projectID: projectID).entries
        let date = now()

        if !force, !policy.allowsBackup(existing: existing, now: date) {
            return .skipped(.intervalNotElapsed)
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return .failed(failure(.createDirectory, url: directory, error: error))
        }

        let data: Data
        do {
            data = try fileManager.read(from: source)
        } catch {
            return .failed(failure(.readSource, url: source, error: error))
        }

        let target = uniqueBackupURL(for: source, date: date, in: directory)
        do {
            try fileManager.write(data, to: target)
        } catch {
            return .failed(failure(.writeBackup, url: target, error: error))
        }

        let metadata = BackupMetadata(
            originalPath: source.path,
            originalFileName: source.lastPathComponent,
            createdAt: date,
            byteSize: data.count
        )
        var warning: BackupFailure?
        do {
            try fileManager.write(try Self.metadataEncoder().encode(metadata), to: metadataURL(for: target))
        } catch {
            warning = failure(.writeMetadata, url: metadataURL(for: target), error: error)
        }

        if let pruneFailure = prune(projectID: projectID, now: date), warning == nil {
            warning = pruneFailure
        }

        let entry = BackupEntry(
            url: target,
            createdAt: date,
            byteSize: data.count,
            originalFileName: source.lastPathComponent,
            originalPath: source.path
        )
        return .created(entry, warning: warning)
    }

    // MARK: - Listing

    public func listing(projectID: String) -> BackupListing {
        let directory = projectDirectory(forProjectID: projectID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return BackupListing()
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return BackupListing(failures: [failure(.listBackups, url: directory, error: error)])
        }

        var entries: [BackupEntry] = []
        var failures: [BackupFailure] = []

        for url in contents where url.pathExtension.lowercased() == "fscr" {
            let sidecar = metadataURL(for: url)
            var metadata: BackupMetadata?
            if fileManager.fileExists(atPath: sidecar.path) {
                do {
                    let data = try fileManager.read(from: sidecar)
                    metadata = try Self.metadataDecoder().decode(BackupMetadata.self, from: data)
                } catch {
                    failures.append(failure(.readMetadata, url: sidecar, error: error))
                }
            }

            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.intValue
            let fileDate = attributes?[.creationDate] as? Date
            let originalFileName = metadata?.originalFileName
                ?? Self.originalFileName(fromBackupFileName: url.lastPathComponent)

            entries.append(
                BackupEntry(
                    url: url,
                    createdAt: metadata?.createdAt ?? fileDate ?? .distantPast,
                    byteSize: fileSize ?? metadata?.byteSize ?? 0,
                    originalFileName: originalFileName,
                    originalPath: metadata?.originalPath
                )
            )
        }

        entries.sort { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.url.standardizedFileURL.path < rhs.url.standardizedFileURL.path
            }
            return lhs.createdAt > rhs.createdAt
        }
        return BackupListing(entries: entries, failures: failures)
    }

    public func listBackups(projectID: String) -> [BackupEntry] {
        listing(projectID: projectID).entries
    }

    // MARK: - Pruning

    /// Removes entries the policy no longer keeps. Returns the first failure,
    /// if any, without preventing the remaining removals.
    @discardableResult
    public func prune(projectID: String, now: Date? = nil) -> BackupFailure? {
        let result = listing(projectID: projectID)
        let deletions = policy.backupsToDelete(
            from: result.entries,
            now: now ?? self.now(),
            calendar: calendar
        )

        var firstFailure = result.failures.first
        for entry in deletions {
            do {
                try fileManager.removeItem(at: entry.url)
            } catch {
                if firstFailure == nil {
                    firstFailure = failure(.removeBackup, url: entry.url, error: error)
                }
                continue
            }
            let sidecar = metadataURL(for: entry.url)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar)
            }
        }
        return firstFailure
    }

    // MARK: - Restore

    /// Replaces `destination` with a backup after first taking a forced backup
    /// of the destination. If that safeguard cannot be written, the restore is
    /// refused and the destination is left untouched.
    public func restore(
        _ entry: BackupEntry,
        over destination: URL,
        projectID: String
    ) -> RestoreOutcome {
        let destination = destination.standardizedFileURL
        let backupURL = entry.url.standardizedFileURL

        guard fileManager.fileExists(atPath: backupURL.path) else {
            return .failed(BackupFailure(
                operation: .readBackup,
                path: backupURL.path,
                reason: "The backup file no longer exists."
            ))
        }
        guard backupURL.path != destination.path else {
            return .failed(BackupFailure(
                operation: .restore,
                path: destination.path,
                reason: "A backup cannot be restored over itself."
            ))
        }

        var safeguard: BackupEntry?
        if fileManager.fileExists(atPath: destination.path) {
            switch backUpIfNeeded(fileURL: destination, projectID: projectID, force: true) {
            case let .created(created, _):
                safeguard = created
            case let .failed(failure):
                return .failed(failure)
            case .skipped:
                return .failed(BackupFailure(
                    operation: .restore,
                    path: destination.path,
                    reason: "Could not back up the current version before restoring."
                ))
            }
        }

        do {
            let data = try fileManager.read(from: backupURL)
            try fileManager.write(data, to: destination)
            return .restored(safeguard: safeguard)
        } catch {
            return .failed(failure(.writeDestination, url: destination, error: error))
        }
    }

    // MARK: - Naming and metadata

    private struct BackupMetadata: Codable {
        let originalPath: String
        let originalFileName: String
        let createdAt: Date
        let byteSize: Int
    }

    private static func metadataEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func metadataDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func metadataURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("json")
    }

    private func uniqueBackupURL(for source: URL, date: Date, in directory: URL) -> URL {
        let base = Self.backupBaseName(for: source, date: date)
        var candidate = directory.appendingPathComponent("\(base).fscr")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            if suffix < 1000 {
                candidate = directory.appendingPathComponent("\(base)-\(suffix).fscr")
                suffix += 1
            } else {
                candidate = directory.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).fscr")
            }
        }
        return candidate
    }

    static func backupBaseName(for source: URL, date: Date) -> String {
        let stamp = fileStamp(for: date)
        let stem = sanitizedOriginalStem(source.deletingPathExtension().lastPathComponent)
        return "\(stamp)__\(stem)"
    }

    /// Filesystem-safe ISO-8601 stamp: `2026-11-12T18-30-00.123Z`.
    static func fileStamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    static func sanitizedOriginalStem(_ name: String) -> String {
        let replaced = name.map { character -> Character in
            switch character {
            case "/", "\\", ":", "\0":
                return "-"
            default:
                return character.isNewline ? "-" : character
            }
        }
        let trimmed = String(replaced).trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "project" : trimmed
        return String(fallback.prefix(120))
    }

    static func originalFileName(fromBackupFileName fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        guard let separator = stem.range(of: "__") else { return stem }
        return String(stem[separator.upperBound...])
    }

    static func safeProjectComponent(_ projectID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let replaced = projectID.map { allowed.contains($0) ? $0 : "_" }
        let value = String(replaced)
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let fallback = trimmed.isEmpty ? "project" : trimmed
        return String(fallback.prefix(120))
    }

    private func failure(_ operation: BackupFailure.Operation, url: URL, error: Error) -> BackupFailure {
        BackupFailure(
            operation: operation,
            path: url.path,
            reason: error.localizedDescription
        )
    }
}
