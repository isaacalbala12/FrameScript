import Foundation
import Testing
@testable import FrameScriptCore

@Suite("ProductionChecklist")
struct ProductionChecklistTests {
    // MARK: - Empty project

    @Test func emptyProjectHasNoItems() {
        let snapshot = ProductionChecklist.snapshot(for: makeProject())

        #expect(snapshot.items.isEmpty)
        #expect(snapshot.summary.totalPending == 0)
        #expect(snapshot.summary.totalCount == 0)
        #expect(snapshot.summary.doneManualCount == 0)
        for kind in ProductionItemKind.allCases {
            #expect(snapshot.summary.pendingCount(for: kind) == 0)
        }
    }

    // MARK: - Recording

    @Test func sceneWithoutTakesNeedsRecording() {
        let scene = makeScene(title: "Gancho", text: "Hola a todos.")
        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))

        #expect(items.count == 1)
        let item = items[0]
        #expect(item.kind == .record)
        #expect(item.reason == .sceneNeedsTake)
        #expect(item.sceneID == scene.id)
        #expect(item.sceneTitle == "Gancho")
        #expect(item.languageCode == nil)
        #expect(item.target == .takes(sceneID: scene.id, languageCode: ""))
    }

    @Test func goodTakeCompletesRecording() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [makeTake(rating: .good, text: "Hola a todos.")]
        )

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func badSafeAndUnratedTakesDoNotCompleteRecording() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [
                makeTake(rating: .bad, text: "Hola a todos.", number: 1),
                makeTake(rating: .safe, text: "Hola a todos.", number: 2),
                makeTake(rating: .unrated, text: "Hola a todos.", number: 3)
            ]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].reason == .sceneNeedsTake)
    }

    @Test func staleGoodTakeNeedsRecordingAgain() {
        let scene = makeScene(
            text: "Texto nuevo.",
            takes: [makeTake(rating: .good, text: "Texto viejo.")]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].reason == .sceneNeedsTake)
    }

    @Test func legacyGoodTakeWithoutHashCountsAsRecorded() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [
                FrameScriptDocument.Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    rating: .good
                )
            ]
        )

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func emptySceneTextDoesNotNeedRecording() {
        let scene = makeScene(text: "   \n  ")

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func languageVariantNeedsItsOwnGoodTake() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [makeTake(rating: .good, text: "Hola a todos.")],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(languageCode: "en", text: "Hello everyone.")
            ]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].kind == .record)
        #expect(items[0].languageCode == "en")
        #expect(items[0].target == .takes(sceneID: scene.id, languageCode: "en"))
    }

    @Test func languageVariantGoodTakeCompletesItsLanguage() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [makeTake(rating: .good, text: "Hola a todos.")],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(
                    languageCode: "en",
                    text: "Hello everyone.",
                    takes: [makeTake(rating: .good, languageCode: "en", text: "Hello everyone.")]
                )
            ]
        )

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func sceneTakeTaggedWithVariantLanguageCompletesVariant() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [
                makeTake(rating: .good, text: "Hola a todos."),
                makeTake(rating: .good, languageCode: "en", text: "Hello everyone.", number: 2)
            ],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(languageCode: "EN-us", text: "Hello everyone.")
            ]
        )

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func emptyVariantTextIsIgnored() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [makeTake(rating: .good, text: "Hola a todos.")],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(languageCode: "en", text: "  ")
            ]
        )

        #expect(ProductionChecklist.items(for: makeProject(scenes: [scene])).isEmpty)
    }

    @Test func duplicateVariantLanguagesProduceOneRow() {
        let scene = makeScene(
            text: "Hola a todos.",
            takes: [makeTake(rating: .good, text: "Hola a todos.")],
            variants: [
                FrameScriptDocument.SceneLanguageVariant(languageCode: "en", text: "Hello everyone."),
                FrameScriptDocument.SceneLanguageVariant(languageCode: "en-US", text: "Hello again.")
            ]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].languageCode == "en")
    }

    // MARK: - B-roll

    @Test func bRollPendingNeedsFootage() {
        let bRoll = FrameScriptDocument.BRollItem(
            descriptionText: "Plano del coche",
            status: .idea
        )
        let scene = makeScene(text: "", bRoll: [bRoll])

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].kind == .acquire)
        #expect(items[0].reason == .bRollNeedsFootage)
        #expect(items[0].sourceText == "Plano del coche")
        #expect(items[0].target == .bRoll(sceneID: scene.id, itemID: bRoll.id))
    }

    @Test func bRollDoneWithLinkedAssetIsComplete() {
        let bRoll = FrameScriptDocument.BRollItem(descriptionText: "Plano", status: .done)
        let scene = makeScene(text: "", bRoll: [bRoll])
        let asset = FrameScriptDocument.ProjectAsset(
            path: "/tmp/plano.mov",
            linkedBRollItemIDs: [bRoll.id]
        )

        let project = makeProject(scenes: [scene], assets: [asset])
        #expect(ProductionChecklist.items(for: project).isEmpty)
    }

    @Test func bRollDoneWithoutAssetNeedsAsset() {
        let bRoll = FrameScriptDocument.BRollItem(descriptionText: "Plano", status: .done)
        let scene = makeScene(text: "", bRoll: [bRoll])

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].kind == .acquire)
        #expect(items[0].reason == .bRollNeedsAsset)
    }

    @Test func bRollPendingWithLinkedAssetStillNeedsFootage() {
        let bRoll = FrameScriptDocument.BRollItem(descriptionText: "Plano", status: .sourced)
        let scene = makeScene(text: "", bRoll: [bRoll])
        let asset = FrameScriptDocument.ProjectAsset(
            path: "/tmp/plano.mov",
            linkedBRollItemIDs: [bRoll.id]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene], assets: [asset]))
        #expect(items.count == 1)
        #expect(items[0].reason == .bRollNeedsFootage)
    }

    @Test func bRollFallsBackToNotesWhenDescriptionIsEmpty() {
        let bRoll = FrameScriptDocument.BRollItem(descriptionText: "", notes: "  Buscar en archivo  ")
        let scene = makeScene(text: "", bRoll: [bRoll])

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items[0].sourceText == "Buscar en archivo")
    }

    // MARK: - Editing

    @Test func editingPendingNeedsWorkAndDoneDoesNot() {
        let pending = FrameScriptDocument.EditingItem(cutStyle: "Corte seco")
        let done = FrameScriptDocument.EditingItem(cutStyle: "Fundido", status: .done)
        let scene = makeScene(text: "", editing: [pending, done])

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 1)
        #expect(items[0].kind == .edit)
        #expect(items[0].reason == .editingNeedsWork)
        #expect(items[0].sourceText == "Corte seco")
        #expect(items[0].target == .editing(sceneID: scene.id, itemID: pending.id))
    }

    @Test func editingFallsBackToNotesWhenCutStyleIsEmpty() {
        let item = FrameScriptDocument.EditingItem(cutStyle: "", notes: "Bajar música")
        let scene = makeScene(text: "", editing: [item])

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items[0].sourceText == "Bajar música")
    }

    // MARK: - Claims

    @Test func claimsNotConfirmedNeedResearch() {
        let scene = makeScene(title: "Datos", text: "")
        let confirmed = FrameScriptDocument.Claim(text: "Confirmada", status: .confirmed)
        let probable = FrameScriptDocument.Claim(
            text: "Probable",
            status: .probable,
            sceneIDs: [scene.id]
        )
        let rumor = FrameScriptDocument.Claim(text: "Rumor", status: .rumor)

        let project = makeProject(scenes: [scene], claims: [confirmed, probable, rumor])
        let items = ProductionChecklist.items(for: project)

        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.kind == .research })
        #expect(items.allSatisfy { $0.reason == .claimNeedsVerification })
        #expect(items[0].sceneID == scene.id)
        #expect(items[0].sceneTitle == "Datos")
        #expect(items[0].target == .research(claimID: probable.id))
        #expect(items[1].sceneID == nil)
        #expect(items[1].target == .research(claimID: rumor.id))
    }

    @Test func claimWithUnknownSceneStaysProjectLevel() {
        let claim = FrameScriptDocument.Claim(text: "Dato", sceneIDs: [UUID()])
        let project = makeProject(claims: [claim])

        let items = ProductionChecklist.items(for: project)
        #expect(items.count == 1)
        #expect(items[0].sceneID == nil)
    }

    @Test func personalExperienceNeverNeedsResearch() {
        let claim = FrameScriptDocument.Claim(
            text: "Yo lo probé y me pareció lento",
            status: .probable,
            needsVerification: true,
            personalExperience: true
        )

        let project = makeProject(claims: [claim])
        #expect(ProductionChecklist.items(for: project).isEmpty)
    }

    @Test func confirmedClaimFlaggedForASecondCheckNeedsResearch() {
        let claim = FrameScriptDocument.Claim(
            text: "Confirmada pero recheck",
            status: .confirmed,
            needsVerification: true
        )

        let items = ProductionChecklist.items(for: makeProject(claims: [claim]))
        #expect(items.count == 1)
        #expect(items[0].reason == .claimNeedsVerification)
        #expect(items[0].target == .research(claimID: claim.id))
    }

    @Test func mirroredResearchTaskDoesNotDuplicateTheClaimRow() {
        let claim = FrameScriptDocument.Claim(
            text: "El neumático mejora el agarre",
            status: .probable,
            needsVerification: true
        )
        let task = FrameScriptDocument.ChecklistTask(
            text: "  el neumático MEJORA el agarre ",
            kind: .research
        )

        let items = ProductionChecklist.items(
            for: makeProject(checklistTasks: [task], claims: [claim])
        )
        #expect(items.count == 1)
        #expect(items[0].kind == .research)
        #expect(items[0].reason == .claimNeedsVerification)
    }

    @Test func researchTaskWithoutAClaimStaysAsAManualRow() {
        let task = FrameScriptDocument.ChecklistTask(text: "Buscar el dato", kind: .research)

        let items = ProductionChecklist.items(for: makeProject(checklistTasks: [task]))
        #expect(items.count == 1)
        #expect(items[0].reason == .manualTask)
        #expect(items[0].kind == .research)
    }

    @Test func productionResearchCountEqualsTheSharedPendingRule() {
        let claims = [
            FrameScriptDocument.Claim(text: "Probable", status: .probable, needsVerification: true),
            FrameScriptDocument.Claim(text: "Confirmada", status: .confirmed),
            FrameScriptDocument.Claim(text: "Confirmada con recheck", status: .confirmed, needsVerification: true),
            FrameScriptDocument.Claim(text: "Rumor sin marcar", status: .rumor),
            FrameScriptDocument.Claim(text: "Experiencia", status: .probable, personalExperience: true)
        ]
        let project = makeProject(claims: claims)

        let production = ProductionChecklist.summary(for: project).pendingCount(for: .research)
        let research = ResearchSummary.counts(claims: claims).pending
        #expect(production == research)
        #expect(production == 3)
    }

    // MARK: - Publishing

    @Test func completePublishingChecklistHasNoItems() {
        let pack = FrameScriptDocument.PublishingPack(
            chosenTitle: "Título",
            description: "Descripción",
            tags: ["uno"],
            thumbnailVariants: [
                FrameScriptDocument.ThumbnailVariant(assetID: UUID(), isChosen: true)
            ]
        )
        let doneChecks = PublishingChecklistItem.allCases.map {
            FrameScriptDocument.ChecklistTask(text: $0.taskToken, kind: .other, isDone: true)
        }

        let project = makeProject(
            publishingPacks: ["es": pack],
            checklistTasks: doneChecks
        )
        #expect(ProductionChecklist.items(for: project).isEmpty)
    }

    @Test func emptyPublishingPackReportsTheEightChecklistItems() {
        let project = makeProject(publishingPacks: ["es": FrameScriptDocument.PublishingPack()])
        let items = ProductionChecklist.items(for: project)

        #expect(items.count == PublishingChecklistItem.allCases.count)
        #expect(items.count == 8)
        #expect(items.allSatisfy { $0.kind == .publish })
        #expect(Set(items.compactMap(\.reason.publishingChecklistItem)) == Set(PublishingChecklistItem.allCases))
        #expect(items.allSatisfy { $0.languageCode == "es" })
        #expect(items.allSatisfy { $0.target == .publishing(languageCode: "es") })
    }

    @Test func publishingChecklistTokensNeverAppearAsManualRows() {
        let token = PublishingChecklistItem.endScreen.taskToken
        let pack = FrameScriptDocument.PublishingPack()
        let project = makeProject(
            publishingPacks: ["es": pack],
            checklistTasks: [FrameScriptDocument.ChecklistTask(text: token, kind: .other)]
        )

        let items = ProductionChecklist.items(for: project)
        #expect(items.allSatisfy { $0.reason != .manualTask })
        #expect(items.contains { $0.reason.publishingChecklistItem == .endScreen })
        #expect(!items.contains { $0.sourceText == token })
    }

    @Test func donePublishingChecklistItemDisappearsFromItsPack() {
        let pack = FrameScriptDocument.PublishingPack()
        let done = FrameScriptDocument.ChecklistTask(
            text: PublishingChecklistItem.endScreen.taskToken,
            kind: .other,
            isDone: true
        )

        let items = ProductionChecklist.items(
            for: makeProject(publishingPacks: ["es": pack], checklistTasks: [done])
        )
        #expect(items.count == 7)
        #expect(!items.contains { $0.reason.publishingChecklistItem == .endScreen })
    }

    @Test func publishingChecklistIsEmittedOncePerProject() {
        let primary = FrameScriptDocument.PublishingPack(
            chosenTitle: "Título",
            description: "Descripción",
            tags: ["uno"],
            thumbnailVariants: [FrameScriptDocument.ThumbnailVariant(isChosen: true)]
        )
        let other = FrameScriptDocument.PublishingPack(
            description: "Descripción",
            tags: ["one"],
            thumbnailVariants: [FrameScriptDocument.ThumbnailVariant(isChosen: true)]
        )

        let project = makeProject(publishingPacks: ["es": primary, "en": other])
        let items = ProductionChecklist.items(for: project)

        // The eight checks have one project-wide done state, so two packs must
        // not double the rows (must-fix 2).
        #expect(items.count == PublishingChecklistItem.allCases.count)
        #expect(items.count == 8)
        #expect(items.allSatisfy { $0.languageCode == "es" })
        #expect(items.allSatisfy { $0.target == .publishing(languageCode: "es") })
        #expect(Set(items.map(\.id)).count == 8)
    }

    @Test func publishingChecklistUsesThePrimaryLanguagePack() {
        let project = makeProject(
            primaryLanguage: "en",
            publishingPacks: ["es": FrameScriptDocument.PublishingPack(), "en": FrameScriptDocument.PublishingPack()]
        )

        let items = ProductionChecklist.items(for: project)
        #expect(items.count == 8)
        #expect(items.allSatisfy { $0.languageCode == "en" })
    }

    @Test func publishingChecklistFallsBackToTheFirstPackWhenThePrimaryHasNone() {
        let project = makeProject(
            primaryLanguage: "es",
            publishingPacks: [
                "fr": FrameScriptDocument.PublishingPack(),
                "de": FrameScriptDocument.PublishingPack()
            ]
        )

        let items = ProductionChecklist.items(for: project)
        #expect(items.count == 8)
        #expect(items.allSatisfy { $0.languageCode == "de" })
    }

    // MARK: - Manual tasks

    @Test func manualTasksKeepKindSceneDoneAndText() {
        let scene = makeScene(title: "Escena manual", text: "")
        let pending = FrameScriptDocument.ChecklistTask(
            text: "Grabar intro",
            kind: .record,
            isDone: false,
            sceneID: scene.id
        )
        let done = FrameScriptDocument.ChecklistTask(
            text: "Revisar dato",
            kind: .research,
            isDone: true
        )
        let other = FrameScriptDocument.ChecklistTask(
            text: "Llamar al editor",
            kind: .other,
            sceneID: UUID()
        )

        let project = makeProject(
            scenes: [scene],
            checklistTasks: [pending, done, other]
        )
        let items = ProductionChecklist.items(for: project)

        #expect(items.count == 3)
        #expect(items[0].kind == .record)
        #expect(items[0].isDone == false)
        #expect(items[0].sceneID == scene.id)
        #expect(items[0].sourceText == "Grabar intro")
        #expect(items[0].target == .manualTask(taskID: pending.id))

        #expect(items[1].kind == .research)
        #expect(items[1].isDone)
        #expect(items[1].sceneID == nil)

        #expect(items[2].kind == .other)
        #expect(items[2].sceneID == nil)
        #expect(items[2].reason == .manualTask)
    }

    @Test func manualTaskKindMappingCoversEveryCase() {
        #expect(FrameScriptDocument.ChecklistTaskKind.record.productionKind == .record)
        #expect(FrameScriptDocument.ChecklistTaskKind.acquire.productionKind == .acquire)
        #expect(FrameScriptDocument.ChecklistTaskKind.edit.productionKind == .edit)
        #expect(FrameScriptDocument.ChecklistTaskKind.research.productionKind == .research)
        #expect(FrameScriptDocument.ChecklistTaskKind.other.productionKind == .other)
    }

    // MARK: - Summary and stability

    @Test func summaryCountsPendingPerKindAndDoneManual() {
        let scene = makeScene(
            text: "Hola.",
            bRoll: [FrameScriptDocument.BRollItem(descriptionText: "Plano")],
            editing: [FrameScriptDocument.EditingItem(cutStyle: "Corte")]
        )
        let claim = FrameScriptDocument.Claim(text: "Dato", status: .probable)
        let pack = FrameScriptDocument.PublishingPack()
        let manual = FrameScriptDocument.ChecklistTask(text: "Tarea", kind: .other)
        let doneManual = FrameScriptDocument.ChecklistTask(
            text: "Hecha",
            kind: .research,
            isDone: true
        )

        let project = makeProject(
            scenes: [scene],
            publishingPacks: ["es": pack],
            checklistTasks: [manual, doneManual],
            claims: [claim]
        )
        let summary = ProductionChecklist.summary(for: project)

        #expect(summary.pendingCount(for: .record) == 1)
        #expect(summary.pendingCount(for: .acquire) == 1)
        #expect(summary.pendingCount(for: .edit) == 1)
        #expect(summary.pendingCount(for: .research) == 1)
        #expect(summary.pendingCount(for: .publish) == 8)
        #expect(summary.pendingCount(for: .other) == 1)
        #expect(summary.totalPending == 13)
        #expect(summary.doneManualCount == 1)
        #expect(summary.totalCount == 14)
    }

    @Test func itemsAndIDsAreStableAcrossCalls() {
        let scene = makeScene(
            text: "Hola.",
            bRoll: [FrameScriptDocument.BRollItem(descriptionText: "Plano")],
            editing: [FrameScriptDocument.EditingItem(cutStyle: "Corte")]
        )
        let project = makeProject(
            scenes: [scene],
            publishingPacks: ["es": FrameScriptDocument.PublishingPack()],
            checklistTasks: [FrameScriptDocument.ChecklistTask(text: "Tarea")]
        )

        let first = ProductionChecklist.items(for: project)
        let second = ProductionChecklist.items(for: project)

        #expect(first == second)
        #expect(Set(first.map(\.id)).count == first.count)
    }

    @Test func scenesAreVisitedInDocumentOrder() {
        let second = makeScene(order: 1, title: "Segunda", text: "Dos.")
        let first = makeScene(order: 0, title: "Primera", text: "Uno.")
        let third = makeScene(order: 2, title: "Tercera", text: "Tres.")

        let items = ProductionChecklist.items(for: makeProject(scenes: [third, first, second]))
        #expect(items.map(\.sceneTitle) == ["Primera", "Segunda", "Tercera"])
    }

    // MARK: - Corrupt / duplicate identities

    @Test func duplicateSceneIDsAreIgnoredWithoutCrashing() {
        let id = UUID()
        let first = makeScene(id: id, order: 0, title: "Primera", text: "Uno.")
        let second = makeScene(id: id, order: 1, title: "Segunda", text: "Dos.")

        let items = ProductionChecklist.items(for: makeProject(scenes: [second, first]))
        #expect(items.count == 1)
        #expect(items[0].sceneTitle == "Primera")
    }

    @Test func duplicateClaimAndTaskIDsAreIgnored() {
        let claimID = UUID()
        let taskID = UUID()
        let project = makeProject(
            checklistTasks: [
                FrameScriptDocument.ChecklistTask(id: taskID, text: "Primera"),
                FrameScriptDocument.ChecklistTask(id: taskID, text: "Segunda")
            ],
            claims: [
                FrameScriptDocument.Claim(id: claimID, text: "Primera", status: .probable),
                FrameScriptDocument.Claim(id: claimID, text: "Segunda", status: .rumor)
            ]
        )

        let items = ProductionChecklist.items(for: project)
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.map(\.sourceText) == ["Primera", "Primera"])
    }

    @Test func duplicateBRollAndEditingIDsAreIgnored() {
        let bRollID = UUID()
        let editingID = UUID()
        let scene = makeScene(
            text: "",
            bRoll: [
                FrameScriptDocument.BRollItem(id: bRollID, descriptionText: "Primero"),
                FrameScriptDocument.BRollItem(id: bRollID, descriptionText: "Segundo")
            ],
            editing: [
                FrameScriptDocument.EditingItem(id: editingID, cutStyle: "Primero"),
                FrameScriptDocument.EditingItem(id: editingID, cutStyle: "Segundo")
            ]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [scene]))
        #expect(items.count == 2)
        #expect(items.map(\.sourceText) == ["Primero", "Primero"])
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func duplicateItemIDsAcrossScenesAreFiltered() {
        let bRollID = UUID()
        let first = makeScene(
            order: 0,
            title: "Primera",
            text: "",
            bRoll: [FrameScriptDocument.BRollItem(id: bRollID, descriptionText: "Primera")]
        )
        let second = makeScene(
            order: 1,
            title: "Segunda",
            text: "",
            bRoll: [FrameScriptDocument.BRollItem(id: bRollID, descriptionText: "Segunda")]
        )

        let items = ProductionChecklist.items(for: makeProject(scenes: [first, second]))
        #expect(items.count == 1)
        #expect(items[0].sourceText == "Primera")
    }

    // MARK: - Helpers

    private func makeProject(
        scenes: [FrameScriptDocument.Scene] = [],
        primaryLanguage: String = "es",
        assets: [FrameScriptDocument.ProjectAsset] = [],
        publishingPacks: [String: FrameScriptDocument.PublishingPack] = [:],
        checklistTasks: [FrameScriptDocument.ChecklistTask] = [],
        claims: [FrameScriptDocument.Claim] = []
    ) -> FrameScriptDocument.Project {
        FrameScriptDocument.Project(
            title: "Fixture",
            scenes: scenes,
            primaryLanguage: primaryLanguage,
            assets: assets,
            publishingPacks: publishingPacks,
            checklistTasks: checklistTasks,
            claims: claims
        )
    }

    private func makeScene(
        id: UUID = UUID(),
        order: Int = 0,
        title: String = "Escena",
        text: String = "Texto de la escena.",
        bRoll: [FrameScriptDocument.BRollItem] = [],
        editing: [FrameScriptDocument.EditingItem] = [],
        takes: [FrameScriptDocument.Take] = [],
        variants: [FrameScriptDocument.SceneLanguageVariant] = []
    ) -> FrameScriptDocument.Scene {
        FrameScriptDocument.Scene(
            id: id,
            order: order,
            sectionType: .hook,
            title: title,
            scriptText: text,
            bRollItems: bRoll,
            editingItems: editing,
            takes: takes,
            languageVariants: variants
        )
    }

    private func makeTake(
        rating: FrameScriptDocument.TakeRating,
        languageCode: String = "",
        text: String,
        number: Int = 1
    ) -> FrameScriptDocument.Take {
        FrameScriptDocument.Take(
            number: number,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12,
            rating: rating,
            languageCode: languageCode,
            sceneTextHash: FrameScriptDocument.TextHash.hash(text)
        )
    }
}

@Suite("ProductionGrouping")
struct ProductionGroupingTests {
    @Test func filterByKind() {
        let items = [
            makeItem(id: "record", kind: .record),
            makeItem(id: "edit", kind: .edit),
            makeItem(id: "other", kind: .other)
        ]
        let filter = ProductionFilter(kinds: [.record, .edit])

        #expect(filter.apply(to: items).map(\.id) == ["record", "edit"])
    }

    @Test func filterBySceneExcludesProjectLevelItems() {
        let sceneID = UUID()
        let items = [
            makeItem(id: "scene", kind: .record, sceneID: sceneID),
            makeItem(id: "project", kind: .publish)
        ]
        let filter = ProductionFilter(sceneID: sceneID)

        #expect(filter.apply(to: items).map(\.id) == ["scene"])
    }

    @Test func filterCanHideDoneManualItems() {
        let items = [
            makeItem(id: "pending", kind: .other),
            makeItem(id: "done", kind: .other, isDone: true)
        ]

        #expect(ProductionFilter(showsDone: true).apply(to: items).count == 2)
        #expect(ProductionFilter(showsDone: false).apply(to: items).map(\.id) == ["pending"])
    }

    @Test func groupByKindOrdersKindsAndSkipsEmptyOnes() {
        let items = [
            makeItem(id: "other", kind: .other, sourceIndex: 0),
            makeItem(id: "record", kind: .record, sourceIndex: 0),
            makeItem(id: "edit", kind: .edit, sourceIndex: 0)
        ]

        let sections = ProductionGrouper.sections(from: items, grouping: .kind)
        #expect(sections.map(\.kind) == [.record, .edit, .other])
        #expect(sections.map { $0.items.map(\.id) } == [["record"], ["edit"], ["other"]])
        #expect(sections.allSatisfy { $0.sceneID == nil })
    }

    @Test func groupBySceneOrdersScenesAndPutsProjectLast() {
        let firstID = UUID()
        let secondID = UUID()
        let items = [
            makeItem(id: "project", kind: .publish),
            makeItem(id: "second", kind: .record, sceneID: secondID, sceneOrder: 1, sceneTitle: "Dos"),
            makeItem(id: "first", kind: .record, sceneID: firstID, sceneOrder: 0, sceneTitle: "Uno")
        ]

        let sections = ProductionGrouper.sections(from: items, grouping: .scene)
        #expect(sections.map(\.id) == [
            "scene:\(firstID.uuidString)",
            "scene:\(secondID.uuidString)",
            "scene:project"
        ])
        #expect(sections.map(\.sceneTitle) == ["Uno", "Dos", ""])
        #expect(sections.last?.items.map(\.id) == ["project"])
    }

    @Test func groupByScenePutsDerivedItemsBeforeManualTasks() {
        let sceneID = UUID()
        let items = [
            makeItem(id: "manual", kind: .record, sceneID: sceneID, sceneOrder: 0, sourceIndex: 0),
            ProductionItem(
                id: "derived",
                kind: .record,
                reason: .sceneNeedsTake,
                sceneID: sceneID,
                sceneOrder: 0,
                target: .takes(sceneID: sceneID, languageCode: "")
            )
        ]

        let sections = ProductionGrouper.sections(from: items, grouping: .scene)
        #expect(sections.first?.items.map(\.id) == ["derived", "manual"])
    }

    @Test func groupBySceneSortsPendingBeforeDone() {
        let sceneID = UUID()
        let items = [
            makeItem(id: "done", kind: .record, sceneID: sceneID, sceneOrder: 0, isDone: true),
            makeItem(id: "pending", kind: .record, sceneID: sceneID, sceneOrder: 0)
        ]

        let sections = ProductionGrouper.sections(from: items, grouping: .scene)
        #expect(sections.first?.items.map(\.id) == ["pending", "done"])
    }

    @Test func emptyItemsProduceNoSections() {
        #expect(ProductionGrouper.sections(from: [], grouping: .kind).isEmpty)
        #expect(ProductionGrouper.sections(from: [], grouping: .scene).isEmpty)
    }

    private func makeItem(
        id: String,
        kind: ProductionItemKind,
        sceneID: UUID? = nil,
        sceneOrder: Int? = nil,
        sceneTitle: String = "",
        isDone: Bool = false,
        sourceIndex: Int? = nil
    ) -> ProductionItem {
        ProductionItem(
            id: id,
            kind: kind,
            reason: .manualTask,
            isDone: isDone,
            sceneID: sceneID,
            sceneOrder: sceneOrder,
            sceneTitle: sceneTitle,
            sourceIndex: sourceIndex,
            target: .manualTask(taskID: UUID())
        )
    }
}
