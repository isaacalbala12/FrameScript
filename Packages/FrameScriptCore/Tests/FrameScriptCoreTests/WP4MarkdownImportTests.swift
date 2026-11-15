import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - WP4: escaleta tables and warning arguments

@Suite("WP4 escaleta tables")
struct WP4EscaletaTableTests {
    @Test func escapedPipeInACellRoundTripsThroughExportAndImport() throws {
        let markdown = [
            "# Escaleta con tabla",
            "",
            "# Guion",
            "",
            "## 0:00 — Escena",
            "",
            "Texto de la escena.",
            "",
            "| Ganar | Perder |",
            "|---|---|",
            "| a \\| b | c \\\\ d |",
            ""
        ].joined(separator: "\n")

        let result = EscaletaParser.parse(markdown)
        let table = try #require(result.document.comparisonTables.first)
        #expect(table.rows == [["a | b", "c \\ d"]])

        let exported = EscaletaExporter.markdown(from: result.document)
        #expect(exported.contains("| a \\| b | c \\\\ d |"))

        let reparsed = EscaletaParser.parse(exported)
        #expect(reparsed.document == result.document)
        #expect(reparsed.document.comparisonTables.first?.rows == [["a | b", "c \\ d"]])
    }

    @Test func customTableHeadingIsRecognisedByItsContent() throws {
        let markdown = [
            "# Documento",
            "",
            "# Guion",
            "",
            "## 0:00 — Escena",
            "",
            "Texto de la escena.",
            "",
            "## Comparativa de precios",
            "",
            "| A | B |",
            "|---|---|",
            "| 1 | 2 |",
            ""
        ].joined(separator: "\n")

        let result = EscaletaParser.parse(markdown)
        #expect(result.document.comparisonTables.count == 1)
        #expect(result.document.comparisonTables.first?.header == ["A", "B"])
        #expect(result.document.tableSectionHeading == "Comparativa de precios")
        #expect(result.document.unparsedSections.isEmpty)

        let reparsed = EscaletaParser.parse(EscaletaExporter.markdown(from: result.document))
        #expect(reparsed.document.comparisonTables.count == 1)
        #expect(reparsed.document.comparisonTables.first?.heading == "Comparativa de precios")
    }

    @Test func tableWithAnEmptyHeaderIsWrittenWithAReadableHeader() throws {
        let document = EscaletaDocument(
            kind: .escaleta,
            title: "Documento",
            scriptHeading: "Guion",
            comparisonTables: [
                ComparisonTable(heading: "Comparativa", header: [], rows: [["uno", "dos"]])
            ]
        )

        let markdown = EscaletaExporter.markdown(from: document)
        #expect(!markdown.contains("||"))

        let reparsed = EscaletaParser.parse(markdown)
        let table = try #require(reparsed.document.comparisonTables.first)
        #expect(table.header == ["Columna 1", "Columna 2"])
        #expect(table.rows == [["uno", "dos"]])
    }

    @Test func timestampTextIsSharedAndClamped() {
        #expect(EscaletaExporter.timestampText(fromSeconds: 0) == "0:00")
        #expect(EscaletaExporter.timestampText(fromSeconds: 61) == "1:01")
        #expect(EscaletaExporter.timestampText(fromSeconds: 3_723) == "1:02:03")
        #expect(EscaletaExporter.timestampText(fromSeconds: -5) == "0:00")
    }
}

@Suite("WP4 escaleta warnings")
struct WP4EscaletaWarningTests {
    @Test func unknownCueWarningsCarryTheirArguments() throws {
        let markdown = [
            "# Documento",
            "",
            "# Guion",
            "",
            "## 0:00 — Escena",
            "",
            "Texto.",
            "",
            "[MARCADOR RARO: algo]",
            ""
        ].joined(separator: "\n")

        let result = EscaletaParser.parse(markdown)
        let warning = try #require(result.warnings.first { $0.kind == .unknownCue })
        #expect(warning.arguments == ["MARCADOR RARO"])
        #expect(!warning.message.isEmpty)
    }

    @Test func montageCuesAreNotBrollAndNotUnknown() {
        let kind = EscaletaCueKind(label: "Montaje")
        #expect(kind == .montage)
        #expect(!kind.isBRoll)
        #expect(EscaletaCueKind(label: "MARCADOR RARO") == .unknown)
    }
}
