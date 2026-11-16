import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Regression tests for the verified wave-3 E/G/I review findings. Every test
/// uses synthetic projects and isolated preferences; no test opens a window,
/// touches the real preference domain or reaches the network.
@MainActor
final class W3FixEGITests: FrameScriptTestCase {
    // MARK: - G-3 · Board stores use the isolated defaults

    func testW3FixEGIBoardStoresDefaultToTheTestDomain() {
        XCTAssertTrue(AppEnvironment.isRunningTests)

        let board = BoardStore()
        let catalog = BoardCatalogStore()
        let plane = PlaneSettingsStore()
        let ledger = BoardPlaneLedgerStore()

        XCTAssertTrue(board.userDefaults === AppEnvironment.testDefaults)
        XCTAssertTrue(catalog.userDefaults === AppEnvironment.testDefaults)
        XCTAssertTrue(plane.userDefaults === AppEnvironment.testDefaults)
        XCTAssertTrue(ledger.userDefaults === AppEnvironment.testDefaults)
        XCTAssertFalse(board.userDefaults === UserDefaults.standard)
        XCTAssertFalse(catalog.userDefaults === UserDefaults.standard)

        // The Settings → Tablero tab builds the `.shared` stores. Mutating the
        // catalog the way that tab does must land in the isolated suite.
        var changed = BoardCatalogStore.shared.catalog
        changed.addTopic("W3FixEGI")
        BoardCatalogStore.shared.catalog = changed
        XCTAssertNotNil(
            AppEnvironment.testDefaults.data(forKey: BoardCatalogStore.storageKey),
            "The Tablero tab wrote outside AppEnvironment.testDefaults"
        )
        BoardCatalogStore.shared.resetToSeeds()
    }

    func testW3FixEGIPlaneInsecureTransportOnlyWarnsForNonLocalHTTP() {
        var settings = PlaneSettings()

        settings.baseURL = "https://plane.example.test"
        XCTAssertFalse(settings.isInsecureTransport)

        settings.baseURL = "http://localhost:8080"
        XCTAssertFalse(settings.isInsecureTransport)

        settings.baseURL = "http://127.0.0.1:8080"
        XCTAssertFalse(settings.isInsecureTransport)

        settings.baseURL = "http://192.168.1.20:8080"
        XCTAssertTrue(settings.isInsecureTransport)

        settings.baseURL = " HTTP://plane.local "
        XCTAssertTrue(settings.isInsecureTransport)
    }

    // MARK: - I-1 · Duplicate source ids open instead of trapping

    func testW3FixEGIDuplicateSourceIDsDoNotTrapThePanelOrExport() {
        let sourceID = UUID()
        let project = FrameProject(
            title: "Proyecto con fuentes duplicadas",
            scenes: [makeScene(order: 0, title: "Escena", text: "Texto.")],
            primaryLanguage: "es",
            sources: [
                ProjectSource(id: sourceID, title: "Primera"),
                ProjectSource(id: sourceID, title: "Segunda")
            ],
            claims: [
                ProjectClaim(
                    text: "El dato",
                    status: .probable,
                    sourceIDs: [sourceID],
                    needsVerification: true
                )
            ]
        )
        let appState = makeAppState(project: project)

        let items = appState.researchPendingItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].sourceTitles, ["Primera"])

        let markdown = ExportService().render(
            project: appState.project,
            format: .markdown,
            preferences: AppSettings.defaults.exportPreferences,
            language: .spanish
        )
        XCTAssertTrue(markdown.contains("Primera"))
        XCTAssertTrue(markdown.contains("Segunda"))
    }

    // MARK: - I-2 · Deleting a claim removes its open research task

    func testW3FixEGIDeletingClaimRemovesItsOpenResearchTask() {
        let scene = makeScene(order: 0, title: "Escena", text: "Texto.")
        let appState = makeAppState(project: FrameProject(
            title: "Proyecto",
            scenes: [scene],
            primaryLanguage: "es"
        ))
        let claim = appState.addResearchClaim(
            text: "El parche sale en mayo",
            sceneIDs: [scene.id],
            needsVerification: true
        )
        XCTAssertTrue(appState.researchOpenTasks().contains { $0.text == claim.text })

        appState.deleteResearchClaim(id: claim.id)

        XCTAssertFalse(appState.researchOpenTasks().contains { $0.text == claim.text })
        XCTAssertTrue(appState.project.claims.isEmpty)
    }

    func testW3FixEGIDeletingClaimKeepsDoneResearchTaskHistory() {
        let appState = makeAppState(project: FrameProject(title: "Proyecto", primaryLanguage: "es"))
        let claim = appState.addResearchClaim(text: "Histórica", needsVerification: true)
        appState.confirmResearchClaim(id: claim.id, resolutionNote: "Resuelta")
        XCTAssertTrue(appState.project.checklistTasks.contains { $0.text == claim.text && $0.isDone })

        appState.deleteResearchClaim(id: claim.id)

        XCTAssertTrue(appState.project.checklistTasks.contains { $0.text == claim.text && $0.isDone })
    }

    // MARK: - I-3 · Duplicated projects remap comparison-table scenes

    func testW3FixEGIDuplicateProjectRemapsComparisonTableScene() throws {
        let originalScene = Scene(
            order: 0,
            sectionType: .custom,
            title: "Original",
            scriptText: "Texto."
        )
        let table = ComparisonTable(
            title: "Neumáticos",
            header: ["A"],
            rows: [["1"]],
            sceneID: originalScene.id
        )
        let project = FrameProject(
            title: "Proyecto",
            scenes: [originalScene],
            primaryLanguage: "es",
            comparisonTables: [table]
        )
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let copy = store.duplicateProject(copySuffix: "copia")
        let copiedSceneID = try XCTUnwrap(copy.scenes.first?.id)
        let copiedTableSceneID = try XCTUnwrap(copy.comparisonTables.first?.sceneID)

        XCTAssertNotEqual(copiedSceneID, originalScene.id)
        XCTAssertEqual(copiedTableSceneID, copiedSceneID)
        XCTAssertFalse(copy.scenes.map(\.id).contains(originalScene.id))
    }

    // MARK: - I-6 · Add to description uses the selected language

    func testW3FixEGIAddToDescriptionCreatesTheSelectedLanguagePackAndReportsIt() {
        let project = FrameProject(
            title: "Proyecto",
            scenes: [makeScene(order: 0, title: "Escena", text: "Texto.")],
            primaryLanguage: "es"
        )
        let appState = makeAppState(project: project)
        _ = appState.addResearchSource(title: "Timing oficial", url: "https://example.com/timing")
        _ = appState.addResearchClaim(text: "El récord es 1:42.3", needsVerification: true)

        let created: ResearchDescriptionAppendOutcome = appState.appendResearchToPublishingDescription(
            language: "en"
        )
        XCTAssertEqual(created, .createdPack)
        XCTAssertNotNil(appState.project.publishingPacks["en"])
        XCTAssertNil(appState.project.publishingPacks["es"])
        XCTAssertTrue(
            appState.project.publishingPacks["en"]?.description.contains("Timing oficial") == true
        )
        let again: ResearchDescriptionAppendOutcome = appState.appendResearchToPublishingDescription(
            language: "en"
        )
        XCTAssertEqual(again, .alreadyPresent)
    }

    // MARK: - I-7 · Deleting a scene drops every dangling reference

    func testW3FixEGIDeletingASceneDropsClaimTableTaskAssetAndClipLinks() throws {
        let first = FrameScript.Scene(order: 0, sectionType: .hook, title: "Primera", scriptText: "Uno.")
        let second = FrameScript.Scene(order: 1, sectionType: .custom, title: "Segunda", scriptText: "Dos.")
        let claim = ProjectClaim(
            text: "Dato",
            status: .probable,
            sceneIDs: [second.id],
            anchorSceneID: second.id,
            anchor: TextAnchor(startUTF16: 0, lengthUTF16: 2, selectedText: "Do"),
            needsVerification: true
        )
        let table = ComparisonTable(title: "Tabla", header: ["A"], rows: [["1"]], sceneID: second.id)
        let task = ChecklistTask(text: "Grabar", kind: .record, sceneID: second.id)
        let asset = ProjectAsset(path: "/tmp/asset.mov", linkedSceneIDs: [second.id])
        let clip = ShortClip(
            title: "Clip",
            sourceSceneIDs: [second.id],
            anchorSceneID: second.id,
            anchor: TextAnchor(startUTF16: 0, lengthUTF16: 2, selectedText: "Do")
        )
        let project = FrameProject(
            title: "Proyecto",
            scenes: [first, second],
            primaryLanguage: "es",
            assets: [asset],
            checklistTasks: [task],
            claims: [claim],
            comparisonTables: [table],
            clips: [clip]
        )
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        store.deleteScene(at: 1, wordsPerMinute: 150)

        let deletedID = second.id
        XCTAssertFalse(store.project.scenes.contains { $0.id == deletedID })
        XCTAssertFalse(store.project.claims.contains { $0.sceneIDs.contains(deletedID) })
        XCTAssertNil(store.project.claims.first?.anchorSceneID)
        XCTAssertNil(store.project.claims.first?.anchor)
        XCTAssertNil(store.project.comparisonTables.first?.sceneID)
        XCTAssertNil(store.project.checklistTasks.first?.sceneID)
        XCTAssertFalse(store.project.assets.first?.linkedSceneIDs.contains(deletedID) == true)
        XCTAssertFalse(store.project.clips.first?.sourceSceneIDs.contains(deletedID) == true)
        XCTAssertNil(store.project.clips.first?.anchorSceneID)
        XCTAssertNil(store.project.clips.first?.anchor)
    }

    // MARK: - G-4 · Cancelling a board open is not a failure

    func testW3FixEGICancellingTheUnsavedPromptIsReportedAsCancelled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("W3FixEGI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetURL = root.appendingPathComponent("destino.fscr")
        try FrameScriptDocumentCodec.write(
            FrameScriptDocument(
                project: FrameScriptDocument.Project(title: "Destino", primaryLanguage: "es")
            ),
            to: targetURL
        )
        let data = try Data(contentsOf: targetURL)
        let summary = BoardProjectSummary(
            fileURL: targetURL,
            projectID: UUID(),
            title: "Destino",
            topic: "",
            videoType: "",
            productionStatus: .idea,
            targetDate: nil,
            publishDate: nil,
            updatedAt: Date(),
            createdAt: Date(),
            templateID: nil,
            sceneCount: 0,
            duration: BoardDuration(seconds: 0, estimatedSeconds: 0, realSceneCount: 0, sceneCount: 0),
            pendingTasks: [],
            fingerprint: BoardFileFingerprint(
                contentHash: BoardFileFingerprint.hash(of: data),
                fileSize: data.count,
                modificationDate: nil
            )
        )

        let appState = makeAppState(
            project: FrameProject(title: "Con cambios", primaryLanguage: "es"),
            closeConfirmation: { .cancel }
        )
        XCTAssertTrue(appState.projectStore.hasUnsavedFileChanges)

        XCTAssertEqual(
            appState.openBoardProject(summary, activatesApplication: false),
            .cancelled
        )
        XCTAssertNil(appState.projectStore.currentFileURL)
        XCTAssertNil(appState.errorCenter.presentedError)
    }

    // MARK: - G-6 · Open action helper

    func testW3FixEGIBoardOpenActionIsAvailableForSelectedRows() {
        let appState = makeAppState(project: FrameProject(title: "Proyecto", primaryLanguage: "es"))
        XCTAssertEqual(
            BoardProjectAccessibility.openActionName(appState: appState),
            appState.localized("board.action.open")
        )
    }

    func testW3FixEGIBoardReturnKeyOpensAFocusedProjectWithoutSelection() {
        var opened: [String] = []
        let result = BoardProjectKeyboard.open {
            opened.append("proyecto-sin-seleccionar")
        }

        XCTAssertEqual(result, .handled)
        XCTAssertEqual(opened, ["proyecto-sin-seleccionar"])
    }

    // MARK: - VW3 · Ensured-contrast kind text

    func testW3FixEGIProductionKindTextMeetsContrastOnEverySurface() {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentPalette.allCases {
                let theme = FrameTheme(colorScheme: scheme, accent: accent)
                let colors: [(String, Color)] = [
                    ("destructive", theme.destructive),
                    ("warning", theme.warning),
                    ("success", theme.success),
                    ("bRollMarker", theme.bRollMarker),
                    ("editingMarker", theme.editingMarker),
                    ("accent", theme.accent.color),
                    ("secondary", theme.secondaryText)
                ]
                for (name, color) in colors {
                    let ensured = NSColor(theme.ensuredText(color))
                    for surface in theme.textSurfaces {
                        let ratio = MarkupEditorPalette.contrastRatio(ensured, NSColor(surface))
                        XCTAssertGreaterThanOrEqual(
                            ratio,
                            4.5,
                            "\(name) \(accent) \(scheme) on \(surface): \(ratio):1"
                        )
                    }
                }
            }
        }
    }

    func testW3FixEGIAcquireReasonReadsAsAcquireInSpanishAndRussian() {
        XCTAssertEqual(L10n.tr("production.reason.bRollNeedsFootage", language: .spanish), "falta conseguir")
        XCTAssertEqual(L10n.tr("production.reason.bRollNeedsFootage", language: .russian), "нужно найти материал")
        XCTAssertEqual(L10n.tr("production.kind.acquire", language: .spanish), "Conseguir")
    }

    func testW3FixEGIPublishingChecklistLabelsAreHumanInEveryLanguage() {
        for item in PublishingChecklistItem.allCases {
            for language in [AppLanguage.english, .spanish, .russian] {
                let label = L10n.tr(item.titleKey, language: language)
                XCTAssertFalse(label.isEmpty, "\(item) has no \(language) label")
                XCTAssertNotEqual(label, item.taskToken, "\(item) leaks its token in \(language)")
                XCTAssertFalse(label.contains("publishing.checklist"), "\(item) leaks a token in \(language)")
            }
        }
        XCTAssertEqual(
            L10n.tr("production.reason.publishingChecklist", language: .spanish),
            "falta publicar"
        )
        XCTAssertEqual(
            L10n.tr(PublishingChecklistItem.endScreen.titleKey, language: .spanish),
            "Pantalla final"
        )
    }

    // MARK: - NEW-1 · Publishing checklist labels reach Plane

    func testW3FixEGIPlanePlanUsesTheHumanPublishingChecklistLabel() async throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let token = PublishingChecklistItem.endScreen.taskToken
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Con checklist",
                topic: "Vantare",
                videoType: "análisis",
                status: .script,
                scenes: [],
                checklist: [FrameScriptDocument.ChecklistTask(text: token, kind: .other)],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "checklist.fscr"
        )
        let document = try FrameScriptDocumentCodec.read(from: url)
        var withPack = document
        withPack.project.publishingPacks["es"] = FrameScriptDocument.PublishingPack()
        try FrameScriptDocumentCodec.write(withPack, to: url)
        await harness.refresh()

        let summary = try XCTUnwrap(harness.board.summaries.first { $0.title == "Con checklist" })
        let plan = await harness.board.planePlan(for: summary, appState: harness.appState)

        XCTAssertTrue(plan.entries.contains { $0.task.kind == .publicar })
        XCTAssertTrue(plan.entries.contains { $0.task.title.contains("Pantalla final") })
        XCTAssertFalse(plan.entries.contains { $0.task.title.hasPrefix("publishing.checklist.") })
    }

    // MARK: - Must-fix 1 · The board never keeps an unsaved state

    func testW3FixEGIBoardRefreshAfterDiscardingOpenProjectRereadsDisk() async throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Abierto",
                topic: "Vantare",
                videoType: "análisis",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "abierto.fscr"
        )
        harness.appState.openProject(at: url)
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))

        let outcome = await harness.board.apply(
            BoardProjectEdit(productionStatus: .recorded),
            to: summary,
            appState: harness.appState
        )
        guard case .saved(let edited) = outcome else {
            return XCTFail("Expected a saved outcome, got \(outcome)")
        }
        XCTAssertEqual(edited.productionStatus, .recorded)
        XCTAssertEqual(harness.board.summary(id: summary.id)?.productionStatus, .recorded)
        XCTAssertEqual(try FrameScriptDocumentCodec.read(from: url).project.productionStatus, .script)

        // A plain refresh must decode the file again: the in-memory summary is
        // marked stale, so the incremental reuse cannot keep an unsaved state
        // forever (must-fix 1).
        await harness.refresh()
        XCTAssertEqual(harness.board.summary(id: summary.id)?.productionStatus, .script)
    }

    func testW3FixEGIClosingWithoutSavingReloadsTheBoardRow() async throws {
        let harness = try BoardTestHarness(closeConfirmation: { .discard })
        addTeardownBlock { harness.tearDown() }
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Abierto",
                topic: "Vantare",
                videoType: "análisis",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "abierto.fscr"
        )
        harness.appState.openProject(at: url)
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))
        _ = await harness.board.apply(
            BoardProjectEdit(productionStatus: .recorded),
            to: summary,
            appState: harness.appState
        )
        XCTAssertEqual(harness.board.summary(id: summary.id)?.productionStatus, .recorded)
        XCTAssertTrue(harness.appState.projectStore.hasUnsavedFileChanges)

        XCTAssertTrue(harness.appState.closeProject())
        await harness.board.waitForPendingFileStateReloads()

        XCTAssertEqual(harness.board.summary(id: summary.id)?.productionStatus, .script)
        XCTAssertEqual(try FrameScriptDocumentCodec.read(from: url).project.productionStatus, .script)
    }

    // MARK: - Must-fix 2 · One publishing checklist per project

    func testW3FixEGIPlanePlanHasEightPublishingTasksForTwoPacks() async throws {
        let harness = try BoardTestHarness()
        addTeardownBlock { harness.tearDown() }
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Dos idiomas",
                topic: "Vantare",
                videoType: "análisis",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "dos-idiomas.fscr"
        )
        var document = try FrameScriptDocumentCodec.read(from: url)
        document.project.primaryLanguage = "es"
        document.project.publishingPacks["es"] = FrameScriptDocument.PublishingPack()
        document.project.publishingPacks["en"] = FrameScriptDocument.PublishingPack()
        try FrameScriptDocumentCodec.write(document, to: url)
        await harness.refresh()

        let summary = try XCTUnwrap(harness.board.summaries.first { $0.title == "Dos idiomas" })
        let plan = await harness.board.planePlan(for: summary, appState: harness.appState)
        let publish = plan.entries.filter { $0.task.kind == .publicar }

        XCTAssertEqual(publish.count, 8)
        XCTAssertEqual(Set(publish.map { $0.task.id }).count, 8)
        XCTAssertEqual(summary.pending.count(for: .publicar), 8)
    }

    // MARK: - Must-fix 3 · Backup failures reach BackupHealth

    func testW3FixEGIBoardClosedFileWriteRecordsAFailedBackup() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("W3FixEGIBackups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let failingStore = BackupStore(
            rootDirectory: tempRoot,
            fileManager: W3FixEGIFailingBackupFileManager()
        )
        let harness = try BoardTestHarness(backupStore: failingStore)
        addTeardownBlock { harness.tearDown() }
        let url = try harness.writeProject(
            BoardTestHarness.makeDocument(
                title: "Respaldo roto",
                topic: "Vantare",
                videoType: "análisis",
                status: .script,
                scenes: [],
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            fileName: "respaldo-roto.fscr"
        )
        await harness.refresh()
        let summary = try XCTUnwrap(harness.board.index.summary(forFileAt: url))
        let backupProjectID = BackupProjectIdentity.identifier(
            projectUUID: summary.projectID,
            fileURL: url
        )
        BackupHealth.shared.clear(projectID: backupProjectID)
        addTeardownBlock { BackupHealth.shared.clear(projectID: backupProjectID) }

        let outcome = await harness.board.apply(
            BoardProjectEdit(productionStatus: .recorded),
            to: summary,
            appState: harness.appState
        )

        guard case .saved = outcome else {
            return XCTFail("A failed backup must not cancel the board write: \(outcome)")
        }
        XCTAssertNotNil(
            BackupHealth.shared.failure(for: backupProjectID),
            "The failed backup was not surfaced through BackupHealth"
        )
        XCTAssertEqual(try FrameScriptDocumentCodec.read(from: url).project.productionStatus, .recorded)
    }

    // MARK: - Must-fix 4 · The checkbox is the pending rule

    func testW3FixEGINewClaimStartsFlaggedAndUntickingAcceptsIt() {
        let scene = makeScene(order: 0, title: "Escena", text: "Texto.")
        let appState = makeAppState(project: FrameProject(
            title: "Proyecto",
            scenes: [scene],
            primaryLanguage: "es"
        ))

        let claim = appState.addResearchClaim(
            text: "En el foro dicen que llueve",
            status: .communityOpinion,
            sceneIDs: [scene.id]
        )
        XCTAssertTrue(claim.needsVerification)
        XCTAssertEqual(appState.researchCounts().pending, 1)
        XCTAssertEqual(appState.productionSnapshot.summary.pendingCount(for: .research), 1)
        let boardBefore = ProductionBoardPendingTaskProvider().pendingTasks(
            for: FrameScriptDocument.Project(project: appState.project),
            labels: .english
        )
        XCTAssertEqual(boardBefore.filter { $0.kind == .investigar }.count, 1)

        appState.toggleResearchClaimVerification(id: claim.id)

        XCTAssertFalse(appState.project.claims[0].needsVerification)
        XCTAssertEqual(appState.researchCounts().pending, 0)
        XCTAssertEqual(appState.researchUnconfirmedCount(for: scene.id), 0)
        XCTAssertEqual(appState.productionSnapshot.summary.pendingCount(for: .research), 0)
        XCTAssertFalse(appState.researchOpenTasks().contains { $0.text == claim.text })
        let boardAfter = ProductionBoardPendingTaskProvider().pendingTasks(
            for: FrameScriptDocument.Project(project: appState.project),
            labels: .english
        )
        XCTAssertFalse(boardAfter.contains { $0.kind == .investigar })
    }

    func testW3FixEGIConfirmClearsTheFlagAndRecheckSurvivesLaterUpdates() {
        let appState = makeAppState(project: FrameProject(title: "Proyecto", primaryLanguage: "es"))
        let claim = appState.addResearchClaim(text: "Dato", status: .probable)
        XCTAssertTrue(claim.needsVerification)

        appState.setResearchClaimStatus(id: claim.id, status: .confirmed)
        XCTAssertFalse(appState.project.claims[0].needsVerification)
        XCTAssertEqual(appState.researchCounts().pending, 0)

        // Ticking a confirmed claim asks for a second check...
        appState.toggleResearchClaimVerification(id: claim.id)
        XCTAssertTrue(appState.project.claims[0].needsVerification)
        XCTAssertEqual(appState.researchCounts().pending, 1)

        // ...and a later edit of that confirmed claim must not clear it.
        var updated = appState.project.claims[0]
        updated.resolutionNote = "Revisado otra vez"
        appState.updateResearchClaim(updated)
        XCTAssertTrue(appState.project.claims[0].needsVerification)
        XCTAssertEqual(appState.researchCounts().pending, 1)
    }

    // MARK: - Must-fix 5 · One shared button style

    func testW3FixEGISharedButtonStylesExposeBothShorthandsAndSizes() {
        let primary: FramePrimaryButtonStyle = .framePrimary
        let secondary: FrameSecondaryButtonStyle = .frameSecondary

        XCTAssertEqual(primary.size, .regular)
        XCTAssertEqual(secondary.size, .regular)
        XCTAssertEqual(FramePrimaryButtonStyle(size: .compact).size, .compact)
        XCTAssertEqual(FrameSecondaryButtonStyle(size: .compact).size, .compact)
        XCTAssertEqual(FramePrimaryButtonStyle(compact: true).size, .compact)
    }

    // MARK: - G-1 · Owned by the parallel publishing fixer

    func testW3FixEGIPublishingPromisePreservesTheBoardTopic() throws {
        throw XCTSkip(
            "G-1 is owned by w3fix/cdh (publishing promise/thesis overwrite). "
                + "Enable this regression once both branches are merged."
        )
    }

    // MARK: - Helpers

    private func makeScene(order: Int, title: String, text: String) -> FrameScript.Scene {
        FrameScript.Scene(order: order, sectionType: .custom, title: title, scriptText: text)
    }

    private func makeAppState(
        project: FrameProject,
        closeConfirmation: AppState.CloseConfirmation? = nil
    ) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false

        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)

        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: W3FixEGIEmptyOBSSecretStore()
            ),
            defaults: defaults
        )
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(
                userDefaults: defaults,
                storageKey: "test.recents",
                legacyPathsKey: "test.legacyPaths",
                bookmarkCreator: { url in Data(url.path.utf8) },
                bookmarkResolver: { data, _ in
                    URL(fileURLWithPath: String(decoding: data, as: UTF8.self))
                },
                securityScope: W3FixEGINoSecurityScope
            ),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            securityScope: W3FixEGINoSecurityScope,
            closeConfirmation: closeConfirmation,
            customTemplates: []
        )
    }

}

private struct W3FixEGIEmptyOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

/// Lets normal file reads succeed but fails every backup write, so the board's
/// closed-file path can prove a backup failure is surfaced without touching the
/// user's real backup folder.
private struct W3FixEGIFailingBackupFileManager: BackupFileManaging {
    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        []
    }

    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        [:]
    }

    func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }

    func removeItem(at url: URL) throws {}
}

private let W3FixEGINoSecurityScope = SecurityScopedResourceAccess(
    start: { _ in false },
    stop: { _ in }
)
