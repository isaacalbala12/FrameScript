import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Helpers

private func script(_ text: String, _ language: SpeechLanguage) -> TokenizedScript {
    ScriptTokenizer.tokenize(text, language: language)
}

private func originalSubstring(of token: ScriptToken, in text: String) -> String {
    (text as NSString).substring(
        with: NSRange(location: token.range.lowerBound, length: token.range.count)
    )
}

private func joinedWords(_ tokens: ArraySlice<ScriptToken>) -> String {
    tokens.map(\.normalized).joined(separator: " ")
}

private func cumulativeTranscript(_ tokens: [ScriptToken], through index: Int) -> String {
    tokens.prefix(index + 1).map(\.normalized).joined(separator: " ")
}

private let spanishScriptText = """
La suspensión del coche está demasiado blanda en la curva rápida.
Vamos a probar el nuevo reglaje en la siguiente vuelta.
El coche gira mejor, pero pierde velocidad en la recta.
Mañana probaremos los neumáticos blandos con menos carga.
"""

private let englishScriptText = """
The throttle response feels sharper after the update.
We tested the new setup on the long straight.
Braking is stable but the tires overheat quickly.
Tomorrow we will compare it with the old configuration.
"""

// MARK: - Tokenizer

@Test func tokenizerStripsPunctuationAndDiacritics() {
    let text = "¡Vámonos, niño! ¿Qué tal?"
    let tokenized = script(text, .spanish)

    #expect(tokenized.tokens.map(\.normalized) == ["vamonos", "nino", "que", "tal"])
    #expect(tokenized.tokens.map(\.sentenceIndex) == [0, 0, 1, 1])
    for token in tokenized.tokens {
        #expect(originalSubstring(of: token, in: text) == token.source)
    }
}

@Test func tokenizerProducesUTF16Ranges() {
    let text = "🚗 El coche está aquí."
    let tokenized = script(text, .spanish)

    #expect(tokenized.tokens.map(\.source) == ["El", "coche", "está", "aquí"])
    // Emoji (2 UTF-16 units) + space = 3.
    #expect(tokenized.tokens[0].range.lowerBound == 3)
    #expect(tokenized.tokens[3].range.lowerBound == 17)
    for token in tokenized.tokens {
        #expect(originalSubstring(of: token, in: text) == token.source)
    }
}

@Test func tokenizerIgnoresMarkupButKeepsEmphasizedWords() {
    let text = "Hola / mundo // [pausa] [pausa 2s] [2s] [LABEL: plano] *rápido* **fuerte** km/h 1/4"
    let tokenized = script(text, .spanish)

    #expect(tokenized.tokens.map(\.normalized) == [
        "hola", "mundo", "rapido", "fuerte", "km", "h", "1", "4"
    ])
    #expect(!tokenized.tokens.contains { $0.normalized == "pausa" })
    #expect(!tokenized.tokens.contains { $0.normalized == "plano" })
    #expect(tokenized.tokens.allSatisfy { $0.sentenceIndex == 0 })
}

@Test func tokenizerSkipsMarkupOnlyScript() {
    let tokenized = script("/ // [pausa 1,5s] ** * [CAM: close-up]", .spanish)
    #expect(tokenized.isEmpty)
    #expect(tokenized.sentenceCount == 0)
    #expect(tokenized.tokenRange(forSentence: 0) == nil)
}

@Test func tokenizerMergesSpanishNumberWords() {
    let text = "Tengo veinte coches y treinta y uno más. En 2026 probaremos mil novecientos ochenta y cuatro ajustes."
    let tokenized = script(text, .spanish)

    #expect(tokenized.tokens.map(\.normalized) == [
        "tengo", "20", "coches", "y", "31", "mas",
        "en", "2026", "probaremos", "1984", "ajustes"
    ])
    #expect(tokenized.tokens.map(\.sentenceIndex) == [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
    #expect(tokenized.tokens[4].source == "treinta y uno")
    #expect(originalSubstring(of: tokenized.tokens[4], in: text) == "treinta y uno")
}

@Test func tokenizerMergesEnglishNumberWordsAndYears() {
    let text = "Twenty-six cars in 2026. Twenty twenty-six was one hundred and five years ago."
    let tokenized = script(text, .english)

    #expect(tokenized.tokens.map(\.normalized) == [
        "26", "cars", "in", "2026", "2026", "was", "105", "years", "ago"
    ])
    #expect(tokenized.tokens.map(\.sentenceIndex) == [0, 0, 0, 0, 1, 1, 1, 1, 1])

    let longYear = script("In two thousand twenty-six we race.", .english)
    #expect(longYear.tokens.map(\.normalized) == ["in", "2026", "we", "race"])

    #expect(script("one thousand and five", .english).tokens.map(\.normalized) == ["1005"])
    #expect(script("hundred and five", .english).tokens.map(\.normalized) == ["105"])
    #expect(
        script("twenty twenty-six a great year", .english).tokens.map(\.normalized)
            == ["2026", "a", "great", "year"]
    )
}

@Test func tokenizerMapsDigitsAndNumberWordsToSameCanonicalForm() {
    let digits = script("En 2026 hay 31 coches.", .spanish)
    let words = script("En dos mil veintiséis hay treinta y uno coches.", .spanish)

    #expect(digits.tokens.map(\.normalized) == words.tokens.map(\.normalized))
    #expect(digits.tokens.map(\.normalized) == ["en", "2026", "hay", "31", "coches"])
}

@Test func tokenizerDoesNotMergeAdjacentStandaloneNumbers() {
    #expect(script("dos tres", .spanish).tokens.map(\.normalized) == ["2", "3"])
    #expect(script("one two", .english).tokens.map(\.normalized) == ["1", "2"])
}

@Test func tokenizerUsesLanguageForAmbiguousWords() {
    #expect(script("once", .spanish).tokens.map(\.normalized) == ["11"])
    #expect(script("once", .english).tokens.map(\.normalized) == ["once"])
}

@Test func tokenizerHandlesZeroToOneHundred() {
    let spanishWords = [
        "cero", "uno", "dieciséis", "veintiuno", "treinta",
        "treinta y uno", "cien"
    ]
    let spanishExpected = ["0", "1", "16", "21", "30", "31", "100"]
    for (words, expected) in zip(spanishWords, spanishExpected) {
        #expect(script(words, .spanish).tokens.map(\.normalized) == [expected])
    }

    let englishWords = [
        "zero", "one", "sixteen", "twenty-one", "thirty",
        "thirty one", "one hundred"
    ]
    let englishExpected = ["0", "1", "16", "21", "30", "31", "100"]
    for (words, expected) in zip(englishWords, englishExpected) {
        #expect(script(words, .english).tokens.map(\.normalized) == [expected])
    }
}

@Test func tokenizerDetectsSentencesAndBlankLines() {
    let tokenized = script("Primera frase. Segunda frase! Tercera?", .spanish)
    #expect(tokenized.tokens.map(\.sentenceIndex) == [0, 0, 1, 1, 2])
    #expect(tokenized.sentenceCount == 3)
    #expect(tokenized.tokenRange(forSentence: 0) == 0..<2)
    #expect(tokenized.tokenRange(forSentence: 1) == 2..<4)
    #expect(tokenized.tokenRange(forSentence: 2) == 4..<5)
    #expect(tokenized.tokenRange(fromSentence: 1, throughSentence: 2) == 2..<5)

    let paragraphBreak = script("Uno\n\nDos", .spanish)
    #expect(paragraphBreak.tokens.map(\.sentenceIndex) == [0, 1])

    let softWrap = script("Uno\nDos", .spanish)
    #expect(softWrap.tokens.map(\.sentenceIndex) == [0, 0])
}

// MARK: - Follower: perfect reading

@Test func followerTracksPerfectSpanishReading() {
    let tokenized = script(spanishScriptText, .spanish)
    var follower = SpeechFollower(script: tokenized)
    var state = follower.state

    for index in tokenized.tokens.indices {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.3
        )
        if index >= 2 {
            #expect(state.tokenIndex == index, "word \(index) should be current")
            #expect(state.utf16Offset == tokenized.tokens[index].range.lowerBound)
        }
    }

    #expect(state.tokenIndex == tokenized.tokens.count - 1)
    #expect(state.sentenceIndex == tokenized.sentenceCount - 1)
    #expect(state.confidence > 0.9)
    #expect(state.matchedWordCount >= 3)
    #expect(!state.isLost)
}

@Test func followerTracksPerfectEnglishReading() {
    let tokenized = script(englishScriptText, .english)
    var follower = SpeechFollower(script: tokenized)
    var state = follower.state

    for index in tokenized.tokens.indices {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    #expect(state.tokenIndex == tokenized.tokens.count - 1)
    #expect(state.confidence > 0.9)
    #expect(!state.isLost)
}

// MARK: - Follower: recognizer noise

@Test func followerToleratesRecognizerSubstitutions() {
    let tokenized = script(englishScriptText, .english)
    var spoken = tokenized.tokens.map(\.normalized)
    spoken[1] = "throtle"      // one edit away from "throttle"
    spoken[2] = "responses"    // plural / prefix variation
    spoken[4] = "sharp"        // truncation of "sharper"
    spoken[5] = "banana"       // outright substitution

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in spoken.indices {
        state = follower.process(
            text: spoken.prefix(index + 1).joined(separator: " "),
            at: Double(index) * 0.25
        )
    }

    #expect(state.tokenIndex == tokenized.tokens.count - 1)
    #expect(state.confidence > 0.7)
    #expect(!state.isLost)
}

@Test func followerToleratesAdLibsInsertedInTheMiddle() {
    let tokenized = script(spanishScriptText, .spanish)
    var spoken = tokenized.tokens.map(\.normalized)
    let adLib = ["bueno", "pues", "aqui", "estamos", "otra", "vez"]
    spoken.insert(contentsOf: adLib, at: 8)

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in spoken.indices {
        state = follower.process(
            text: spoken.prefix(index + 1).joined(separator: " "),
            at: Double(index) * 0.2
        )
    }

    #expect(state.tokenIndex == tokenized.tokens.count - 1)
    #expect(!state.isLost)
}

@Test func followerToleratesSkippedScriptWord() {
    let tokenized = script(englishScriptText, .english)
    var spoken = tokenized.tokens.map(\.normalized)
    spoken.remove(at: 4) // reader omits "sharper"

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in spoken.indices {
        state = follower.process(
            text: spoken.prefix(index + 1).joined(separator: " "),
            at: Double(index) * 0.25
        )
    }

    #expect(state.tokenIndex == tokenized.tokens.count - 1)
    #expect(!state.isLost)
}

@Test func followerReportsLowConfidenceForGarbage() {
    let tokenized = script(englishScriptText, .english)
    var follower = SpeechFollower(script: tokenized)

    let state = follower.process(text: "banana platano naranja limon", at: 0)
    #expect(state.tokenIndex == 0)
    #expect(state.confidence < 0.4)
    #expect(!state.isLost)
}

@Test func followerStaysStableUnderRepeatedIdenticalHypotheses() {
    let tokenized = script(englishScriptText, .english)
    var follower = SpeechFollower(script: tokenized)
    let text = joinedWords(tokenized.tokens[0..<6])

    let first = follower.process(text: text, at: 1)
    #expect(first.tokenIndex == 5)

    for tick in 2...7 {
        let repeated = follower.process(text: text, at: Double(tick))
        #expect(repeated.tokenIndex == first.tokenIndex)
        #expect(repeated.utf16Offset == first.utf16Offset)
        #expect(repeated.confidence == first.confidence)
        #expect(repeated.matchedWordCount == first.matchedWordCount)
        #expect(!repeated.isLost)
    }
}

// MARK: - Follower: jumps

@Test func followerJumpsForwardOverOneSkippedSentence() throws {
    let text = """
    Primera frase del guion con palabras claras.
    Segunda frase que el lector se salta por completo.
    Tercera frase retomada despues del salto.
    Cuarta frase para seguir leyendo sin problemas.
    Quinta frase final del ejemplo.
    """
    let tokenized = script(text, .spanish)
    let firstSentence = try #require(tokenized.tokenRange(forSentence: 0))
    let thirdSentence = try #require(tokenized.tokenRange(forSentence: 2))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state

    for index in firstSentence {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.sentenceIndex == 0)

    var spoken = tokenized.tokens[firstSentence].map(\.normalized)
    for (offset, index) in thirdSentence.enumerated() {
        spoken.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: spoken.joined(separator: " "),
            at: 10 + Double(offset) * 0.2
        )
    }

    #expect(state.sentenceIndex == 2)
    #expect(thirdSentence.contains(state.tokenIndex ?? -1))
    #expect(!state.isLost)
}

@Test func followerRequiresSustainedStrengthForLongForwardJumps() throws {
    let text = """
    Primera frase del guion con palabras claras.
    Segunda frase que nadie llega a leer.
    Tercera frase intermedia del ejemplo.
    Cuarta frase que tampoco se escucha.
    Quinta frase retomada despues del salto largo.
    Sexta frase para cerrar el ejemplo.
    Septima frase final del guion completo.
    """
    let tokenized = script(text, .spanish)
    let firstSentence = try #require(tokenized.tokenRange(forSentence: 0))
    let targetSentence = try #require(tokenized.tokenRange(forSentence: 4))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstSentence {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    let prefix = tokenized.tokens[0..<firstSentence.upperBound].map(\.normalized)
    var appended: [String] = []
    for (offset, index) in targetSentence.enumerated() {
        appended.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: (prefix + appended).joined(separator: " "),
            at: 5 + Double(offset) * 0.3
        )
        if appended.count == 4 {
            // Strong, but not yet sustained: must not have jumped to sentence 4.
            #expect((state.sentenceIndex ?? 0) <= 2)
        }
        if appended.count == 5 {
            #expect((state.sentenceIndex ?? 0) <= 2)
        }
    }

    #expect(state.sentenceIndex == 4)
    #expect(targetSentence.contains(state.tokenIndex ?? -1))
}

@Test func followerNeverJumpsBeyondConfirmedForwardWindow() throws {
    let text = """
    Primera frase del guion con palabras claras.
    Segunda frase que nadie llega a leer.
    Tercera frase intermedia del ejemplo.
    Cuarta frase que tampoco se escucha.
    Quinta frase de relleno para el ejemplo.
    Sexta frase de relleno otra vez.
    Septima frase final del guion completo.
    Octava frase que queda demasiado lejos.
    """
    let tokenized = script(text, .spanish)
    let firstSentence = try #require(tokenized.tokenRange(forSentence: 0))
    let farSentence = try #require(tokenized.tokenRange(forSentence: 7))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstSentence {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    let prefix = tokenized.tokens[0..<firstSentence.upperBound].map(\.normalized)
    var appended: [String] = []
    for (offset, index) in farSentence.enumerated() {
        appended.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: (prefix + appended).joined(separator: " "),
            at: 5 + Double(offset) * 0.3
        )
        #expect((state.sentenceIndex ?? 0) <= 2)
    }

    #expect((state.sentenceIndex ?? 0) <= 2)
}

@Test func followerNeverJumpsBackMoreThanOneSentenceButAllowsOne() throws {
    let text = """
    Primera frase del guion con palabras claras.
    Segunda frase que nadie llega a leer.
    Tercera frase intermedia del ejemplo.
    Cuarta frase que tampoco se escucha.
    Quinta frase retomada despues del salto largo.
    Sexta frase para cerrar el ejemplo.
    Septima frase final del guion completo.
    """
    let tokenized = script(text, .spanish)
    let fourthSentence = try #require(tokenized.tokenRange(forSentence: 3))
    let farBack = try #require(tokenized.tokenRange(forSentence: 0))
    let oneBack = try #require(tokenized.tokenRange(forSentence: 3))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    let throughSentenceFour = try #require(
        tokenized.tokenRange(fromSentence: 0, throughSentence: 4)
    )
    for index in throughSentenceFour {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.sentenceIndex == 4)

    state = follower.process(
        text: tokenized.tokens[farBack].map(\.normalized).joined(separator: " "),
        at: 30
    )
    #expect((state.sentenceIndex ?? 0) >= 3)

    state = follower.process(
        text: tokenized.tokens[oneBack].map(\.normalized).joined(separator: " "),
        at: 31
    )
    #expect(state.sentenceIndex == 3)
    #expect(fourthSentence.contains(state.tokenIndex ?? -1))

    // One more backward step would be two sentences behind the furthest point
    // reached, so it must be refused even with perfect evidence.
    let twoBack = try #require(tokenized.tokenRange(forSentence: 2))
    state = follower.process(
        text: tokenized.tokens[twoBack].map(\.normalized).joined(separator: " "),
        at: 32
    )
    #expect(state.sentenceIndex == 3)
}

@Test func followerPrefersNearestAheadWhenAPhraseRepeats() throws {
    let text = """
    Vamos a ver el coche en la pista.
    El coche es rojo y suena muy bien.
    Vamos a ver el coche otra vez.
    """
    let tokenized = script(text, .spanish)
    let throughSecondSentence = try #require(
        tokenized.tokenRange(fromSentence: 0, throughSentence: 1)
    )

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in throughSecondSentence {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.25
        )
    }

    let repeatedPhrase = "vamos a ver el coche"
    state = follower.process(text: repeatedPhrase, at: 20)
    #expect(state.sentenceIndex == 2)
    #expect(state.tokenIndex == 20)

    let stable = follower.process(text: repeatedPhrase, at: 21)
    #expect(stable.tokenIndex == state.tokenIndex)
    #expect(stable.confidence == state.confidence)
}

// MARK: - Follower: revisions and lost state

@Test func followerFollowsPartialHypothesisRevisions() {
    let tokenized = script("Vamos a ver el coche rojo en la pista. Despues seguimos con la prueba.", .spanish)
    var follower = SpeechFollower(script: tokenized)

    _ = follower.process(text: "vamos", at: 0)
    _ = follower.process(text: "vamos a", at: 0.3)
    var state = follower.process(text: "vamos a ver", at: 0.6)
    #expect(state.tokenIndex == 2)

    state = follower.process(text: "vamos a ver el", at: 0.9)
    #expect(state.tokenIndex == 3)

    state = follower.process(text: "vamos a ver el coche", at: 1.2)
    #expect(state.tokenIndex == 4)

    // Wrong revision: the anchor must not jump to the wrong word.
    state = follower.process(text: "vamos a ver el coche rosa", at: 1.5)
    #expect(state.tokenIndex == 4)

    state = follower.process(text: "vamos a ver el coche rojo", at: 1.8)
    #expect(state.tokenIndex == 5)

    state = follower.process(text: "vamos a ver el coche rojo en la pista", at: 2.1)
    #expect(state.tokenIndex == 8)
}

@Test func followerReportsLostAfterSustainedSilenceAndRecovers() {
    let tokenized = script("La prueba empieza ahora mismo. Seguimos con la segunda frase.", .spanish)
    var follower = SpeechFollower(script: tokenized)

    var state = follower.process(text: "la prueba empieza", at: 0)
    #expect(state.tokenIndex == 2)

    state = follower.process(text: "", at: 1)
    #expect(!state.isLost)
    state = follower.process(text: "", at: 2)
    #expect(!state.isLost)
    state = follower.process(text: "", at: 4.1)
    #expect(state.isLost)
    #expect(state.tokenIndex == 2)

    state = follower.process(text: "la prueba empieza ahora mismo", at: 5)
    #expect(!state.isLost)
    #expect(state.tokenIndex == 4)
}

@Test func followerTickDetectsStalledRecognition() {
    let tokenized = script("La prueba empieza ahora mismo. Seguimos con la segunda frase.", .spanish)
    var follower = SpeechFollower(script: tokenized)

    _ = follower.process(text: "la prueba empieza ahora", at: 0)
    var state = follower.tick(at: 2.9)
    #expect(!state.isLost)
    state = follower.tick(at: 3.1)
    #expect(state.isLost)

    state = follower.process(text: "la prueba empieza ahora mismo", at: 4)
    #expect(!state.isLost)
}

@Test func followerHandlesEmptyScriptWithoutCrashing() {
    let tokenized = script("", .spanish)
    var follower = SpeechFollower(script: tokenized)

    let state = follower.process(text: "hola mundo", at: 1)
    #expect(state.tokenIndex == nil)
    #expect(state.utf16Offset == 0)
    #expect(state.confidence == 0)
}
