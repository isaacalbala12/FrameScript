import Foundation
import Testing
@testable import FrameScriptCore

/// Wave 3 fix pass A/B/F: pure-logic regressions for clip staleness, the
/// per-clip speaking rate, and the AV script CSV options.
@Suite("W3FixABF core regressions")
struct W3FixABFCoreTests {
    // MARK: - F-1

    @Test("W3FixABF: an unresolved anchor is stale in every surface")
    func unresolvedAnchorIsStaleEverywhere() throws {
        var scene = makeScene(order: 0, title: "Escena", text: "alfa beta gamma")
        let anchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: scene.scriptText,
                range: (scene.scriptText as NSString).range(of: "beta")
            )
        )
        var clip = ClipFactory.make(
            title: "Fragmento",
            sceneIDs: [scene.id],
            anchorSceneID: scene.id,
            anchor: anchor,
            scenes: [scene]
        )

        scene.scriptText = "alfa gamma"
        let report = ClipStaleness.report(clip: clip, scenes: [scene])
        #expect(report.hasUnresolvedAnchor)
        #expect(report.isStale)
        #expect(ClipStaleness.isStale(clip: clip, scenes: [scene]) == report.isStale)

        // "Mark as reviewed" can only rebaseline the hash; it cannot invent
        // the deleted passage, so the clip stays stale and the summary agrees.
        clip = ClipStaleness.reviewed(clip, scenes: [scene])
        let reviewedReport = ClipStaleness.report(clip: clip, scenes: [scene])
        #expect(reviewedReport.hasUnresolvedAnchor)
        #expect(reviewedReport.isStale)
        #expect(ClipStaleness.isStale(clip: clip, scenes: [scene]) == reviewedReport.isStale)

        let summary = ClipSummaryBuilder.summary(
            clips: [clip],
            scenes: [scene],
            wordsPerMinute: { _ in 150 }
        )
        #expect(summary.stale == 1)
    }

    // MARK: - F-3

    @Test("W3FixABF: the summary uses each clip's own speaking rate")
    func summaryUsesPerClipSpeakingRate() {
        let scene = makeScene(order: 0, title: "Escena", text: "alfa beta gamma")
        var spanishClip = ClipFactory.make(title: "ES", sceneIDs: [scene.id], scenes: [scene])
        spanishClip.languageCode = "es"
        spanishClip.hook = ""
        spanishClip.adaptedText = Array(repeating: "palabra", count: 40).joined(separator: " ")
        var englishClip = ClipFactory.make(title: "EN", sceneIDs: [scene.id], scenes: [scene])
        englishClip.languageCode = "en"
        englishClip.hook = ""
        englishClip.adaptedText = Array(repeating: "word", count: 40).joined(separator: " ")

        let rates: [String: Double] = ["es": 120, "en": 240]
        let summary = ClipSummaryBuilder.summary(
            clips: [spanishClip, englishClip],
            scenes: [scene],
            wordsPerMinute: { rates[$0.languageCode] ?? 150 }
        )

        let expected = [spanishClip, englishClip].reduce(0.0) { partial, clip in
            partial + ClipEstimator.estimate(
                hook: clip.hook,
                adaptedText: clip.adaptedText,
                targetSeconds: clip.targetSeconds,
                wordsPerMinute: rates[clip.languageCode] ?? 150
            ).seconds
        }
        #expect(summary.estimatedTotalSeconds == expected)
        #expect(summary.estimatedTotalSeconds != ClipEstimator.estimate(
            hook: spanishClip.hook,
            adaptedText: spanishClip.adaptedText,
            targetSeconds: spanishClip.targetSeconds,
            wordsPerMinute: 150
        ).seconds * 2)

        let items = ClipSummaryBuilder.productionItems(
            clips: [spanishClip, englishClip],
            scenes: [scene],
            wordsPerMinute: { rates[$0.languageCode] ?? 150 }
        )
        #expect(items.map(\.estimatedSeconds) == [
            ClipEstimator.estimate(
                hook: spanishClip.hook,
                adaptedText: spanishClip.adaptedText,
                targetSeconds: spanishClip.targetSeconds,
                wordsPerMinute: 120
            ).seconds,
            ClipEstimator.estimate(
                hook: englishClip.hook,
                adaptedText: englishClip.adaptedText,
                targetSeconds: englishClip.targetSeconds,
                wordsPerMinute: 240
            ).seconds,
        ])
    }

    // MARK: - A-6

    @Test("W3FixABF: AV CSV escapes formulas and can carry a BOM")
    func avCSVEscapesFormulasAndOptionallyAddsBOM() throws {
        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: UUID(),
                title: "Escena",
                scriptText: "=SUM(1)\n\nTexto normal",
                annotations: []
            )
        )
        let document = AVScriptDocument(title: "Prueba", scenes: [scene])

        let escaped = AVScriptExporter.csv(document: document, escapeFormulas: true)
        #expect(escaped.contains("'=SUM(1)"))
        let plain = AVScriptExporter.csv(document: document, escapeFormulas: false)
        #expect(!plain.contains("'=SUM(1)"))

        let bom = AVScriptExporter.csv(document: document, includesBOM: true)
        #expect(bom.hasPrefix("\u{FEFF}"))
        let withoutBOM = AVScriptExporter.csv(document: document, includesBOM: false)
        #expect(!withoutBOM.hasPrefix("\u{FEFF}"))
    }

    @Test("W3FixABF: dialogue dashes are prose, formula-like cells stay escaped")
    func avCSVKeepsDialogueDashesButEscapesFormulaTokens() {
        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: UUID(),
                title: "Escena",
                scriptText: "- uno dos\n\n-1+2\n\nTexto normal",
                annotations: []
            )
        )
        let document = AVScriptDocument(title: "Prueba", scenes: [scene])

        let csv = AVScriptExporter.csv(document: document, escapeFormulas: true)
        #expect(csv.contains(",- uno dos,"))
        #expect(!csv.contains("'- uno dos"))
        #expect(csv.contains("'-1+2"))
        #expect(csv.contains("Texto normal"))
    }

    // MARK: - Helpers

    private func makeScene(order: Int, title: String, text: String) -> FrameScriptDocument.Scene {
        FrameScriptDocument.Scene(
            order: order,
            sectionType: .custom,
            title: title,
            scriptText: text
        )
    }
}
