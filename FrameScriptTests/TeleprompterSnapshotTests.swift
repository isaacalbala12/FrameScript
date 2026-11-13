import AppKit
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

/// Renders the real teleprompter hierarchy (`TeleprompterRootView` inside an
/// `NSHostingView` in an offscreen, never-ordered-front window) and verifies the
/// layout without needing to look at an image.
///
/// Set `FS_SNAPSHOTS=1` to also write 1512x949 PNGs to
/// `/tmp/fs-snapshots/teleprompter/`. The PNGs are the visual evidence for a
/// human reviewer; the assertions below run with or without them.
@MainActor
final class TeleprompterSnapshotTests: XCTestCase {
    private let viewport = CGSize(width: 1512, height: 949)
    private let outputDirectory = "/tmp/fs-snapshots/teleprompter"

    func testSnapshotStates() throws {
        try snapshot(
            name: "01-default-start",
            scenes: Fixtures.fullScript(),
            start: 0
        )

        try snapshot(
            name: "02-mid-scene-3",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            let sceneID = harness.model.sections[2].sceneID
            let count = harness.model.visibleCharacterCounts.indices.contains(2)
                ? harness.model.visibleCharacterCounts[2]
                : 0
            harness.model.restore(
                anchor: TeleprompterReadingAnchor(
                    sceneID: sceneID,
                    characterOffset: max(1, count / 2)
                )
            )
        }

        try snapshot(
            name: "03-mirror-horizontal",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.settings.mirrorHorizontal = true
        }

        try snapshot(
            name: "04-mirror-vertical",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.settings.mirrorVertical = true
        }

        try snapshot(
            name: "05-font-120",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.settings.fontSize = 120
        }

        try snapshot(
            name: "06-narrow-column-500",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.settings.columnWidth = 500
        }

        try snapshot(
            name: "07-empty-scene",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.jump(to: Fixtures.emptySceneIndex)
        }

        try snapshot(
            name: "08-voice-controls",
            scenes: Fixtures.fullScript(),
            start: 0
        ) { harness in
            harness.model.controlsVisible = true
        }

        try snapshot(
            name: "09-light-appearance",
            scenes: Fixtures.fullScript(),
            start: 0,
            appearance: .aqua
        )

        try snapshot(
            name: "10-reported-project-hook-only",
            scenes: Fixtures.reportedProject(),
            start: TeleprompterContentBuilder.startingIndex(
                in: Fixtures.reportedProject(),
                selectedIndex: 6
            )
        ) { harness in
            // The reported project selected the CTA scene in the editor. The
            // prompter must still open on the only readable scene (the hook).
            XCTAssertEqual(harness.model.currentSectionIndex, 0)
            XCTAssertEqual(harness.model.sections.count, 7)
        }

        try snapshot(
            name: "11-markup-tokens",
            scenes: Fixtures.markupTokens(),
            start: 0
        ) { harness in
            // Every token on one screen: 36 pt keeps the four pause lines, two
            // cue lines and the closing sentence above the bottom HUD.
            harness.model.settings.fontSize = 36
        }
    }

    // MARK: Harness

    func testOpenWindowRebuildsStringsWhenLanguageChanges() throws {
        let language = LanguageBox(.spanish)
        let harness = try Harness(
            scenes: Fixtures.reportedProject(),
            start: 0,
            viewport: viewport,
            appearance: .darkAqua,
            languageProvider: { language.value }
        )
        defer { harness.tearDown() }

        let renderer = try XCTUnwrap(
            harness.model.attachedTextRenderer as? TeleprompterTextRenderer
        )
        XCTAssertEqual(harness.model.language, .spanish)
        XCTAssertTrue(renderer.documentText.contains("(escena vacía)"))

        language.value = .english
        NotificationCenter.default.post(
            name: .frameScriptInterfaceLanguageDidChange,
            object: nil
        )
        harness.pump()

        XCTAssertEqual(harness.model.language, .english)
        XCTAssertEqual(harness.model.emptyScenePlaceholder, "(empty scene)")
        XCTAssertTrue(
            renderer.documentText.contains("(empty scene)"),
            "The open window must rebuild its placeholder in the new language"
        )
        XCTAssertFalse(renderer.documentText.contains("(escena vacía)"))
    }

    private func snapshot(
        name: String,
        scenes: [TeleprompterSceneText],
        start: Int,
        appearance: NSAppearance.Name = .darkAqua,
        configure: ((Harness) -> Void)? = nil
    ) throws {
        let harness = try Harness(
            scenes: scenes,
            start: start,
            viewport: viewport,
            appearance: appearance
        )
        defer { harness.tearDown() }

        configure?(harness)
        harness.pump()
        try assertLayoutInvariants(harness)
        try harness.writePNG(named: name, to: outputDirectory)
    }

    /// Invariants that hold without any image:
    /// - headers run top-to-bottom when mirroring is off,
    /// - no header frame overlaps a body line,
    /// - the reported scene is the one under the reading line.
    private func assertLayoutInvariants(
        _ harness: Harness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let renderer = try XCTUnwrap(
            harness.model.attachedTextRenderer as? TeleprompterTextRenderer,
            "The real AppKit renderer must be attached",
            file: file,
            line: line
        )
        let sample = renderer.currentFrameSample()
        let sectionCount = harness.model.sections.count

        XCTAssertEqual(sample.headerFrames.count, sectionCount, file: file, line: line)
        XCTAssertFalse(sample.bodyLineFrames.isEmpty, file: file, line: line)

        if !harness.model.settings.mirrorVertical {
            let origins = sample.headerFrames.map(\.minY)
            XCTAssertEqual(
                origins,
                origins.sorted(),
                "Scene headers must run top-to-bottom when vertical mirroring is off",
                file: file,
                line: line
            )
        }

        for header in sample.headerFrames {
            for bodyLine in sample.bodyLineFrames {
                XCTAssertLessThanOrEqual(
                    header.intersection(bodyLine).height,
                    0.5,
                    "Header \(header) overlaps text \(bodyLine)",
                    file: file,
                    line: line
                )
            }
        }

        let guide = harness.model.offset + harness.model.readingContentY
        let contentEnd: Double
        if let lastStart = sample.sectionStarts.last,
           let lastHeight = sample.sectionHeights.last {
            contentEnd = lastStart + lastHeight
        } else {
            contentEnd = .greatestFiniteMagnitude
        }
        let expected: Int
        if guide < contentEnd {
            var indexUnderGuide = 0
            for (index, frame) in sample.headerFrames.enumerated() where frame.minY <= guide {
                indexUnderGuide = index
            }
            expected = indexUnderGuide
        } else {
            expected = harness.model.sections.lastIndex(where: \.hasVisibleText) ?? 0
        }
        XCTAssertEqual(
            harness.model.currentSectionIndex,
            expected,
            "Scene counter must match the header under the reading line (guide \(guide))",
            file: file,
            line: line
        )

        let textViewState = renderer.textViewAccessibilityState
        XCTAssertFalse(textViewState.isEditable, file: file, line: line)
        XCTAssertFalse(textViewState.isSelectable, file: file, line: line)
        XCTAssertFalse(textViewState.acceptsFirstResponder, file: file, line: line)
    }

    // MARK: Harness implementation

    @MainActor
    private final class Harness {
        let model: TeleprompterModel
        private let window: NSWindow
        private let hostingView: NSHostingView<AnyView>
        private let defaults: UserDefaults
        private let suiteName: String

        init(
            scenes: [TeleprompterSceneText],
            start: Int,
            viewport: CGSize,
            appearance: NSAppearance.Name,
            languageProvider: (@MainActor () -> AppLanguage)? = nil
        ) throws {
            suiteName = "TeleprompterSnapshot-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let settingsStore = TeleprompterSettingsStore(userDefaults: defaults)
            settingsStore.save(
                TeleprompterSettings(
                    wordsPerMinute: 150,
                    fontSize: 64,
                    columnWidth: 900,
                    mirrorHorizontal: false,
                    mirrorVertical: false,
                    readingLineFraction: 1.0 / 3.0,
                    countdownEnabled: false
                )
            )

            let sections = TeleprompterContentBuilder.sections(from: scenes)
            model = TeleprompterModel(
                sections: sections,
                startingSectionIndex: start,
                language: .spanish,
                settingsStore: settingsStore,
                sceneProvider: nil,
                resumeAnchor: nil,
                speechLanguage: nil,
                speechRecognizer: nil,
                languageProvider: languageProvider
            )
            model.updateViewport(width: viewport.width, height: viewport.height)

            let root = TeleprompterRootView(model: model)
                .environment(\.colorScheme, appearance == .aqua ? .light : .dark)
            hostingView = NSHostingView(rootView: AnyView(root))
            hostingView.frame = NSRect(origin: .zero, size: viewport)
            hostingView.appearance = NSAppearance(named: appearance)

            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: viewport),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            // Keep it far offscreen and never order it front. This test must
            // not change the user's focus or show a window.
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderOut(nil)
            hostingView.layoutSubtreeIfNeeded()

            pump(timeout: 4) {
                self.model.attachedTextRenderer != nil
                    && !self.model.isAwaitingLayout
                    && !self.model.sectionStarts.isEmpty
            }
        }

        func pump(timeout: TimeInterval = 2) {
            pump(timeout: timeout) { !self.model.isAwaitingLayout }
            // One extra turn so SwiftUI commits the scale effect and metrics.
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }

        private func pump(timeout: TimeInterval, until condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                hostingView.layoutSubtreeIfNeeded()
            }
        }

        func writePNG(named name: String, to directory: String) throws {
            guard ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" else { return }
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: 1512,
                    pixelsHigh: 949,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            )
            rep.size = NSSize(width: 1512, height: 949)
            hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory, isDirectory: true),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }

        func tearDown() {
            model.stop()
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

// MARK: - Fixtures

@MainActor
private final class LanguageBox {
    var value: AppLanguage
    init(_ value: AppLanguage) { self.value = value }
}

private enum Fixtures {
    /// Index of the deliberately empty scene in `fullScript()`.
    static let emptySceneIndex = 3

    static func fullScript() -> [TeleprompterSceneText] {
        [
            scene(
                "01 HOOK",
                "El gancho que engancha en los primeros segundos. Una promesa clara y directa."
            ),
            scene(
                "02 CONTEXTO",
                "De dónde venimos y por qué esta historia importa ahora mismo. *Un matiz* que cambia la lectura."
            ),
            scene(
                "03 PROBLEMA",
                "El problema real no es el que parece. / Es la fricción que nadie ha medido todavía.\n[CAM: Plano medio]"
            ),
            scene("04 GIRO", ""),
            scene(
                "05 PRUEBA",
                "Probamos la idea con tres ejemplos distintos. **El resultado** fue más consistente de lo esperado."
            ),
            scene(
                "06 RESULTADO",
                "Lo que cambia cuando aplicas este sistema. Dos pasos concretos y una señal para saber que funciona."
            ),
            scene(
                "07 CTA",
                "Si esto te sirve, guarda el vídeo y escríbeme qué parte quieres que desarrolle en el siguiente."
            )
        ]
    }

    /// The exact shape of the project in the bug report: seven scenes, only the
    /// hook has one line of text.
    static func reportedProject() -> [TeleprompterSceneText] {
        [
            scene("01 HOOK", "Hola, esto es el gancho."),
            scene("02 CONTEXTO", ""),
            scene("03 PROBLEMA", ""),
            scene("04 GIRO", ""),
            scene("05 PRUEBA", ""),
            scene("06 RESULTADO", ""),
            scene("07 CTA", "")
        ]
    }

    /// Every markup token the editor and teleprompter share: short and long
    /// slashes, bracketed pauses with and without a decimal comma, both
    /// emphasis levels and two cue lines.
    static func markupTokens() -> [TeleprompterSceneText] {
        [
            scene(
                "01 MARKUP",
                "*Énfasis suave* y **fuerza fuerte**. / // [pausa 2s] [1,5 s]\n[CAM: Plano medio]\n[IMAGEN: Gráfico de resultados]"
            )
        ]
    }

    private static func scene(_ title: String, _ text: String) -> TeleprompterSceneText {
        TeleprompterSceneText(id: UUID(), title: title, text: text)
    }
}
