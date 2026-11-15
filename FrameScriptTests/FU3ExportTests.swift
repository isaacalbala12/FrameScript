import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// FU3 fix-up regressions for WP4: a table after the last paragraph must survive
/// the fallback export path, and fractional durations must round instead of
/// truncating.
@MainActor
final class FU3ExportTests: FrameScriptTestCase {
    // MARK: - WP4 #12: a trailing table is not lost after a B-roll is added

    func testEscaletaExportKeepsATableAfterTheLastParagraphWhenABRollIsAdded() throws {
        let markdown = """
        # Escaleta con tabla

        ## Promesa del vídeo

        Una promesa sintética para la prueba.

        # Guion

        ## 0:00 — Escena uno

        Texto de la primera escena.

        | Ganar | Perder |
        |---|---|
        | A | B |
        """

        let mapping = importMarkdown(markdown)
        XCTAssertEqual(mapping.project.comparisonTables.count, 1)
        let scene = try XCTUnwrap(mapping.project.scenes.sortedByOrder.first)
        XCTAssertEqual(
            EscaletaParser.parse(EscaletaProjectExporter.markdown(from: mapping.project))
                .document.comparisonTables.count,
            1,
            "The table must be present right after the import"
        )

        // A B-roll invalidates the round-trip metadata (the block count no longer
        // matches), so the export takes the fallback path. The table sits in the
        // trailing slot, which that path used to mark as placed but never emit.
        let text = scene.scriptText
        scene.bRollItems.append(BRollItem(
            textAnchor: TextAnchor(
                startUTF16: 0,
                lengthUTF16: (text as NSString).length,
                selectedText: text
            ),
            templateType: "Escaleta",
            sourceType: .custom,
            descriptionText: "Plano de recurso"
        ))

        let exported = EscaletaProjectExporter.markdown(from: mapping.project)
        XCTAssertTrue(exported.contains("| Ganar | Perder |"), exported)
        XCTAssertEqual(
            exported.components(separatedBy: "| A | B |").count - 1, 1,
            "The table must be exported exactly once:\n\(exported)"
        )
        XCTAssertTrue(exported.contains("Plano de recurso"), exported)

        let paragraphRange = try XCTUnwrap(exported.range(of: "Texto de la primera escena."))
        let tableRange = try XCTUnwrap(exported.range(of: "| Ganar | Perder |"))
        XCTAssertLessThan(
            paragraphRange.lowerBound, tableRange.lowerBound,
            "A table that followed the last paragraph must stay after it"
        )

        let reparsed = EscaletaParser.parse(exported)
        XCTAssertEqual(reparsed.document.comparisonTables.count, 1)
        XCTAssertEqual(reparsed.document.comparisonTables.first?.rows, [["A", "B"]])
    }

    /// Guard against over-fixing: a table between paragraphs still belongs to
    /// its slot and must not be appended twice.
    func testEscaletaExportKeepsATableBetweenParagraphsWhenABRollIsAdded() throws {
        let markdown = """
        # Escaleta con tabla

        # Guion

        ## 0:00 — Escena uno

        Texto de la primera escena.

        | Ganar | Perder |
        |---|---|
        | A | B |

        Texto de la segunda escena.
        """

        let mapping = importMarkdown(markdown)
        let scene = try XCTUnwrap(mapping.project.scenes.sortedByOrder.first)
        let text = scene.scriptText
        scene.bRollItems.append(BRollItem(
            textAnchor: TextAnchor(
                startUTF16: 0,
                lengthUTF16: (text as NSString).length,
                selectedText: text
            ),
            templateType: "Escaleta",
            sourceType: .custom,
            descriptionText: "Plano de recurso"
        ))

        let exported = EscaletaProjectExporter.markdown(from: mapping.project)
        XCTAssertEqual(
            exported.components(separatedBy: "| A | B |").count - 1, 1,
            "The table must be exported exactly once:\n\(exported)"
        )
    }

    // MARK: - WP4 #13: durations round, never truncate

    func testFractionalSceneDurationsRoundTheNextSceneTimestamp() {
        let first = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena uno",
            scriptText: "Texto uno.",
            estimatedDuration: 12.6
        )
        let second = Scene(
            order: 1,
            sectionType: .explanation,
            title: "Escena dos",
            scriptText: "Texto dos.",
            estimatedDuration: 4
        )
        let project = FrameProject(title: "Proyecto", scenes: [first, second])

        let exported = EscaletaProjectExporter.markdown(from: project)
        XCTAssertTrue(
            exported.contains("## 0:13 — Escena dos"),
            "12.6 s must round to 0:13, not truncate to 0:12:\n\(exported)"
        )
        XCTAssertFalse(exported.contains("## 0:12 — Escena dos"), exported)
    }

    func testClampedSecondsRoundsAndStillClamps() {
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(12.6), 13)
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(12.4), 12)
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(0.4), 0)
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(-5), 0)
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(1e300), 86_400)
        XCTAssertEqual(EscaletaProjectExporter.clampedSeconds(.infinity), 0)

        XCTAssertEqual(EscaletaProjectMapper.clampedSeconds(12.6), 13)
        XCTAssertEqual(EscaletaProjectMapper.clampedSeconds(12.4), 12)
        XCTAssertEqual(EscaletaProjectMapper.clampedSeconds(1e300), 86_400)
        XCTAssertEqual(EscaletaProjectMapper.clampedSeconds(.nan), 0)
    }

    // MARK: - Helpers

    private func importMarkdown(
        _ markdown: String,
        options: EscaletaMappingOptions = EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
    ) -> EscaletaProjectMapping {
        EscaletaProjectMapper.map(EscaletaParser.parse(markdown), options: options)
    }
}
