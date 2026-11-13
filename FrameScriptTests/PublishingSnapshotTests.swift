import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

@MainActor
final class PublishingSnapshotTests: XCTestCase {
    private var suiteName = ""
    private var recordingSuiteName = ""
    private var defaults: UserDefaults!
    private var recordingDefaults: UserDefaults!
    private var temporaryDirectory: URL!
    private var appState: AppState!

    private static let snapshotDirectory = URL(
        fileURLWithPath: "/tmp/fs-snapshots/w3-d-publishing",
        isDirectory: true
    )
    private static let windowSizes = [
        CGSize(width: 1180, height: 760),
        CGSize(width: 980, height: 712),
    ]

    override func setUp() {
        super.setUp()
        suiteName = "FrameScript.PublishingSnapshotTests.\(UUID().uuidString)"
        recordingSuiteName = "\(suiteName).recording"
        defaults = UserDefaults(suiteName: suiteName)
        recordingDefaults = UserDefaults(suiteName: recordingSuiteName)
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublishingSnapshots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        PublishingPresentation.shared.resetTitleGeneration()
        appState = makeAppState()
    }

    override func tearDown() {
        appState = nil
        if !suiteName.isEmpty {
            defaults?.removePersistentDomain(forName: suiteName)
            let plist = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        if !recordingSuiteName.isEmpty {
            UserDefaults(suiteName: recordingSuiteName)?.removePersistentDomain(forName: recordingSuiteName)
            let plist = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Preferences/\(recordingSuiteName).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        PublishingPresentation.shared.resetTitleGeneration()
        super.tearDown()
    }

    // MARK: - Layout invariants

    func testPanelGeometryFitsTheMinimumWindow() {
        XCTAssertGreaterThan(PublishingMetrics.contentHeight, 0)
        XCTAssertLessThanOrEqual(PublishingMetrics.panelWidth, 980)
        XCTAssertLessThanOrEqual(PublishingMetrics.panelHeight, 712)
        XCTAssertEqual(
            PublishingMetrics.headerHeight
                + PublishingMetrics.tabBarHeight
                + PublishingMetrics.footerHeight
                + 3
                + PublishingMetrics.contentHeight,
            PublishingMetrics.panelHeight
        )
    }

    func testAllPublishingCopyIsSpanish() {
        XCTAssertEqual(appState.currentLanguage, .spanish)
        XCTAssertEqual(appState.localized("publishing.title"), "Publicación")
        XCTAssertEqual(appState.localized("publishing.tab.metadata"), "Metadatos")
        XCTAssertEqual(appState.localized("publishing.tab.chapters"), "Capítulos")
        XCTAssertEqual(appState.localized("publishing.tab.thumbnails"), "Miniaturas")
        XCTAssertEqual(appState.localized("publishing.tab.checklist"), "Checklist")
        XCTAssertEqual(appState.localized("publishing.checklist.chosenTitle"), "Título elegido")
        XCTAssertEqual(appState.localized("publishing.titles.generate"), "Generar títulos")
        XCTAssertEqual(appState.localized("publishing.chapters.valid"), "Cumple las reglas de YouTube")
        XCTAssertEqual(appState.publishingPack(language: "es").chosenTitle, "Neumáticos de lluvia: la presión que nadie mira")
    }

    // MARK: - Panel tabs

    func testPublishingPanelSnapshots() throws {
        for window in Self.windowSizes {
            for scheme in [ColorScheme.light, .dark] {
                for tab in PublishingTab.allCases {
                    let view = PublishingPanel(initialTab: tab, initialLanguage: "es")
                    try render(
                        view,
                        name: "publishing-\(tab.rawValue)-\(sizeName(window))-\(schemeName(scheme))",
                        windowSize: window,
                        scheme: scheme
                    )
                }
            }
        }
    }

    // MARK: - Validation state

    func testMetadataWithValidationIssuesSnapshots() throws {
        var pack = appState.publishingPack(language: "es")
        pack.chosenTitle = String(repeating: "Título largo ", count: 10)
        pack.description = String(repeating: "x", count: 4_600)
        pack.tags = (1...21).map { "etiqueta\($0)" }
        pack.hashtags = ["#a", "#b", "#c", "#d"]
        pack.pinnedComment = String(repeating: "y", count: 501)
        pack.thumbnailConceptNotes = """
        ### Concepto A — Una dos tres cuatro
        Idea: Demasiadas palabras para una miniatura.
        """
        appState.updatePublishingPack(language: "es") { $0 = pack }

        for window in Self.windowSizes {
            for scheme in [ColorScheme.light, .dark] {
                try render(
                    PublishingPanel(initialTab: .metadata, initialLanguage: "es"),
                    name: "publishing-metadata-issues-\(sizeName(window))-\(schemeName(scheme))",
                    windowSize: window,
                    scheme: scheme
                )
            }
        }
    }

    // MARK: - Sheets

    func testPublishingSheetsSnapshots() throws {        let input = appState.publishingExportInput(language: "es")
        let suggestions = [
            "La presión que cambia el neumático de lluvia",
            "Tres neumáticos de lluvia: cuál elegir",
            "Probamos la presión que casi nadie usa en mojado",
        ]
        let diff = ChapterRegenerationDiff(
            titleChanges: [
                ChapterTitleChange(
                    sceneID: UUID(),
                    oldTitle: "Mi gancho",
                    newTitle: "Gancho"
                ),
                ChapterTitleChange(
                    sceneID: UUID(),
                    oldTitle: "La prueba de verdad",
                    newTitle: "Prueba en mojado"
                ),
            ],
            removedImportedTitles: ["Capítulo importado de la escaleta"]
        )

        for window in Self.windowSizes {
            for scheme in [ColorScheme.light, .dark] {
                try render(
                    PublishingExportSheet(language: "es"),
                    name: "publishing-export-\(sizeName(window))-\(schemeName(scheme))",
                    windowSize: window,
                    scheme: scheme
                )
                try render(
                    PublishingTitleSuggestionsSheet(language: "es", suggestions: suggestions),
                    name: "publishing-title-suggestions-\(sizeName(window))-\(schemeName(scheme))",
                    windowSize: window,
                    scheme: scheme
                )
                try render(
                    ChapterRegenerationSheet(
                        diff: diff,
                        onKeep: {},
                        onReplace: {},
                        onCancel: {}
                    ),
                    name: "publishing-chapter-diff-\(sizeName(window))-\(schemeName(scheme))",
                    windowSize: window,
                    scheme: scheme
                )
            }
        }

        XCTAssertEqual(input.chapters.count, 4)
    }

    // MARK: - Rendering

    private func render<V: View>(
        _ view: V,
        name: String,
        windowSize: CGSize,
        scheme: ColorScheme
    ) throws {
        let theme = FrameTheme(colorScheme: scheme, accent: .sage)
        let root = ZStack {
            theme.appBackground
            view
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .environment(appState)
        .environment(\.frameTheme, theme)
        .environment(\.colorScheme, scheme)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hostingView.wantsLayer = true
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.bounds.width, 0, "\(name) has no width")
        XCTAssertGreaterThan(hostingView.bounds.height, 0, "\(name) has no height")
        let fitting = hostingView.fittingSize
        XCTAssertLessThanOrEqual(fitting.width, windowSize.width + 1, "\(name) clips horizontally")
        XCTAssertLessThanOrEqual(fitting.height, windowSize.height + 1, "\(name) clips vertically")

        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("\(name) could not create a bitmap")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            XCTFail("\(name) could not encode a PNG")
            return
        }

        XCTAssertGreaterThan(representation.pixelsWide, 0, "\(name) has no pixels")
        XCTAssertGreaterThan(representation.pixelsHigh, 0, "\(name) has no pixel height")
        XCTAssertGreaterThan(png.count, 8_000, "\(name) looks blank")

        let colors = sampledColors(representation)
        XCTAssertGreaterThan(colors, 8, "\(name) has too little visible content")

        if snapshotsEnabled {
            try FileManager.default.createDirectory(
                at: Self.snapshotDirectory,
                withIntermediateDirectories: true
            )
            try png.write(to: Self.snapshotDirectory.appendingPathComponent("\(name).png"))
        }
    }

    private func sampledColors(_ representation: NSBitmapImageRep) -> Int {
        var colors = Set<String>()
        let stepX = max(1, representation.pixelsWide / 60)
        let stepY = max(1, representation.pixelsHigh / 50)
        for x in stride(from: 0, to: representation.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: representation.pixelsHigh, by: stepY) {
                guard let color = representation.colorAt(x: x, y: y) else { continue }
                let key = "\(Int(color.redComponent * 255))-\(Int(color.greenComponent * 255))-\(Int(color.blueComponent * 255))"
                colors.insert(key)
            }
        }
        return colors.count
    }

    private var snapshotsEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["FS_SNAPSHOTS"] == "1"
            || environment["TEST_RUNNER_FS_SNAPSHOTS"] == "1"
    }

    private func sizeName(_ size: CGSize) -> String {
        "\(Int(size.width))x\(Int(size.height))"
    }

    private func schemeName(_ scheme: ColorScheme) -> String {
        scheme == .dark ? "dark" : "light"
    }

    // MARK: - Synthetic project

    private func makeAppState() -> AppState {
        let project = makeProject()
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
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)
        return AppState(
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
                preferences: OBSPreferencesStore(defaults: recordingDefaults),
                defaults: recordingDefaults
            ),
            customTemplatesLoader: { [] }
        )
    }

    private func makeProject() -> FrameProject {
        let scenes = [
            makeScene(order: 0, section: .hook, title: "Gancho", words: 110),
            makeScene(order: 1, section: .explanation, title: "Qué cambia", words: 150),
            makeScene(order: 2, section: .explanation, title: "Prueba en mojado", words: 180),
            makeScene(order: 3, section: .takeaway, title: "Veredicto", words: 120),
        ]
        scenes[0].languageVariants = [
            SceneLanguageVariant(
                languageCode: "en",
                text: "Synthetic translated script for the snapshot fixture.",
                sourceHash: FrameScriptDocument.TextHash.hash(scenes[0].scriptText)
            )
        ]

        let thumbnailURL = temporaryDirectory.appendingPathComponent("snapshot-thumb.png")
        if let image = makePNG() {
            try? image.write(to: thumbnailURL)
        }
        let asset = ProjectAsset(
            path: thumbnailURL.path,
            kind: .thumbnail,
            isCopiedIntoProject: true
        )

        let project = FrameProject(
            title: "Cómo elegir neumáticos para mojado",
            scenes: scenes,
            primaryLanguage: "es"
        )
        project.topic = EscaletaProjectNotes(
            promise: "Elegir el neumático correcto sin gastar de más.",
            thesis: "La presión importa más que la marca."
        ).encoded()
        project.videoType = "Prueba comparativa"
        project.targetDuration = 12 * 60
        project.assets = [asset]
        project.sources = [
            ProjectSource(title: "Reglamento técnico", url: "https://example.com/reglamento"),
            ProjectSource(title: "Notas de la prueba", note: "Prueba sintética en mojado."),
        ]
        project.checklistTasks = [
            ChecklistTask(text: PublishingChecklistItem.chosenTitle.taskToken, kind: .other, isDone: true),
            ChecklistTask(text: PublishingChecklistItem.tags.taskToken, kind: .other, isDone: true),
        ]
        project.publishingPacks["es"] = PublishingPack(
            titleCandidates: [
                "Neumáticos de lluvia: la presión que nadie mira",
                "Probamos tres neumáticos de lluvia en el mismo circuito",
                "Qué neumático de lluvia comprar según tu ritmo",
            ],
            chosenTitle: "Neumáticos de lluvia: la presión que nadie mira",
            description: "Comparamos tres neumáticos de lluvia con telemetría real. Al final tienes una recomendación concreta para tu coche y tu ritmo.",
            tags: ["simracing", "neumáticos de lluvia", "iRacing", "guía de compra"],
            hashtags: ["#simracing", "#iRacing", "#lluvia"],
            pinnedComment: "¿Qué neumático usas tú cuando llueve? Cuéntamelo en los comentarios.",
            communityPost: "Nuevo vídeo: comparamos tres neumáticos de lluvia con telemetría real.",
            chapterOverrides: [
                ChapterOverride(sceneID: scenes[0].id, title: "", startSeconds: 0, isExcluded: false),
                ChapterOverride(sceneID: scenes[1].id, title: "", startSeconds: 45, isExcluded: false),
                ChapterOverride(sceneID: scenes[2].id, title: "La prueba de verdad", startSeconds: 105, isExcluded: false),
                ChapterOverride(sceneID: scenes[3].id, title: "", startSeconds: 165, isExcluded: false),
            ],
            thumbnailVariants: [
                ThumbnailVariant(assetID: asset.id, pairedTitle: "Neumáticos de lluvia: la presión que nadie mira", isChosen: true),
                ThumbnailVariant(assetID: asset.id, pairedTitle: "Tres neumáticos, una decisión", isChosen: false),
            ],
            thumbnailConceptNotes: """
            ### Concepto A — La presión manda
            Idea: Enfrentar dos ruedas idénticas con presiones distintas.
            Composición:
            - Rueda a la izquierda
            - Manómetro a la derecha
            Por qué funciona: El contraste se entiende en un segundo.

            ### Concepto B — Tres datos
            Idea: Mostrar los tres números de la prueba.
            Por qué funciona: Es legible a tamaño móvil.
            """
        )
        project.publishingPacks["en"] = PublishingPack(
            chosenTitle: "Wet tyres: the pressure nobody checks",
            description: "Synthetic English publishing pack for layout checks."
        )
        return project
    }

    private func makeScene(order: Int, section: SectionType, title: String, words: Int) -> AppScene {
        let text = (1...words).map { "palabra\($0)" }.joined(separator: " ")
        return AppScene(
            order: order,
            sectionType: section,
            title: title,
            scriptText: text,
            estimatedDuration: Double(words) / 150 * 60
        )
    }

    private func makePNG() -> Data? {
        let image = NSImage(size: NSSize(width: 32, height: 18))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 18).fill()
        NSColor.systemYellow.setFill()
        NSRect(x: 6, y: 4, width: 14, height: 10).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
