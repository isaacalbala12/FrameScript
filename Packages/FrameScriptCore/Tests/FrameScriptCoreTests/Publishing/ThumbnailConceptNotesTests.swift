import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Thumbnail concept notes")
struct ThumbnailConceptNotesTests {
    @Test("Parses the importer's structured format")
    func parsesImporterFormat() {
        let text = """
        ### Concepto A — El título engaña
        Idea: Mostrar el titular verdadero detrás del clickbait.
        Composición:
        - Texto a la izquierda
        - Cara a la derecha
        Por qué funciona: El contraste se entiende en un segundo.

        ### Concepto B — Tres palabras
        Idea: Una promesa concreta.
        Por qué funciona: Es legible a tamaño móvil.
        """

        let parsed = PublishingThumbnailNotes.parse(text)
        #expect(parsed.concepts.count == 2)
        #expect(parsed.notes.isEmpty)
        #expect(parsed.concepts[0].label == "A")
        #expect(parsed.concepts[0].text == "El título engaña")
        #expect(parsed.concepts[0].composition == ["Texto a la izquierda", "Cara a la derecha"])
        #expect(parsed.concepts[0].whyItWorks == "El contraste se entiende en un segundo.")
        #expect(parsed.concepts[1].text == "Tres palabras")
        #expect(parsed.concepts[1].wordCount == 2)
    }

    @Test("Renders back to the importer's format")
    func rendersImporterFormat() {
        let concepts = [
            PublishingThumbnailConcept(
                label: "A",
                text: "El título engaña",
                idea: "Mostrar el titular real.",
                composition: ["Texto a la izquierda", "Cara a la derecha"],
                whyItWorks: "Se entiende de un vistazo."
            ),
            PublishingThumbnailConcept(
                label: "B",
                text: "Dos segundos",
                isRecommended: true
            ),
        ]
        let rendered = PublishingThumbnailNotes(concepts: concepts).rendered()

        #expect(rendered.contains("### Concepto A — El título engaña"))
        #expect(rendered.contains("Idea: Mostrar el titular real."))
        #expect(rendered.contains("Composición:\n- Texto a la izquierda\n- Cara a la derecha"))
        #expect(rendered.contains("Por qué funciona: Se entiende de un vistazo."))
        #expect(rendered.contains("### Concepto B — Dos segundos — Recomendado"))
    }

    @Test("Round-trips structured notes exactly")
    func roundTrip() {
        let text = """
        ### Concepto A — Texto uno
        Idea: Idea uno.
        Composición:
        - Plano medio
        Por qué funciona: Porque sí.

        ### Concepto B — Texto dos
        """
        let parsed = PublishingThumbnailNotes.parse(text)
        #expect(parsed.rendered() == text)
    }

    @Test("Free-form notes are kept verbatim when there are no concepts")
    func freeForm() {
        let text = "Miniatura: primer plano del casco, fondo oscuro y el número 24 grande."
        let parsed = PublishingThumbnailNotes.parse(text)
        #expect(parsed.concepts.isEmpty)
        #expect(parsed.notes == text)
        #expect(parsed.rendered() == text)
    }

    @Test("Text outside the concept blocks survives")
    func preservesLooseNotes() {
        let text = """
        Referencia visual: portada de la temporada anterior.

        ### Concepto A — Texto uno
        Idea: Idea uno.
        """
        let parsed = PublishingThumbnailNotes.parse(text)
        #expect(parsed.concepts.count == 1)
        #expect(parsed.notes.contains("Referencia visual"))
        #expect(parsed.rendered().hasSuffix("Referencia visual: portada de la temporada anterior."))
    }
}
