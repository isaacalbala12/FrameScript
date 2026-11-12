import AppKit
import Foundation
import FrameScriptCore

// MARK: - Duration (F4 / F11 / F3)

extension AppState {
    /// Effective duration configuration for the project's language, including
    /// learned speed and the configured pause defaults.
    var editorDurationConfiguration: DurationConfiguration {
        durationConfiguration(forLanguage: project.primaryLanguage)
    }

    func durationConfiguration(for scene: Scene) -> DurationConfiguration {
        durationConfiguration(forLanguage: project.primaryLanguage)
    }

    func durationConfiguration(forLanguage language: String) -> DurationConfiguration {
        DurationEstimator.configuration(
            language: language,
            learnedWordsPerMinute: project.learnedWordsPerMinuteByLanguage,
            settings: settings
        )
    }

    /// Recomputes every scene estimate. Call after changing the language rate,
    /// pause defaults or a learned WPM.
    func refreshDurationEstimates() {
        guard hasOpenProject else { return }
        for scene in project.scenes {
            projectStore.updateSceneMetricsUsingMarkup(
                sceneID: scene.id,
                configuration: durationConfiguration(for: scene)
            )
        }
    }
}

extension ProjectStore {
    /// Duration estimate that keeps markers and pauses. Used by the app hooks
    /// in ``ProjectStore/updateCurrentSceneMetrics(sceneID:wordsPerMinute:)``.
    func updateSceneMetricsUsingMarkup(sceneID: UUID, configuration: DurationConfiguration) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        scene.estimatedDuration = DurationEstimator.estimate(
            text: scene.scriptText,
            configuration: configuration
        )
    }

    /// Central estimate used by every store call site. Falls back to the legacy
    /// words-per-minute argument when `AppState` has not installed a provider
    /// yet (for example inside `ProjectStore.init`).
    func estimatedDuration(for scene: Scene, fallbackWordsPerMinute: Int) -> TimeInterval {
        if let configuration = durationConfigurationProvider?(scene) {
            return DurationEstimator.estimate(text: scene.scriptText, configuration: configuration)
        }
        return DurationEstimator.estimate(
            text: scene.scriptText,
            wordsPerMinute: fallbackWordsPerMinute
        )
    }
}

// MARK: - Rhythm review (F26)

extension AppState {
    var rhythmReviewEnabled: Bool {
        settings.editorPreferences.rhythmReviewEnabled
    }

    var totalRhythmWarningCount: Int {
        RhythmReviewCenter.shared.totalWarningCount
    }

    func scheduleRhythmReview(for scene: Scene? = nil, delay: Duration = .milliseconds(400)) {
        RhythmReviewCenter.shared.scheduleRefresh(project: project, settings: settings, delay: delay)
    }

    func refreshRhythmReviewNow() {
        RhythmReviewCenter.shared.refreshNow(project: project, settings: settings)
    }

    func rhythmWarningText(_ warning: RhythmWarning) -> String {
        RhythmWarningFormatter.text(for: warning, language: currentLanguage)
    }

    /// Selects the warning range in the editor, switching scenes first when the
    /// warning belongs to another one.
    func selectRhythmWarning(_ warning: RhythmWarning) {
        guard let rawSceneID = warning.sceneID,
              let sceneID = UUID(uuidString: rawSceneID) else { return }
        if selectedScene?.id != sceneID {
            selectScene(sceneID)
        }
        let text = project.scenes.first(where: { $0.id == sceneID })?.scriptText ?? ""
        let textLength = (text as NSString).length
        let range = TextAnchorGeometry.clamp(
            NSRange(location: warning.range.location, length: warning.range.length),
            toLength: textLength
        )
        Task { @MainActor in
            for attempt in 0..<6 {
                if ActiveScriptEditorSession.shared.selectRange(range, inScene: sceneID) {
                    return
                }
                if attempt < 5 {
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }
    }
}
