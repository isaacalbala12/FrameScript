import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Timeline fit and empty state")
struct TimelineFitTests {
    @Test func fitFillsTheAvailableWidth() {
        // 480 s over 960 pt is 2 pt/s: the whole video, not 400%.
        let fit = TimelineZoom.fitPointsPerSecond(totalDuration: 480, availableWidth: 960)
        #expect(fit == 2)
        #expect(TimelineViewport(pointsPerSecond: fit).contentWidth(totalDuration: 480) == 960)
    }

    @Test func fitGoesBelowTheManualMinimumForLongVideos() {
        let fit = TimelineZoom.fitPointsPerSecond(totalDuration: 3_600, availableWidth: 900)
        #expect(fit == 0.25)
        #expect(fit < TimelineZoom.minimumPointsPerSecond)
    }

    @Test func fitNeverZoomsInPastTheMaximum() {
        let fit = TimelineZoom.fitPointsPerSecond(totalDuration: 5, availableWidth: 900)
        #expect(fit == TimelineZoom.maximumPointsPerSecond)
    }

    @Test func fitFallsBackToDefaultOnInvalidInput() {
        #expect(TimelineZoom.fitPointsPerSecond(totalDuration: 0, availableWidth: 900) == TimelineZoom.defaultPointsPerSecond)
        #expect(TimelineZoom.fitPointsPerSecond(totalDuration: 60, availableWidth: 0) == TimelineZoom.defaultPointsPerSecond)
        #expect(TimelineZoom.fitPointsPerSecond(totalDuration: .nan, availableWidth: 900) == TimelineZoom.defaultPointsPerSecond)
    }

    @Test func isFittedDetectsTheFittedZoomOnly() {
        #expect(TimelineZoom.isFitted(pointsPerSecond: 2, totalDuration: 480, availableWidth: 960))
        #expect(!TimelineZoom.isFitted(pointsPerSecond: 4, totalDuration: 480, availableWidth: 960))
    }

    @Test func scaleReadoutMatchesTheRulerSpacing() {
        // At 4 pt/s a 64 pt tick needs 16 s, so the first preferred interval is 30 s.
        #expect(TimelineZoom.secondsPerDivision(pointsPerSecond: 4) == 30)
        #expect(TimelineZoom.secondsPerDivision(pointsPerSecond: 16) == 5)
        #expect(TimelineZoom.secondsPerDivision(pointsPerSecond: 0.5) == 300)
    }

    private func scene(paragraphs: Int, end: TimeInterval, real: TimeInterval? = nil) -> TimelineScene {
        TimelineScene(
            id: UUID(), title: "S", order: 0, start: 0, end: end,
            estimatedDuration: end, realDuration: real, takeCount: real == nil ? 0 : 1,
            paragraphCount: paragraphs
        )
    }

    @Test func emptyStateThreshold() {
        #expect(TimelineEmptyState.shouldShow(for: .empty))
        // Four untouched scenes: no text at all.
        let blank = TimelineLayout(scenes: Array(repeating: scene(paragraphs: 0, end: 0.5), count: 4), totalDuration: 2)
        #expect(TimelineEmptyState.shouldShow(for: blank))
        // Text, but only 29.9 s.
        let short = TimelineLayout(scenes: [scene(paragraphs: 2, end: 29.9)], totalDuration: 29.9)
        #expect(TimelineEmptyState.shouldShow(for: short))
        // Exactly 30 s is enough to draw.
        let enough = TimelineLayout(scenes: [scene(paragraphs: 2, end: 30)], totalDuration: 30)
        #expect(!TimelineEmptyState.shouldShow(for: enough))
        // A short video that was really recorded is not "unwritten".
        let recorded = TimelineLayout(scenes: [scene(paragraphs: 2, end: 20, real: 20)], totalDuration: 20)
        #expect(!TimelineEmptyState.shouldShow(for: recorded))
    }
}
