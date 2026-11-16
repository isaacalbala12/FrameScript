import Foundation

/// Metadata the scanner needs. Kept as a value type so `BoardLibraryScanner`
/// stays testable and Sendable without leaking `URLResourceValues`.
public struct BoardFileMetadata: Sendable, Equatable {
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let fileSize: Int
    public let modificationDate: Date?

    public init(
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymbolicLink: Bool = false,
        fileSize: Int = 0,
        modificationDate: Date? = nil
    ) {
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }
}

/// Narrow file-system seam used by the scanner. Tests can supply a fake, but
/// the scanner tests also use the real file system through temporary folders.
public protocol BoardFileSystemProviding: Sendable {
    func fileExists(atPath path: String) -> Bool
    func metadata(at url: URL) throws -> BoardFileMetadata
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func read(from url: URL) throws -> Data
}

public struct SystemBoardFileSystem: BoardFileSystemProviding {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func metadata(at url: URL) throws -> BoardFileMetadata {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ])
        return BoardFileMetadata(
            isDirectory: values.isDirectory ?? false,
            isPackage: values.isPackage ?? false,
            isSymbolicLink: values.isSymbolicLink ?? false,
            fileSize: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate
        )
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles]
        )
    }

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

/// Scans user-chosen folders plus recent files for `.fscr` projects.
///
/// The scan is synchronous and does no UI work, so the app runs it on a
/// background task. It is read-only, tolerates unreadable/corrupt files with
/// warnings, and reuses unchanged summaries from the previous index based on
/// size and modification date.
public struct BoardLibraryScanner: Sendable {
    public let fileSystem: any BoardFileSystemProviding
    public let maximumDepth: Int
    public let maximumFileCount: Int

    public init(
        fileSystem: any BoardFileSystemProviding = SystemBoardFileSystem(),
        maximumDepth: Int = 12,
        maximumFileCount: Int = 20_000
    ) {
        self.fileSystem = fileSystem
        self.maximumDepth = max(1, maximumDepth)
        self.maximumFileCount = max(1, maximumFileCount)
    }

    public func scan(_ request: BoardScanRequest) -> BoardScanResult {
        var warnings: [BoardScanWarning] = []
        var discovered: [URL] = []
        var seenPaths: Set<String> = []
        var truncated = false

        func addFile(_ url: URL) -> Bool {
            guard url.pathExtension.lowercased() == "fscr" else { return true }
            guard discovered.count < maximumFileCount else { return false }
            let standardized = url.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { return true }
            discovered.append(standardized)
            return true
        }

        for folder in request.folderURLs {
            guard fileSystem.fileExists(atPath: folder.path) else {
                warnings.append(BoardScanWarning(url: folder, kind: .folderMissing))
                continue
            }
            let rootMetadata: BoardFileMetadata
            do {
                rootMetadata = try fileSystem.metadata(at: folder)
            } catch {
                warnings.append(BoardScanWarning(url: folder, kind: .folderUnreadable))
                continue
            }
            guard rootMetadata.isDirectory else {
                warnings.append(BoardScanWarning(url: folder, kind: .folderUnreadable))
                continue
            }

            var visitedDirectories: Set<String> = []
            enumerate(
                folder,
                depth: 0,
                visitedDirectories: &visitedDirectories,
                addFile: addFile,
                warnings: &warnings,
                truncated: &truncated
            )
            if truncated {
                warnings.append(BoardScanWarning(url: folder, kind: .fileLimitReached))
                break
            }
        }

        // Recent projects may live outside the chosen folders. Missing files
        // are already handled by the recents store, so they are skipped here.
        for url in request.extraFileURLs where fileSystem.fileExists(atPath: url.path) {
            if !addFile(url) {
                truncated = true
                warnings.append(BoardScanWarning(url: url, kind: .fileLimitReached))
                break
            }
        }

        var summaries: [BoardProjectSummary] = []
        var decoded = 0
        var reused = 0

        for fileURL in discovered {
            let metadata: BoardFileMetadata
            do {
                metadata = try fileSystem.metadata(at: fileURL)
            } catch {
                warnings.append(BoardScanWarning(url: fileURL, kind: .unreadableFile))
                continue
            }
            guard !metadata.isDirectory else { continue }

            let cheapFingerprint = BoardFileFingerprint(
                contentHash: "",
                fileSize: metadata.fileSize,
                modificationDate: metadata.modificationDate
            )

            if let previous = request.previous.summary(forFileAt: fileURL),
               previous.fingerprint.matchesCheaply(cheapFingerprint) {
                summaries.append(previous)
                reused += 1
                continue
            }

            let data: Data
            do {
                data = try fileSystem.read(from: fileURL)
            } catch {
                warnings.append(BoardScanWarning(url: fileURL, kind: .unreadableFile))
                continue
            }

            let fingerprint = BoardFileFingerprint(
                contentHash: BoardFileFingerprint.hash(of: data),
                fileSize: data.count,
                modificationDate: metadata.modificationDate
            )
            do {
                let document = try FrameScriptDocumentCodec.decode(data)
                summaries.append(
                    BoardProjectSummaryBuilder.makeSummary(
                        document: document,
                        fileURL: fileURL,
                        fingerprint: fingerprint,
                        labels: request.labels
                    )
                )
                decoded += 1
            } catch let error as FrameScriptDocumentError {
                switch error {
                case .unsupportedVersion:
                    warnings.append(BoardScanWarning(url: fileURL, kind: .unsupportedVersion))
                default:
                    warnings.append(BoardScanWarning(url: fileURL, kind: .corruptDocument))
                }
            } catch {
                warnings.append(BoardScanWarning(url: fileURL, kind: .corruptDocument))
            }
        }

        let index = BoardLibraryIndex(summaries: summaries, warnings: warnings)
        return BoardScanResult(
            index: index,
            stats: BoardScanStats(
                folderCount: request.folderURLs.count,
                fileCount: discovered.count,
                decodedCount: decoded,
                reusedCount: reused,
                warningCount: index.warnings.count,
                wasTruncated: truncated
            )
        )
    }

    private func enumerate(
        _ directory: URL,
        depth: Int,
        visitedDirectories: inout Set<String>,
        addFile: (URL) -> Bool,
        warnings: inout [BoardScanWarning],
        truncated: inout Bool
    ) {
        guard !truncated else { return }
        let key = directory.standardizedFileURL.path
        guard visitedDirectories.insert(key).inserted else { return }
        guard depth <= maximumDepth else {
            warnings.append(BoardScanWarning(url: directory, kind: .depthLimitReached))
            return
        }

        let contents: [URL]
        do {
            contents = try fileSystem.contentsOfDirectory(at: directory)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            warnings.append(BoardScanWarning(url: directory, kind: .folderUnreadable))
            return
        }

        for url in contents {
            guard !url.lastPathComponent.hasPrefix(".") else { continue }

            let metadata: BoardFileMetadata
            do {
                metadata = try fileSystem.metadata(at: url)
            } catch {
                if url.pathExtension.lowercased() == "fscr" {
                    warnings.append(BoardScanWarning(url: url, kind: .unreadableFile))
                }
                continue
            }

            if metadata.isDirectory {
                guard !metadata.isPackage, !metadata.isSymbolicLink else { continue }
                enumerate(
                    url,
                    depth: depth + 1,
                    visitedDirectories: &visitedDirectories,
                    addFile: addFile,
                    warnings: &warnings,
                    truncated: &truncated
                )
                if truncated { return }
            } else if !metadata.isSymbolicLink {
                guard addFile(url) else {
                    truncated = true
                    return
                }
            }
        }
    }
}
