import Foundation

/// Pure project-level summary that the board and the production checklist can
/// consume without knowing anything about the clip UI.
public struct ClipSummary: Sendable, Equatable {
    public let total: Int
    public let byStatus: [FrameScriptDocument.ShortClipStatus: Int]
    public let byFormat: [FrameScriptDocument.ShortClipFormat: Int]
    public let stale: Int
    public let ready: Int
    public let published: Int
    public let estimatedTotalSeconds: TimeInterval
    public let nextStatus: FrameScriptDocument.ShortClipStatus?

    public init(
        total: Int,
        byStatus: [FrameScriptDocument.ShortClipStatus: Int],
        byFormat: [FrameScriptDocument.ShortClipFormat: Int],
        stale: Int,
        ready: Int,
        published: Int,
        estimatedTotalSeconds: TimeInterval,
        nextStatus: FrameScriptDocument.ShortClipStatus?
    ) {
        self.total = max(0, total)
        self.byStatus = byStatus
        self.byFormat = byFormat
        self.stale = max(0, stale)
        self.ready = max(0, ready)
        self.published = max(0, published)
        self.estimatedTotalSeconds = estimatedTotalSeconds.isFinite
            ? min(max(0, estimatedTotalSeconds), 86_400 * 1_000)
            : 0
        self.nextStatus = nextStatus
    }

    public static let empty = ClipSummary(
        total: 0,
        byStatus: [:],
        byFormat: [:],
        stale: 0,
        ready: 0,
        published: 0,
        estimatedTotalSeconds: 0,
        nextStatus: nil
    )

    public var isEmpty: Bool { total == 0 }

    public func count(for status: FrameScriptDocument.ShortClipStatus) -> Int {
        byStatus[status] ?? 0
    }

    public func count(for format: FrameScriptDocument.ShortClipFormat) -> Int {
        byFormat[format] ?? 0
    }
}

/// One row for a production checklist or board card.
public struct ClipProductionItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let title: String
    public let status: FrameScriptDocument.ShortClipStatus
    public let format: FrameScriptDocument.ShortClipFormat
    public let isStale: Bool
    public let targetSeconds: TimeInterval
    public let estimatedSeconds: TimeInterval

    public init(
        id: UUID,
        title: String,
        status: FrameScriptDocument.ShortClipStatus,
        format: FrameScriptDocument.ShortClipFormat,
        isStale: Bool,
        targetSeconds: TimeInterval,
        estimatedSeconds: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.format = format
        self.isStale = isStale
        self.targetSeconds = ClipLimits.sanitizedTarget(targetSeconds)
            ?? ClipLimits.defaultTargetSeconds
        self.estimatedSeconds = estimatedSeconds.isFinite
            ? min(max(0, estimatedSeconds), 86_400)
            : 0
    }

    public var isReadyToPublish: Bool {
        status == .ready && !isStale
    }
}

public enum ClipSummaryBuilder {
    public static func summary(
        clips: [FrameScriptDocument.ShortClip],
        scenes: [FrameScriptDocument.Scene],
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard
    ) -> ClipSummary {
        guard !clips.isEmpty else { return .empty }

        var byStatus: [FrameScriptDocument.ShortClipStatus: Int] = [:]
        var byFormat: [FrameScriptDocument.ShortClipFormat: Int] = [:]
        var stale = 0
        var totalSeconds: TimeInterval = 0

        for clip in clips {
            byStatus[clip.status, default: 0] += 1
            byFormat[clip.format, default: 0] += 1
            if ClipStaleness.isStale(clip: clip, scenes: scenes) {
                stale += 1
            }
            totalSeconds += ClipEstimator.estimate(
                hook: clip.hook,
                adaptedText: clip.adaptedText,
                targetSeconds: clip.targetSeconds,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults
            ).seconds
        }

        let nextStatus: FrameScriptDocument.ShortClipStatus? = [
            FrameScriptDocument.ShortClipStatus.idea,
            .draft,
            .ready
        ].first { (byStatus[$0] ?? 0) > 0 }

        return ClipSummary(
            total: clips.count,
            byStatus: byStatus,
            byFormat: byFormat,
            stale: stale,
            ready: byStatus[.ready] ?? 0,
            published: byStatus[.published] ?? 0,
            estimatedTotalSeconds: totalSeconds,
            nextStatus: nextStatus
        )
    }

    public static func productionItems(
        clips: [FrameScriptDocument.ShortClip],
        scenes: [FrameScriptDocument.Scene],
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard
    ) -> [ClipProductionItem] {
        clips.map { clip in
            let estimate = ClipEstimator.estimate(
                hook: clip.hook,
                adaptedText: clip.adaptedText,
                targetSeconds: clip.targetSeconds,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults
            )
            return ClipProductionItem(
                id: clip.id,
                title: clip.title,
                status: clip.status,
                format: clip.format,
                isStale: ClipStaleness.isStale(clip: clip, scenes: scenes),
                targetSeconds: clip.targetSeconds,
                estimatedSeconds: estimate.seconds
            )
        }
    }
}
