import Foundation
import FrameScriptCore

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
        guard !scene.takes.isEmpty || scene.languageVariants.contains(where: { !$0.takes.isEmpty }) else {
            return []
        }
        var records: [DurationTakeRecord] = []
        let sceneHash = FrameScriptDocument.TextHash.hash(scene.scriptText)
        for take in scene.takes {
            let language = take.languageCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? project.primaryLanguage : take.languageCode
            records.append(
                DurationTakeRecord(
                    take: take,
                    languageCode: language,
                    sourceText: scene.scriptText,
                    sourceTextHash: sceneHash
                )
            )
        }
        for variant in scene.languageVariants {
            let variantHash = FrameScriptDocument.TextHash.hash(variant.text)
            for take in variant.takes {
                records.append(
                    DurationTakeRecord(
                        take: take,
                        languageCode: variant.languageCode,
                        sourceText: variant.text,
                        sourceTextHash: variantHash
                    )
                )
            }
        }
        return records
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

    func setProjectTargetDuration(_ duration: TimeInterval?) {
        if let duration {
            guard let sanitized = DurationLimits.sanitizedTarget(duration) else { return }
            project.targetDuration = sanitized
        } else {
            project.targetDuration = nil
        }
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
        touchProject()
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
            resetCutoffs: project.learnedWordsPerMinuteResetAtByLanguage
        )
    }

    /// Popover-friendly report: sampling happens on the main actor, the EMA
    /// work does not block it.
    func durationLearningReportAsync() async -> DurationLearningResult {
        guard hasOpenProject else { return .empty }
        let samples = DurationLearning.samples(
            from: project.scenes,
            primaryLanguage: project.primaryLanguage
        )
        let cutoffs = project.learnedWordsPerMinuteResetAtByLanguage
        return await Task.detached(priority: .userInitiated) {
            DurationLearning.recompute(samples: samples, resetCutoffs: cutoffs)
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

    /// Open-time and edit-time recompute. Learning samples are gathered on the
    /// main actor (they read the model), while the EMA work runs off-main so a
    /// large project does not stall the window.
    func recomputeLearnedWPMInBackground(markDirty: Bool = false) {
        guard hasOpenProject else { return }
        let projectID = project.id
        let signature = durationLearningSignature
        let samples = DurationLearning.samples(
            from: project.scenes,
            primaryLanguage: project.primaryLanguage
        )
        let cutoffs = project.learnedWordsPerMinuteResetAtByLanguage

        Task { @MainActor [weak self] in
            let report = await Task.detached(priority: .userInitiated) {
                DurationLearning.recompute(samples: samples, resetCutoffs: cutoffs)
            }.value
            guard let self else { return }
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
        let valuesChanged = project.learnedWordsPerMinuteByLanguage
            != report.learnedWordsPerMinuteByLanguage
        if valuesChanged {
            project.learnedWordsPerMinuteByLanguage = report.learnedWordsPerMinuteByLanguage
        }

        let estimatesChanged = refreshEstimatedDurationsUsingLearnedWPM()
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
