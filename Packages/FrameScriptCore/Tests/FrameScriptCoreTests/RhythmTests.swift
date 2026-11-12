import Foundation
import Testing
@testable import FrameScriptCore

@Suite("RhythmSentenceSplitter")
struct RhythmSentenceSplitterTests {
    @Test func spanishQuestionAndExclamationMarks() {
        #expect(sentenceTexts("¿Qué pasa? Nada. ¡Vamos! Bien… Fin.") == [
            "¿Qué pasa?", "Nada.", "¡Vamos!", "Bien…", "Fin."
        ])
    }

    @Test func questionAndExclamationWithoutSpaces() {
        #expect(sentenceTexts("¿Qué?¡Vamos!") == ["¿Qué?", "¡Vamos!"])
    }

    @Test func abbreviationsDoNotSplit() {
        #expect(sentenceTexts("Hablé con el Sr. García. Luego me fui.") == [
            "Hablé con el Sr. García.", "Luego me fui."
        ])
        #expect(sentenceTexts("Trae p. ej. dos cosas. Gracias.") == [
            "Trae p. ej. dos cosas.", "Gracias."
        ])
        #expect(sentenceTexts("Terminó etc. y siguió. Vale.") == [
            "Terminó etc. y siguió.", "Vale."
        ])
    }

    @Test func decimalsAndUnitsDoNotSplit() {
        #expect(sentenceTexts("Cuesta 3.5 euros. Es caro.") == [
            "Cuesta 3.5 euros.", "Es caro."
        ])
        #expect(sentenceTexts("Velocidad de 120 km/h. Después frenó.") == [
            "Velocidad de 120 km/h.", "Después frenó."
        ])
        #expect(sentenceTexts("Son 1.000.000 de vueltas. Increíble.") == [
            "Son 1.000.000 de vueltas.", "Increíble."
        ])
    }

    @Test func initialsDoNotSplit() {
        #expect(sentenceTexts("Fue idea de J. García. Después se supo.") == [
            "Fue idea de J. García.", "Después se supo."
        ])
    }

    @Test func ellipsisOnlySplitsBeforeANewSentence() {
        #expect(sentenceTexts("Espera... y sigue la frase. Otra.") == [
            "Espera... y sigue la frase.", "Otra."
        ])
        #expect(sentenceTexts("Dudó… Luego decidió.") == [
            "Dudó…", "Luego decidió."
        ])
    }

    @Test func markupCuesAreIgnored() {
        #expect(sentenceTexts("[pausa 2 s] Hola. [B-roll: coche]. Adiós.") == [
            "Hola.", "Adiós."
        ])
        #expect(sentenceTexts("[corte. 3 s] Hola mundo.") == ["Hola mundo."])
    }

    @Test func wordCountExcludesMarkup() {
        let sentences = RhythmSentenceSplitter.sentences(in: "[pausa 5 s] Hola mundo.")
        #expect(sentences.count == 1)
        #expect(sentences.first?.wordCount == 2)
    }

    @Test func accentedWordsAndEmojiAreCountedSafely() {
        let sentences = RhythmSentenceSplitter.sentences(in: "El niño 👋 come piña.")
        #expect(sentences.count == 1)
        #expect(sentences.first?.wordCount == 4)
    }

    @Test func singleLineBreakDoesNotSplitButBlankLineDoes() {
        #expect(sentenceTexts("Uno\ndos\n\nTres.") == ["Uno\ndos", "Tres."])
    }

    @Test func emptyAndWhitespaceOnlyTexts() {
        #expect(RhythmSentenceSplitter.sentences(in: "").isEmpty)
        #expect(RhythmSentenceSplitter.sentences(in: "   \n\n  ").isEmpty)
    }

    @Test func rangesSliceTheOriginalText() {
        let text = "¿Qué pasa? Nada. ¡Vamos!"
        let ns = text as NSString
        for sentence in RhythmSentenceSplitter.sentences(in: text) {
            let slice = ns.substring(
                with: NSRange(location: sentence.range.location, length: sentence.range.length)
            )
            #expect(slice == sentence.text)
        }
    }

    private func sentenceTexts(_ text: String) -> [String] {
        RhythmSentenceSplitter.sentences(in: text).map(\.text)
    }
}

@Suite("RhythmAnalyzer")
struct RhythmAnalyzerTests {
    @Test func longSentenceByWordCount() {
        let text = (1...30).map { "palabra\($0)" }.joined(separator: " ") + "."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 1_000)
        )
        let warnings = analysis.warnings.filter { $0.kind == .longSentence }
        #expect(warnings.count == 1)
        let warning = warnings[0]
        #expect(warning.messageKey == RhythmMessageKey.longSentence)
        #expect(warning.range == analysis.sentences.first?.range)
        #expect(argument("words", in: warning) == 30)
        #expect(argument("maxWords", in: warning) == 25)
    }

    @Test func longSentenceByDuration() {
        let text = "Uno dos tres."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 10)
        )
        let warnings = analysis.warnings.filter { $0.kind == .longSentence }
        #expect(warnings.count == 1)
        #expect(argument("words", in: warnings[0]) == 3)
        #expect(abs((argument("seconds", in: warnings[0]) ?? 0) - 18) < 0.001)
        #expect(abs((argument("maxSeconds", in: warnings[0]) ?? 0) - 9) < 0.001)
    }

    @Test func shortSentenceDoesNotWarn() {
        let text = "El coche gira."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 150)
        )
        #expect(analysis.warnings.filter { $0.kind == .longSentence }.isEmpty)
    }

    @Test func narrationWithoutVisualChangeWarns() {
        let words = (1...10).map { "palabra\($0)" }
        let text = words.joined(separator: " ") + "."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 60)
        )
        let warnings = analysis.warnings.filter { $0.kind == .noVisualChange }
        #expect(warnings.count == 1)
        #expect(warnings[0].range == UTF16Span(location: 0, length: (text as NSString).length))
        #expect(abs((argument("seconds", in: warnings[0]) ?? 0) - 10) < 0.001)
    }

    @Test func visualAnchorsSplitTheStretch() {
        let words = (1...20).map { "palabra\($0)" }
        let text = words.joined(separator: " ") + "."
        var offset = 0
        for word in words.prefix(10) {
            offset += word.utf16.count + 1
        }
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(
                id: "s1",
                text: text,
                wordsPerMinute: 60,
                visualChangeOffsets: [offset]
            )
        )
        let warnings = analysis.warnings.filter { $0.kind == .noVisualChange }
        #expect(warnings.count == 2)
        #expect(warnings.allSatisfy { $0.range.length > 0 })
    }

    @Test func anchorsAreClampedSortedAndDeduplicated() {
        let text = "El coche gira en la curva y frena con precisión."
        let length = (text as NSString).length
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(
                id: "s1",
                text: text,
                wordsPerMinute: 120,
                visualChangeOffsets: [length + 100, -5, 0, 20, 20, 40]
            )
        )
        for warning in analysis.warnings {
            #expect(warning.range.location >= 0)
            #expect(warning.range.end <= length)
        }
    }

    @Test func hookOverFifteenSecondsWarns() {
        let text = (1...10).map { "palabra\($0)" }.joined(separator: " ") + "."
        let atLimit = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "hook", text: text, wordsPerMinute: 40, role: .hook)
        )
        #expect(atLimit.warnings.filter { $0.kind == .longHook }.isEmpty)

        let overLimit = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "hook", text: text, wordsPerMinute: 39, role: .hook)
        )
        let warnings = overLimit.warnings.filter { $0.kind == .longHook }
        #expect(warnings.count == 1)
        #expect(abs((argument("seconds", in: warnings[0]) ?? 0) - 15.3846) < 0.01)
    }

    @Test func normalSceneDoesNotGetAHookWarning() {
        let text = (1...40).map { "palabra\($0)" }.joined(separator: " ") + "."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 40, role: .normal)
        )
        #expect(analysis.warnings.filter { $0.kind == .longHook }.isEmpty)
    }

    @Test func pauseProviderAddsSeconds() {
        let text = "Uno dos tres cuatro cinco."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 60),
            pauseDuration: { range in range.length > 0 ? 5 : 0 }
        )
        let warnings = analysis.warnings.filter { $0.kind == .longSentence }
        #expect(warnings.count == 1)
        #expect(abs((argument("seconds", in: warnings[0]) ?? 0) - 10) < 0.001)
    }

    @Test func markupIsNotCountedAsWords() {
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: "[pausa 3 s] Hola mundo.", wordsPerMinute: 60)
        )
        #expect(analysis.wordCount == 2)
        #expect(analysis.warnings.filter { $0.kind == .longSentence }.isEmpty)
    }

    @Test func invalidWPMDisablesTimeWarnings() {
        let text = "Uno dos tres."
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 0, role: .hook)
        )
        #expect(analysis.durationSeconds == 0)
        #expect(analysis.warnings.isEmpty)
    }

    @Test func emptySceneIsSafe() {
        let analysis = RhythmAnalyzer.analyze(
            scene: RhythmSceneInput(id: "empty", text: "", wordsPerMinute: 150, role: .hook)
        )
        #expect(analysis.sentences.isEmpty)
        #expect(analysis.wordCount == 0)
        #expect(analysis.warnings.isEmpty)
    }

    @Test func projectOutlierUsesAverageAndFactor() {
        let short = (1...10).map { "palabra\($0)" }.joined(separator: " ") + "."
        let long = (1...40).map { "palabra\($0)" }.joined(separator: " ") + "."
        let project = RhythmAnalyzer.analyzeProject(scenes: [
            RhythmSceneInput(id: "s1", text: short, wordsPerMinute: 60),
            RhythmSceneInput(id: "s2", text: short, wordsPerMinute: 60),
            RhythmSceneInput(id: "s3", text: long, wordsPerMinute: 60)
        ])
        #expect(project.projectWarnings.count == 1)
        #expect(project.projectWarnings[0].sceneID == "s3")
        #expect(project.projectWarnings[0].kind == .sceneLengthOutlier)
        #expect(abs((argument("average", in: project.projectWarnings[0]) ?? 0) - 20) < 0.001)
        #expect(abs((argument("factor", in: project.projectWarnings[0]) ?? 0) - 1.8) < 0.001)
    }

    @Test func projectWithUniformScenesHasNoOutliers() {
        let text = (1...10).map { "palabra\($0)" }.joined(separator: " ") + "."
        let project = RhythmAnalyzer.analyzeProject(scenes: [
            RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 60),
            RhythmSceneInput(id: "s2", text: text, wordsPerMinute: 60)
        ])
        #expect(project.projectWarnings.isEmpty)
    }

    @Test func singleSceneProjectSkipsOutliers() {
        let text = (1...10).map { "palabra\($0)" }.joined(separator: " ") + "."
        let project = RhythmAnalyzer.analyzeProject(scenes: [
            RhythmSceneInput(id: "s1", text: text, wordsPerMinute: 60)
        ])
        #expect(project.projectWarnings.isEmpty)
    }

    @Test func thresholdsDecodePartiallyAndRoundTrip() throws {
        let partial = Data(#"{"maxSentenceWords": 10}"#.utf8)
        let decoded = try JSONDecoder().decode(RhythmThresholds.self, from: partial)
        #expect(decoded.maxSentenceWords == 10)
        #expect(decoded.maxSentenceSeconds == 9)
        #expect(decoded.maxSecondsWithoutVisualChange == 5)
        #expect(decoded.hookMaxSeconds == 15)
        #expect(decoded.sceneLengthOutlierFactor == 1.8)

        let custom = RhythmThresholds(
            maxSentenceWords: 18,
            maxSentenceSeconds: 7,
            maxSecondsWithoutVisualChange: 4,
            hookMaxSeconds: 12,
            sceneLengthOutlierFactor: 2.1
        )
        let encoded = try JSONEncoder().encode(custom)
        let roundTripped = try JSONDecoder().decode(RhythmThresholds.self, from: encoded)
        #expect(roundTripped == custom)
    }

    @Test func warningIDsAreStable() {
        let text = (1...30).map { "palabra\($0)" }.joined(separator: " ") + "."
        let first = RhythmAnalyzer.analyze(scene: RhythmSceneInput(id: "s1", text: text))
        let second = RhythmAnalyzer.analyze(scene: RhythmSceneInput(id: "s1", text: text))
        #expect(first.warnings.map(\.id) == second.warnings.map(\.id))
        #expect(!first.warnings[0].messageKey.isEmpty)
    }

    @Test func sceneInputIsCodable() throws {
        let input = RhythmSceneInput(
            id: "s1",
            text: "Hola.",
            wordsPerMinute: 140,
            visualChangeOffsets: [2, 4],
            role: .hook
        )
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(RhythmSceneInput.self, from: data)
        #expect(decoded == input)
    }

    private func argument(_ name: String, in warning: RhythmWarning) -> Double? {
        warning.arguments.first { $0.name == name }?.value
    }
}
