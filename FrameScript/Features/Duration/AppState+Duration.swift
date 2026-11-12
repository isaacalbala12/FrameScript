import Foundation
import FrameScriptCore

/// Session-scoped "forget this language" cutoffs. Reset means older takes stop
/// teaching the learner; new good takes teach it again.
///
/// The v4 document stores only the learned value per language, not learner
/// history, so a cutoff cannot survive an app relaunch. Reopening the project
/// deliberately recomputes from the takes it contains (F11).
@MainActor
final class DurationLearningResetStore {
    static let shared = DurationLearningResetStore()

    private var cutoffsByProject: [UUID: [String: Date]] = [:]

    func cutoffs(for projectID: UUID) -> [String: Date] {
        cutoffsByProject[projectID] ?? [:]
    }

    func reset(projectID: UUID, language: String, at date: Date = Date()) {
        let code = DurationLanguage.normalized(language)
        guard !code.isEmpty else { return }
        cutoffsByProject[projectID, default: [:]][code] = date
    }

    func clear(projectID: UUID) {
        cutoffsByProject[projectID] = nil
    }

    func clearAll() {
        cutoffsByProject.removeAll()
    }
}

// MARK: - Duration state for the app

@MainActor
extension AppState {
    // MARK: Language and estimates

    /// Language the visible scene text is written in. The scene editor always
    /// shows the original script, so estimates use the project language.
    var durationProjectLanguage: String {
        DurationLanguage.normalized(project.primaryLanguage)
    }

    /// Learned personal pace for a language, falling back to the reading-speed
    /// setting. This is the single value estimates use.
    func effectiveWPM(language: String? = nil) -> Double {
        let code = DurationLanguage.normalized(language ?? project.primaryLanguage)
        if let learned = project.learnedWordsPerMinuteByLanguage[code],
           learned.isFinite,
           learned > 0 {
            return learned
        }
        return Double(max(1, settings.editorPreferences.wordsPerMinute))
    }

    /// Single estimate entry point. W2-A owns `DurationEstimator`; when its
    /// markup-aware per-language API lands, switch **only this line** to:
    ///
    ///     DurationEstimator.estimate(
    ///         text: scene.scriptText,
    ///         language: durationProjectLanguage,
    ///         settings: settings
    ///     )
    ///
    /// For now it uses the current estimator with ``effectiveWPM(language:)``,
    /// so learned WPM already affects every duration shown by this feature.
    func estimatedDuration(for scene: Scene) -> TimeInterval {
        DurationEstimator.estimate(
            text: scene.scriptText,
            wordsPerMinute: max(1, Int(effectiveWPM(language: durationProjectLanguage).rounded()))
        )
    }

    // MARK: Per-scene and project summaries

    func sceneDurationSummary(for scene: Scene) -> SceneDurationSummary {
        let take = DurationTakeSelector.selectedTake(
            from: scene.takes,
            language: durationProjectLanguage,
            primaryLanguage: project.primaryLanguage
        )
        return SceneDurationSummary(
            sceneID: scene.id,
            estimated: estimatedDuration(for: scene),
            real: take?.duration,
            realTakeID: take?.id,
            realTakeNumber: take?.number,
            realTakeRating: take?.rating,
            target: scene.targetDuration
        )
    }

    func projectDurationSummary() -> ProjectDurationSummary {
        ProjectDurationSummary(
            sceneSummaries: project.scenes.sortedByOrder.map(sceneDurationSummary),
            target: project.targetDuration
        )
    }

    // MARK: Targets

    func setProjectTargetDuration(_ duration: TimeInterval?) {
        project.targetDuration = Self.sanitizedTarget(duration)
        touchProject()
    }

    func setSceneTargetDuration(_ duration: TimeInterval?, sceneID: UUID) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        scene.targetDuration = Self.sanitizedTarget(duration)
        touchProject()
    }

    private static func sanitizedTarget(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    // MARK: WPM learning

    /// Rebuilds learned WPM from every good take. Rebuilding is idempotent, so
    /// the same code runs on project open and whenever a take rating changes.
    func durationLearningReport() -> DurationLearningResult {
        guard hasOpenProject else { return .empty }
        return DurationLearning.recompute(
            samples: DurationLearning.samples(
                from: project.scenes,
                primaryLanguage: project.primaryLanguage
            ),
            resetCutoffs: DurationLearningResetStore.shared.cutoffs(for: project.id)
        )
    }

    /// Persists the learned value per language. Unsupported languages and
    /// languages without enough good takes keep using the reading-speed
    /// setting.
    func recomputeLearnedWPM(markDirty: Bool = true) {
        guard hasOpenProject else { return }
        let report = durationLearningReport()
        let previousValues = project.learnedWordsPerMinuteByLanguage
        let valuesChanged = previousValues != report.learnedWordsPerMinuteByLanguage
        if valuesChanged {
            project.learnedWordsPerMinuteByLanguage = report.learnedWordsPerMinuteByLanguage
        }

        let estimatesChanged = refreshEstimatedDurationsUsingLearnedWPM()
        guard valuesChanged || estimatesChanged else { return }
        if markDirty {
            touchProject()
        }
    }

    /// Forgets the learned pace for one language and ignores takes recorded
    /// before the reset. The next few good takes teach it again.
    func resetLearnedWPM(language: String) {
        let code = DurationLanguage.normalized(language)
        guard !code.isEmpty else { return }
        DurationLearningResetStore.shared.reset(projectID: project.id, language: code)
        project.learnedWordsPerMinuteByLanguage[code] = nil
        _ = refreshEstimatedDurationsUsingLearnedWPM()
        touchProject()
    }

    /// Keeps the stored `scene.estimatedDuration` (used by exports and the
    /// legacy total) in sync with the learned pace. Returns whether anything
    /// changed.
    @discardableResult
    private func refreshEstimatedDurationsUsingLearnedWPM() -> Bool {
        var changed = false
        for scene in project.scenes {
            let updated = estimatedDuration(for: scene)
            if abs(scene.estimatedDuration - updated) > 0.0001 {
                scene.estimatedDuration = updated
                changed = true
            }
        }
        return changed
    }

    /// Cheap value that changes when take ratings, durations or read texts
    /// change. Views use it to trigger a learning refresh.
    var durationLearningSignature: Int {
        var hasher = Hasher()
        hasher.combine(project.id)
        let scenes = project.scenes.sortedByOrder
        hasher.combine(scenes.count)
        for scene in scenes {
            hasher.combine(scene.id)
            hasher.combine(scene.takes.count)
            for take in scene.takes {
                hasher.combine(take.id)
                hasher.combine(take.number)
                hasher.combine(take.rating)
                hasher.combine(take.duration)
                hasher.combine(take.startedAt)
                hasher.combine(take.languageCode)
                hasher.combine(take.readText.count)
            }
        }
        return hasher.finalize()
    }

#if DEBUG
    /// Debug-only fixture used by `--framescript-duration-demo` so the sidebar
    /// and project popover can be inspected without recording real takes.
    func seedDurationDemoIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--framescript-duration-demo") else { return }
        guard hasOpenProject, project.scenes.allSatisfy({ $0.takes.isEmpty }) else { return }

        let scenes = project.scenes.sortedByOrder
        guard scenes.count >= 5 else { return }

        func words(in scene: Scene) -> Int {
            ScriptMarkup.spokenWordCount(scene.scriptText)
        }

        func duration(for scene: Scene, pace: Double = 148) -> TimeInterval {
            max(20, Double(words(in: scene)) / pace * 60)
        }

        func makeTake(
            number: Int,
            scene: Scene,
            duration: TimeInterval,
            rating: TakeRating,
            daysAgo: Int
        ) -> Take {
            Take(
                number: number,
                startedAt: Date(timeIntervalSinceNow: -Double(daysAgo) * 86_400),
                duration: duration,
                rating: rating,
                languageCode: "",
                readText: scene.scriptText
            )
        }

        let first = scenes[0]
        first.takes = [
            makeTake(number: 1, scene: first, duration: 21, rating: .bad, daysAgo: 3),
            makeTake(number: 2, scene: first, duration: duration(for: first), rating: .good, daysAgo: 2)
        ]
        first.targetDuration = duration(for: first)

        let second = scenes[1]
        second.takes = [
            makeTake(number: 1, scene: second, duration: duration(for: second, pace: 140), rating: .safe, daysAgo: 2)
        ]

        let third = scenes[2]
        let thirdReal = duration(for: third, pace: 135)
        third.takes = [
            makeTake(number: 1, scene: third, duration: thirdReal, rating: .good, daysAgo: 1)
        ]
        // Deliberately tighter than the take so the warning is visible.
        third.targetDuration = thirdReal * 0.82

        let fifth = scenes[4]
        fifth.takes = [
            makeTake(number: 1, scene: fifth, duration: duration(for: fifth), rating: .good, daysAgo: 1)
        ]
        fifth.targetDuration = duration(for: fifth)

        project.targetDuration = 2 * 60 + 30
    }
#endif
}
