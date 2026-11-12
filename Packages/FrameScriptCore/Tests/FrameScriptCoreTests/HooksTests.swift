import Foundation
import Testing
@testable import FrameScriptCore

@Suite("HookResponseParser")
struct HookResponseParserTests {
    @Test func parsesPlainStructuredHooks() throws {
        let response = """
        {"hooks":[
          {"angle":"pregunta","text":"El parche llega tarde y la pregunta es otra: ¿merece la pena esperar?","onScreenText":"¿Merece la pena?"},
          {"angle":"dato","text":"Tres cambios, una cifra y un problema que nadie ha mencionado todavía.","onScreenText":""}
        ]}
        """

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.count == 2)
        #expect(hooks[0].angle == "pregunta")
        #expect(hooks[0].onScreenText == "¿Merece la pena?")
        #expect(hooks[1].onScreenText.isEmpty)
        #expect(hooks.allSatisfy { $0.wordCount > 0 })
        #expect(hooks[0].estimatedSeconds > 0)
        #expect(hooks.allSatisfy { $0.isWithinLimit })
    }

    @Test func parsesFencedAndWrappedJSON() throws {
        let fenced = """
        ```json
        {"hooks":[{"angle":"contraste","text":"Sobre el papel suena muy bien. En pista, el problema es otro."}]}
        ```
        """
        let wrapped = #"{"data":{"hooks":[{"angle":"promesa","text":"Hay una promesa pequeña que cambia toda la comparativa."}]}}"#
        let array = #"[{"angle":"dato","text":"Una cifra concreta basta para abrir el vídeo sin rodeos."}]"#

        #expect(try HookResponseParser.parseHooks(fenced, wordsPerMinute: 150).first?.angle == "contraste")
        #expect(try HookResponseParser.parseHooks(wrapped, wordsPerMinute: 150).first?.angle == "promesa")
        #expect(try HookResponseParser.parseHooks(array, wordsPerMinute: 150).first?.angle == "dato")
    }

    @Test func extractsJSONSurroundedByProse() throws {
        let response = "Claro, aquí tienes las alternativas:\n{\"hooks\":[{\"text\":\"Esto empieza con el problema real, no con el menú.\"}]}\nEspero que sirvan."

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.count == 1)
        #expect(hooks[0].text == "Esto empieza con el problema real, no con el menú.")
    }

    @Test func skipsMalformedEntriesAndKeepsValidOnes() throws {
        let response = #"{"hooks":[{"angle":"dato"},{"text":"   "},{"text":123},{"text":"**Negrita** no es texto hablado."},{"text":"Esta sí sirve como gancho hablado."}]}"#

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.count == 1)
        #expect(hooks[0].text == "Esta sí sirve como gancho hablado.")
    }

    @Test func rejectsNonJSONAndEmptyStructuredPayloads() {
        #expect(throws: HookParsingError.invalidJSON) {
            try HookResponseParser.parseHooks("No hay JSON aquí, solo una frase.", wordsPerMinute: 150)
        }
        #expect(throws: HookParsingError.invalidJSON) {
            try HookResponseParser.parseHooks("```json\n```", wordsPerMinute: 150)
        }
        #expect(throws: HookParsingError.noSuggestions) {
            try HookResponseParser.parseHooks(#"{"hooks":[]}"#, wordsPerMinute: 150)
        }
        #expect(throws: HookParsingError.noSuggestions) {
            try HookResponseParser.parseHooks(#"{"hooks":[{"text":"..."}]}"#, wordsPerMinute: 150)
        }
    }

    @Test func stripsWrappingQuotesAndListBullets() throws {
        let response = #"{"hooks":[{"text":"\"Un gancho entre comillas.\""},{"text":"- Un gancho con viñeta."}]}"#

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.map(\.text) == ["Un gancho entre comillas.", "Un gancho con viñeta."])
    }

    @Test func deduplicatesAlternatives() throws {
        let response = #"{"hooks":[{"text":"El mismo gancho."},{"text":"  el mismo   gancho. "}]}"#

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.count == 1)
    }

    @Test func capsAlternativesAtFive() throws {
        let entries = (1...8).map { #"{"text":"Alternativa número \#($0) para abrir el vídeo."}"# }.joined(separator: ",")
        let response = #"{"hooks":[\#(entries)]}"#

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks.count == HookLimits.maximumHookAlternatives)
    }

    @Test func flagsHooksOverFifteenSeconds() throws {
        let short = Array(repeating: "palabra", count: 30).joined(separator: " ")
        let long = Array(repeating: "palabra", count: 40).joined(separator: " ")
        let response = #"{"hooks":[{"text":"\#(short)"},{"text":"\#(long)"}]}"#

        let hooks = try HookResponseParser.parseHooks(response, wordsPerMinute: 150)

        #expect(hooks[0].estimatedSeconds == 12)
        #expect(hooks[0].isWithinLimit)
        #expect(hooks[1].estimatedSeconds > 15)
        #expect(hooks[1].exceedsLimit)
    }

    @Test func countsPausesInEstimatedSeconds() throws {
        let response = #"{"hooks":[{"text":"Una frase corta. [pausa 2s] Y otra frase."}]}"#

        let hook = try #require(try HookResponseParser.parseHooks(response, wordsPerMinute: 150).first)

        #expect(hook.wordCount == 6)
        #expect(abs(hook.estimatedSeconds - (6.0 / 150.0 * 60.0 + 2.0)) < 0.001)
    }

    @Test func rateFallsBackWhenInvalid() throws {
        let response = #"{"hooks":[{"text":"Una alternativa con palabras suficientes para medir."}]}"#

        let zero = try HookResponseParser.parseHooks(response, wordsPerMinute: 0).first
        let negative = try HookResponseParser.parseHooks(response, wordsPerMinute: -10).first

        #expect(zero?.estimatedSeconds == negative?.estimatedSeconds)
    }
}

@Suite("RehookResponseParser")
struct RehookResponseParserTests {
    @Test func parsesBridgeWithExactAnchor() throws {
        let scene = "Primero empieza el contexto. Después llega el dato que importa. Y al final el veredicto."
        let anchors = RehookPlanner.positions(
            in: scene,
            wordsPerMinute: 150,
            sceneStartSeconds: 297,
            videoDurationSeconds: 600
        )
        let anchor = try #require(anchors.first)
        let response = #"{"bridges":[{"text":"Pero hay otra pieza que cambia la comparativa entera.","anchor":"\#(anchor.anchor)"}]}"#

        let suggestions = try HookResponseParser.parseRehooks(
            response,
            anchors: anchors,
            wordsPerMinute: 150
        )

        #expect(suggestions.count == 1)
        #expect(suggestions[0].anchor == anchor.anchor)
        #expect(suggestions[0].isWithinLimit)
    }

    @Test func missingAnchorIsAcceptedOnlyForOnePosition() throws {
        let anchors = [
            RehookPosition(anchor: "Uno. Dos.", anchorRange: UTF16Span(location: 0, length: 9), sentenceIndex: 1, reason: .longScene)
        ]
        let response = #"{"bridges":[{"text":"Un puente sin ancla explícita."}]}"#

        let suggestions = try HookResponseParser.parseRehooks(
            response,
            anchors: anchors,
            wordsPerMinute: 150
        )

        #expect(suggestions.first?.anchor == "Uno. Dos.")
    }

    @Test func unknownAnchorIsRejected() throws {
        let anchors = [
            RehookPosition(anchor: "La frase correcta.", anchorRange: UTF16Span(location: 0, length: 17), sentenceIndex: 1, reason: .longScene)
        ]
        let response = #"{"bridges":[{"text":"Un puente que no debería entrar.","anchor":"Otra frase distinta."}]}"#

        #expect(throws: HookParsingError.noSuggestions) {
            try HookResponseParser.parseRehooks(response, anchors: anchors, wordsPerMinute: 150)
        }
    }

    @Test func rejectsEmptyAnchors() {
        #expect(throws: HookParsingError.noValidAnchors) {
            try HookResponseParser.parseRehooks(#"{"bridges":[]}"#, anchors: [], wordsPerMinute: 150)
        }
    }

    @Test func capsTwoBridgesPerPosition() throws {
        let anchors = [
            RehookPosition(anchor: "La frase ancla.", anchorRange: UTF16Span(location: 0, length: 15), sentenceIndex: 1, reason: .longScene)
        ]
        let entries = (1...4)
            .map { #"{"text":"Puente número \#($0) para seguir viendo.","anchor":"La frase ancla."}"# }
            .joined(separator: ",")
        let response = #"{"bridges":[\#(entries)]}"#

        let suggestions = try HookResponseParser.parseRehooks(
            response,
            anchors: anchors,
            wordsPerMinute: 150
        )

        #expect(suggestions.count == 2)
    }

    @Test func flagsBridgesOverSixSeconds() throws {
        let short = Array(repeating: "palabra", count: 12).joined(separator: " ")
        let long = Array(repeating: "palabra", count: 20).joined(separator: " ")
        let anchors = [
            RehookPosition(anchor: "La frase ancla.", anchorRange: UTF16Span(location: 0, length: 15), sentenceIndex: 1, reason: .longScene)
        ]
        let response = #"{"bridges":[{"text":"\#(short)","anchor":"La frase ancla."},{"text":"\#(long)","anchor":"La frase ancla."}]}"#

        let suggestions = try HookResponseParser.parseRehooks(
            response,
            anchors: anchors,
            wordsPerMinute: 150
        )

        #expect(suggestions[0].isWithinLimit)
        #expect(suggestions[1].exceedsLimit)
    }
}

@Suite("RehookPlanner")
struct RehookPlannerTests {
    @Test func longSceneGetsTwoPositionsAround40And60Percent() throws {
        let text = longScene(sentenceCount: 30)

        let positions = RehookPlanner.positions(in: text, wordsPerMinute: 150)

        #expect(positions.count == 2)
        #expect(positions.map(\.reason) == [.longScene, .longScene])
        #expect(positions[0].anchorRange.location < positions[1].anchorRange.location)
        #expect(positions.allSatisfy { !$0.anchor.isEmpty })
        let ns = text as NSString
        for position in positions {
            #expect(ns.substring(with: NSRange(location: position.anchorRange.location, length: position.anchorRange.length)) == position.anchor)
        }
    }

    @Test func shortSceneWithoutVideoMidpointHasNoPositions() {
        let text = longScene(sentenceCount: 15)

        let positions = RehookPlanner.positions(
            in: text,
            wordsPerMinute: 150,
            sceneStartSeconds: 0,
            videoDurationSeconds: 600
        )

        #expect(positions.isEmpty)
    }

    @Test func shortSceneCoveringVideoMidpointGetsOnePosition() throws {
        let text = longScene(sentenceCount: 15)

        let positions = RehookPlanner.positions(
            in: text,
            wordsPerMinute: 150,
            sceneStartSeconds: 280,
            videoDurationSeconds: 600
        )

        #expect(positions.count == 1)
        #expect(positions.first?.reason == .videoMidpoint)
    }

    @Test func sceneWithFewerThanThreeSentencesHasNoPositions() {
        #expect(RehookPlanner.positions(in: "Uno. Dos.", wordsPerMinute: 150).isEmpty)
        #expect(RehookPlanner.positions(in: "", wordsPerMinute: 150).isEmpty)
    }

    @Test func duplicateTargetsDoNotRepeatAnAnchor() {
        let text = longScene(sentenceCount: 4)

        let positions = RehookPlanner.positions(in: text, wordsPerMinute: 150)

        #expect(Set(positions.map(\.anchorRange.location)).count == positions.count)
    }

    private func longScene(sentenceCount: Int) -> String {
        (1...sentenceCount)
            .map { "Frase número \($0) con diez palabras para probar el plan." }
            .joined(separator: " ")
    }
}

@Suite("HookInsertion")
struct HookInsertionTests {
    @Test func replacesFirstSpokenParagraphAndKeepsTheRest() {
        let text = "Gancho viejo.\n\nSegundo bloque.\n\nTercero."

        let result = HookInsertion.replacingHook(in: text, with: "Gancho nuevo.")

        #expect(result == "Gancho nuevo.\n\nSegundo bloque.\n\nTercero.")
    }

    @Test func preservesLeadingCueLinesInsideTheHookParagraph() {
        let text = "[IMAGEN: coche en pista]\nGancho viejo.\n\nResto del guion."

        let result = HookInsertion.replacingHook(in: text, with: "Gancho nuevo.")

        #expect(result == "[IMAGEN: coche en pista]\nGancho nuevo.\n\nResto del guion.")
    }

    @Test func appendsWhenThereIsNoSpokenParagraph() {
        #expect(HookInsertion.replacingHook(in: "", with: "Nuevo.") == "Nuevo.")
        #expect(HookInsertion.replacingHook(in: "   \n\n ", with: "Nuevo.") == "Nuevo.")
        #expect(HookInsertion.replacingHook(in: "[IMAGEN: coche]", with: "Nuevo.") == "[IMAGEN: coche]\n\nNuevo.")
    }

    @Test func normalizesMultilineHookTextIntoOneParagraph() {
        let result = HookInsertion.replacingHook(in: "Viejo.", with: "  Nuevo\n  gancho  ")

        #expect(result == "Nuevo gancho")
    }

    @Test func rehookIsInsertedBeforeAnchorWithCueLine() throws {
        let text = "Uno. Dos. Tres."
        let anchor = try #require(HookInsertion.anchorRange(for: "Dos.", in: text))

        let result = try #require(HookInsertion.insertingRehook(in: text, before: anchor, rehook: "Puente."))

        #expect(result == "Uno.\n\n[RE-HOOK]\nPuente.\n\nDos. Tres.")
    }

    @Test func rehookAtTheStartNeedsNoLeadingParagraphBreak() throws {
        let text = "Dos. Tres."
        let anchor = try #require(HookInsertion.anchorRange(for: "Dos.", in: text))

        let result = try #require(HookInsertion.insertingRehook(in: text, before: anchor, rehook: "Puente."))

        #expect(result == "[RE-HOOK]\nPuente.\n\nDos. Tres.")
    }

    @Test func invalidAnchorRangeIsRejected() {
        #expect(HookInsertion.insertingRehook(in: "Uno.", before: UTF16Span(location: 99, length: 1), rehook: "Puente.") == nil)
        #expect(HookInsertion.insertingRehook(in: "Uno.", before: UTF16Span(location: 0, length: 0), rehook: "Puente.") == nil)
        #expect(HookInsertion.insertingRehook(in: "Uno.", before: UTF16Span(location: 0, length: 4), rehook: "   ") == nil)
    }

    @Test func anchorResolutionSurvivesTextEdits() throws {
        let original = "Uno. Dos. Tres."
        let originalRange = try #require(HookInsertion.anchorRange(for: "Dos.", in: original))
        let edited = "Un párrafo nuevo.\n\nUno. Dos. Tres."

        let resolved = try #require(HookInsertion.anchorRange(for: "Dos.", in: edited))

        #expect(resolved != originalRange)
        #expect((edited as NSString).substring(with: NSRange(location: resolved.location, length: resolved.length)) == "Dos.")
    }

    @Test func missingAnchorResolutionReturnsNil() {
        #expect(HookInsertion.anchorRange(for: "No existe.", in: "Uno. Dos.") == nil)
        #expect(HookInsertion.anchorRange(for: "", in: "Uno. Dos.") == nil)
    }

    @Test func rangeMatchingIgnoresCaseAndWhitespaceDifferences() throws {
        let text = "Uno. DOS. Tres."
        let range = try #require(HookInsertion.anchorRange(for: "Dos.", in: text))

        #expect(HookInsertion.matchesAnchor("dos.", at: range, in: text))
        #expect(!HookInsertion.matchesAnchor("Tres.", at: range, in: text))
        #expect(!HookInsertion.matchesAnchor("Dos.", at: UTF16Span(location: 99, length: 4), in: text))
    }
}
