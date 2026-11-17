import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Offscreen rendering for F18. Nothing is ordered front, no synthetic input is
/// sent, and the fixture is synthetic Spanish copy owned by this test.
@MainActor
final class TimelineSnapshotTests: XCTestCase {
    private let sizes: [CGSize] = [
        CGSize(width: 1180, height: 760),
        CGSize(width: 980, height: 712)
    ]

    func testTimelinePanelMeetsLayoutInvariantsAtEverySizeAndAppearance() throws {
        for size in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let rendered = try render(size: size, scheme: scheme, writeSnapshot: false)
                XCTAssertEqual(rendered.pixelSize, size)
                XCTAssertGreaterThan(rendered.distinctColors, 8, "Blank timeline at \(size) \(scheme)")
                assertLayoutInvariants(size: size)
            }
        }
        XCTAssertEqual(L10n.tr("timeline.title", language: .spanish), "Línea de tiempo del guion")
        XCTAssertEqual(L10n.tr("timeline.track.narration", language: .spanish), "Narración")
        XCTAssertEqual(L10n.tr("timeline.dragHint", language: .spanish), "Arrastra para reordenar")
    }

    func testTimelinePanelSnapshotMatrix() throws {
        let wantsSnapshots = ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1"
        var written: [String] = []

        for size in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let name = "timeline-\(Int(size.width))x\(Int(size.height))-\(scheme == .dark ? "dark" : "light").png"
                let rendered = try render(
                    size: size,
                    scheme: scheme,
                    writeSnapshot: wantsSnapshots,
                    name: name
                )
                XCTAssertEqual(rendered.pixelSize, size)
                XCTAssertGreaterThan(rendered.distinctColors, 8)
                assertLayoutInvariants(size: size)
                if wantsSnapshots {
                    written.append("/tmp/fs-snapshots/w3-b-timeline/\(name)")
                }
            }
        }

        if wantsSnapshots {
            for path in written {
                print("FS_SNAPSHOT \(path)")
            }
            XCTAssertEqual(written.count, 4)
        }
    }

    // MARK: Invariants

    private func assertLayoutInvariants(size: CGSize) {
        let metrics = TimelineTrackMetrics.standard
        var previousBottom: CGFloat = metrics.rulerHeight

        for track in TimelineTrack.allCases {
            let range = metrics.yRange(for: track)
            XCTAssertGreaterThan(range.lowerBound, previousBottom - 0.001, "Overlapping \(track.rawValue) rows")
            XCTAssertLessThan(range.lowerBound, range.upperBound)
            XCTAssertLessThanOrEqual(range.upperBound, metrics.totalHeight + 0.001)
            previousBottom = range.upperBound
        }

        // Header (60) + two dividers + footer (34) must leave the whole canvas
        // visible at the smallest supported window.
        let panelChrome: CGFloat = 60 + 2 + 34
        XCTAssertLessThanOrEqual(
            metrics.totalHeight + panelChrome,
            size.height,
            "Timeline canvas is clipped at \(size)"
        )
        XCTAssertLessThanOrEqual(metrics.totalHeight, 560)

        let layout = syntheticLayout()
        XCTAssertFalse(layout.blocks(on: .scenes).isEmpty)
        XCTAssertFalse(layout.blocks(on: .narration).isEmpty)
        XCTAssertFalse(layout.blocks(on: .pauses).isEmpty)
        XCTAssertFalse(layout.blocks(on: .bRoll).isEmpty)
        XCTAssertFalse(layout.blocks(on: .editing).isEmpty)
        XCTAssertFalse(layout.blocks(on: .takes).isEmpty)
        XCTAssertFalse(layout.blocks(on: .warnings).isEmpty)
    }

    // MARK: Rendering

    private struct Rendered {
        let pixelSize: CGSize
        let distinctColors: Int
    }

    private func render(
        size: CGSize,
        scheme: ColorScheme,
        writeSnapshot: Bool,
        name: String = "timeline.png"
    ) throws -> Rendered {
        let theme = FrameTheme(colorScheme: scheme, accent: .sage)
        let layout = syntheticLayout()
        let pointsPerSecond = min(
            TimelineZoom.maximumPointsPerSecond,
            max(6, (Double(size.width) - 125) / max(1, layout.totalDuration))
        )
        let root = TimelinePanelView(
            layout: layout,
            language: .spanish,
            theme: theme,
            pointsPerSecond: pointsPerSecond,
            zoomFraction: .constant(TimelineZoom.fraction(forPointsPerSecond: pointsPerSecond)),
            selectedBlockID: layout.blocks(on: .narration).first?.id,
            selectedSceneID: layout.scenes.first?.id,
            isPending: false,
            onSelectBlock: { _ in },
            onMoveScene: { _, _ in },
            onZoomIn: {},
            onZoomOut: {},
            onZoomChange: { _ in }
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)
        .environment(\.frameTheme, theme)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.setIsVisible(false)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("Could not create a bitmap for the timeline panel")
            return Rendered(pixelSize: .zero, distinctColors: 0)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode the timeline panel")
            return Rendered(pixelSize: .zero, distinctColors: 0)
        }
        XCTAssertGreaterThan(data.count, 2_000, "Snapshot is suspiciously small")

        if writeSnapshot {
            let directory = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-b-timeline", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }

        return Rendered(
            pixelSize: rep.size,
            distinctColors: distinctColors(in: rep)
        )
    }

    private func distinctColors(in rep: NSBitmapImageRep) -> Int {
        guard let data = rep.bitmapData, rep.bitsPerPixel >= 24 else { return 0 }
        let bytesPerPixel = max(1, rep.bitsPerPixel / 8)
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 12) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 12) {
                let index = y * rep.bytesPerRow + x * bytesPerPixel
                let red = UInt32(data[index])
                let green = UInt32(data[index + 1])
                let blue = UInt32(data[index + 2])
                colors.insert((red << 16) | (green << 8) | blue)
                if colors.count > 64 { return colors.count }
            }
        }
        return colors.count
    }

    // MARK: Fixture

    /// Synthetic Spanish copy, deliberately generic so it never carries real
    /// script text or personal data.
    private func syntheticLayout() -> TimelineLayout {
        let first = "Abres la aplicación y la primera duda ya está ahí.\n\n¿Dónde estaba aquella toma [pausa 1s] que juraste no perder?\n\nHoy montamos el guion sin saltar entre ventanas."
        let second = "El problema no es escribir: es reconstruir el contexto cada vez.\n\nUna frase aprobada se queda sin plano / y el editor empieza a adivinar.\n\nEse hueco cuesta minutos que nadie factura."
        let third = "La línea de tiempo muestra la escena completa de un vistazo.\n\nLos párrafos ocupan su tiempo real [pausa 2s] y cada pausa tiene su propio bloque.\n\nArrastra una escena y el orden cambia en un solo paso."
        let fourth = "Cierra el proyecto con una decisión clara.\n\nPrueba el modo Línea y vuelve al guion cuando quieras."

        let scenes = [
            makeScene(
                title: "Gancho",
                text: first,
                bRoll: [("primera duda", 3), ("aquella toma", 2)],
                editing: ["Hoy montamos"],
                takes: [(1, 34, false, .safe), (2, 31, true, .good)],
                warnings: [(.longSentence, "primera duda"), (.noVisualChange, "Hoy montamos")]
            ),
            makeScene(
                title: "Problema",
                text: second,
                bRoll: [("contexto", 4)],
                editing: ["editor empieza"],
                takes: [(1, 29, true, .good)],
                warnings: [(.longSentence, "reconstruir el contexto")]
            ),
            makeScene(
                title: "Demostración",
                text: third,
                bRoll: [("línea de tiempo", 3), ("párrafos", 2), ("Arrastra", 2)],
                editing: ["pausa", "Arrastra"],
                takes: [(1, 26, false, .bad), (2, 24, false, .safe), (3, 23, true, .good)],
                warnings: []
            ),
            makeScene(
                title: "Cierre",
                text: fourth,
                bRoll: [("decisión clara", 3)],
                editing: ["vuelve al guion"],
                takes: [],
                warnings: []
            )
        ]

        return TimelineLayoutBuilder.build(
            scenes: scenes,
            configuration: TimelineConfiguration(
                wordsPerMinute: 95,
                pauseDefaults: PauseDefaults(short: 0.5, long: 1.2)
            )
        )
    }

    private func makeScene(
        title: String,
        text: String,
        bRoll: [(String, TimeInterval)],
        editing: [String],
        takes: [(Int, TimeInterval, Bool, TimelineTakeRating)],
        warnings: [(RhythmWarning.Kind, String)]
    ) -> TimelineSceneInput {
        let nsText = text as NSString
        func offset(_ phrase: String) -> Int? {
            let range = nsText.range(of: phrase)
            return range.location == NSNotFound ? nil : range.location
        }

        return TimelineSceneInput(
            id: UUID(),
            title: title,
            text: text,
            takes: takes.map { number, duration, selected, rating in
                TimelineTakeInput(
                    id: UUID(),
                    number: number,
                    duration: duration,
                    isSelected: selected,
                    rating: rating
                )
            },
            bRoll: bRoll.map { phrase, duration in
                TimelineMarkerInput(
                    id: UUID(),
                    anchorUTF16: offset(phrase),
                    duration: duration,
                    label: phrase
                )
            },
            editing: editing.map { phrase in
                TimelineMarkerInput(id: UUID(), anchorUTF16: offset(phrase), label: phrase)
            },
            warnings: warnings.compactMap { kind, phrase in
                guard let location = offset(phrase) else { return nil }
                let range = nsText.range(of: phrase)
                return TimelineWarningInput(kind: kind, location: location, length: range.length)
            }
        )
    }
}
