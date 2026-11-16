import AppKit
import SwiftUI
import Vision
import XCTest
@testable import FrameScript

/// Renders the research panel offscreen. Never orders a window front and never
/// touches the real app defaults, recent projects or Keychain.
@MainActor
final class ResearchSnapshotTests: XCTestCase {
    /// Isolated suites in the process temporary directory; no real plist.
    private var isolatedSuites: [TestDefaults] = []
    private let branchFolder = "w3-i-research"

    override func setUp() async throws {
        try await super.setUp()
        ResearchSnapshotSupport.resetPresentation()
    }

    override func tearDown() async throws {
        for suite in isolatedSuites {
            suite.cleanup()
        }
        isolatedSuites.removeAll()
        try await super.tearDown()
    }

    func testResearchPanelRendersAtRequiredSizesInBothThemes() throws {
        let appState = makeAppState()

        let themes: [(String, ColorScheme, NSAppearance.Name)] = [
            ("light", .light, .aqua),
            ("dark", .dark, .darkAqua)
        ]
        let sizes: [(String, CGFloat, CGFloat)] = [
            ("1180x760", 1180, 760),
            ("980x712", 980, 712)
        ]
        let tabs = ResearchTab.allCases

        for (themeName, colorScheme, appearanceName) in themes {
            for (sizeName, width, height) in sizes {
                for tab in tabs {
                    ResearchPresentation.shared.selectedTab = tab
                    ResearchSnapshotSupport.prepareSelection(appState: appState, tab: tab)

                    let view = ResearchPanelView()
                        .environment(appState)
                        .environment(\.frameTheme, FrameTheme(colorScheme: colorScheme, accent: .sage))
                        .preferredColorScheme(colorScheme)
                        .frame(width: width, height: height)

                    let result = try ResearchSnapshotSupport.render(
                        view,
                        width: width,
                        height: height,
                        appearance: NSAppearance(named: appearanceName),
                        shouldRecognizeText: colorScheme == .light
                    )

                    let name = "research-\(tab.rawValue)-\(themeName)-\(sizeName)"
                    if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
                        try ResearchSnapshotSupport.writePNG(
                            result,
                            name: name,
                            branchFolder: branchFolder
                        )
                    }

                    // OCR is expensive; visible-text and key-frame checks run
                    // on every light render, while dark renders still prove the
                    // image is non-blank and the layout does not demand a
                    // larger canvas. The PNGs cover dark text visually.
                    try assertLayout(
                        result,
                        expectedName: name,
                        width: width,
                        height: height,
                        tab: tab,
                        assertVisibleText: colorScheme == .light
                    )
                }
            }
        }
    }

    func testSceneSidebarShowsResearchBadgeWithoutClipping() throws {
        let appState = makeAppState()
        let themes: [(String, ColorScheme, NSAppearance.Name)] = [
            ("light", .light, .aqua),
            ("dark", .dark, .darkAqua)
        ]

        for (themeName, colorScheme, appearanceName) in themes {
            let view = SceneSidebar()
                .environment(appState)
                .environment(\.frameTheme, FrameTheme(colorScheme: colorScheme, accent: .sage))
                .preferredColorScheme(colorScheme)
                .frame(width: 240, height: 640)

            let result = try ResearchSnapshotSupport.render(
                view,
                width: 240,
                height: 640,
                appearance: NSAppearance(named: appearanceName)
            )

            let name = "research-scene-sidebar-\(themeName)-240x640"
            if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
                try ResearchSnapshotSupport.writePNG(
                    result,
                    name: name,
                    branchFolder: branchFolder
                )
            }

            XCTAssertEqual(result.size.width, 240, accuracy: 0.5)
            XCTAssertEqual(result.size.height, 640, accuracy: 0.5)
            let image = try XCTUnwrap(result.image, "\(name): no image")
            try assertNotBlank(image, name: name)
            let joined = result.recognizedText.map(\.text.compactForSnapshotMatch).joined()
            XCTAssertTrue(
                joined.contains("ladudadelrecord"),
                "\(name): scene title not visible; OCR: \(result.recognizedText.map(\.text))"
            )
            XCTAssertTrue(
                joined.contains("cierre"),
                "\(name): third scene title not visible; OCR: \(result.recognizedText.map(\.text))"
            )
        }
    }

    func testW3FixEGIStaleClaimAnchorShowsWarningAndRelinkAction() throws {
        let appState = makeAppState()
        ResearchPresentation.shared.selectedTab = .claims
        ResearchPresentation.shared.focusedSceneID = nil
        ResearchSnapshotSupport.prepareSelection(appState: appState, tab: .claims)

        var claim = try XCTUnwrap(appState.project.claims.first { $0.text == "El parche sale en mayo" })
        claim.anchorSceneID = claim.sceneIDs.first
        claim.anchor = TextAnchor(
            startUTF16: 0,
            lengthUTF16: 6,
            selectedText: "ZZZZZZ"
        )
        appState.updateResearchClaim(claim)

        let view = ResearchPanelView()
            .environment(appState)
            .environment(\.frameTheme, FrameTheme(colorScheme: .light, accent: .sage))
            .preferredColorScheme(.light)
            .frame(width: 1180, height: 760)

        let result = try ResearchSnapshotSupport.render(
            view,
            width: 1180,
            height: 760,
            appearance: NSAppearance(named: .aqua),
            shouldRecognizeText: true
        )

        if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
            try ResearchSnapshotSupport.writePNG(
                result,
                name: "research-stale-anchor-light-1180x760",
                branchFolder: branchFolder
            )
        }

        let joined = result.recognizedText.map(\.text.compactForSnapshotMatch).joined()
        XCTAssertTrue(
            joined.contains("yanocoincide"),
            "The stale anchor warning is not visible; OCR: \(result.recognizedText.map(\.text))"
        )
        XCTAssertTrue(
            joined.contains("volveravincular"),
            "The re-link action is not visible; OCR: \(result.recognizedText.map(\.text))"
        )
    }

    // MARK: - Invariants

    private func assertLayout(
        _ result: ResearchSnapshotSupport.RenderResult,
        expectedName: String,
        width: CGFloat,
        height: CGFloat,
        tab: ResearchTab,
        assertVisibleText: Bool
    ) throws {
        XCTAssertEqual(result.size.width, width, accuracy: 0.5, "\(expectedName): wrong width")
        XCTAssertEqual(result.size.height, height, accuracy: 0.5, "\(expectedName): wrong height")
        XCTAssertGreaterThan(result.size.width, 0, "\(expectedName): zero width")
        XCTAssertGreaterThan(result.size.height, 0, "\(expectedName): zero height")

        // The hosting view must not demand more room than the canvas. This is
        // the programmatic version of "nothing is cut off on the right".
        XCTAssertLessThanOrEqual(
            result.fittingSize.width,
            width + 1,
            "\(expectedName): view needs \(result.fittingSize.width) pt but the canvas is \(width) pt"
        )
        XCTAssertLessThanOrEqual(
            result.fittingSize.height,
            height + 1,
            "\(expectedName): view needs \(result.fittingSize.height) pt but the canvas is \(height) pt"
        )

        let image = try XCTUnwrap(result.image, "\(expectedName): no image")
        XCTAssertEqual(image.size.width, width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, height, accuracy: 0.5)
        try assertNotBlank(image, name: expectedName)

        guard assertVisibleText else { return }

        let recognized = result.recognizedText
        XCTAssertFalse(recognized.isEmpty, "\(expectedName): OCR found no visible text")
        let joined = recognized
            .map(\.text.compactForSnapshotMatch)
            .joined()

        XCTAssertTrue(
            joined.contains("investigacion"),
            "\(expectedName): Spanish title not visible; OCR: \(recognized.map(\.text).prefix(30))"
        )
        for expected in ["fuentes", "afirmaciones", "verificar", "tablas"] {
            XCTAssertTrue(
                joined.contains(expected),
                "\(expectedName): missing Spanish tab label \(expected); OCR: \(recognized.map(\.text).prefix(40))"
            )
        }

        let sampleText: String
        switch tab {
        case .sources: sampleText = "fuentesguardadas"
        case .claims: sampleText = "recorddelcircuito"
        case .verify: sampleText = "verificarantesdegrabar"
        case .tables: sampleText = "neumaticos"
        }
        XCTAssertTrue(
            joined.contains(sampleText),
            "\(expectedName): missing Spanish sample text \(sampleText); OCR: \(recognized.map(\.text).prefix(50))"
        )

        if tab == .claims {
            // VW5: the two research actions must read as buttons. OCR proves
            // the labels are on-canvas; the style itself is asserted by the
            // shared style tests.
            XCTAssertTrue(
                joined.contains("nuevaafirmacion"),
                "\(expectedName): missing Nueva afirmación; OCR: \(recognized.map(\.text).prefix(50))"
            )
            XCTAssertTrue(
                joined.contains("vincular"),
                "\(expectedName): missing Vincular; OCR: \(recognized.map(\.text).prefix(50))"
            )
        }

        // Key labels must be fully on-canvas and must not overlap each other.
        var framesByLabel: [String: NSRect] = [:]
        if let titleFrame = recognized.first(where: {
            $0.text.compactForSnapshotMatch.contains("investigacion")
        })?.frame {
            XCTAssertGreaterThanOrEqual(titleFrame.minX, -1, "\(expectedName): title clipped on the left")
            XCTAssertGreaterThanOrEqual(titleFrame.minY, -1, "\(expectedName): title clipped on the bottom")
            XCTAssertLessThanOrEqual(titleFrame.maxX, width + 1, "\(expectedName): title clipped on the right")
            XCTAssertLessThanOrEqual(titleFrame.maxY, height + 1, "\(expectedName): title clipped on the top")
            framesByLabel["investigacion"] = titleFrame
        } else {
            XCTFail("\(expectedName): no OCR frame for the title")
        }

        for label in ["fuentes", "afirmaciones", "verificar", "tablas"] {
            guard let frame = frameForTabLabel(label, in: recognized) else {
                XCTFail("\(expectedName): no OCR frame for \(label); OCR: \(recognized.map(\.text).prefix(50))")
                continue
            }
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(expectedName): \(label) clipped on the left")
            XCTAssertGreaterThanOrEqual(frame.minY, -1, "\(expectedName): \(label) clipped on the bottom")
            XCTAssertLessThanOrEqual(frame.maxX, width + 1, "\(expectedName): \(label) clipped on the right")
            XCTAssertLessThanOrEqual(frame.maxY, height + 1, "\(expectedName): \(label) clipped on the top")
            framesByLabel[label] = frame
        }

        let entries = Array(framesByLabel)
        for index in entries.indices {
            for other in entries.indices where other > index {
                let (firstLabel, firstFrame) = entries[index]
                let (secondLabel, secondFrame) = entries[other]
                let inset = firstFrame.insetBy(dx: 2, dy: 2)
                XCTAssertFalse(
                    inset.intersects(secondFrame),
                    "\(expectedName): \(firstLabel) overlaps \(secondLabel): \(firstFrame) vs \(secondFrame)"
                )
            }
        }
    }

    private func frameForTabLabel(
        _ label: String,
        in recognized: [ResearchSnapshotSupport.RecognizedText]
    ) -> NSRect? {
        recognized.first { item in
            let text = item.text.compactForSnapshotMatch
            guard text.hasPrefix(label) else { return false }
            let rest = String(text.dropFirst(label.count))
            return rest.isEmpty || rest.allSatisfy(\.isNumber)
        }?.frame
    }

    private func assertNotBlank(_ image: NSImage, name: String) throws {
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = cgImage.width
        let height = cgImage.height
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            XCTFail("\(name): image has no pixel data")
            return
        }
        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else {
            XCTFail("\(name): unexpected pixel format")
            return
        }

        var colors: Set<UInt32> = []
        var sampled = 0
        var nonCorner = 0
        let corner = colorAt(0, 0, bytes, bytesPerRow, bytesPerPixel)
        var x = 0
        while x < width {
            var y = 0
            while y < height {
                let color = colorAt(x, y, bytes, bytesPerRow, bytesPerPixel)
                colors.insert(color)
                sampled += 1
                if color != corner { nonCorner += 1 }
                y += 8
            }
            x += 8
        }
        XCTAssertGreaterThan(colors.count, 6, "\(name): image looks flat/blank")
        XCTAssertGreaterThan(nonCorner, max(20, sampled / 100), "\(name): image looks blank")
    }

    private func colorAt(
        _ x: Int,
        _ y: Int,
        _ bytes: UnsafePointer<UInt8>,
        _ bytesPerRow: Int,
        _ bytesPerPixel: Int
    ) -> UInt32 {
        let offset = y * bytesPerRow + x * bytesPerPixel
        var value: UInt32 = 0
        for index in 0..<min(4, bytesPerPixel) {
            value = (value << 8) | UInt32(bytes[offset + index])
        }
        return value
    }

    // MARK: - Fixture

    private func makeAppState() -> AppState {
        let isolated = TestDefaults.make()
        isolatedSuites.append(isolated)
        let defaults = isolated.defaults

        let scene1 = Scene(
            order: 0,
            sectionType: .hook,
            title: "La duda del récord",
            scriptText: "El récord del circuito es 1:42.3 y lo confirmó el equipo. El parche sale en mayo, aunque nadie lo ha dicho oficialmente."
        )
        let scene2 = Scene(
            order: 1,
            sectionType: .custom,
            title: "Neumáticos y desgaste",
            scriptText: "El compuesto blando dura menos de diez vueltas. En el foro dicen que la degradación es peor con calor."
        )
        let scene3 = Scene(
            order: 2,
            sectionType: .cta,
            title: "Cierre",
            scriptText: "Cuéntame en comentarios qué compuesto elegirías."
        )

        let source1 = ProjectSource(
            title: "Timing oficial",
            url: "https://example.com/timing",
            kind: .official,
            reliability: .high,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            note: "Resultados de la sesión y récord de vuelta."
        )
        let source2 = ProjectSource(
            title: "Nota de prensa",
            url: "https://example.com/press",
            kind: .press,
            reliability: .medium,
            note: "Anuncia la fecha del parche sin detalle técnico."
        )
        let source3 = ProjectSource(
            title: "Hilo del foro",
            url: "https://example.com/forum",
            kind: .community,
            reliability: .low,
            note: "Impresiones de usuarios, sin datos medidos."
        )

        let claim1 = ProjectClaim(
            text: "El récord del circuito es 1:42.3",
            status: .confirmed,
            sourceIDs: [source1.id],
            sceneIDs: [scene1.id],
            needsVerification: false,
            resolutionNote: "Confirmado con el PDF del timing."
        )
        let claim2 = ProjectClaim(
            text: "El parche sale en mayo",
            status: .probable,
            sourceIDs: [source2.id],
            sceneIDs: [scene1.id],
            needsVerification: true
        )
        let claim3 = ProjectClaim(
            text: "En el foro dicen que la degradación es peor con calor",
            status: .communityOpinion,
            sourceIDs: [source3.id],
            sceneIDs: [scene2.id],
            needsVerification: true
        )
        let claim4 = ProjectClaim(
            text: "El blando dura menos de diez vueltas",
            status: .rumor,
            sceneIDs: [scene2.id],
            needsVerification: false,
            personalExperience: true
        )

        let table1 = ComparisonTable(
            title: "Neumáticos",
            header: ["Compuesto", "Duración", "Uso"],
            rows: [
                ["Blando", "8 vueltas", "Clasificación"],
                ["Medio", "14 vueltas", "Carrera"],
                ["Duro", "20 vueltas", "Stint largo"]
            ],
            sceneID: scene2.id
        )

        let project = FrameProject(
            title: "Comparativa de neumáticos",
            scenes: [scene1, scene2, scene3],
            primaryLanguage: "es",
            publishingPacks: [
                "es": PublishingPack(description: "Comparativa sintética para la revisión visual.")
            ],
            checklistTasks: [
                ChecklistTask(text: "El parche sale en mayo", kind: .research, sceneID: scene1.id),
                ChecklistTask(text: "Pedir captura del timing", kind: .acquire, sceneID: scene1.id)
            ],
            sources: [source1, source2, source3],
            claims: [claim1, claim2, claim3, claim4],
            comparisonTables: [table1]
        )

        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish

        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)

        let recording = RecordingController(
            preferences: OBSPreferencesStore(
                defaults: defaults,
                secretStore: ResearchSnapshotOBSSecretStore()
            ),
            defaults: defaults
        )

        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: AppDependencies(
                rewriteService: RewriteService(provider: MockLLMProvider()),
                analysisService: AnalysisService(provider: MockLLMProvider()),
                exportService: ExportService(),
                llmProvider: MockLLMProvider(),
                providerCredentials: ProviderCredentialSession(reader: { _ in "test-key" })
            ),
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }
}

// MARK: - Offscreen renderer

@MainActor
enum ResearchSnapshotSupport {
    struct RecognizedText {
        let text: String
        let frame: NSRect
    }

    struct RenderResult {
        let image: NSImage?
        let size: NSSize
        let fittingSize: NSSize
        let recognizedText: [RecognizedText]
    }

    static func prepareSelection(appState: AppState, tab: ResearchTab) {
        let presentation = ResearchPresentation.shared
        presentation.focusedSceneID = nil
        presentation.onlyPending = false
        presentation.searchText = ""
        presentation.selectedSourceID = appState.project.sources.first?.id
        presentation.selectedClaimID = appState.project.claims.first?.id
        presentation.selectedTableID = appState.project.comparisonTables.first?.id
        presentation.resetSuggestions()
        presentation.resetPaste()
        presentation.statusMessage = nil
    }

    static func resetPresentation() {
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

    static func render<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat,
        appearance: NSAppearance?,
        shouldRecognizeText: Bool = true
    ) throws -> RenderResult {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.appearance = appearance

        // A borderless window that is never ordered front gives SwiftUI a real
        // window for appearance and accessibility without stealing focus.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderOut(nil)

        hostingView.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        hostingView.layoutSubtreeIfNeeded()

        let image: NSImage?
        if let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            let rendered = NSImage(size: hostingView.bounds.size)
            rendered.addRepresentation(rep)
            image = rendered
        } else {
            image = nil
        }

        let recognized = shouldRecognizeText
            ? (image.flatMap { recognizeText(in: $0) } ?? [])
            : []

        window.contentView = nil
        window.close()

        return RenderResult(
            image: image,
            size: hostingView.bounds.size,
            fittingSize: hostingView.fittingSize,
            recognizedText: recognized
        )
    }

    static func writePNG(_ result: RenderResult, name: String, branchFolder: String) throws {
        guard let image = result.image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        let folder = URL(fileURLWithPath: "/tmp/fs-snapshots")
            .appendingPathComponent(branchFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private static func recognizeText(in image: NSImage) -> [RecognizedText] {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES"]
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: cgImage)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else {
            return []
        }
        let width = image.size.width
        let height = image.size.height
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            let frame = NSRect(
                x: box.minX * width,
                y: box.minY * height,
                width: box.width * width,
                height: box.height * height
            )
            return RecognizedText(text: candidate.string, frame: frame)
        }
    }
}

extension String {
    /// OCR sometimes inserts spaces inside a word and accents drift. Match on
    /// letters and digits only so the assertion checks meaning, not kerning.
    var compactForSnapshotMatch: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}

private struct ResearchSnapshotOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
