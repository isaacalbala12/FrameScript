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

        let tasks = BoardPendingTaskDeriver().pendingTasks(for: document.project, labels: .english)

        #expect(tasks.count == 1)
        #expect(tasks[0].kind == .grabar)
        #expect(tasks[0].title == "Record · Con texto")
        #expect(tasks[0].sceneTitle == "Con texto")
    }

    @Test func goodTakeRemovesTheRecordingTaskAndRecordedStageNeverAsksToRecord() {
        let text = "Texto del guion."
        let hash = FrameScriptDocument.TextHash.hash(text)
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: text,
            takes: [boardTake(duration: 40, rating: .good, sceneTextHash: hash)]
        )
        let deriver = BoardPendingTaskDeriver()

        #expect(deriver.pendingTasks(for: document(status: .script, scenes: [scene]).project).isEmpty)

        let unrecorded = boardScene(order: 0, title: "Sin grabar", text: text)
        let recorded = deriver.pendingTasks(for: document(status: .recorded, scenes: [unrecorded]).project)
        #expect(recorded.isEmpty)
    }

    @Test func staleTakeDoesNotCountAsRecorded() {
        let scene = boardScene(
            order: 0,
            title: "Escena",
            text: "Texto nuevo.",
            takes: [boardTake(duration: 40, rating: .good, sceneTextHash: "hash-viejo")]
        )

        let tasks = BoardPendingTaskDeriver().pendingTasks(
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

        let tasks = BoardPendingTaskDeriver().pendingTasks(
            for: document(status: .recorded, scenes: [scene]).project
        )

        #expect(tasks.map(\.kind) == [.conseguirBroll, .editar])
        #expect(tasks[0].title.contains("Plano de podio"))
        #expect(tasks[1].title.contains("Zoom"))
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

        let tasks = BoardPendingTaskDeriver().pendingTasks(
            for: document(status: .edited, scenes: [scene], checklist: checklist).project
        )

        #expect(tasks.map(\.kind) == [.grabar, .conseguirBroll, .editar, .investigar, .manual])
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

        #expect(BoardPendingTaskDeriver().pendingTasks(for: document.project).isEmpty)
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

        let tasks = BoardPendingTaskDeriver().pendingTasks(
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
