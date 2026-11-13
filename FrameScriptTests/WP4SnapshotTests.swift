import AppKit
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

/// WP4 visual coverage: the escaleta import preview with localized warnings
/// and the RE-HOOK badge. Set `TEST_RUNNER_FS_SNAPSHOTS=1` to write the PNGs.
@MainActor
final class WP4SnapshotTests: FrameScriptTestCase {
    func testEscaletaImportPreviewWithWarningsSnapshots() {
        let appState = makeSnapshotAppState()
        let markdown = Self.escaletaWithWarnings
        let result = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            result,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let request = EscaletaImportRequest(
            url: URL(fileURLWithPath: "/tmp/escaleta-wp4.md"),
            markdown: markdown,
            result: result,
            mapping: mapping,
            mode: .newProject
        )

        for appearance in SnapshotAppearance.allCases {
            let name = "escaleta-import-warnings-standard-\(appearance.rawValue)"
            let rendered = SnapshotRenderer.render(
                EscaletaImportPreviewSheet(request: request),
                name: name,
                suite: "WP4SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            XCTAssertGreaterThan(rendered.pixelSize.width, 0, "\(name) produced no pixels")
            XCTAssertGreaterThan(rendered.pixelSize.height, 0, "\(name) produced no pixels")
            XCTAssertTrue(
                rendered.textFragments.contains { $0.contains("RE-HOOK") },
                "\(name) did not render the RE-HOOK badge: \(rendered.textFragments)"
            )
            XCTAssertTrue(
                rendered.textFragments.contains { $0.contains("MARCADOR RARO") },
                "\(name) did not render the localized unknown-cue warning: \(rendered.textFragments)"
            )
        }
    }

    private func makeSnapshotAppState() -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false

        let project = SampleData.demoProject(language: .spanish)
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults),
            defaults: defaults
        )
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: .live,
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }

    private static let escaletaWithWarnings = """
    # Escaleta sintética de prueba

    ## Promesa del vídeo

    Una promesa sintética para la prueba visual.

    ## Tesis

    Una tesis sintética para la prueba visual.

    # Guion

    ## 0:00 — Gancho

    Texto sintético del gancho.

    [RE-HOOK]

    ## 0:20 — Desarrollo

    Texto sintético del desarrollo.

    [MARCADOR RARO: algo]

    ## Sección desconocida

    Contenido sintético que no pertenece a ninguna escena.

    ## Verificar antes de grabar

    ---
    """
}
