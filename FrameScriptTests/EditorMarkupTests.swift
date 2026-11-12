import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class EditorMarkupTests: XCTestCase {
    // MARK: - Duration (F4 / F11 / F3)

    func testDurationCountsSpokenWordsAndPausesButNotCues() {
        let text = "Hola mundo [IMAGEN: coche] / otra // frase [2s] fin."
        let configuration = DurationConfiguration(
            wordsPerMinute: 60,
            pauseDefaults: PauseDefaults(short: 0.5, long: 1.0)
        )
        // Five spoken words at 60 wpm = 5 s. Pauses: / = 0.5, // = 1, [2s] = 2.
        XCTAssertEqual(ScriptMarkup.spokenWordCount(text), 5)
        XCTAssertEqual(
            DurationEstimator.estimate(text: text, configuration: configuration),
            8.5,
            accuracy: 0.001
        )
    }

    func testDurationIgnoresSlashesInsideTokens() {
        let text = "Velocidad 120 km/h y 1/4 de vuelta."
        XCTAssertEqual(
            DurationEstimator.estimate(text: text, configuration: DurationConfiguration(wordsPerMinute: 60)),
            7,
            accuracy: 0.001
        )
    }

    func testConfiguredPauseDefaultsChangeTheEstimate() {
        let text = "Uno / dos // tres."
        XCTAssertEqual(
            DurationEstimator.estimate(
                text: text,
                configuration: DurationConfiguration(
                    wordsPerMinute: 60,
                    pauseDefaults: PauseDefaults(short: 2, long: 3)
                )
            ),
            8,
            accuracy: 0.001
        )
    }

    func testPerLanguageDefaultWordsPerMinute() {
        let settings = AppSettings.defaults
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "es", learnedWordsPerMinute: [:], settings: settings), 150)
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "en", learnedWordsPerMinute: [:], settings: settings), 160)
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "ru", learnedWordsPerMinute: [:], settings: settings), 140)
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "es-ES", learnedWordsPerMinute: [:], settings: settings), 150)

        let englishText = Array(repeating: "word", count: 160).joined(separator: " ")
        XCTAssertEqual(
            DurationEstimator.estimate(text: englishText, language: "en", settings: settings),
            60,
            accuracy: 0.001
        )
    }

    func testUserLanguageRateWinsOverBuiltInDefault() {
        var settings = AppSettings.defaults
        settings.editorPreferences.setWordsPerMinute(180, for: "es")
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "es", learnedWordsPerMinute: [:], settings: settings), 180)

        let text = Array(repeating: "palabra", count: 180).joined(separator: " ")
        XCTAssertEqual(
            DurationEstimator.estimate(text: text, language: "es", settings: settings),
            60,
            accuracy: 0.001
        )
    }

    func testLearnedWordsPerMinuteOverridesSettings() {
        var settings = AppSettings.defaults
        settings.editorPreferences.setWordsPerMinute(180, for: "es")

        let text = Array(repeating: "palabra", count: 120).joined(separator: " ")
        XCTAssertEqual(
            DurationEstimator.estimate(
                text: text,
                language: "es",
                project: FrameProject(title: "Demo", learnedWordsPerMinuteByLanguage: ["es": 120]),
                settings: settings
            ),
            60,
            accuracy: 0.001
        )
    }

    func testInvalidLearnedRateFallsBackToSettings() {
        var settings = AppSettings.defaults
        settings.editorPreferences.setWordsPerMinute(180, for: "es")
        XCTAssertEqual(
            DurationEstimator.effectiveWordsPerMinute(
                language: "es",
                learnedWordsPerMinute: ["es": 2],
                settings: settings
            ),
            180
        )
        XCTAssertEqual(
            DurationEstimator.effectiveWordsPerMinute(
                language: "es",
                learnedWordsPerMinute: ["es": .nan],
                settings: settings
            ),
            180
        )
    }

    func testUnknownLanguageFallsBackToLegacyRate() {
        var settings = AppSettings.defaults
        settings.editorPreferences.wordsPerMinute = 175
        XCTAssertEqual(DurationEstimator.effectiveWordsPerMinute(language: "de", learnedWordsPerMinute: [:], settings: settings), 175)
    }

    func testPauseConfigurationIsClampedByPauseDefaults() {
        let preferences = EditorPreferences(
            wordsPerMinute: 150,
            fontSize: 22,
            spellcheck: true,
            smartQuotes: true,
            showWordCount: true,
            showSceneDuration: true,
            showAIReviewPanel: true,
            shortPauseSeconds: -3,
            longPauseSeconds: 500
        )
        XCTAssertEqual(preferences.markupPauseDefaults.short, 0)
        XCTAssertEqual(preferences.markupPauseDefaults.long, 60)
    }

    func testLegacySettingsDecodeUsesNewDefaults() throws {
        let legacy = """
        {"wordsPerMinute":150,"fontSize":22,"spellcheck":true,"smartQuotes":true,"showWordCount":true,"showSceneDuration":true,"showAIReviewPanel":true,"defaultNotesVisibility":"Collapsed"}
        """
        let decoded = try JSONDecoder().decode(EditorPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.shortPauseSeconds, 0.5)
        XCTAssertEqual(decoded.longPauseSeconds, 1.0)
        XCTAssertTrue(decoded.rhythmReviewEnabled)
        XCTAssertTrue(decoded.wordsPerMinuteByLanguage.isEmpty)
    }

    // MARK: - Highlight planning (F4)

    func testHighlightRunsForSampleScript() {
        let text = "Hola / mundo // *énfasis* **fuerte** [2s] [IMAGEN: coche] km/h"
        let runs = MarkupHighlightPlanner.highlightRuns(text: text, pauseDefaults: .standard)
        let ns = text as NSString

        XCTAssertEqual(style(of: ns.range(of: "*énfasis*").location + 1, in: runs), .emphasis)
        XCTAssertEqual(style(of: ns.range(of: "**fuerte**").location + 2, in: runs), .strongEmphasis)
        XCTAssertEqual(style(of: ns.range(of: "[2s]").location + 1, in: runs), .explicitPause)
        XCTAssertEqual(style(of: ns.range(of: "[IMAGEN: coche]").location + 1, in: runs), .cue)
        XCTAssertEqual(style(of: ns.range(of: " / ").location + 1, in: runs), .shortPause)
        XCTAssertEqual(style(of: ns.range(of: " // ").location + 1, in: runs), .longPause)

        // Delimiters are kept and dimmed: four asterisks and the escaped markers.
        let delimiterRuns = runs.filter { $0.style == .delimiter }
        XCTAssertEqual(delimiterRuns.count, 4)
        XCTAssertEqual(delimiterRuns.reduce(0) { $0 + $1.range.length }, 6)

        // `km/h` is literal text, never a pause.
        let slashRange = ns.range(of: "km/h")
        XCTAssertFalse(runs.contains { NSIntersectionRange($0.range, slashRange).length > 0 })

        assertSortedAndNonOverlapping(runs)
    }

    func testHighlightRunsStayInsideTheRequestedRange() {
        let text = "uno\n\n*énfasis\ncontinúa* fin\n\n**otro** párrafo"
        let ns = text as NSString
        let caret = ns.range(of: "continúa").location
        let expanded = MarkupHighlightPlanner.extendedParagraphRange(
            around: NSRange(location: caret, length: 0),
            in: ns
        )
        let runs = MarkupHighlightPlanner.highlightRuns(
            text: text,
            pauseDefaults: .standard,
            in: expanded
        )
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.range.location, expanded.location)
            XCTAssertLessThanOrEqual(NSMaxRange(run.range), NSMaxRange(expanded))
        }
        // The emphasis opens in the previous paragraph, so extending the range
        // must keep its content styled on both lines.
        XCTAssertEqual(style(of: ns.range(of: "énfasis").location + 1, in: runs), .emphasis)
        XCTAssertEqual(style(of: ns.range(of: "continúa").location + 1, in: runs), .emphasis)
    }

    func testHighlightRunsSkipCueEvenWhenItLooksLikeEmphasis() {
        let text = "[IMAGEN: *coche*] fin"
        let runs = MarkupHighlightPlanner.highlightRuns(text: text, pauseDefaults: .standard)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.style, .cue)
    }

    func testRhythmUnderlinesClampAndSkipEmpty() {
        let warnings = [
            RhythmWarning(
                sceneID: "s1",
                kind: .longSentence,
                range: UTF16Span(location: 2, length: 400),
                messageKey: RhythmMessageKey.longSentence
            ),
            RhythmWarning(
                sceneID: "s1",
                kind: .noVisualChange,
                range: UTF16Span(location: 50, length: 0),
                messageKey: RhythmMessageKey.noVisualChange
            )
        ]
        let underlines = RhythmUnderlinePlanner.underlines(
            warnings: warnings,
            textLength: 20,
            message: { $0.kind.rawValue }
        )
        XCTAssertEqual(underlines.count, 1)
        XCTAssertEqual(underlines.first?.range, NSRange(location: 2, length: 18))
        XCTAssertEqual(underlines.first?.message, "longSentence")
    }

    // MARK: - Rhythm review mapping (F26)

    func testVisualChangeOffsetsComeFromAnchoredBRollAndEditingItems() throws {
        let text = "El coche gira en la curva y frena con precisión antes del piano."
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: text)
        let bRollRange = (text as NSString).range(of: "curva")
        let editingRange = (text as NSString).range(of: "antes")
        let bRollAnchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: bRollRange))
        let editingAnchor = try XCTUnwrap(TextAnchorRepair.anchor(in: text, range: editingRange))
        scene.bRollItems = [BRollItem(textAnchor: bRollAnchor, templateType: "", sourceType: .stockFootage, descriptionText: "curva")]
        scene.editingItems = [EditingItem(textAnchor: editingAnchor, templateType: "", cutStyle: "corte", transition: "", subtitleStyle: "")]

        XCTAssertEqual(
            RhythmReview.visualChangeOffsets(for: scene),
            [bRollRange.location, editingRange.location].sorted()
        )
    }

    func testRhythmInputUsesHookRoleAndConfiguredRate() throws {
        let text = "Uno dos tres."
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: text)
        let input = RhythmReview.input(for: scene, wordsPerMinute: 140)
        XCTAssertEqual(input.id, scene.id.uuidString)
        XCTAssertEqual(input.role, .hook)
        XCTAssertEqual(input.wordsPerMinute, 140)
        XCTAssertTrue(input.visualChangeOffsets.isEmpty)
    }

    func testNoVisualChangeWarningStartsAtAnchoredItem() {
        let text = "Uno dos tres cuatro cinco seis siete ocho nueve diez once doce."
        let scene = Scene(order: 0, sectionType: .custom, title: "Escena", scriptText: text)
        let secondHalf = (text as NSString).range(of: "siete")
        scene.bRollItems = [
            BRollItem(
                textAnchor: TextAnchorRepair.anchor(in: text, range: secondHalf),
                templateType: "",
                sourceType: .stockFootage,
                descriptionText: "plano"
            )
        ]
        let pauses = RhythmReview.pauses(in: text, defaults: .standard)
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmReview.input(for: scene, wordsPerMinute: 60),
            thresholds: .init(maxSecondsWithoutVisualChange: 2),
            pauseDuration: { RhythmReview.pauseDuration(in: $0, pauses: pauses) }
        )
        let warnings = analysis.warnings.filter { $0.kind == .noVisualChange }
        XCTAssertEqual(warnings.count, 2)
        XCTAssertEqual(warnings.first?.range.end, secondHalf.location)
    }

    func testPauseProviderMatchesScriptMarkup() {
        let text = "Uno / dos // tres [2s] cuatro [pausa 1,5s] cinco"
        let pauses = RhythmReview.pauses(in: text, defaults: PauseDefaults(short: 0.5, long: 1))
        let whole = UTF16Span(location: 0, length: (text as NSString).length)
        XCTAssertEqual(RhythmReview.pauseDuration(in: whole, pauses: pauses), 5, accuracy: 0.001)
        // Five spoken words at 1000 wpm add 0.3 s.
        XCTAssertEqual(
            ScriptMarkup.estimateDuration(text, wordsPerMinute: 1000, defaults: PauseDefaults(short: 0.5, long: 1)),
            5.3,
            accuracy: 0.001
        )
    }

    func testOutlierWarningsMatchCoreProjectRule() {
        let short = Array(repeating: "palabra", count: 10).joined(separator: " ") + "."
        let long = Array(repeating: "palabra", count: 40).joined(separator: " ") + "."
        let analyses = [
            RhythmAnalyzer.analyze(scene: RhythmSceneInput(id: "s1", text: short, wordsPerMinute: 60)),
            RhythmAnalyzer.analyze(scene: RhythmSceneInput(id: "s2", text: short, wordsPerMinute: 60)),
            RhythmAnalyzer.analyze(scene: RhythmSceneInput(id: "s3", text: long, wordsPerMinute: 60))
        ]
        let appWarnings = RhythmReview.sceneLengthOutlierWarnings(from: analyses, factor: 1.8)
        let coreProject = RhythmAnalyzer.analyzeProject(scenes: [
            RhythmSceneInput(id: "s1", text: short, wordsPerMinute: 60),
            RhythmSceneInput(id: "s2", text: short, wordsPerMinute: 60),
            RhythmSceneInput(id: "s3", text: long, wordsPerMinute: 60)
        ])
        XCTAssertEqual(appWarnings.map(\.sceneID), coreProject.projectWarnings.map(\.sceneID))
        XCTAssertEqual(appWarnings.first?.kind, .sceneLengthOutlier)
        XCTAssertEqual(RhythmWarningFormatter.argument("factor", in: appWarnings[0]), 1.8, accuracy: 0.001)
    }

    func testThresholdPrecedenceIsProjectThenVideoTypeThenDefaults() {
        var settings = AppSettings.defaults
        settings.rhythmThresholdsByVideoType["Review"] = AppRhythmThresholds(
            longSentenceWordLimit: 18,
            uncoveredSecondsLimit: 4,
            sceneLengthRatioLimit: 2.1,
            hookSecondsLimit: 12
        )
        let project = FrameProject(title: "Demo", videoType: "Review")
        var calibration = RhythmReview.effectiveThresholds(project: project, settings: settings)
        XCTAssertEqual(calibration.maxSentenceWords, 18)
        XCTAssertEqual(calibration.maxSecondsWithoutVisualChange, 4)
        XCTAssertEqual(calibration.hookMaxSeconds, 12)
        XCTAssertEqual(calibration.sceneLengthOutlierFactor, 2.1)
        XCTAssertEqual(calibration.maxSentenceSeconds, 9)

        project.rhythmThresholdsOverride = AppRhythmThresholds(hookSecondsLimit: 8)
        calibration = RhythmReview.effectiveThresholds(project: project, settings: settings)
        XCTAssertEqual(calibration.hookMaxSeconds, 8)
        XCTAssertEqual(calibration.maxSentenceWords, 18)
    }

    // MARK: - Clean export (F4)

    func testMarkdownKeepsMarkersByDefaultAndCleanExportStripsThem() {
        let text = "Hola [pausa], mundo. / *énfasis* [2s] [IMAGEN: coche] fin."
        let scene = Scene(order: 0, sectionType: .custom, title: "Escena", scriptText: text)
        let project = FrameProject(title: "Demo", scenes: [scene])
        let service = ExportService()
        var preferences = AppSettings.defaults.exportPreferences
        preferences.includeBRoll = false
        preferences.includeEditingNotes = false

        preferences.cleanMarkup = false
        let marked = service.render(project: project, format: .markdown, preferences: preferences, language: .spanish)
        XCTAssertTrue(marked.contains("*énfasis*"))
        XCTAssertTrue(marked.contains("[2s]"))
        XCTAssertTrue(marked.contains("[IMAGEN: coche]"))

        preferences.cleanMarkup = true
        let clean = service.render(project: project, format: .markdown, preferences: preferences, language: .spanish)
        XCTAssertFalse(clean.contains("*énfasis*"))
        XCTAssertFalse(clean.contains("[2s]"))
        XCTAssertFalse(clean.contains("[IMAGEN: coche]"))
        XCTAssertTrue(clean.contains("énfasis"))
        XCTAssertTrue(clean.contains("Hola, mundo."))
    }

    // MARK: - Localization

    func testRhythmStringsExistInEveryLanguage() {
        let keys = [
            "rhythm.sectionTitle", "rhythm.empty", "rhythm.disabled", "rhythm.longSentence",
            "rhythm.noVisualChange", "rhythm.longHook", "rhythm.sceneLengthOutlier",
            "rhythm.badgeAccessibility", "settings.markupRhythm", "settings.rhythmReview",
            "settings.rhythmThresholds", "settings.cleanMarkup"
        ]
        for language in [AppLanguage.english, .russian, .spanish] {
            for key in keys {
                XCTAssertNotEqual(L10n.tr(key, language: language), key, "Missing \(key) in \(language.rawValue)")
            }
        }
    }

    func testWarningTextUsesLocalizedNumbers() {
        let warning = RhythmWarning(
            sceneID: "s1",
            kind: .longSentence,
            range: UTF16Span(location: 0, length: 3),
            messageKey: RhythmMessageKey.longSentence,
            arguments: [
                RhythmArgument("words", 32),
                RhythmArgument("seconds", 10.4),
                RhythmArgument("maxWords", 25),
                RhythmArgument("maxSeconds", 9)
            ]
        )
        let spanish = RhythmWarningFormatter.text(for: warning, language: .spanish)
        XCTAssertTrue(spanish.contains("32"))
        XCTAssertTrue(spanish.contains("10,4"), spanish)
        XCTAssertTrue(spanish.contains("25"))
    }

    // MARK: - Editor selection routing

    func testActiveEditorSessionRoutesWarningSelectionToItsScene() {
        let session = ActiveScriptEditorSession.shared
        let sceneID = UUID()
        let editor = FakeActiveScriptEditor(sceneID: sceneID)
        session.register(editor)
        defer { session.unregister(editor) }

        XCTAssertTrue(session.selectRange(NSRange(location: 4, length: 6), inScene: sceneID))
        XCTAssertEqual(editor.selectedRange, NSRange(location: 4, length: 6))
        XCTAssertFalse(session.selectRange(NSRange(location: 0, length: 1), inScene: UUID()))
    }

    // MARK: - Performance

    func testIncrementalHighlightingStaysFastOnTwentyThousandWords() {
        let paragraph = "En la curva el coche *frena* fuerte / y luego acelera // con [2s] cuidado. [IMAGEN: telemetría]\n\n"
        let text = String(repeating: paragraph, count: 2_000)
        let ns = text as NSString
        XCTAssertGreaterThan(ScriptMarkup.spokenWordCount(text), 20_000)

        let middle = ns.length / 2
        let editRange = NSRange(location: middle, length: 0)
        let expanded = MarkupHighlightPlanner.extendedParagraphRange(around: editRange, in: ns)

        // Full-document plan, measured once (open / external rewrite path).
        let fullStarted = DispatchTime.now()
        let fullRuns = MarkupHighlightPlanner.highlightRuns(text: text, pauseDefaults: .standard)
        let fullMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - fullStarted.uptimeNanoseconds) / 1_000_000
        XCTAssertGreaterThan(fullRuns.count, 1_000)

        // Incremental plan of the edited paragraphs, averaged over 20 edits.
        var incrementalTotal = 0.0
        let iterations = 20
        for _ in 0..<iterations {
            let started = DispatchTime.now()
            let runs = MarkupHighlightPlanner.highlightRuns(
                text: text,
                pauseDefaults: .standard,
                in: expanded
            )
            XCTAssertFalse(runs.isEmpty)
            incrementalTotal += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        }
        let incrementalAverage = incrementalTotal / Double(iterations)
        print(String(format: "Markup highlight: full 20k-word plan %.2f ms, edited paragraphs %.3f ms (%d UTF-16 units)", fullMilliseconds, incrementalAverage, expanded.length))
        XCTAssertLessThan(incrementalAverage, 8, "Incremental highlight must stay under 8 ms")

        // Same edit through the real TextKit styler (font attributes + colors).
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        textView.isRichText = false
        textView.string = text
        let styler = MarkupEditorStyler()
        styler.attach(to: textView)
        styler.configure(MarkupEditorStyler.Configuration(
            isEnabled: true,
            pauseDefaults: .standard,
            palette: MarkupEditorPalette(
                fontSize: 22,
                textColor: .labelColor,
                secondaryColor: .secondaryLabelColor,
                accentColor: .systemBlue,
                rhythmColor: .systemOrange
            )
        ))
        var stylerTotal = 0.0
        for _ in 0..<iterations {
            styler.apply(around: editRange, in: textView)
            stylerTotal += styler.lastApplyDuration
        }
        let stylerAverage = stylerTotal / Double(iterations)
        print(String(format: "Markup styler: edited paragraphs %.2f ms (%d UTF-16 units)", stylerAverage, styler.lastAppliedCharacterCount))
        XCTAssertLessThan(stylerAverage, 30, "TextKit attribute application must stay under 30 ms")
    }

    func testHugeSingleParagraphUsesACappedIncrementalWindow() {
        let text = String(repeating: "palabra *énfasis* / [2s] texto normal ", count: 1_500)
        let ns = text as NSString
        let caret = ns.length / 2
        let editRange = NSRange(location: caret, length: 0)
        let window = MarkupHighlightPlanner.extendedParagraphRange(around: editRange, in: ns)
        XCTAssertLessThanOrEqual(window.length, MarkupHighlightPlanner.maximumIncrementalLength)
        XCTAssertTrue(NSLocationInRange(caret, window))
        XCTAssertTrue(MarkupHighlightPlanner.needsDeferredFullRefresh(around: editRange, in: ns))

        var total = 0.0
        for _ in 0..<20 {
            let started = DispatchTime.now()
            _ = MarkupHighlightPlanner.highlightRuns(text: text, pauseDefaults: .standard, in: window)
            total += Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        }
        let average = total / 20
        print(String(format: "Markup highlight: capped window %.3f ms (%d UTF-16 units)", average, window.length))
        XCTAssertLessThan(average, 8)
    }

    // MARK: - Helpers

    private func style(of location: Int, in runs: [MarkupHighlightRun]) -> MarkupHighlightStyle? {
        runs.first { NSLocationInRange(location, $0.range) }?.style
    }

    private func assertSortedAndNonOverlapping(
        _ runs: [MarkupHighlightRun],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var previousEnd = 0
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.range.location, previousEnd, file: file, line: line)
            XCTAssertGreaterThan(run.range.length, 0, file: file, line: line)
            previousEnd = NSMaxRange(run.range)
        }
    }
}

@MainActor
private final class FakeActiveScriptEditor: ActiveScriptEditor {
    let sceneID: UUID
    let editorIdentity = UUID()
    private(set) var selectedRange: NSRange?

    init(sceneID: UUID) {
        self.sceneID = sceneID
    }

    var owningWindow: NSWindow? { nil }
    var isActualFirstResponder: Bool { false }

    @discardableResult
    func commitMarkedTextAndFlush() -> Bool { false }
    func cancelAutocomplete(clearStatus: Bool) {}
    func selectRange(_ range: NSRange) { selectedRange = range }
}
