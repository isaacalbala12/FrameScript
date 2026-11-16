import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Visual coverage for the script action bar and the right inspector.
///
/// The main shell renders at 1440×900, 1180×760 and 980×712 in light and dark.
/// At 980 the real shell hides the inspector (the existing `< 1080` rule), so a
/// second set renders the inspector beside a neutral editor at the same size to
/// show every tab. Set `TEST_RUNNER_FS_SNAPSHOTS=1` to write the PNGs.
@MainActor
final class UXSnapshotTests: FrameScriptTestCase {
    private struct SizeCase {
        let label: String
        let size: CGSize
    }

    private let sizes: [SizeCase] = [
        SizeCase(label: "1440x900", size: CGSize(width: 1440, height: 900)),
        SizeCase(label: "1180x760", size: CGSize(width: 1180, height: 760)),
        SizeCase(label: "980x712", size: CGSize(width: 980, height: 712))
    ]

    // MARK: - Script mode with each inspector tab

    func testScriptModeInspectorTabSnapshots() {
        for tab in UXInspectorTab.allCases {
            let project = makeProject()
            let (appState, inspector) = makeSnapshotAppState(project: project, inspectorTab: tab)

            for sizeCase in sizes {
                for appearance in SnapshotAppearance.allCases {
                    let name = "ux-script-\(tab.rawValue)-\(sizeCase.label)-\(appearance.rawValue)"
                    let result = SnapshotRenderer.render(
                        AppShellView(inspectorState: inspector),
                        name: name,
                        suite: "UXSnapshotTests",
                        size: sizeCase.size,
                        appearance: appearance,
                        language: .spanish,
                        appState: appState
                    )
                    assertRendered(result, name: name)
                    assertTabContent(tab, sizeCase: sizeCase, result: result, name: name)
                }
            }
        }
    }

    private func assertTabContent(
        _ tab: UXInspectorTab,
        sizeCase: SizeCase,
        result: SnapshotRenderer.Result,
        name: String
    ) {
        let text = result.textFragments
        XCTAssertTrue(text.contains { $0.contains("Apexia") }, "\(name): script content missing")

        switch sizeCase.label {
        case "1440x900":
            // 1440 with the inspector open collapses Proyecto; Insertar keeps
            // its labels. The layout test covers the exact stage boundaries.
            XCTAssertTrue(text.contains { $0.contains("Pausa corta") }, "\(name): Insert labels missing")
            XCTAssertTrue(text.contains { $0.contains("Panel lateral") }, "\(name): inspector missing")
            XCTAssertFalse(text.contains { $0.contains("Resolve") }, "\(name): Proyecto must be icons")
        case "1180x760":
            // The inspector narrows the text column: Insertar is the group that
            // keeps its labels; IA, Producción and Proyecto are icon buttons.
            XCTAssertTrue(text.contains { $0.contains("Pausa corta") }, "\(name): Insert labels missing")
            XCTAssertFalse(text.contains { $0.contains("Resolve") }, "\(name): Proyecto must be icons")
            XCTAssertTrue(text.contains { $0.contains("Panel lateral") }, "\(name): inspector missing")
        default:
            XCTAssertTrue(text.contains { $0.contains("Pausa corta") }, "\(name): Insert labels missing")
            XCTAssertFalse(text.contains { $0.contains("Panel lateral") }, "\(name): inspector must hide")
            return
        }

        switch tab {
        case .ai:
            XCTAssertTrue(
                text.contains { $0.contains("Analizar la escena actual") },
                "\(name): AI content missing"
            )
            XCTAssertFalse(
                text.contains { $0.contains("Sin cambio de imagen") || $0.contains("Sin avisos de ritmo") },
                "\(name): the rhythm card must stay in the Ritmo tab"
            )
        case .rhythm:
            XCTAssertTrue(text.contains { $0.contains("Ritmo") }, "\(name): rhythm card missing")
        case .scene:
            XCTAssertTrue(
                text.contains { $0.contains("Objetivo de la escena") },
                "\(name): scene duration content missing"
            )
            XCTAssertTrue(text.contains { $0.contains("Tomas") }, "\(name): takes card missing")
        case .research:
            XCTAssertTrue(
                text.contains { $0.contains("Afirmaciones de la escena") },
                "\(name): research summary missing"
            )
            XCTAssertTrue(
                text.contains { $0.contains("El circuito se reasfaltó en 2025") },
                "\(name): scene claim missing"
            )
        case .production:
            XCTAssertTrue(
                text.contains { $0.contains("Tareas de la escena") },
                "\(name): production summary missing"
            )
            XCTAssertTrue(
                text.contains { $0.contains("Grabar el gancho") },
                "\(name): scene task missing"
            )
        }
    }

    // MARK: - Every tab at the minimum width

    func testInspectorTabsAtMinimumWidthSnapshots() {
        for tab in UXInspectorTab.allCases {
            let project = makeProject()
            let (appState, inspector) = makeSnapshotAppState(project: project, inspectorTab: tab)

            for appearance in SnapshotAppearance.allCases {
                let theme = FrameTheme(
                    colorScheme: appearance.colorScheme,
                    accent: appState.settings.accentColor
                )
                let name = "ux-inspector-\(tab.rawValue)-980x712-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Escena de ejemplo")
                                .font(.system(size: 30, weight: .semibold))
                            Text("El guion sigue visible mientras el panel lateral trabaja.")
                                .font(.system(size: 14))
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                        }
                        .padding(48)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(theme.editorSurface)

                        Divider()
                            .overlay(theme.divider)

                        UXInspectorPanel(state: inspector)
                            .frame(width: 292)
                    },
                    name: name,
                    suite: "UXSnapshotTests",
                    size: CGSize(width: 980, height: 712),
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                assertRendered(result, name: name)

                switch tab {
                case .ai:
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Analizar la escena actual") },
                        "\(name): AI tab content missing"
                    )
                case .rhythm:
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Ritmo") },
                        "\(name): rhythm tab content missing"
                    )
                case .scene:
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Objetivo de la escena") },
                        "\(name): scene tab content missing"
                    )
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Última toma") },
                        "\(name): latest take status missing"
                    )
                case .research:
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Afirmaciones de la escena") },
                        "\(name): research tab content missing"
                    )
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Abrir Investigación") },
                        "\(name): research open button missing"
                    )
                case .production:
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Tareas de la escena") },
                        "\(name): production tab content missing"
                    )
                    XCTAssertTrue(
                        result.textFragments.contains { $0.contains("Abrir Producción") },
                        "\(name): production open button missing"
                    )
                }
            }
        }
    }

    // MARK: - Icon-only action bar

    func testIconOnlyActionBarSnapshots() {
        let project = makeProject()
        let (appState, _) = makeSnapshotAppState(project: project, inspectorTab: .ai)
        let scene = project.scenes.sortedByOrder[0]

        for sizeCase in sizes {
            for appearance in SnapshotAppearance.allCases {
                let theme = FrameTheme(
                    colorScheme: appearance.colorScheme,
                    accent: appState.settings.accentColor
                )
                let name = "ux-action-bar-narrow-\(sizeCase.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    VStack(alignment: .leading, spacing: 10) {
                        Text(scene.title)
                            .font(.system(size: 30, weight: .semibold))
                        Text("1:15 estimado · 186 palabras")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                        UXEditorActionBar(sceneID: scene.id)
                            .frame(width: 520)
                        Spacer()
                    }
                    .padding(48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                    name: name,
                    suite: "UXSnapshotTests",
                    size: sizeCase.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                assertRendered(result, name: name)
                XCTAssertFalse(
                    result.textFragments.contains { $0.contains("Pausa corta") },
                    "\(name): icon-only mode still shows labels"
                )
                XCTAssertFalse(
                    result.textFragments.contains { $0.contains("Analizar escena") },
                    "\(name): icon-only mode still shows AI labels"
                )
            }
        }
    }

    // MARK: - Disabled state

    func testDisabledActionBarSnapshots() {
        let (appState, _) = makeSnapshotAppState(project: nil, aiConfigured: false)

        for sizeCase in sizes {
            for appearance in SnapshotAppearance.allCases {
                let theme = FrameTheme(
                    colorScheme: appearance.colorScheme,
                    accent: appState.settings.accentColor
                )
                let name = "ux-action-bar-disabled-\(sizeCase.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Escena de ejemplo")
                            .font(.system(size: 30, weight: .semibold))
                        Text("0:00 · 0 palabras")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                        UXEditorActionBar(sceneID: UUID())
                        Spacer()
                    }
                    .padding(48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                    name: name,
                    suite: "UXSnapshotTests",
                    size: sizeCase.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                assertRendered(result, name: name)
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("Pausa corta") },
                    "\(name): Insertar should keep its labels at this width"
                )
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("Grabar toma") },
                    "\(name): disabled production action missing"
                )
            }
        }
    }

    // MARK: - AI not configured

    func testAIConfiguredDisabledActionBarSnapshots() {
        let project = makeProject()
        let (appState, _) = makeSnapshotAppState(project: project, aiConfigured: false)
        let scene = project.scenes.sortedByOrder[0]

        for sizeCase in sizes {
            for appearance in SnapshotAppearance.allCases {
                let theme = FrameTheme(
                    colorScheme: appearance.colorScheme,
                    accent: appState.settings.accentColor
                )
                let name = "ux-action-bar-ai-unavailable-\(sizeCase.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    VStack(alignment: .leading, spacing: 10) {
                        Text(scene.title)
                            .font(.system(size: 30, weight: .semibold))
                        Text("1:15 estimado · 186 palabras")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.secondaryText)
                        UXEditorActionBar(sceneID: scene.id)
                        Text(L10n.tr("ux.action.aiUnavailable", language: .spanish))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        Spacer()
                    }
                    .padding(48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                    name: name,
                    suite: "UXSnapshotTests",
                    size: sizeCase.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                assertRendered(result, name: name)
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("Pausa corta") },
                    "\(name): Insertar should stay labeled without AI"
                )
            }
        }
    }

    // MARK: - Proyecto label stage

    func testActionBarKeepsInsertAndProductionLabelsAt760() {
        let project = makeProject()
        let (appState, _) = makeSnapshotAppState(project: project, inspectorTab: .ai)
        let scene = project.scenes.sortedByOrder[0]

        for appearance in SnapshotAppearance.allCases {
            let theme = FrameTheme(
                colorScheme: appearance.colorScheme,
                accent: appState.settings.accentColor
            )
            let name = "ux-action-bar-insert-production-1180x760-\(appearance.rawValue)"
            let result = SnapshotRenderer.render(
                VStack(alignment: .leading, spacing: 10) {
                    Text(scene.title)
                        .font(.system(size: 30, weight: .semibold))
                    Text("1:15 estimado · 186 palabras")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                    // Proyecto and IA have collapsed; Insertar and Producción
                    // keep their labels.
                    UXEditorActionBar(sceneID: scene.id)
                        .frame(width: 760)
                    Spacer()
                }
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                name: name,
                suite: "UXSnapshotTests",
                size: CGSize(width: 1180, height: 760),
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            assertRendered(result, name: name)
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("Pausa corta") },
                "\(name): Insertar must keep its label"
            )
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("Grabar toma") },
                "\(name): Producción must keep its label"
            )
            XCTAssertFalse(
                result.textFragments.contains { $0.contains("Analizar escena") },
                "\(name): IA should be icon-only in this stage"
            )
            XCTAssertFalse(
                result.textFragments.contains { $0.contains("Investigación") },
                "\(name): Proyecto should be icon-only in this stage"
            )
        }
    }

    // MARK: - Hover and tooltip

    func testHoveredActionTooltipSnapshots() {
        let project = makeProject()
        let (appState, _) = makeSnapshotAppState(project: project, inspectorTab: .ai)
        let scene = project.scenes.sortedByOrder[0]
        let tooltip = UXActionTooltip.text(
            title: L10n.tr("ux.action.ai.hook", language: .spanish),
            command: .generateHook,
            settings: appState.settings
        )

        for appearance in SnapshotAppearance.allCases {
            let theme = FrameTheme(
                colorScheme: appearance.colorScheme,
                accent: appState.settings.accentColor
            )
            let name = "ux-action-bar-hover-tooltip-1180x760-\(appearance.rawValue)"
            let result = SnapshotRenderer.render(
                VStack(alignment: .leading, spacing: 8) {
                    UXEditorActionBar(sceneID: scene.id, previewHoveredAction: .generateHook)
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.primaryText.opacity(0.92))
                        }
                        .padding(.leading, 300)
                    Spacer()
                }
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                name: name,
                suite: "UXSnapshotTests",
                size: CGSize(width: 1180, height: 760),
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            assertRendered(result, name: name)
            XCTAssertTrue(
                result.textFragments.contains { $0.contains(tooltip) },
                "\(name): tooltip text missing"
            )
        }
    }

    // MARK: - Proyecto wiring snapshots

    func testProjectActionBarSnapshots() {
        let project = makeProject()
        let (appState, inspector) = makeSnapshotAppState(project: project, inspectorTab: .ai)

        for size in [SizeCase(label: "1180x760", size: CGSize(width: 1180, height: 760)),
                     SizeCase(label: "980x712", size: CGSize(width: 980, height: 712))] {
            for appearance in SnapshotAppearance.allCases {
                let name = "ux-project-action-bar-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    AppShellView(inspectorState: inspector),
                    name: name,
                    suite: "UXSnapshotTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                assertRendered(result, name: name)
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("Pausa corta") },
                    "\(name): Insertar must keep its labels"
                )
                XCTAssertFalse(
                    result.textFragments.contains { $0.contains("Grabar toma") },
                    "\(name): Producción must have collapsed to icons"
                )
                XCTAssertFalse(
                    result.textFragments.contains { $0.contains("Resolve") },
                    "\(name): Proyecto must have collapsed to icons"
                )
                // The scene header keeps a single research chip, not a badge
                // plus a chip.
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("por verificar") },
                    "\(name): the scene research chip is missing"
                )
            }
        }
    }

    func testProjectInspectorTabsSnapshots() {
        for tab in [UXInspectorTab.research, .production] {
            let project = makeProject()
            let (appState, inspector) = makeSnapshotAppState(project: project, inspectorTab: tab)

            for size in [SizeCase(label: "1180x760", size: CGSize(width: 1180, height: 760)),
                         SizeCase(label: "980x712", size: CGSize(width: 980, height: 712))] {
                for appearance in SnapshotAppearance.allCases {
                    let theme = FrameTheme(
                        colorScheme: appearance.colorScheme,
                        accent: appState.settings.accentColor
                    )
                    let name = "ux-inspector-\(tab.rawValue)-\(size.label)-\(appearance.rawValue)"
                    let result = SnapshotRenderer.render(
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Escena de ejemplo")
                                    .font(.system(size: 30, weight: .semibold))
                                Text("El guion sigue visible mientras el panel lateral trabaja.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.secondaryText)
                                Spacer()
                            }
                            .padding(48)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(theme.editorSurface)

                            Divider()
                                .overlay(theme.divider)

                            UXInspectorPanel(state: inspector)
                                .frame(width: 292)
                        },
                        name: name,
                        suite: "UXSnapshotTests",
                        size: size.size,
                        appearance: appearance,
                        language: .spanish,
                        appState: appState
                    )
                    assertRendered(result, name: name)

                    switch tab {
                    case .research:
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Afirmaciones de la escena") },
                            "\(name): research summary missing"
                        )
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("El circuito se reasfaltó en 2025") },
                            "\(name): scene claim missing"
                        )
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Verificar antes de grabar") },
                            "\(name): verification checkbox missing"
                        )
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Abrir Investigación") },
                            "\(name): open button missing"
                        )
                    case .production:
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Tareas de la escena") },
                            "\(name): production summary missing"
                        )
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Grabar el gancho") },
                            "\(name): scene task missing"
                        )
                        XCTAssertFalse(
                            result.textFragments.contains { $0.contains("El circuito se reasfaltó en 2025") },
                            "\(name): E-2 research copy leaked into the production tab"
                        )
                        XCTAssertTrue(
                            result.textFragments.contains { $0.contains("Abrir Producción") },
                            "\(name): open button missing"
                        )
                    default:
                        XCTFail("unexpected tab \(tab)")
                    }
                }
            }
        }
    }

    func testSceneResearchChipSnapshots() {
        let project = makeProject()
        let (appState, inspector) = makeSnapshotAppState(
            project: project,
            inspectorTab: .research
        )
        let scene = project.scenes.sortedByOrder[0]

        for appearance in SnapshotAppearance.allCases {
            let theme = FrameTheme(
                colorScheme: appearance.colorScheme,
                accent: appState.settings.accentColor
            )
            let name = "ux-scene-research-chip-\(appearance.rawValue)"
            let result = SnapshotRenderer.render(
                VStack(alignment: .leading, spacing: 10) {
                    Text(scene.title)
                        .font(.system(size: 30, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("1:15 · 186 palabras")
                        UXSceneMetaChips(scene: scene)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    Spacer()
                }
                .environment(inspector)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                name: name,
                suite: "UXSnapshotTests",
                size: CGSize(width: 980, height: 712),
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            assertRendered(result, name: name)
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("por verificar") },
                "\(name): research chip text missing"
            )
            XCTAssertFalse(
                result.textFragments.contains { $0 == "2" },
                "\(name): the old count-only research badge is still visible"
            )
        }
    }

    // MARK: - Helpers

    private func assertRendered(
        _ result: SnapshotRenderer.Result,
        name: String
    ) {
        XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels")
        XCTAssertGreaterThan(result.pixelSize.height, 0, "\(name) produced no pixels")
        XCTAssertFalse(result.textFragments.isEmpty, "\(name) has no text")
    }

    private func makeSnapshotAppState(
        project: FrameProject?,
        aiConfigured: Bool = true,
        inspectorTab: UXInspectorTab? = nil
    ) -> (AppState, UXInspectorState) {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = project != nil
        settings.aiPreferences.provider = aiConfigured ? .openRouter : .disabled

        let store = ProjectStore(project: project ?? SampleData.defaultProject)
        if let project {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        }
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: UXSnapshotOBSSecretStore()),
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

        let inspector = UXInspectorState(defaults: defaults, key: "ux.snapshot.inspector")
        if let inspectorTab {
            inspector.select(inspectorTab)
        }
        return (appState, inspector)
    }

    private func makeProject() -> FrameProject {
        var project = SampleData.demoProject(language: .spanish)
        project.targetDuration = 600
        guard let scene = project.scenes.sortedByOrder.first else { return project }
        scene.targetDuration = 75
        scene.aiComments = [
            AIComment(
                sceneID: scene.id,
                type: "Gancho",
                severity: .important,
                message: "El gancho tarda en llegar a la promesa.",
                suggestion: "Abre con el dato del retraso."
            ),
            AIComment(
                sceneID: scene.id,
                type: "Ritmo",
                severity: .suggestion,
                message: "La segunda frase tiene 31 palabras.",
                suggestion: "Pártela en dos."
            )
        ]
        scene.takes = [
            Take(
                number: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 72,
                rating: .safe,
                note: "Bajar el ritmo en el cierre."
            ),
            Take(
                number: 2,
                startedAt: Date(timeIntervalSince1970: 1_700_000_600),
                duration: 74,
                rating: .good
            )
        ]
        // Synthetic research and production work for the Proyecto snapshots.
        // No real script or personal data: the text is invented fixture copy.
        project.claims = [
            ProjectClaim(
                text: "El circuito se reasfaltó en 2025",
                status: .probable,
                sceneIDs: [scene.id],
                needsVerification: true
            ),
            ProjectClaim(
                text: "La batería dura ocho horas de grabación",
                status: .communityOpinion,
                sceneIDs: [scene.id],
                needsVerification: true
            ),
            ProjectClaim(
                text: "El volante tiene levas de carbono",
                status: .confirmed,
                sceneIDs: [scene.id],
                needsVerification: false
            )
        ]
        project.checklistTasks = [
            ChecklistTask(
                text: "Grabar el gancho con el plano de la recta",
                kind: .record,
                sceneID: scene.id
            ),
            ChecklistTask(
                text: "Guardar el material de la cámara lenta",
                kind: .acquire,
                isDone: true,
                sceneID: scene.id
            ),
            // Mirror copy created for the pending claim above. The production
            // snapshot hides it (E-2); the inspector must not resurrect it.
            ChecklistTask(
                text: "El circuito se reasfaltó en 2025",
                kind: .research,
                sceneID: scene.id
            ),
            ChecklistTask(text: "Publicar el jueves", kind: .other)
        ]
        return project
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct UXSnapshotOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
