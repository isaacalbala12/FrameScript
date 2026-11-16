import AppKit
import FrameScriptCore
import SwiftUI
import Vision
import XCTest
@testable import FrameScript

/// Offscreen rendering tests for the Resolve delivery sheet.
///
/// The view is hosted in an `NSWindow` that is never ordered front, never made
/// key and never activates the app. With `FS_SNAPSHOTS=1` in the test host the
/// PNGs are written to `/tmp/fs-snapshots/w3fix-cdh-resolve-pack/`; without it the
/// same render is checked for size, non-blank pixels, visible Spanish text and
/// the layout contract.
///
/// Fixtures are synthetic Spanish sample data. No `UserDefaults`, Keychain,
/// Application Support folder, recents or real project files are read.
@MainActor
final class ResolvePackSnapshotTests: XCTestCase {
    private let snapshotDirectory = URL(
        fileURLWithPath: "/tmp/fs-snapshots/w3fix-cdh-resolve-pack",
        isDirectory: true
    )

    // MARK: - Tests

    func testResolvePackSheetRendersAtBothWindowSizesAndThemes() throws {
        let plan = try makePlan()
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let sizes = [
            CGSize(width: 1180, height: 760),
            CGSize(width: 980, height: 712)
        ]
        let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

        for size in sizes {
            for (name, scheme) in schemes {
                let rendered = render(
                    content(plan: plan, configuration: configuration),
                    size: size,
                    scheme: scheme
                )
                try assertRender(rendered, size: size, name: "\(name)")
                if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
                    try writePNG(
                        rendered.image,
                        name: "resolve-pack-\(Int(size.width))x\(Int(size.height))-\(name).png"
                    )
                }
            }
        }
    }

    func testResolvePackSheetShowsSpanishTextAndTheExportAction() throws {
        let plan = try makePlan()
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let rendered = render(
            content(plan: plan, configuration: configuration),
            size: CGSize(width: 1180, height: 760),
            scheme: .light
        )

        let visibleText = recognizedText(in: rendered.image)
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("Pack para DaVinci Resolve"),
            "Missing Spanish title. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("Marcadores"),
            "Missing marker list heading. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("Exportar"),
            "Missing export button. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("Frecuencia"),
            "Missing frame rate label. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("Leyenda"),
            "Missing colour legend. OCR text: \(visibleText)"
        )
    }

    func testResolvePackSheetInvalidTimecodeShowsAnInlineError() throws {
        let plan = try makePlan()
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        configuration.startTimecodeText = "99:99:99:99"
        let rendered = render(
            content(plan: plan, configuration: configuration),
            size: ResolvePackSheetLayout.minimumWindowSize,
            scheme: .dark
        )
        let visibleText = recognizedText(in: rendered.image)
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("válido")
                || visibleText.localizedCaseInsensitiveContains("valido"),
            "Missing inline timecode error. OCR text: \(visibleText)"
        )
    }

    func testResolvePackInvalidChaptersWarnAndOfferTheOptIn() throws {
        let scenes = [
            ExportScene(title: "Uno", start: 0, duration: 20),
            ExportScene(title: "Dos", start: 20, duration: 20)
        ]
        var configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let options = try XCTUnwrap(configuration.options())
        let plan = ResolveDeliveryPack.plan(
            scenes: scenes,
            projectName: "Dos escenas",
            options: options
        )
        XCTAssertFalse(plan.chapters.isValidForYouTube)

        let rendered = render(
            content(plan: plan, configuration: configuration),
            size: CGSize(width: 980, height: 712),
            scheme: .light
        )
        try assertRender(rendered, size: CGSize(width: 980, height: 712), name: "invalid chapters")
        let visibleText = recognizedText(in: rendered.image)
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("capítulos"),
            "Missing invalid-chapters warning. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("5 de 6"),
            "The footer must count the omitted chapters file. OCR text: \(visibleText)"
        )
        XCTAssertTrue(
            visibleText.localizedCaseInsensitiveContains("no se escribirá"),
            "The chapter row must say it will not be written. OCR text: \(visibleText)"
        )
        if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
            try writePNG(rendered.image, name: "resolve-pack-invalid-chapters-light-980x712.png")
        }

        configuration.writeInvalidChapters = true
        XCTAssertNotNil(configuration.options())
    }

    func testResolveExportButtonStaysAccentFilledWhenTheWindowIsNotKey() throws {
        let plan = try makePlan()
        let configuration = ResolvePackConfiguration.defaults(languageCode: "es")
        let size = CGSize(width: 980, height: 712)
        let sage = render(
            content(plan: plan, configuration: configuration),
            size: size,
            scheme: .light,
            accent: .sage
        )
        let rose = render(
            content(plan: plan, configuration: configuration),
            size: size,
            scheme: .light,
            accent: .rose
        )
        let scale = CGFloat(sage.image.pixelsWide) / size.width
        let band = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sage.image.pixelsWide),
            height: ResolvePackSheetLayout.footerHeight * scale
        )
        let differing = differingPixels(sage.image, rose.image, in: band)
        XCTAssertGreaterThan(
            differing,
            100,
            "The Resolve export primary button is not accent-filled (\(differing) footer pixels changed)"
        )
    }

    // MARK: - Synthetic data

    private func makePlan() throws -> ResolvePackPlan {
        let hookText = "Hoy analizamos la actualización del simulador y por qué cambia el comportamiento del coche en las curvas rápidas."
        let problemText = "El problema no es la potencia: es la temperatura de los neumáticos y la forma en la que el coche gira a baja velocidad."
        let closeText = "Si quieres probar esta configuración, déjamelo en comentarios y nos vemos en la siguiente vuelta."

        let hook = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: hookText,
            bRollItems: [
                BRollItem(
                    textAnchor: anchor("simulador", in: hookText),
                    templateType: "",
                    sourceType: .screenRecording,
                    descriptionText: "Gameplay en Spa con la cámara aérea"
                ),
                BRollItem(
                    textAnchor: anchor("comportamiento", in: hookText),
                    templateType: "",
                    sourceType: .talkingHead,
                    descriptionText: "Plano a cámara del presentador"
                )
            ],
            takes: [
                Take(
                    number: 1,
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    duration: 8,
                    rating: .good,
                    languageCode: "es",
                    readText: hookText,
                    sceneTextHash: FrameScriptDocument.TextHash.hash(hookText)
                )
            ]
        )

        let problem = Scene(
            order: 1,
            sectionType: .explanation,
            title: "El problema",
            scriptText: problemText,
            bRollItems: [
                BRollItem(
                    textAnchor: anchor("neumáticos", in: problemText),
                    templateType: "",
                    sourceType: .screenshot,
                    descriptionText: "Captura de la telemetría"
                )
            ],
            editingItems: [
                EditingItem(
                    textAnchor: anchor("temperatura", in: problemText),
                    templateType: "",
                    cutStyle: "",
                    transition: "Fundido",
                    subtitleStyle: "Rótulo: temperatura",
                    musicCue: "Música tensa",
                    graphics: "Tabla comparativa"
                )
            ]
        )

        let close = Scene(
            order: 2,
            sectionType: .cta,
            title: "Cierre",
            scriptText: closeText,
            bRollItems: [
                BRollItem(
                    textAnchor: anchor("comentarios", in: closeText),
                    templateType: "",
                    sourceType: .infographic,
                    descriptionText: "Gráfico de suscripción"
                )
            ]
        )

        let claim = ProjectClaim(
            text: "La actualización reduce un 12 % el desgaste",
            status: .probable,
            sceneIDs: [problem.id]
        )
        let project = FrameProject(
            title: "AC EVO 0.9: guía completa",
            scenes: [hook, problem, close],
            primaryLanguage: "es",
            claims: [claim]
        )

        let mapper = ResolveSceneMapper(
            languageCode: "es",
            durationSource: .realTakes,
            wordsPerMinute: 150,
            pauseDefaults: .standard
        )
        let mapping = mapper.map(project: project)
        XCTAssertGreaterThanOrEqual(mapping.scenes.count, 3)
        let options = try XCTUnwrap(
            ResolvePackConfiguration.defaults(languageCode: "es").options()
        )
        let plan = ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: project.title,
            options: options,
            extraWarnings: mapping.warnings
        )
        XCTAssertGreaterThanOrEqual(plan.markers.count, 8)
        return plan
    }

    private func anchor(_ phrase: String, in text: String) -> TextAnchor {
        let range = (text as NSString).range(of: phrase)
        precondition(range.location != NSNotFound, "fixture phrase missing: \(phrase)")
        return TextAnchor(startUTF16: range.location, lengthUTF16: range.length, selectedText: phrase)
    }

    private func content(
        plan: ResolvePackPlan,
        configuration: ResolvePackConfiguration
    ) -> ResolvePackSheetContent {
        ResolvePackSheetContent(
            projectTitle: "AC EVO 0.9: guía completa",
            interfaceLanguage: .spanish,
            languageOptions: [
                ResolvePackLanguageOption(code: "es", isOriginal: true),
                ResolvePackLanguageOption(code: "en", isOriginal: false)
            ],
            configuration: .constant(configuration),
            plan: plan,
            defaultFolderPath: "/Volumes/Proyectos/Resolve",
            exportedFolder: nil,
            errorMessage: nil,
            onExport: {},
            onClose: {},
            onReveal: { _ in }
        )
    }

    // MARK: - Rendering

    private struct Rendered {
        let image: NSBitmapImageRep
        let hosting: NSHostingView<AnyView>
        let window: NSWindow
    }

    private func render(
        _ view: ResolvePackSheetContent,
        size: CGSize,
        scheme: ColorScheme,
        accent: AccentPalette = .sage
    ) -> Rendered {
        let theme = FrameTheme(colorScheme: scheme, accent: accent)
        let root = AnyView(
            view
                .environment(\.frameTheme, theme)
                .environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height)
                .background(theme.windowBackground)
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        // Never ordered front, never made key: no focus stealing.
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            ?? NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return Rendered(image: image, hosting: hosting, window: window)
    }

    private func assertRender(
        _ rendered: Rendered,
        size: CGSize,
        name: String
    ) throws {
        XCTAssertGreaterThan(rendered.image.pixelsWide, 0)
        XCTAssertGreaterThan(rendered.image.pixelsHigh, 0)
        XCTAssertGreaterThanOrEqual(rendered.image.pixelsWide, Int(size.width))
        XCTAssertGreaterThanOrEqual(rendered.image.pixelsHigh, Int(size.height))
        XCTAssertGreaterThanOrEqual(
            distinctColorCount(in: rendered.image),
            8,
            "The \(name) render looks blank"
        )

        // Layout contract: nothing extends past the canvas and the three
        // columns do not overlap.
        let frames = ResolvePackSheetLayout.frames(in: size)
        let canvas = CGRect(origin: .zero, size: size)
        for rect in [frames.header, frames.body, frames.footer, frames.options, frames.divider, frames.preview] {
            XCTAssertTrue(canvas.contains(rect), "\(rect) outside \(canvas)")
        }
        XCTAssertFalse(frames.options.intersects(frames.divider))
        XCTAssertFalse(frames.divider.intersects(frames.preview))
        XCTAssertFalse(frames.header.intersects(frames.footer))
    }

    private func differingPixels(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep,
        in band: CGRect
    ) -> Int {
        let width = min(lhs.pixelsWide, rhs.pixelsWide)
        let height = min(lhs.pixelsHigh, rhs.pixelsHigh)
        let minX = max(0, Int(band.minX))
        let maxX = min(width, Int(band.maxX))
        let minY = max(0, Int(band.minY))
        let maxY = min(height, Int(band.maxY))
        guard minX < maxX, minY < maxY else { return 0 }
        var differing = 0
        for x in stride(from: minX, to: maxX, by: 2) {
            for y in stride(from: minY, to: maxY, by: 2) {
                guard let left = lhs.colorAt(x: x, y: y),
                      let right = rhs.colorAt(x: x, y: y) else { continue }
                let dr = abs(left.redComponent - right.redComponent)
                let dg = abs(left.greenComponent - right.greenComponent)
                let db = abs(left.blueComponent - right.blueComponent)
                if dr + dg + db > 0.05 { differing += 1 }
            }
        }
        return differing
    }

    private func distinctColorCount(in image: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        let stepX = max(1, image.pixelsWide / 40)
        let stepY = max(1, image.pixelsHigh / 40)
        for y in stride(from: 0, to: image.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: image.pixelsWide, by: stepX) {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                let rgb = color.usingColorSpace(.deviceRGB) ?? color
                let red = UInt32((rgb.redComponent * 31).rounded())
                let green = UInt32((rgb.greenComponent * 31).rounded())
                let blue = UInt32((rgb.blueComponent * 31).rounded())
                colors.insert((red << 10) | (green << 5) | blue)
            }
        }
        return colors.count
    }

    /// Offscreen OCR is the only reliable way to assert that Spanish text is
    /// actually painted: SwiftUI's accessibility tree only exposed the
    /// text-field value during development.
    private func recognizedText(in image: NSBitmapImageRep) -> String {
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["es-ES", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cgImage)
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private func writePNG(_ image: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )
        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
        try data.write(to: snapshotDirectory.appendingPathComponent(name), options: .atomic)
    }
}
