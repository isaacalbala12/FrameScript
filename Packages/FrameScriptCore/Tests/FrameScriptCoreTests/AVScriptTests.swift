import Foundation
import Testing
@testable import FrameScriptCore

@Suite("AV script")
struct AVScriptTests {
    private let sceneID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: Paragraph splitting

    @Test("paragraph ranges are exact UTF-16 substrings across CRLF and emoji")
    func paragraphRanges() {
        let text = "Uno\r\n\r\nDos con emoji 🎬\r\n\r\n\r\nTres"
        let paragraphs = AVScriptBuilder.paragraphs(in: text, sceneID: sceneID)

        #expect(paragraphs.map(\.text) == ["Uno", "Dos con emoji 🎬", "Tres"])
        #expect(paragraphs.map(\.index) == [0, 1, 2])
        for paragraph in paragraphs {
            #expect((text as NSString).substring(with: paragraph.range.nsRange) == paragraph.text)
        }
    }

    @Test("blank-only scripts produce no rows")
    func blankScript() {
        #expect(AVScriptBuilder.paragraphs(in: "  \n\n\t\n", sceneID: sceneID).isEmpty)
        #expect(AVScriptBuilder.paragraphs(in: "", sceneID: sceneID).isEmpty)

        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(id: sceneID, title: "Vacía", scriptText: "\n\n")
        )
        #expect(scene.rows.isEmpty)
    }

    @Test("a single line break stays inside one paragraph")
    func singleLineBreakIsOneParagraph() {
        let paragraphs = AVScriptBuilder.paragraphs(in: "Línea uno\nLínea dos\n\nSiguiente", sceneID: sceneID)
        #expect(paragraphs.map(\.text) == ["Línea uno\nLínea dos", "Siguiente"])
    }

    // MARK: Alignment

    @Test("annotations align with the paragraph that contains their anchor")
    func annotationsAlign() throws {
        let text = "Primer párrafo.\n\nSegundo párrafo."
        let secondRange = (text as NSString).range(of: "Segundo párrafo.")
        let firstRange = (text as NSString).range(of: "Primer párrafo.")
        let secondAnchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: secondRange))
        let firstAnchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: firstRange))

        let visualID = UUID()
        let editingID = UUID()
        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: sceneID,
                title: "Escena",
                scriptText: text,
                annotations: [
                    AVScriptAnnotationInput(
                        id: visualID,
                        kind: .bRoll,
                        text: "Plano de recurso",
                        source: "Stock footage",
                        status: "Idea",
                        anchor: secondAnchor
                    ),
                    AVScriptAnnotationInput(
                        id: editingID,
                        kind: .editing,
                        text: "Corte seco",
                        status: "Pendiente",
                        anchor: firstAnchor
                    ),
                ]
            )
        )

        #expect(scene.rows.count == 2)
        #expect(scene.rows[0].paragraph?.text == "Primer párrafo.")
        #expect(scene.rows[0].annotations.map(\.id) == [editingID])
        #expect(scene.rows[1].paragraph?.text == "Segundo párrafo.")
        #expect(scene.rows[1].annotations.map(\.id) == [visualID])
        #expect(scene.rows.allSatisfy { !$0.isUnanchored })
    }

    @Test("a deleted paragraph keeps its items in the unanchored group")
    func deletedParagraphIsUnanchored() throws {
        let original = "Uno queda.\n\nDos desaparece."
        let removedRange = (original as NSString).range(of: "Dos desaparece.")
        let anchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: original, range: removedRange))
        let itemID = UUID()

        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: sceneID,
                title: "Escena",
                scriptText: "Uno queda.",
                annotations: [
                    AVScriptAnnotationInput(
                        id: itemID,
                        kind: .bRoll,
                        text: "Plano perdido",
                        anchor: anchor
                    ),
                ]
            )
        )

        #expect(scene.rows.count == 2)
        #expect(scene.rows[0].paragraph?.text == "Uno queda.")
        let unanchored = try #require(scene.rows.last)
        #expect(unanchored.isUnanchored)
        #expect(unanchored.annotations.map(\.id) == [itemID])
        #expect(unanchored.annotations.first?.anchorExcerpt == "Dos desaparece.")
    }

    @Test("an anchor that points at a blank separator is unanchored, never dropped")
    func separatorAnchorIsUnanchored() throws {
        let text = "Uno\n\nDos"
        let separatorRange = NSRange(location: 3, length: 2)
        let anchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: separatorRange))
        let itemID = UUID()

        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: sceneID,
                title: "Escena",
                scriptText: text,
                annotations: [
                    AVScriptAnnotationInput(id: itemID, kind: .editing, text: "Nota", anchor: anchor),
                ]
            )
        )

        let unanchored = try #require(scene.rows.last)
        #expect(unanchored.isUnanchored)
        #expect(unanchored.annotations.map(\.id) == [itemID])
    }

    @Test("every input annotation appears exactly once even when anchors are stale")
    func annotationsAreNeverLost() throws {
        let text = "Uno\n\nDos"
        let validRange = (text as NSString).range(of: "Dos")
        let validAnchor = try #require(FrameScriptDocument.TextAnchorRepair.anchor(in: text, range: validRange))
        let staleAnchor = FrameScriptDocument.TextAnchor(
            startUTF16: 99,
            lengthUTF16: 4,
            selectedText: "Nada"
        )
        let ids = [UUID(), UUID(), UUID(), UUID()]

        let scene = AVScriptBuilder.scene(
            AVScriptSceneInput(
                id: sceneID,
                title: "Escena",
                scriptText: text,
                annotations: [
                    AVScriptAnnotationInput(id: ids[0], kind: .bRoll, text: "A", anchor: validAnchor),
                    AVScriptAnnotationInput(id: ids[1], kind: .bRoll, text: "B", anchor: nil),
                    AVScriptAnnotationInput(id: ids[2], kind: .editing, text: "C", anchor: staleAnchor),
                    AVScriptAnnotationInput(id: ids[3], kind: .editing, text: "D", anchor: validAnchor),
                ]
            )
        )

        let outputIDs = scene.rows.flatMap(\.annotations).map(\.id)
        #expect(Set(outputIDs) == Set(ids))
        #expect(outputIDs.count == ids.count)
        #expect(scene.rows.first(where: { $0.isUnanchored })?.annotations.count == 2)
    }

    // MARK: Exports

    @Test("golden Markdown two-column table")
    func markdownGolden() throws {
        let text = "Uno con *énfasis*.\n\nDos | con tubería."
        let firstAnchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: text,
                range: (text as NSString).range(of: "Uno con *énfasis*.")
            )
        )
        let secondAnchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: text,
                range: (text as NSString).range(of: "Dos | con tubería.")
            )
        )
        let document = AVScriptBuilder.document(
            title: "Demo",
            scenes: [
                AVScriptSceneInput(
                    id: sceneID,
                    title: "Gancho",
                    scriptText: text,
                    annotations: [
                        AVScriptAnnotationInput(
                            id: UUID(),
                            kind: .bRoll,
                            text: "Plano de recurso",
                            source: "Stock footage",
                            status: "Idea",
                            anchor: firstAnchor
                        ),
                        AVScriptAnnotationInput(
                            id: UUID(),
                            kind: .editing,
                            text: "Corte seco",
                            status: "Pendiente",
                            anchor: secondAnchor
                        ),
                    ]
                ),
                AVScriptSceneInput(
                    id: UUID(),
                    title: "Cierre",
                    scriptText: "Final."
                ),
            ]
        )

        let markdown = AVScriptExporter.markdown(document: document)

        #expect(markdown == """
        # Guion AV — Demo

        | Narración | Visuales y montaje |
        | --- | --- |
        | **Escena 01 — Gancho** | |
        | Uno con *énfasis*. | **Visual** — Plano de recurso · Fuente: Stock footage · Estado: Idea |
        | Dos \\| con tubería. | **Montaje** — Corte seco · Estado: Pendiente |
        | **Escena 02 — Cierre** | |
        | Final. | |

        """)
    }

    @Test("golden CSV keeps one row per paragraph or annotation")
    func csvGolden() throws {
        let text = "Uno con *énfasis*.\n\nDos | con tubería."
        let firstAnchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: text,
                range: (text as NSString).range(of: "Uno con *énfasis*.")
            )
        )
        let secondAnchor = try #require(
            FrameScriptDocument.TextAnchorRepair.anchor(
                in: text,
                range: (text as NSString).range(of: "Dos | con tubería.")
            )
        )
        let document = AVScriptBuilder.document(
            title: "Demo",
            scenes: [
                AVScriptSceneInput(
                    id: sceneID,
                    title: "Gancho",
                    scriptText: text,
                    annotations: [
                        AVScriptAnnotationInput(
                            id: UUID(),
                            kind: .bRoll,
                            text: "Plano de recurso",
                            source: "Stock footage",
                            status: "Idea",
                            anchor: firstAnchor
                        ),
                        AVScriptAnnotationInput(
                            id: UUID(),
                            kind: .editing,
                            text: "Corte seco",
                            status: "Pendiente",
                            anchor: secondAnchor
                        ),
                    ]
                ),
                AVScriptSceneInput(
                    id: UUID(),
                    title: "Cierre",
                    scriptText: "Final."
                ),
            ]
        )

        let csv = AVScriptExporter.csv(document: document)

        #expect(csv == "Escena,Parrafo,Narracion,Tipo,Descripcion,Fuente,Estado,Anclaje\r\n"
            + "Gancho,1,Uno con *énfasis*.,Visual,Plano de recurso,Stock footage,Idea,\r\n"
            + "Gancho,2,Dos | con tubería.,Montaje,Corte seco,,Pendiente,\r\n"
            + "Cierre,1,Final.,,,,,\r\n")
    }

    @Test("unanchored items keep their old excerpt in both exports")
    func unanchoredExports() {
        let document = AVScriptBuilder.document(
            title: "Demo",
            scenes: [
                AVScriptSceneInput(
                    id: sceneID,
                    title: "Escena",
                    scriptText: "Texto actual.",
                    annotations: [
                        AVScriptAnnotationInput(
                            id: UUID(),
                            kind: .bRoll,
                            text: "Plano antiguo",
                            source: "Stock footage",
                            status: "Idea",
                            anchor: FrameScriptDocument.TextAnchor(
                                startUTF16: 50,
                                lengthUTF16: 6,
                                selectedText: "Antiguo"
                            )
                        ),
                    ]
                ),
            ]
        )

        let markdown = AVScriptExporter.markdown(document: document)
        #expect(markdown.contains("*Sin anclar*"))
        #expect(markdown.contains("«Antiguo»"))

        let csv = AVScriptExporter.csv(document: document)
        #expect(csv.contains(",sin anclar: Antiguo\r\n"))
    }

    @Test("empty projects export a clear, valid table")
    func emptyExport() {
        let document = emptyDocument()
        #expect(AVScriptExporter.markdown(document: document) == """
        # Guion AV — Vacío

        | Narración | Visuales y montaje |
        | --- | --- |
        | Sin escenas. | |

        """)
        #expect(AVScriptExporter.csv(document: document) == "Escena,Parrafo,Narracion,Tipo,Descripcion,Fuente,Estado,Anclaje\r\n")
    }

    @Test("CSV quotes commas, quotes and line breaks")
    func csvEscaping() {
        let document = AVScriptBuilder.document(
            title: "Demo",
            scenes: [
                AVScriptSceneInput(
                    id: sceneID,
                    title: "Gancho, con coma",
                    scriptText: "Uno\nDos"
                ),
            ]
        )

        let csv = AVScriptExporter.csv(document: document)
        #expect(csv.contains("\"Gancho, con coma\",1,\"Uno\nDos\","))
    }

    @Test("labels can be localized without changing the table shape")
    func localizedLabels() {
        let document = AVScriptBuilder.document(
            title: "Demo",
            scenes: [AVScriptSceneInput(id: sceneID, title: "Hook", scriptText: "Hello.")]
        )
        let labels = AVScriptExportLabels(
            documentTitle: "AV script",
            narration: "Narration",
            annotations: "Visuals and editing",
            scene: "Scene",
            unanchored: "Unanchored",
            empty: "No scenes.",
            notAnchored: "unanchored",
            csvScene: "Scene",
            csvParagraph: "Paragraph",
            csvNarration: "Narration",
            csvType: "Type",
            csvDescription: "Description",
            csvSource: "Source",
            csvStatus: "Status",
            csvAnchor: "Anchor"
        )

        let markdown = AVScriptExporter.markdown(document: document, labels: labels)
        #expect(markdown.contains("# AV script — Demo"))
        #expect(markdown.contains("| Narration | Visuals and editing |"))
        #expect(markdown.contains("**Scene 01 — Hook**"))

        let csv = AVScriptExporter.csv(document: document, labels: labels)
        #expect(csv.hasPrefix("Scene,Paragraph,Narration,Type,Description,Source,Status,Anchor\r\n"))
        #expect(csv.contains("Hook,1,Hello.,,,,,\r\n"))
    }

    // MARK: Performance shape

    @Test("forty scenes with a large script build one row per paragraph")
    func largeProjectBuilds() {
        let wordBag = Array(repeating: "palabra", count: 500).joined(separator: " ")
        let scenes = (0..<40).map { index in
            AVScriptSceneInput(
                id: UUID(),
                title: "Escena \(index)",
                scriptText: "\(wordBag).\n\n\(wordBag)."
            )
        }

        let document = AVScriptBuilder.document(title: "Grande", scenes: scenes)
        #expect(document.scenes.count == 40)
        #expect(document.scenes.allSatisfy { $0.rows.count == 2 })
    }

    private func emptyDocument() -> AVScriptDocument {
        AVScriptDocument(title: "Vacío", scenes: [])
    }
}
