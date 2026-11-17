import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Design-review matrix for the main window.
///
/// Every workspace mode, the full-script view, the welcome screen and each
/// inspector tab render at 1512×949 (a 14" MacBook Pro window), the standard
/// 1180×760 and the 980×712 minimum, light and dark, in Spanish. The fixture
/// mirrors the creator's real layout (nine scenes, an empty hook, a two-digit
/// production badge) with invented copy. PNGs are written with
/// `TEST_RUNNER_FS_SNAPSHOTS=1` to `/tmp/fs-snapshots/DesignReviewSnapshotTests/`.
@MainActor
final class DesignReviewSnapshotTests: FrameScriptTestCase {
    struct SizeCase {
        let label: String
        let size: CGSize
    }

    static let sizes: [SizeCase] = [
        SizeCase(label: "1512x949", size: CGSize(width: 1512, height: 949)),
        SizeCase(label: "1180x760", size: CGSize(width: 1180, height: 760)),
        SizeCase(label: "980x712", size: CGSize(width: 980, height: 712))
    ]

    func testWelcomeMatrix() {
        let (appState, _) = Self.makeAppState(project: nil, defaults: makeDefaults())
        renderMatrix("welcome", appState: appState) { WelcomeView() }
    }

    func testWorkspaceModeMatrix() {
        let modes: [(String, WorkspaceMode)] = [
            ("script", .script),
            ("visuales", .bRoll),
            ("edicion", .editing),
            ("clips", .clips),
            ("timeline", .timeline),
            ("guion-av", .avScript)
        ]
        for (label, mode) in modes {
            let (appState, inspector) = Self.makeAppState(project: Self.reviewProject(), defaults: makeDefaults())
            appState.editorState.selectedMode = mode
            renderMatrix("mode-\(label)", appState: appState) {
                AppShellView(inspectorState: inspector)
            }
        }
    }

    func testEmptySceneMatrix() {
        let project = Self.reviewProject(emptyFirstScene: true)
        let (appState, inspector) = Self.makeAppState(project: project, defaults: makeDefaults())
        renderMatrix("script-empty-scene", appState: appState) {
            AppShellView(inspectorState: inspector)
        }
    }

    func testFullScriptMatrix() {
        let (appState, inspector) = Self.makeAppState(project: Self.reviewProject(), defaults: makeDefaults())
        appState.selectFullScript()
        renderMatrix("full-script", appState: appState) {
            AppShellView(inspectorState: inspector)
        }
    }

    func testInspectorTabMatrix() {
        for tab in UXInspectorTab.allCases {
            let (appState, inspector) = Self.makeAppState(
                project: Self.reviewProject(emptyFirstScene: true),
                defaults: makeDefaults()
            )
            inspector.select(tab)
            renderMatrix("inspector-\(tab.rawValue)", appState: appState, sizes: Array(Self.sizes.prefix(2))) {
                AppShellView(inspectorState: inspector)
            }
        }
    }

    // MARK: - Helpers

    private func renderMatrix<Content: View>(
        _ screen: String,
        appState: AppState,
        sizes: [SizeCase] = DesignReviewSnapshotTests.sizes,
        file: StaticString = #filePath,
        line: UInt = #line,
        @ViewBuilder content: () -> Content
    ) {
        for sizeCase in sizes {
            for appearance in SnapshotAppearance.allCases {
                let name = "\(screen)-\(sizeCase.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    content(),
                    name: name,
                    suite: "DesignReviewSnapshotTests",
                    size: sizeCase.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState,
                    file: file,
                    line: line
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels", file: file, line: line)
            }
        }
    }

    static func makeAppState(
        project: FrameProject?,
        defaults: UserDefaults
    ) -> (AppState, UXInspectorState) {
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = project != nil
        settings.aiPreferences.provider = .disabled

        let store = ProjectStore(project: project ?? SampleData.defaultProject)
        if let project {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        }
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: DesignReviewOBSSecretStore()),
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
        appState.editorState.selectedMode = .script
        if let project {
            ProductionChecklistCenter.shared.refreshNow(project: project)
        }
        let inspector = UXInspectorState(defaults: defaults, key: "design.review.inspector")
        return (appState, inspector)
    }

    /// Nine scenes with long Spanish titles (the sidebar truncation case), an
    /// optional empty first scene and enough open tasks for a two-digit badge.
    /// Invented fixture copy only.
    static func reviewProject(emptyFirstScene: Bool = false) -> FrameProject {
        let titles = [
            "Gancho",
            "Qué es y quién lo hace",
            "Versiones e instalación",
            "Cómo funciona I",
            "Cómo funciona II",
            "Cómo se conduce",
            "Comparativa",
            "Pegas y para quién es",
            "Veredicto y llamada a la acción"
        ]
        let body = "La actualización de Apexia promete arreglar el online. [IMAGEN: hoja de ruta] "
            + "El problema nunca fue la conducción: eran las salas vacías y el emparejamiento sin avisar."
        let scenes = titles.enumerated().map { index, title in
            Scene(
                order: index,
                sectionType: index == 0 ? .hook : .custom,
                title: title,
                scriptText: (index == 0 && emptyFirstScene) ? "" : body
            )
        }
        var project = FrameProject(title: "Análisis de Apexia 3.0", scenes: scenes)
        project.targetDuration = 600
        project.checklistTasks = (1...12).map { number in
            ChecklistTask(
                text: "Tarea de producción \(number)",
                kind: number.isMultiple(of: 2) ? .record : .acquire,
                sceneID: scenes[number % scenes.count].id
            )
        }
        return project
    }
}

private struct DesignReviewOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
