import Foundation
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Wiring coverage for the Proyecto action-bar group, the two new inspector
/// tabs and the scene research chip.
///
/// `ProductionTestCase` already provides an isolated defaults suite, an
/// `AppState` with an open synthetic project, and resets the shared
/// presentation singletons. Everything here is headless: no window is opened,
/// the research window presenter is replaced with a no-op, and no test touches
/// a real preference, the Keychain or `~/Library/Application Support`.
@MainActor
final class UXProjectWiringTests: ProductionTestCase {
    override func setUp() {
        super.setUp()
        ResolvePackPresenter.shared.request = nil
    }

    override func tearDown() {
        ResolvePackPresenter.shared.request = nil
        super.tearDown()
    }

    // MARK: - Routing

    func testEveryProjectActionMapsToItsMenuCommand() {
        let expected: [UXEditorAction: ShortcutCommand] = [
            .productionChecklist: .productionChecklist,
            .researchPanel: .researchPanel,
            .assets: .assets,
            .publishingPack: .publishingPack,
            .resolvePack: .resolvePack
        ]
        let projectActions = UXEditorAction.allCases.filter { $0.group == .project }

        XCTAssertEqual(UXActionGroup.allCases.last, .project, "Proyecto must trail the bar")
        XCTAssertEqual(Set(projectActions), Set(expected.keys))
        for action in projectActions {
            XCTAssertEqual(action.shortcutCommand, expected[action], "\(action) routes to the wrong command")
            if let command = expected[action] {
                XCTAssertTrue(
                    UXProjectCommandDispatcher.commands.contains(command),
                    "\(action) is missing from the shared dispatcher"
                )
            }
        }

        // The dispatcher list and the group cannot drift apart.
        XCTAssertEqual(
            Set(UXProjectCommandDispatcher.commands),
            Set(projectActions.compactMap(\.shortcutCommand))
        )

        // Every command is a real application-menu item with a factory shortcut.
        for command in UXProjectCommandDispatcher.commands {
            XCTAssertTrue(
                ApplicationMenuSpec.items.contains { $0.command == command },
                "\(command) is not in the application menu"
            )
            XCTAssertNotNil(
                AppSettings.defaults.activeShortcut(for: command),
                "\(command) has no factory shortcut to show in the tooltip"
            )
        }
    }

    func testProjectGroupTooltipsShowTheActiveShortcut() {
        let settings = AppSettings.defaults
        for action in UXEditorAction.allCases where action.group == .project {
            let title = L10n.tr(action.titleKey, language: .spanish)
            let tooltip = UXActionTooltip.text(
                title: title,
                command: action.shortcutCommand,
                settings: settings
            )
            XCTAssertTrue(tooltip.hasPrefix(title), "\(action) tooltip lost its title")
            if let command = action.shortcutCommand,
               let binding = settings.activeShortcut(for: command) {
                XCTAssertTrue(tooltip.contains(binding.display), "\(action) tooltip omits \(binding.display)")
            }
        }
    }

    func testDispatcherIgnoresCommandsOutsideTheProjectGroup() {
        let appState = makeAppState(project: makeSpanishFixtureProject())

        XCTAssertFalse(UXProjectCommandDispatcher.perform(.save, appState: appState))
        XCTAssertFalse(UXProjectCommandDispatcher.perform(.scriptMode, appState: appState))
        XCTAssertFalse(UXProjectCommandDispatcher.perform(.analyzeCurrentScene, appState: appState))
    }

    func testDispatcherUsesTheSharedPresentationSeams() {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        var researchOpened = 0
        appState.researchWindowPresenter = { _ in researchOpened += 1 }

        XCTAssertTrue(UXProjectCommandDispatcher.perform(.productionChecklist, appState: appState))
        XCTAssertTrue(ProductionPresentation.shared.isPresented)

        ProductionPresentation.shared.resetForTesting()
        XCTAssertTrue(UXProjectCommandDispatcher.perform(.assets, appState: appState))
        XCTAssertTrue(appState.isAssetsPresented)

        XCTAssertTrue(UXProjectCommandDispatcher.perform(.publishingPack, appState: appState))
        XCTAssertTrue(PublishingPresentation.shared.isPresented)

        XCTAssertTrue(UXProjectCommandDispatcher.perform(.researchPanel, appState: appState))
        XCTAssertEqual(researchOpened, 1)
        XCTAssertNil(ResearchPresentation.shared.focusedSceneID)

        XCTAssertTrue(UXProjectCommandDispatcher.perform(.resolvePack, appState: appState))
        XCTAssertEqual(ResolvePackPresenter.shared.request?.languageCode, "es")
    }

    func testPalettePresentationDefersSheetsUntilThePaletteDismisses() {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        appState.researchWindowPresenter = { _ in }

        XCTAssertTrue(
            UXProjectCommandDispatcher.perform(
                .productionChecklist,
                appState: appState,
                presentation: .afterSheetDismissal
            )
        )
        XCTAssertFalse(ProductionPresentation.shared.isPresented)
        ProductionPresentation.shared.presentPendingRequest()
        XCTAssertTrue(ProductionPresentation.shared.isPresented)

        XCTAssertTrue(
            UXProjectCommandDispatcher.perform(
                .resolvePack,
                appState: appState,
                presentation: .afterSheetDismissal
            )
        )
        XCTAssertNil(ResolvePackPresenter.shared.request)
        ResolvePackPresenter.shared.presentPendingRequest()
        XCTAssertEqual(ResolvePackPresenter.shared.request?.languageCode, "es")
    }

    // MARK: - Enablement

    func testActionBarModelDisablesProjectActionsWithoutAProject() {
        let appState = makeClosedAppState()
        let model = UXActionBarModel(appState: appState)

        for action in UXEditorAction.allCases where action.group == .project {
            XCTAssertFalse(model.isEnabled(action), "\(action) enabled without a project")
        }
    }

    func testActionBarModelEnablesProjectActionsWithoutASelectedScene() {
        let project = FrameProject(title: "Sin escenas", scenes: [], primaryLanguage: "es")
        let appState = makeAppState(project: project)
        XCTAssertNil(appState.selectedScene)

        let model = UXActionBarModel(appState: appState)
        for action in UXEditorAction.allCases where action.group == .project {
            XCTAssertTrue(model.isEnabled(action), "\(action) must not require a scene")
        }
        XCTAssertFalse(model.isEnabled(.recordTake), "recording still needs a selected scene")
    }

    // MARK: - Badges

    func testBadgesCountPendingClaimsAndOpenProductionWork() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]

        var badges = UXProjectBadges(appState: appState)
        XCTAssertEqual(badges.researchPending, 1)
        XCTAssertEqual(badges.count(for: .researchPanel), 1)
        XCTAssertGreaterThan(badges.productionPending, 0)
        XCTAssertEqual(badges.count(for: .productionChecklist), badges.productionPending)
        XCTAssertNil(badges.count(for: .insertShortPause))
        XCTAssertNil(badges.count(for: .recordTake))

        // Personal experience is never pending, even with the flag ticked.
        _ = appState.addResearchClaim(
            text: "Lo probé y me pareció lento",
            sceneIDs: [scene.id],
            needsVerification: true,
            personalExperience: true
        )
        badges = UXProjectBadges(appState: appState)
        XCTAssertEqual(badges.researchPending, 1, "personal experience must not raise the badge")

        // Confirming every claim clears the research badge.
        for claim in appState.project.claims {
            appState.confirmResearchClaim(id: claim.id)
        }
        badges = UXProjectBadges(appState: appState)
        XCTAssertEqual(badges.researchPending, 0)
        XCTAssertNil(badges.count(for: .researchPanel))

        let empty = UXProjectBadges(researchPending: 0, productionPending: 0)
        XCTAssertNil(empty.count(for: .researchPanel))
        XCTAssertNil(empty.count(for: .productionChecklist))
    }

    func testBadgesStayEmptyWithoutAnOpenProject() {
        // Simulate a stale cache from a previous project: the badge must not
        // leak its counts into the welcome/disabled state.
        ProductionChecklistCenter.shared.refreshNow(project: makeSpanishFixtureProject())
        let appState = makeClosedAppState()

        let badges = UXProjectBadges(appState: appState)
        XCTAssertEqual(badges.researchPending, 0)
        XCTAssertEqual(badges.productionPending, 0)
        XCTAssertNil(badges.count(for: .researchPanel))
        XCTAssertNil(badges.count(for: .productionChecklist))
    }

    func testProductionBadgeFollowsTaskToggles() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let openTask = try XCTUnwrap(
            appState.project.checklistTasks.first { !$0.isDone }
        )

        let before = UXProjectBadges(appState: appState).productionPending
        XCTAssertTrue(appState.toggleProductionTask(id: openTask.id))
        let after = UXProjectBadges(appState: appState).productionPending
        XCTAssertEqual(after, before - 1)
    }

    // MARK: - Inspector registry

    func testInspectorRegistryContainsTheProjectTabs() {
        XCTAssertEqual(
            UXInspectorRegistry.definitions.map(\.tab),
            [.ai, .rhythm, .scene, .research, .production]
        )
        XCTAssertEqual(UXInspectorTab.allCases, [.ai, .rhythm, .scene, .research, .production])

        for tab in [UXInspectorTab.research, .production] {
            guard let definition = UXInspectorRegistry.definition(for: tab) else {
                XCTFail("\(tab) is not registered")
                continue
            }
            XCTAssertFalse(definition.systemImage.isEmpty)
            for language in [AppLanguage.english, .spanish, .russian] {
                let title = L10n.tr(definition.titleKey, language: language)
                XCTAssertFalse(title.isEmpty, "\(tab) has an empty title in \(language)")
                XCTAssertNotEqual(title, definition.titleKey, "\(tab) is untranslated in \(language)")
            }
        }
    }

    func testInspectorSelectionPersistsTheProjectTabs() {
        let state = UXInspectorState(defaults: suite, key: "ux.project.inspector")
        state.select(.research)
        XCTAssertEqual(UXInspectorState(defaults: suite, key: "ux.project.inspector").selectedTab, .research)
        state.select(.production)
        XCTAssertEqual(UXInspectorState(defaults: suite, key: "ux.project.inspector").selectedTab, .production)
    }

    // MARK: - Inspector toggles

    func testInspectorClaimToggleWritesTheSameFieldAsTheResearchPanel() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]
        let claim = appState.addResearchClaim(
            text: "El neumático nuevo mejora el agarre",
            status: .probable,
            sceneIDs: [scene.id],
            needsVerification: true
        )

        let binding = UXInspectorProjectBindings.claimVerification(
            claimID: claim.id,
            appState: appState
        )
        XCTAssertTrue(binding.wrappedValue)

        binding.wrappedValue = false
        XCTAssertEqual(
            appState.project.claims.first { $0.id == claim.id }?.needsVerification,
            false
        )

        // The research panel calls the same AppState API.
        appState.toggleResearchClaimVerification(id: claim.id)
        XCTAssertEqual(
            appState.project.claims.first { $0.id == claim.id }?.needsVerification,
            true
        )

        // Writing the value that is already stored must not toggle again.
        binding.wrappedValue = true
        XCTAssertEqual(
            appState.project.claims.first { $0.id == claim.id }?.needsVerification,
            true
        )
    }

    func testInspectorTaskToggleChangesTheProductionState() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]
        let task = try XCTUnwrap(
            appState.project.checklistTasks.first { $0.sceneID == scene.id && !$0.isDone }
        )
        let pendingBefore = ProductionChecklistCenter.shared.snapshot.summary.totalPending

        let binding = UXInspectorProjectBindings.taskDone(taskID: task.id, appState: appState)
        XCTAssertFalse(binding.wrappedValue)

        binding.wrappedValue = true
        XCTAssertEqual(appState.project.checklistTasks.first { $0.id == task.id }?.isDone, true)
        XCTAssertEqual(
            ProductionChecklistCenter.shared.snapshot.summary.totalPending,
            pendingBefore - 1
        )

        binding.wrappedValue = false
        XCTAssertEqual(appState.project.checklistTasks.first { $0.id == task.id }?.isDone, false)
        XCTAssertEqual(
            ProductionChecklistCenter.shared.snapshot.summary.totalPending,
            pendingBefore
        )
    }

    func testInspectorProductionRowsMatchThePanelAndHideTheResearchCopy() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)
        let claim = appState.addResearchClaim(
            text: "El circuito se reasfaltó en 2025",
            status: .probable,
            sceneIDs: [scene.id],
            needsVerification: true
        )
        XCTAssertTrue(
            appState.project.checklistTasks.contains {
                $0.kind == .research && $0.text == claim.text
            },
            "the pending claim must create its mirror checklist task"
        )
        appState.refreshProductionChecklist()

        let snapshot = ProductionChecklistCenter.shared.snapshot
        let panelTaskIDs = snapshot.items.compactMap { item -> UUID? in
            guard item.reason == .manualTask,
                  item.sceneID == scene.id,
                  case let .manualTask(taskID) = item.target
            else { return nil }
            return taskID
        }
        let model = try XCTUnwrap(UXInspectorProductionModel(appState: appState))

        XCTAssertEqual(model.tasks.map(\.id), panelTaskIDs, "inspector and panel rows must match")
        XCTAssertTrue(model.tasks.contains { $0.text == "Grabar la intro" })
        XCTAssertFalse(
            model.tasks.contains { $0.text == claim.text },
            "E-2: the research mirror must not appear in the inspector"
        )
        XCTAssertTrue(
            snapshot.items.contains { item in
                guard case .claimNeedsVerification = item.reason else { return false }
                return item.sourceText == claim.text
            },
            "the claim stays visible once, via its derived research row"
        )
    }

    // MARK: - Scene chip

    func testSceneResearchChipUsesThePendingPluralRule() {
        XCTAssertEqual(UXSceneResearchChip.text(pending: 1, language: .spanish), "1 por verificar")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 3, language: .spanish), "3 por verificar")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 1, language: .english), "1 to verify")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 4, language: .english), "4 to verify")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 1, language: .russian), "1 к проверке")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 3, language: .russian), "3 к проверке")
        XCTAssertEqual(UXSceneResearchChip.text(pending: 5, language: .russian), "5 к проверке")
        // Russian uses the singular noun form for 21 and 31, so the raw count
        // must reach the formatter instead of a hardcoded “1”.
        XCTAssertEqual(UXSceneResearchChip.text(pending: 21, language: .russian), "21 к проверке")
    }

    func testRussianPluralSingularFormsPrintTheActualCount() {
        XCTAssertEqual(
            L10n.plural("ux.inspector.production.open", count: 1, language: .russian),
            "1 открытая задача"
        )
        XCTAssertEqual(
            L10n.plural("ux.inspector.production.open", count: 21, language: .russian),
            "21 открытая задача"
        )
        XCTAssertEqual(
            L10n.plural("ux.chip.takes", count: 21, language: .russian),
            "21 дубль"
        )
    }

    func testBadgeAccessibilityUsesPluralizedNouns() throws {
        XCTAssertEqual(
            UXProjectBadgeAccessibility.text(for: .researchPanel, count: 1, language: .spanish),
            "1 afirmación pendiente"
        )
        XCTAssertEqual(
            UXProjectBadgeAccessibility.text(for: .researchPanel, count: 3, language: .spanish),
            "3 afirmaciones pendientes"
        )
        XCTAssertEqual(
            UXProjectBadgeAccessibility.text(for: .productionChecklist, count: 1, language: .spanish),
            "1 tarea pendiente"
        )
        XCTAssertEqual(
            UXProjectBadgeAccessibility.text(for: .productionChecklist, count: 21, language: .russian),
            "21 открытая задача"
        )
        XCTAssertEqual(
            UXProjectBadgeAccessibility.text(for: .researchPanel, count: 21, language: .russian),
            "21 утверждение к проверке"
        )
        XCTAssertNil(UXProjectBadgeAccessibility.text(for: .insertShortPause, count: 3, language: .spanish))

        let badges = UXProjectBadges(researchPending: 1, productionPending: 2)
        XCTAssertEqual(
            badges.accessibilityText(for: .researchPanel, language: .spanish),
            "1 afirmación pendiente"
        )
        XCTAssertEqual(
            badges.accessibilityText(for: .productionChecklist, language: .spanish),
            "2 tareas pendientes"
        )
        XCTAssertNil(badges.accessibilityText(for: .assets, language: .spanish))
    }

    func testResearchPendingCountsUseTheStoredNeedsResearchRule() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)

        _ = appState.addResearchClaim(
            text: "Lo probé y me pareció lento",
            sceneIDs: [scene.id],
            needsVerification: true,
            personalExperience: true
        )

        XCTAssertEqual(
            UXResearchPending.projectCount(in: appState.project.claims),
            appState.researchCounts().pending
        )
        XCTAssertEqual(
            UXResearchPending.sceneCount(in: appState.project.claims, sceneID: scene.id),
            appState.researchUnconfirmedCount(for: scene.id)
        )
    }

    // MARK: - Action bar layout

    func testActionBarCollapseOrderKeepsInsertLabelsLongest() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = try XCTUnwrap(project.scenes.sortedByOrder.first)

        struct Case {
            let width: CGFloat
            let present: [String]
            let absent: [String]
        }
        let cases: [Case] = [
            // All groups labeled.
            Case(width: 1_420, present: ["Pausa corta", "Analizar escena", "Grabar toma", "Producción"], absent: []),
            // Proyecto collapses first.
            Case(width: 1_100, present: ["Pausa corta", "Analizar escena", "Grabar toma"], absent: ["Investigación"]),
            // IA collapses next.
            Case(width: 760, present: ["Pausa corta", "Grabar toma"], absent: ["Analizar escena", "Investigación"]),
            // Producción collapses next; Insertar is last with labels.
            Case(width: 600, present: ["Pausa corta"], absent: ["Grabar toma", "Analizar escena", "Investigación"]),
            // Everything is icon-only.
            Case(width: 520, present: [], absent: ["Pausa corta", "Grabar toma", "Analizar escena", "Investigación"])
        ]

        for item in cases {
            let name = "ux-action-bar-collapse-\(Int(item.width))"
            let result = SnapshotRenderer.render(
                VStack(alignment: .leading, spacing: 10) {
                    Text("Barra de acciones")
                        .font(.system(size: 13, weight: .medium))
                    UXEditorActionBar(sceneID: scene.id)
                        .frame(width: item.width)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading),
                name: name,
                suite: "UXProjectWiringTests",
                size: CGSize(width: 1_500, height: 120),
                appearance: .light,
                language: .spanish,
                appState: appState
            )

            for label in item.present {
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains(label) },
                    "\(name): \(label) should still be labeled"
                )
            }
            for label in item.absent {
                XCTAssertFalse(
                    result.textFragments.contains { $0.contains(label) },
                    "\(name): \(label) should have collapsed to an icon"
                )
            }
        }
    }

    // MARK: - Helpers

    private func makeClosedAppState() -> AppState {
        AppState(
            projectStore: ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: suite, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: suite, secretStore: EmptyOBSSecretStore()),
                defaults: suite
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: suite)
        )
    }
}
