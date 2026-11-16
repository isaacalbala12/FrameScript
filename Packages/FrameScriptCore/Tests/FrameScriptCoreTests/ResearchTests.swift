import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Research logic")
struct ResearchTests {
    // MARK: - Fixtures

    private func scene(
        id: UUID = UUID(),
        order: Int = 0,
        title: String = "Escena",
        text: String = "alpha beta gamma delta",
        bRoll: [FrameScriptDocument.BRollItem] = []
    ) -> FrameScriptDocument.Scene {
        FrameScriptDocument.Scene(
            id: id,
            order: order,
            sectionType: .custom,
            title: title,
            scriptText: text,
            bRollItems: bRoll
        )
    }

    private func source(
        id: UUID = UUID(),
        title: String = "Fuente",
        url: String = "https://example.com/source",
        kind: FrameScriptDocument.SourceKind = .official,
        reliability: FrameScriptDocument.SourceReliability = .high,
        date: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        note: String = ""
    ) -> FrameScriptDocument.Source {
        FrameScriptDocument.Source(
            id: id,
            title: title,
            url: url,
            kind: kind,
            reliability: reliability,
            date: date,
            note: note
        )
    }

    private func claim(
        id: UUID = UUID(),
        text: String,
        status: FrameScriptDocument.ClaimStatus = .probable,
        sourceIDs: [UUID] = [],
        sceneIDs: [UUID] = [],
        needsVerification: Bool = false,
        personalExperience: Bool = false,
        resolutionNote: String = "",
        anchor: FrameScriptDocument.TextAnchor? = nil,
        anchorSceneID: UUID? = nil
    ) -> FrameScriptDocument.Claim {
        FrameScriptDocument.Claim(
            id: id,
            text: text,
            status: status,
            sourceIDs: sourceIDs,
            sceneIDs: sceneIDs,
            anchorSceneID: anchorSceneID,
            anchor: anchor,
            needsVerification: needsVerification,
            personalExperience: personalExperience,
            resolutionNote: resolutionNote
        )
    }

    private func project(
        scenes: [FrameScriptDocument.Scene],
        sources: [FrameScriptDocument.Source] = [],
        claims: [FrameScriptDocument.Claim] = [],
        tasks: [FrameScriptDocument.ChecklistTask] = [],
        tables: [FrameScriptDocument.ComparisonTable] = []
    ) -> FrameScriptDocument.Project {
        FrameScriptDocument.Project(
            title: "Proyecto",
            scenes: scenes,
            checklistTasks: tasks,
            sources: sources,
            claims: claims,
            comparisonTables: tables
        )
    }

    // MARK: - Summary

    @Test("Counters separate statuses from the pending flag")
    func countersSeparateStatusesFromPending() {
        let claims = [
            claim(text: "A", status: .confirmed),
            claim(text: "B", status: .probable, needsVerification: true),
            claim(text: "C", status: .probable, needsVerification: true),
            claim(text: "D", status: .rumor, needsVerification: true),
            claim(text: "E", status: .communityOpinion),
            claim(text: "F", status: .confirmed, needsVerification: true),
            claim(text: "G", status: .probable, needsVerification: true, personalExperience: true)
        ]

        let counts = ResearchSummary.counts(claims: claims)

        #expect(counts.confirmed == 2)
        #expect(counts.probable == 3)
        #expect(counts.rumor == 1)
        #expect(counts.communityOpinion == 1)
        #expect(counts.pending == 4)
        #expect(counts.total == 7)
        #expect(counts.count(for: .rumor) == 1)
        #expect(counts.statusParts.map(\.status) == [.confirmed, .probable, .rumor, .communityOpinion])
    }

    @Test("Scene badges count only unconfirmed claims linked to the scene")
    func sceneBadgesCountUnconfirmedClaims() {
        let first = UUID()
        let second = UUID()
        let claims = [
            claim(text: "A", status: .probable, sceneIDs: [first]),
            claim(text: "B", status: .rumor, sceneIDs: [first, second]),
            claim(text: "C", status: .confirmed, sceneIDs: [first]),
            claim(text: "D", status: .communityOpinion, sceneIDs: [second])
        ]

        let counts = ResearchSummary.unconfirmedCountsByScene(claims: claims)

        #expect(counts[first] == 2)
        #expect(counts[second] == 2)
        #expect(ResearchSummary.unconfirmedCount(sceneID: first, claims: claims) == 2)
        #expect(ResearchSummary.unconfirmedCount(sceneID: UUID(), claims: claims) == 0)
    }

    @Test("Filters combine status, scene, pending flag and search")
    func filtersCombine() {
        let sceneID = UUID()
        let otherScene = UUID()
        let claims = [
            claim(text: "El récord es 1:42.3", status: .confirmed, sceneIDs: [sceneID]),
            claim(text: "El neumático blando dura menos", status: .probable, sceneIDs: [sceneID], needsVerification: true),
            claim(text: "Dicen en el foro que llueve", status: .communityOpinion, sceneIDs: [otherScene])
        ]

        let probable = ResearchFilter(statuses: [.probable])
        #expect(probable.apply(to: claims).map(\.text) == ["El neumático blando dura menos"])

        let pendingInScene = ResearchFilter(sceneID: sceneID, onlyPending: true)
        #expect(pendingInScene.apply(to: claims).count == 1)

        let diacriticSearch = ResearchFilter(searchText: "record")
        #expect(diacriticSearch.apply(to: claims).map(\.text) == ["El récord es 1:42.3"])

        let other = ResearchFilter(sceneID: otherScene)
        #expect(other.apply(to: claims).count == 1)
    }

    @Test("Pending list joins scene and source titles in stored order")
    func pendingListJoinsTitles() {
        let sceneID = UUID()
        let sourceID = UUID()
        let project = project(
            scenes: [scene(id: sceneID, title: "Vuelta rápida")],
            sources: [source(id: sourceID, title: "Timing oficial")],
            claims: [
                claim(text: "Pendiente", sourceIDs: [sourceID], sceneIDs: [sceneID], needsVerification: true),
                claim(text: "Resuelta", sceneIDs: [sceneID], needsVerification: false)
            ]
        )

        let items = ResearchSummary.pendingItems(project: project)

        #expect(items.count == 1)
        #expect(items[0].sceneTitles == ["Vuelta rápida"])
        #expect(items[0].sourceTitles == ["Timing oficial"])
        #expect(items[0].claimID == project.claims[0].id)
    }

    @Test("Source usage counts each claim once per source")
    func sourceUsageCountsClaims() {
        let first = UUID()
        let second = UUID()
        let claims = [
            claim(text: "A", sourceIDs: [first, second]),
            claim(text: "B", sourceIDs: [first, first]),
            claim(text: "C")
        ]

        let usage = ResearchSummary.sourceUsage(claims: claims)

        #expect(usage[first] == 2)
        #expect(usage[second] == 1)
        #expect(usage.count == 2)
    }

    // MARK: - Checklist

    @Test("Merging pending claims adds research tasks without duplicating them")
    func mergingPendingClaims() {
        let sceneID = UUID()
        let existing = [
            FrameScriptDocument.ChecklistTask(text: "Comprar tarjeta", kind: .acquire),
            FrameScriptDocument.ChecklistTask(text: "El récord es 1:42.3", kind: .research, isDone: true)
        ]
        let claims = [
            claim(text: "El récord es 1:42.3", sceneIDs: [sceneID], needsVerification: true),
            claim(text: "  El récord es   1:42.3 ", needsVerification: true),
            claim(text: "Neumático nuevo", sceneIDs: [sceneID], needsVerification: true),
            claim(text: "Experiencia propia", needsVerification: true, personalExperience: true)
        ]

        let result = ResearchChecklist.mergingPendingClaims(claims, into: existing)

        #expect(result.count == 3)
        #expect(result.map(\.text) == ["Comprar tarjeta", "El récord es 1:42.3", "Neumático nuevo"])
        #expect(result[1].isDone)
        #expect(result[2].kind == .research)
        #expect(result[2].sceneID == sceneID)
    }

    @Test("Resolving a claim marks only the matching research task done")
    func resolvingClaimMarksTask() {
        let tasks = [
            FrameScriptDocument.ChecklistTask(text: "El récord es 1:42.3", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "Otra tarea", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "El récord es 1:42.3", kind: .other)
        ]

        let result = ResearchChecklist.markingResolved(claimText: "el record es 1:42.3", in: tasks)

        #expect(result[0].isDone)
        #expect(!result[1].isDone)
        #expect(!result[2].isDone)
    }

    @Test("Renaming a claim keeps its research task in sync")
    func renamingClaimUpdatesTask() {
        let sceneID = UUID()
        let tasks = [
            FrameScriptDocument.ChecklistTask(text: "El parche sale en mayo", kind: .research),
            FrameScriptDocument.ChecklistTask(text: "Otra tarea", kind: .research)
        ]

        let result = ResearchChecklist.renaming(
            claimText: "el parche sale en mayo",
            to: "El parche sale en junio",
            sceneID: sceneID,
            in: tasks
        )

        #expect(result[0].text == "El parche sale en junio")
        #expect(result[0].sceneID == sceneID)
        #expect(result[1].text == "Otra tarea")
    }

    // MARK: - Anchoring and links

    @Test("Anchoring finds a fragment and stores its context")
    func anchoringFindsFragment() {
        let text = "Antes del dato. El récord es 1:42.3. Después del dato."
        let anchor = ResearchAnchoring.anchor(for: "récord es 1:42.3", in: text)

        #expect(anchor != nil)
        #expect(anchor?.selectedText == "récord es 1:42.3")
        #expect(anchor?.prefixContext.hasSuffix("El ") == true)
        #expect(anchor?.suffixContext.hasPrefix(". Después") == true)
    }

    @Test("Anchoring falls back to a case- and accent-insensitive match")
    func anchoringFallsBack() {
        let text = "El récord absoluto está aquí."
        let anchor = ResearchAnchoring.anchor(for: "RECORD ABSOLUTO", in: text)

        #expect(anchor?.selectedText == "récord absoluto")
    }

    @Test("Anchoring returns nil for empty or missing fragments")
    func anchoringRejectsMissing() {
        #expect(ResearchAnchoring.anchor(for: "   ", in: "texto") == nil)
        #expect(ResearchAnchoring.anchor(for: "no existe", in: "texto") == nil)
    }

    @Test("Only http and https links are openable")
    func onlyWebLinksOpen() {
        #expect(ResearchLinks.validURL(from: "https://example.com/a") != nil)
        #expect(ResearchLinks.validURL(from: "http://example.com") != nil)
        #expect(ResearchLinks.validURL(from: "file:///etc/passwd") == nil)
        #expect(ResearchLinks.validURL(from: "javascript:alert(1)") == nil)
        #expect(ResearchLinks.validURL(from: "example.com") == nil)
        #expect(ResearchLinks.displayHost(from: "https://WWW.Example.com/a") == "www.example.com")
    }

    // MARK: - Comparison tables

    @Test("Grid operations add and remove rows and columns safely")
    func gridOperations() {
        let table = FrameScriptDocument.ComparisonTable(
            title: "Neumáticos",
            header: ["Compuesto", "Tiempo"],
            rows: [["Blando", "1:42.3"]]
        )

        let withRow = ComparisonTableEditing.addRow(table)
        #expect(withRow.rows.count == 2)
        #expect(withRow.rows[1] == ["", ""])

        let withColumn = ComparisonTableEditing.addColumn(withRow, title: "Duración")
        #expect(withColumn.header == ["Compuesto", "Tiempo", "Duración"])
        #expect(withColumn.rows.allSatisfy { $0.count == 3 })

        let removed = ComparisonTableEditing.removeColumn(withColumn, at: 1)
        #expect(removed.header == ["Compuesto", "Duración"])
        #expect(removed.rows[0].count == 2)

        #expect(ComparisonTableEditing.removeColumn(table, at: 99) == table)
        #expect(ComparisonTableEditing.removeRow(table, at: 99) == table)
        #expect(ComparisonTableEditing.setCell(table, row: 9, column: 9, value: "x") == table)
    }

    @Test("Normalization pads ragged rows and header to one width")
    func normalizationPadsRaggedRows() {
        let table = FrameScriptDocument.ComparisonTable(
            title: "Ragged",
            header: ["A"],
            rows: [["1", "2"], ["3"]]
        )

        let normalized = ComparisonTableEditing.normalized(table)

        #expect(normalized.header == ["A", ""])
        #expect(normalized.rows == [["1", "2"], ["3", ""]])
    }

    @Test("Validation reports ragged rows, empty cells and duplicate headers")
    func validationReportsProblems() {
        let table = FrameScriptDocument.ComparisonTable(
            title: "Problemas",
            header: ["A", "A", ""],
            rows: [["1"], ["", "2", "3"]]
        )

        let issues = ComparisonTableValidation.issues(in: table)

        #expect(issues.contains(.duplicateHeader(column: 1)))
        #expect(issues.contains(.emptyHeader(column: 2)))
        #expect(issues.contains(.raggedRow(row: 0, expected: 3, actual: 1)))
        #expect(issues.contains(.emptyCell(row: 1, column: 0)))
        #expect(ComparisonTableValidation.issues(in: FrameScriptDocument.ComparisonTable(title: "Vacía")).contains(.noColumns))
    }

    @Test("Paste parses a Markdown table and reports ragged rows")
    func pasteMarkdown() throws {
        let input = """
        | Compuesto | Tiempo | Nota |
        | --- | :---: | --- |
        | Blando | 1:42.3 |
        | Duro | 1:43.9 | estable |
        """

        let result = try ComparisonTablePaste.parse(input)

        #expect(result.format == .markdown)
        #expect(result.header == ["Compuesto", "Tiempo", "Nota"])
        #expect(result.rows.count == 2)
        #expect(result.rows[0] == ["Blando", "1:42.3", ""])
        #expect(result.issues.contains(.raggedRow(row: 0, expected: 3, actual: 2)))
        #expect(result.issues.contains(.emptyCell(row: 0, column: 2)))
    }

    @Test("Paste accepts Markdown without a separator and escaped pipes")
    func pasteMarkdownWithoutSeparator() throws {
        let input = "A | B\nuno \\| dos | tres"

        let result = try ComparisonTablePaste.parse(input)

        #expect(result.format == .markdown)
        #expect(result.header == ["A", "B"])
        #expect(result.rows == [["uno | dos", "tres"]])
    }

    @Test("Paste parses TSV")
    func pasteTSV() throws {
        let input = "A\tB\n1\t2\n3\t4"

        let result = try ComparisonTablePaste.parse(input)

        #expect(result.format == .tsv)
        #expect(result.header == ["A", "B"])
        #expect(result.rows == [["1", "2"], ["3", "4"]])
    }

    @Test("Paste parses CSV with quoted commas and quotes")
    func pasteCSV() throws {
        let input = "Nombre,Comentario\nBlando,\"Rápido, pero se degrada\"\nDuro,\"Dice \"\"hola\"\"\""

        let result = try ComparisonTablePaste.parse(input)

        #expect(result.format == .csv)
        #expect(result.header == ["Nombre", "Comentario"])
        #expect(result.rows[0] == ["Blando", "Rápido, pero se degrada"])
        #expect(result.rows[1] == ["Duro", "Dice \"hola\""])
    }

    @Test("Paste rejects empty and unsupported input")
    func pasteRejectsUnsupported() {
        #expect(throws: ComparisonTablePasteError.empty) {
            try ComparisonTablePaste.parse("   \n  ")
        }
        #expect(throws: ComparisonTablePasteError.unsupported) {
            try ComparisonTablePaste.parse("una línea suelta\notra línea")
        }
    }

    @Test("Markdown render escapes pipes and round-trips through the parser")
    func markdownRoundTrip() throws {
        let table = FrameScriptDocument.ComparisonTable(
            title: "Comparativa",
            header: ["A", "B"],
            rows: [["uno | dos", "tres"], ["cuatro", "cinco"]]
        )

        let markdown = ComparisonTableRender.markdown(table)
        #expect(markdown.contains("uno \\| dos"))

        let parsed = try ComparisonTablePaste.parse(markdown)
        #expect(parsed.header == ["A", "B"])
        #expect(parsed.rows == [["uno | dos", "tres"], ["cuatro", "cinco"]])
    }

    @Test("CSV render quotes commas and quotes")
    func csvRender() {
        let table = FrameScriptDocument.ComparisonTable(
            title: "CSV",
            header: ["A", "B"],
            rows: [["uno, dos", "comillas \"x\""]]
        )

        let csv = ComparisonTableRender.csv(table)

        #expect(csv == "A,B\n\"uno, dos\",\"comillas \"\"x\"\"\"")
    }

    // MARK: - AI suggestions

    @Test("Claim suggestions parse fenced JSON and never confirm a claim")
    func suggestionsNeverConfirm() {
        let response = """
        ```json
        {"claims":[
          {"text":"El récord es 1:42.3","status":"confirmed","reason":"Timing oficial"},
          {"text":"  El neumático blando dura menos  ","status":"probable"},
          {"text":"En el foro dicen que llueve","status":"opinión comunitaria"},
          {"text":"El récord es 1:42.3","status":"rumor"}
        ]}
        ```
        """

        let suggestions = ClaimSuggestionParser.parse(response)

        #expect(suggestions.count == 3)
        #expect(suggestions[0].status == .probable)
        #expect(suggestions[0].reason == "Timing oficial")
        #expect(suggestions[1].text == "El neumático blando dura menos")
        #expect(suggestions[2].status == .communityOpinion)
        #expect(suggestions.allSatisfy { $0.status != .confirmed })
    }

    @Test("Claim suggestions accept a bare array and downgrade speculative aliases")
    func suggestionsBareArray() {
        let response = #"[{"text":"Dato dudoso del parche","status":"especulativa"},{"text":"","status":"probable"}]"#
        let suggestions = ClaimSuggestionParser.parse(response)

        #expect(suggestions.count == 1)
        #expect(suggestions[0].status == .rumor)
    }

    @Test("Claim suggestions return nothing for garbage or short text")
    func suggestionsRejectGarbage() {
        #expect(ClaimSuggestionParser.parse("no soy json").isEmpty)
        #expect(ClaimSuggestionParser.parse(#"{"claims":[{"text":"corto"}]}"#).isEmpty)
    }

    // MARK: - Export

    @Test("Appendix includes sources, statuses, scenes and resolution notes")
    func appendixContent() {
        let sceneID = UUID()
        let sourceID = UUID()
        let project = project(
            scenes: [scene(id: sceneID, title: "Vuelta rápida")],
            sources: [source(id: sourceID, title: "Timing oficial", note: "Página de resultados.")],
            claims: [
                claim(
                    text: "El récord es 1:42.3",
                    status: .confirmed,
                    sourceIDs: [sourceID],
                    sceneIDs: [sceneID],
                    resolutionNote: "Confirmado con el PDF."
                ),
                claim(
                    text: "El parche sale en mayo",
                    status: .probable,
                    needsVerification: true
                )
            ]
        )

        let appendix = ResearchExport.markdownAppendix(project: project)
        let expectedDay = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        }()

        #expect(appendix.hasPrefix("## Fuentes y verificación"))
        #expect(appendix.contains("**Timing oficial** — oficial · fiabilidad alta · \(expectedDay) — https://example.com/source"))
        #expect(appendix.contains("Página de resultados."))
        #expect(appendix.contains("**Confirmada** — El récord es 1:42.3"))
        #expect(appendix.contains("Fuentes: Timing oficial · Escenas: Vuelta rápida"))
        #expect(appendix.contains("Nota: Confirmado con el PDF."))
        #expect(appendix.contains("pendiente de verificación"))
    }

    @Test("Empty research data produces no appendix or description block")
    func emptyAppendix() {
        let empty = project(scenes: [])
        #expect(ResearchExport.markdownAppendix(project: empty).isEmpty)
        #expect(ResearchExport.descriptionBlock(project: empty).isEmpty)
        #expect(ResearchExport.warnings(project: empty).isEmpty)
        #expect(ResearchExport.warningsMarkdown(project: empty).isEmpty)
    }

    @Test("Description block starts with a stable marker")
    func descriptionBlock() {
        let project = project(
            scenes: [],
            sources: [source(title: "Timing")],
            claims: [claim(text: "Dato", status: .probable, needsVerification: true)]
        )

        let block = ResearchExport.descriptionBlock(project: project)

        #expect(block.hasPrefix("Fuentes y verificación\n"))
        #expect(block.contains("- Timing — https://example.com/source"))
        #expect(block.contains("- [Probable] Dato (pendiente)"))
    }

    @Test("Warnings flag unconfirmed claims without a disclaimer cue")
    func exportWarnings() {
        let sceneID = UUID()
        let safeSceneID = UUID()
        let cueSceneID = UUID()
        let project = project(
            scenes: [
                scene(id: sceneID, order: 0, title: "Sin aviso"),
                scene(
                    id: cueSceneID,
                    order: 1,
                    title: "Con rótulo",
                    bRoll: [
                        FrameScriptDocument.BRollItem(
                            sourceType: .textOnScreen,
                            descriptionText: "RÓTULO EN PANTALLA: dato sin confirmar"
                        )
                    ]
                ),
                scene(id: safeSceneID, order: 2, title: "Confirmada")
            ],
            claims: [
                claim(text: "Dato sin confirmar", status: .probable, sceneIDs: [sceneID]),
                claim(text: "Dato con rótulo", status: .probable, sceneIDs: [cueSceneID]),
                claim(text: "Dato confirmado", status: .confirmed, sceneIDs: [safeSceneID]),
                claim(text: "Vivencia propia", status: .probable, sceneIDs: [sceneID], personalExperience: true)
            ]
        )

        let warnings = ResearchExport.warnings(project: project)

        #expect(warnings.count == 1)
        #expect(warnings[0].sceneTitle == "Sin aviso")
        #expect(warnings[0].claimText == "Dato sin confirmar")
        #expect(ResearchExport.warningsMarkdown(project: project).contains("sigue sin confirmar y no hay rótulo ni aviso"))
    }

    @Test("Disclaimer cue detection ignores case and accents")
    func disclaimerCueDetection() {
        let withCue = scene(text: "Texto normal. [Aviso legal: dato pendiente]")
        let withRotulo = scene(text: "Aquí va un ROTULO EN PANTALLA")
        let withoutCue = scene(text: "Texto normal sin nada")

        #expect(ResearchExport.hasDisclaimerCue(in: withCue))
        #expect(ResearchExport.hasDisclaimerCue(in: withRotulo))
        #expect(!ResearchExport.hasDisclaimerCue(in: withoutCue))
    }

    @Test("Spanish export labels match the panel vocabulary")
    func exportLabels() {
        #expect(ResearchExport.claimStatusLabel(.confirmed) == "Confirmada")
        #expect(ResearchExport.claimStatusLabel(.communityOpinion) == "Opinión comunitaria")
        #expect(ResearchExport.sourceKindLabel(.community) == "foro/comunidad")
        #expect(ResearchExport.reliabilityLabel(.low) == "baja")
    }

    // MARK: - Persistence

    @Test("New research fields survive a document encode and decode")
    func documentRoundTrip() throws {
        let sceneID = UUID()
        let sourceID = UUID()
        let anchor = FrameScriptDocument.TextAnchor(
            startUTF16: 0,
            lengthUTF16: 5,
            selectedText: "alpha"
        )
        let project = project(
            scenes: [scene(id: sceneID)],
            sources: [
                source(id: sourceID, kind: .video, reliability: .low, date: Date(timeIntervalSince1970: 1_700_000_000))
            ],
            claims: [
                claim(
                    text: "alpha",
                    status: .communityOpinion,
                    sourceIDs: [sourceID],
                    sceneIDs: [sceneID],
                    needsVerification: true,
                    resolutionNote: "Discutido en el foro",
                    anchor: anchor,
                    anchorSceneID: sceneID
                )
            ],
            tables: [
                FrameScriptDocument.ComparisonTable(
                    title: "Tabla",
                    header: ["A"],
                    rows: [["1"]],
                    sceneID: sceneID
                )
            ]
        )
        let document = FrameScriptDocument(project: project)

        let data = try FrameScriptDocumentCodec.encode(document)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        #expect(decoded.project.sources == project.sources)
        #expect(decoded.project.claims == project.claims)
        #expect(decoded.project.comparisonTables == project.comparisonTables)
        #expect(decoded.project.claims[0].needsVerification)
        #expect(decoded.project.claims[0].anchorSceneID == sceneID)
        #expect(decoded.project.claims[0].anchor?.selectedText == "alpha")
        #expect(decoded.project.comparisonTables[0].sceneID == sceneID)
    }
}
