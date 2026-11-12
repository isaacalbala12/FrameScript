import Foundation
import FrameScriptCore
import Observation

/// Debounced cache of the rhythm review (F26).
///
/// The analyzer runs on the main actor because the document model is not
/// sendable. A keystroke only schedules a pass; the analysis runs once the user
/// pauses, and a newer edit cancels the pending one. Reads from SwiftUI are
/// observation-tracked, so the editor underlines, the review section and the
/// sidebar badges all refresh from the same result.
@MainActor
@Observable
final class RhythmReviewCenter {
    static let shared = RhythmReviewCenter()

    private(set) var analysesBySceneID: [UUID: RhythmSceneAnalysis] = [:]
    private(set) var projectWarnings: [RhythmWarning] = []
    private(set) var isEnabled = true
    /// Changes on every completed refresh; useful for debugging and tests.
    private(set) var revision = 0
    /// Wall time of the last pass, for diagnostics.
    private(set) var lastRefreshDuration: TimeInterval = 0
    private(set) var lastAnalyzedTextLength = 0

    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshGeneration = 0

    private init() {}

    var totalWarningCount: Int {
        analysesBySceneID.values.reduce(0) { $0 + $1.warnings.count } + projectWarnings.count
    }

    func warnings(for sceneID: UUID) -> [RhythmWarning] {
        analysesBySceneID[sceneID]?.warnings ?? []
    }

    func warningCount(for sceneID: UUID) -> Int {
        analysesBySceneID[sceneID]?.warnings.count ?? 0
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
        refreshTask?.cancel()
        guard settings.editorPreferences.rhythmReviewEnabled else {
            clear()
            return
        }
        isEnabled = true
        refreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, generation == self.refreshGeneration else { return }
            self.performRefresh(project: project, settings: settings)
        }
    }

    /// Runs the pass immediately. Used on appear and after threshold changes.
    func refreshNow(project: FrameProject, settings: AppSettings) {
        refreshGeneration += 1
        refreshTask?.cancel()
        guard settings.editorPreferences.rhythmReviewEnabled else {
            clear()
            return
        }
        isEnabled = true
        performRefresh(project: project, settings: settings)
    }

    func clear() {
        refreshTask?.cancel()
        refreshTask = nil
        isEnabled = false
        analysesBySceneID = [:]
        projectWarnings = []
        revision += 1
    }

    private func performRefresh(project: FrameProject, settings: AppSettings) {
        let started = DispatchTime.now()
        let thresholds = RhythmReview.effectiveThresholds(project: project, settings: settings)
        let configuration = DurationEstimator.configuration(
            language: project.primaryLanguage,
            learnedWordsPerMinute: project.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
        let orderedScenes = project.scenes.sortedByOrder
        var analyses: [UUID: RhythmSceneAnalysis] = [:]
        analyses.reserveCapacity(orderedScenes.count)

        for scene in orderedScenes {
            let pauses = RhythmReview.pauses(
                in: scene.scriptText,
                defaults: configuration.pauseDefaults
            )
            let input = RhythmReview.input(for: scene, wordsPerMinute: configuration.wordsPerMinute)
            analyses[scene.id] = RhythmAnalyzer.analyze(
                scene: input,
                thresholds: .init(
                    maxSentenceWords: thresholds.maxSentenceWords,
                    maxSentenceSeconds: thresholds.maxSentenceSeconds,
                    maxSecondsWithoutVisualChange: thresholds.maxSecondsWithoutVisualChange,
                    hookMaxSeconds: thresholds.hookMaxSeconds,
                    sceneLengthOutlierFactor: thresholds.sceneLengthOutlierFactor
                ),
                pauseDuration: { span in
                    RhythmReview.pauseDuration(in: span, pauses: pauses)
                }
            )
        }

        let orderedAnalyses = orderedScenes.compactMap { analyses[$0.id] }
        analysesBySceneID = analyses
        projectWarnings = RhythmReview.sceneLengthOutlierWarnings(
            from: orderedAnalyses,
            factor: thresholds.sceneLengthOutlierFactor
        )
        lastAnalyzedTextLength = orderedScenes.reduce(0) { $0 + ($1.scriptText as NSString).length }
        lastRefreshDuration = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        revision += 1
    }
}
