import Foundation
import FrameScriptCore
import Observation

/// Immutable input for one scene analysis. Building it on the main actor and
/// analyzing it elsewhere keeps the document model off the background thread.
struct RhythmSceneSnapshot: Sendable {
    let sceneID: UUID
    let input: RhythmSceneInput
    let pauseDefaults: PauseDefaults
    let utf16Length: Int
}

/// Sendable pause range captured from `Scene.scriptText`.
struct RhythmPauseSpan: Sendable {
    let location: Int
    let length: Int
    let seconds: TimeInterval

    var end: Int { location + length }
}

/// Result of an off-main analysis pass.
struct RhythmAnalysisOutput: Sendable {
    let analyses: [UUID: RhythmSceneAnalysis]
    let projectWarnings: [RhythmWarning]
    let textLength: Int
}

/// Pure background analyzer. No `Scene`, SwiftUI or settings cross into it.
enum RhythmAnalysisRunner {
    static func analyze(
        _ snapshots: [RhythmSceneSnapshot],
        calibration: RhythmCalibration
    ) -> RhythmAnalysisOutput {
        var analyses: [UUID: RhythmSceneAnalysis] = [:]
        analyses.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let pauses = RhythmReview.pauses(
                in: snapshot.input.text,
                defaults: snapshot.pauseDefaults
            ).map {
                RhythmPauseSpan(location: $0.range.location, length: $0.range.length, seconds: $0.seconds)
            }
            let analysis = RhythmAnalyzer.analyze(
                scene: snapshot.input,
                thresholds: .init(
                    maxSentenceWords: calibration.maxSentenceWords,
                    maxSentenceSeconds: calibration.maxSentenceSeconds,
                    maxSecondsWithoutVisualChange: calibration.maxSecondsWithoutVisualChange,
                    hookMaxSeconds: calibration.hookMaxSeconds,
                    sceneLengthOutlierFactor: calibration.sceneLengthOutlierFactor
                ),
                pauseDuration: { span in
                    var total = 0.0
                    for pause in pauses where pause.location < span.end && pause.end > span.location {
                        total += pause.seconds
                    }
                    return total
                }
            )
            analyses[snapshot.sceneID] = analysis
        }

        let ordered = snapshots.compactMap { analyses[$0.sceneID] }
        let projectWarnings = RhythmReview.sceneLengthOutlierWarnings(
            from: ordered,
            factor: calibration.sceneLengthOutlierFactor
        )
        return RhythmAnalysisOutput(
            analyses: analyses,
            projectWarnings: projectWarnings,
            textLength: snapshots.reduce(0) { $0 + $1.utf16Length }
        )
    }
}

/// Debounced cache of the rhythm review (F26).
///
/// The analyzer runs off the main actor on an immutable snapshot, so a large
/// project never stalls typing or scrolling. Reads from SwiftUI are
/// observation-tracked, so the editor underlines, the review section and the
/// sidebar badges all refresh from the same result.
@MainActor
@Observable
final class RhythmReviewCenter {
    static let shared = RhythmReviewCenter()

    private(set) var analysesBySceneID: [UUID: RhythmSceneAnalysis] = [:]
    private(set) var projectWarnings: [RhythmWarning] = []
    private(set) var isEnabled = true
    /// True while a scheduled or running analysis has no result for the
    /// current text yet.
    private(set) var isPending = false
    /// Changes on every completed refresh or invalidation.
    private(set) var revision = 0
    /// Wall time of the last off-main analysis, for diagnostics.
    private(set) var lastRefreshDuration: TimeInterval = 0
    private(set) var lastAnalyzedTextLength = 0

    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    init() {}

    var totalWarningCount: Int {
        analysesBySceneID.values.reduce(0) { $0 + $1.warnings.count } + projectWarnings.count
    }

    func warnings(for sceneID: UUID) -> [RhythmWarning] {
        analysesBySceneID[sceneID]?.warnings ?? []
    }

    func warningCount(for sceneID: UUID) -> Int {
        Self.warningCount(sceneID: sceneID, analyses: analysesBySceneID, projectWarnings: projectWarnings)
    }

    /// Pure count used by the sidebar badge and by tests. Includes the
    /// project-level outliers that point at the scene.
    static func warningCount(
        sceneID: UUID,
        analyses: [UUID: RhythmSceneAnalysis],
        projectWarnings: [RhythmWarning]
    ) -> Int {
        let sceneCount = analyses[sceneID]?.warnings.count ?? 0
        let projectCount = projectWarnings.filter { $0.sceneID == sceneID.uuidString }.count
        return sceneCount + projectCount
    }

    func projectWarnings(for sceneID: UUID) -> [RhythmWarning] {
        projectWarnings.filter { $0.sceneID == sceneID.uuidString }
    }

    /// Schedules a debounced pass. Call after text, anchors, selection, settings
    /// or thresholds change.
    func scheduleRefresh(
        project: FrameProject,
        settings: AppSettings,
        delay: Duration = .milliseconds(400)
    ) {
        refreshGeneration += 1
        let generation = refreshGeneration
        analysisTask?.cancel()
        guard settings.editorPreferences.rhythmReviewEnabled else {
            clear()
            return
        }
        isEnabled = true
        isPending = true

        analysisTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, generation == self.refreshGeneration else { return }
            // Snapshot building stays on the main actor (it reads the document
            // model) but runs only after the debounce, never per keystroke.
            let calibration = RhythmReview.effectiveThresholds(project: project, settings: settings)
            let snapshots = Self.makeSnapshots(project: project, settings: settings)
            let started = DispatchTime.now()
            let output = await Task.detached(priority: .userInitiated) {
                RhythmAnalysisRunner.analyze(snapshots, calibration: calibration)
            }.value
            guard !Task.isCancelled, generation == self.refreshGeneration else {
                return
            }
            self.apply(output, started: started)
        }
    }

    /// Runs the pass immediately. Used on appear and after threshold changes.
    func refreshNow(project: FrameProject, settings: AppSettings) {
        scheduleRefresh(project: project, settings: settings, delay: .zero)
    }

    /// Drops the cached analysis for one scene. Called as soon as its text or
    /// anchors change so underlines and click targets never point at stale
    /// UTF-16 offsets.
    func invalidate(sceneID: UUID) {
        refreshGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        analysesBySceneID.removeValue(forKey: sceneID)
        projectWarnings.removeAll { $0.sceneID == sceneID.uuidString }
        isPending = true
        revision += 1
    }

    /// Removes a deleted scene from the cache.
    func removeScene(_ sceneID: UUID) {
        analysesBySceneID.removeValue(forKey: sceneID)
        projectWarnings.removeAll { $0.sceneID == sceneID.uuidString }
        revision += 1
    }

    func clear() {
        refreshGeneration += 1
        analysisTask?.cancel()
        analysisTask = nil
        isEnabled = false
        isPending = false
        analysesBySceneID = [:]
        projectWarnings = []
        lastRefreshDuration = 0
        lastAnalyzedTextLength = 0
        revision += 1
    }

    private func apply(_ output: RhythmAnalysisOutput, started: DispatchTime) {
        analysesBySceneID = output.analyses
        projectWarnings = output.projectWarnings
        lastAnalyzedTextLength = output.textLength
        lastRefreshDuration = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        isPending = false
        revision += 1
    }

    private static func makeSnapshots(
        project: FrameProject,
        settings: AppSettings
    ) -> [RhythmSceneSnapshot] {
        let configuration = DurationEstimator.configuration(
            language: project.primaryLanguage,
            learnedWordsPerMinute: project.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
        return project.scenes.sortedByOrder.map { scene in
            RhythmSceneSnapshot(
                sceneID: scene.id,
                input: RhythmReview.input(for: scene, wordsPerMinute: configuration.wordsPerMinute),
                pauseDefaults: configuration.pauseDefaults,
                utf16Length: (scene.scriptText as NSString).length
            )
        }
    }
}
