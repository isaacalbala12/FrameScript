import Foundation

extension AppState {
    /// Opens the teleprompter for the open project, starting at the scene that
    /// is selected in the editor. Previous/next scene navigation still spans the
    /// whole project, matching a run-through that begins mid-script.
    func presentTeleprompter() {
        guard hasOpenProject else { return }
        let ordered = project.scenes.sortedByOrder
        guard !ordered.isEmpty else { return }

        let snapshots = ordered.map { scene in
            TeleprompterSceneText(id: scene.id, title: scene.title, text: scene.scriptText)
        }
        let sections = TeleprompterConverter.makeSections(from: snapshots)
        let startIndex = ordered.firstIndex { $0.id == editorState.selectedSceneID } ?? 0

        TeleprompterPresenter.shared.show(
            source: StaticTeleprompterSource(sections: sections),
            startingSectionIndex: startIndex,
            language: currentLanguage
        )
    }
}

#if DEBUG
extension AppState {
    /// Debug launch-argument hook so automated runs can open the teleprompter
    /// without driving menus through accessibility.
    func presentTeleprompterForUITestingIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--framescript-ui-test-open-teleprompter") else { return }

        if arguments.contains("--framescript-ui-test-teleprompter-sample") {
            TeleprompterPresenter.shared.show(
                source: TeleprompterUITestSample.source(),
                startingSectionIndex: 0,
                language: currentLanguage
            )
            if arguments.contains("--framescript-ui-test-teleprompter-autoplay") {
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

/// Synthetic marker fixture for visual checks of the debug build only.
private enum TeleprompterUITestSample {
    static func source() -> StaticTeleprompterSource {
        let scenes = [
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
        return StaticTeleprompterSource(sections: TeleprompterConverter.makeSections(from: scenes))
    }
}
#endif
