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

@Test func tokenizerNormalizesDecimalsAndThousands() {
    #expect(script("1,5", .spanish).tokens.map(\.normalized) == ["1.5"])
    #expect(script("1.5", .spanish).tokens.map(\.normalized) == ["1.5"])
    #expect(script("uno coma cinco", .spanish).tokens.map(\.normalized) == ["1.5"])
    #expect(script("1.5", .english).tokens.map(\.normalized) == ["1.5"])
    #expect(script("one point five", .english).tokens.map(\.normalized) == ["1.5"])

    #expect(script("1.500", .spanish).tokens.map(\.normalized) == ["1500"])
    #expect(script("mil quinientos", .spanish).tokens.map(\.normalized) == ["1500"])
    #expect(script("1,500", .english).tokens.map(\.normalized) == ["1500"])
    #expect(script("1.500,25", .spanish).tokens.map(\.normalized) == ["1500.25"])
    #expect(script("cero coma cero cinco", .spanish).tokens.map(\.normalized) == ["0.05"])
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

    // A single newline is a script line boundary too: line-based scripts often
    // omit terminal punctuation.
    let lineBreak = script("Uno\nDos", .spanish)
    #expect(lineBreak.tokens.map(\.sentenceIndex) == [0, 1])

    let abbreviation = script("El Sr. García llega tarde. Otra frase.", .spanish)
    #expect(abbreviation.tokens.map(\.sentenceIndex) == [0, 0, 0, 0, 0, 1, 1])
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

@Test func followerContinuesReadingAfterPauseAcrossSentences() {
    // Exact review script: after a pause the reader adds 12 new words that
    // continue right after the current word. This is reading, not a jump, even
    // though it spans sentences 2 and 3.
    let text = "Hoy probamos el nuevo coche en Monza. La frenada es brutal y el coche gira muy bien. Ahora vamos con la lluvia. En mojado el coche gira muy bien pero hay que frenar antes. Conclusión: merece la pena."
    let tokenized = script(text, .spanish)
    var follower = SpeechFollower(script: tokenized)
    var state = follower.state

    for index in 0...16 {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.tokenIndex == 16)
    #expect(state.sentenceIndex == 1)

    let continuingHypothesis = tokenized.tokens[12...28]
        .map(\.normalized)
        .joined(separator: " ")
    state = follower.process(text: continuingHypothesis, at: 20)

    #expect(state.tokenIndex == 28)
    #expect(state.sentenceIndex == 3)
    #expect(state.matchedWordCount >= 10)
    #expect(!state.isLost)
}

@Test func followerContinuesFromSegmentOnlyHypothesis() {
    let text = "Hoy probamos el nuevo coche en Monza. La frenada es brutal y el coche gira muy bien. Ahora vamos con la lluvia. En mojado el coche gira muy bien pero hay que frenar antes."
    let tokenized = script(text, .spanish)
    var follower = SpeechFollower(script: tokenized)

    for index in 0...16 {
        _ = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    // A new recognition segment contains only the 12 new words.
    let state = follower.process(
        text: "ahora vamos con la lluvia en mojado el coche gira muy bien",
        at: 20,
        segment: 2
    )
    #expect(state.tokenIndex == 28)
    #expect(state.sentenceIndex == 3)
}

@Test func followerKeepsPositionAcrossRecognizerSegmentRestart() {
    let text = "Hoy probamos el nuevo coche en Monza. La frenada es brutal y el coche gira muy bien. Ahora vamos con la lluvia. En mojado el coche gira muy bien pero hay que frenar antes."
    let tokenized = script(text, .spanish)
    var follower = SpeechFollower(script: tokenized)

    var state = follower.state
    for index in 0...16 {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2,
            segment: 1
        )
    }
    #expect(state.tokenIndex == 16)

    // New SFSpeechRecognitionTask, transcript restarts from empty with words
    // from the beginning of the current sentence. The position must not move.
    state = follower.process(text: "la frenada es", at: 20, segment: 2)
    #expect(state.tokenIndex == 16)
    #expect(!state.isLost)

    // Once the new segment reaches the continuation, it advances normally.
    state = follower.process(
        text: "bien ahora vamos con la lluvia en mojado el coche gira muy bien",
        at: 21,
        segment: 2
    )
    #expect(state.tokenIndex == 28)
    #expect(state.sentenceIndex == 3)
}

@Test func followerDoesNotJitterBackwardsOnShortRevision() {
    let text = "Hoy probamos el nuevo coche en Monza. La frenada es brutal y el coche gira muy bien. Ahora vamos con la lluvia."
    let tokenized = script(text, .spanish)
    var follower = SpeechFollower(script: tokenized)

    var state = follower.state
    for index in 0...16 {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.tokenIndex == 16)

    // Three words of a revised partial, confidence exactly 0.6 before the fix.
    state = follower.process(text: "la frenada es", at: 20)
    #expect(state.tokenIndex == 16)
    #expect(state.confidence < 0.85)
}

@Test func followerRecoversAfterSkippingManySentences() throws {
    let lines = [
        "El motor suena limpio en la recta principal.",
        "La suspensión absorbe los pianos sin brusquedad.",
        "Los frenos aguantan vueltas y vueltas.",
        "El volante transmite cada bache del asfalto.",
        "La caja de cambios encaja con precisión.",
        "Los neumáticos blandos se calientan deprisa.",
        "El alerón trasero genera carga estable.",
        "La telemetría muestra una diferencia mínima.",
        "El sector dos castiga la tracción.",
        "La lluvia cambia por completo el agarre.",
        "El depósito va lleno para esta tanda.",
        "La conclusión merece una vuelta más."
    ]
    let tokenized = script(lines.joined(separator: "\n"), .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let targetLine = try #require(tokenized.tokenRange(forSentence: 9))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.sentenceIndex == 0)

    var spoken: [String] = []
    for (offset, index) in targetLine.enumerated() {
        spoken.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: spoken.joined(separator: " "),
            at: 10 + Double(offset) * 0.4
        )
    }

    #expect(state.sentenceIndex == 9)
    #expect(targetLine.contains(state.tokenIndex ?? -1))
    #expect(!state.isLost)
}

@Test func followerStillRejectsJumpsBeyondRecoveryWindow() throws {
    let lines = (0..<16).map { index in
        switch index {
        case 0: "El motor suena limpio en la recta principal."
        case 1: "La suspensión absorbe los pianos sin brusquedad."
        case 2: "Los frenos aguantan vueltas y vueltas."
        case 3: "El volante transmite cada bache del asfalto."
        case 4: "La caja de cambios encaja con precisión."
        case 5: "Los neumáticos blandos se calientan deprisa."
        case 6: "El alerón trasero genera carga estable."
        case 7: "La telemetría muestra una diferencia mínima."
        case 8: "El sector dos castiga la tracción."
        case 9: "La lluvia cambia por completo el agarre."
        case 10: "El depósito va lleno para esta tanda."
        case 11: "La conclusión merece una vuelta más."
        case 12: "El chasis responde sin retardo."
        case 13: "La dirección pesa lo justo."
        case 14: "El escape suena ronco arriba."
        default: "La bandera cae y termina."
        }
    }
    let tokenized = script(lines.joined(separator: "\n"), .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let farLine = try #require(tokenized.tokenRange(forSentence: 13))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    var spoken: [String] = []
    for (offset, index) in farLine.enumerated() {
        spoken.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: spoken.joined(separator: " "),
            at: 10 + Double(offset) * 0.4
        )
    }

    #expect((state.sentenceIndex ?? 0) <= 2)
}

@Test func followerResolvesRepeatedPhraseAfterALongSkip() throws {
    let text = """
    Vamos a ver el coche en la pista de Monza.
    Primera frase distinta del ejemplo.
    Segunda frase distinta del ejemplo.
    Tercera frase distinta del ejemplo.
    Cuarta frase distinta del ejemplo.
    Quinta frase distinta del ejemplo.
    Sexta frase distinta del ejemplo.
    Septima frase distinta del ejemplo.
    Octava frase distinta del ejemplo.
    Vamos a ver el coche en la pista de Monza con lluvia y neumáticos nuevos.
    """
    let tokenized = script(text, .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let targetLine = try #require(tokenized.tokenRange(forSentence: 9))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.1
        )
    }

    var spoken: [String] = []
    for (offset, index) in targetLine.enumerated() {
        spoken.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: spoken.joined(separator: " "),
            at: 10 + Double(offset) * 0.4
        )
    }

    #expect(state.sentenceIndex == 9)
    #expect(targetLine.contains(state.tokenIndex ?? -1))
}

@Test func followerResolvesFarRepeatedPhraseByCoverage() throws {
    let text = """
    Vamos a ver el coche en la pista de Monza.
    Primera frase distinta del ejemplo.
    Segunda frase distinta del ejemplo.
    Tercera frase distinta del ejemplo.
    Vamos a ver el coche en la pista de Monza con lluvia y neumáticos nuevos.
    """
    let tokenized = script(text, .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let targetLine = try #require(tokenized.tokenRange(forSentence: 4))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.1
        )
    }

    var spoken: [String] = []
    for (offset, index) in targetLine.enumerated() {
        spoken.append(tokenized.tokens[index].normalized)
        state = follower.process(
            text: spoken.joined(separator: " "),
            at: 10 + Double(offset) * 0.4
        )
    }

    #expect(state.sentenceIndex == 4)
    #expect(targetLine.contains(state.tokenIndex ?? -1))
}

@Test func followerRespectsLinesInUnpunctuatedScripts() throws {
    let text = """
    linea uno con palabras claras
    otra linea distinta aqui
    tercera linea del guion
    cuarta linea del ejemplo
    quinta linea retomada
    sexta linea final
    """
    let tokenized = script(text, .spanish)
    #expect(tokenized.sentenceCount == 6)

    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let fifthLine = try #require(tokenized.tokenRange(forSentence: 4))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }
    #expect(state.sentenceIndex == 0)

    state = follower.process(
        text: tokenized.tokens[fifthLine].map(\.normalized).joined(separator: " "),
        at: 5
    )
    #expect((state.sentenceIndex ?? 0) <= 2)
}

@Test func followerDoesNotJumpAcrossManyUnpunctuatedLines() throws {
    var lines: [String] = []
    for index in 0..<30 {
        if index == 0 || index == 29 {
            lines.append("vamos a ver el coche en la pista numero \(index) con calma")
        } else {
            lines.append("linea \(index) con palabras distintas del ejemplo")
        }
    }
    let tokenized = script(lines.joined(separator: "\n"), .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let lastLine = try #require(tokenized.tokenRange(forSentence: 29))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    let temptingPhrase = tokenized.tokens[lastLine]
        .prefix(6)
        .map(\.normalized)
        .joined(separator: " ")
    state = follower.process(text: temptingPhrase, at: 5)

    #expect((state.sentenceIndex ?? 0) <= 2)
    #expect((state.tokenIndex ?? 0) < 100)
}

@Test func followerRequiresStrongMatchForTwoSentenceJump() throws {
    let text = """
    El motor suena limpio en la recta principal.
    La suspensión absorbe los pianos sin brusquedad.
    Los frenos aguantan vueltas y vueltas.
    El volante transmite cada bache del asfalto.
    La caja de cambios encaja con precisión.
    """
    let tokenized = script(text, .spanish)
    let firstLine = try #require(tokenized.tokenRange(forSentence: 0))
    let thirdLine = try #require(tokenized.tokenRange(forSentence: 2))

    var follower = SpeechFollower(script: tokenized)
    var state = follower.state
    for index in firstLine {
        state = follower.process(
            text: cumulativeTranscript(tokenized.tokens, through: index),
            at: Double(index) * 0.2
        )
    }

    let firstThree = tokenized.tokens[thirdLine].prefix(3).map(\.normalized)
    state = follower.process(text: firstThree.joined(separator: " "), at: 10)
    #expect((state.sentenceIndex ?? 0) <= 2)

    let firstFive = tokenized.tokens[thirdLine].prefix(5).map(\.normalized)
    state = follower.process(text: firstFive.joined(separator: " "), at: 10.4)
    #expect(state.sentenceIndex == 2)
}

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
