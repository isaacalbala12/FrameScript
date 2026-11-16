import Foundation
import FrameScriptCore
import XCTest
@testable import FrameScript

@MainActor
final class ProductionTests: ProductionTestCase {
    func testDerivedSnapshotUsesTheAppProject() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let snapshot = appState.productionSnapshot

        XCTAssertEqual(snapshot.summary.totalPending, 13)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .record), 2)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .acquire), 1)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .edit), 1)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .research), 1)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .publish), 8)
        XCTAssertEqual(snapshot.summary.pendingCount(for: .other), 0)
        XCTAssertEqual(snapshot.summary.doneManualCount, 1)
        XCTAssertTrue(snapshot.items.contains { $0.reason == .sceneNeedsTake })
        XCTAssertTrue(snapshot.items.contains { $0.reason == .bRollNeedsFootage })
        XCTAssertTrue(snapshot.items.contains { $0.reason == .editingNeedsWork })
        XCTAssertTrue(snapshot.items.contains { $0.reason == .claimNeedsVerification })
        XCTAssertTrue(snapshot.items.contains { $0.reason.publishingChecklistItem == .chosenTitle })
    }

    func testManualTaskLifecycleRefreshesTheChecklistAndMarksTheProjectDirty() throws {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        let initialCount = appState.productionSnapshot.summary.totalPending

        XCTAssertTrue(appState.addProductionTask(
            text: "  Comprar tarjeta de captura  ",
            kind: .acquire,
            sceneID: appState.project.scenes.sortedByOrder.first?.id
        ))
        XCTAssertEqual(appState.productionSnapshot.summary.totalPending, initialCount + 1)

        let task = try XCTUnwrap(appState.project.checklistTasks.last)
        XCTAssertEqual(task.text, "Comprar tarjeta de captura")
        XCTAssertEqual(task.kind, .acquire)
        XCTAssertFalse(task.isDone)
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        XCTAssertTrue(appState.toggleProductionTask(id: task.id))
        XCTAssertTrue(try XCTUnwrap(appState.project.checklistTasks.last).isDone)
        XCTAssertEqual(appState.productionSnapshot.summary.totalPending, initialCount)
        XCTAssertEqual(appState.productionSnapshot.summary.doneManualCount, 2)

        XCTAssertTrue(appState.updateProductionTask(
            id: task.id,
            text: "Comprar dos tarjetas",
            kind: .other,
            sceneID: nil
        ))
        let updated = try XCTUnwrap(appState.project.checklistTasks.last)
        XCTAssertEqual(updated.text, "Comprar dos tarjetas")
        XCTAssertEqual(updated.kind, .other)
        XCTAssertNil(updated.sceneID)

        XCTAssertTrue(appState.deleteProductionTask(id: task.id))
        XCTAssertFalse(appState.project.checklistTasks.contains { $0.id == task.id })
        XCTAssertFalse(appState.addProductionTask(text: "   "))
        XCTAssertFalse(appState.toggleProductionTask(id: UUID()))
        XCTAssertFalse(appState.deleteProductionTask(id: UUID()))
    }

    func testNavigationSelectsSceneModeAndRecordingLanguage() throws {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let firstScene = try XCTUnwrap(project.scenes.first)
        let secondScene = try XCTUnwrap(project.scenes.last)
        let bRoll = try XCTUnwrap(firstScene.bRollItems.first)
        let editing = try XCTUnwrap(firstScene.editingItems.first)

        XCTAssertTrue(appState.navigateToProductionTarget(.bRoll(sceneID: firstScene.id, itemID: bRoll.id)))
        XCTAssertEqual(appState.editorState.selectedSceneID, firstScene.id)
        XCTAssertEqual(appState.editorState.selectedMode, .bRoll)
        XCTAssertTrue(appState.editorState.selectedProductionItemIDs.contains(bRoll.id))

        XCTAssertTrue(appState.navigateToProductionTarget(.editing(sceneID: firstScene.id, itemID: editing.id)))
        XCTAssertEqual(appState.editorState.selectedMode, .editing)
        XCTAssertTrue(appState.editorState.selectedProductionItemIDs.contains(editing.id))

        XCTAssertTrue(appState.navigateToProductionTarget(.takes(sceneID: secondScene.id, languageCode: "en")))
        XCTAssertEqual(appState.editorState.selectedSceneID, secondScene.id)
        XCTAssertEqual(appState.editorState.selectedMode, .script)
        XCTAssertTrue(appState.recording.isPanelVisible)
        XCTAssertEqual(appState.recording.selectedLanguageCode, "en")

        XCTAssertTrue(appState.navigateToProductionTarget(.scene(sceneID: firstScene.id)))
        XCTAssertEqual(appState.editorState.selectedMode, .script)

        XCTAssertFalse(appState.navigateToProductionTarget(.scene(sceneID: UUID())))
        XCTAssertFalse(appState.navigateToProductionTarget(.takes(sceneID: UUID(), languageCode: "")))
    }

    func testRealProductionNavigatorOpensPublishingAndResearchPanels() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        appState.researchWindowPresenter = { _ in }
        let claim = project.claims[0]
        PublishingPresentation.shared.isPresented = false
        PublishingPresentation.shared.selectedLanguageCode = nil

        XCTAssertTrue(appState.navigateToProductionTarget(.publishing(languageCode: "es")))
        XCTAssertTrue(PublishingPresentation.shared.isPresented)
        XCTAssertEqual(PublishingPresentation.shared.selectedLanguageCode, "es")

        XCTAssertTrue(appState.navigateToProductionTarget(.research(claimID: claim.id)))
        XCTAssertEqual(ResearchPresentation.shared.selectedClaimID, claim.id)
        XCTAssertEqual(ResearchPresentation.shared.focusedSceneID, claim.sceneIDs.first)

        XCTAssertFalse(
            appState.navigateToProductionTarget(.research(claimID: UUID())),
            "An unknown claim must not pretend to have opened a panel"
        )
    }

    func testPublishingAndResearchStillHonourAnInjectedNavigator() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)
        let claim = project.claims[0]

        let navigator = RecordingProductionNavigator()
        appState.productionNavigator = navigator

        XCTAssertTrue(appState.navigateToProductionTarget(.publishing(languageCode: "es")))
        XCTAssertTrue(appState.navigateToProductionTarget(.research(claimID: claim.id)))
        XCTAssertEqual(navigator.targets, [
            .publishing(languageCode: "es"),
            .research(claimID: claim.id)
        ])

        navigator.accepts = false
        XCTAssertFalse(appState.navigateToProductionTarget(.publishing(languageCode: "es")))
        XCTAssertEqual(navigator.targets.count, 3)
    }

    func testChecklistCenterRefreshesAndClears() {
        let project = makeSpanishFixtureProject()
        let appState = makeAppState(project: project)

        XCTAssertFalse(ProductionChecklistCenter.shared.snapshot.items.isEmpty)
        XCTAssertEqual(
            ProductionChecklistCenter.shared.snapshot.summary.totalPending,
            appState.productionSnapshot.summary.totalPending
        )

        ProductionChecklistCenter.shared.clear()
        XCTAssertTrue(ProductionChecklistCenter.shared.snapshot.items.isEmpty)
        XCTAssertEqual(ProductionChecklistCenter.shared.snapshot.summary.totalPending, 0)
    }

    func testPresentationDefersUntilAfterThePaletteDismisses() {
        let presentation = ProductionPresentation.shared
        XCTAssertFalse(presentation.isPresented)

        presentation.presentAfterPaletteDismissal()
        XCTAssertFalse(presentation.isPresented)

        presentation.presentPendingRequest()
        XCTAssertTrue(presentation.isPresented)

        presentation.presentPendingRequest()
        XCTAssertTrue(presentation.isPresented)

        presentation.resetForTesting()
        XCTAssertFalse(presentation.isPresented)
    }

    func testProductionShortcutIsRegisteredAndUnique() {
        let definition = ShortcutRegistry.definition(for: .productionChecklist)

        XCTAssertEqual(definition.command, .productionChecklist)
        XCTAssertEqual(definition.localizationKey, "production.menu")
        XCTAssertEqual(definition.category, .workspace)
        XCTAssertEqual(definition.factoryDefault, .init("p", modifiers: [.command, .shift]))
        XCTAssertTrue(ShortcutRegistry.isAssignable(definition.factoryDefault))
        XCTAssertEqual(
            ShortcutRegistry.definitions.filter { $0.factoryDefault == definition.factoryDefault }.count,
            1
        )
        XCTAssertEqual(
            ShortcutRegistry.definitions.filter { $0.command == .productionChecklist }.count,
            1
        )
    }

    func testProductionLocalizationCoversEveryFeatureKeyInSpanishAndRussian() throws {
        let english = try XCTUnwrap(L10n.productionStrings[.english])
        let spanish = try XCTUnwrap(L10n.productionStrings[.spanish])
        let russian = try XCTUnwrap(L10n.productionStrings[.russian])

        XCTAssertEqual(Set(spanish.keys), Set(english.keys))
        XCTAssertEqual(Set(russian.keys), Set(english.keys))
        XCTAssertEqual(L10n.tr("production.title", language: .spanish), "Producción")
        XCTAssertEqual(L10n.tr("production.menu", language: .spanish), "Producción")
        XCTAssertEqual(L10n.tr("production.reason.sceneNeedsTake", language: .spanish), "falta grabar")
        XCTAssertEqual(L10n.tr("production.reason.bRollNeedsAsset", language: .spanish), "falta vincular el archivo")
        XCTAssertEqual(L10n.tr("production.reason.bRollNeedsFootage", language: .spanish), "falta conseguir")
        XCTAssertEqual(L10n.tr("production.reason.editingNeedsWork", language: .spanish), "falta editar")
        XCTAssertEqual(L10n.tr("production.reason.claimNeedsVerification", language: .spanish), "falta investigar")
        XCTAssertEqual(L10n.tr("production.filter.allScenes", language: .spanish), "Todas las escenas")
        XCTAssertEqual(L10n.tr("production.group.kind", language: .spanish), "Por tipo")
        XCTAssertEqual(L10n.tr("production.menu", language: .english), "Production")
        XCTAssertEqual(L10n.tr("production.menu", language: .russian), "Производство")
        for (key, value) in english where !value.isEmpty {
            XCTAssertFalse(
                spanish[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                "Missing Spanish value for \(key)"
            )
            XCTAssertFalse(
                russian[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                "Missing Russian value for \(key)"
            )
        }
    }
}
