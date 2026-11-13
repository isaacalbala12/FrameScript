import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class TeleprompterReadingTests: XCTestCase {
    // MARK: Starting scene

    func testStartIndexSkipsAnEmptySelectedScene() {
        let scenes = [
            TeleprompterSceneText(id: UUID(), title: "01 HOOK", text: "Hola, esto es el gancho."),
            TeleprompterSceneText(id: UUID(), title: "02 CONTEXTO", text: ""),
            TeleprompterSceneText(id: UUID(), title: "07 CTA", text: "  \n ")
        ]
        XCTAssertEqual(
            TeleprompterContentBuilder.startingIndex(in: scenes, selectedIndex: 2),
            0
        )
    }

    func testStartIndexKeepsAReadableSelectedScene() {
        let scenes = [
            TeleprompterSceneText(id: UUID(), title: "01 HOOK", text: "Hola."),
            TeleprompterSceneText(id: UUID(), title: "02 CONTEXTO", text: "Seguimos.")
        ]
        XCTAssertEqual(
            TeleprompterContentBuilder.startingIndex(in: scenes, selectedIndex: 1),
            1
        )
    }

    func testStartIndexKeepsTheSelectionWhenEverySceneIsEmpty() {
        let scenes = (0..<3).map { index in
            TeleprompterSceneText(id: UUID(), title: "0\(index + 1)", text: "")
        }
        XCTAssertEqual(
            TeleprompterContentBuilder.startingIndex(in: scenes, selectedIndex: 2),
            2
        )
    }

    // MARK: Empty scenes

    func testSceneTitlesAreNotNumberedTwice() {
        XCTAssertEqual(TeleprompterAttributedStringBuilder.displayTitle("01 HOOK"), "HOOK")
        XCTAssertEqual(TeleprompterAttributedStringBuilder.displayTitle("7. CTA"), "CTA")
        XCTAssertEqual(TeleprompterAttributedStringBuilder.displayTitle("03 — Problema"), "Problema")
        XCTAssertEqual(TeleprompterAttributedStringBuilder.displayTitle("Escena 1"), "Escena 1")
        XCTAssertEqual(TeleprompterAttributedStringBuilder.displayTitle("100 ideas"), "100 ideas")
    }

    func testEmptySceneContributesNoReadingTime() {
        let hook = TeleprompterSection(
            sceneID: UUID(),
            title: "01 HOOK",
            runs: [.text("uno dos tres cuatro cinco seis siete ocho nueve diez once doce")]
        )
        let empty = TeleprompterSection(sceneID: UUID(), title: "02 VACÍA", runs: [])
        let cta = TeleprompterSection(sceneID: UUID(), title: "03 CTA", runs: [.text("uno dos tres")])
        let durations = TeleprompterTiming.estimatedDurations(
            for: [hook, empty, cta],
            wordsPerMinute: 60
        )

        XCTAssertEqual(durations[1], 0)
        XCTAssertEqual(durations[0], 12, accuracy: 0.000_001)
        XCTAssertEqual(durations[2], 3, accuracy: 0.000_001)
        XCTAssertEqual(
            TeleprompterTiming.estimatedDuration(for: [hook, empty, cta], wordsPerMinute: 60),
            15,
            accuracy: 0.000_001
        )
    }

    func testEmptySceneGetsAPlaceholderWithoutCountingAsSpokenText() {
        let hook = TeleprompterSection(sceneID: UUID(), title: "01 HOOK", runs: [.text("Hola mundo")])
        let empty = TeleprompterSection(sceneID: UUID(), title: "02 VACÍA", runs: [])
        let document = TeleprompterAttributedStringBuilder.build(
            sections: [hook, empty],
            fontSize: 64,
            emptyScenePlaceholder: "(escena vacía)"
        )

        XCTAssertTrue(document.attributedString.string.contains("(escena vacía)"))
        XCTAssertEqual(document.visibleCharacterCounts, [10, 0])
        XCTAssertGreaterThan(document.sectionBodyRanges[1].length, 0)
        let emptyBody = document.attributedString.attributedSubstring(
            from: document.sectionBodyRanges[1]
        ).string
        XCTAssertTrue(emptyBody.contains("(escena vacía)"))
        XCTAssertFalse(
            document.attributedString.attributedSubstring(
                from: document.sectionHeaderRanges[1]
            ).string.contains("(escena vacía)")
        )
    }

    func testCueOnlySceneKeepsItsCueAndGetsNoEmptyPlaceholder() {
        let section = TeleprompterSection(
            sceneID: UUID(),
            title: "01 HOOK",
            runs: [.cue("CAM"), .pause(2)]
        )
        let document = TeleprompterAttributedStringBuilder.build(
            sections: [section],
            fontSize: 64,
            emptyScenePlaceholder: "(escena vacía)"
        )

        XCTAssertTrue(document.attributedString.string.contains("▸ CAM"))
        XCTAssertFalse(document.attributedString.string.contains("(escena vacía)"))
        XCTAssertEqual(document.visibleCharacterCounts, [0])
    }

    // MARK: Reading-position mapping

    func testGuidePastTheContentEndDoesNotJumpToTrailingEmptyScenes() {
        let starts = [64.0, 164.0, 264.0]
        let heights = [100.0, 100.0, 100.0]

        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(
                offset: 0,
                readingContentY: 500,
                starts: starts,
                heights: heights,
                hasVisibleText: [true, false, false]
            ),
            0,
            "A guide below a mostly empty script must stay on the only readable scene"
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(
                offset: 0,
                readingContentY: 500,
                starts: starts,
                heights: heights,
                hasVisibleText: [true, true, false]
            ),
            1,
            "The last readable scene wins, never the trailing empty header"
        )
        XCTAssertEqual(
            TeleprompterLayout.currentSectionIndex(
                offset: 0,
                readingContentY: 500,
                starts: starts,
                heights: heights,
                hasVisibleText: [false, false, false]
            ),
            0,
            "An all-empty script must report the first scene, not the last"
        )
    }

    func testCounterTracksTheSceneUnderTheGuideAfterAClampedJump() throws {
        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("one two")]),
            TeleprompterSection(sceneID: UUID(), title: "Two", runs: [.text("three four")]),
            TeleprompterSection(sceneID: UUID(), title: "Three", runs: [.text("five six")])
        ]
        let model = try makeModel(sections: sections, start: 0)
        model.updateViewport(width: 1200, height: 600)
        model.updateTextMetrics(
            TeleprompterTextMetrics(
                contentHeight: 800,
                sectionStarts: [64, 800, 1400],
                sectionHeights: [736, 600, 400],
                visibleCharacterCounts: [7, 10, 8]
            )
        )
        XCTAssertEqual(model.currentSectionIndex, 0)

        // The target for scene 3 (1_400 - 200 + 48) is clamped to maxOffset
        // (200), so the guide never leaves scene 1. The header must follow the
        // geometry, not the requested index.
        model.jump(to: 2)
        XCTAssertEqual(model.offset, 200, accuracy: 0.000_001)
        XCTAssertEqual(model.currentSectionIndex, 0)
    }

    func testMirrorToggleKeepsTheReadingPositionAndEstimate() throws {
        let sections = (0..<7).map { index in
            TeleprompterSection(
                sceneID: UUID(),
                title: "Escena \(index + 1)",
                runs: [.text("Texto de la escena \(index + 1) con varias palabras para leer.")]
            )
        }
        let model = try makeModel(sections: sections, start: 0)
        model.updateViewport(width: 1512, height: 949)
        let renderer = TeleprompterTextRenderer(frame: NSRect(x: 0, y: 0, width: 1512, height: 949))
        model.attachRenderer(renderer)

        func layOut(mirror: Bool) {
            renderer.render(
                sections: sections,
                fontSize: 64,
                columnWidth: 900,
                viewportSize: CGSize(width: 1512, height: 949),
                readingLineFraction: 1.0 / 3.0,
                mirrorVertical: mirror,
                emptyScenePlaceholder: "(escena vacía)",
                onMetrics: { model.updateTextMetrics($0) }
            )
        }

        layOut(mirror: false)
        let before = model.elapsedEstimate
        model.settings.mirrorVertical = true
        layOut(mirror: true)
        let after = model.elapsedEstimate

        XCTAssertEqual(
            model.currentSectionIndex,
            0,
            "offset \(model.offset) starts \(model.sectionStarts) readingY \(model.readingContentY) heights \(model.sectionHeights) max \(model.maxOffset)"
        )
        XCTAssertLessThanOrEqual(
            abs(after - before),
            1.0,
            "Toggling mirror must not move the reading position (before \(before), after \(after), offset \(model.offset))"
        )
    }

    func testElapsedEstimateFollowsTheReadingLine() {
        let durations = [4.0, 6.0]
        let elapsed = TeleprompterTiming.elapsedEstimate(
            offset: 100,
            readingContentY: 100,
            starts: [0, 400],
            heights: [400, 600],
            hasVisibleText: [true, true],
            durations: durations
        )

        XCTAssertEqual(elapsed, 2, accuracy: 0.000_001)
    }

    func testTimeDoesNotReportTheEndWhileTheGuideIsInTheHook() {
        let hookDuration = 4.0
        let emptyDuration = 0.0
        let elapsed = TeleprompterTiming.elapsedEstimate(
            offset: 0,
            readingContentY: 200,
            starts: [64, 900],
            heights: [836, 100],
            hasVisibleText: [true, false],
            durations: [hookDuration, emptyDuration]
        )
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        XCTAssertLessThan(elapsed, hookDuration)
    }

    // MARK: Layout invariants

    func testHeaderFramesAscendAndNeverOverlapTextAtEverySize() {
        let sections = (0..<5).map { index in
            TeleprompterSection(
                sceneID: UUID(),
                title: "Escena \(index + 1)",
                runs: index == 2
                    ? []
                    : [.text(
                        "Línea \(index + 1) del guion con palabras suficientes para envolver en la columna y comprobar la separación de la cabecera. "
                            + "Seguimos con otra frase que también debe caber."
                    )]
            )
        }

        for fontSize in [24.0, 32.0, 48.0, 64.0, 96.0, 120.0] {
            for width in [320.0, 500.0, 900.0, 1400.0, 1600.0] {
                let renderer = TeleprompterTextRenderer(
                    frame: NSRect(x: 0, y: 0, width: 1512, height: 949)
                )
                var metrics: TeleprompterTextMetrics?
                renderer.render(
                    sections: sections,
                    fontSize: fontSize,
                    columnWidth: width,
                    viewportSize: CGSize(width: 1512, height: 949),
                    readingLineFraction: 1.0 / 3.0,
                    mirrorVertical: false,
                    emptyScenePlaceholder: "(escena vacía)",
                    onMetrics: { metrics = $0 }
                )
                renderer.layoutSubtreeIfNeeded()

                let sample = renderer.currentFrameSample()
                XCTAssertEqual(
                    sample.headerFrames.count,
                    sections.count,
                    "font \(fontSize), width \(width)"
                )
                XCTAssertFalse(sample.bodyLineFrames.isEmpty, "font \(fontSize), width \(width)")

                let headerOrigins = sample.headerFrames.map(\.minY)
                XCTAssertEqual(
                    headerOrigins,
                    headerOrigins.sorted(),
                    "Headers must run top-to-bottom when mirroring is off (font \(fontSize), width \(width))"
                )

                for header in sample.headerFrames {
                    for line in sample.bodyLineFrames {
                        let overlap = header.intersection(line)
                        XCTAssertLessThanOrEqual(
                            overlap.height,
                            0.5,
                            "Header \(header) overlaps text line \(line) at font \(fontSize), width \(width)"
                        )
                    }
                }

                if let metrics {
                    XCTAssertEqual(metrics.sectionStarts.count, sections.count)
                    for index in 1..<metrics.sectionStarts.count {
                        XCTAssertLessThan(
                            metrics.sectionStarts[index - 1],
                            metrics.sectionStarts[index],
                            "Section starts must ascend at font \(fontSize), width \(width)"
                        )
                    }
                }
            }
        }
    }

    // MARK: Live language

    func testOpenModelFollowsTheSettingsLanguage() throws {
        let languageSuite = "TeleprompterLanguage-\(UUID().uuidString)"
        let languageDefaults = try XCTUnwrap(UserDefaults(suiteName: languageSuite))
        addTeardownBlock {
            languageDefaults.removePersistentDomain(forName: languageSuite)
        }
        let settingsStore = SettingsStore(
            settings: AppSettings.defaults,
            userDefaults: languageDefaults,
            key: "settings"
        )

        let teleprompterSuite = "TeleprompterLanguageModel-\(UUID().uuidString)"
        let teleprompterDefaults = try XCTUnwrap(UserDefaults(suiteName: teleprompterSuite))
        addTeardownBlock {
            teleprompterDefaults.removePersistentDomain(forName: teleprompterSuite)
        }
        let model = TeleprompterModel(
            sections: [
                TeleprompterSection(sceneID: UUID(), title: "Uno", runs: [.text("Hola")])
            ],
            startingSectionIndex: 0,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: teleprompterDefaults),
            languageProvider: {
                L10n.resolve(
                    settingsStore.settings.generalPreferences.language,
                    preferredLanguages: ["es-ES"]
                )
            }
        )
        addTeardownBlock { model.stop() }

        settingsStore.settings.generalPreferences.language = .english
        XCTAssertEqual(model.language, .english)
        XCTAssertEqual(model.localized("teleprompter.speed"), "Speed")

        settingsStore.settings.generalPreferences.language = .spanish
        XCTAssertEqual(model.language, .spanish)
        XCTAssertEqual(model.localized("teleprompter.speed"), "Velocidad")

        settingsStore.settings.generalPreferences.language = .russian
        XCTAssertEqual(model.localized("teleprompter.speed"), "Скорость")

        settingsStore.settings.generalPreferences.language = .system
        XCTAssertEqual(model.language, .spanish, "es-ES is injected as the system preference")

        let revision = model.localizationRevision
        model.refreshLocalization()
        XCTAssertEqual(model.localizationRevision, revision + 1)
    }

    func testSettingsStorePostsTheLanguageChangeNotification() throws {
        let suiteName = "TeleprompterLanguageNotice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = SettingsStore(
            settings: AppSettings.defaults,
            userDefaults: defaults,
            key: "settings"
        )
        let expectation = expectation(
            forNotification: .frameScriptInterfaceLanguageDidChange,
            object: store,
            handler: nil
        )

        store.settings.generalPreferences.language = .spanish
        wait(for: [expectation], timeout: 1)
    }

    // MARK: Accessibility and input

    func testTextViewIsInertAndExposedAsStaticText() {
        let sections = [
            TeleprompterSection(sceneID: UUID(), title: "Uno", runs: [.text("Hola mundo")])
        ]
        let renderer = TeleprompterTextRenderer(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        renderer.render(
            sections: sections,
            fontSize: 64,
            columnWidth: 900,
            viewportSize: CGSize(width: 1200, height: 800),
            readingLineFraction: 1.0 / 3.0,
            mirrorVertical: false,
            onMetrics: { _ in }
        )

        let state = renderer.textViewAccessibilityState
        XCTAssertFalse(state.acceptsFirstResponder)
        XCTAssertFalse(state.isEditable)
        XCTAssertFalse(state.isSelectable)
        XCTAssertEqual(renderer.accessibilityRole(), .staticText)
        XCTAssertEqual(renderer.accessibilityValue() as? String, renderer.documentText)
        XCTAssertTrue(renderer.documentText.contains("Hola mundo"))
    }

    func testShortcutsOnlyFireForAKeyWindowWithoutTextFocus() {
        XCTAssertTrue(
            TeleprompterKeyRouting.shouldHandleShortcut(windowIsKey: true, firstResponder: nil)
        )
        XCTAssertTrue(
            TeleprompterKeyRouting.shouldHandleShortcut(
                windowIsKey: true,
                firstResponder: NSButton(frame: .zero)
            )
        )
        XCTAssertFalse(
            TeleprompterKeyRouting.shouldHandleShortcut(windowIsKey: false, firstResponder: nil)
        )
        XCTAssertFalse(
            TeleprompterKeyRouting.shouldHandleShortcut(
                windowIsKey: true,
                firstResponder: NSTextView(frame: .zero)
            )
        )
        XCTAssertFalse(
            TeleprompterKeyRouting.shouldHandleShortcut(
                windowIsKey: true,
                firstResponder: NSTextField(frame: .zero)
            )
        )
    }

    // MARK: Language

    func testSpanishTeleprompterStringsResolveFromSystemLanguage() {
        let preferred = ["es-ES"]
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: preferred), .spanish)
        XCTAssertEqual(
            L10n.tr("teleprompter.speed", language: .system, preferredLanguages: preferred),
            "Velocidad"
        )
        XCTAssertEqual(
            L10n.tr("teleprompter.previousScene", language: .system, preferredLanguages: preferred),
            "Escena anterior"
        )
        XCTAssertEqual(
            L10n.tr("teleprompter.emptyScene", language: .system, preferredLanguages: preferred),
            "(escena vacía)"
        )
        XCTAssertEqual(
            L10n.tr("teleprompter.mirrorVerticalBadge", language: .system, preferredLanguages: preferred),
            "Espejo vertical"
        )
        XCTAssertEqual(
            L10n.tr("voiceFollow.toggle", language: .system, preferredLanguages: preferred),
            "Seguir mi voz"
        )
        XCTAssertTrue(
            Bundle.main.localizations.contains("es"),
            "The app bundle must advertise Spanish: \(Bundle.main.localizations.sorted())"
        )
    }

    // MARK: Helpers

    private func makeModel(
        sections: [TeleprompterSection],
        start: Int
    ) throws -> TeleprompterModel {
        let suiteName = "TeleprompterReading-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let model = TeleprompterModel(
            sections: sections,
            startingSectionIndex: start,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: defaults)
        )
        addTeardownBlock {
            model.stop()
        }
        return model
    }
}
