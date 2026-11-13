import Foundation

/// Thin `AppState` surface for recording. All take logic lives in
/// `RecordingController`; this file only gives the UI and menus a stable API and
/// connects the controller to the project's dirty/autosave rules.
@MainActor
extension AppState {
    func attachRecordingContext() {
        recording.attach(RecordingController.Gateway(
            scene: { [weak self] id in
                self?.project.scenes.first(where: { $0.id == id })
            },
            markProjectChanged: { [weak self] in
                self?.touchProject()
            },
            language: { [weak self] in
                self?.currentLanguage ?? .english
            }
        ))
    }

    /// Menu, toolbar and command palette entry point. Opens the panel so a
    /// connection problem is visible instead of silent.
    func toggleRecordingTake() {
        recording.isPanelVisible = true
        // Keep the menu/⌘R path able to stop even if the selected scene was
        // deleted while the take was running.
        if recording.phase.isActive {
            Task { [weak self] in
                await self?.recording.stopTake()
            }
            return
        }
        guard let scene = selectedScene else { return }
        let language = recording.effectiveLanguage(for: scene)
        Task { [weak self] in
            await self?.recording.toggleRecording(sceneID: scene.id, languageCode: language)
        }
    }

    func setOBSSceneName(_ name: String?, for sceneID: UUID) {
        recording.setOBSSceneName(name, for: sceneID)
    }

    @discardableResult
    func addManualRecordingTake(
        sceneID: UUID,
        startedAt: Date,
        duration: TimeInterval,
        fileURL: URL?,
        note: String,
        languageCode: String
    ) -> Bool {
        recording.addManualTake(
            sceneID: sceneID,
            startedAt: startedAt,
            duration: duration,
            fileURL: fileURL,
            note: note,
            languageCode: languageCode
        )
    }

    var hasNextScene: Bool {
        guard let index = selectedSceneIndex else { return false }
        return index + 1 < project.scenes.count
    }

    func selectNextScene() {
        let ordered = project.scenes.sortedByOrder
        guard let index = selectedSceneIndex, ordered.indices.contains(index + 1) else { return }
        selectScene(ordered[index + 1].id)
    }
}
