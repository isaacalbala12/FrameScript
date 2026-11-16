import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

// MARK: - Shared fixture

@MainActor
private final class W3FixCDHFixture {
    let preferences: TestDefaults
    let recording: TestDefaults
    let directory: URL
    let defaults: UserDefaults
    private(set) var states: [AppState] = []

    init() throws {
        preferences = TestDefaults.make()
        recording = TestDefaults.make()
        defaults = preferences.defaults
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("W3FixCDH-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        states.removeAll()
        preferences.cleanup()
        recording.cleanup()
        try? FileManager.default.removeItem(at: directory)
    }

    func makeState(
        project: FrameProject,
        fileURL: URL? = nil,
        language: AppLanguage = .spanish
    ) -> AppState {
        var settings = AppSettings.defaults
        settings.generalPreferences.language = language
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
                rewriteService: RewriteService(provider: MockLLMProvider()),
                analysisService: AnalysisService(provider: MockLLMProvider()),
                exportService: ExportService(),
                llmProvider: MockLLMProvider(),
                providerCredentials: ProviderCredentialSession(reader: { _ in "test-key" })
            ),
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: recording.defaults),
                defaults: recording.defaults
            ),
            customTemplates: []
        )
        states.append(state)
        return state
    }
}

private func w3LongText(_ count: Int = 18) -> String {
    (1...count).map { "palabra\($0)" }.joined(separator: " ")
}

private func w3Scene(
    order: Int,
    title: String,
    text: String? = nil,
    estimated: TimeInterval = 40
) -> AppScene {
    AppScene(
        order: order,
        sectionType: order == 0 ? .hook : .explanation,
        title: title,
        scriptText: text ?? w3LongText(),
        estimatedDuration: estimated
    )
}

private func w3PNG(at url: URL) throws {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()
    let tiff = try XCTUnwrap(image.tiffRepresentation)
    let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try data.write(to: url, options: .atomic)
}

// MARK: - C-1 / C-5

@MainActor
final class W3FixCDHAssetsTests: XCTestCase {
    private var fixture: W3FixCDHFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try W3FixCDHFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    func testW3FixCDHAddedThumbnailSurvivesReachabilityRefresh() async throws {
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)
        let source = fixture.directory.appendingPathComponent("portada.png")
        try w3PNG(at: source)

        let variant = try state.addPublishingThumbnail(from: source, language: "es")
        let before = try XCTUnwrap(project.assets.first(where: { $0.id == variant.assetID }))

        await state.refreshAssetReachability()

        let after = try XCTUnwrap(project.assets.first(where: { $0.id == variant.assetID }))
        XCTAssertEqual(after.path, before.path)
        XCTAssertTrue(AssetPath.isAbsolute(after.path))
        XCTAssertTrue(after.path.contains("Proyecto assets/"))
        XCTAssertFalse(after.isLastKnownMissing)
        let url = try XCTUnwrap(state.publishingThumbnailURL(for: variant))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testW3FixCDHLegacyRelativeThumbnailPathIsMigratedOnLoad() async throws {
        let assetsDirectory = fixture.directory.appendingPathComponent("Proyecto assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let image = assetsDirectory.appendingPathComponent("portada.png")
        try w3PNG(at: image)
        let asset = ProjectAsset(
            path: "Proyecto assets/portada.png",
            kind: .thumbnail,
            isCopiedIntoProject: true
        )
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        project.assets = [asset]
        project.publishingPacks["es"] = PublishingPack(
            thumbnailVariants: [ThumbnailVariant(assetID: asset.id, isChosen: true)]
        )
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)

        await state.refreshAssetReachability()

        let migrated = try XCTUnwrap(project.assets.first)
        XCTAssertEqual(migrated.path, image.path)
        XCTAssertFalse(migrated.isLastKnownMissing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "migration must not move or delete the file")
        let variant = try XCTUnwrap(project.publishingPacks["es"]?.thumbnailVariants.first)
        XCTAssertEqual(state.publishingThumbnailURL(for: variant)?.path, image.path)
    }

    func testW3FixCDHBogusAbsoluteThumbnailPathIsRepairedWithoutLosingTheFile() async throws {
        let assetsDirectory = fixture.directory.appendingPathComponent("Proyecto assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let image = assetsDirectory.appendingPathComponent("portada.png")
        try w3PNG(at: image)
        // Exactly what the pre-fix reachability pass wrote: an absolute path
        // that does not exist, built from a project-relative path.
        let asset = ProjectAsset(
            path: "/Proyecto assets/portada.png",
            kind: .thumbnail,
            isCopiedIntoProject: true
        )
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        project.assets = [asset]
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)

        await state.refreshAssetReachability()

        let repaired = try XCTUnwrap(project.assets.first)
        XCTAssertEqual(repaired.path, image.path)
        XCTAssertFalse(repaired.isLastKnownMissing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }

    func testW3FixCDHReferencedOrForeignThumbnailPathIsNotRepointedToAProjectCopy() async throws {
        let assetsDirectory = fixture.directory.appendingPathComponent("Proyecto assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        try w3PNG(at: assetsDirectory.appendingPathComponent("portada.png"))
        let referenced = ProjectAsset(
            path: "/Old/Proyecto assets/portada.png",
            kind: .thumbnail,
            isCopiedIntoProject: false
        )
        let copiedButForeign = ProjectAsset(
            path: "/Old/portada.png",
            kind: .thumbnail,
            isCopiedIntoProject: true
        )
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        project.assets = [referenced, copiedButForeign]
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)

        await state.refreshAssetReachability()

        let first = try XCTUnwrap(project.assets.first(where: { $0.id == referenced.id }))
        let second = try XCTUnwrap(project.assets.first(where: { $0.id == copiedButForeign.id }))
        XCTAssertEqual(first.path, "/Old/Proyecto assets/portada.png")
        XCTAssertEqual(second.path, "/Old/portada.png")
        XCTAssertTrue(first.isLastKnownMissing)
        XCTAssertTrue(second.isLastKnownMissing)
    }

    func testW3FixCDHRemovingTheOnlyVariantRemovesItsAsset() throws {
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)
        let source = fixture.directory.appendingPathComponent("portada.png")
        try w3PNG(at: source)

        let variant = try state.addPublishingThumbnail(from: source, language: "es")
        XCTAssertEqual(project.assets.count, 1)

        state.removePublishingThumbnail(variantID: variant.id, language: "es")

        XCTAssertTrue(project.assets.isEmpty)
        XCTAssertTrue(project.publishingPacks["es"]?.thumbnailVariants.isEmpty == true)
    }

    func testW3FixCDHRemovingAReferencedAssetClearsPublishingVariants() throws {
        let project = FrameProject(title: "Proyecto", scenes: [w3Scene(order: 0, title: "Gancho")])
        let projectURL = fixture.directory.appendingPathComponent("Proyecto.fscr")
        let state = fixture.makeState(project: project, fileURL: projectURL)
        let source = fixture.directory.appendingPathComponent("portada.png")
        try w3PNG(at: source)
        let variant = try state.addPublishingThumbnail(from: source, language: "es")
        let assetID = try XCTUnwrap(variant.assetID)
        XCTAssertEqual(state.publishingUsageCount(forAssetID: assetID), 1)

        state.removeAsset(id: assetID)

        XCTAssertTrue(project.assets.isEmpty)
        XCTAssertTrue(project.publishingPacks["es"]?.thumbnailVariants.isEmpty == true)
    }
}

// MARK: - D-1 / D-3 / D-6 / N-1

@MainActor
final class W3FixCDHPublishingTests: XCTestCase {
    private var fixture: W3FixCDHFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try W3FixCDHFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    private func makeProject(titles: [String] = ["Gancho", "Prueba", "Veredicto"]) -> FrameProject {
        let scenes = titles.enumerated().map { index, title in
            w3Scene(order: index, title: title)
        }
        return FrameProject(title: "Vídeo sintético", scenes: scenes, primaryLanguage: "es")
    }

    func testW3FixCDHPlainTopicSurvivesTypingAPromise() {
        let project = makeProject()
        project.topic = "Assetto Corsa"
        let state = fixture.makeState(project: project)

        state.setPublishingPromise("Elegir sin gastar de más.")

        XCTAssertEqual(state.publishingPromise, "Elegir sin gastar de más.")
        XCTAssertEqual(BoardProjectTopic.display(from: project.topic), "Assetto Corsa")
        XCTAssertTrue(project.topic.hasPrefix(BoardProjectTopic.marker))
    }

    func testW3FixCDHMarkerNotesAndMetadataSurvivePromiseThesisAndFileRoundTrip() throws {
        let project = makeProject()
        let metadata = EscaletaRoundTripMetadata(
            document: EscaletaDocument(title: "Vídeo sintético"),
            scenes: []
        )
        let originalNotes = EscaletaProjectNotes(
            promise: "Promesa original",
            thesis: "Tesis original",
            versionNote: "v3",
            scriptIntro: "Entrada",
            pacingNotes: ["rápido", "pausa"],
            metadata: metadata
        )
        let encoded = Data("Assetto Corsa".utf8).base64EncodedString()
        project.topic = BoardProjectTopic.marker + encoded + "\n\n" + originalNotes.encoded()
        let state = fixture.makeState(project: project)

        state.setPublishingPromise("Promesa nueva")
        state.setPublishingThesis("Tesis nueva")

        let notes = EscaletaProjectNotes.decode(project.topic)
        XCTAssertEqual(BoardProjectTopic.display(from: project.topic), "Assetto Corsa")
        XCTAssertEqual(notes.promise, "Promesa nueva")
        XCTAssertEqual(notes.thesis, "Tesis nueva")
        XCTAssertEqual(notes.versionNote, "v3")
        XCTAssertEqual(notes.scriptIntro, "Entrada")
        XCTAssertEqual(notes.pacingNotes, ["rápido", "pausa"])
        XCTAssertNotNil(notes.metadata)

        let url = fixture.directory.appendingPathComponent("Proyecto.fscr")
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(BoardProjectTopic.display(from: loaded.topic), "Assetto Corsa")
        XCTAssertEqual(EscaletaProjectNotes.decode(loaded.topic).promise, "Promesa nueva")
        XCTAssertEqual(EscaletaProjectNotes.decode(loaded.topic).versionNote, "v3")

        state.setPublishingPromise("")
        XCTAssertEqual(BoardProjectTopic.display(from: project.topic), "Assetto Corsa")
        XCTAssertEqual(EscaletaProjectNotes.decode(project.topic).versionNote, "v3")
    }

    func testW3FixCDHImportedChapterWithoutSceneReachesBothExports() {
        let project = makeProject()
        let scenes = project.scenes.sortedByOrder
        scenes[0].estimatedDuration = 30
        scenes[1].estimatedDuration = 60
        scenes[2].estimatedDuration = 30
        project.publishingPacks["es"] = PublishingPack(
            chapterOverrides: [
                ChapterOverride(
                    sceneID: nil,
                    title: "Capítulo importado",
                    startSeconds: 100
                )
            ]
        )
        let state = fixture.makeState(project: project)

        let markdown = state.publishingExportMarkdown(language: "es")
        let studio = state.publishingStudioDescription(language: "es")

        XCTAssertTrue(markdown.contains("1:40 Capítulo importado"))
        XCTAssertTrue(studio.contains("1:40 Capítulo importado"))
    }

    func testW3FixCDHImporterKeepsTwoChaptersInsideOneScene() {
        let markdown = """
        # Prueba

        ## Escaleta

        1. Gancho
        2. Prueba
        3. Cierre

        ---

        # Guion

        ## 0:00 — Gancho

        Texto de gancho con varias palabras para que dure lo suficiente.

        ## 1:00 — Prueba

        Texto de prueba con varias palabras para que dure lo suficiente.

        ## 3:00 — Cierre

        Texto de cierre con varias palabras para que dure lo suficiente.

        ---

        # Paquete SEO

        ## Título recomendado

        Prueba de capítulos

        ## Descripción

        Descripción de prueba.

        ## Capítulos

        00:00 Gancho
        01:00 Prueba
        01:30 Vuelta rápida
        03:00 Cierre
        """
        let parsed = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            parsed,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let pack = try? XCTUnwrap(mapping.project.publishingPacks["es"])
        let overrides = pack?.chapterOverrides ?? []
        let oneMinute = overrides.first { Int(($0.startSeconds ?? 0).rounded()) == 60 }
        let oneThirty = overrides.first { Int(($0.startSeconds ?? 0).rounded()) == 90 }

        XCTAssertNotNil(oneMinute?.sceneID)
        XCTAssertNil(oneThirty?.sceneID, "the second chapter in a scene must stay imported, not vanish")

        // Keep the scenes long enough that the generated plan has all three
        // chapter starts; the imported 1:30 is still the extra one.
        let state = fixture.makeState(project: mapping.project)
        for scene in mapping.project.scenes {
            scene.estimatedDuration = 60
        }
        let exported = state.publishingExportMarkdown(language: "es")
        XCTAssertTrue(exported.contains("1:00 Prueba"))
        XCTAssertTrue(exported.contains("1:30 Vuelta rápida"))
        XCTAssertTrue(state.publishingStudioDescription(language: "es").contains("1:30 Vuelta rápida"))
    }

    func testW3FixCDHUnsortedImportedChaptersClaimTheSceneInTimeOrder() {
        let markdown = """
        # Prueba

        ## Escaleta

        1. Gancho
        2. Prueba
        3. Cierre

        ---

        # Guion

        ## 0:00 — Gancho

        Texto de gancho con varias palabras para que dure lo suficiente.

        ## 1:00 — Prueba

        Texto de prueba con varias palabras para que dure lo suficiente.

        ## 3:00 — Cierre

        Texto de cierre con varias palabras para que dure lo suficiente.

        ---

        # Paquete SEO

        ## Título recomendado

        Prueba de capítulos

        ## Descripción

        Descripción de prueba.

        ## Capítulos

        00:00 Gancho
        02:00 Segunda
        01:30 Primera
        03:00 Cierre
        """
        let parsed = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            parsed,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let overrides = mapping.project.publishingPacks["es"]?.chapterOverrides ?? []
        let primera = overrides.first { Int(($0.startSeconds ?? 0).rounded()) == 90 }
        let segunda = overrides.first { Int(($0.startSeconds ?? 0).rounded()) == 120 }

        XCTAssertEqual(primera?.title, "Primera")
        XCTAssertNotNil(primera?.sceneID, "the earliest range chapter must claim the scene")
        XCTAssertEqual(segunda?.title, "Segunda")
        XCTAssertNil(segunda?.sceneID, "the later chapter in the same scene must stay imported")
    }

    func testW3FixCDHFooterIsNotReadyWithAnEmptyPackAndTwoOfEightChecks() {
        let project = makeProject()
        let state = fixture.makeState(project: project)
        state.setPublishingChecklist(.chosenTitle, done: true)
        state.setPublishingChecklist(.tags, done: true)
        let issues = state.publishingValidationIssues(language: "es")
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count

        let summary = state.publishingFooterSummaryText(errors: errors, warnings: warnings)

        XCTAssertFalse(summary.contains("Todo listo"))
        XCTAssertTrue(summary.contains("2/8"))
        XCTAssertGreaterThan(warnings, 0, "an empty title and description must warn")
    }

    func testW3FixCDHFooterIsReadyOnlyWithCompleteChecklistAndNoIssues() {
        let project = makeProject()
        let state = fixture.makeState(project: project)
        state.updatePublishingPack(language: "es") { pack in
            pack.chosenTitle = "Un título válido"
            pack.description = "Una descripción válida."
        }
        for item in PublishingChecklistItem.allCases {
            state.setPublishingChecklist(item, done: true)
        }
        let issues = state.publishingValidationIssues(language: "es")

        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(
            state.publishingFooterSummaryText(errors: 0, warnings: 0),
            state.localized("publishing.validation.ok")
        )
    }

    func testW3FixCDHStudioDescriptionLengthIsCheckedByTheAppValidator() {
        let project = makeProject()
        project.publishingPacks["es"] = PublishingPack(
            chosenTitle: "Título",
            description: String(repeating: "x", count: 4_900)
        )
        project.publishingPacks["es"]?.chapterOverrides = (0..<15).map { index in
            ChapterOverride(
                sceneID: nil,
                title: "Capítulo \(index)",
                startSeconds: TimeInterval(index * 20)
            )
        }
        let state = fixture.makeState(project: project)

        let rules = Set(state.publishingValidationIssues(language: "es").map(\.rule))

        XCTAssertTrue(rules.contains(.studioDescriptionTooLong))
    }
}

// MARK: - H-1 / H-5 / N-6 / N-7

@MainActor
final class W3FixCDHResolvePackTests: XCTestCase {
    private var fixture: W3FixCDHFixture!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try W3FixCDHFixture()
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    private func makeProject(title: String = "Prueba sintética") -> FrameProject {
        let scenes = [
            w3Scene(order: 0, title: "Gancho", estimated: 40),
            w3Scene(order: 1, title: "Prueba en mojado", estimated: 40),
            w3Scene(order: 2, title: "Patrocinio", estimated: 40),
            w3Scene(order: 3, title: "Veredicto", estimated: 40)
        ]
        return FrameProject(title: title, scenes: scenes, primaryLanguage: "es")
    }

    func testW3FixCDHChaptersFileUsesThePublishingOverrides() throws {
        let project = makeProject()
        let scenes = project.scenes.sortedByOrder
        project.publishingPacks["es"] = PublishingPack(
            chapterOverrides: [
                ChapterOverride(sceneID: scenes[1].id, title: "La prueba de verdad", startSeconds: 40),
                ChapterOverride(sceneID: scenes[2].id, title: "", startSeconds: 80, isExcluded: true),
                ChapterOverride(sceneID: nil, title: "Vuelta rápida", startSeconds: 100)
            ]
        )
        let state = fixture.makeState(project: project)
        for scene in project.scenes {
            scene.estimatedDuration = 40
        }
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let plan = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))

        XCTAssertTrue(plan.chapters.text.contains("La prueba de verdad"))
        XCTAssertFalse(plan.chapters.text.contains("Patrocinio"))
        XCTAssertTrue(plan.chapters.text.contains("1:40 Vuelta rápida"))
        let file = ResolveDeliveryPack.files(for: plan).first { $0.name == plan.names.chapters }
        XCTAssertEqual(file?.text, plan.chapters.text + "\n")
    }

    func testW3FixCDHRehookAtSceneStartSurvivesWhenALaterRehookExists() throws {
        let text = "uno dos tres cuatro cinco seis siete ocho nueve diez"
        let firstAnchor = TextAnchor(
            startUTF16: 0,
            lengthUTF16: 3,
            selectedText: "uno"
        )
        let laterRange = (text as NSString).range(of: "cinco")
        let laterAnchor = TextAnchor(
            startUTF16: laterRange.location,
            lengthUTF16: laterRange.length,
            selectedText: "cinco"
        )
        let scene = w3Scene(order: 0, title: "Problema", text: text, estimated: 10)
        scene.editingItems = [
            EditingItem(
                textAnchor: firstAnchor,
                templateType: "",
                cutStyle: "RE-HOOK",
                transition: "",
                subtitleStyle: ""
            ),
            EditingItem(
                textAnchor: laterAnchor,
                templateType: "",
                cutStyle: "RE-HOOK",
                transition: "",
                subtitleStyle: ""
            )
        ]
        let project = FrameProject(title: "Prueba", scenes: [scene], primaryLanguage: "es")
        let mapper = ResolveSceneMapper(
            languageCode: "es",
            durationSource: .estimates,
            wordsPerMinute: 150,
            pauseDefaults: .standard
        )
        let mapping = mapper.map(project: project)
        let exported = try XCTUnwrap(mapping.scenes.first)

        XCTAssertTrue(exported.isRehook)
        XCTAssertTrue(exported.emitsSceneRehookMarker, "the 0:00 re-hook must keep its start marker")

        let options = try XCTUnwrap(
            ResolvePackConfiguration.defaults(languageCode: "es").options()
        )
        let plan = ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: "Prueba",
            options: options
        )
        XCTAssertEqual(plan.allMarkers.filter { $0.kind == .rehook }.count, 1)
        XCTAssertEqual(plan.allMarkers.filter { $0.color == .purple }.count, 2)
    }

    func testW3FixCDHExportFlushesTheLatestConfiguration() throws {
        let project = makeProject()
        for scene in project.scenes {
            scene.estimatedDuration = 40
        }
        let state = fixture.makeState(project: project)
        let controller = ResolvePackPlanRefreshController()
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        controller.refreshNow(appState: state, configuration: configuration)
        XCTAssertEqual(
            controller.plan?.settings.startTimecode.string(rate: .fps25, dropFrame: false),
            "01:00:00:00"
        )

        configuration.startTimecodeText = "00:59:50:00"
        controller.schedule(appState: state, configuration: configuration)
        let fresh = controller.flushForExport(appState: state, configuration: configuration)

        XCTAssertEqual(
            fresh?.settings.startTimecode.string(rate: .fps25, dropFrame: false),
            "00:59:50:00"
        )
        XCTAssertEqual(
            controller.plan?.settings.startTimecode.string(rate: .fps25, dropFrame: false),
            "00:59:50:00"
        )
    }

    func testW3FixCDHFCPXMLChapterMarkersUseTheTimelineFrames() throws {
        let project = FrameProject(
            title: "Prueba sintética",
            scenes: [
                w3Scene(order: 0, title: "Gancho", text: w3LongText(100), estimated: 40),
                w3Scene(order: 1, title: "Prueba en mojado", text: w3LongText(100), estimated: 40),
                w3Scene(order: 2, title: "Cierre", text: w3LongText(100), estimated: 40)
            ],
            primaryLanguage: "es"
        )
        let scenes = project.scenes.sortedByOrder
        let firstText = scenes[0].scriptText
        scenes[0].takes = [
            Take(
                number: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 30,
                rating: .good,
                readText: firstText,
                sceneTextHash: FrameScriptDocument.TextHash.hash(firstText)
            )
        ]
        let state = fixture.makeState(project: project)
        for scene in scenes {
            scene.estimatedDuration = 40
        }
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        configuration.durationSource = .estimates
        let plan = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))

        // The pasteable file follows Publishing (real take: 0:30); the timeline
        // markers must follow the Resolve-sheet duration (estimate: 0:40).
        XCTAssertTrue(plan.chapters.text.contains("0:30"))
        XCTAssertTrue(plan.timelineChapters.text.contains("0:40"))
        XCTAssertNotEqual(plan.chapters.text, plan.timelineChapters.text)
        XCTAssertTrue(plan.warningItems.contains { $0.kind.isChapterListsDiffer })

        let files = ResolveDeliveryPack.files(for: plan)
        let xml = try XCTUnwrap(
            files.first { $0.name == plan.names.fcpxml }?.text
        )
        let document = try XMLDocument(data: Data(xml.utf8))
        let chapterMarkers = try document.nodes(forXPath: "//chapter-marker")
            .compactMap { $0 as? XMLElement }
        let sceneMarkers = try document.nodes(forXPath: "//marker")
            .compactMap { $0 as? XMLElement }
        XCTAssertFalse(chapterMarkers.isEmpty)

        for chapter in plan.timelineChapters.chapters {
            guard let sceneID = chapter.sceneID,
                  let sceneIndex = plan.scenes.firstIndex(where: { $0.id == sceneID }) else {
                continue
            }
            let scene = plan.scenes[sceneIndex]
            let expectedFrame = Timecode(
                seconds: max(0, scene.start),
                rate: plan.settings.fps
            ).frames
            XCTAssertEqual(chapter.startFrame, expectedFrame)

            let title = scene.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let sceneMarkerValue = String(format: "%02d", sceneIndex)
                + " " + (title.isEmpty ? "Escena" : title)
            let sceneStart = try XCTUnwrap(
                sceneMarkers.first {
                    $0.attribute(forName: "value")?.stringValue == sceneMarkerValue
                }?.attribute(forName: "start")?.stringValue
            )
            let chapterStart = try XCTUnwrap(
                chapterMarkers.first {
                    $0.attribute(forName: "value")?.stringValue == chapter.title
                }?.attribute(forName: "start")?.stringValue
            )
            XCTAssertEqual(
                chapterStart,
                sceneStart,
                "chapter \(chapter.title) does not start with its scene marker"
            )
        }
    }

    func testW3FixCDHUnlinkedClaimProducesAWarning() throws {
        let project = makeProject()
        let claim = ProjectClaim(
            text: "El circuito cuesta 40 millones",
            status: .probable,
            sceneIDs: []
        )
        project.claims = [claim]
        let state = fixture.makeState(project: project)
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let plan = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))

        XCTAssertTrue(plan.warningItems.contains { item in
            if case let .unlinkedClaim(_, text) = item.kind { return text == claim.text }
            return false
        })
        XCTAssertTrue(plan.warnings.contains { $0.contains(claim.text) })
    }

    func testW3FixCDHEnglishPackDoesNotLeakSpanishChapterWarnings() throws {
        let project = FrameProject(
            title: "Dos escenas",
            scenes: [
                w3Scene(order: 0, title: "Uno", estimated: 20),
                w3Scene(order: 1, title: "Dos", estimated: 20)
            ],
            primaryLanguage: "es"
        )
        let state = fixture.makeState(project: project, language: .english)
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let plan = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))
        let chapterWarnings = plan.warningItems.filter { item in
            if case .chapter = item.kind { return true }
            return false
        }

        XCTAssertFalse(chapterWarnings.isEmpty)
        for warning in chapterWarnings {
            let english = warning.localizedMessage(language: .english)
            XCTAssertFalse(english.contains("capítulos"))
            XCTAssertFalse(english.contains("escena"))
        }
    }

    func testW3FixCDHInvalidChaptersAreOmittedUnlessTheUserOptsIn() throws {
        let project = FrameProject(
            title: "Dos escenas",
            scenes: [
                w3Scene(order: 0, title: "Uno", estimated: 20),
                w3Scene(order: 1, title: "Dos", estimated: 20)
            ],
            primaryLanguage: "es"
        )
        let state = fixture.makeState(project: project)
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let plan = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))

        XCTAssertFalse(plan.chapters.isValidForYouTube)
        XCTAssertFalse(ResolveDeliveryPack.files(for: plan).contains { $0.name == plan.names.chapters })
        XCTAssertTrue(plan.warningItems.contains { item in
            if case .chaptersOmitted = item.kind { return true }
            return false
        })

        configuration.writeInvalidChapters = true
        let forced = try XCTUnwrap(state.makeResolvePackPlan(configuration: configuration))
        XCTAssertTrue(ResolveDeliveryPack.files(for: forced).contains { $0.name == forced.names.chapters })
    }
}

// MARK: - D-5 / D-4

@MainActor
final class W3FixCDHThemeAndThumbnailTests: XCTestCase {
    func testW3FixCDHAccentTextMeetsContrastOnEverySurface() {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentPalette.allCases {
                let theme = FrameTheme(colorScheme: scheme, accent: accent)
                let text = NSColor(theme.accentText)
                for surface in theme.textSurfaces {
                    let ratio = MarkupEditorPalette.contrastRatio(text, NSColor(surface))
                    XCTAssertGreaterThanOrEqual(
                        ratio,
                        4.49,
                        "\(accent) \(scheme) on \(surface): \(ratio)"
                    )
                }
            }
        }
    }

    func testW3FixCDHThumbnailCardDoesNotReloadWhenOnlyThePairedTitleChanges() async {
        let loader = W3FixCDHCountingImageLoader()
        let model = PublishingThumbnailCardImageModel()
        let asset = ProjectAsset(path: "/tmp/portada.png", kind: .thumbnail)
        let directory = FileManager.default.temporaryDirectory

        await model.update(asset: asset, projectDirectory: directory, loader: loader)
        XCTAssertEqual(model.loadCount, 1)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertFalse(model.isLoading)

        // A paired-title keystroke leaves the resource identical.
        await model.update(asset: asset, projectDirectory: directory, loader: loader)
        XCTAssertEqual(model.loadCount, 1)
        XCTAssertEqual(loader.calls, 1)

        var changed = asset
        changed.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await model.update(asset: changed, projectDirectory: directory, loader: loader)
        XCTAssertEqual(model.loadCount, 2)
        XCTAssertEqual(loader.calls, 2)
    }

    func testW3FixCDHChapterWarningIsLocalized() {
        let warning = ChapterWarning(
            kind: .tooFewChapters,
            message: "YouTube necesita al menos 3 capítulos y solo se han podido formar 2.",
            chapterCount: 2
        )

        let english = warning.localizedMessage(language: .english)
        let spanish = warning.localizedMessage(language: .spanish)

        XCTAssertTrue(english.contains("3 chapters"))
        XCTAssertFalse(english.contains("capítulos"))
        XCTAssertTrue(spanish.contains("capítulos"))
    }
}

@MainActor
private final class W3FixCDHCountingImageLoader: ThumbnailCardImageLoading {
    private(set) var calls = 0

    func image(for asset: ProjectAsset, projectDirectory: URL?) async -> NSImage? {
        calls += 1
        return NSImage(size: NSSize(width: 4, height: 4))
    }
}

private extension ResolvePackWarning.Kind {
    var isChapterListsDiffer: Bool {
        if case .chapterListsDiffer = self { return true }
        return false
    }
}
