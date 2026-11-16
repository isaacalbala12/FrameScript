import Foundation
import FrameScriptCore
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

    func testProjectGroupEnablementMirrorsCommandAvailability() {
        let projectActions = UXEditorAction.allCases.filter { $0.group == .project }

        let noProject = UXActionBarModel(
            availability: CommandAvailability(),
            isAIProviderConfigured: true
        )
        for action in projectActions {
            XCTAssertFalse(noProject.isEnabled(action), "\(action) enabled without a project")
        }

        let projectWithoutScene = UXActionBarModel(
            availability: CommandAvailability(hasOpenProject: true, hasScenes: false),
            isAIProviderConfigured: false
        )
        for action in projectActions {
            XCTAssertTrue(
                projectWithoutScene.isEnabled(action),
                "\(action) must work with a project and no selected scene"
            )
        }

        let withScene = CommandAvailability(
            hasOpenProject: true,
            hasScenes: true,
            hasSelectedScene: true
        )
        let model = UXActionBarModel(availability: withScene, isAIProviderConfigured: false)
        for action in projectActions {
            XCTAssertEqual(
                model.isEnabled(action),
                action.shortcutCommand.map(withScene.isEnabled) ?? false,
                "\(action) drifted from the menu matrix"
            )
        }
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
        let appState = AppState(
            projectStore: ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: suite, key: "settings"),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: suite, secretStore: EmptyOBSSecretStore()),
                defaults: suite
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: suite)
        )

        let badges = UXProjectBadges(appState: appState)
        XCTAssertEqual(badges.researchPending, 0)
        XCTAssertEqual(badges.productionPending, 0)
        XCTAssertNil(badges.count(for: .researchPanel))
        XCTAssertNil(badges.count(for: .productionChecklist))
    }

    func testProductionBadgeFollowsTaskToggles() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let openTask = try? XCTUnwrap(
            appState.project.checklistTasks.first { !$0.isDone }
        )
        guard let openTask else {
            XCTFail("fixture has no open checklist task")
            return
        }

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

    func testProductionModelOnlyListsTheCurrentSceneTasks() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]

        guard let model = UXInspectorProductionModel(appState: appState) else {
            XCTFail("fixture has no selected scene")
            return
        }
        XCTAssertEqual(model.sceneID, scene.id)
        XCTAssertTrue(model.tasks.allSatisfy { $0.sceneID == scene.id })
        XCTAssertEqual(model.tasks.count, 1)
        XCTAssertEqual(model.openCount, 1)
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
    }
}
