import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import Vision
import XCTest

@testable import FrameScript

@MainActor
final class AVScriptTests: XCTestCase {
    private var harness: AVTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try AVTestHarness()
        harness.appState.editorState.selectedSceneID = harness.scene.id
        harness.appState.editorState.selectedMode = .avScript
    }

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testDocumentPairsItemsWithTheirParagraphs() {
        let document = harness.appState.avScriptDocument()

        XCTAssertEqual(document.scenes.count, 2)
        XCTAssertEqual(document.scenes[0].rows.count, 3)
        XCTAssertEqual(document.scenes[0].rows[1].annotations.count, 1)
        XCTAssertEqual(document.scenes[0].rows[1].annotations.first?.kind, .bRoll)
        XCTAssertEqual(document.scenes[0].rows[1].annotations.first?.text, "Plano de la curva Eau Rouge")
        XCTAssertEqual(document.scenes[0].rows[2].annotations.first?.kind, .editing)
        XCTAssertTrue(document.scenes[0].rows.allSatisfy { !$0.isUnanchored })
    }

    func testAddingVisualAnchorsToTheParagraph() throws {
        let document = harness.appState.avScriptDocument()
        let paragraph = try XCTUnwrap(document.scenes[0].rows[0].paragraph)

        let id = try XCTUnwrap(
            harness.appState.addAVAnnotation(
                sceneID: harness.scene.id,
                paragraphRange: paragraph.range.nsRange,
                kind: .bRoll
            )
        )

        let item = try XCTUnwrap(harness.scene.bRollItems.first { $0.id == id })
        XCTAssertEqual(item.textAnchor?.selectedText, paragraph.text)
        XCTAssertEqual(item.sourceType, .custom)
        XCTAssertTrue(item.descriptionText.isEmpty)

        let updated = harness.appState.avScriptDocument()
        XCTAssertEqual(updated.scenes[0].rows[0].annotations.filter { $0.id == id }.count, 1)
    }

    func testAddingEditingNoteAnchorsToTheParagraph() throws {
        let document = harness.appState.avScriptDocument()
        let paragraph = try XCTUnwrap(document.scenes[0].rows[1].paragraph)

        let id = try XCTUnwrap(
            harness.appState.addAVAnnotation(
                sceneID: harness.scene.id,
                paragraphRange: paragraph.range.nsRange,
                kind: .editing
            )
        )

        let item = try XCTUnwrap(harness.scene.editingItems.first { $0.id == id })
        XCTAssertEqual(item.textAnchor?.selectedText, paragraph.text)
        XCTAssertEqual(item.status, .pending)

        let updated = harness.appState.avScriptDocument()
        XCTAssertEqual(updated.scenes[0].rows[1].annotations.filter { $0.id == id }.count, 1)
    }

    func testDeletingParagraphMovesItsItemToTheUnanchoredGroup() throws {
        let text = harness.scene.scriptText
        let removed = "Al final comparamos los tres coches."
        let range = (text as NSString).range(of: removed)
        let updated = (text as NSString).replacingCharacters(in: range, with: "")

        harness.appState.commitScriptTextChange(
            sceneID: harness.scene.id,
            previousText: text,
            text: updated
        )

        XCTAssertNil(harness.scene.editingItems.first?.textAnchor)
        let document = harness.appState.avScriptDocument()
        let unanchored = try XCTUnwrap(document.scenes[0].rows.last)
        XCTAssertTrue(unanchored.isUnanchored)
        XCTAssertEqual(unanchored.annotations.count, 1)
        XCTAssertEqual(unanchored.annotations.first?.text, "Corte seco al cruzar la meta")
    }

    func testExternalScriptCommitIsReflectedInTheAVDocument() throws {
        let text = harness.scene.scriptText
        let original = "Hoy probamos el nuevo simulador de carreras en Spa."
        let range = (text as NSString).range(of: original)
        let replacement = "Hoy probamos el simulador en Spa."

        harness.appState.commitScriptTextChange(
            sceneID: harness.scene.id,
            previousText: text,
            text: (text as NSString).replacingCharacters(in: range, with: replacement)
        )

        let document = harness.appState.avScriptDocument()
        XCTAssertEqual(document.scenes[0].rows[0].paragraph?.text, replacement)
        XCTAssertTrue(harness.appState.projectStore.hasUnsavedFileChanges)
    }

    func testModeAndShortcutRegistrations() {
        XCTAssertEqual(WorkspaceMode.avScript.rawValue, "AV Script")
        XCTAssertTrue(WorkspaceMode.allCases.contains(.avScript))
        // Integration moved AV Script to ⌘6: clips owns ⌘4 and timeline ⌘5.
        XCTAssertEqual(harness.appState.shortcutDisplay(for: .avScriptMode), "⌘6")
        XCTAssertEqual(harness.appState.shortcutDisplay(for: .exportAVScript), "⌥⌘E")

        let bindings = ShortcutCommand.allCases.compactMap {
            ShortcutRegistry.binding(for: $0, overrides: [:])
        }
        XCTAssertEqual(Set(bindings).count, bindings.count, "Shortcut defaults must stay unique")
    }

    func testSpanishAndRussianLocalization() {
        XCTAssertEqual(L10n.tr("mode.avScript", language: .spanish), "Guion AV")
        XCTAssertEqual(L10n.tr("avScript.narration", language: .spanish), "Narración")
        XCTAssertEqual(L10n.tr("avScript.addToParagraph", language: .spanish), "Añadir al párrafo")
        XCTAssertEqual(L10n.tr("mode.avScript", language: .english), "AV Script")
        XCTAssertEqual(L10n.tr("avScript.addToParagraph", language: .russian), "Добавить к абзацу")
        XCTAssertEqual(L10n.tr("avScript.unanchored", language: .russian), "Без привязки")
    }

    func testExportsUseTheActiveSpanishLabels() {
        let markdown = harness.appState.avScriptExportText(format: .markdown)
        XCTAssertTrue(markdown.contains("# Guion AV — Guion AV de prueba"))
        XCTAssertTrue(markdown.contains("| Narración | Visuales y montaje |"))
        XCTAssertTrue(markdown.contains("**Visual** — Plano de la curva Eau Rouge"))

        let csv = harness.appState.avScriptExportText(format: .csv)
        XCTAssertTrue(csv.hasPrefix("Escena,Párrafo,Narración,Tipo,Descripción,Fuente,Estado,Anclaje\r\n"))
        XCTAssertTrue(csv.contains("Corte seco al cruzar la meta"))
    }
}

// MARK: - Offscreen snapshots

@MainActor
final class AVScriptSnapshotTests: XCTestCase {
    private var harness: AVTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try AVTestHarness()
        harness.appState.editorState.selectedSceneID = harness.scene.id
        harness.appState.editorState.selectedMode = .avScript
    }

    override func tearDown() async throws {
        harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testReadOnlyNarrationAppliesMarkupStyling() throws {
        let rendered = try renderAVScript(
            harness: harness,
            scene: harness.scene,
            showsAllScenes: false,
            size: CGSize(width: 1180, height: 760),
            colorScheme: .light,
            name: "av-markup-1180x760-light"
        )
        let textViews = collectSubviews(rendered.hosting).compactMap { $0 as? NSTextView }
        let paragraph = try XCTUnwrap(
            textViews.first { $0.string.contains("La primera *curva*") },
            "paragraph editor is missing"
        )
        let text = paragraph.string as NSString

        let emphasisIndex = text.range(of: "curva").location
        let font = try XCTUnwrap(
            paragraph.textStorage?.attribute(.font, at: emphasisIndex, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.italic),
            "emphasis should use the same italic markup style as the script editor"
        )

        let pauseIndex = text.range(of: "//").location
        let pauseHasBackground: Bool
        if let layoutManager = paragraph.layoutManager {
            pauseHasBackground = layoutManager.temporaryAttributes(
                atCharacterIndex: pauseIndex,
                effectiveRange: nil
            )[.backgroundColor] != nil
        } else {
            pauseHasBackground = paragraph.textStorage?.attribute(
                .backgroundColor,
                at: pauseIndex,
                effectiveRange: nil
            ) != nil
        }
        XCTAssertTrue(pauseHasBackground, "pause marker should get the script editor's tinted tag")
    }

    private func collectSubviews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(collectSubviews)
    }

    func testCurrentSceneSnapshotsAtBothSizesAndAppearances() throws {
        let sizes = [
            CGSize(width: 1180, height: 760),
            CGSize(width: 980, height: 712),
        ]
        for size in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let name = "av-editor-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark ? "dark" : "light")"
                let rendered = try renderAVScript(
                    harness: harness,
                    scene: harness.scene,
                    showsAllScenes: false,
                    size: size,
                    colorScheme: scheme,
                    name: name
                )

                assertLayoutInvariants(rendered, size: size, name: name)
                let text = recognizedText(in: rendered.image)
                XCTAssertTrue(
                    text.contains("simulador") || text.contains("narracion") || text.contains("gancho"),
                    "Snapshot \(name) has no recognizable Spanish text: \(text.prefix(400))"
                )
            }
        }
    }

    func testNarrowEditorWithSidebarOpen() throws {
        let size = CGSize(width: 740, height: 712)
        let rendered = try renderAVScript(
            harness: harness,
            scene: harness.scene,
            showsAllScenes: false,
            size: size,
            colorScheme: .light,
            name: "av-editor-740x712-light"
        )

        assertLayoutInvariants(rendered, size: size, name: "av-editor-740x712-light")
        XCTAssertGreaterThanOrEqual(
            AVScriptLayoutMetrics.narrationColumnWidth(
                containerWidth: size.width,
                contentInset: WorkspaceLayout.contentInset(isFocusModeEnabled: false)
            ),
            280,
            "narration stays readable with the sidebar open at the minimum window"
        )
        let text = recognizedText(in: rendered.image)
        XCTAssertTrue(
            text.contains("simulador") || text.contains("narracion") || text.contains("gancho"),
            "Narrow snapshot has no recognizable Spanish text: \(text.prefix(400))"
        )
    }

    func testAllScenesSnapshotShowsSceneHeaders() throws {
        let size = CGSize(width: 1180, height: 760)
        let rendered = try renderAVScript(
            harness: harness,
            scene: harness.scene,
            showsAllScenes: true,
            size: size,
            colorScheme: .light,
            name: "av-all-scenes-1180x760-light"
        )

        assertLayoutInvariants(rendered, size: size, name: "av-all-scenes-1180x760-light")
        let text = recognizedText(in: rendered.image)
        XCTAssertTrue(
            text.contains("gancho") || text.contains("cierre") || text.contains("escena"),
            "All-scenes snapshot has no recognizable Spanish scene text: \(text.prefix(400))"
        )
    }

    func testToolbarModeSwitcherFitsMinimumWidth() throws {
        for width in [CGFloat(980), 1180] {
            let size = CGSize(width: width, height: 58)
            let theme = FrameTheme(colorScheme: .light, accent: .sage)
            let root = TopToolbar()
                .environment(harness.appState)
                .environment(\.frameTheme, theme)
                .frame(width: size.width, height: size.height)
            let name = "av-toolbar-\(Int(width))x58-light"
            let rendered = try renderSnapshot(root, size: size, colorScheme: .light, name: name)

            XCTAssertEqual(rendered.image.size.width, size.width, accuracy: 0.5)
            XCTAssertEqual(rendered.image.size.height, size.height, accuracy: 0.5)
            let text = recognizedText(in: rendered.image)
            XCTAssertTrue(
                text.contains("guion av") || text.contains("visuales") || text.contains("edicion"),
                "Toolbar snapshot \(name) is missing the mode labels: \(text.prefix(400))"
            )
            XCTAssertTrue(
                text.contains("sin conexion") || text.contains("conectado"),
                "Toolbar snapshot \(name) clipped the recording status: \(text.prefix(400))"
            )
        }
    }

    func testUnanchoredGroupSnapshot() throws {
        harness.scene.scriptText = "Hoy probamos el nuevo simulador de carreras en Spa."
        let staleAnchor = TextAnchor(
            startUTF16: 99_999,
            lengthUTF16: 8,
            selectedText: "Antiguo",
            prefixContext: "ZZZ",
            suffixContext: "YYY"
        )
        harness.scene.bRollItems.append(
            BRollItem(
                textAnchor: staleAnchor,
                linkedSegmentID: nil,
                templateType: "",
                sourceType: .screenRecording,
                descriptionText: "Plano que perdió su párrafo",
                status: .idea
            )
        )
        let size = CGSize(width: 1180, height: 760)
        let rendered = try renderAVScript(
            harness: harness,
            scene: harness.scene,
            showsAllScenes: false,
            size: size,
            colorScheme: .light,
            name: "av-unanchored-1180x760-light"
        )

        assertLayoutInvariants(rendered, size: size, name: "av-unanchored-1180x760-light")
        let text = recognizedText(in: rendered.image)
        XCTAssertTrue(
            text.contains("sin ancla") || text.contains("antiguo"),
            "Unanchored snapshot is missing the recovery group: \(text.prefix(400))"
        )
    }

    private struct RenderedSnapshot {
        let hosting: NSView
        let image: NSBitmapImageRep
        let pngData: Data
    }

    private func renderAVScript(
        harness: AVTestHarness,
        scene: FrameScript.Scene,
        showsAllScenes: Bool,
        size: CGSize,
        colorScheme: ColorScheme,
        name: String
    ) throws -> RenderedSnapshot {
        let theme = FrameTheme(colorScheme: colorScheme, accent: .sage)
        let root = AVScriptEditorView(scene: scene, initiallyShowsAllScenes: showsAllScenes)
            .environment(harness.appState)
            .environment(\.frameTheme, theme)
            .frame(width: size.width, height: size.height)
        return try renderSnapshot(root, size: size, colorScheme: colorScheme, name: name)
    }

    private func renderSnapshot<Content: View>(
        _ root: Content,
        size: CGSize,
        colorScheme: ColorScheme,
        name: String
    ) throws -> RenderedSnapshot {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.appearance = window.appearance
        // Never order the window front: the snapshot must not steal focus.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("Could not create a bitmap for \(name)")
            throw SnapshotError.bitmapCreationFailed
        }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        guard let pngData = image.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name) as PNG")
            throw SnapshotError.encodingFailed
        }

        if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
            let directory = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-a-av-script", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        }

        return RenderedSnapshot(hosting: hosting, image: image, pngData: pngData)
    }

    private func assertLayoutInvariants(_ rendered: RenderedSnapshot, size: CGSize, name: String) {
        XCTAssertGreaterThan(rendered.image.pixelsWide, 0, "\(name) bitmap width")
        XCTAssertGreaterThan(rendered.image.pixelsHigh, 0, "\(name) bitmap height")
        XCTAssertEqual(rendered.image.size.width, size.width, accuracy: 0.5, "\(name) rendered width")
        XCTAssertEqual(rendered.image.size.height, size.height, accuracy: 0.5, "\(name) rendered height")
        XCTAssertGreaterThan(rendered.pngData.count, 8_000, "\(name) looks blank")

        let annotationWidth = AVScriptLayoutMetrics.annotationColumnWidth(containerWidth: size.width)
        let narrationWidth = AVScriptLayoutMetrics.narrationColumnWidth(
            containerWidth: size.width,
            contentInset: WorkspaceLayout.contentInset(isFocusModeEnabled: false)
        )
        XCTAssertGreaterThanOrEqual(narrationWidth, AVScriptLayoutMetrics.minimumNarrationWidth, "\(name) narration is too narrow")
        XCTAssertGreaterThanOrEqual(annotationWidth, 220, "\(name) annotation column is too narrow")

        let contentWidth = size.width - WorkspaceLayout.contentInset(isFocusModeEnabled: false) * 2
        let occupied = narrationWidth
            + AVScriptLayoutMetrics.narrationTrailingInset
            + AVScriptLayoutMetrics.columnGap
            + AVScriptLayoutMetrics.dividerWidth
            + annotationWidth
        XCTAssertLessThanOrEqual(occupied, contentWidth + 0.5, "\(name) columns overflow the canvas")
        XCTAssertLessThanOrEqual(contentWidth, size.width, "\(name) content is wider than the canvas")
    }

    private func recognizedText(in image: NSBitmapImageRep) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
        return text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
    }

    private enum SnapshotError: Error {
        case bitmapCreationFailed
        case encodingFailed
    }
}

// MARK: - Isolated harness

@MainActor
private final class AVTestHarness {
    /// Isolated suite in the process temporary directory: no test writes
    /// `~/Library/Preferences`.
    let isolatedDefaults: TestDefaults
    var defaults: UserDefaults { isolatedDefaults.defaults }
    let appState: AppState
    let project: FrameProject
    let scene: FrameScript.Scene

    init() throws {
        let isolatedDefaults = TestDefaults.make()
        self.isolatedDefaults = isolatedDefaults
        let defaults = isolatedDefaults.defaults

        let project = try Self.makeProject()
        let scene = try XCTUnwrap(project.scenes.first)
        self.project = project
        self.scene = scene

        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let dependencies = AppDependencies(
            rewriteService: RewriteService(provider: OpenAICompatibleLLMProvider()),
            analysisService: AnalysisService(provider: OpenAICompatibleLLMProvider()),
            exportService: ExportService(),
            llmProvider: OpenAICompatibleLLMProvider(),
            providerCredentials: ProviderCredentialSession(reader: { _ in nil })
        )
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: FakeOBSSecretStore()),
            defaults: defaults
        )
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish

        appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            themeManager: ResolvedThemeManager(systemColorScheme: .light),
            dependencies: dependencies,
            recording: recording,
            subscriptionRuntime: SubscriptionAIRuntime(
                store: SubscriptionAISettingsStore(userDefaults: defaults),
                routerFactory: SubscriptionAIRouterFactory(),
                inspector: SubscriptionAIT3ThreadInspector()
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            templates: SampleData.templates,
            customTemplates: []
        )
    }

    func tearDown() {
        isolatedDefaults.cleanup()
    }

    private static func makeProject() throws -> FrameProject {
        let firstText = """
        Hoy probamos el nuevo simulador de carreras en Spa.

        La primera *curva* decide si el tiempo sale // o se pierde.

        Al final comparamos los tres coches.
        """
        let secondText = "Cerramos con una pregunta para la próxima entrega."

        let firstParagraphRange = (firstText as NSString).range(of: "La primera *curva* decide si el tiempo sale // o se pierde.")
        let thirdParagraphRange = (firstText as NSString).range(of: "Al final comparamos los tres coches.")
        let visualAnchor = try XCTUnwrap(TextAnchorRepair.anchor(in: firstText, range: firstParagraphRange))
        let editingAnchor = try XCTUnwrap(TextAnchorRepair.anchor(in: firstText, range: thirdParagraphRange))

        let visual = BRollItem(
            textAnchor: visualAnchor,
            linkedSegmentID: nil,
            templateType: "",
            sourceType: .stockFootage,
            descriptionText: "Plano de la curva Eau Rouge",
            notes: "Cámara lenta y luego corte al cockpit.",
            status: .planned
        )
        let editing = EditingItem(
            textAnchor: editingAnchor,
            linkedSegmentID: nil,
            templateType: "",
            cutStyle: "Corte seco al cruzar la meta",
            transition: "",
            subtitleStyle: "",
            notes: "Bajar la música justo antes del corte.",
            status: .done
        )

        let firstScene = FrameScript.Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: firstText,
            bRollItems: [visual],
            editingItems: [editing]
        )
        let secondScene = FrameScript.Scene(
            order: 1,
            sectionType: .cta,
            title: "Cierre",
            scriptText: secondText
        )
        return FrameProject(
            title: "Guion AV de prueba",
            scenes: [firstScene, secondScene],
            primaryLanguage: "es"
        )
    }

}

private struct FakeOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
