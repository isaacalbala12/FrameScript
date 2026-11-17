import CoreGraphics
import Foundation
import FrameScriptCore

// MARK: - Input

/// Maps the app document model to the pure timeline input.
///
/// Kept free of `AppState` so tests can build the exact same input from a
/// synthetic project without touching app preferences or the file system.
@MainActor
enum TimelineInputBuilder {
    static func input(
        project: FrameProject,
        configuration: DurationConfiguration,
        selectedTakeIDs: [UUID: UUID],
        warningsByScene: [UUID: [RhythmWarning]],
        projectWarnings: [RhythmWarning],
        interfaceLanguage: AppLanguage = .spanish
    ) -> TimelineProjectInput {
        let scenes = project.scenes.sortedByOrder.map { scene in
            let selectedID = selectedTakeIDs[scene.id]
            let sceneWarnings = (warningsByScene[scene.id] ?? [])
                + projectWarnings.filter { $0.sceneID == scene.id.uuidString }
            return TimelineSceneInput(
                id: scene.id,
                title: scene.title,
                text: scene.scriptText,
                takes: scene.takes.map { take in
                    TimelineTakeInput(
                        id: take.id,
                        number: take.number,
                        duration: take.duration,
                        isSelected: take.id == selectedID,
                        rating: timelineRating(take.rating)
                    )
                },
                bRoll: scene.bRollItems.map { item in
                    TimelineMarkerInput(
                        id: item.id,
                        anchorUTF16: TextAnchorRepair.current(item.textAnchor, in: scene.scriptText)?.startUTF16,
                        duration: item.duration,
                        label: firstNonEmpty(
                            item.descriptionText,
                            L10n.tr("brollSource.\(item.sourceType.rawValue)", language: interfaceLanguage)
                        )
                    )
                },
                editing: scene.editingItems.map { item in
                    TimelineMarkerInput(
                        id: item.id,
                        anchorUTF16: TextAnchorRepair.current(item.textAnchor, in: scene.scriptText)?.startUTF16,
                        label: firstNonEmpty(
                            item.cutStyle,
                            item.transition,
                            item.notes,
                            item.emphasis
                        )
                    )
                },
                warnings: sceneWarnings.map { warning in
                    TimelineWarningInput(
                        kind: warning.kind,
                        location: warning.range.location,
                        length: warning.range.length
                    )
                }
            )
        }

        return TimelineProjectInput(
            scenes: scenes,
            configuration: TimelineConfiguration(
                wordsPerMinute: configuration.wordsPerMinute,
                pauseDefaults: configuration.pauseDefaults
            )
        )
    }

    private static func timelineRating(_ rating: TakeRating) -> TimelineTakeRating {
        switch rating {
        case .good: .good
        case .bad: .bad
        case .safe: .safe
        case .unrated: .unrated
        }
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }
}

// MARK: - Track geometry

/// Vertical geometry of the timeline panel. The canvas, the labels and hit
/// testing all read the same values.
struct TimelineTrackMetrics: Equatable {
    var rulerHeight: CGFloat = 30
    var rowSpacing: CGFloat = 4
    var sceneRowHeight: CGFloat = 46
    var narrationRowHeight: CGFloat = 54
    var pauseRowHeight: CGFloat = 26
    var bRollRowHeight: CGFloat = 26
    var editingRowHeight: CGFloat = 26
    var takeRowHeight: CGFloat = 44
    var warningRowHeight: CGFloat = 22

    static let standard = TimelineTrackMetrics()

    func height(for track: TimelineTrack) -> CGFloat {
        switch track {
        case .scenes: sceneRowHeight
        case .narration: narrationRowHeight
        case .pauses: pauseRowHeight
        case .bRoll: bRollRowHeight
        case .editing: editingRowHeight
        case .takes: takeRowHeight
        case .warnings: warningRowHeight
        }
    }

    /// Top edge of a track, measured from the top of the canvas.
    func yOffset(for track: TimelineTrack) -> CGFloat {
        var y = rulerHeight
        for candidate in TimelineTrack.allCases {
            if candidate == track { return y }
            y += height(for: candidate) + rowSpacing
        }
        return y
    }

    func yRange(for track: TimelineTrack) -> ClosedRange<CGFloat> {
        let top = yOffset(for: track)
        return top...(top + height(for: track))
    }

    var trackAreaHeight: CGFloat {
        TimelineTrack.allCases.reduce(0) { $0 + height(for: $1) }
            + rowSpacing * CGFloat(max(0, TimelineTrack.allCases.count - 1))
    }

    var totalHeight: CGFloat {
        rulerHeight + trackAreaHeight
    }

    func track(atY y: CGFloat) -> TimelineTrack? {
        TimelineTrack.allCases.first { yRange(for: $0).contains(y) }
    }

    /// Gap between stacked take lanes.
    static let takeLaneGap: CGFloat = 2
    /// Height of a take block when only one lane is used.
    static let takeBlockHeight: CGFloat = 26

    /// Vertical placement of a take lane inside the takes row. The stack of
    /// lanes actually in use is centered in the row; a single lane gets a
    /// normal block height instead of a sliver at the top edge.
    func takeLaneRect(lane: Int, lanesUsed: Int) -> (offset: CGFloat, height: CGFloat) {
        let lanes = min(max(1, lanesUsed), TimelineLayoutBuilder.maximumTakeLanes)
        let available = takeRowHeight - 8
        let gaps = CGFloat(lanes - 1) * Self.takeLaneGap
        let laneHeight = lanes == 1
            ? min(Self.takeBlockHeight, available)
            : (available - gaps) / CGFloat(lanes)
        let total = laneHeight * CGFloat(lanes) + gaps
        let start = (takeRowHeight - total) / 2
        let index = min(max(lane, 0), lanes - 1)
        return (start + CGFloat(index) * (laneHeight + Self.takeLaneGap), laneHeight)
    }

    /// Take lane nearest to a point inside the takes track.
    func takeLane(atY y: CGFloat, lanesUsed: Int) -> Int {
        let top = yOffset(for: .takes)
        let lanes = min(max(1, lanesUsed), TimelineLayoutBuilder.maximumTakeLanes)
        var best = 0
        var bestDistance = CGFloat.infinity
        for lane in 0..<lanes {
            let rect = takeLaneRect(lane: lane, lanesUsed: lanes)
            let distance = abs(y - (top + rect.offset + rect.height / 2))
            if distance < bestDistance {
                best = lane
                bestDistance = distance
            }
        }
        return best
    }
}

// MARK: - Hit testing

enum TimelineHitTester {
    /// 4 pt of slack around zero-length markers and narrow blocks.
    static let hitSlackPoints: CGFloat = 4

    static func block(
        at point: CGPoint,
        layout: TimelineLayout,
        metrics: TimelineTrackMetrics,
        viewport: TimelineViewport
    ) -> TimelineBlock? {
        guard point.x.isFinite, point.y.isFinite,
              let track = metrics.track(atY: point.y) else { return nil }
        let time = viewport.time(forX: Double(point.x))
        let slack = Double(hitSlackPoints) / viewport.pointsPerSecond
        let lane = track == .takes ? metrics.takeLane(atY: point.y, lanesUsed: layout.maximumLane(on: .takes) + 1) : 0

        let candidates = layout.blocks(on: track).filter { block in
            guard block.lane == lane else { return false }
            if block.duration > 0 {
                return time >= block.start - slack && time <= block.end + slack
            }
            return abs(time - block.start) <= slack
        }

        return candidates.min { lhs, rhs in
            distance(from: time, to: lhs) < distance(from: time, to: rhs)
        }
    }

    /// Insertion index in the array without the dragged scene.
    static func sceneInsertionIndex(
        atX x: CGFloat,
        layout: TimelineLayout,
        viewport: TimelineViewport,
        excluding sceneID: UUID? = nil
    ) -> Int {
        let time = viewport.time(forX: Double(x))
        let others = layout.scenes.filter { $0.id != sceneID }
        return others.reduce(0) { count, scene in
            count + (scene.start + scene.duration / 2 < time ? 1 : 0)
        }
    }

    private static func distance(from time: TimeInterval, to block: TimelineBlock) -> Double {
        if block.duration <= 0 {
            return abs(time - block.start)
        }
        if time < block.start { return block.start - time }
        if time > block.end { return time - block.end }
        return 0
    }
}

// MARK: - Reordering

enum TimelineSceneOrder {
    /// Moves `id` to `destination` in the list without it.
    static func reorderedIDs(_ ids: [UUID], moving id: UUID, to destination: Int) -> [UUID] {
        guard let from = ids.firstIndex(of: id), ids.count > 1 else { return ids }
        var result = ids
        result.remove(at: from)
        let clamped = min(max(0, destination), result.count)
        result.insert(id, at: clamped)
        return result
    }
}

// MARK: - Zoom

/// Shared zoom so menu commands and the timeline canvas stay in sync.
@MainActor
@Observable
final class TimelineViewState {
    static let shared = TimelineViewState()

    private(set) var pointsPerSecond: Double = TimelineZoom.defaultPointsPerSecond

    init(pointsPerSecond: Double = TimelineZoom.defaultPointsPerSecond) {
        self.pointsPerSecond = TimelineZoom.clamp(pointsPerSecond)
    }

    var zoomFraction: Double {
        get { TimelineZoom.fraction(forPointsPerSecond: pointsPerSecond) }
        set { pointsPerSecond = TimelineZoom.pointsPerSecond(forFraction: newValue) }
    }

    func zoomIn() {
        pointsPerSecond = TimelineZoom.zoomedIn(pointsPerSecond)
    }

    func zoomOut() {
        pointsPerSecond = TimelineZoom.zoomedOut(pointsPerSecond)
    }

    func reset() {
        pointsPerSecond = TimelineZoom.defaultPointsPerSecond
    }

    func setPointsPerSecond(_ value: Double) {
        pointsPerSecond = TimelineZoom.clamp(value)
    }

    /// «Ajustar»: the whole video across `availableWidth`.
    func fit(totalDuration: TimeInterval, availableWidth: Double) {
        pointsPerSecond = TimelineZoom.fitPointsPerSecond(
            totalDuration: totalDuration,
            availableWidth: availableWidth
        )
    }
}

// MARK: - Editor navigation

struct TimelineJumpRequest: Equatable {
    let id: UUID
    let sceneID: UUID
    let range: NSRange
}

/// Pending paragraph/selection jump consumed by the script editor.
@MainActor
@Observable
final class TimelineNavigation {
    static let shared = TimelineNavigation()

    private(set) var pendingRequest: TimelineJumpRequest?

    func requestJump(sceneID: UUID, range: NSRange) {
        pendingRequest = TimelineJumpRequest(id: UUID(), sceneID: sceneID, range: range)
    }

    func consume(_ id: UUID) {
        guard pendingRequest?.id == id else { return }
        pendingRequest = nil
    }

    func clear() {
        pendingRequest = nil
    }
}
