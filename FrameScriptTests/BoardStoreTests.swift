import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class BoardStoreTests: XCTestCase {
    private var harness: BoardTestHarness!

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try BoardTestHarness()
        let harness = harness!
        addTeardownBlock { harness.tearDown() }
    }

    // MARK: Library folders

    func testFoldersPersistWithBookmarksAndDeduplicateByPath() throws {
        XCTAssertTrue(try harness.board.addFolder(at: harness.libraryRoot))
        XCTAssertFalse(try harness.board.addFolder(at: harness.libraryRoot))

        let second = BoardStore(
            userDefaults: harness.defaults,
            foldersStorageKey: "test.board.folders",
            bookmarkCreator: { url in Data(url.path.utf8) },
            bookmarkResolver: { data, _ in URL(fileURLWithPath: String(decoding: data, as: UTF8.self)) },
            securityScope: BoardTestHarness.noSecurityScope
        )
        second.loadFolders()

        XCTAssertEqual(second.folders.count, 1)
        XCTAssertEqual(second.resolvedFolders().first?.url?.standardizedFileURL.path, harness.libraryRoot.standardizedFileURL.path)

        second.removeFolder(id: second.folders[0].id)
        XCTAssertTrue(second.folders.isEmpty)
    }

    func testAddingAMissingFolderThrows() {
        let missing = harness.tempRoot.appendingPathComponent("no-existe", isDirectory: true)
        XCTAssertThrowsError(try harness.board.addFolder(at: missing)) { error in
            XCTAssertEqual(error as? BoardFolderError, .missingFolder)
        }
    }

    // MARK: Scanning

    func testScanBuildsReadableSummariesAndPendingCounts() async throws {
        try harness.writeSampleLibrary()
        await harness.refresh()

        XCTAssertEqual(harness.board.summaries.count, 7)
        XCTAssertTrue(harness.board.warnings.isEmpty)
        XCTAssertEqual(harness.board.lastScanStats.decodedCount, 7)
        XCTAssertEqual(harness.board.lastScanStats.reusedCount, 0)

        let analysis = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )
        XCTAssertEqual(analysis.topic, "Assetto Corsa Competizione")
        XCTAssertEqual(analysis.videoType, "análisis")
        XCTAssertEqual(analysis.productionStatus, .script)
        XCTAssertEqual(analysis.duration.kind, .mixed)
        XCTAssertEqual(analysis.pending.count(for: .grabar), 1)
        XCTAssertEqual(analysis.pending.count(for: .conseguirBroll), 2)
        XCTAssertEqual(analysis.pending.count(for: .editar), 1)
        XCTAssertEqual(analysis.pending.count(for: .investigar), 1)

        let published = try XCTUnwrap(harness.board.summaries.first { $0.productionStatus == .published })
        XCTAssertTrue(published.pending.isEmpty)
        XCTAssertNotNil(published.publishDate)

        let unclassified = try XCTUnwrap(harness.board.summaries.first { $0.title == "Proyecto sin clasificar" })
        XCTAssertTrue(unclassified.isUnclassifiedTopic)
        XCTAssertTrue(unclassified.isUnclassifiedType)
    }

    func testSecondScanIsIncrementalAndCorruptFilesBecomeWarnings() async throws {
        try harness.writeSampleLibrary()
        await harness.refresh()

        let corruptURL = harness.libraryRoot.appendingPathComponent("roto.fscr")
        try Data("{ esto no es un proyecto".utf8).write(to: corruptURL)

        await harness.refresh()
        XCTAssertEqual(harness.board.lastScanStats.reusedCount, 7)
        XCTAssertEqual(harness.board.lastScanStats.decodedCount, 0)
        XCTAssertTrue(harness.board.warnings.contains { $0.kind == .corruptDocument && $0.url.lastPathComponent == "roto.fscr" })
        XCTAssertEqual(harness.board.summaries.count, 7)
    }

    // MARK: Writes

    func testClosedFileWriteAppliesClassificationAtomically() async throws {
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Clasificar",
                topic: "iRacing",
                videoType: "análisis",
                status: .idea,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "clasificar.fscr"
        )
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))

        let target = Date(timeIntervalSince1970: 1_800_500_000)
        let publish = Date(timeIntervalSince1970: 1_800_900_000)
        let outcome = await harness.board.apply(
            BoardProjectEdit(
                topic: "Assetto Corsa EVO",
                videoType: "comparativa",
                productionStatus: .edited,
                targetDate: target,
                publishDate: publish
            ),
            to: summary,
            appState: harness.appState
        )

        guard case .saved(let refreshed) = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(refreshed.topic, "Assetto Corsa EVO")
        XCTAssertEqual(refreshed.videoType, "comparativa")
        XCTAssertEqual(refreshed.productionStatus, FrameScriptDocument.ProductionStatus.edited)
        XCTAssertEqual(refreshed.targetDate, target)
        XCTAssertEqual(refreshed.publishDate, publish)

        let document = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertEqual(document.project.topic, "Assetto Corsa EVO")
        XCTAssertEqual(document.project.videoType, "comparativa")
        XCTAssertEqual(document.project.productionStatus, FrameScriptDocument.ProductionStatus.edited)
        XCTAssertEqual(document.project.targetDate, target)
        XCTAssertEqual(document.project.publishDate, publish)
        XCTAssertEqual(harness.board.index.summary(forFileAt: url), refreshed)
    }

    func testClosedFileWriteRefusesToOverwriteAnExternalChange() async throws {
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Original",
                topic: "iRacing",
                videoType: "análisis",
                status: .idea,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "conflicto.fscr"
        )
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))

        try FrameScriptDocumentCodec.write(
            BoardTestHarness.makeDocument(
                title: "Cambiado fuera",
                topic: "Vantare",
                videoType: "crónica",
                status: .published,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_810_000_000)
            ),
            to: url
        )

        let outcome = await harness.board.apply(
            BoardProjectEdit(topic: "No debe escribirse"),
            to: summary,
            appState: harness.appState
        )

        guard case .conflict(let refreshed) = outcome else {
            return XCTFail("Expected a conflict outcome, got \(outcome)")
        }
        XCTAssertEqual(refreshed?.title, "Cambiado fuera")
        let disk = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertEqual(disk.project.title, "Cambiado fuera")
        XCTAssertEqual(disk.project.topic, "Vantare")
        XCTAssertEqual(disk.project.productionStatus, .published)
    }

    func testOpenProjectWriteUsesTheAppSavePathAndKeepsTheDocumentInSync() async throws {
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Abierto",
                topic: "iRacing",
                videoType: "gameplay",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "abierto.fscr"
        )
        harness.appState.openProject(at: url)
        XCTAssertEqual(
            harness.appState.projectStore.currentFileURL?.standardizedFileURL,
            url.standardizedFileURL
        )

        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))
        let outcome = await harness.board.apply(
            BoardProjectEdit(topic: "Vantare", productionStatus: .recorded),
            to: summary,
            appState: harness.appState
        )

        guard case .saved = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(harness.appState.project.topic, "Vantare")
        XCTAssertEqual(harness.appState.project.productionStatus, .recorded)
        XCTAssertFalse(harness.appState.projectStore.hasUnsavedFileChanges)

        let disk = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertEqual(disk.project.topic, "Vantare")
        XCTAssertEqual(disk.project.productionStatus, .recorded)
    }

    func testOpenProjectReloadPromptIsNotReportedAsASavedBoardEdit() async throws {
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Original",
                topic: "iRacing",
                videoType: "análisis",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "recarga.fscr"
        )
        harness.appState.openProject(at: url)
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))

        try FrameScriptDocumentCodec.write(
            BoardTestHarness.makeDocument(
                title: "Versión externa",
                topic: "Vantare",
                videoType: "crónica",
                status: .published,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
            ),
            to: url
        )
        harness.externalChange.resolution = .reload

        let outcome = await harness.board.apply(
            BoardProjectEdit(topic: "No debe quedar"),
            to: summary,
            appState: harness.appState
        )

        guard case .conflict(let refreshed) = outcome else {
            return XCTFail("A reload prompt must not look like a successful save: \(outcome)")
        }
        XCTAssertEqual(refreshed?.title, "Versión externa")
        XCTAssertEqual(harness.appState.project.topic, "Vantare")
        let disk = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertEqual(disk.project.topic, "Vantare")
        XCTAssertEqual(disk.project.title, "Versión externa")
    }

    func testOpeningAProjectFromTheBoardUsesTheNormalOpenPath() async throws {
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Abrir desde el tablero",
                topic: "Vantare",
                videoType: "noticia",
                status: .idea,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "abrir.fscr"
        )
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))

        XCTAssertTrue(harness.appState.openBoardProject(summary, activatesApplication: false))
        XCTAssertEqual(
            harness.appState.projectStore.currentFileURL?.standardizedFileURL,
            url.standardizedFileURL
        )
        XCTAssertEqual(harness.appState.project.title, "Abrir desde el tablero")
    }

    func testEscaletaNotesInTopicSurviveBoardClassification() async throws {
        let notes = EscaletaProjectNotes(promise: "Promesa sintética de la escaleta")
        let rawTopic = notes.encoded()
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Importado",
                topic: rawTopic,
                videoType: "análisis",
                status: .idea,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "importado.fscr"
        )

        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))
        XCTAssertTrue(summary.topic.isEmpty, "The notes block must not be shown as a game")

        let outcome = await harness.board.apply(
            BoardProjectEdit(topic: "Vantare", videoType: "crónica"),
            to: summary,
            appState: harness.appState
        )
        guard case .saved(let refreshed) = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(refreshed.topic, "Vantare")

        let document = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertTrue(document.project.topic.contains(EscaletaProjectNotes.promiseLabel))
        XCTAssertTrue(document.project.topic.contains(BoardProjectTopic.marker))
        XCTAssertEqual(BoardProjectTopic.display(from: document.project.topic), "Vantare")
        XCTAssertEqual(
            EscaletaProjectNotes.decode(document.project.topic).promise,
            "Promesa sintética de la escaleta"
        )

        let cleared = await harness.board.apply(
            BoardProjectEdit(topic: ""),
            to: refreshed,
            appState: harness.appState
        )
        guard case .saved(let clearedSummary) = cleared else {
            return XCTFail("Expected a saved outcome, got \(cleared)")
        }
        XCTAssertTrue(clearedSummary.topic.isEmpty)
        let clearedDocument = try FrameScriptDocumentCodec.read(from: url)
        XCTAssertFalse(clearedDocument.project.topic.contains(BoardProjectTopic.marker))
        XCTAssertTrue(clearedDocument.project.topic.contains(EscaletaProjectNotes.promiseLabel))
    }

    func testProjectInfoTopicEditPreservesEscaletaNotes() {
        harness.appState.project.topic = EscaletaProjectNotes(promise: "Promesa").encoded()
        harness.appState.setProjectTopic("Vantare")

        XCTAssertEqual(BoardProjectTopic.display(from: harness.appState.project.topic), "Vantare")
        XCTAssertEqual(
            EscaletaProjectNotes.decode(harness.appState.project.topic).promise,
            "Promesa"
        )
        XCTAssertTrue(harness.appState.projectStore.hasUnsavedFileChanges)
    }

    func testBoardProjectTopicKeepsPlainProjectsPlain() {
        XCTAssertEqual(BoardProjectTopic.display(from: "iRacing"), "iRacing")
        XCTAssertEqual(BoardProjectTopic.merging("Vantare", into: "iRacing"), "Vantare")
        XCTAssertEqual(BoardProjectTopic.merging("", into: "iRacing"), "")
        XCTAssertEqual(BoardProjectTopic.display(from: ""), "")

        let notes = EscaletaProjectNotes(promise: "Promesa").encoded()
        XCTAssertEqual(BoardProjectTopic.display(from: notes), "")
        let merged = BoardProjectTopic.merging("Vantare", into: notes)
        XCTAssertEqual(BoardProjectTopic.display(from: merged), "Vantare")
        XCTAssertEqual(BoardProjectTopic.strippingMarker(from: merged), notes)
        XCTAssertEqual(
            BoardProjectTopic.merging("iRacing", into: merged).components(separatedBy: BoardProjectTopic.marker).count,
            2,
            "Repeated edits must replace the marker instead of stacking it"
        )
    }

    // MARK: Plane

    func testPlanePlanIsLocalizedAndMapsTheTargetDate() async throws {
        try harness.writeSampleLibrary()
        await harness.refresh()
        let summary = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )

        let plan = harness.board.planePlan(for: summary, appState: harness.appState)
        XCTAssertEqual(plan.entries.count, summary.pending.total)
        XCTAssertTrue(plan.entries.contains { $0.task.title.contains("Grabar ·") })
        XCTAssertTrue(plan.entries.contains { $0.task.title.contains("Conseguir B-roll ·") })
        XCTAssertTrue(plan.entries.contains { $0.task.title == "Verificar los datos de la actualización" })

        let dueDate = try XCTUnwrap(BoardPlaneDate.make(from: summary.targetDate))
        XCTAssertTrue(plan.entries.allSatisfy { $0.task.dueDate == dueDate })
        XCTAssertTrue(plan.entries.allSatisfy { $0.draft.externalSource == PlaneExternalID.source })
    }

    func testPlaneLedgerRoundTripsPerProjectAndNeverTouchesOtherProjects() {
        let first = UUID()
        let second = UUID()
        var ledger = PlaneExportLedger()
        ledger.record(workItemID: "plane-1", forTaskExternalID: "framescript:a:b")

        harness.ledger.save(ledger, for: first)

        XCTAssertEqual(harness.ledger.ledger(for: first), ledger)
        XCTAssertEqual(harness.ledger.ledger(for: second), PlaneExportLedger())
    }

    func testPlaneSettingsValidateAndUseOnlyTheInjectedTokenStore() throws {
        XCTAssertFalse(harness.plane.settings.isConfigured)
        XCTAssertFalse(harness.plane.hasStoredToken)

        harness.plane.settings.baseURL = "https://plane.example.test"
        harness.plane.settings.workspaceSlug = "mi-workspace"
        harness.plane.settings.projectID = "project-id"
        XCTAssertTrue(harness.plane.settings.isConfigured)

        let configuration = try harness.plane.settings.configuration(apiKey: "token")
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://plane.example.test")
        XCTAssertEqual(configuration.workspaceSlug, "mi-workspace")
        XCTAssertEqual(configuration.projectID, "project-id")
        XCTAssertEqual(configuration.apiKey, "token")

        try harness.plane.saveToken("secreto")
        XCTAssertTrue(harness.plane.hasStoredToken)
        XCTAssertEqual(harness.keychain.token, "secreto")
        XCTAssertEqual(try harness.plane.tokenForExport(), "secreto")

        try harness.plane.deleteStoredToken()
        XCTAssertFalse(harness.plane.hasStoredToken)
        XCTAssertNil(harness.keychain.token)
    }

    func testPlaneSettingsRejectAnEmptyConfiguration() {
        harness.plane.settings.baseURL = "   "
        XCTAssertThrowsError(try harness.plane.settings.configuration(apiKey: "token"))
    }

    // MARK: Catalog and templates

    func testCatalogStorePersistsEditsInTheIsolatedSuite() {
        var updated = harness.catalog.catalog
        updated.addTopic("Circuito sintético")
        harness.catalog.catalog = updated

        let second = BoardCatalogStore(userDefaults: harness.defaults, storageKey: "test.board.catalog")
        XCTAssertTrue(second.catalog.topics.contains("Circuito sintético"))
    }

    func testTemplateDefaultClassificationIsAppliedOnNewProjects() {
        let template = SampleData.templates.first { $0.name == "Simracing Comparison" }
        XCTAssertNotNil(template)

        harness.appState.createNewProject(named: "Proyecto de prueba", template: template)
        XCTAssertEqual(harness.appState.project.videoType, "comparativa")
    }

    func testBoardSpanishStringsCoverStatusesAndPlaneAction() {
        XCTAssertEqual(L10n.tr("board.windowTitle", language: .spanish), "Tablero")
        XCTAssertEqual(L10n.tr("board.status.outline", language: .spanish), "Escaleta")
        XCTAssertEqual(L10n.tr("board.status.edited", language: .spanish), "Montado")
        XCTAssertEqual(L10n.tr("board.action.exportPlane", language: .spanish), "Exportar pendientes a Plane")
        XCTAssertEqual(L10n.tr("board.menu", language: .english), "Board")
    }
}
