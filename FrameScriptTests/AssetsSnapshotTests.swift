import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Renders the Assets sheet offscreen at the two supported window sizes in both
/// appearances. With `FS_SNAPSHOTS=1` in the test host the PNGs are written to
/// `/tmp/fs-snapshots/w3-c-assets`; without it the same render asserts layout
/// invariants (no clipping, no overlapping key regions, Spanish strings).
@MainActor
final class AssetsSnapshotTests: XCTestCase {
    private struct RenderResult {
        let image: NSBitmapImageRep
        let frames: [String: CGRect]
    }

    func testAssetsSheetLayoutAtMinimumAndDefaultSizesInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [CGSize(width: 1180, height: 760), CGSize(width: 980, height: 712)] {
                let appState = makeAppState()
                let result = try await render(
                    appState: appState,
                    layout: .grid,
                    size: size,
                    colorScheme: scheme
                )
                assertLayout(result, appState: appState, canvas: size)
                try writeSnapshotIfRequested(
                    result.image,
                    name: "assets-grid-\(scheme == .dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
                )
            }
        }
    }

    func testAssetsListLayoutAtMinimumSize() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let size = CGSize(width: 980, height: 712)
            let appState = makeAppState()
            let result = try await render(
                appState: appState,
                layout: .list,
                size: size,
                colorScheme: scheme
            )
            assertLayout(result, appState: appState, canvas: size)
            try writeSnapshotIfRequested(
                result.image,
                name: "assets-list-\(scheme == .dark ? "dark" : "light")-980x712"
            )
        }
    }

    // MARK: Rendering

    private func render(
        appState: AppState,
        layout: AssetLayout,
        size: CGSize,
        colorScheme: ColorScheme
    ) async throws -> RenderResult {
        let theme = FrameTheme(colorScheme: colorScheme, accent: .sage)
        let framesBox = FramesBox()
        let root = AssetsSheetView(
            initialLayout: layout,
            onLayoutFrames: { frames in framesBox.frames = frames }
        )
        .environment(appState)
        .environment(\.frameTheme, theme)
        .preferredColorScheme(colorScheme)
        .frame(width: size.width, height: size.height)
        .background(theme.appBackground)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // The window is deliberately never ordered front: rendering must not
        // steal focus or appear on the user's screen.
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<8 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
        }
        hosting.displayIfNeeded()

        let bounds = hosting.bounds
        let representation = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: bounds),
            "The offscreen hosting view must produce a bitmap"
        )
        hosting.cacheDisplay(in: bounds, to: representation)
        return RenderResult(image: representation, frames: framesBox.frames)
    }

    private func assertLayout(_ result: RenderResult, appState: AppState, canvas: CGSize) {
        XCTAssertGreaterThan(result.image.pixelsWide, 0)
        XCTAssertGreaterThan(result.image.pixelsHigh, 0)

        let sheet = CGRect(x: 0, y: 0, width: 940, height: 640)
        XCTAssertLessThanOrEqual(sheet.width, canvas.width, "the sheet must fit the minimum window width")
        XCTAssertLessThanOrEqual(sheet.height, canvas.height, "the sheet must fit the minimum window height")

        let keys = ["header", "filter", "content", "inspector"]
        for key in keys {
            let frame = result.frames[key]
            XCTAssertNotNil(frame, "missing layout frame for \(key)")
            guard let frame else { continue }
            XCTAssertGreaterThan(frame.width, 0, "\(key) has zero width")
            XCTAssertGreaterThan(frame.height, 0, "\(key) has zero height")
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(key) is clipped on the left")
            XCTAssertGreaterThanOrEqual(frame.minY, -0.5, "\(key) is clipped on the top")
            XCTAssertLessThanOrEqual(frame.maxX, sheet.width + 0.5, "\(key) is clipped on the right")
            XCTAssertLessThanOrEqual(frame.maxY, sheet.height + 0.5, "\(key) is clipped on the bottom")
        }

        guard let header = result.frames["header"],
              let filter = result.frames["filter"],
              let content = result.frames["content"],
              let inspector = result.frames["inspector"]
        else { return }

        XCTAssertLessThanOrEqual(header.maxY, filter.minY + 0.5, "header overlaps the filter bar")
        XCTAssertLessThanOrEqual(filter.maxY, content.minY + 0.5, "filter bar overlaps the library")
        XCTAssertLessThanOrEqual(content.maxX, inspector.minX + 0.5, "library overlaps the inspector")
        XCTAssertEqual(content.width, 653, accuracy: 2, "unexpected library width")
        XCTAssertEqual(inspector.width, 286, accuracy: 1)
        XCTAssertGreaterThanOrEqual(content.width, 600, "the library needs room for the grid")

        // The sheet must keep showing Spanish, the language the sample data
        // uses, rather than falling back to raw keys.
        XCTAssertEqual(appState.currentLanguage, .spanish)
        XCTAssertEqual(appState.localized("assets.title"), "Recursos")
        XCTAssertTrue(appState.localized("assets.add").contains("Añadir"))
        for key in (L10n.assetsStrings[.spanish] ?? [:]).keys {
            XCTAssertNotEqual(appState.localized(key), key, "Missing Spanish string for \(key)")
        }
    }

    private func writeSnapshotIfRequested(_ image: NSBitmapImageRep, name: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FS_SNAPSHOTS"] == "1" || environment["TEST_RUNNER_FS_SNAPSHOTS"] == "1" else {
            return
        }
        guard let png = image.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode \(name).png")
            return
        }
        let directory = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-c-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    // MARK: Synthetic Spanish data

    private func makeAppState() -> AppState {
        // Absolute path in the temporary directory: no real preferences file.
        let isolated = TestDefaults.make()
        addTeardownBlock { isolated.cleanup() }
        let defaults = isolated.defaults

        let sceneA = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho: la curva que lo cambia todo",
            scriptText: "Hoy analizamos la actualización del simulador."
        )
        let sceneB = Scene(
            order: 1,
            sectionType: .explanation,
            title: "Explicación: telemetría y frenada",
            scriptText: "Comparamos la telemetría con la vuelta anterior."
        )
        let sceneC = Scene(
            order: 2,
            sectionType: .takeaway,
            title: "Cierre y siguiente vídeo",
            scriptText: "Nos vemos en el siguiente análisis."
        )
        let visual = BRollItem(
            templateType: "Plano recurso",
            sourceType: .screenRecording,
            descriptionText: "Telemetría comparada en pantalla"
        )
        sceneB.bRollItems = [visual]
        let take = Take(
            number: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 74,
            filePath: "/tmp/sintetico/Plano 03.mkv",
            rating: .good,
            languageCode: "es"
        )
        sceneA.takes = [take]

        let project = FrameProject(title: "Análisis sintético de Spa", scenes: [sceneA, sceneB, sceneC])
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: NoopOBSSecretStore()),
            defaults: defaults
        )
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        let appState = AppState(
            projectStore: ProjectStore(project: project),
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            customTemplates: []
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptAssetsSnapshots-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        var assets: [ProjectAsset] = []
        let specifications: [(name: String, kind: AssetKind, tags: [String], duration: TimeInterval?)] = [
            ("00 Captura de pantalla 2026-11-13 a las 10.14.22.png", .screenshot, ["referencia", "lanzamiento"], nil),
            ("Plano cámara — Spa-Francorchamps.mov", .camera, ["b-roll", "plano"], 48),
            ("OBS · Toma 3 · Introducción.mkv", .obs, ["voz", "plano"], 74),
            ("Música de fondo — synth cálido.mp3", .music, ["música", "fondo"], 132),
            ("Miniatura A — Portada.png", .thumbnail, ["portada", "miniatura"], nil),
            ("Referencia — web del circuito.html", .web, ["referencia"], nil)
        ]
        for (index, specification) in specifications.enumerated() {
            let url = directory.appendingPathComponent(specification.name)
            try? Data("sintético".utf8).write(to: url, options: .atomic)
            let bookmark = AssetBookmark.make(for: url)
            let asset = ProjectAsset(
                path: url.path,
                bookmarkData: bookmark,
                kind: specification.kind,
                tags: specification.tags,
                linkedSceneIDs: [],
                linkedBRollItemIDs: [],
                linkedTakeIDs: [],
                isCopiedIntoProject: false,
                duration: specification.duration,
                fileSize: Int64(240_000 + index * 180_000),
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                isLastKnownMissing: false
            )
            project.assets.append(asset)
            AssetThumbnailCache.shared.seedForTesting(
                syntheticThumbnail(index: index, label: appState.localized(specification.kind.localizationKey)),
                for: asset
            )
            assets.append(asset)
        }

        let missing = directory.appendingPathComponent("00 Archivo movido — sin conexión.mov")
        try? FileManager.default.removeItem(at: missing)
        let missingAsset = ProjectAsset(
            path: missing.path,
            kind: .camera,
            tags: ["plano"],
            isCopiedIntoProject: false,
            duration: 32,
            fileSize: 910_000,
            modifiedAt: Date(timeIntervalSince1970: 1_700_500_000),
            isLastKnownMissing: true
        )
        project.assets.append(missingAsset)
        AssetThumbnailCache.shared.seedForTesting(
            syntheticThumbnail(index: 6, label: "CAM"),
            for: missingAsset
        )
        assets.append(missingAsset)

        if !assets.isEmpty {
            appState.toggleAssetSceneLink(assetID: assets[0].id, sceneID: sceneB.id)
            appState.toggleAssetBRollLink(assetID: assets[0].id, bRollItemID: visual.id)
        }
        if assets.count > 1 {
            appState.toggleAssetSceneLink(assetID: assets[1].id, sceneID: sceneA.id)
            appState.toggleAssetSceneLink(assetID: assets[1].id, sceneID: sceneB.id)
        }
        if assets.count > 2 {
            appState.toggleAssetTakeLink(assetID: assets[2].id, takeID: take.id)
        }
        if assets.count > 3 {
            appState.toggleAssetTakeLink(assetID: assets[3].id, takeID: take.id)
        }
        return appState
    }

    private func syntheticThumbnail(index: Int, label: String) -> NSImage {
        let size = NSSize(width: 320, height: 180)
        let image = NSImage(size: size)
        let palette: [NSColor] = [
            NSColor(calibratedRed: 0.17, green: 0.29, blue: 0.45, alpha: 1),
            NSColor(calibratedRed: 0.29, green: 0.42, blue: 0.30, alpha: 1),
            NSColor(calibratedRed: 0.45, green: 0.30, blue: 0.27, alpha: 1),
            NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.45, alpha: 1),
            NSColor(calibratedRed: 0.43, green: 0.36, blue: 0.22, alpha: 1),
            NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.42, alpha: 1)
        ]
        image.lockFocus()
        let base = palette[index % palette.count]
        base.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSRect(x: 0, y: 0, width: 320, height: 72).fill()
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSRect(x: 24, y: 34, width: 112, height: 72).fill()
        let text = "\(label) · \(String(format: "%02d", index + 1))" as NSString
        text.draw(
            at: NSPoint(x: 24, y: 126),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        image.unlockFocus()
        return image
    }
}

private final class FramesBox {
    var frames: [String: CGRect] = [:]
}
