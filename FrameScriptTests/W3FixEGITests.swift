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
        XCTAssertTrue(BoardProjectAccessibility.handlesReturnKey(isSelected: true))
        XCTAssertFalse(BoardProjectAccessibility.handlesReturnKey(isSelected: false))
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

private let W3FixEGINoSecurityScope = SecurityScopedResourceAccess(
    start: { _ in false },
    stop: { _ in }
)
