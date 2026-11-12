import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Fixtures

enum MarkdownFixture {
    static let canonicalNames = [
        "ac-evo-style",
        "beamng-style",
        "vrc-style",
        "thumbnail-concepts",
        "edge-no-timestamps",
        "edge-inline-unknown",
        "edge-empty-sections",
        "edge-dossier",
    ]

    static let allNames = canonicalNames

    static func text(_ name: String) throws -> String {
        let url = try url(for: name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func url(for name: String) throws -> URL {
        if let url = Bundle.module.url(
            forResource: name,
            withExtension: "md",
            subdirectory: "Fixtures/MarkdownImport"
        ) {
            return url
        }
        if let base = Bundle.module.resourceURL {
            let candidate = base.appendingPathComponent("Fixtures/MarkdownImport/\(name).md")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw FixtureError.missing(name)
    }

    enum FixtureError: Error {
        case missing(String)
    }
}

/// Whitespace-insensitive comparison used by the golden text tests: line
/// endings, trailing spaces, runs of spaces and repeated blank lines do not
/// count. Structural equality is checked separately.
func canonicalWhitespace(_ text: String) -> String {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    var result: [String] = []
    var previousBlank = false
    for raw in normalized.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            if !previousBlank { result.append("") }
            previousBlank = true
        } else {
            let collapsed = line.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            result.append(collapsed)
            previousBlank = false
        }
    }

    while result.first == "" { result.removeFirst() }
    while result.last == "" { result.removeLast() }
    return result.joined(separator: "\n")
}

// MARK: - AC-EVO-style fixture

@Test func acEVOStyleParsesTheFullContract() throws {
    let markdown = try MarkdownFixture.text("ac-evo-style")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .escaleta)
    #expect(document.title == "VELOCITY RIDGE 3.0 — ESCALETA Y SEO")
    #expect(document.versionNote?.contains("12 June 2028") == true)
    #expect(document.promise?.isEmpty == false)
    #expect(document.thesis?.isEmpty == false)
    #expect(document.outline.count == 9)
    #expect(document.outline.first?.marker == .numbered(1))
    #expect(document.outline.last?.text.hasPrefix("Verdict") == true)
    #expect(document.scriptHeading == "Guion")
    #expect(document.scenes.count == 9)
    #expect(document.scenes.map(\.timestampText) == [
        "0:00", "0:40", "1:40", "3:10", "4:35", "6:15", "7:30", "9:25", "10:35",
    ])
    #expect(document.scenes.allSatisfy { $0.separator == "—" })

    let cues = document.scenes.flatMap(\.cues)
    #expect(cues.count == 12)
    #expect(cues.filter { $0.kind == .image }.count == 6)
    #expect(cues.filter { $0.kind == .capture }.count == 1)
    #expect(cues.filter { $0.kind == .testOnScreen }.count == 1)
    #expect(cues.filter { $0.kind == .bRoll }.count == 1)
    #expect(cues.filter { $0.kind == .recordingNote }.count == 1)
    #expect(cues.filter { $0.kind == .rehook }.count == 2)

    let recordingNote = try #require(cues.first { $0.kind == .recordingNote })
    #expect(recordingNote.payload?.contains("three cars") == true)
    #expect(document.scenes[4].notes.count == 1)
    #expect(document.scenes[3].isRehook)
    #expect(document.scenes[0].text.contains("Velocity Ridge 3.0 is out"))
    #expect(document.scenes[0].bodyParagraphs.count == 3)

    let pack = try #require(document.publishing)
    #expect(pack.evidence.count == 3)
    #expect(pack.primaryTitle?.isEmpty == false)
    #expect(pack.titleCandidates.count == 4)
    #expect(pack.thumbnailBrief?.contains("FINALLY?") == true)
    #expect(pack.description?.contains("career") == true)
    #expect(pack.chapters.count == 9)
    #expect(pack.chaptersPlacement == .section)
    #expect(pack.tags.count == 12)
    #expect(pack.hashtags == ["#VelocityRidge", "#GravelRacing", "#SimRally"])
    #expect(pack.pinnedComment?.isEmpty == false)
    #expect(pack.communityPost?.isEmpty == false)
    #expect(pack.fieldOrder == EscaletaPublishingField.defaultOrder)

    #expect(document.sourcesPlacement == .descriptionTrailer)
    #expect(document.sources.count == 3)
    #expect(document.sources.allSatisfy { $0.origin == .descriptionTrailer })
    #expect(document.sources.allSatisfy { $0.links.count == 1 })

    #expect(document.comparisonTables.isEmpty)
    #expect(document.verificationItems.isEmpty)
    #expect(result.warnings.isEmpty)
}

@Test func acEVOStyleKeepsItsText() throws {
    let markdown = try MarkdownFixture.text("ac-evo-style")
    let exported = EscaletaExporter.markdown(from: EscaletaParser.parse(markdown).document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

// MARK: - BeamNG-style fixture

@Test func beamNGStyleParsesCuesAndPublishing() throws {
    let markdown = try MarkdownFixture.text("beamng-style")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .escaleta)
    #expect(document.scenes.count == 9)
    #expect(document.outline.count == 9)

    let cues = document.scenes.flatMap(\.cues)
    #expect(cues.count == 14)
    #expect(cues.filter { $0.kind == .image }.count == 8)
    #expect(cues.filter { $0.kind == .comparison }.count == 1)
    #expect(cues.filter { $0.kind == .test }.count == 1)
    #expect(cues.filter { $0.kind == .proposedTest }.count == 2)
    #expect(cues.filter { $0.kind == .graphic }.count == 1)
    #expect(cues.filter { $0.kind == .rehook }.count == 1)

    let emptyPayload = try #require(cues.first { $0.kind == .proposedTest && $0.payload == nil })
    #expect(emptyPayload.label == "PRUEBA PROPUESTA")

    let pack = try #require(document.publishing)
    #expect(pack.evidence.count == 3)
    #expect(pack.titleCandidates.count == 4)
    #expect(pack.chapters.count == 9)
    #expect(pack.tags.count == 17)
    #expect(pack.hashtags.count == 3)
    #expect(document.sources.count == 4)
    #expect(document.sourcesPlacement == .descriptionTrailer)
    #expect(result.warnings.isEmpty)
}

@Test func beamNGStyleKeepsItsText() throws {
    let markdown = try MarkdownFixture.text("beamng-style")
    let exported = EscaletaExporter.markdown(from: EscaletaParser.parse(markdown).document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

// MARK: - VRC-style fixture

@Test func vrcStyleParsesAnnexesAndBoldSEO() throws {
    let markdown = try MarkdownFixture.text("vrc-style")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .escaleta)
    #expect(document.scenes.count == 12)
    #expect(document.pacingNotes.count == 1)
    #expect(document.pacingNotes[0].contains("Pace"))
    #expect(document.scriptIntro == nil)

    let cues = document.scenes.flatMap(\.cues)
    #expect(cues.count == 18)
    #expect(cues.filter { $0.kind == .record }.count == 2)
    #expect(cues.filter { $0.kind == .screenTable }.count == 1)
    #expect(cues.filter { $0.kind == .lowerThird }.count == 3)
    #expect(cues.filter { $0.kind == .rehook }.count == 2)

    let table = try #require(document.comparisonTables.first)
    #expect(document.comparisonTables.count == 1)
    #expect(table.heading == "Tabla comparativa (para pantalla)")
    #expect(table.header.count == 5)
    #expect(table.header.first == "")
    #expect(table.rows.count == 9)
    #expect(table.alignments.count == 5)
    #expect(table.sceneIndex == nil)
    #expect(document.tableSectionHeading == "Tabla comparativa (para pantalla)")

    #expect(document.verifyHeading == "Verificar antes de grabar")
    #expect(document.verificationItems.count == 6)
    #expect(document.verificationItems.first?.label == "Release date")
    let proseItem = try #require(document.verificationItems.first { $0.label == nil })
    #expect(proseItem.text.contains("**Note** (clarification in parentheses)"))

    #expect(document.seoHeading == "SEO")
    #expect(document.seoHeadingLevel == 2)
    #expect(document.seoLayout == .boldLabels)
    let pack = try #require(document.publishing)
    #expect(pack.titleCandidates.count == 4)
    #expect(pack.thumbnailBrief?.contains("FULL THROTTLE BRAKING") == true)
    #expect(pack.description?.contains("2028 open-wheel car") == true)
    #expect(pack.chapters.count == 12)
    #expect(pack.chaptersPlacement == .inlineDescription)
    #expect(pack.tags.count == 12)
    #expect(pack.hashtags.isEmpty)
    #expect(pack.fieldOrder == [.titleCandidates, .thumbnailBrief, .description, .tags])

    #expect(document.sourcesHeading == "Fuentes principales")
    #expect(document.sourcesPlacement == .seoSection)
    #expect(document.sources.count == 4)
    #expect(document.sources.flatMap(\.links).count == 6)
    #expect(document.sources.first?.links.isEmpty == true)
    #expect(result.warnings.isEmpty)
}

@Test func vrcStyleKeepsItsText() throws {
    let markdown = try MarkdownFixture.text("vrc-style")
    let exported = EscaletaExporter.markdown(from: EscaletaParser.parse(markdown).document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

// MARK: - Thumbnail concepts

@Test func thumbnailConceptsParseTheSection36Format() throws {
    let markdown = try MarkdownFixture.text("thumbnail-concepts")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .thumbnailConcepts)
    #expect(document.scenes.isEmpty)
    let thumbnail = try #require(document.thumbnailConcepts)
    #expect(thumbnail.separatorAfterIntro)
    #expect(thumbnail.intro?.contains("Goal") == true)
    #expect(thumbnail.groups.count == 2)
    #expect(thumbnail.groups[0].title == "Velocity Ridge 3.0")
    #expect(thumbnail.groups[0].referenceTitle?.contains("DOES IT FINALLY MAKE SENSE?") == true)
    #expect(thumbnail.groups[0].concepts.count == 3)
    #expect(thumbnail.groups[0].concepts[0].label == "A")
    #expect(thumbnail.groups[0].concepts[0].text == "FINALLY?")
    #expect(thumbnail.groups[0].concepts[0].recommended)
    #expect(thumbnail.groups[0].concepts[0].idea?.isEmpty == false)
    #expect(thumbnail.groups[0].concepts[0].composition.count == 5)
    #expect(thumbnail.groups[0].concepts[0].whyItWorks?.isEmpty == false)
    #expect(thumbnail.groups[0].abTestItems.count == 2)
    #expect(thumbnail.groups[0].abTestNote?.contains("Avoid") == true)
    #expect(thumbnail.groups[1].concepts.count == 3)
    #expect(thumbnail.sharedRulesHeading == "Jerarquía visual común")
    #expect(thumbnail.sharedRules.count == 5)
    #expect(result.warnings.isEmpty)
}

@Test func thumbnailConceptsKeepTheirText() throws {
    let markdown = try MarkdownFixture.text("thumbnail-concepts")
    let exported = EscaletaExporter.markdown(from: EscaletaParser.parse(markdown).document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

// MARK: - Edge cases

@Test func noTimestampsFallsBackToTheOutline() throws {
    let markdown = try MarkdownFixture.text("edge-no-timestamps")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .escaleta)
    #expect(document.scriptHeading == nil)
    #expect(document.outline.count == 3)
    #expect(document.scenes.count == 3)
    #expect(document.scenes.allSatisfy { $0.isOutlineFallback })
    #expect(document.scenes.allSatisfy { $0.startSeconds == nil })
    #expect(document.scenes.map(\.title) == document.outline.map(\.text))
    #expect(result.warnings.contains { $0.kind == .outlineFallback })

    let exported = EscaletaExporter.markdown(from: document)
    #expect(!exported.contains("## 0:00"))
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

@Test func inlineCuesUnknownCuesAndUnknownH2ArePreserved() throws {
    let markdown = try MarkdownFixture.text("edge-inline-unknown")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.scenes.count == 3)
    #expect(document.scenes.map(\.timestampText) == ["0:00", "0:30", "1:02:03"])
    #expect(document.scenes.map(\.startSeconds) == [0, 30, 3723])
    #expect(document.scenes[0].separator == "-")
    #expect(document.scenes[1].separator == "–")
    #expect(document.scenes[2].separator == "—")

    let inlineCue = try #require(document.scenes[0].cues.first)
    #expect(inlineCue.kind == .unknown)
    #expect(inlineCue.payload == "unknown prefix")
    #expect(document.scenes[0].notes.count == 1)
    #expect(document.scenes[0].bodyParagraphs.contains { $0.contains("[IMAGEN: something]") })
    #expect(document.thesis == "")

    #expect(document.unparsedSections.count == 1)
    #expect(document.unparsedSections[0].heading == "Strange section")
    #expect(document.unparsedSections[0].level == 2)
    #expect(document.unparsedSections[0].placement == .document)
    #expect(document.unparsedSections[0].body.contains("Content preserved"))

    #expect(document.comparisonTables.count == 1)
    #expect(document.comparisonTables[0].sceneIndex == 2)
    #expect(document.comparisonTables[0].header == ["Left", "Right"])
    #expect(document.comparisonTables[0].rows == [["1", "2"]])

    let pack = try #require(document.publishing)
    #expect(pack.description == "Description only, with no main title.")
    #expect(result.warnings.contains { $0.kind == .inlineCue })
    #expect(result.warnings.contains { $0.kind == .unknownCue })
    #expect(result.warnings.contains { $0.kind == .seoMissingTitle })
    #expect(result.warnings.first { $0.kind == .inlineCue }?.line != nil)
    #expect(result.warnings.first { $0.kind == .unknownCue }?.line != nil)

    let exported = EscaletaExporter.markdown(from: document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

@Test func emptySectionsAreReportedButNeverDropped() throws {
    let markdown = try MarkdownFixture.text("edge-empty-sections")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.scenes.isEmpty)
    #expect(document.promise == "")
    #expect(document.thesis == "")
    #expect(document.outlineHeading == "Escaleta")
    #expect(document.outline.isEmpty)
    #expect(document.scriptHeading == "Guion completo")
    #expect(document.verifyHeading == "Verificar antes de grabar")
    #expect(document.verificationItems.isEmpty)
    #expect(document.seoHeading == "Paquete SEO")
    #expect(document.sourcesHeading == "Fuentes principales")
    #expect(document.sourcesPlacement == .seoSection)
    #expect(document.sources.isEmpty)

    let pack = try #require(document.publishing)
    #expect(pack.fieldOrder == [.primaryTitle, .description])
    #expect(pack.primaryTitle == nil)
    #expect(pack.description == nil)
    #expect(result.warnings.contains { $0.kind == .noScenes })
    #expect(result.warnings.filter { $0.kind == .emptySection }.count >= 5)

    let exported = EscaletaExporter.markdown(from: document)
    #expect(exported.contains("## Título recomendado"))
    #expect(exported.contains("## Descripción"))
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

@Test func researchDossierKeepsAllGroups() throws {
    let markdown = try MarkdownFixture.text("edge-dossier")
    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.kind == .researchDossier)
    #expect(document.scenes.isEmpty)
    #expect(document.unparsedSections.count == 3)
    #expect(document.unparsedSections.map(\.level) == [1, 1, 1])
    #expect(document.unparsedSections[0].heading.contains("1. TUNDRA ENGINE"))
    #expect(document.unparsedSections[0].body.contains("## Confirmed facts"))
    #expect(document.unparsedSections[0].body.contains("https://example.com/tundra-official"))
    #expect(result.warnings.contains { $0.kind == .unknownSection })
    #expect(result.warnings.contains { $0.kind == .noScenes })

    let exported = EscaletaExporter.markdown(from: document)
    #expect(canonicalWhitespace(exported) == canonicalWhitespace(markdown))
}

@Test func bomAndCRLFAreNormalizedBeforeParsing() throws {
    let base = try MarkdownFixture.text("ac-evo-style")
    let modified = "\u{FEFF}" + base.replacingOccurrences(of: "\n", with: "\r\n")

    let fromBase = EscaletaParser.parse(base).document
    let fromModified = EscaletaParser.parse(modified).document

    #expect(fromBase == fromModified)
    #expect(fromModified.scenes.count == 9)
    #expect(fromModified.title.hasPrefix("VELOCITY RIDGE"))
}

@Test func descendingTimestampsAndEmptySceneTitlesAreWarnings() throws {
    let markdown = """
    # DOCUMENTO DE AVISOS

    # Guion completo

    ## 1:00 — Primera

    Texto.

    ## 0:30 — Segunda

    Texto.

    ## 0:40 —

    Texto.
    """

    let result = EscaletaParser.parse(markdown)
    #expect(result.warnings.contains { $0.kind == .descendingTimestamp })
    #expect(result.warnings.contains { $0.kind == .emptySceneTitle })
    #expect(result.document.scenes.count == 2)
}

@Test func cueKindMappingFollowsSection34() {
    let cases: [(String, EscaletaCueKind)] = [
        ("IMAGEN", .image),
        ("B-ROLL", .bRoll),
        ("CAPTURA", .capture),
        ("PRUEBA", .test),
        ("PRUEBA EN PANTALLA", .testOnScreen),
        ("PRUEBA PROPUESTA", .proposedTest),
        ("GRABAR", .record),
        ("COMPARATIVA", .comparison),
        ("RÓTULO", .lowerThird),
        ("GRÁFICA", .graphic),
        ("TABLA EN PANTALLA", .screenTable),
        ("NOTA DE GRABACIÓN", .recordingNote),
        ("RE-HOOK", .rehook),
        ("MOOD", .unknown),
    ]

    for (label, expected) in cases {
        #expect(EscaletaCueKind(label: label) == expected, "Cue \(label)")
    }

    #expect(EscaletaCueKind(label: "PRUEBA DE SONIDO") == .test)
    #expect(EscaletaCueKind(label: "prueba") == .test)
    #expect(EscaletaCueKind.image.isBRoll)
    #expect(EscaletaCueKind.proposedTest.needsRecording)
    #expect(!EscaletaCueKind.rehook.isBRoll)
    #expect(!EscaletaCueKind.recordingNote.isBRoll)
}

@Test func aliasesFromSection35AreRecognised() throws {
    let markdown = """
    # DOCUMENTO DE ALIAS

    ## Promesa

    Promesa de prueba.

    ## Idea central

    Tesis de prueba.

    ## Verificar antes de grabar

    - Comprobar el dato principal.

    # Guion

    ## 0:00 — Uno

    Texto.

    # Paquete SEO

    ## Título principal

    TÍTULO DE PRUEBA

    ## Títulos

    1. Variante uno
    2. Variante dos

    ## Descripción (borrador)

    Descripción de prueba.

    ## Etiquetas

    uno, dos, Uno

    ## Fuentes oficiales y referencias

    - [Documento](https://example.com/documento)
    """

    let result = EscaletaParser.parse(markdown)
    let document = result.document

    #expect(document.promise == "Promesa de prueba.")
    #expect(document.thesis == "Tesis de prueba.")
    #expect(document.verifyHeading == "Verificar antes de grabar")
    #expect(document.verificationItems.count == 1)

    let pack = try #require(document.publishing)
    #expect(pack.primaryTitle == "TÍTULO DE PRUEBA")
    #expect(pack.titleCandidates == ["Variante uno", "Variante dos"])
    #expect(pack.description == "Descripción de prueba.")
    #expect(pack.tags == ["uno", "dos"])
    #expect(document.sources.count == 1)
    #expect(document.sources.first?.links.first?.url == "https://example.com/documento")
    #expect(result.warnings.contains { $0.kind == .duplicateTag })
}

@Test func thumbnailTextLongerThanThreeWordsWarns() {
    let markdown = """
    # Conceptos de miniatura — Juego de prueba

    # Juego de prueba

    ## Concepto A — ESTE TEXTO TIENE DEMASIADAS PALABRAS — Recomendado

    **Idea:** una idea.

    - Un elemento.

    **Por qué funciona:** porque sí.
    """

    let result = EscaletaParser.parse(markdown)
    #expect(result.document.kind == .thumbnailConcepts)
    #expect(result.warnings.contains { $0.kind == .thumbnailTextLength })
}

@Test(arguments: MarkdownFixture.allNames)
func allFixturesRoundTripStructurally(_ name: String) throws {
    let markdown = try MarkdownFixture.text(name)
    let first = EscaletaParser.parse(markdown)
    let exported = EscaletaExporter.markdown(from: first.document)
    let second = EscaletaParser.parse(exported)

    #expect(first.document == second.document, "Round-trip estructural: \(name)")
}

@Test(arguments: MarkdownFixture.canonicalNames)
func allFixturesKeepTheirText(_ name: String) throws {
    let markdown = try MarkdownFixture.text(name)
    let exported = EscaletaExporter.markdown(from: EscaletaParser.parse(markdown).document)
    #expect(
        canonicalWhitespace(exported) == canonicalWhitespace(markdown),
        "Texto canónico: \(name)"
    )
}
