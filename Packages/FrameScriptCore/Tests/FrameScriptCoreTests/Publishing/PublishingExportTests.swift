import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Publishing export")
struct PublishingExportTests {
    static func sampleInput() -> PublishingExportInput {
        PublishingExportInput(
            projectTitle: "Cómo elegir neumáticos para mojado",
            promise: "Elegir el neumático correcto sin gastar de más.",
            thesis: "La presión importa más que la marca.",
            title: "Neumáticos de lluvia: la presión que nadie mira",
            titleCandidates: [
                "Neumáticos de lluvia: la presión que nadie mira",
                "Probamos tres neumáticos de lluvia en el mismo circuito",
                "Qué neumático de lluvia comprar según tu ritmo",
            ],
            thumbnailNotes: """
            ### Concepto A — La presión manda
            Idea: Enfrentar dos ruedas idénticas con presiones distintas.
            Composición:
            - Rueda a la izquierda
            - Manómetro a la derecha
            Por qué funciona: El contraste se entiende en un segundo.

            ### Concepto B — Tres datos
            Idea: Mostrar los tres números de la prueba.
            Por qué funciona: Es legible a tamaño móvil.
            """,
            description: "Comparamos tres neumáticos de lluvia con telemetría real. Al final tienes una recomendación concreta para tu coche y tu ritmo.",
            chapters: [
                EscaletaChapter(seconds: 0, timestamp: "0:00", title: "Gancho"),
                EscaletaChapter(seconds: 45, timestamp: "0:45", title: "Qué cambia"),
                EscaletaChapter(seconds: 130, timestamp: "2:10", title: "Veredicto"),
            ],
            tags: ["simracing", "neumáticos de lluvia", "iRacing", "guía de compra"],
            hashtags: ["#simracing", "#iRacing", "#lluvia"],
            pinnedComment: "¿Qué neumático usas tú cuando llueve? Cuéntamelo en los comentarios.",
            communityPost: "Nuevo vídeo: comparamos tres neumáticos de lluvia con telemetría real.",
            sources: [
                PublishingSource(title: "Reglamento técnico", url: "https://example.com/reglamento", note: ""),
                PublishingSource(title: "", url: "", note: "Notas de la prueba en mojado del 12 de mayo."),
            ]
        )
    }

    @Test("Golden synthetic publishing pack")
    func goldenPack() throws {
        let expected = try String(
            contentsOf: #require(
                Bundle.module.url(
                    forResource: "synthetic-pack",
                    withExtension: "md",
                    subdirectory: "Fixtures/Publishing"
                )
            ),
            encoding: .utf8
        )
        let output = PublishingExport.make(Self.sampleInput())
        #expect(output == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("The SEO block uses the exact importer section names")
    func sectionNames() {
        let output = PublishingExport.make(Self.sampleInput())
        for heading in [
            "# Paquete SEO",
            "## Título recomendado",
            "## Variantes",
            "## Concepto de miniatura",
            "## Descripción",
            "## Capítulos",
            "## Etiquetas",
            "## Hashtags",
            "## Comentario fijado",
            "## Texto para comunidad",
        ] {
            #expect(output.contains(heading), "missing \(heading)")
        }
        #expect(output.contains("# Cómo elegir neumáticos para mojado"))
        #expect(output.contains("## YouTube Studio"))
    }

    @Test("YouTube Studio description includes chapters and sources")
    func studioDescription() {
        let text = PublishingExport.studioDescription(Self.sampleInput())
        #expect(text.contains("Comparamos tres neumáticos"))
        #expect(text.contains("Capítulos\n0:00 Gancho\n0:45 Qué cambia\n2:10 Veredicto"))
        #expect(text.contains("Fuentes\n- Reglamento técnico — https://example.com/reglamento"))
        #expect(text.contains("- Notas de la prueba en mojado del 12 de mayo."))
    }

    @Test("Studio description does not duplicate chapters already in the text")
    func studioDescriptionAvoidsDuplicates() {
        var input = Self.sampleInput()
        input.description += "\n\n0:00 Gancho\n0:45 Qué cambia\n2:10 Veredicto"
        let text = PublishingExport.studioDescription(input)
        #expect(text.components(separatedBy: "0:00 Gancho").count - 1 == 1)
        #expect(!text.contains("Capítulos\n0:00 Gancho"))
    }

    @Test("Field values are paste-ready")
    func fieldValues() {
        let input = Self.sampleInput()
        #expect(PublishingExport.fieldValue(.title, input: input) == input.title)
        #expect(PublishingExport.fieldValue(.tags, input: input) == input.tags.joined(separator: ", "))
        #expect(PublishingExport.fieldValue(.hashtags, input: input) == "#simracing #iRacing #lluvia")
        #expect(PublishingExport.fieldValue(.chapters, input: input).hasPrefix("0:00 Gancho"))
        #expect(PublishingExport.fieldValue(.titleCandidates, input: input).hasPrefix("1. Neumáticos"))
        #expect(PublishingExport.fieldValue(.description, input: input).contains("Capítulos"))
    }

    @Test("Empty fields still produce the canonical section skeleton")
    func emptyPack() {
        let output = PublishingExport.make(
            PublishingExportInput(
                projectTitle: "Proyecto vacío",
                title: "",
                description: "",
                tags: [],
                hashtags: [],
                pinnedComment: ""
            )
        )
        #expect(output.contains("# Paquete SEO"))
        #expect(output.contains("## Título recomendado"))
        #expect(output.contains("## Texto para comunidad"))
    }

    @Test("The pack parses back with the escaleta importer")
    func roundTrip() {
        let input = Self.sampleInput()
        let markdown = PublishingExport.make(input)
        let parsed = EscaletaParser.parse(markdown)
        let publishing = parsed.document.publishing

        #expect(parsed.document.title == input.projectTitle)
        #expect(parsed.document.promise == input.promise)
        #expect(parsed.document.thesis == input.thesis)
        #expect(publishing?.primaryTitle == input.title)
        #expect(publishing?.titleCandidates == input.titleCandidates)
        #expect(publishing?.description == input.description)
        #expect(publishing?.tags == input.tags)
        #expect(publishing?.hashtags == input.hashtags)
        #expect(publishing?.pinnedComment == input.pinnedComment)
        #expect(publishing?.communityPost == input.communityPost)
        #expect(publishing?.chapters.map(\.title) == ["Gancho", "Qué cambia", "Veredicto"])
        #expect(parsed.document.sources.count == 2)
    }
}
