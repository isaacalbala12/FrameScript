import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class PublishingTests: XCTestCase {
    /// Two isolated suites in the process temporary directory: one for the app
    /// preferences and one for the OBS recording preferences.
    private var preferencesSuite: TestDefaults?
    private var recordingSuite: TestDefaults?
    private var defaults: UserDefaults!
    private var recordingDefaults: UserDefaults!
    private var temporaryDirectory: URL!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        let preferencesSuite = TestDefaults.make()
        let recordingSuite = TestDefaults.make()
        self.preferencesSuite = preferencesSuite
        self.recordingSuite = recordingSuite
        defaults = preferencesSuite.defaults
        recordingDefaults = recordingSuite.defaults
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        PublishingPresentation.shared.resetTitleGeneration()
        PublishingPresentation.shared.isPresented = false
    }

    override func tearDown() {
        appState = nil
        preferencesSuite?.cleanup()
        preferencesSuite = nil
        recordingSuite?.cleanup()
        recordingSuite = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        PublishingPresentation.shared.resetTitleGeneration()
        PublishingPresentation.shared.isPresented = false
        super.tearDown()
    }

    // MARK: - Pack access and languages

    func testPackIsKeyedByLanguageAndCaseInsensitiveWritesReuseTheKey() {
        let project = makeProject()
        project.publishingPacks["es"] = PublishingPack(chosenTitle: "Título en español")
        project.publishingPacks["en"] = PublishingPack(chosenTitle: "English title")
        let state = makeAppState(project: project)

        XCTAssertEqual(state.publishingAvailableLanguageCodes, ["es", "en"])
        XCTAssertEqual(state.publishingPack(language: "es").chosenTitle, "Título en español")
        XCTAssertEqual(state.publishingPack(language: "EN").chosenTitle, "English title")

        state.updatePublishingPack(language: "EN") { $0.chosenTitle = "Updated English" }
        XCTAssertNil(project.publishingPacks["EN"])
        XCTAssertEqual(project.publishingPacks["en"]?.chosenTitle, "Updated English")
        XCTAssertEqual(project.publishingPacks["es"]?.chosenTitle, "Título en español")

        let name = state.publishingLanguageDisplayName("es")
        XCTAssertTrue(name.contains("Español"))
        XCTAssertTrue(name.contains("(es)"))
    }

    func testPromiseAndThesisRoundTripThroughTheProjectFile() throws {
        let project = makeProject()
        let state = makeAppState(project: project)
        state.setPublishingPromise("Elegir sin gastar de más.")
        state.setPublishingThesis("La presión importa más que la marca.")

        XCTAssertEqual(state.publishingPromise, "Elegir sin gastar de más.")
        XCTAssertEqual(state.publishingThesis, "La presión importa más que la marca.")

        let url = temporaryDirectory.appendingPathComponent("Proyecto.fscr")
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(EscaletaProjectNotes.decode(loaded.topic).promise, "Elegir sin gastar de más.")
        XCTAssertEqual(EscaletaProjectNotes.decode(loaded.topic).thesis, "La presión importa más que la marca.")
    }

    // MARK: - Chapters

    func testChapterPlanUsesTheBestRealTakeAndTheEstimateForTheRest() {
        let sceneA = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 40)
        sceneA.takes = [makeTake(duration: 33, text: longText())]
        let sceneB = makeScene(order: 1, title: "Qué cambia", text: longText(), estimated: 40)
        let sceneC = makeScene(order: 2, title: "Prueba", text: longText(), estimated: 40)
        let sceneD = makeScene(order: 3, title: "Veredicto", text: longText(), estimated: 40)
        let project = FrameProject(title: "Vídeo sintético", scenes: [sceneA, sceneB, sceneC, sceneD])
        let state = makeAppState(project: project)
        sceneB.estimatedDuration = 40
        sceneC.estimatedDuration = 40
        sceneD.estimatedDuration = 40

        let plan = state.publishingChapterPlan(language: "es")
        XCTAssertEqual(plan.chapters.map(\.startSeconds), [0, 33, 73, 113])
        XCTAssertEqual(plan.chapters.map(\.title), ["Gancho", "Qué cambia", "Prueba", "Veredicto"])
        XCTAssertTrue(plan.isValidForYouTube)

        let infoA = state.publishingSceneDurationInfo(scene: sceneA, language: "es")
        let infoB = state.publishingSceneDurationInfo(scene: sceneB, language: "es")
        XCTAssertTrue(infoA.isReal)
        XCTAssertEqual(infoA.duration, 33, accuracy: 0.01)
        XCTAssertFalse(infoB.isReal)
        XCTAssertEqual(infoB.duration, 40, accuracy: 0.01)
    }

    func testChapterPlanUsesTheTranslatedTakeForTheVariantLanguage() {
        let originalText = longText()
        let translatedText = "Uno dos tres cuatro cinco seis siete ocho nueve diez."
        let scene = makeScene(order: 0, title: "Gancho", text: originalText, estimated: 40)
        var take = makeTake(duration: 50, text: translatedText)
        take.languageCode = "en"
        scene.languageVariants = [
            SceneLanguageVariant(
                languageCode: "en",
                text: translatedText,
                sourceHash: FrameScriptDocument.TextHash.hash(originalText),
                takes: [take]
            )
        ]
        let second = makeScene(order: 1, title: "Second", text: translatedText, estimated: 30)
        let third = makeScene(order: 2, title: "Third", text: translatedText, estimated: 30)
        let project = FrameProject(title: "Synthetic", scenes: [scene, second, third], primaryLanguage: "es")
        let state = makeAppState(project: project)
        second.estimatedDuration = 30
        third.estimatedDuration = 30

        let plan = state.publishingChapterPlan(language: "en")
        XCTAssertEqual(plan.chapters.first?.startSeconds, 0)
        XCTAssertEqual(plan.chapters.dropFirst().first?.startSeconds, 50)

        let info = state.publishingSceneDurationInfo(scene: scene, language: "en")
        XCTAssertTrue(info.isReal)
        XCTAssertEqual(info.duration, 50, accuracy: 0.01)
    }

    func testRegenerationKeepsHandEditedTitlesOnlyWhenAsked() {
        let sceneA = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 40)
        let sceneB = makeScene(order: 1, title: "Qué cambia", text: longText(), estimated: 40)
        let sceneC = makeScene(order: 2, title: "Veredicto", text: longText(), estimated: 40)
        let project = FrameProject(title: "Vídeo sintético", scenes: [sceneA, sceneB, sceneC])
        let state = makeAppState(project: project)
        sceneA.estimatedDuration = 40
        sceneB.estimatedDuration = 40
        sceneC.estimatedDuration = 40

        state.setPublishingChapterTitle("Mi gancho", sceneID: sceneA.id, language: "es")
        let diff = state.publishingChapterDiff(language: "es")
        XCTAssertTrue(diff.hasChanges)
        XCTAssertEqual(diff.titleChanges.first?.oldTitle, "Mi gancho")
        XCTAssertEqual(diff.titleChanges.first?.newTitle, "Gancho")

        let plan = state.publishingChapterPlan(language: "es", ignoringOverrideTitles: true)
        state.applyPublishingChapterPlan(plan, language: "es", keepingEditedTitles: true)
        XCTAssertEqual(state.publishingChapterOverride(sceneID: sceneA.id, language: "es")?.title, "Mi gancho")

        state.applyPublishingChapterPlan(plan, language: "es", keepingEditedTitles: false)
        XCTAssertEqual(state.publishingChapterOverride(sceneID: sceneA.id, language: "es")?.title, "Gancho")
    }

    func testExcludingASceneSurvivesRegeneration() {
        let sceneA = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 40)
        let sceneB = makeScene(order: 1, title: "Fuera", text: longText(), estimated: 40)
        let sceneC = makeScene(order: 2, title: "Veredicto", text: longText(), estimated: 40)
        let project = FrameProject(title: "Vídeo sintético", scenes: [sceneA, sceneB, sceneC])
        let state = makeAppState(project: project)
        sceneA.estimatedDuration = 40
        sceneB.estimatedDuration = 40
        sceneC.estimatedDuration = 40

        state.setPublishingChapterIncluded(false, sceneID: sceneB.id, language: "es")
        let plan = state.publishingChapterPlan(language: "es")
        XCTAssertFalse(plan.chapters.contains { $0.sceneID == sceneB.id })
        XCTAssertEqual(plan.chapters.map(\.startSeconds), [0, 80])

        state.applyPublishingChapterPlan(plan, language: "es", keepingEditedTitles: true)
        XCTAssertEqual(state.publishingChapterOverride(sceneID: sceneB.id, language: "es")?.isExcluded, true)
        XCTAssertFalse(state.publishingChapterPlan(language: "es").chapters.contains { $0.sceneID == sceneB.id })
    }

    // MARK: - Checklist

    func testChecklistPersistsInChecklistTasksAndSurvivesFileRoundTrip() throws {
        let project = makeProject()
        let state = makeAppState(project: project)

        state.setPublishingChecklist(.chosenTitle, done: true)
        state.setPublishingChecklist(.subtitlesReviewed, done: true)
        XCTAssertTrue(state.publishingChecklistIsDone(.chosenTitle))
        XCTAssertFalse(state.publishingChecklistIsDone(.tags))
        XCTAssertEqual(state.publishingChecklistProgress.done, 2)
        XCTAssertEqual(state.publishingChecklistProgress.total, 8)

        let url = temporaryDirectory.appendingPathComponent("Checklist.fscr")
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        let tasks = loaded.checklistTasks.filter { $0.kind == .other }
        XCTAssertTrue(tasks.contains { $0.text == PublishingChecklistItem.chosenTitle.taskToken && $0.isDone })
        XCTAssertTrue(tasks.contains { $0.text == PublishingChecklistItem.subtitlesReviewed.taskToken && $0.isDone })

        let second = makeAppState(project: loaded)
        XCTAssertTrue(second.publishingChecklistIsDone(.chosenTitle))
        XCTAssertTrue(second.publishingChecklistIsDone(.subtitlesReviewed))
        XCTAssertFalse(second.publishingChecklistIsDone(.endScreen))
    }

    // MARK: - Thumbnails

    func testThumbnailCopyUsesTheSiblingAssetsFolderAndAvoidsOverwriting() throws {
        let project = makeProject()
        let projectURL = temporaryDirectory.appendingPathComponent("Proyecto.fscr")
        let state = makeAppState(project: project, fileURL: projectURL)
        let source = try makePNG(named: "portada.png")

        let first = try state.addPublishingThumbnail(from: source, language: "es")
        let firstAsset = try XCTUnwrap(project.assets.first(where: { $0.id == first.assetID }))
        XCTAssertEqual(
            firstAsset.path,
            temporaryDirectory.appendingPathComponent("Proyecto assets/portada.png").path
        )
        XCTAssertTrue(firstAsset.path.hasPrefix("/"))
        XCTAssertNotNil(firstAsset.bookmarkData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAsset.path))
        XCTAssertEqual(project.publishingPacks["es"]?.thumbnailVariants.count, 1)
        XCTAssertEqual(project.publishingPacks["es"]?.thumbnailVariants.first?.isChosen, true)

        let second = try state.addPublishingThumbnail(from: source, language: "es")
        let secondPath = try XCTUnwrap(project.assets.first(where: { $0.id == second.assetID })?.path)
        XCTAssertEqual(
            secondPath,
            temporaryDirectory.appendingPathComponent("Proyecto assets/portada 2.png").path
        )
        XCTAssertNotEqual(firstAsset.path, secondPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAsset.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))

        let url = try XCTUnwrap(state.publishingThumbnailURL(for: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testThumbnailCopyRequiresASavedProject() throws {
        let project = makeProject()
        let state = makeAppState(project: project, fileURL: nil)
        let source = try makePNG(named: "portada.png")

        XCTAssertThrowsError(try state.addPublishingThumbnail(from: source, language: "es")) { error in
            XCTAssertEqual(error as? ThumbnailFileStoreError, .projectNotSaved)
        }
    }

    // MARK: - Export

    func testExportRoundTripsThePublishingPackThroughTheImporter() throws {
        let sceneA = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 45)
        let sceneB = makeScene(order: 1, title: "Prueba", text: longText(), estimated: 60)
        let sceneC = makeScene(order: 2, title: "Veredicto", text: longText(), estimated: 45)
        let project = FrameProject(
            title: "Cómo elegir neumáticos para mojado",
            scenes: [sceneA, sceneB, sceneC],
            primaryLanguage: "es"
        )
        project.topic = EscaletaProjectNotes(
            promise: "Elegir sin gastar de más.",
            thesis: "La presión importa más que la marca."
        ).encoded()
        project.publishingPacks["es"] = PublishingPack(
            titleCandidates: ["Uno", "Dos", "Tres"],
            chosenTitle: "Neumáticos de lluvia: la presión que nadie mira",
            description: "Comparamos tres neumáticos con telemetría real.",
            tags: ["simracing", "lluvia", "guía"],
            hashtags: ["#simracing", "#lluvia"],
            pinnedComment: "¿Qué neumático usas tú?",
            communityPost: "Nuevo vídeo sobre neumáticos de lluvia.",
            thumbnailConceptNotes: """
            ### Concepto A — La presión manda
            Idea: Dos ruedas con presiones distintas.
            Composición:
            - Rueda a la izquierda
            Por qué funciona: Se entiende de un vistazo.
            """
        )
        project.sources = [
            ProjectSource(title: "Reglamento técnico", url: "https://example.com/reglamento")
        ]
        let state = makeAppState(project: project)
        sceneA.estimatedDuration = 45
        sceneB.estimatedDuration = 60
        sceneC.estimatedDuration = 45

        let markdown = state.publishingExportMarkdown(language: "es")
        XCTAssertTrue(markdown.contains("# Paquete SEO"))
        XCTAssertTrue(markdown.contains("## Título recomendado"))
        XCTAssertTrue(markdown.contains("## Capítulos"))
        XCTAssertTrue(markdown.contains("## YouTube Studio"))
        XCTAssertTrue(markdown.contains("0:00 Gancho"))

        let parsed = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            parsed,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let pack = try XCTUnwrap(mapping.project.publishingPacks["es"])

        XCTAssertEqual(mapping.project.title, "Cómo elegir neumáticos para mojado")
        XCTAssertEqual(EscaletaProjectNotes.decode(mapping.project.topic).promise, "Elegir sin gastar de más.")
        XCTAssertEqual(EscaletaProjectNotes.decode(mapping.project.topic).thesis, "La presión importa más que la marca.")
        XCTAssertEqual(pack.chosenTitle, "Neumáticos de lluvia: la presión que nadie mira")
        XCTAssertEqual(pack.titleCandidates, ["Uno", "Dos", "Tres"])
        XCTAssertEqual(pack.description, "Comparamos tres neumáticos con telemetría real.")
        XCTAssertEqual(pack.tags, ["simracing", "lluvia", "guía"])
        XCTAssertEqual(pack.hashtags, ["#simracing", "#lluvia"])
        XCTAssertEqual(pack.pinnedComment, "¿Qué neumático usas tú?")
        XCTAssertEqual(pack.communityPost, "Nuevo vídeo sobre neumáticos de lluvia.")
        XCTAssertTrue(pack.thumbnailConceptNotes.contains("### Concepto A"))
        XCTAssertEqual(pack.chapterOverrides.map(\.title), ["Gancho", "Prueba", "Veredicto"])
        XCTAssertEqual(pack.chapterOverrides.map { Int(($0.startSeconds ?? 0).rounded()) }, [0, 45, 105])
        XCTAssertEqual(mapping.project.sources.count, 1)
        XCTAssertEqual(mapping.project.sources.first?.title, "Reglamento técnico")
    }

    func testStudioDescriptionAddsChaptersAndSourcesWithoutTouchingTheEditableText() {
        let sceneA = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 45)
        let sceneB = makeScene(order: 1, title: "Prueba", text: longText(), estimated: 60)
        let sceneC = makeScene(order: 2, title: "Veredicto", text: longText(), estimated: 45)
        let project = FrameProject(title: "Vídeo", scenes: [sceneA, sceneB, sceneC])
        project.publishingPacks["es"] = PublishingPack(description: "Descripción base.")
        project.sources = [ProjectSource(title: "Fuente", url: "https://example.com/fuente")]
        let state = makeAppState(project: project)
        sceneA.estimatedDuration = 45
        sceneB.estimatedDuration = 60
        sceneC.estimatedDuration = 45

        let studio = state.publishingStudioDescription(language: "es")
        XCTAssertTrue(studio.hasPrefix("Descripción base."))
        XCTAssertTrue(studio.contains("Capítulos"))
        XCTAssertTrue(studio.contains("Fuentes\n- Fuente — https://example.com/fuente"))
        XCTAssertEqual(state.publishingPack(language: "es").description, "Descripción base.")
    }

    // MARK: - AI titles

    func testGeneratingTitlesNeverChangesTheChosenTitleUntilApplied() async {
        let project = makeProject()
        project.publishingPacks["es"] = PublishingPack(chosenTitle: "Título actual")
        let provider = PublishingTestProvider(
            response: #"{"titles":["Propuesta uno","Propuesta dos","Propuesta tres"]}"#
        )
        let state = makeAppState(project: project, provider: provider)

        await state.generatePublishingTitles(language: "es")

        XCTAssertEqual(PublishingPresentation.shared.titleSuggestions.count, 3)
        XCTAssertEqual(state.publishingPack(language: "es").chosenTitle, "Título actual")
        let request = try? XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request?.task, .titlesSEO)
        XCTAssertTrue(request?.systemPrompt.contains("100 characters") == true)
        XCTAssertTrue(request?.userPrompt.contains("Vídeo sintético") == true)

        state.addPublishingTitleSuggestions(
            PublishingPresentation.shared.titleSuggestions,
            language: "es"
        )
        XCTAssertEqual(state.publishingPack(language: "es").titleCandidates.count, 3)
        XCTAssertEqual(state.publishingPack(language: "es").chosenTitle, "Título actual")

        state.usePublishingTitle("Propuesta dos", language: "es")
        XCTAssertEqual(state.publishingPack(language: "es").chosenTitle, "Propuesta dos")
    }

    func testValidationReflectsMetadataAndThumbnailText() {
        let project = makeProject()
        project.publishingPacks["es"] = PublishingPack(
            chosenTitle: String(repeating: "a", count: 101),
            description: String(repeating: "b", count: 4_501),
            tags: (1...21).map { "etiqueta\($0)" },
            hashtags: ["#a", "#b", "#c", "#d"],
            pinnedComment: String(repeating: "c", count: 501),
            thumbnailConceptNotes: "### Concepto A — Cuatro palabras de más"
        )
        let state = makeAppState(project: project)
        let rules = Set(state.publishingValidationIssues(language: "es").map(\.rule))
        XCTAssertTrue(rules.contains(.titleTooLong))
        XCTAssertTrue(rules.contains(.descriptionNearLimit))
        XCTAssertTrue(rules.contains(.tooManyTags))
        XCTAssertTrue(rules.contains(.tooManyHashtags))
        XCTAssertTrue(rules.contains(.pinnedCommentNearLimit))
        XCTAssertTrue(rules.contains(.thumbnailTextTooLong))
    }

    // MARK: - Fixtures

    private func makeAppState(
        project: FrameProject,
        provider: any LLMProviderProtocol = MockLLMProvider(),
        fileURL: URL? = nil
    ) -> AppState {
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.aiPreferences.provider = .openAICompatible
        settings.aiPreferences.enableInlineAutocomplete = false
        let settingsStore = SettingsStore(
            settings: settings,
            userDefaults: defaults,
            key: "FrameScript.settings.v1"
        )
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: fileURL, wordsPerMinute: 150, markUnsaved: true)
        let state = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: settingsStore,
            dependencies: AppDependencies(
                rewriteService: RewriteService(provider: provider),
                analysisService: AnalysisService(provider: provider),
                exportService: ExportService(),
                llmProvider: provider,
                providerCredentials: ProviderCredentialSession(reader: { _ in "test-key" })
            ),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: recordingDefaults),
                defaults: recordingDefaults
            ),
            customTemplates: []
        )
        appState = state
        state.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        return state
    }

    private func makeProject() -> FrameProject {
        let scene = makeScene(order: 0, title: "Gancho", text: longText(), estimated: 40)
        var variant = SceneLanguageVariant(
            languageCode: "en",
            text: "One two three four five six seven eight nine ten.",
            sourceHash: FrameScriptDocument.TextHash.hash(longText())
        )
        variant.estimatedDuration = 35
        scene.languageVariants = [variant]
        return FrameProject(title: "Vídeo sintético", scenes: [scene], primaryLanguage: "es")
    }

    private func makeScene(
        order: Int,
        title: String,
        text: String,
        estimated: TimeInterval
    ) -> Scene {
        Scene(
            order: order,
            sectionType: order == 0 ? .hook : .explanation,
            title: title,
            scriptText: text,
            estimatedDuration: estimated
        )
    }

    private func makeTake(duration: TimeInterval, text: String) -> Take {
        Take(
            number: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: duration,
            rating: .good,
            readText: text,
            sceneTextHash: FrameScriptDocument.TextHash.hash(text)
        )
    }

    private func longText() -> String {
        (1...18).map { "palabra\($0)" }.joined(separator: " ")
    }

    private func makePNG(named name: String) throws -> URL {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

@MainActor
private final class PublishingTestProvider: LLMProviderProtocol {
    private let response: LLMResponse
    private(set) var requests: [LLMRequest] = []

    init(response: String) {
        self.response = LLMResponse(text: response)
    }

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        requests.append(request)
        return response
    }
}
