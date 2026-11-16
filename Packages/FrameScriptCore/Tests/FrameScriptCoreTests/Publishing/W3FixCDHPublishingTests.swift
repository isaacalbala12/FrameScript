import Foundation
import Testing
@testable import FrameScriptCore

@Suite("W3FixCDH publishing")
struct W3FixCDHPublishingTests {
    private func chapterInput(_ title: String, duration: TimeInterval, excluded: Bool = false) -> ChapterSceneInput {
        ChapterSceneInput(
            sceneID: UUID(),
            title: title,
            duration: duration,
            isExcluded: excluded
        )
    }

    private func exportInput(
        title: String = "Título",
        description: String = "Descripción",
        chapters: [EscaletaChapter] = [],
        sources: [PublishingSource] = []
    ) -> PublishingExportInput {
        PublishingExportInput(
            projectTitle: "Proyecto",
            title: title,
            description: description,
            chapters: chapters,
            sources: sources
        )
    }

    // MARK: Validation

    @Test("W3FixCDH an empty pack warns about the missing title and description")
    func emptyPackWarnsAboutRequiredFields() {
        let rules = Set(PublishingValidator.issues(for: PublishingValidationInput()).map(\.rule))
        #expect(rules.contains(.titleMissing))
        #expect(rules.contains(.descriptionMissing))
    }

    @Test("W3FixCDH angle brackets in the title or description are errors")
    func angleBracketsAreErrors() {
        let issues = PublishingValidator.issues(
            for: PublishingValidationInput(
                title: "a<b",
                description: "texto > texto"
            )
        )
        #expect(issues.contains { $0.rule == .titleInvalidCharacters && $0.severity == .error })
        #expect(issues.contains { $0.rule == .descriptionInvalidCharacters && $0.severity == .error })
    }

    @Test("W3FixCDH the final studio description is validated against 5,000 characters")
    func studioDescriptionLengthIsValidated() {
        let chapters = (0..<15).map { index in
            EscaletaChapter(
                seconds: index * 20,
                timestamp: DurationFormat.clock(seconds: index * 20),
                title: "Capítulo \(index)"
            )
        }
        let input = PublishingExportInput(
            description: String(repeating: "x", count: 4_900),
            chapters: chapters
        )
        let studio = PublishingExport.studioDescription(input)
        let issues = PublishingValidator.issues(
            for: PublishingValidationInput(
                title: "Título",
                description: input.description,
                studioDescription: studio
            )
        )

        #expect(studio.count > PublishingLimits.descriptionMaximum)
        #expect(issues.contains { $0.rule == .studioDescriptionTooLong && $0.severity == .error })
    }

    @Test("W3FixCDH multi-word tags cost two extra characters")
    func tagCounterCountsQuotesForMultiWordTags() {
        #expect(PublishingText.tagCharacterCount(["assetto corsa", "ac"]) == 18)
    }

    // MARK: Export

    @Test("W3FixCDH a partially pasted chapter block is appended in full")
    func partialChapterBlockIsStillAppended() {
        let chapters = (0..<6).map { index in
            EscaletaChapter(
                seconds: index * 20,
                timestamp: DurationFormat.clock(seconds: index * 20),
                title: "Capitulo \(index)"
            )
        }
        let description = "Intro\n0:00 Capitulo 0\n0:20 Capitulo 1"
        let studio = PublishingExport.studioDescription(
            exportInput(description: description, chapters: chapters)
        )

        #expect(studio.contains("0:40 Capitulo 2"))
        #expect(studio.contains("1:40 Capitulo 5"))
    }

    @Test("W3FixCDH sources are filtered line by line")
    func sourcesAreFilteredLineByLine() {
        let sources = [
            PublishingSource(title: "Fuente A", url: "https://example.com/a"),
            PublishingSource(title: "Fuente B", url: "https://example.com/b")
        ]
        let studio = PublishingExport.studioDescription(
            exportInput(
                description: "Texto\n- Fuente A — https://example.com/a",
                sources: sources
            )
        )

        #expect(!studio.contains("- Fuente A — https://example.com/a\n- Fuente B"))
        #expect(studio.contains("- Fuente B — https://example.com/b"))
    }

    // MARK: Chapters

    @Test("W3FixCDH imported chapters without a scene stay in the export")
    func importedChaptersWithoutSceneAreExported() {
        let sceneID = UUID()
        let plan = PublishingChapters.plan(
            scenes: [
                ChapterSceneInput(sceneID: sceneID, title: "Gancho", duration: 30),
                ChapterSceneInput(sceneID: UUID(), title: "Prueba", duration: 60),
                ChapterSceneInput(sceneID: UUID(), title: "Cierre", duration: 30)
            ]
        )
        let imported = FrameScriptDocument.ChapterOverride(
            sceneID: nil,
            title: "Capítulo importado",
            startSeconds: 100
        )

        let chapters = PublishingChapters.escaletaChapters(plan: plan, importedOverrides: [imported])

        #expect(chapters.contains { $0.seconds == 100 && $0.title == "Capítulo importado" })
        #expect(chapters.map(\.seconds) == chapters.map(\.seconds).sorted())
    }

    // MARK: YouTube chapter merge

    @Test("W3FixCDH a short first chapter takes the next chapter's title")
    func shortFirstChapterTakesNextTitle() {
        let list = YouTubeChapters.make(scenes: [
            ExportScene(title: "Gancho", start: 0, duration: 3),
            ExportScene(title: "Prueba", start: 3, duration: 60),
            ExportScene(title: "Cierre", start: 63, duration: 30)
        ])

        #expect(list.text.hasPrefix("0:00 Prueba"))
        #expect(!list.text.contains("Gancho"))
        #expect(list.warnings.contains {
            $0.kind == .shortSceneMerged && $0.message.contains("capítulo siguiente")
        })
    }

    @Test("W3FixCDH the shorter-merge warning names the previous chapter and its start")
    func shortMiddleChapterWarningNamesPreviousChapter() {
        let list = YouTubeChapters.make(scenes: [
            ExportScene(title: "Intro", start: 0, duration: 30),
            ExportScene(title: "Corta", start: 30, duration: 4),
            ExportScene(title: "Cierre", start: 34, duration: 30)
        ])

        let warning = list.warnings.first { $0.kind == .shortSceneMerged }
        #expect(warning?.message.contains("capítulo anterior") == true)
        #expect(warning?.message.contains("Intro") == true)
        #expect(warning?.message.contains("0:00") == true)
    }

    // MARK: Resolve pack integration

    private func resolveOptions(
        includeChapters: Bool = true,
        writeInvalidChapters: Bool = false,
        includeFCPXML: Bool = true,
        includeChapterMarkersInFCPXML: Bool = true
    ) -> ResolvePackOptions {
        ResolvePackOptions(
            includeFCPXML: includeFCPXML,
            includeChapters: includeChapters,
            includeChapterMarkersInFCPXML: includeChapterMarkersInFCPXML,
            writeInvalidChapters: writeInvalidChapters
        )
    }

    private func publishingChapterList(
        _ entries: [(seconds: Int, title: String)]
    ) -> ChapterList {
        let chapters = entries.enumerated().map { index, entry in
            Chapter(
                startFrame: Timecode(seconds: TimeInterval(entry.seconds), rate: .fps25).frames,
                startSeconds: entry.seconds,
                title: entry.title,
                position: index + 1
            )
        }
        return ChapterList(
            chapters: chapters,
            text: chapters.map { "\(DurationFormat.clock(seconds: $0.startSeconds)) \($0.title)" }
                .joined(separator: "\n"),
            warnings: [],
            videoEndSeconds: 120
        )
    }

    private var threeScenes: [ExportScene] {
        [
            ExportScene(title: "Uno", start: 0, duration: 20),
            ExportScene(title: "Dos", start: 20, duration: 20),
            ExportScene(title: "Tres", start: 40, duration: 20)
        ]
    }

    @Test("W3FixCDH fewer than three chapters does not write a chapters file")
    func invalidChaptersFileIsOmitted() {
        let scenes = [
            ExportScene(title: "Uno", start: 0, duration: 20),
            ExportScene(title: "Dos", start: 20, duration: 20)
        ]
        let plan = ResolveDeliveryPack.plan(
            scenes: scenes,
            projectName: "Prueba",
            options: resolveOptions()
        )

        #expect(!plan.chapters.isValidForYouTube)
        #expect(plan.warningItems.contains { $0.kind.isChaptersOmitted })
        #expect(!ResolveDeliveryPack.files(for: plan).contains { $0.name == plan.names.chapters })
        #expect(ResolvePackReadme.make(plan: plan).contains("no se incluye"))
    }

    @Test("W3FixCDH the creator can explicitly force an invalid chapters file")
    func invalidChaptersFileCanBeForced() {
        let scenes = [
            ExportScene(title: "Uno", start: 0, duration: 20),
            ExportScene(title: "Dos", start: 20, duration: 20)
        ]
        let plan = ResolveDeliveryPack.plan(
            scenes: scenes,
            projectName: "Prueba",
            options: resolveOptions(writeInvalidChapters: true)
        )

        #expect(ResolveDeliveryPack.files(for: plan).contains { $0.name == plan.names.chapters })
    }

    @Test("W3FixCDH the CSV neutralises a formula-like shot summary")
    func csvNeutralisesFormulas() {
        let scene = ExportScene(
            title: "Escena",
            start: 0,
            duration: 20,
            shots: [
                ExportShot(summary: "+10 km/h", source: .cam, status: .approved)
            ]
        )
        let plan = ResolveDeliveryPack.plan(
            scenes: [scene],
            projectName: "Prueba",
            options: resolveOptions()
        )
        let file = ResolveDeliveryPack.files(for: plan).first { $0.name == plan.names.shotList }

        #expect(file?.text?.contains("'+10 km/h") == true)
    }

    @Test("W3FixCDH a real re-hook cue does not duplicate the scene-level purple marker")
    func rehookCueDoesNotDuplicateSceneMarker() {
        let scene = ExportScene(
            title: "Problema",
            start: 0,
            duration: 20,
            isRehook: true,
            emitsSceneRehookMarker: false,
            markers: [
                ExportMarker(offset: 5, name: "RE-HOOK", note: "Punto de re-enganche", color: .purple)
            ]
        )
        let plan = ResolveDeliveryPack.plan(
            scenes: [scene],
            projectName: "Prueba",
            options: resolveOptions()
        )

        #expect(plan.allMarkers.filter { $0.kind == .rehook }.isEmpty)
        #expect(plan.allMarkers.filter { $0.color == .purple }.count == 1)
    }

    @Test("W3FixCDH chapter warnings carry structured parameters for localization")
    func chapterWarningsCarryStructuredParameters() {
        let list = YouTubeChapters.make(scenes: [
            ExportScene(title: "Gancho", start: 0, duration: 3),
            ExportScene(title: "Prueba", start: 3, duration: 60)
        ])
        let warning = list.warnings.first { $0.kind == .shortSceneMerged }

        #expect(warning?.title == "Gancho")
        #expect(warning?.otherTitle == "Prueba")
        #expect(warning?.timestamp == "0:00")
    }
    @Test("W3FixCDH chapter lists differ only when both outputs are written")
    func chapterListsDifferOnlyWhenBothOutputsAreWritten() {
        let publishingList = publishingChapterList([
            (0, "Uno"), (25, "Dos"), (45, "Tres")
        ])

        let bothWritten = ResolveDeliveryPack.plan(
            scenes: threeScenes,
            projectName: "Prueba",
            options: resolveOptions(),
            chapters: publishingList
        )
        #expect(bothWritten.warningItems.contains { $0.kind.isChapterListsDiffer })

        let fileNotWritten = ResolveDeliveryPack.plan(
            scenes: threeScenes,
            projectName: "Prueba",
            options: resolveOptions(includeChapters: false),
            chapters: publishingList
        )
        #expect(!fileNotWritten.warningItems.contains { $0.kind.isChapterListsDiffer })

        let noFCPXMLMarkers = ResolveDeliveryPack.plan(
            scenes: threeScenes,
            projectName: "Prueba",
            options: resolveOptions(includeChapterMarkersInFCPXML: false),
            chapters: publishingList
        )
        #expect(!noFCPXMLMarkers.warningItems.contains { $0.kind.isChapterListsDiffer })

        let identical = ResolveDeliveryPack.plan(
            scenes: threeScenes,
            projectName: "Prueba",
            options: resolveOptions(),
            chapters: nil
        )
        #expect(!identical.warningItems.contains { $0.kind.isChapterListsDiffer })
    }

    @Test("W3FixCDH chapter comparison ignores order but not content")
    func chapterListComparisonUsesContent() {
        let first = publishingChapterList([(0, "Uno"), (20, "Dos")])
        let reordered = publishingChapterList([(20, "Dos"), (0, "Uno")])
        let reworded = publishingChapterList([(0, "Uno"), (20, "Dos editado")])
        let extra = publishingChapterList([(0, "Uno"), (20, "Dos"), (30, "Extra")])

        #expect(!ResolveDeliveryPack.chapterListsDiffer(first, reordered))
        #expect(ResolveDeliveryPack.chapterListsDiffer(first, reworded))
        #expect(ResolveDeliveryPack.chapterListsDiffer(first, extra))
    }

    @Test("W3FixCDH sceneless chapters keep the list valid for YouTube")
    func scenelessChaptersAreOnlyDeduplicatedExactly() {
        let plan = PublishingChapters.plan(
            scenes: [
                ChapterSceneInput(sceneID: UUID(), title: "Uno", duration: 30),
                ChapterSceneInput(sceneID: UUID(), title: "Dos", duration: 30),
                ChapterSceneInput(sceneID: UUID(), title: "Tres", duration: 30)
            ]
        )
        let overrides = [
            FrameScriptDocument.ChapterOverride(
                sceneID: nil,
                title: "Uno",
                startSeconds: 0
            ),
            FrameScriptDocument.ChapterOverride(
                sceneID: nil,
                title: "Otra versión del gancho",
                startSeconds: 0
            ),
            FrameScriptDocument.ChapterOverride(
                sceneID: nil,
                title: "Antes de la primera escena",
                startSeconds: 10
            )
        ]

        let chapters = PublishingChapters.escaletaChapters(
            plan: plan,
            importedOverrides: overrides
        )

        // One chapter per second: the scene chapter wins at 0:00.
        #expect(chapters.filter { $0.seconds == 0 }.count == 1)
        #expect(chapters.first { $0.seconds == 0 }?.title == "Uno")
        #expect(!chapters.contains { $0.title == "Otra versión del gancho" })
        // A sceneless chapter at a free second is still exported.
        #expect(chapters.contains { $0.seconds == 10 && $0.title == "Antes de la primera escena" })
        #expect(Set(chapters.map(\.seconds)).count == chapters.count)
    }
}

private extension ResolvePackWarning.Kind {
    var isChaptersOmitted: Bool {
        if case .chaptersOmitted = self { return true }
        return false
    }

    var isChapterListsDiffer: Bool {
        if case .chapterListsDiffer = self { return true }
        return false
    }
}
