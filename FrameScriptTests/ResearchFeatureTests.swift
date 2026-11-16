import Foundation
@testable import FrameScript
import FrameScriptCore
import XCTest

@MainActor
final class ResearchFeatureTests: XCTestCase {
    /// Isolated suites in the process temporary directory; no real plist.
    private var isolatedSuites: [TestDefaults] = []

    override func setUp() async throws {
        try await super.setUp()
        resetPresentation()
    }

    override func tearDown() async throws {
        for suite in isolatedSuites {
            suite.cleanup()
        }
        isolatedSuites.removeAll()
        resetPresentation()
        try await super.tearDown()
    }

    // MARK: - Counters and badges

    func testCountersAndSceneBadgeUseStoredClaims() {
        let first = makeScene(order: 0, title: "Apertura")
        let second = makeScene(order: 1, title: "Cierre")
        let project = makeProject(scenes: [first, second])
        let appState = makeAppState(project: project)

        _ = appState.addResearchClaim(
            text: "El récord es 1:42.3",
            status: .confirmed,
            sceneIDs: [first.id],
            needsVerification: false
        )
        _ = appState.addResearchClaim(
            text: "El parche sale en mayo",
            status: .probable,
            sceneIDs: [first.id],
            needsVerification: true
        )
        _ = appState.addResearchClaim(
            text: "En el foro dicen que llueve",
            status: .communityOpinion,
            sceneIDs: [second.id],
            needsVerification: false
        )

        let counts = appState.researchCounts()
        XCTAssertEqual(counts.confirmed, 1)
        XCTAssertEqual(counts.probable, 1)
        XCTAssertEqual(counts.communityOpinion, 1)
        XCTAssertEqual(counts.pending, 1)
        XCTAssertEqual(appState.researchUnconfirmedCount(for: first.id), 1)
        XCTAssertEqual(appState.researchUnconfirmedCount(for: second.id), 0)
    }

    func testSceneFilterAndPendingFilterNarrowClaims() {
        let scene = makeScene(order: 0, title: "Apertura")
        let other = makeScene(order: 1, title: "Cierre")
        let appState = makeAppState(project: makeProject(scenes: [scene, other]))

        _ = appState.addResearchClaim(text: "Pendiente en apertura", sceneIDs: [scene.id], needsVerification: true)
        _ = appState.addResearchClaim(text: "Resuelta en apertura", status: .confirmed, sceneIDs: [scene.id], needsVerification: false)
        _ = appState.addResearchClaim(text: "Pendiente en cierre", sceneIDs: [other.id], needsVerification: true)

        ResearchPresentation.shared.focusedSceneID = scene.id
        ResearchPresentation.shared.onlyPending = true

        XCTAssertEqual(appState.filteredResearchClaims().map(\.text), ["Pendiente en apertura"])
    }

    // MARK: - Checklist

    func testAddingPendingClaimAddsResearchTaskAndConfirmingClosesIt() {
        let scene = makeScene(order: 0, title: "Apertura")
        let appState = makeAppState(project: makeProject(scenes: [scene]))

        let claim = appState.addResearchClaim(
            text: "El récord es 1:42.3",
            sceneIDs: [scene.id],
            needsVerification: true
        )

        let task = appState.project.checklistTasks.first { $0.text == claim.text }
        XCTAssertEqual(task?.kind, .research)
        XCTAssertEqual(task?.isDone, false)

        appState.confirmResearchClaim(id: claim.id, resolutionNote: "PDF oficial")

        let updated = appState.project.claims.first { $0.id == claim.id }
        XCTAssertEqual(updated?.status, .confirmed)
        XCTAssertEqual(updated?.needsVerification, false)
        XCTAssertEqual(updated?.resolutionNote, "PDF oficial")
        XCTAssertEqual(appState.project.checklistTasks.first { $0.text == claim.text }?.isDone, true)
        XCTAssertTrue(appState.researchPendingItems().isEmpty)
    }

    func testDuplicatePendingTextDoesNotDuplicateResearchTasks() {
        let scene = makeScene(order: 0, title: "Apertura")
        let appState = makeAppState(project: makeProject(scenes: [scene]))

        _ = appState.addResearchClaim(text: "El récord es 1:42.3", sceneIDs: [scene.id])
        _ = appState.addResearchClaim(text: "  el récord es  1:42.3 ", sceneIDs: [scene.id])

        XCTAssertEqual(appState.project.checklistTasks.filter { $0.kind == .research }.count, 1)
    }

    func testEditingPendingClaimRenamesItsResearchTask() {
        let scene = makeScene(order: 0, title: "Apertura")
        let appState = makeAppState(project: makeProject(scenes: [scene]))
        var claim = appState.addResearchClaim(
            text: "El parche sale en mayo",
            sceneIDs: [scene.id],
            needsVerification: true
        )

        claim.text = "El parche sale en junio"
        appState.updateResearchClaim(claim)

        let task = appState.project.checklistTasks.first { $0.kind == .research }
        XCTAssertEqual(task?.text, "El parche sale en junio")
        XCTAssertEqual(appState.project.checklistTasks.filter { $0.kind == .research }.count, 1)
    }

    func testPersonalExperienceNeverEntersPendingOrChecklist() {
        let appState = makeAppState(project: makeProject(scenes: [makeScene(order: 0, title: "Apertura")]))

        _ = appState.addResearchClaim(
            text: "Yo lo probé y me pareció lento",
            needsVerification: true,
            personalExperience: true
        )

        XCTAssertEqual(appState.researchCounts().pending, 0)
        XCTAssertTrue(appState.project.checklistTasks.isEmpty)
    }

    // MARK: - Sources and anchors

    func testDeletingSourceRemovesItFromClaims() {
        let appState = makeAppState(project: makeProject(scenes: [makeScene(order: 0, title: "Apertura")]))
        let source = appState.addResearchSource(title: "Timing oficial", url: "https://example.com/timing")
        let claim = appState.addResearchClaim(
            text: "El récord es 1:42.3",
            sourceIDs: [source.id],
            needsVerification: false
        )

        appState.deleteResearchSource(id: source.id)

        XCTAssertTrue(appState.project.sources.isEmpty)
        XCTAssertTrue(appState.project.claims.first { $0.id == claim.id }?.sourceIDs.isEmpty == true)
    }

    func testAnchorLinksOnlyWhenFragmentExists() {
        let scene = makeScene(
            order: 0,
            title: "Apertura",
            text: "Antes. El récord del circuito es 1:42.3. Después."
        )
        let appState = makeAppState(project: makeProject(scenes: [scene]))
        let claim = appState.addResearchClaim(text: "El récord es 1:42.3", sceneIDs: [scene.id])

        XCTAssertFalse(appState.setResearchClaimAnchor(id: claim.id, fragment: "no aparece"))
        XCTAssertTrue(appState.setResearchClaimAnchor(id: claim.id, fragment: "récord del circuito"))

        let updated = appState.project.claims.first { $0.id == claim.id }
        XCTAssertEqual(updated?.anchor?.selectedText, "récord del circuito")
        XCTAssertEqual(updated?.anchorSceneID, scene.id)

        appState.clearResearchClaimAnchor(id: claim.id)
        XCTAssertNil(appState.project.claims.first { $0.id == claim.id }?.anchor)
    }

    // MARK: - Tables

    func testTableOperationsAndPasteApplyToProject() throws {
        let appState = makeAppState(project: makeProject(scenes: [makeScene(order: 0, title: "Apertura")]))
        let table = appState.addComparisonTable(title: "Neumáticos", header: ["Compuesto", "Tiempo"])

        appState.addComparisonTableRow(id: table.id)
        appState.addComparisonTableColumn(id: table.id)

        var updated = try XCTUnwrap(appState.project.comparisonTables.first { $0.id == table.id })
        XCTAssertEqual(updated.rows.count, 1)
        XCTAssertEqual(updated.header.count, 3)

        let parsed = try ComparisonTablePaste.parse("Compuesto\tTiempo\nBlando\t1:42.3\nDuro\t1:43.9")
        appState.applyComparisonTablePaste(id: table.id, result: parsed)

        updated = try XCTUnwrap(appState.project.comparisonTables.first { $0.id == table.id })
        XCTAssertEqual(updated.header, ["Compuesto", "Tiempo"])
        XCTAssertEqual(updated.rows, [["Blando", "1:42.3"], ["Duro", "1:43.9"]])

        let issues = appState.tableValidationIssues(ComparisonTable(title: "Vacía", header: ["A"], rows: [[""]]))
        XCTAssertTrue(issues.contains { if case .emptyCell = $0 { return true }; return false })
    }

    func testTableCueIsAddedOnlyOnce() {
        let scene = makeScene(order: 0, title: "Apertura")
        let appState = makeAppState(project: makeProject(scenes: [scene]))
        let table = appState.addComparisonTable(title: "Neumáticos", header: ["A"], rows: [["1"]], sceneID: scene.id)

        XCTAssertTrue(appState.addComparisonTableCue(tableID: table.id))
        XCTAssertFalse(appState.addComparisonTableCue(tableID: table.id))

        let cues = appState.project.scenes.first?.bRollItems.filter {
            $0.descriptionText.contains("[TABLA EN PANTALLA]")
        }
        XCTAssertEqual(cues?.count, 1)
        XCTAssertEqual(cues?.first?.sourceType, .infographic)
        XCTAssertEqual(cues?.first?.notes, "Neumáticos")
    }

    // MARK: - Export

    func testMarkdownExportContainsResearchAppendixAndWarnings() {
        let scene = makeScene(order: 0, title: "Apertura", text: "El récord del circuito es 1:42.3.")
        let appState = makeAppState(project: makeProject(scenes: [scene]))
        let source = appState.addResearchSource(title: "Timing oficial", url: "https://example.com/timing")
        _ = appState.addResearchClaim(
            text: "El récord es 1:42.3",
            status: .probable,
            sourceIDs: [source.id],
            sceneIDs: [scene.id],
            needsVerification: true
        )

        let markdown = ExportService().render(
            project: appState.project,
            format: .markdown,
            preferences: AppSettings.defaults.exportPreferences,
            language: .spanish
        )

        XCTAssertTrue(markdown.contains("## Fuentes y verificación"))
        XCTAssertTrue(markdown.contains("**Timing oficial**"))
        XCTAssertTrue(markdown.contains("## Avisos de verificación"))
        XCTAssertTrue(markdown.contains("Apertura"))
    }

    func testDescriptionBlockIsAppendedOnlyOnce() {
        let appState = makeAppState(project: makeProject(scenes: [makeScene(order: 0, title: "Apertura")]))
        _ = appState.addResearchSource(title: "Timing oficial", url: "https://example.com/timing")
        _ = appState.addResearchClaim(text: "El récord es 1:42.3", needsVerification: true)

        XCTAssertEqual(appState.appendResearchToPublishingDescription(language: "es"), .createdPack)
        let description = appState.project.publishingPacks["es"]?.description ?? ""
        XCTAssertTrue(description.hasPrefix("Fuentes y verificación"))
        XCTAssertTrue(description.contains("Timing oficial"))

        XCTAssertEqual(appState.appendResearchToPublishingDescription(language: "es"), .alreadyPresent)
        XCTAssertEqual(appState.project.publishingPacks["es"]?.description, description)
    }

    func testEscaletaExportKeepsTableSceneLinkAndDropsConfirmedClaim() {
        let scene = makeScene(order: 0, title: "Apertura")
        let appState = makeAppState(project: makeProject(scenes: [scene]))
        let table = appState.addComparisonTable(
            title: "Neumáticos",
            header: ["A"],
            rows: [["1"]],
            sceneID: scene.id
        )
        let claim = appState.addResearchClaim(text: "El parche sale en mayo", sceneIDs: [scene.id])

        var document = EscaletaProjectExporter.document(from: appState.project)
        XCTAssertEqual(document.comparisonTables.first?.sceneIndex, 0)
        XCTAssertEqual(document.verificationItems.count, 1)
        XCTAssertEqual(table.sceneID, scene.id)

        appState.confirmResearchClaim(id: claim.id)

        document = EscaletaProjectExporter.document(from: appState.project)
        XCTAssertTrue(document.verificationItems.isEmpty)
    }

    // MARK: - AI suggestions

    func testAIClaimCheckNeverConfirmsAndRequiresUserAcceptance() async {
        let scene = makeScene(order: 0, title: "Apertura", text: "El parche sale en mayo.")
        let provider = ResearchTestProvider(
            LLMResponse(text: #"{"claims":[{"text":"El parche sale en mayo.","status":"confirmed","reason":"Falta la fecha oficial."}]}"#)
        )
        let appState = makeAppState(project: makeProject(scenes: [scene]), provider: provider, aiEnabled: true)

        await appState.suggestResearchClaims(for: scene.id)

        XCTAssertEqual(ResearchPresentation.shared.claimSuggestions.count, 1)
        let suggestion = ResearchPresentation.shared.claimSuggestions[0]
        XCTAssertEqual(suggestion.status, .probable)
        XCTAssertTrue(appState.project.claims.isEmpty, "the AI must not add claims by itself")

        appState.acceptResearchClaimSuggestion(suggestion)

        let claim = appState.project.claims.first
        XCTAssertEqual(claim?.status, .probable)
        XCTAssertEqual(claim?.needsVerification, true)
        XCTAssertEqual(claim?.sceneIDs, [scene.id])
        XCTAssertNotEqual(claim?.status, .confirmed)
        XCTAssertTrue(ResearchPresentation.shared.claimSuggestions.isEmpty)
    }

    // MARK: - Window wiring

    func testResearchWindowBuildsOffscreenWithSpanishTitleAndMinimumSize() {
        let appState = makeAppState(project: makeProject(scenes: [makeScene(order: 0, title: "Apertura")]))
        let controller = ResearchWindowController(appState: appState)
        let window = controller.window

        XCTAssertEqual(window?.title, "Investigación")
        XCTAssertNotNil(window?.contentView)
        XCTAssertEqual(window?.minSize.width, 900)
        XCTAssertEqual(window?.minSize.height, 600)
        XCTAssertFalse(window?.isVisible ?? true)
        controller.close()
    }

    // MARK: - Helpers

    private func resetPresentation() {
        let presentation = ResearchPresentation.shared
        presentation.selectedTab = .claims
        presentation.focusedSceneID = nil
        presentation.statusFilter = Set(ClaimStatus.allCases)
        presentation.onlyPending = false
        presentation.searchText = ""
        presentation.selectedSourceID = nil
        presentation.selectedClaimID = nil
        presentation.selectedTableID = nil
        presentation.resetSuggestions()
        presentation.resetPaste()
        presentation.statusMessage = nil
    }

    private func makeScene(
        order: Int,
        title: String,
        text: String = "Texto sintético de la escena."
    ) -> Scene {
        Scene(order: order, sectionType: .custom, title: title, scriptText: text)
    }

    private func makeProject(scenes: [Scene]) -> FrameProject {
        FrameProject(title: "Proyecto sintético", scenes: scenes, primaryLanguage: "es")
    }

    private func makeAppState(
        project: FrameProject,
        provider: (any LLMProviderProtocol)? = nil,
        aiEnabled: Bool = false
    ) -> AppState {
        let isolated = TestDefaults.make()
        isolatedSuites.append(isolated)
        let defaults = isolated.defaults

        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        if aiEnabled {
            settings.aiPreferences.provider = .openAICompatible
            settings.aiPreferences.model = "test-model"
        }

        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let llm = provider ?? ResearchTestProvider(LLMResponse(text: "{}"))
        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: ResearchTestOBSSecretStore()
            ),
            defaults: defaults
        )
        let dependencies = AppDependencies(
            rewriteService: RewriteService(provider: llm),
            analysisService: AnalysisService(provider: llm),
            exportService: ExportService(),
            llmProvider: llm,
            providerCredentials: ProviderCredentialSession(reader: { _ in "test-key" })
        )

        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: dependencies,
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }
}

@MainActor
private final class ResearchTestProvider: LLMProviderProtocol {
    private(set) var requests: [LLMRequest] = []
    private let response: LLMResponse

    init(_ response: LLMResponse) {
        self.response = response
    }

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        requests.append(request)
        return response
    }
}

private struct ResearchTestOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
