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
        calendar: Calendar = .autoupdatingCurrent,
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
                return lhs.url.standardizedFileURL.path > rhs.url.standardizedFileURL.path
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
    ///
    /// The selected backup is read into memory before the safeguard runs, so a
    /// retention prune can never delete the copy that is being restored. An
    /// optional `validate` closure runs on those bytes before anything on disk
    /// changes; callers use it to reject malformed project files.
    public func restore(
        _ entry: BackupEntry,
        over destination: URL,
        projectID: String,
        validate: (@Sendable (Data) throws -> Void)? = nil
    ) -> RestoreOutcome {
        // Follow a symlinked destination so the target file is restored and the
        // link itself is not replaced by a regular file.
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        let backupURL = entry.url.resolvingSymlinksInPath().standardizedFileURL

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

        // Read first: the safeguard below prunes, and the selected entry may be
        // the oldest copy in the ring.
        let data: Data
        do {
            data = try fileManager.read(from: backupURL)
        } catch {
            return .failed(failure(.readBackup, url: backupURL, error: error))
        }
        if let validate {
            do {
                try validate(data)
            } catch {
                return .failed(BackupFailure(
                    operation: .validateBackup,
                    path: backupURL.path,
                    reason: error.localizedDescription
                ))
            }
        }
        return writeValidatedData(data, over: destination, projectID: projectID)
    }

    /// Restores bytes that were already read from a backup.
    ///
    /// The app uses this when it must save unsaved edits before restoring:
    /// that save can run retention and remove the selected file, so the payload
    /// has to survive the save/prune cycle.
    public func restore(
        data: Data,
        over destination: URL,
        projectID: String,
        validate: (@Sendable (Data) throws -> Void)? = nil
    ) -> RestoreOutcome {
        if let validate {
            do {
                try validate(data)
            } catch {
                return .failed(BackupFailure(
                    operation: .validateBackup,
                    path: destination.path,
                    reason: error.localizedDescription
                ))
            }
        }
        return writeValidatedData(data, over: destination, projectID: projectID)
    }

    private func writeValidatedData(
        _ data: Data,
        over destination: URL,
        projectID: String
    ) -> RestoreOutcome {
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
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
            try fileManager.write(data, to: destination)
            return .restored(safeguard: safeguard)
        } catch {
            return .failed(failure(.writeDestination, url: destination, error: error))
        }
    }

    // MARK: - Naming and metadata

    private struct BackupMetadata: Codable {
        let originalPath: String?
        let originalFileName: String?
        let createdAt: Date
        let byteSize: Int?

        init(
            originalPath: String?,
            originalFileName: String?,
            createdAt: Date,
            byteSize: Int?
        ) {
            self.originalPath = originalPath
            self.originalFileName = originalFileName
            self.createdAt = createdAt
            self.byteSize = byteSize
        }

        private enum CodingKeys: String, CodingKey {
            case originalPath
            case originalFileName
            case createdAt
            case createdAtMilliseconds
            case byteSize
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            originalPath = try container.decodeIfPresent(String.self, forKey: .originalPath)
            originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName)
            byteSize = try container.decodeIfPresent(Int.self, forKey: .byteSize)
            if let milliseconds = try container.decodeIfPresent(Int64.self, forKey: .createdAtMilliseconds) {
                createdAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            } else if let legacyDate = try container.decodeIfPresent(Date.self, forKey: .createdAt) {
                // Sidecars written before 0.5 stored whole-second ISO dates.
                createdAt = legacyDate
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.createdAtMilliseconds,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Backup metadata has no creation date."
                    )
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(originalPath, forKey: .originalPath)
            try container.encodeIfPresent(originalFileName, forKey: .originalFileName)
            try container.encodeIfPresent(byteSize, forKey: .byteSize)
            // Whole-second ISO dates collapsed sub-second backups and could
            // make pruning delete the actual newest copy.
            try container.encode(
                Int64((createdAt.timeIntervalSince1970 * 1000).rounded()),
                forKey: .createdAtMilliseconds
            )
        }
    }

    private static func metadataEncoder() -> JSONEncoder {
        JSONEncoder()
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
        return truncatedFileNameStem(fallback)
    }

    /// Truncates by UTF-8 bytes *and* UTF-16 units, with a short hash suffix.
    ///
    /// APFS rejects names over 255 UTF-16 units; the ISO stamp, `__`, an
    /// optional `-NNN` collision suffix and `.fscr` already spend about 31.
    /// Counting `Character` instead (the old bug) let 113 emoji through, which
    /// made every backup fail with "file name invalid".
    static func truncatedFileNameStem(
        _ value: String,
        maxUTF8Bytes: Int = 200,
        maxUTF16Units: Int = 200
    ) -> String {
        guard value.utf8.count > maxUTF8Bytes || value.utf16.count > maxUTF16Units else {
            return value
        }

        let suffix = "-" + String(BackupProjectIdentity.pathHash(value).prefix(8))
        let byteBudget = max(0, maxUTF8Bytes - suffix.utf8.count)
        let unitBudget = max(0, maxUTF16Units - suffix.utf16.count)
        var result = ""
        var bytes = 0
        var units = 0
        for character in value {
            let piece = String(character)
            let pieceBytes = piece.utf8.count
            let pieceUnits = piece.utf16.count
            guard bytes + pieceBytes <= byteBudget, units + pieceUnits <= unitBudget else {
                break
            }
            result.append(character)
            bytes += pieceBytes
            units += pieceUnits
        }
        return result.isEmpty ? "project" + suffix : result + suffix
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

public extension BackupStore {
    /// Shared entry point for every write path: the app save hook now and the
    /// `framescript` CLI/MCP later. Resolves the stable project id and takes a
    /// backup of `fileURL` before it is overwritten.
    @discardableResult
    func backUpBeforeOverwrite(
        projectUUID: UUID?,
        fileURL: URL,
        force: Bool = false
    ) -> BackupOutcome {
        backUpIfNeeded(
            fileURL: fileURL,
            projectID: BackupProjectIdentity.identifier(projectUUID: projectUUID, fileURL: fileURL),
            force: force
        )
    }
}
