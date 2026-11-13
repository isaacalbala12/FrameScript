import Foundation
import FrameScriptCore

extension AppState {
    /// Opens the teleprompter for the open project, starting at the scene that
    /// is selected in the editor. Previous/next scene navigation still spans the
    /// whole project, matching a run-through that begins mid-script.
    func presentTeleprompter() {
        guard hasOpenProject else { return }
        let scenes = teleprompterScenes()
        guard !scenes.isEmpty else { return }

        let startIndex = project.scenes.sortedByOrder.firstIndex { $0.id == editorState.selectedSceneID } ?? 0
        let provider: TeleprompterSceneProvider = { [weak self] in
            guard let self, self.hasOpenProject else { return [] }
            return self.teleprompterScenes()
        }
        let speechLanguage = SpeechLanguage(projectLanguageCode: project.primaryLanguage)
        let wpmProvider: (@MainActor () -> Double?)? = { [weak self] in
            guard let self else { return nil }
            let code = self.project.primaryLanguage
            let shortCode = String(code.prefix(2))
            return self.project.learnedWordsPerMinuteByLanguage[code]
                ?? self.project.learnedWordsPerMinuteByLanguage[shortCode]
        }

        TeleprompterPresenter.shared.show(
            source: StaticTeleprompterSource(
                sections: TeleprompterContentBuilder.sections(from: scenes)
            ),
            provider: provider,
            startingSectionIndex: startIndex,
            language: currentLanguage,
            speechLanguage: speechLanguage,
            fallbackWordsPerMinuteProvider: wpmProvider
        )
    }

    private func teleprompterScenes() -> [TeleprompterSceneText] {
        project.scenes.sortedByOrder.map { scene in
            TeleprompterSceneText(id: scene.id, title: scene.title, text: scene.scriptText)
        }
    }
}

#if DEBUG
extension AppState {
    /// Debug launch-argument hook so automated runs can open the teleprompter
    /// without driving menus through accessibility.
    func presentTeleprompterForUITestingIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--framescript-ui-test-open-teleprompter") else { return }

        let sampleScenes: [TeleprompterSceneText]
        if arguments.contains("--framescript-ui-test-teleprompter-long") {
            sampleScenes = TeleprompterUITestSample.longScenes()
        } else if arguments.contains("--framescript-ui-test-teleprompter-sample") {
            sampleScenes = TeleprompterUITestSample.scenes()
        } else {
            sampleScenes = []
        }

        if !sampleScenes.isEmpty {
            let autoplay = arguments.contains("--framescript-ui-test-teleprompter-autoplay")
            TeleprompterPresenter.shared.show(
                source: StaticTeleprompterSource(
                    sections: TeleprompterContentBuilder.sections(from: sampleScenes)
                ),
                provider: { sampleScenes },
                startingSectionIndex: 0,
                language: currentLanguage
            )
            if autoplay {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    TeleprompterPresenter.shared.playForUITesting()
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<50 {
                if self.hasOpenProject { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard self.hasOpenProject else { return }
            self.presentTeleprompter()
            if ProcessInfo.processInfo.arguments.contains("--framescript-ui-test-teleprompter-autoplay") {
                try? await Task.sleep(for: .milliseconds(400))
                TeleprompterPresenter.shared.playForUITesting()
            }
        }
    }
}

/// Synthetic marker fixture for visual and performance checks of debug builds.
private enum TeleprompterUITestSample {
    static func scenes() -> [TeleprompterSceneText] {
        [
            TeleprompterSceneText(
                id: UUID(),
                title: "Hook",
                text: "Esta es una prueba del teleprompter con *énfasis suave* y **énfasis fuerte**. / Después de una pausa corta seguimos. // Pausa larga. [2s] Pausa explícita.\n[CAM: Plano medio]\nLa línea de lectura queda a un tercio de la pantalla."
            ),
            TeleprompterSceneText(
                id: UUID(),
                title: "Explanation",
                text: "Cada escena empieza con su cabecera. El texto se desplaza a la velocidad elegida en palabras por minuto. **Una idea importante** merece una pausa.\n[LOWER THIRD: Vantare]\nY aquí termina la segunda escena."
            ),
            TeleprompterSceneText(
                id: UUID(),
                title: "Close",
                text: "Gracias por leer. / Nos vemos en la siguiente toma."
            )
        ]
    }

    static func longScenes() -> [TeleprompterSceneText] {
        (0..<40).map { sceneIndex in
            let lines = (0..<50).map { lineIndex in
                let number = sceneIndex * 50 + lineIndex + 1
                return "Línea \(number) del guion largo con *énfasis* y **fuerza** para comprobar el rendimiento del teleprompter en una toma real. / Pausa breve."
            }
            return TeleprompterSceneText(
                id: UUID(),
                title: "Escena \(sceneIndex + 1)",
                text: lines.joined(separator: "\n")
            )
        }
    }
}
#endif
