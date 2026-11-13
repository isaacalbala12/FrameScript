import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Regression tests for WP6 (visual UI, accessibility and theme).
///
/// The contrast, styling and plural checks are pure. The toolbar, settings and
/// B-roll checks render the real views through `SnapshotRenderer`, which also
/// writes PNGs when `FS_SNAPSHOTS=1`.
@MainActor
final class WP6VisualTests: FrameScriptTestCase {
    // MARK: - Theme contrast

    /// Every text token must reach WCAG AA (4.5:1) on every surface it can be
    /// drawn on, in light and dark mode, for every accent.
    func testThemeTextTokensMeetWCAGAAOnEverySurface() {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentPalette.allCases {
                let theme = FrameTheme(colorScheme: scheme, accent: accent)
                for surface in theme.textSurfaces {
                    for (name, color) in [
                        ("primaryText", theme.primaryText),
                        ("secondaryText", theme.secondaryText),
                        ("tertiaryText", theme.tertiaryText)
                    ] {
                        assertContrast(color, on: surface, "\(name) \(accent) \(scheme)")
                    }
                }
                // Accent-as-text is contracted against the app background; the
                // toolbar draws it on the same colour.
                assertContrast(theme.accentText, on: theme.appBackground, "accentText \(accent) \(scheme)")
                assertContrast(theme.accentText, on: theme.windowBackground, "accentText/window \(accent) \(scheme)")
                // Filled primary buttons use white text on `accentStrong`.
                assertContrast(.white, on: theme.accentStrong, "accentStrong \(accent) \(scheme)")
            }
        }
    }

    /// Record, stop and countdown buttons pick their foreground from the fill,
    /// so every fill the panel can produce must reach 4.5:1.
    func testFilledRecordingControlsUseAReadableForeground() {
        for scheme in [ColorScheme.light, .dark] {
            for accent in AccentPalette.allCases {
                let theme = FrameTheme(colorScheme: scheme, accent: accent)
                let states: [(String, RecordingPhase, Bool)] = [
                    ("connected idle", .idle, true),
                    ("disconnected idle", .idle, false),
                    ("starting disconnected", .starting, false),
                    ("countdown", .countdown(3), true),
                    ("recording", .recording(startedAt: Date()), true),
                    ("stopping", .stopping, true)
                ]
                for (name, phase, connected) in states {
                    let palette = RecordingButtonPalette.colors(phase: phase, connected: connected, theme: theme)
                    let renderedFill = composite(
                        NSColor(palette.fill),
                        over: NSColor(theme.panelBackground)
                    )
                    let ratio = MarkupEditorPalette.contrastRatio(NSColor(palette.foreground), renderedFill)
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(name) \(accent) \(scheme): \(ratio):1"
                    )
                }
            }
        }
    }

    // MARK: - Rhythm marks

    func testRhythmMarkSkipsBlankLinesInsideTheWarningRange() {
        let textView = makeRhythmTextView("Uno dos\n\nTres cuatro")
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.rhythmUnderlines = [RhythmEditorUnderline(range: range, kind: .longSentence, message: "aviso")]

        let marks = textView.rhythmMarkRects()

        // Two paragraphs, so two marks: the empty line between them gets none.
        XCTAssertEqual(marks.count, 2)
        for mark in marks {
            XCTAssertGreaterThan(mark.width, 0)
            XCTAssertLessThanOrEqual(mark.maxX, textView.bounds.width + 0.5)
        }
    }

    func testRhythmMarkIgnoresWhitespaceOnlyRanges() {
        let textView = makeRhythmTextView("Primero\n   \nSegundo")
        let blankLine = (textView.string as NSString).range(of: "   ")
        textView.rhythmUnderlines = [RhythmEditorUnderline(range: blankLine, kind: .longSentence, message: "aviso")]

        XCTAssertTrue(textView.rhythmMarkRects().isEmpty)
    }

    func testSceneLengthOutlierDrawsNoMark() {
        let textView = makeRhythmTextView("Una escena demasiado larga.")
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.rhythmUnderlines = [RhythmEditorUnderline(range: range, kind: .sceneLengthOutlier, message: "larga")]

        XCTAssertTrue(textView.rhythmMarkRects().isEmpty)
    }

    func testRhythmMarkTooltipsSkipBlankLines() {
        let textView = makeRhythmTextView("Uno dos\n\nTres cuatro")
        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.rhythmUnderlines = [RhythmEditorUnderline(range: range, kind: .longSentence, message: "aviso")]
        textView.refreshRhythmToolTips()

        XCTAssertEqual(textView.rhythmToolTipRects().count, 2)
    }

    // MARK: - Scene list navigation

    func testSceneListArrowKeysStopAtTheEnds() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let ids = [first, second, third]

        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: first, direction: .up), nil)
        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: first, direction: .down), second)
        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: second, direction: .down), third)
        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: third, direction: .down), nil)
        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: third, direction: .up), second)
        XCTAssertEqual(SceneListNavigation.destination(in: ids, current: nil, direction: .down), first)
        XCTAssertEqual(SceneListNavigation.destination(in: [], current: nil, direction: .down), nil)
    }

    // MARK: - Toolbar

    func testToolbarKeepsTheCommandPaletteKeycapAtMinimumWidth() {
        let appState = makeSnapshotAppState()
        for size in [CGSize(width: 1180, height: 58), CGSize(width: 980, height: 58)] {
            let name = "toolbar-\(Int(size.width))x\(Int(size.height))"
            let result = SnapshotRenderer.render(
                TopToolbar(),
                name: name,
                suite: "WP6VisualTests",
                size: size,
                appearance: .light,
                language: .spanish,
                appState: appState
            )
            let shortcut = appState.shortcutDisplay(for: .commandPalette)
            XCTAssertFalse(shortcut.isEmpty)
            XCTAssertTrue(
                result.textFragments.contains { $0.contains(shortcut) },
                "\(name): the command-palette keycap \(shortcut) is not laid out"
            )
        }
    }

    // MARK: - Settings

    func testEditorSettingsShowTheWordsPerMinuteUnit() {
        let appState = makeSnapshotAppState()
        appState.windowState.requestedSettingsTab = .editor
        let result = SnapshotRenderer.render(
            SettingsRootView(),
            name: "settings-editor-wpm-unit",
            suite: "WP6VisualTests",
            size: CGSize(width: 940, height: 650),
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        let unit = L10n.tr("hooks.wpm", language: .spanish)
        XCTAssertEqual(unit, "ppm")
        XCTAssertTrue(
            result.textFragments.contains { $0.contains("150 \(unit)") || $0.replacingOccurrences(of: " ", with: "").contains("150\(unit)") },
            "editor settings must show the localized wpm unit next to the global value; text was \(result.textFragments)"
        )
    }

    /// The headless SwiftUI accessibility tree is empty (SwiftUI only builds it
    /// for a real accessibility client), so this guards the source of the three
    /// view files WP6 owns: no unnamed picker or toggle may come back.
    func testOwnedViewSourcesNeverPassAnEmptyControlLabel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "FrameScript/Features/Settings/SettingsView.swift",
            "FrameScript/Features/BRoll/BRollEditorView.swift",
            "FrameScript/Features/Recording/RecordingPanel.swift",
            "FrameScript/Components/FormBits.swift"
        ]
        for file in files {
            let source = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(source.contains("Picker(\"\""), "\(file): Picker with an empty label")
            XCTAssertFalse(source.contains("Toggle(\"\""), "\(file): Toggle with an empty label")
        }
        let formBits = try String(
            contentsOf: root.appendingPathComponent("FrameScript/Components/FormBits.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(formBits.contains(".accessibilityLabel(placeholder)"), "MultilineField lost its accessible name")
    }

    // MARK: - Empty production state

    func testEmptyBRollStateOffersAWayBackToTheScript() {
        let project = SampleData.defaultProject
        let scene = project.scenes.sortedByOrder[0]
        scene.scriptText = ""
        scene.bRollItems = []
        let appState = makeSnapshotAppState(project: project)
        appState.editorState.selectedMode = .bRoll
        appState.editorState.selectedSceneID = scene.id
        let actionTitle = L10n.tr("production.goToScript", language: .spanish)

        for size in SnapshotSize.allCases {
            for appearance in SnapshotAppearance.allCases {
                let name = "broll-empty-\(size.label)-\(appearance.rawValue)"
                let result = SnapshotRenderer.render(
                    AppShellView(),
                    name: name,
                    suite: "WP6VisualTests",
                    size: size.size,
                    appearance: appearance,
                    language: .spanish,
                    appState: appState
                )
                XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels")
                XCTAssertTrue(
                    result.textFragments.contains { $0.contains(actionTitle) },
                    "\(name): the empty B-roll state must offer '\(actionTitle)'"
                )
            }
        }
    }

    // MARK: - Recording strings

    func testRecordingLanguageNamesUseTheInterfaceLanguage() {
        XCTAssertEqual(RecordingLanguageNames.name(for: "en", interfaceLanguage: .spanish), "Inglés")
        XCTAssertEqual(RecordingLanguageNames.name(for: "en", interfaceLanguage: .russian), "Английский")
        XCTAssertEqual(RecordingLanguageNames.name(for: "es", interfaceLanguage: .english), "Spanish")
        XCTAssertEqual(RecordingLanguageNames.name(for: "", interfaceLanguage: .spanish), "")
    }

    /// The language picker must show the name in the interface language, not in
    /// the Mac's current locale (`Locale.current` was the old behaviour). Both
    /// renders are asserted so the test fails on an English, Spanish *or*
    /// Russian Mac.
    func testRecordingLanguagePickerUsesTheInterfaceLanguage() {
        let project = SampleData.defaultProject
        let scene = project.scenes.sortedByOrder[0]
        scene.languageVariants = [
            SceneLanguageVariant(languageCode: "es", text: scene.scriptText),
            SceneLanguageVariant(languageCode: "en", text: "English take.")
        ]
        let appState = makeSnapshotAppState(project: project)
        appState.recording.selectedLanguageCode = "en"

        for (language, expected) in [
            (AppLanguage.spanish, "Inglés"),
            (AppLanguage.russian, "Английский")
        ] {
            let result = SnapshotRenderer.render(
                RecordingPanel(),
                name: "recording-language-picker-\(language.rawValue)",
                suite: "WP6VisualTests",
                size: CGSize(width: 330, height: 700),
                appearance: .light,
                language: language,
                appState: appState
            )
            XCTAssertTrue(
                result.textFragments.contains { $0.contains(expected) },
                "the language picker must read '\(expected)' in a \(language.rawValue) UI; text was \(result.textFragments)"
            )
        }
    }

    func testRecordingTakesCountUsesPlurals() {
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 1, language: .spanish), "1 toma")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 3, language: .spanish), "3 tomas")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 1, language: .english), "1 take")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 4, language: .english), "4 takes")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 1, language: .russian), "1 дубль")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 3, language: .russian), "3 дубля")
        XCTAssertEqual(L10n.plural("recording.takes.count", count: 7, language: .russian), "7 дублей")
    }

    func testAutosaveIntervalUsesALocalizedUnit() {
        XCTAssertEqual(
            String(format: L10n.tr("settings.autosaveIntervalValue", language: .spanish), 10),
            "10 s"
        )
        XCTAssertEqual(
            String(format: L10n.tr("settings.autosaveIntervalValue", language: .russian), 10),
            "10 с"
        )

        let appState = makeSnapshotAppState()
        appState.windowState.requestedSettingsTab = .general
        let result = SnapshotRenderer.render(
            SettingsRootView(),
            name: "settings-general-autosave-unit",
            suite: "WP6VisualTests",
            size: CGSize(width: 940, height: 650),
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        XCTAssertTrue(
            result.textFragments.contains { $0 == "10 s" },
            "the autosave interval row must render '10 s' with a space; text was \(result.textFragments)"
        )
    }

    // MARK: - Helpers

    private func makeRhythmTextView(_ text: String) -> MarkupEditorTextView {
        let textView = MarkupEditorTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.font = .systemFont(ofSize: 14)
        textView.string = text
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        return textView
    }

    private func composite(_ fill: NSColor, over background: NSColor) -> NSColor {
        background.blended(withFraction: fill.alphaComponent, of: fill) ?? background
    }

    private func assertContrast(
        _ foreground: Color,
        on background: Color,
        _ label: String,
        minimum: CGFloat = 4.5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ratio = MarkupEditorPalette.contrastRatio(NSColor(foreground), NSColor(background))
        XCTAssertGreaterThanOrEqual(ratio, minimum, "\(label): \(ratio):1", file: file, line: line)
    }

    private func makeSnapshotAppState(project: FrameProject? = nil) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.editorPreferences.showAIReviewPanel = false

        let store = ProjectStore(project: project ?? SampleData.defaultProject)
        if let project {
            store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        }
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: .live,
            recording: RecordingController(
                preferences: OBSPreferencesStore(defaults: defaults, secretStore: WP6SnapshotSecretStore()),
                defaults: defaults
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
        appState.editorState.selectedSceneID = project?.scenes.sortedByOrder.first?.id
        return appState
    }
}

/// In-memory OBS credentials for snapshots: never touches the Keychain.
private struct WP6SnapshotSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}
