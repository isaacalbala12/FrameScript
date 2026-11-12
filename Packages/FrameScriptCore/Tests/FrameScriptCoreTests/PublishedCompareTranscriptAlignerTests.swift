import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Published compare – transcript alignment")
struct PublishedCompareTranscriptAlignerTests {
    private func segment(_ text: String, start: Double, end: Double) -> SubtitleSegment {
        SubtitleSegment(start: start, end: end, text: text)
    }

    @Test func normalizesScriptMarkupAndDiacritics() {
        #expect(ScriptNormalizer.normalize("Hola / [risas] *mundo* // adiós") == ["hola", "mundo", "adios"])
        #expect(ScriptNormalizer.normalize("¡Análisis! / F1 2026") == ["analisis", "f1", "2026"])
        #expect(ScriptNormalizer.normalize("[...] AC/EVO — *importante*") == ["ac", "evo", "importante"])
    }

    @Test func exactTranscriptAlignsAllScenes() {
        let scenes = [
            SceneScript(id: "s1", text: "Hola bienvenidos al canal"),
            SceneScript(id: "s2", text: "Hoy probamos el nuevo mod"),
            SceneScript(id: "s3", text: "Vamos a la pista")
        ]
        let transcript = [
            segment("Hola bienvenidos al canal", start: 0, end: 2),
            segment("Hoy probamos el nuevo mod", start: 2, end: 5),
            segment("Vamos a la pista", start: 5, end: 7)
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)

        #expect(alignment.scenes.count == 3)
        #expect(alignment.scenes.allSatisfy { $0.coverage == 1 })
        #expect(alignment.scenes.allSatisfy { !$0.timingIsEstimated })
        #expect(approximatelyEqual(alignment.scenes[0].start, 0))
        #expect(approximatelyEqual(alignment.scenes[0].end, 2))
        #expect(approximatelyEqual(alignment.scenes[1].start, 2))
        #expect(approximatelyEqual(alignment.scenes[1].end, 5))
        #expect(approximatelyEqual(alignment.scenes[2].start, 5))
        #expect(approximatelyEqual(alignment.scenes[2].end, 7))
        #expect(alignment.totalMatchedWords == 13)
        #expect(alignment.totalAddedWords == 0)
        #expect(alignment.totalRemovedWords == 0)
    }

    @Test func adLibCountsAsAddedAndBecomesDeviation() {
        let scenes = [SceneScript(id: "s1", text: "hoy probamos el nuevo mod en el circuito")]
        let transcript = [
            segment("hoy probamos el nuevo mod que me acabo de descargar ayer en el circuito", start: 0, end: 5)
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)
        let scene = alignment.scenes[0]

        #expect(scene.scriptWordCount == 8)
        #expect(scene.matchedWordCount == 8)
        #expect(scene.addedWordCount == 6)
        #expect(scene.removedWordCount == 0)
        #expect(scene.coverage == 1)
        #expect(scene.deviations.count == 1)
        #expect(scene.deviations[0].kind == .inserted)
        #expect(scene.deviations[0].wordCount == 6)
        #expect(scene.deviations[0].text.contains("acabo"))
    }

    @Test func cutCountsAsRemovedAndBecomesDeviation() {
        let scenes = [SceneScript(id: "s1", text: "vamos a la pista y hacemos una vuelta rápida")]
        let transcript = [segment("vamos a la pista", start: 0, end: 2)]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)
        let scene = alignment.scenes[0]

        #expect(scene.scriptWordCount == 9)
        #expect(scene.matchedWordCount == 4)
        #expect(scene.removedWordCount == 5)
        #expect(scene.addedWordCount == 0)
        #expect(approximatelyEqual(scene.coverage, 4.0 / 9.0))
        #expect(scene.deviations.count == 1)
        #expect(scene.deviations[0].kind == .removed)
        #expect(scene.deviations[0].wordCount == 5)
        #expect(scene.deviations[0].text.contains("vuelta"))
    }

    @Test func substitutionCountsOnBothSides() {
        let scenes = [SceneScript(id: "s1", text: "el coche rojo")]
        let transcript = [segment("el auto rojo", start: 1, end: 3)]

        let alignment = TranscriptAligner(minimumDeviationWordCount: 1)
            .align(scenes: scenes, transcript: transcript)
        let scene = alignment.scenes[0]

        #expect(scene.matchedWordCount == 2)
        #expect(scene.addedWordCount == 1)
        #expect(scene.removedWordCount == 1)
        #expect(approximatelyEqual(scene.coverage, 2.0 / 3.0))
        #expect(scene.deviations.contains { $0.kind == .inserted && $0.text == "auto" })
        #expect(scene.deviations.contains { $0.kind == .removed && $0.text == "coche" })
    }

    @Test func fullyCutSceneGetsEstimatedTiming() {
        let scenes = [
            SceneScript(id: "s1", text: "primera escena"),
            SceneScript(id: "s2", text: "bloque suprimido del todo"),
            SceneScript(id: "s3", text: "tercera escena")
        ]
        let transcript = [
            segment("primera escena", start: 0, end: 2),
            segment("tercera escena", start: 2, end: 4)
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)
        let cut = alignment.scenes[1]

        #expect(cut.coverage == 0)
        #expect(cut.removedWordCount == 4)
        #expect(cut.addedWordCount == 0)
        #expect(cut.timingIsEstimated)
        #expect(approximatelyEqual(cut.start, 2))
        #expect(approximatelyEqual(cut.end, 2))
        #expect(approximatelyEqual(alignment.scenes[2].start, 2))
    }

    @Test func scriptMarkupDoesNotAffectMatching() {
        let scenes = [SceneScript(id: "s1", text: "Hola / [risas] *mundo* // adiós")]
        let transcript = [segment("hola mundo adios", start: 0, end: 2)]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)

        #expect(alignment.scenes[0].scriptWordCount == 3)
        #expect(alignment.scenes[0].matchedWordCount == 3)
        #expect(alignment.scenes[0].coverage == 1)
    }

    @Test func repeatedWordsDoNotInflateCoverage() {
        let scenes = [SceneScript(id: "s1", text: "no no no vamos")]
        let transcript = [segment("no vamos", start: 0, end: 1)]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)
        let scene = alignment.scenes[0]

        #expect(scene.matchedWordCount == 2)
        #expect(scene.removedWordCount == 2)
        #expect(approximatelyEqual(scene.coverage, 0.5))
    }

    @Test func emptyScriptSceneHasFullCoverage() {
        let scenes = [
            SceneScript(id: "s1", text: ""),
            SceneScript(id: "s2", text: "hola mundo")
        ]
        let transcript = [segment("hola mundo", start: 0, end: 2)]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)

        #expect(alignment.scenes[0].scriptWordCount == 0)
        #expect(alignment.scenes[0].coverage == 1)
        #expect(alignment.scenes[1].coverage == 1)
        #expect(approximatelyEqual(alignment.scenes[1].start, 0))
        #expect(approximatelyEqual(alignment.scenes[1].end, 2))
    }

    @Test func emptyTranscriptYieldsZeroCoverageAndNoTiming() {
        let scenes = [
            SceneScript(id: "s1", text: "hola mundo"),
            SceneScript(id: "s2", text: "otra escena")
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: [])

        #expect(alignment.coverage == 0)
        #expect(alignment.scenes.allSatisfy { $0.coverage == 0 })
        #expect(alignment.scenes.allSatisfy { $0.start == nil && $0.end == nil })
        #expect(alignment.scenes.allSatisfy { $0.timingIsEstimated })
    }

    @Test func globalTotalsMatchSceneTotals() {
        let scenes = [
            SceneScript(id: "s1", text: "uno dos tres"),
            SceneScript(id: "s2", text: "cuatro cinco seis")
        ]
        let transcript = [
            segment("uno dos tres cuatro cinco seis extra words", start: 0, end: 4)
        ]

        let alignment = TranscriptAligner().align(scenes: scenes, transcript: transcript)

        #expect(alignment.totalScriptWords == 6)
        #expect(alignment.totalMatchedWords == 6)
        #expect(alignment.totalAddedWords == 2)
        #expect(alignment.totalRemovedWords == 0)
        #expect(alignment.scenes.reduce(0) { $0 + $1.addedWordCount } == 2)
        #expect(alignment.scenes.reduce(0) { $0 + $1.matchedWordCount } == 6)
    }

    @Test func alignsLongAdLibWithAnchorSplitting() {
        let sceneCount = 40
        let wordsPerScene = 10
        var scenes: [SceneScript] = []
        var transcriptWords: [String] = []

        for sceneIndex in 0..<sceneCount {
            var words: [String] = []
            for wordIndex in 0..<wordsPerScene {
                let word = "s\(sceneIndex)w\(wordIndex)"
                words.append(word)
                transcriptWords.append(word)
            }
            scenes.append(SceneScript(id: "s\(sceneIndex)", text: words.joined(separator: " ")))
        }

        let adLib = (0..<300).map { "adlib\($0)" }
        transcriptWords.insert(contentsOf: adLib, at: 20 * wordsPerScene)
        let transcript = [
            segment(transcriptWords.joined(separator: " "), start: 0, end: 100)
        ]

        // Force the anchor path: the full DP matrix would be 400 × 700 cells.
        let aligner = TranscriptAligner(maximumDynamicProgrammingCells: 10_000)
        let alignment = aligner.align(scenes: scenes, transcript: transcript)

        #expect(alignment.totalScriptWords == 400)
        #expect(alignment.totalMatchedWords == 400)
        #expect(alignment.totalAddedWords == 300)
        #expect(alignment.coverage == 1)
        #expect(alignment.scenes[19].addedWordCount == 150)
        #expect(alignment.scenes[20].addedWordCount == 150)
        #expect((alignment.scenes[19].end ?? 0) <= (alignment.scenes[20].start ?? 0))
    }
}
