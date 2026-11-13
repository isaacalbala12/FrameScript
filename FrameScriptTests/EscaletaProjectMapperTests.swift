import Foundation
@testable import FrameScript
import FrameScriptCore
import XCTest

@MainActor
final class EscaletaProjectMapperTests: XCTestCase {
    func testACEvoFixtureMapsScenesCuesAndPublishingPack() throws {
        let result = try fixture("ac-evo-style.md")
        let mapping = EscaletaProjectMapper.map(result, options: .init(wordsPerMinute: 150))
        let project = mapping.project
        let scenes = project.scenes.sortedByOrder

        XCTAssertEqual(project.title, "VELOCITY RIDGE 3.0 — ESCALETA Y SEO")
        XCTAssertEqual(project.primaryLanguage, "en")
        XCTAssertEqual(project.productionStatus, .script)
        XCTAssertEqual(scenes.count, 9)
        XCTAssertEqual(scenes.map(\.title), [
            "Hook", "The 2.5 problem", "Career mode", "Damage and repairs", "Gravel tyres",
            "Stages and editor", "Menus and performance", "Roadmap and community", "Verdict"
        ])
        XCTAssertEqual(scenes.first?.targetDuration, 40)
        XCTAssertEqual(scenes[1].targetDuration, 60)
        XCTAssertNil(scenes.last?.targetDuration)

        XCTAssertFalse(scenes[0].scriptText.contains("[IMAGEN"))
        XCTAssertTrue(scenes[0].scriptText.hasPrefix("Velocity Ridge 3.0 is out"))
        XCTAssertTrue(scenes[3].escaletaHasReHook)
        XCTAssertTrue(scenes[6].escaletaHasReHook)
        XCTAssertTrue(scenes[4].notes.contains("Nota de grabación: compare a fresh set"))

        XCTAssertEqual(mapping.stats.sceneCount, 9)
        XCTAssertEqual(mapping.stats.cueCount, 12)
        XCTAssertEqual(mapping.stats.bRollCount, 9)
        XCTAssertEqual(mapping.stats.recordingNoteCount, 1)
        XCTAssertEqual(mapping.stats.reHookCount, 2)
        XCTAssertEqual(mapping.stats.anchorsResolved, 9)
        XCTAssertEqual(mapping.stats.anchorsUnresolved, 0)
        XCTAssertEqual(mapping.stats.bRollCount(for: .unspecified), 6)
        XCTAssertEqual(mapping.stats.bRollCount(for: .obsGameplay), 3)
        XCTAssertEqual(mapping.stats.sourceCount, 3)
        XCTAssertEqual(mapping.stats.claimCount, 0)
        XCTAssertEqual(mapping.stats.comparisonTableCount, 0)
        XCTAssertEqual(mapping.stats.seoFields, [
            .evidence, .primaryTitle, .titleCandidates, .thumbnailBrief,
            .description, .chapters, .tags, .hashtags, .pinnedComment, .communityPost
        ])

        let firstItem = try XCTUnwrap(scenes[0].bRollItems.first)
        XCTAssertEqual(firstItem.sourceType, .custom)
        XCTAssertEqual(firstItem.status, .planned)
        XCTAssertEqual(firstItem.templateType, "Escaleta")
        let anchor = try XCTUnwrap(firstItem.textAnchor)
        XCTAssertTrue(anchor.selectedText.hasPrefix("Velocity Ridge 3.0 is out"))
        XCTAssertNotNil(TextAnchorRepair.current(anchor, in: scenes[0].scriptText))
        XCTAssertTrue(firstItem.notes.contains("Cue original: [IMAGEN:"))
        XCTAssertTrue(firstItem.notes.contains("Posición: antes"))

        let pack = try XCTUnwrap(project.publishingPacks[project.primaryLanguage])
        XCTAssertEqual(pack.chosenTitle, "VELOCITY RIDGE 3.0: DOES IT FINALLY MAKE SENSE?")
        XCTAssertEqual(pack.titleCandidates.count, 4)
        XCTAssertEqual(pack.chaptersCount, 9)
        XCTAssertEqual(pack.tags.count, 12)
        XCTAssertEqual(pack.hashtags, ["#VelocityRidge", "#GravelRacing", "#SimRally"])
        XCTAssertFalse(pack.description.isEmpty)
        XCTAssertFalse(pack.pinnedComment.isEmpty)
        XCTAssertFalse(pack.communityPost.isEmpty)
        XCTAssertFalse(pack.thumbnailConceptNotes.isEmpty)

        XCTAssertTrue(project.topic.contains("Promesa:"))
        XCTAssertTrue(project.topic.contains("Tesis:"))
        XCTAssertTrue(project.topic.contains("Nota de versión:"))
        XCTAssertTrue(project.unparsedSections.isEmpty)
    }

    func testVRCFixtureMapsCameraGraphicAndTableSourcesAndClaims() throws {
        let result = try fixture("vrc-style.md")
        let mapping = EscaletaProjectMapper.map(result)
        let project = mapping.project
        let scenes = project.scenes.sortedByOrder

        XCTAssertEqual(scenes.count, 12)
        XCTAssertEqual(mapping.stats.cueCount, 18)
        XCTAssertEqual(mapping.stats.reHookCount, 2)
        XCTAssertEqual(mapping.stats.bRollCount(for: .camera), 2)
        XCTAssertEqual(mapping.stats.bRollCount(for: .graphic), 3)
        XCTAssertEqual(mapping.stats.bRollCount(for: .table), 1)
        XCTAssertEqual(mapping.stats.bRollCount(for: .obsGameplay), 4)
        XCTAssertEqual(mapping.stats.bRollCount(for: .unspecified), 6)
        XCTAssertEqual(mapping.stats.claimCount, 6)
        XCTAssertEqual(mapping.stats.checklistTaskCount, 6)
        XCTAssertEqual(mapping.stats.comparisonTableCount, 1)
        XCTAssertEqual(mapping.stats.anchorsResolved, mapping.stats.bRollCount)
        XCTAssertEqual(mapping.stats.anchorsUnresolved, 0)

        let pack = try XCTUnwrap(project.publishingPacks[project.primaryLanguage])
        XCTAssertEqual(pack.chosenTitle, pack.titleCandidates.first)
        XCTAssertEqual(pack.titleCandidates.count, 4)
        XCTAssertEqual(pack.chaptersCount, 12)
        XCTAssertEqual(pack.chapterOverrides.count, 12)
        XCTAssertNotNil(pack.chapterOverrides.first?.sceneID)
        XCTAssertEqual(pack.chapterOverrides.first?.sceneID, scenes.first?.id)

        let table = try XCTUnwrap(project.comparisonTables.first)
        XCTAssertEqual(table.header.count, 5)
        XCTAssertEqual(table.rows.count, 9)
        XCTAssertEqual(table.title, "Tabla comparativa (para pantalla)")

        XCTAssertEqual(project.checklistTasks.filter { $0.kind == .research }.count, 6)
        XCTAssertTrue(project.claims.allSatisfy { $0.status == .probable })
        XCTAssertEqual(project.sources.count, mapping.stats.sourceCount)
        XCTAssertGreaterThan(project.sources.count, 0)
    }

    func testBeamNGFixtureMapsOutlineAndSEOFields() throws {
        let result = try fixture("beamng-style.md")
        let mapping = EscaletaProjectMapper.map(result)
        let project = mapping.project

        XCTAssertEqual(project.scenes.count, 9)
        XCTAssertEqual(project.videoType, "update")
        XCTAssertEqual(mapping.stats.bRollCount, 13)
        XCTAssertEqual(mapping.stats.reHookCount, 1)
        XCTAssertEqual(mapping.stats.sceneCount, 9)
        XCTAssertEqual(project.publishingPacks[project.primaryLanguage]?.titleCandidates.count, 4)
        XCTAssertEqual(project.publishingPacks[project.primaryLanguage]?.hashtags.count, 3)
        XCTAssertEqual(project.publishingPacks[project.primaryLanguage]?.chaptersCount, 9)
    }

    func testEverySyntheticEscaletaAnchorResolves() throws {
        let names = [
            "ac-evo-style.md", "beamng-style.md", "vrc-style.md",
            "edge-no-timestamps.md", "edge-scene-only.md", "edge-title-script.md",
            "edge-dual-sources.md", "edge-seo-miniature.md", "edge-global-h2.md",
            "edge-fenced-scene.md", "edge-inline-unknown.md", "edge-empty-sections.md",
            "edge-interior-rule.md", "edge-pre-title.md", "edge-title-script-note.md",
            "edge-scene-only.md"
        ]

        for name in names {
            let result = try fixture(name)
            guard result.document.kind == .escaleta else { continue }
            let mapping = EscaletaProjectMapper.map(result)
            for scene in mapping.project.scenes {
                for item in scene.bRollItems {
                    guard let anchor = item.textAnchor else { continue }
                    XCTAssertNotNil(
                        TextAnchorRepair.current(anchor, in: scene.scriptText),
                        "Anchor in \(name), scene \(scene.title): \(anchor.selectedText)"
                    )
                    XCTAssertEqual(item.status, .planned)
                }
                for item in scene.bRollItems {
                    XCTAssertFalse(item.descriptionText.isEmpty, "Empty B-roll description in \(name)")
                }
            }
        }
    }

    func testImportExportRoundTripKeepsScenesCuesAndPublishingFields() throws {
        for name in ["ac-evo-style.md", "vrc-style.md", "beamng-style.md"] {
            let result = try fixture(name)
            let mapping = EscaletaProjectMapper.map(result)
            let markdown = EscaletaProjectExporter.markdown(from: mapping.project)
            let reimported = EscaletaParser.parse(markdown).document
            let original = result.document

            XCTAssertEqual(reimported.title, original.title, "Title changed in \(name)")
            XCTAssertEqual(reimported.promise, original.promise, "Promise changed in \(name)")
            XCTAssertEqual(reimported.thesis, original.thesis, "Thesis changed in \(name)")
            XCTAssertEqual(reimported.scenes.count, original.scenes.count, "Scene count changed in \(name)")

            for (lhs, rhs) in zip(original.scenes, reimported.scenes) {
                XCTAssertEqual(rhs.startSeconds, lhs.startSeconds, "Start changed in \(name): \(lhs.title)")
                XCTAssertEqual(rhs.title, lhs.title, "Title changed in \(name)")
                XCTAssertEqual(rhs.text, lhs.text, "Script text changed in \(name): \(lhs.title)")
                XCTAssertEqual(cueSignatures(rhs), cueSignatures(lhs), "Cues changed in \(name): \(lhs.title)")
            }

            XCTAssertEqual(
                reimported.publishing?.primaryTitle ?? reimported.publishing?.titleCandidates.first,
                original.publishing?.primaryTitle ?? original.publishing?.titleCandidates.first,
                "Chosen title changed in \(name)"
            )
            XCTAssertEqual(reimported.publishing?.titleCandidates, original.publishing?.titleCandidates, "Title candidates changed in \(name)")
            XCTAssertEqual(reimported.publishing?.description, original.publishing?.description, "Description changed in \(name)")
            XCTAssertEqual(reimported.publishing?.tags, original.publishing?.tags, "Tags changed in \(name)")
            XCTAssertEqual(reimported.publishing?.hashtags, original.publishing?.hashtags, "Hashtags changed in \(name)")
            XCTAssertEqual(reimported.publishing?.pinnedComment, original.publishing?.pinnedComment, "Pinned comment changed in \(name)")
            XCTAssertEqual(reimported.publishing?.communityPost, original.publishing?.communityPost, "Community post changed in \(name)")
            XCTAssertEqual(reimported.publishing?.thumbnailBrief, original.publishing?.thumbnailBrief, "Thumbnail changed in \(name)")
            XCTAssertEqual(reimported.publishing?.evidence, original.publishing?.evidence, "Evidence changed in \(name)")
            XCTAssertEqual(chapterSignatures(reimported.publishing), chapterSignatures(original.publishing), "Chapters changed in \(name)")

            XCTAssertEqual(
                reimported.sources.map(\.raw).sorted(),
                original.sources.map(\.raw).sorted(),
                "Sources changed in \(name)"
            )
            XCTAssertEqual(
                reimported.comparisonTables.map(\.header),
                original.comparisonTables.map(\.header),
                "Table headers changed in \(name)"
            )
            XCTAssertEqual(
                reimported.comparisonTables.map(\.rows),
                original.comparisonTables.map(\.rows),
                "Table rows changed in \(name)"
            )
            XCTAssertEqual(
                reimported.verificationItems.map(verificationSignature),
                original.verificationItems.map(verificationSignature),
                "Verification items changed in \(name)"
            )
        }
    }

    func testThumbnailConceptsAndDossierKeepTheirKind() throws {
        let thumbnails = try fixture("thumbnail-concepts.md")
        XCTAssertEqual(thumbnails.document.kind, .thumbnailConcepts)
        XCTAssertEqual(thumbnails.document.thumbnailConcepts?.groups.count, 2)
        XCTAssertEqual(thumbnails.document.thumbnailConcepts?.groups.reduce(0) { $0 + $1.concepts.count }, 6)
        XCTAssertEqual(thumbnails.document.thumbnailConcepts?.sharedRules.count, 5)

        let dossier = try fixture("edge-dossier.md")
        XCTAssertEqual(dossier.document.kind, .researchDossier)
        XCTAssertFalse(dossier.document.unparsedSections.isEmpty)
    }

    func testLanguageDetectionUsesDocumentContent() {
        let spanish = EscaletaParser.parse("""
        # Análisis de la actualización

        ## Promesa del vídeo

        El vídeo explica qué cambia en el juego y por qué importa para el jugador.

        # Guion

        ## 0:00 — Gancho

        Esto es una prueba del coche en la pista con la cámara y el volante.
        """).document
        let english = EscaletaParser.parse("""
        # Update analysis

        ## Promesa del vídeo

        This video explains what changed in the game and why it matters to the player.

        # Script

        ## 0:00 — Hook

        This is a test of the car on the track with the camera and the wheel.
        """).document
        let russian = EscaletaParser.parse("""
        # Анализ обновления

        ## Promesa del vídeo

        В этом видео объясняется, что изменилось в игре и почему это важно.

        # Сценарий

        ## 0:00 — Начало

        Это тест машины на трассе с камерой и рулём.
        """).document
        XCTAssertEqual(EscaletaLanguageDetector.detect(spanish), "es")
        XCTAssertEqual(EscaletaLanguageDetector.detect(english), "en")
        XCTAssertEqual(EscaletaLanguageDetector.detect(russian), "ru")
    }

    func testReHookIsStoredAsCueNotSpokenText() throws {
        let result = try fixture("vrc-style.md")
        let project = EscaletaProjectMapper.map(result).project
        let scenes = project.scenes.sortedByOrder
        XCTAssertEqual(scenes.filter(\.escaletaHasReHook).count, 2)
        for scene in scenes {
            XCTAssertFalse(scene.scriptText.contains("[RE-HOOK]"))
            XCTAssertFalse(scene.scriptText.contains("RE-HOOK"))
        }
        let rehookScene = try XCTUnwrap(scenes.first(where: \.escaletaHasReHook))
        XCTAssertTrue(rehookScene.editingItems.contains { $0.cutStyle == "RE-HOOK" })
        let exported = EscaletaProjectExporter.markdown(from: project)
        XCTAssertTrue(exported.contains("[RE-HOOK]"))
    }

    func testCandidatesOnlySourceStoresNoPrimaryTitleButUserEditExportsOne() throws {
        let result = try fixture("vrc-style.md")
        let project = EscaletaProjectMapper.map(result).project
        var pack = try XCTUnwrap(project.publishingPacks[project.primaryLanguage])
        XCTAssertEqual(pack.chosenTitle, pack.titleCandidates.first)

        let unchanged = EscaletaParser.parse(EscaletaProjectExporter.markdown(from: project)).document
        XCTAssertNil(unchanged.publishing?.primaryTitle)

        pack.chosenTitle = "A user chosen title"
        project.publishingPacks[project.primaryLanguage] = pack
        let edited = EscaletaParser.parse(EscaletaProjectExporter.markdown(from: project)).document
        XCTAssertEqual(edited.publishing?.primaryTitle, "A user chosen title")
    }

    func testFullDocumentRoundTripMatchesEverythingExceptLineNumbers() throws {
        let directory = try fixturesDirectory()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".md") }
            .sorted()
        var checked = 0
        for name in names {
            let result = try fixture(name)
            guard result.document.kind == .escaleta else { continue }
            let original = result.document
            let mapping = EscaletaProjectMapper.map(EscaletaImportResult(document: original))
            let markdown = EscaletaProjectExporter.markdown(from: mapping.project)
            let reimported = EscaletaParser.parse(markdown).document
            XCTAssertEqual(reimported, original, "Full document changed in \(name)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testProjectNotesCodecKeepsFrontMatter() {
        let notes = EscaletaProjectNotes(
            promise: "Promesa\ncon dos líneas",
            thesis: "Tesis",
            versionNote: "Versión 1",
            scriptIntro: "Introducción",
            pacingNotes: ["Ritmo rápido", "Cortes cada 3 s"]
        )
        XCTAssertEqual(EscaletaProjectNotes.decode(notes.encoded()), notes)
    }

    func testThumbnailAndDossierRequestsExplainAndEnableOnlyTheirMode() throws {
        let thumbnails = try fixture("thumbnail-concepts.md")
        let thumbnailRequest = EscaletaImportRequest(
            url: URL(fileURLWithPath: "/tmp/concepts.md"),
            markdown: "",
            result: thumbnails,
            mapping: nil,
            mode: .appendThumbnailConcepts
        )
        XCTAssertEqual(thumbnailRequest.thumbnailConceptCount, 6)
        XCTAssertTrue(thumbnailRequest.isConfirmEnabled)
        XCTAssertFalse(
            EscaletaImportRequest(
                url: URL(fileURLWithPath: "/tmp/concepts.md"),
                markdown: "",
                result: thumbnails,
                mapping: nil,
                mode: .requiresOpenProject
            ).isConfirmEnabled
        )

        let dossier = try fixture("edge-dossier.md")
        let dossierRequest = EscaletaImportRequest(
            url: URL(fileURLWithPath: "/tmp/dossier.md"),
            markdown: "",
            result: dossier,
            mapping: nil,
            mode: .appendResearchDossier
        )
        XCTAssertFalse(dossierRequest.dossierSections.isEmpty)
        XCTAssertTrue(dossierRequest.isConfirmEnabled)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> EscaletaImportResult {
        let url = try fixturesDirectory().appendingPathComponent(name)
        let markdown = try String(contentsOf: url, encoding: .utf8)
        return EscaletaParser.parse(markdown)
    }

    private func fixturesDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Packages/FrameScriptCore/Tests/FrameScriptCoreTests/Fixtures/MarkdownImport")
    }

    private func cueSignatures(_ scene: EscaletaScene) -> [String] {
        scene.cues
            .map { "\($0.kind.rawValue)|\($0.label)|\($0.payload ?? "")" }
            .sorted()
    }

    private func chapterSignatures(_ pack: EscaletaPublishingPack?) -> [String] {
        (pack?.chapters ?? [])
            .map { "\($0.seconds)|\($0.title)" }
    }

    private func verificationSignature(_ item: EscaletaVerificationItem) -> String {
        if let label = item.label, !label.isEmpty {
            return "\(label): \(item.text)"
        }
        return item.text
    }
}

private extension PublishingPack {
    var chaptersCount: Int { chapterOverrides.count }
}
