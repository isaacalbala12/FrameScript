import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// WP4 regressions: escaleta export/import and the app export formats.
@MainActor
final class WP4ExportsTests: FrameScriptTestCase {
    // MARK: - Escaleta: scene tables survive an edit

    func testEscaletaExportKeepsSceneTableAfterAParagraphEdit() throws {
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

        ## 0:30 — Escena dos

        Texto de la segunda escena.
        """

        let mapping = importMarkdown(markdown)
        XCTAssertEqual(mapping.project.comparisonTables.count, 1)
        let scene = try XCTUnwrap(mapping.project.scenes.sortedByOrder.first)
        scene.scriptText += "\n\nPárrafo nuevo añadido después de importar."

        let exported = EscaletaProjectExporter.markdown(from: mapping.project)
        XCTAssertTrue(exported.contains("| Ganar | Perder |"), exported)
        XCTAssertTrue(exported.contains("| A | B |"), exported)

        let reparsed = EscaletaParser.parse(exported)
        XCTAssertEqual(reparsed.document.comparisonTables.count, 1)
        XCTAssertEqual(reparsed.document.comparisonTables.first?.sceneIndex, 0)
        XCTAssertEqual(reparsed.document.comparisonTables.first?.rows, [["A", "B"]])
    }

    // MARK: - Escaleta: edited b-roll text

    func testEditedBRollDescriptionIsExported() throws {
        let markdown = """
        # Escaleta

        # Guion

        ## 0:00 — Escena

        Hola mundo.

        [B-ROLL: texto viejo]
        """

        let mapping = importMarkdown(markdown)
        let scene = try XCTUnwrap(mapping.project.scenes.sortedByOrder.first)
        let item = try XCTUnwrap(scene.bRollItems.first)
        XCTAssertEqual(item.descriptionText, "texto viejo")
        item.descriptionText = "Texto nuevo editado"

        let exported = EscaletaProjectExporter.markdown(from: mapping.project)
        XCTAssertTrue(exported.contains("[B-ROLL: Texto nuevo editado]"), exported)
        XCTAssertFalse(exported.contains("texto viejo"), exported)
    }

    // MARK: - Escaleta: non re-hook editing items

    func testNonReHookEditingItemSurvivesExportAndReimport() throws {
        let text = "Hola mundo."
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: text,
            editingItems: [
                EditingItem(
                    textAnchor: TextAnchor(
                        startUTF16: 0,
                        lengthUTF16: (text as NSString).length,
                        selectedText: text
                    ),
                    templateType: "Escaleta",
                    cutStyle: "Corte rápido",
                    transition: "Barrido",
                    subtitleStyle: "",
                    notes: "saltar silencio"
                )
            ]
        )
        let project = FrameProject(title: "Proyecto", scenes: [scene])

        let exported = EscaletaProjectExporter.markdown(from: project)
        XCTAssertTrue(exported.contains("[MONTAJE: Corte rápido · Barrido · saltar silencio]"), exported)

        let reparsed = EscaletaParser.parse(exported)
        let remapping = EscaletaProjectMapper.map(
            reparsed,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        let reimported = try XCTUnwrap(remapping.project.scenes.first)
        XCTAssertEqual(reimported.editingItems.count, 1)
        XCTAssertEqual(reimported.editingItems[0].cutStyle, "Corte rápido · Barrido · saltar silencio")

        // A second export is stable: the original cue line is reused.
        let secondExport = EscaletaProjectExporter.markdown(from: remapping.project)
        XCTAssertTrue(secondExport.contains("[MONTAJE: Corte rápido · Barrido · saltar silencio]"), secondExport)
    }

    func testReHookStillExportsAsReHook() throws {
        let text = "Hola mundo."
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: text,
            editingItems: [
                EditingItem(
                    textAnchor: TextAnchor(
                        startUTF16: 0,
                        lengthUTF16: (text as NSString).length,
                        selectedText: text
                    ),
                    templateType: "Escaleta",
                    cutStyle: "RE-HOOK",
                    transition: "",
                    subtitleStyle: ""
                )
            ]
        )
        let exported = EscaletaProjectExporter.markdown(
            from: FrameProject(title: "Proyecto", scenes: [scene])
        )
        XCTAssertTrue(exported.contains("[RE-HOOK]"), exported)
        XCTAssertFalse(exported.contains("[MONTAJE"), exported)
    }

    // MARK: - Export formats: scene notes

    func testSceneNotesAppearInEveryExportFormat() {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: "Guion hablado.",
            notes: "Nota importante de grabación."
        )
        let project = FrameProject(title: "Proyecto", scenes: [scene])
        let preferences = AppSettings.defaults.exportPreferences
        let service = ExportService()

        for format in ExportFormat.allCases {
            let output = service.render(
                project: project,
                format: format,
                preferences: preferences,
                language: .spanish
            )
            XCTAssertTrue(
                output.contains("Nota importante de grabación."),
                "\(format) lost the scene notes: \(output)"
            )
        }
    }

    // MARK: - CSV safety

    func testCSVNeutralizesFormulasAndUsesCRLFRecords() {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: "Guion hablado.",
            bRollItems: [
                BRollItem(
                    templateType: "Escaleta",
                    sourceType: .screenRecording,
                    descriptionText: "=SUM(1)",
                    notes: "nota\r\ncon salto"
                )
            ]
        )
        let project = FrameProject(title: "Proyecto", scenes: [scene])
        var preferences = AppSettings.defaults.exportPreferences
        preferences.includeBRoll = true

        let csv = ExportService().render(
            project: project,
            format: .csv,
            preferences: preferences,
            language: .spanish
        )

        XCTAssertTrue(csv.contains("\"'=SUM(1)\""), csv)
        XCTAssertTrue(csv.contains("\"nota\r\ncon salto\""), csv)
        XCTAssertTrue(csv.contains("\r\n"), "CSV records must use CRLF")
        XCTAssertFalse(csv.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF found")
    }

    // MARK: - Small export issues

    func testPlainTextExportEndsWithANewline() {
        let project = FrameProject(
            title: "Proyecto",
            scenes: [Scene(order: 0, sectionType: .hook, title: "Escena", scriptText: "Guion.")]
        )
        let text = ExportService().render(
            project: project,
            format: .plainText,
            preferences: AppSettings.defaults.exportPreferences,
            language: .spanish
        )
        XCTAssertTrue(text.hasSuffix("\n"), "plain text must end with a newline")
    }

    func testOutlineDoesNotRepeatTheSceneLabelWhenSectionNamesAreOff() {
        let project = FrameProject(
            title: "Proyecto",
            scenes: [Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: "Guion.")]
        )
        var preferences = AppSettings.defaults.exportPreferences
        preferences.includeSectionNames = false

        let outline = ExportService().render(
            project: project,
            format: .productionOutline,
            preferences: preferences,
            language: .spanish
        )
        XCTAssertTrue(outline.contains("## Escena 01"), outline)
        XCTAssertFalse(outline.contains("## Escena 01 — Escena"), outline)
    }

    // MARK: - Crash hardening

    func testHugeChapterAndSceneDurationsExportWithoutATrap() {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: "Guion.",
            estimatedDuration: 12
        )
        scene.targetDuration = 1e300
        let project = FrameProject(title: "Proyecto", scenes: [scene])
        project.publishingPacks[project.primaryLanguage] = PublishingPack(
            chosenTitle: "Título",
            chapterOverrides: [
                ChapterOverride(title: "Capítulo enorme", startSeconds: 1e300),
                ChapterOverride(title: "Capítulo infinito", startSeconds: .infinity)
            ]
        )

        let exported = EscaletaProjectExporter.markdown(from: project)
        XCTAssertTrue(exported.contains("24:00:00 Capítulo enorme"), exported)
        XCTAssertTrue(exported.contains("0:00 Capítulo infinito"), exported)
    }

    // MARK: - Import reading speed

    func testImportResolvesTheWordsPerMinuteOfTheDetectedLanguage() throws {
        let markdown = """
        # Synthetic English escaleta

        # Script

        ## 0:00 — Scene

        This is a synthetic English sentence with exactly twelve words to measure.
        """

        let mapping = importMarkdown(markdown, options: EscaletaMappingOptions(settings: AppSettings.defaults))
        XCTAssertEqual(mapping.project.primaryLanguage, "en")
        let scene = try XCTUnwrap(mapping.project.scenes.first)
        // The English built-in rate is 160 wpm. Twelve spoken words = 4.5 s.
        XCTAssertEqual(scene.estimatedDuration, 4.5, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func importMarkdown(
        _ markdown: String,
        options: EscaletaMappingOptions = EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
    ) -> EscaletaProjectMapping {
        EscaletaProjectMapper.map(EscaletaParser.parse(markdown), options: options)
    }
}
