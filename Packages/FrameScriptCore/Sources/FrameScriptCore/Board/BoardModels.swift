import CryptoKit
import Foundation

/// Identity of a `.fscr` file as the board last read it.
///
/// The board never writes a project without comparing the hash it indexed with
/// the hash on disk, so an edit made in another app (or another FrameScript
/// window) is never overwritten silently.
public struct BoardFileFingerprint: Sendable, Equatable {
    public let contentHash: String
    public let fileSize: Int
    public let modificationDate: Date?

    public init(contentHash: String, fileSize: Int, modificationDate: Date?) {
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    /// SHA-256 of the file bytes, matching the app's project snapshot reader.
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when size and modification date agree. Content is only re-read
    /// when one of these cheap checks fails; a writer that preserves both can
    /// still go unnoticed until the next full refresh.
    public func matchesCheaply(_ other: BoardFileFingerprint) -> Bool {
        fileSize == other.fileSize && modificationDate == other.modificationDate
    }
}

/// A pending production task derived from a project document.
///
/// The kind reuses `PlaneTaskKind` so a board summary can be turned into a
/// `PlaneExportPlan` without another mapping table.
public struct BoardPendingTask: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let kind: PlaneTaskKind
    public let title: String
    public let sceneTitle: String

    public init(id: String, kind: PlaneTaskKind, title: String, sceneTitle: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sceneTitle = sceneTitle
    }

    /// Converts the derived task into the network-free shape the Plane plan
    /// builder consumes.
    public func planeTask(
        projectID: String,
        projectTitle: String,
        dueDate: PlaneDate? = nil
    ) -> PlanePendingTask {
        PlanePendingTask(
            id: id,
            projectID: projectID,
            title: title,
            kind: kind,
            sceneTitle: sceneTitle,
            projectTitle: projectTitle,
            dueDate: dueDate
        )
    }
}

/// Pending task totals grouped by kind.
public struct BoardPendingCounts: Sendable, Equatable {
    public private(set) var byKind: [PlaneTaskKind: Int]

    public init(byKind: [PlaneTaskKind: Int] = [:]) {
        self.byKind = byKind.filter { $0.value > 0 }
    }

    public init(tasks: [BoardPendingTask]) {
        var counts: [PlaneTaskKind: Int] = [:]
        for task in tasks {
            counts[task.kind, default: 0] += 1
        }
        self.byKind = counts
    }

    public func count(for kind: PlaneTaskKind) -> Int {
        byKind[kind] ?? 0
    }

    public var total: Int {
        byKind.values.reduce(0, +)
    }

    public var isEmpty: Bool {
        total == 0
    }

    /// Kinds with at least one pending task, in the stable enum order.
    public var activeKinds: [PlaneTaskKind] {
        PlaneTaskKind.allCases.filter { count(for: $0) > 0 }
    }
}

/// Duration shown on a board card: real takes where they exist, the stored
/// estimate everywhere else.
public struct BoardDuration: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// No scene has a usable real take.
        case estimated
        /// Some scenes use a real take and the rest use their estimate.
        case mixed
        /// Every scene has a usable real take.
        case real
    }

    /// Total the board displays.
    public let seconds: TimeInterval
    public let estimatedSeconds: TimeInterval
    public let realSceneCount: Int
    public let sceneCount: Int
    public let kind: Kind

    public init(
        seconds: TimeInterval,
        estimatedSeconds: TimeInterval,
        realSceneCount: Int,
        sceneCount: Int
    ) {
        let safeTotal = Self.sanitized(seconds)
        let safeEstimate = Self.sanitized(estimatedSeconds)
        self.seconds = safeTotal
        self.estimatedSeconds = safeEstimate
        self.realSceneCount = max(0, min(realSceneCount, max(0, sceneCount)))
        self.sceneCount = max(0, sceneCount)
        if self.realSceneCount <= 0 {
            self.kind = .estimated
        } else if self.realSceneCount >= self.sceneCount {
            self.kind = .real
        } else {
            self.kind = .mixed
        }
    }

    private static func sanitized(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return 0 }
        return min(value, 86_400)
    }
}

/// One readable project file in the board library.
public struct BoardProjectSummary: Sendable, Equatable, Identifiable {
    public let fileURL: URL
    public let projectID: UUID
    public let title: String
    public let topic: String
    public let videoType: String
    public let productionStatus: FrameScriptDocument.ProductionStatus
    public let targetDate: Date?
    public let publishDate: Date?
    public let updatedAt: Date
    public let createdAt: Date
    public let templateID: UUID?
    public let sceneCount: Int
    public let duration: BoardDuration
    public let pendingTasks: [BoardPendingTask]
    public let fingerprint: BoardFileFingerprint

    public var id: String {
        fileURL.standardizedFileURL.path
    }

    public var pending: BoardPendingCounts {
        BoardPendingCounts(tasks: pendingTasks)
    }

    public var fileName: String {
        fileURL.lastPathComponent
    }

    public var isUnclassifiedTopic: Bool {
        topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var isUnclassifiedType: Bool {
        videoType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public init(
        fileURL: URL,
        projectID: UUID,
        title: String,
        topic: String,
        videoType: String,
        productionStatus: FrameScriptDocument.ProductionStatus,
        targetDate: Date?,
        publishDate: Date?,
        updatedAt: Date,
        createdAt: Date,
        templateID: UUID?,
        sceneCount: Int,
        duration: BoardDuration,
        pendingTasks: [BoardPendingTask],
        fingerprint: BoardFileFingerprint
    ) {
        self.fileURL = fileURL
        self.projectID = projectID
        self.title = title
        self.topic = topic
        self.videoType = videoType
        self.productionStatus = productionStatus
        self.targetDate = targetDate
        self.publishDate = publishDate
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.templateID = templateID
        self.sceneCount = sceneCount
        self.duration = duration
        self.pendingTasks = pendingTasks
        self.fingerprint = fingerprint
    }

    /// Returns a copy with edited classification fields. Used by the app after
    /// a successful document write so the index does not need a full rescan.
    public func applying(_ edit: BoardProjectEdit, fingerprint: BoardFileFingerprint) -> BoardProjectSummary {
        BoardProjectSummary(
            fileURL: fileURL,
            projectID: projectID,
            title: title,
            topic: edit.topic.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? topic,
            videoType: edit.videoType.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? videoType,
            productionStatus: edit.productionStatus ?? productionStatus,
            targetDate: edit.clearsTargetDate ? nil : (edit.targetDate ?? targetDate),
            publishDate: edit.clearsPublishDate ? nil : (edit.publishDate ?? publishDate),
            updatedAt: updatedAt,
            createdAt: createdAt,
            templateID: templateID,
            sceneCount: sceneCount,
            duration: duration,
            pendingTasks: pendingTasks,
            fingerprint: fingerprint
        )
    }

    /// Replaces only the derived pending tasks. The board uses it after an
    /// in-memory edit so a card never shows stale counts while the project is
    /// waiting for the normal save (NEW-2).
    public func replacingPendingTasks(_ pendingTasks: [BoardPendingTask]) -> BoardProjectSummary {
        BoardProjectSummary(
            fileURL: fileURL,
            projectID: projectID,
            title: title,
            topic: topic,
            videoType: videoType,
            productionStatus: productionStatus,
            targetDate: targetDate,
            publishDate: publishDate,
            updatedAt: updatedAt,
            createdAt: createdAt,
            templateID: templateID,
            sceneCount: sceneCount,
            duration: duration,
            pendingTasks: pendingTasks,
            fingerprint: fingerprint
        )
    }
}

/// A file or folder the scan could not use. The board shows these instead of
/// hiding them so a damaged project never disappears without explanation.
public struct BoardScanWarning: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case folderMissing
        case folderUnreadable
        case unreadableFile
        case corruptDocument
        case unsupportedVersion
        case depthLimitReached
        case fileLimitReached
    }

    public let url: URL
    public let kind: Kind

    public var id: String {
        "\(url.standardizedFileURL.path)#\(kind.rawValue)"
    }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Counters from the most recent scan, used by the UI footer and tests.
public struct BoardScanStats: Sendable, Equatable {
    public let folderCount: Int
    public let fileCount: Int
    public let decodedCount: Int
    public let reusedCount: Int
    public let warningCount: Int
    public let wasTruncated: Bool

    public init(
        folderCount: Int,
        fileCount: Int,
        decodedCount: Int,
        reusedCount: Int,
        warningCount: Int,
        wasTruncated: Bool
    ) {
        self.folderCount = folderCount
        self.fileCount = fileCount
        self.decodedCount = decodedCount
        self.reusedCount = reusedCount
        self.warningCount = warningCount
        self.wasTruncated = wasTruncated
    }

    public static let empty = BoardScanStats(
        folderCount: 0,
        fileCount: 0,
        decodedCount: 0,
        reusedCount: 0,
        warningCount: 0,
        wasTruncated: false
    )
}

/// The readable projects plus warnings produced by a scan.
public struct BoardLibraryIndex: Sendable, Equatable {
    public var summaries: [BoardProjectSummary]
    public var warnings: [BoardScanWarning]

    public init(
        summaries: [BoardProjectSummary] = [],
        warnings: [BoardScanWarning] = []
    ) {
        self.summaries = summaries.sorted {
            $0.fileURL.standardizedFileURL.path < $1.fileURL.standardizedFileURL.path
        }
        self.warnings = warnings.sorted { $0.id < $1.id }
    }

    public func summary(forFileAt url: URL) -> BoardProjectSummary? {
        let path = url.standardizedFileURL.path
        return summaries.first { $0.fileURL.standardizedFileURL.path == path }
    }

    public var isEmpty: Bool {
        summaries.isEmpty
    }

    public func replacing(_ summary: BoardProjectSummary) -> BoardLibraryIndex {
        var next = summaries.filter {
            $0.fileURL.standardizedFileURL.path != summary.fileURL.standardizedFileURL.path
        }
        next.append(summary)
        return BoardLibraryIndex(summaries: next, warnings: warnings)
    }

    public func removingFile(at url: URL) -> BoardLibraryIndex {
        let path = url.standardizedFileURL.path
        return BoardLibraryIndex(
            summaries: summaries.filter { $0.fileURL.standardizedFileURL.path != path },
            warnings: warnings
        )
    }
}

/// A request for `BoardLibraryScanner`. Everything is a value so the scan can
/// run on a background task.
public struct BoardScanRequest: Sendable, Equatable {
    /// User-chosen library roots, scanned recursively.
    public var folderURLs: [URL]
    /// Individual files (recent projects) that may live outside the folders.
    public var extraFileURLs: [URL]
    /// Index from the previous scan, used for incremental reuse.
    public var previous: BoardLibraryIndex
    /// Localized labels for the pending-task titles stored in the summaries.
    public var labels: BoardPendingLabels

    public init(
        folderURLs: [URL],
        extraFileURLs: [URL] = [],
        previous: BoardLibraryIndex = BoardLibraryIndex(),
        labels: BoardPendingLabels = .english
    ) {
        self.folderURLs = folderURLs
        self.extraFileURLs = extraFileURLs
        self.previous = previous
        self.labels = labels
    }
}

/// Outcome of a scan; `index` replaces the previous one.
public struct BoardScanResult: Sendable, Equatable {
    public var index: BoardLibraryIndex
    public var stats: BoardScanStats

    public init(index: BoardLibraryIndex, stats: BoardScanStats) {
        self.index = index
        self.stats = stats
    }
}
