import Foundation
import FrameScriptCore

/// The seam the recording controller talks to when a take starts or stops.
/// Tests replace the live implementation with a fake so no window is created.
@MainActor
protocol RecordingTeleprompterPresenting: AnyObject {
    func present(
        sections: [TeleprompterSceneText],
        startingSectionIndex: Int,
        uiLanguage: AppLanguage,
        speechLanguage: SpeechLanguage?,
        wordsPerMinute: Double
    )
    func pauseActiveSession()
    /// Pause durations the prompter's markup must use.
    var pauseDefaults: PauseDefaults { get set }
    /// Live scene provider for the take's language. `nil` keeps the snapshot
    /// passed to `present`.
    var sceneProvider: (@MainActor () -> [TeleprompterSceneText])? { get set }
}

extension RecordingTeleprompterPresenting {
    // Defaults keep in-memory test doubles minimal; the live presenter
    // overrides both.
    var pauseDefaults: PauseDefaults {
        get { .standard }
        set {}
    }

    var sceneProvider: (@MainActor () -> [TeleprompterSceneText])? {
        get { nil }
        set {}
    }
}

/// Production wiring to the shared teleprompter window.
@MainActor
final class LiveRecordingTeleprompter: RecordingTeleprompterPresenting {
    var pauseDefaults: PauseDefaults = .standard
    var sceneProvider: (@MainActor () -> [TeleprompterSceneText])?

    func present(
        sections: [TeleprompterSceneText],
        startingSectionIndex: Int,
        uiLanguage: AppLanguage,
        speechLanguage: SpeechLanguage?,
        wordsPerMinute: Double
    ) {
        guard !sections.isEmpty else { return }
        let provider: TeleprompterSceneProvider = if sceneProvider == nil {
            { sections }
        } else {
            { [weak self] in self?.sceneProvider?() ?? sections }
        }
        TeleprompterPresenter.shared.show(
            source: StaticTeleprompterSource(
                sections: TeleprompterContentBuilder.sections(
                    from: sections,
                    pauseDefaults: pauseDefaults
                )
            ),
            provider: provider,
            startingSectionIndex: startingSectionIndex,
            language: uiLanguage,
            speechLanguage: speechLanguage,
            fallbackWordsPerMinuteProvider: { wordsPerMinute },
            pauseDefaults: pauseDefaults
        )
    }

    func pauseActiveSession() {
        TeleprompterPresenter.shared.activeModel?.pause()
    }
}

// MARK: - Recording -> teleprompter

@MainActor
extension AppState: RecordingTeleprompterHook {
    func recordingCountdownDidBegin(seconds: Int) {}

    func recordingCountdownDidTick(seconds: Int) {}

    /// Opening the teleprompter when OBS confirms the take gives the reader the
    /// scene text without a second manual action. The language is the take's
    /// variant language, so a translated take reads the translated text.
    func recordingDidStart(sceneID: UUID) {
        presentRecordingTeleprompter(sceneID: sceneID)
    }

    /// Stopping the take stops the scroll but keeps the window and position.
    func recordingDidStop(sceneID: UUID, takeID: UUID?, wasInterrupted: Bool) {
        recordingTeleprompter.pauseActiveSession()
    }

    func presentRecordingTeleprompter(sceneID: UUID) {
        guard hasOpenProject else { return }
        let ordered = project.scenes.sortedByOrder
        guard let startIndex = ordered.firstIndex(where: { $0.id == sceneID }) else { return }
        let languageCode = recording.effectiveLanguage(for: ordered[startIndex])
        let speechCode = languageCode.isEmpty ? project.primaryLanguage : languageCode
        let sections = teleprompterSceneTexts(forLanguageCode: languageCode)
        guard !sections.isEmpty else { return }

        TeleprompterPresenter.shared.languageProvider = { [weak self] in
            self?.currentLanguage ?? .english
        }
        // The live presenter reads the configured pauses and the current
        // document, so a project edit or a settings change reaches an already
        // open window.
        recordingTeleprompter.pauseDefaults = settings.editorPreferences.markupPauseDefaults
        recordingTeleprompter.sceneProvider = { [weak self] in
            self?.teleprompterSceneTexts(forLanguageCode: languageCode) ?? []
        }
        recordingTeleprompter.present(
            sections: sections,
            startingSectionIndex: startIndex,
            uiLanguage: currentLanguage,
            speechLanguage: SpeechLanguage(projectLanguageCode: speechCode),
            wordsPerMinute: effectiveWPM(language: speechCode)
        )
    }

    /// Scene snapshots for the teleprompter. A non-empty language code selects
    /// that translated variant when the scene has one; otherwise the original
    /// script is read.
    func teleprompterSceneTexts(forLanguageCode languageCode: String) -> [TeleprompterSceneText] {
        let normalized = DurationEstimator.normalizedLanguageCode(languageCode)
        return project.scenes.sortedByOrder.map { scene in
            let variantText = normalized.isEmpty
                ? nil
                : scene.languageVariants.first {
                    DurationEstimator.normalizedLanguageCode($0.languageCode) == normalized
                }?.text
            return TeleprompterSceneText(
                id: scene.id,
                title: scene.title,
                text: variantText ?? scene.scriptText
            )
        }
    }
}
