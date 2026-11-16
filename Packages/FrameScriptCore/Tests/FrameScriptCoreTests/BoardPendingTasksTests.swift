import Foundation
@testable import FrameScriptCore
import Testing

@Suite("Board pending tasks")
struct BoardPendingTasksTests {
    private func document(
        status: FrameScriptDocument.ProductionStatus,
        scenes: [FrameScriptDocument.Scene],
        checklist: [FrameScriptDocument.ChecklistTask] = []
    ) -> FrameScriptDocument {
        boardDocument(
            status: status,
            primaryLanguage: "es",
            checklistTasks: checklist,
            scenes: scenes
        )
    }

    @Test func scriptStageAsksToRecordScenesWithTextButNotEmptyScenes() {
        let document = document(
            status: .script,
            scenes: [
                boardScene(order: 0, title: "Con texto", text: "Una linea escrita."),
                boardScene(order: 1, title: "Vacía", text: "")
            ]
        )

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(for: document.project, labels: .english)

        #expect(tasks.count == 1)
        #expect(tasks[0].kind == .grabar)
        #expect(tasks[0].title == "Record · Con texto")
        #expect(tasks[0].sceneTitle == "Con texto")
    }

    @Test func goodTakeRemovesTheRecordingTaskEvenAfterTheScriptStage() {
        let text = "Texto del guion."
        let hash = FrameScriptDocument.TextHash.hash(text)
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: text,
            takes: [boardTake(duration: 40, rating: .good, sceneTextHash: hash)]
        )
        let provider = ProductionBoardPendingTaskProvider()

        #expect(provider.pendingTasks(for: document(status: .script, scenes: [scene]).project).isEmpty)
        #expect(provider.pendingTasks(for: document(status: .recorded, scenes: [scene]).project).isEmpty)
    }

    @Test func recordedStageStillAsksForAMissingTake() {
        // Production, the board and Plane share one rule: the status alone does
        // not prove that a usable take exists (G-2).
        let unrecorded = boardScene(order: 0, title: "Sin grabar", text: "Texto.")
        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document(status: .recorded, scenes: [unrecorded]).project
        )
        #expect(tasks.map(\.kind) == [.grabar])
    }

    @Test func staleTakeDoesNotCountAsRecorded() {
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: "Texto nuevo.",
            takes: [boardTake(duration: 40, rating: .good, sceneTextHash: "hash-viejo")]
        )

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document(status: .script, scenes: [scene]).project
        )
        #expect(tasks.map(\.kind) == [.grabar])
    }

    @Test func brollAndEditingItemsCreateTasksUntilTheyAreDone() {
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: "Texto.",
            bRollItems: [
                FrameScriptDocument.BRollItem(descriptionText: "Plano de podio", status: .idea),
                FrameScriptDocument.BRollItem(descriptionText: "Plano ya listo", status: .done)
            ],
            editingItems: [
                FrameScriptDocument.EditingItem(cutStyle: "Zoom", status: .pending),
                FrameScriptDocument.EditingItem(cutStyle: "Listo", status: .done)
            ]
        )

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document(status: .recorded, scenes: [scene]).project
        )

        #expect(tasks.map(\.kind) == [.grabar, .conseguirBroll, .conseguirBroll, .editar])
        #expect(tasks[1].title.contains("Plano de podio"))
        #expect(tasks[2].title.contains("Plano ya listo"))
        #expect(tasks[3].title.contains("Zoom"))
    }

    @Test func checklistTasksMapToPlaneKindsAndUseTheirOwnText() {
        let scene = boardScene(order: 0, title: "Escena", text: "Texto.")
        let checklist = [
            FrameScriptDocument.ChecklistTask(text: "Grabar el intro", kind: .record, sceneID: scene.id),
            FrameScriptDocument.ChecklistTask(text: "Conseguir el coche", kind: .acquire),
            FrameScriptDocument.ChecklistTask(text: "Montar el vídeo", kind: .edit),
            FrameScriptDocument.ChecklistTask(text: "Verificar datos", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "Publicar", kind: .other),
            FrameScriptDocument.ChecklistTask(text: "Hecho", kind: .other, isDone: true)
        ]

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document(status: .edited, scenes: [scene], checklist: checklist).project
        )

        #expect(tasks.map(\.kind) == [.grabar, .grabar, .conseguirBroll, .editar, .investigar, .manual])
        #expect(tasks.first?.sceneTitle == "Escena")
        #expect(tasks.last?.title == "Publicar")
    }

    @Test func publishedProjectsHaveNoPendingTasks() {
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: "Texto.",
            bRollItems: [FrameScriptDocument.BRollItem(descriptionText: "Pendiente", status: .idea)]
        )
        let document = document(
            status: .published,
            scenes: [scene],
            checklist: [FrameScriptDocument.ChecklistTask(text: "Pendiente", kind: .other)]
        )

        #expect(ProductionBoardPendingTaskProvider().pendingTasks(for: document.project).isEmpty)
    }

    @Test func customLabelsAreUsedInGeneratedTitles() {
        let labels = BoardPendingLabels(
            record: "Grabar",
            bRoll: "Conseguir B-roll",
            edit: "Montar",
            research: "Investigar",
            manual: "Tarea",
            separator: " · "
        )
        let scene = boardScene(order: 0, title: "Intro", text: "Texto.")

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document(status: .script, scenes: [scene]).project,
            labels: labels
        )

        #expect(tasks.first?.title == "Grabar · Intro")
    }

    @Test func countsGroupTasksByKindAndPlaneTaskConversionKeepsTheStableIDs() {
        let tasks = [
            boardPendingTask(id: "a", kind: .grabar),
            boardPendingTask(id: "b", kind: .editar),
            boardPendingTask(id: "c", kind: .editar)
        ]
        let counts = BoardPendingCounts(tasks: tasks)

        #expect(counts.total == 3)
        #expect(counts.count(for: .editar) == 2)
        #expect(counts.activeKinds == [.grabar, .editar])

        let plane = tasks[1].planeTask(
            projectID: "project-id",
            projectTitle: "Project",
            dueDate: PlaneDate(year: 2027, month: 1, day: 15)
        )
        #expect(plane.id == "b")
        #expect(plane.projectID == "project-id")
        #expect(plane.kind == .editar)
        #expect(plane.dueDate?.iso8601 == "2027-01-15")
    }

    @Test func boardPendingCountsExactlyMatchTheProductionChecklist() {
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: "Texto sin grabar.",
            bRollItems: [
                FrameScriptDocument.BRollItem(descriptionText: "Sin material", status: .idea),
                FrameScriptDocument.BRollItem(descriptionText: "Hecho sin archivo", status: .done)
            ],
            editingItems: [FrameScriptDocument.EditingItem(cutStyle: "Montar")]
        )
        let claims = [
            FrameScriptDocument.Claim(text: "Dato uno", status: .probable, needsVerification: true),
            FrameScriptDocument.Claim(text: "Dato dos", status: .probable, needsVerification: true)
        ]
        let checklist = [
            FrameScriptDocument.ChecklistTask(text: "Dato uno", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "Dato dos", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "Hecho", kind: .other, isDone: true),
            FrameScriptDocument.ChecklistTask(
                text: PublishingChecklistItem.endScreen.taskToken,
                kind: .other
            )
        ]
        let document = boardDocument(
            status: .recorded,
            publishingPacks: ["es": FrameScriptDocument.PublishingPack(description: "Descripción")],
            checklistTasks: checklist,
            claims: claims,
            scenes: [scene]
        )

        let tasks = ProductionBoardPendingTaskProvider().pendingTasks(
            for: document.project,
            labels: BoardPendingLabels(
                record: "Grabar",
                bRoll: "Conseguir B-roll",
                edit: "Montar",
                research: "Investigar",
                manual: "Tarea",
                publish: "Publicar",
                publishingChecklistTitles: [
                    PublishingChecklistItem.endScreen.rawValue: "Pantalla final"
                ]
            )
        )
        let production = ProductionChecklist.summary(for: document.project)

        #expect(tasks.count == production.totalPending)
        #expect(tasks.filter { $0.kind == PlaneTaskKind.grabar }.count == production.pendingCount(for: .record))
        #expect(tasks.filter { $0.kind == PlaneTaskKind.conseguirBroll }.count == production.pendingCount(for: .acquire))
        #expect(tasks.filter { $0.kind == PlaneTaskKind.editar }.count == production.pendingCount(for: .edit))
        #expect(tasks.filter { $0.kind == PlaneTaskKind.investigar }.count == production.pendingCount(for: .research))
        #expect(tasks.filter { $0.kind == PlaneTaskKind.publicar }.count == production.pendingCount(for: .publish))
        #expect(tasks.filter { $0.kind == PlaneTaskKind.manual }.count == production.pendingCount(for: .other))
        // Recorded status with no usable take still asks for the recording.
        #expect(tasks.filter { $0.kind == PlaneTaskKind.grabar }.count == 1)
        // A done B-roll item without a linked asset still asks for the file.
        #expect(tasks.filter { $0.kind == PlaneTaskKind.conseguirBroll }.count == 2)
        // The duplicated claim task is not counted twice.
        #expect(tasks.filter { $0.kind == PlaneTaskKind.investigar }.count == 2)
        // The publishing token becomes a human label, not a raw token.
        #expect(tasks.contains { $0.kind == PlaneTaskKind.publicar && $0.title == "Publicar · Pantalla final" })
        #expect(!tasks.contains { $0.title.hasPrefix("publishing.checklist.") })
    }

    @Test func summaryBuilderFallsBackToMarkupEstimateWhenTheStoredEstimateIsMissing() {
        // 150 spoken words at 150 wpm equals 60 seconds.
        let text = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let scene = boardScene(order: 0, title: "Larga", text: text, estimatedDuration: 0)
        let document = document(status: .script, scenes: [scene])
        let summary = BoardProjectSummaryBuilder.makeSummary(
            document: document,
            fileURL: URL(fileURLWithPath: "/tmp/estimate.fscr"),
            fingerprint: BoardFileFingerprint(contentHash: "hash", fileSize: 1, modificationDate: nil)
        )

        #expect(abs(summary.duration.seconds - 60) < 0.5)
        #expect(summary.duration.kind == .estimated)
    }

    @Test func summaryBuilderUsesLearnedPaceForMixedRealAndEstimatedScenes() {
        let textA = "texto"
        let sceneA = boardScene(
            order: 0,
            title: "Real",
            text: textA,
            estimatedDuration: 30,
            takes: [boardTake(duration: 20, rating: .good, sceneTextHash: FrameScriptDocument.TextHash.hash(textA))]
        )
        let sceneB = boardScene(order: 1, title: "Estimada", text: textA, estimatedDuration: 40)
        let document = boardDocument(
            status: .script,
            primaryLanguage: "es",
            scenes: [sceneA, sceneB]
        )
        let summary = BoardProjectSummaryBuilder.makeSummary(
            document: document,
            fileURL: URL(fileURLWithPath: "/tmp/mixed.fscr"),
            fingerprint: BoardFileFingerprint(contentHash: "hash", fileSize: 1, modificationDate: nil)
        )

        #expect(summary.duration.kind == .mixed)
        #expect(summary.duration.realSceneCount == 1)
        #expect(summary.duration.seconds == 60)
        #expect(summary.duration.estimatedSeconds == 70)
    }
}
