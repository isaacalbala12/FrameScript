import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Visual coverage for every main screen that previously shipped unseen.
///
/// Each screen is rendered in Spanish, light and dark, at the default
/// 1180×760 window and at the 980×712 minimum. Set `FS_SNAPSHOTS=1` (or
/// `TEST_RUNNER_FS_SNAPSHOTS=1` through xcodebuild) to write the PNGs.
@MainActor
final class MainWindowSnapshotTests: FrameScriptTestCase {
    // MARK: - Welcome

    func testWelcomeSnapshots() {
        let appState = makeSnapshotAppState()
        renderAll("welcome", appState: appState) {
            WelcomeView()
        }
    }

    // MARK: - Workspace modes

    func testScriptModeSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        appState.editorState.selectedMode = .script
        renderAll("script-mode", appState: appState) {
            AppShellView()
        }
    }

    func testBRollModeSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        appState.editorState.selectedMode = .bRoll
        renderAll("broll-mode", appState: appState) {
            AppShellView()
        }
    }

    func testEditingModeSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        appState.editorState.selectedMode = .editing
        renderAll("editing-mode", appState: appState) {
            AppShellView()
        }
    }

    // MARK: - Settings

    func testSettingsTabSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        for tab in SettingsTab.allCases {
            appState.windowState.requestedSettingsTab = tab
            renderAll("settings-\(tab.rawValue)", appState: appState) {
                SettingsRootView()
            }
        }
    }

    func testAIProviderSettingsSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        renderAll("ai-provider-settings", appState: appState) {
            ScrollView {
                SubscriptionAISettingsView()
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: - Sheets and panels

    func testEscaletaImportPreviewSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        let markdown = Self.spanishEscaleta
        let result = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            result,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let request = EscaletaImportRequest(
            url: URL(fileURLWithPath: "/tmp/escaleta-demo.md"),
            markdown: markdown,
            result: result,
            mapping: mapping,
            mode: .newProject
        )
        renderAll("escaleta-import-preview", appState: appState) {
            EscaletaImportPreviewSheet(request: request)
        }
    }

    func testHookSheetSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        appState.settings.aiPreferences.provider = .disabled
        renderAll("hooks-sheet", appState: appState) {
            HookGeneratorSheet(mode: .hook)
        }
    }

    func testRecordingPanelSnapshots() {
        let appState = makeSnapshotAppState(project: spanishDemoProject())
        appState.recording.isPanelVisible = true
        renderAll("recording-panel", appState: appState) {
            HStack(spacing: 0) {
                RecordingPanel()
                    .frame(maxHeight: .infinity)
                Spacer(minLength: 0)
            }
        }
    }

    func testDurationPopoverSnapshots() {
        let project = spanishDemoProject()
        let appState = makeSnapshotAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]
        renderAll("duration-scene-popover", appState: appState) {
            SceneDurationPopover(scene: scene)
        }
        renderAll("duration-project-popover", appState: appState) {
            ProjectDurationPopover()
        }
    }

    // MARK: - Helpers

    private func renderAll<Content: View>(
        _ screen: String,
        appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line,
        @ViewBuilder content: () -> Content
    ) {
        for size in SnapshotSize.allCases {
            for appearance in SnapshotAppearance.allCases {
                let name = "\(screen)-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    content(),
                    name: name,
                    suite: "MainWindowSnapshotTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState,
                    file: file,
                    line: line
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels", file: file, line: line)
                XCTAssertGreaterThan(result.pixelSize.height, 0, "\(name) produced no pixels", file: file, line: line)
            }
        }
    }

    private func makeSnapshotAppState(project: FrameProject? = nil) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = false

        let store = ProjectStore(project: project ?? SampleData.defaultProject)
        if let project {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        }
        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: SnapshotOBSSecretStore()
            ),
            defaults: defaults
        )
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: .live,
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
        appState.editorState.selectedSceneID = project?.scenes.sortedByOrder.first?.id
        return appState
    }

    private func spanishDemoProject() -> FrameProject {
        var project = SampleData.demoProject(language: .spanish)
        project.targetDuration = 600
        project.scenes.first?.targetDuration = 75
        return project
    }

    private static let spanishEscaleta = """
    # Escaleta — Análisis de Apexia 3.0

    ## Promesa del vídeo

    La actualización promete arreglar el online y recuperar la categoría que todos pedían.

    ## Tesis

    El cambio de temporadas funciona; el garaje sigue siendo demasiado lento.

    ## Escaleta

    1. Gancho: la promesa y los cuatro meses de retraso.
    2. Problema: el online vacío y el emparejamiento sin avisar.
    3. Explicación: temporadas, lluvia dinámica y ventana de neumáticos.
    4. Cierre: veredicto por perfil de jugador.

    ---

    # Guion

    ## 0:00 — Gancho

    [IMAGEN: montaje de la actualización y una hoja de ruta]

    La actualización 3.0 de Apexia promete arreglar el online y recuperar la categoría que todos pedían. También llega cuatro meses tarde.

    ¿Te devuelve las ganas de volver o es otra promesa?

    ## 0:40 — Problema

    [IMAGEN: navegador de servidores con pocas salas]

    El problema nunca fue la conducción. Lo que fallaba era el online: salas vacías, emparejamiento sin avisar y una progresión que dependía de repetir la misma prueba.

    ## 1:20 — Explicación

    [IMAGEN: calendario de temporadas]

    El nuevo sistema de temporadas rota una serie cada semana y alimenta una clasificación por divisiones. La lluvia dinámica obliga a elegir neumático antes de salir.

    ## 2:10 — Cierre

    [IMAGEN: plano a cámara con el volante al fondo]

    La 3.0 no convierte a Apexia en otro juego. Sigue siendo un simulador que pide paciencia, pero por primera vez el online tiene una estructura que invita a volver mañana.
    """
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct SnapshotOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
