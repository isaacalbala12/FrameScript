import Foundation
import FrameScriptCore
import Observation

/// Debounces learning refreshes triggered by edits. The recomputation itself
/// runs off the main actor; this only delays repeated keystrokes.
@MainActor
final class DurationLearningScheduler {
    static let shared = DurationLearningScheduler()

    private var task: Task<Void, Never>?

    func schedule(
        after delay: Duration = .milliseconds(450),
        operation: @escaping @MainActor () -> Void
    ) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Runs one learning pass off the main actor and cancels the previous one.
///
/// The parse of every take used to happen on the main actor before the detached
/// EMA step, so a settled keystroke cost tens of milliseconds. A generation
/// token makes a superseded pass drop its result instead of overwriting newer
/// state.
@MainActor
final class DurationLearningWorker {
    static let shared = DurationLearningWorker()

    private var task: Task<DurationLearningResult?, Never>?
    private var generation = 0

    func start(
        inputs: [DurationLearningTakeInput],
        resetCutoffs: [String: Date]
    ) -> (generation: Int, task: Task<DurationLearningResult?, Never>) {
        task?.cancel()
        generation += 1
        let currentGeneration = generation
        let task = Task.detached(priority: .userInitiated) { () -> DurationLearningResult? in
            guard !Task.isCancelled else { return nil }
            let samples = DurationLearning.samples(from: inputs)
            guard !Task.isCancelled else { return nil }
            return DurationLearning.recompute(samples: samples, resetCutoffs: resetCutoffs)
        }
        self.task = task
        return (currentGeneration, task)
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
    }
}

/// Cheap change counter for the duration UI.
///
/// `durationLearningSignature` hashes every script text and every take, so it
/// must not be evaluated from a SwiftUI body. Mutations that can change a
/// duration estimate bump this counter instead, and the toolbar observes the
/// integer.
@MainActor
@Observable
final class DurationRevisionCounter {
    static let shared = DurationRevisionCounter()

    private(set) var value = 0

    func bump() {
        value &+= 1
    }
}

// MARK: - Duration state for the app

@MainActor
extension AppState {
    // MARK: Language and estimates

    /// Language the visible scene text is written in. The scene editor always
    /// shows the original script, so estimates use the project language.
    var durationProjectLanguage: String {
        let code = DurationLanguage.normalized(project.primaryLanguage)
        if !code.isEmpty { return code }
        return currentLanguage.contentLanguageCode
    }

    /// Learned personal pace for a language, falling back to the reading-speed
    /// setting. This is the single value estimates use.
    func effectiveWPM(language: String? = nil) -> Double {
        let code = DurationLanguage.normalized(language ?? durationProjectLanguage)
        return DurationEstimator.effectiveWordsPerMinute(
            language: code,
            learnedWordsPerMinute: project.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
    }

    /// Integer WPM passed into `ProjectStore`, which keeps stored estimates in
    /// sync on text edits and before saves.
    var currentDurationWordsPerMinute: Int {
        durationWordsPerMinute(for: project)
    }

    /// Learned pace for a project that is about to be opened (before it
    /// becomes `self.project`).
    func durationWordsPerMinute(for project: FrameProject) -> Int {
        let code = DurationLanguage.normalized(project.primaryLanguage)
        let pace = DurationEstimator.effectiveWordsPerMinute(
            language: code,
            learnedWordsPerMinute: project.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
        return DurationNumber.clampedInt(pace, range: 30...400)
    }

    /// Single estimate entry point for text. Markup-aware (`ScriptMarkup`
    /// ignores cues and adds pauses) and driven by the learned pace.
    func estimatedDuration(for text: String) -> TimeInterval {
        DurationEstimator.estimate(
            text: text,
            configuration: durationConfiguration(forLanguage: durationProjectLanguage)
        )
    }

    func estimatedDuration(for scene: Scene) -> TimeInterval {
        estimatedDuration(for: scene.scriptText)
    }

    // MARK: Per-scene and project summaries

    /// Scene takes plus translated-variant takes, paired with the text each
    /// take was recorded against so stale hashes can be rejected.
    func durationTakeRecords(for scene: Scene) -> [DurationTakeRecord] {
        DurationTakeRecords.make(
            scene: scene,
            primaryLanguage: project.primaryLanguage,
            sceneTextHash: projectStore.textHash(for: scene)
        )
    }

    func sceneDurationSummary(for scene: Scene) -> SceneDurationSummary {
        sceneDurationSummary(for: scene, language: durationProjectLanguage)
    }

    func sceneDurationSummary(for scene: Scene, language: String) -> SceneDurationSummary {
        let selected = DurationTakeSelector.selectedTake(
            from: durationTakeRecords(for: scene),
            language: language
        )
        return SceneDurationSummary(
            sceneID: scene.id,
            estimated: storedEstimatedDuration(for: scene),
            real: selected?.take.duration,
            realTakeID: selected?.take.id,
            realTakeNumber: selected?.take.number,
            realTakeRating: selected?.take.rating,
            target: scene.targetDuration
        )
    }

    func projectDurationSummary() -> ProjectDurationSummary {
        ProjectDurationSummary(
            sceneSummaries: project.scenes.sortedByOrder.map { sceneDurationSummary(for: $0) },
            target: project.targetDuration
        )
    }

    /// Display uses the stored estimate that `ProjectStore` refreshes on every
    /// edit and save. That keeps summaries cheap enough to evaluate during
    /// normal typing instead of re-parsing every scene per keystroke.
    private func storedEstimatedDuration(for scene: Scene) -> TimeInterval {
        let stored = scene.estimatedDuration
        if stored.isFinite, stored >= 0, stored <= DurationLimits.maximumDuration {
            return stored
        }
        return estimatedDuration(for: scene)
    }

    // MARK: Targets

    /// Cheap structural value the toolbar observes instead of
    /// `durationLearningSignature` (which hashes every script text, so it must
    /// never be read from a SwiftUI body).
    ///
    /// The counter alone was not enough: scene delete/duplicate, variant edits
    /// and imported takes never bumped it, so the learned pace went stale after
    /// structural edits (WP3 item 4). This hashes ids, take counts and variant
    /// lengths, which is cheap but still changes for every one of those edits.
    var durationRevision: Int {
        var hasher = Hasher()
        hasher.combine(DurationRevisionCounter.shared.value)
        hasher.combine(project.id)
        for scene in project.scenes {
            hasher.combine(scene.id)
            hasher.combine(scene.takes.count)
            for variant in scene.languageVariants {
                hasher.combine(variant.languageCode)
                hasher.combine(variant.text.utf16.count)
                hasher.combine(variant.takes.count)
            }
        }
        return hasher.finalize()
    }

    func setProjectTargetDuration(_ duration: TimeInterval?) {
        if let duration {
            guard let sanitized = DurationLimits.sanitizedTarget(duration) else { return }
            project.targetDuration = sanitized
        } else {
            project.targetDuration = nil
        }
        DurationRevisionCounter.shared.bump()
        touchProject()
    }

    func setSceneTargetDuration(_ duration: TimeInterval?, sceneID: UUID) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        if let duration {
            guard let sanitized = DurationLimits.sanitizedTarget(duration) else { return }
            scene.targetDuration = sanitized
        } else {
            scene.targetDuration = nil
        }
        DurationRevisionCounter.shared.bump()
        touchProject()
    }

    // MARK: WPM learning

    /// Rebuilds learned WPM from every good take. Rebuilding is idempotent, so
    /// the same code runs on project open and whenever a take rating changes.
    func durationLearningReport() -> DurationLearningResult {
        guard hasOpenProject else { return .empty }
        return DurationLearning.recompute(
            samples: DurationLearning.samples(from: durationLearningInputs()),
            resetCutoffs: project.learnedWordsPerMinuteResetAtByLanguage
        )
    }

    /// Sendable take copies for the off-main learner. Built on the main actor
    /// because it reads the document model, but it only copies value types.
    func durationLearningInputs() -> [DurationLearningTakeInput] {
        guard hasOpenProject else { return [] }
        return DurationLearning.inputs(
            from: project.scenes,
            primaryLanguage: project.primaryLanguage
        )
    }

    /// Popover-friendly report: only the value copies are made on the main
    /// actor, the parse and the EMA run off it.
    func durationLearningReportAsync() async -> DurationLearningResult {
        guard hasOpenProject else { return .empty }
        let inputs = durationLearningInputs()
        let cutoffs = project.learnedWordsPerMinuteResetAtByLanguage
        return await Task.detached(priority: .userInitiated) {
            DurationLearning.recompute(
                samples: DurationLearning.samples(from: inputs),
                resetCutoffs: cutoffs
            )
        }.value
    }

    /// Synchronous variant used by tests and explicit UI actions.
    func recomputeLearnedWPM(markDirty: Bool = true) {
        guard hasOpenProject else { return }
        let projectID = project.id
        applyLearningReport(
            durationLearningReport(),
            projectID: projectID,
            signature: durationLearningSignature,
            resetCutoffs: project.learnedWordsPerMinuteResetAtByLanguage,
            markDirty: markDirty
        )
    }

    /// Open-time and edit-time recompute. Only value copies are made on the main
    /// actor; the markup parse of every take and the EMA run in a detached task,
    /// and a newer pass cancels the previous one.
    func recomputeLearnedWPMInBackground(markDirty: Bool = false) {
        guard hasOpenProject else { return }
        let projectID = project.id
        let signature = durationLearningSignature
        let inputs = durationLearningInputs()
        let cutoffs = project.learnedWordsPerMinuteResetAtByLanguage
        let worker = DurationLearningWorker.shared
        let (generation, task) = worker.start(inputs: inputs, resetCutoffs: cutoffs)

        Task { @MainActor [weak self] in
            let report = await task.value
            guard let self,
                  let report,
                  worker.isCurrent(generation) else { return }
            self.applyLearningReport(
                report,
                projectID: projectID,
                signature: signature,
                resetCutoffs: cutoffs,
                markDirty: markDirty
            )
        }
    }

    private func applyLearningReport(
        _ report: DurationLearningResult,
        projectID: UUID,
        signature: Int,
        resetCutoffs: [String: Date],
        markDirty: Bool
    ) {
        guard hasOpenProject,
              project.id == projectID,
              durationLearningSignature == signature,
              project.learnedWordsPerMinuteResetAtByLanguage == resetCutoffs else {
            return
        }
        // Rebuilding from takes must not discard a pace learned from
        // teleprompter sessions (F9). Sessions are not stored in the document,
        // and the take learner needs three accepted samples before it reports a
        // value, so with one or two good takes the rebuild would still be
        // empty. Keep the value already in use until the take rebuild has
        // enough evidence to win.
        let minimumSamples = max(1, WPMConfiguration().minimumAcceptedSamples)
        var learned = report.learnedWordsPerMinuteByLanguage
        for (code, existing) in project.learnedWordsPerMinuteByLanguage {
            let statistics = report.statistics(for: code)
            let acceptedSamples = statistics?.acceptedSampleCount ?? 0
            if learned[code] == nil,
               acceptedSamples < minimumSamples,
               existing.isFinite,
               DurationLimits.plausibleWordsPerMinute.contains(existing) {
                learned[code] = existing
            }
        }

        let valuesChanged = project.learnedWordsPerMinuteByLanguage != learned
        var estimatesChanged = false
        if valuesChanged {
            project.learnedWordsPerMinuteByLanguage = learned
            // Nothing else can have changed the stored estimates here: the
            // whole-project re-parse is only needed when the pace changed.
            estimatesChanged = refreshEstimatedDurationsUsingLearnedWPM()
        }

        guard valuesChanged || estimatesChanged else { return }
        if markDirty {
            touchProject()
        }
    }

    /// Forgets the learned pace for one language and persists the cutoff in
    /// the project document. Takes recorded at or before `date` stop teaching
    /// the learner; the next few good takes teach it again.
    func resetLearnedWPM(language: String, at date: Date = Date()) {
        let code = DurationLanguage.normalized(language)
        guard !code.isEmpty else { return }
        project.learnedWordsPerMinuteResetAtByLanguage[code] = date
        project.learnedWordsPerMinuteByLanguage[code] = nil
        _ = refreshEstimatedDurationsUsingLearnedWPM()
        DurationRevisionCounter.shared.bump()
        touchProject()
    }

    /// Keeps the stored `scene.estimatedDuration` (used by exports and the
    /// legacy total) in sync with the learned pace. Returns whether anything
    /// changed.
    @discardableResult
    private func refreshEstimatedDurationsUsingLearnedWPM() -> Bool {
        // The configuration-based refresh is the single source of truth: it
        // also updates `SceneMetricsCache`, so the editor header and the
        // stored estimates never disagree.
        refreshDurationEstimates()
    }

    /// Cheap value that changes when take ratings, durations, read texts,
    /// scene texts, variant texts or targets change.
    var durationLearningSignature: Int {
        var hasher = Hasher()
        hasher.combine(project.id)
        hasher.combine(project.primaryLanguage)
        let scenes = project.scenes.sortedByOrder
        hasher.combine(scenes.count)
        for scene in scenes {
            hasher.combine(scene.id)
            hasher.combine(scene.scriptText)
            hasher.combine(scene.targetDuration)
            hasher.combine(scene.takes.count)
            for take in scene.takes {
                hash(take, into: &hasher)
            }
            hasher.combine(scene.languageVariants.count)
            for variant in scene.languageVariants {
                hasher.combine(variant.languageCode)
                hasher.combine(variant.text)
                hasher.combine(variant.takes.count)
                for take in variant.takes {
                    hash(take, into: &hasher)
                }
            }
        }
        return hasher.finalize()
    }

    private func hash(_ take: Take, into hasher: inout Hasher) {
        hasher.combine(take.id)
        hasher.combine(take.number)
        hasher.combine(take.rating)
        hasher.combine(take.duration)
        hasher.combine(take.startedAt)
        hasher.combine(take.languageCode)
        hasher.combine(take.readText)
        hasher.combine(take.sceneTextHash)
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
                readText: scene.scriptText,
                sceneTextHash: FrameScriptDocument.TextHash.hash(scene.scriptText)
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
