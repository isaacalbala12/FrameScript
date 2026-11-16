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
            XCTAssertTrue(text.contains { $0.contains("Pausa corta") }, "\(name): wide labels missing")
            XCTAssertTrue(text.contains { $0.contains("Panel lateral") }, "\(name): inspector missing")
            XCTAssertTrue(text.contains { $0.contains("Grabar toma") }, "\(name): production label missing")
        case "1180x760":
            // The inspector narrows the text column: Insert and Production
            // keep their labels, AI collapses to icons.
            XCTAssertTrue(text.contains { $0.contains("Pausa corta") }, "\(name): Insert labels missing")
            XCTAssertTrue(text.contains { $0.contains("Grabar toma") }, "\(name): Production labels missing")
            XCTAssertFalse(text.contains { $0.contains("Analizar escena") }, "\(name): AI should be icon-only")
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
                    "\(name): disabled bar should keep its labels at this width"
                )
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains("Grabar toma") },
                    "\(name): disabled production actions missing"
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
                    "\(name): insert actions should stay available without AI"
                )
            }
        }
    }

    // MARK: - Middle label stage

    func testActionBarUsesMiddleLabelsWhenFullLabelsDoNotFit() {
        let project = makeProject()
        let (appState, _) = makeSnapshotAppState(project: project, inspectorTab: .ai)
        let scene = project.scenes.sortedByOrder[0]

        for appearance in SnapshotAppearance.allCases {
            let theme = FrameTheme(
                colorScheme: appearance.colorScheme,
                accent: appState.settings.accentColor
            )
            let name = "ux-action-bar-middle-labels-1180x760-\(appearance.rawValue)"
            let result = SnapshotRenderer.render(
                VStack(alignment: .leading, spacing: 10) {
                    Text(scene.title)
                        .font(.system(size: 30, weight: .semibold))
                    Text("1:15 estimado · 186 palabras")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.secondaryText)
                    // Too narrow for the full label set, wide enough for the
                    // Insert and Production labels. AI stays icon-only.
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
                "\(name): Insert labels should survive the middle stage"
            )
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("Grabar toma") },
                "\(name): Production labels should survive the middle stage"
            )
            XCTAssertFalse(
                result.textFragments.contains { $0.contains("Analizar escena") },
                "\(name): AI should be icon-only in the middle stage"
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
        return project
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct UXSnapshotOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
