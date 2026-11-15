import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Publishing titles")
struct PublishingTitlesTests {
    @Test("Parses the JSON object the prompt asks for")
    func parsesObject() {
        let titles = PublishingTitleParser.parse(
            #"{"titles":["El neumático que cambia todo","Qué probar antes de comprar"]}"#
        )
        #expect(titles == ["El neumático que cambia todo", "Qué probar antes de comprar"])
    }

    @Test("Parses an array and an object inside prose or fences")
    func parsesVariants() {
        #expect(PublishingTitleParser.parse(#"["Uno","Dos"]"#) == ["Uno", "Dos"])
        let fenced = """
        Aquí tienes las opciones:
        ```json
        {"titles": ["Uno", "Dos"]}
        ```
        Espero que te sirvan.
        """
        #expect(PublishingTitleParser.parse(fenced) == ["Uno", "Dos"])
    }

    @Test("Falls back to numbered lines")
    func parsesLines() {
        let response = """
        1. **El dato** que nadie mira 🚀
        2) La decisión que cambia la compra
        - Tercera opción
        """
        let titles = PublishingTitleParser.parse(response)
        #expect(titles.count == 3)
        #expect(titles[0] == "El dato que nadie mira")
        #expect(titles[1] == "La decisión que cambia la compra")
        #expect(titles[2] == "Tercera opción")
    }

    @Test("Deduplicates case-insensitively and caps at eight")
    func deduplicates() {
        let raw = (1...10).map { "Título \($0)" } + ["título 1"]
        let titles = PublishingTitleParser.parse(raw.joined(separator: "\n"))
        #expect(titles.count == 8)
    }

    @Test("Truncates titles at the hard limit")
    func truncates() {
        let long = String(repeating: "palabra ", count: 20)
        let titles = PublishingTitleParser.parse(long)
        #expect(titles.count == 1)
        #expect(titles[0].count == 100)
    }

    @Test("Rejects empty responses")
    func rejectsEmpty() {
        #expect(PublishingTitleParser.parse("").isEmpty)
        #expect(PublishingTitleParser.parse("```json\n{\"titles\":[]}\n```").isEmpty)
    }

    @Test("Prompt carries the promise, thesis and hard limit")
    func prompt() {
        let context = PublishingTitleContext(
            projectTitle: "Neumáticos de lluvia",
            promise: "Elegir sin gastar de más",
            thesis: "El compuesto importa menos que la presión",
            videoType: "prueba",
            targetDuration: "12:00",
            sceneTitles: ["Gancho", "Prueba"],
            openingText: "Texto sintético de apertura."
        )
        let user = PublishingTitlePrompt.userPrompt(context)
        let system = PublishingTitlePrompt.systemPrompt(languageName: "Spanish")

        #expect(user.contains("Neumáticos de lluvia"))
        #expect(user.contains("Elegir sin gastar de más"))
        #expect(user.contains("El compuesto importa menos que la presión"))
        #expect(user.contains("Gancho"))
        #expect(system.contains("100 characters"))
        #expect(system.contains("Spanish"))
        #expect(system.contains(#"{"titles":["…","…"]}"#))
    }
}
