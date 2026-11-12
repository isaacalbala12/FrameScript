import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Published compare – retention import")
struct PublishedCompareRetentionImportTests {
    @Test func parsesEnglishStudioExportWithPreamble() throws {
        let text = try PublishedCompareFixtures.text("retention-studio-en", extension: "csv")
        let result = try RetentionCSVParser.parse(text, videoDuration: 120)

        #expect(result.samples.count == 9)
        #expect(result.delimiter == .comma)
        #expect(result.positionUnit == .timecode)
        #expect(result.retentionUnit == .percent)
        #expect(result.positionColumn == "Video position")
        #expect(result.retentionColumn == "Absolute audience retention (%)")
        #expect(approximatelyEqual(result.samples[0].position, 0))
        #expect(approximatelyEqual(result.samples[0].retention, 1.0))
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[1].retention, 0.842))
        #expect(approximatelyEqual(result.samples[8].position, 120))
        #expect(approximatelyEqual(result.samples[8].retention, 0.31))
    }

    @Test func parsesSpanishStudioExportWithDecimalComma() throws {
        let text = try PublishedCompareFixtures.text("retention-studio-es", extension: "csv")
        let result = try RetentionCSVParser.parse(text, videoDuration: 120)

        #expect(result.samples.count == 9)
        #expect(result.delimiter == .semicolon)
        #expect(result.positionUnit == .timecode)
        #expect(result.retentionUnit == .percent)
        #expect(result.positionColumn == "Posición del vídeo")
        #expect(result.retentionColumn == "Retención de audiencia absoluta (%)")
        #expect(approximatelyEqual(result.samples[2].position, 30))
        #expect(approximatelyEqual(result.samples[2].retention, 0.765))
        #expect(approximatelyEqual(result.samples[4].retention, 0.613))
    }

    @Test func parsesYouTubeAnalyticsRatiosWithDuration() throws {
        let text = try PublishedCompareFixtures.text("retention-api-ratio", extension: "csv")
        let result = try RetentionCSVParser.parse(text, videoDuration: 300)

        #expect(result.samples.count == 9)
        #expect(result.positionUnit == .ratio)
        #expect(result.retentionUnit == .ratio)
        #expect(approximatelyEqual(result.samples[0].position, 3))
        #expect(approximatelyEqual(result.samples[0].retention, 0.98))
        #expect(approximatelyEqual(result.samples[5].position, 30))
        #expect(approximatelyEqual(result.samples[5].retention, 1.04))
        #expect(approximatelyEqual(result.samples[8].position, 300))
        #expect(approximatelyEqual(result.samples[8].retention, 0.42))
    }

    @Test func parsesHeaderlessRatioColumns() throws {
        let text = try PublishedCompareFixtures.text("retention-headerless-ratio", extension: "csv")
        let result = try RetentionCSVParser.parse(text, videoDuration: 300)

        #expect(result.samples.count == 9)
        #expect(result.positionUnit == .ratio)
        #expect(result.retentionUnit == .ratio)
        #expect(approximatelyEqual(result.samples[0].position, 3))
        #expect(approximatelyEqual(result.samples[8].position, 300))
    }

    @Test func parsesPastedTabColumnsWithDecimalComma() throws {
        let text = try PublishedCompareFixtures.text("retention-paste", extension: "txt")
        let result = try RetentionCSVParser.parsePastedColumns(text)

        #expect(result.samples.count == 9)
        #expect(result.delimiter == .tab)
        #expect(result.positionUnit == .seconds)
        #expect(result.retentionUnit == .percent)
        #expect(approximatelyEqual(result.samples[0].position, 0))
        #expect(approximatelyEqual(result.samples[0].retention, 1.0))
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[1].retention, 0.842))
        #expect(approximatelyEqual(result.samples[8].position, 120))
    }

    @Test func parsesSecondsAndPercentWithoutDuration() throws {
        let text = try PublishedCompareFixtures.text("retention-seconds-percent", extension: "csv")
        let result = try RetentionCSVParser.parse(text)

        #expect(result.samples.count == 9)
        #expect(result.positionUnit == .seconds)
        #expect(result.retentionUnit == .percent)
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[1].retention, 0.842))
    }

    @Test func rejectsRelativeOnlyExport() throws {
        let text = try PublishedCompareFixtures.text("retention-relative-only", extension: "csv")
        #expect(throws: RetentionImportError.relativeRetentionOnly) {
            try RetentionCSVParser.parse(text, videoDuration: 60)
        }
    }

    @Test func requiresDurationForNormalizedPositions() {
        let text = """
        "Video position","Absolute audience retention (%)"
        "0%","100%"
        "50%","80%"
        "100%","40%"
        """
        #expect(throws: RetentionImportError.missingVideoDuration) {
            try RetentionCSVParser.parse(text)
        }
    }

    @Test func toleratesBadRowsAndReportsSkippedRows() throws {
        let text = """
        "Video position","Absolute audience retention (%)"
        "0:00","100.00%"
        "not a time","garbage"
        "0:30","80.00%"
        "1:00",""
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 60)

        #expect(result.samples.count == 2)
        #expect(result.warnings.contains { $0.contains("Skipped 2 rows") })
        #expect(approximatelyEqual(result.samples[1].position, 30))
    }

    @Test func averagesDuplicatePositions() throws {
        let text = """
        Time (seconds),Retention (%)
        0,100
        0,90
        15,80
        """
        let result = try RetentionCSVParser.parse(text)

        #expect(result.samples.count == 2)
        #expect(approximatelyEqual(result.samples[0].retention, 0.95))
        #expect(result.warnings.contains { $0.contains("Merged 1 duplicate") })
    }

    @Test func parsesWhitespacePaste() throws {
        let text = """
        0:00 100%
        0:15 84%
        0:30 76%
        """
        let result = try RetentionCSVParser.parsePastedColumns(text)

        #expect(result.samples.count == 3)
        #expect(result.positionUnit == .timecode)
        #expect(result.retentionUnit == .percent)
        #expect(approximatelyEqual(result.samples[2].position, 30))
    }

    @Test func convertsPercentPositionsToSeconds() throws {
        let text = """
        Video position,Absolute audience retention (%)
        0%,100%
        25%,80%
        50%,60%
        100%,40%
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 200)

        #expect(result.positionUnit == .percent)
        #expect(result.samples.count == 4)
        #expect(approximatelyEqual(result.samples[1].position, 50))
        #expect(approximatelyEqual(result.samples[2].position, 100))
        #expect(approximatelyEqual(result.samples[3].position, 200))
    }

    @Test func dropsPointsBeyondVideoDuration() throws {
        let text = """
        Time (seconds),Retention (%)
        0,100
        30,80
        90,60
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 60)

        #expect(result.samples.count == 2)
        #expect(result.warnings.contains { $0.contains("beyond the video duration") })
    }

    @Test func treatsShortVideoPositionsAsSecondsWhenTheyEndAtDuration() throws {
        let text = """
        Video position,Absolute audience retention (%)
        0,100.0
        30,80.0
        60,60.0
        90,40.0
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 90)

        #expect(result.positionUnit == .seconds)
        #expect(result.samples.count == 4)
        #expect(approximatelyEqual(result.samples.last?.position, 90))
    }

    @Test func prefersDelimiterThatParsesDataWhenHeadersContainCommas() throws {
        let text = """
        "Position, seconds";"Retention, percent"
        "0:00";"100,00"
        "0:30";"80,00"
        "1:00";"60,00"
        """
        let result = try RetentionCSVParser.parse(text, videoDuration: 60)

        #expect(result.delimiter == .semicolon)
        #expect(result.samples.count == 3)
        #expect(approximatelyEqual(result.samples[0].retention, 1.0))
        #expect(approximatelyEqual(result.samples[1].retention, 0.80))
    }

    @Test func parsesSpanishTiempoSegundosHeader() throws {
        let text = """
        Tiempo (s);Retención (%)
        0;100
        15;84,2
        30;76,5
        """
        let result = try RetentionCSVParser.parse(text)

        #expect(result.delimiter == .semicolon)
        #expect(result.positionUnit == .seconds)
        #expect(result.retentionUnit == .percent)
        #expect(result.samples.count == 3)
        #expect(approximatelyEqual(result.samples[1].position, 15))
        #expect(approximatelyEqual(result.samples[1].retention, 0.842))
    }

    @Test func parsesSemicolonPasteWithDecimalComma() throws {
        let text = """
        0;100,0%
        15;84,2%
        """
        let result = try RetentionCSVParser.parsePastedColumns(text, videoDuration: 15)

        #expect(result.delimiter == .semicolon)
        #expect(result.positionUnit == .seconds)
        #expect(result.samples.count == 2)
        #expect(approximatelyEqual(result.samples[1].retention, 0.842))
    }

    @Test func importedCurveRoundTripsThroughCodable() throws {
        let text = try PublishedCompareFixtures.text("retention-studio-en", extension: "csv")
        let result = try RetentionCSVParser.parse(text, videoDuration: 120)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(RetentionImport.self, from: data)

        #expect(decoded == result)
    }
}
