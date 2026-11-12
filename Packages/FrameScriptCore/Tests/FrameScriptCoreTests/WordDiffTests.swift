import Foundation
import Testing
@testable import FrameScriptCore

@Suite("WordDiff")
struct WordDiffTests {
    // MARK: - Basic cases

    @Test func identicalTextsProduceOneEqualOp() {
        let text = "El niño comió piña."
        let ops = WordDiff.diff(old: text, new: text)
        #expect(ops.count == 1)
        #expect(ops.first?.kind == .equal)
        #expect(ops.first?.oldRange == UTF16Span(location: 0, length: (text as NSString).length))
        verify(ops, old: text, new: text)
    }

    @Test func emptyInputs() {
        #expect(WordDiff.diff(old: "", new: "").isEmpty)

        let inserted = WordDiff.diff(old: "", new: "Hola")
        #expect(inserted.count == 1)
        #expect(inserted.first?.kind == .insert)
        #expect(inserted.first?.changedText == "Hola")
        verify(inserted, old: "", new: "Hola")

        let deleted = WordDiff.diff(old: "Hola", new: "")
        #expect(deleted.count == 1)
        #expect(deleted.first?.kind == .delete)
        #expect(deleted.first?.changedText == "Hola")
        verify(deleted, old: "Hola", new: "")
    }

    @Test func singleWordInsert() {
        let old = "El coche rojo"
        let new = "El coche muy rojo"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .insert && $0.changedText == "muy " })
    }

    @Test func singleWordDelete() {
        let old = "El coche muy rojo"
        let new = "El coche rojo"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .delete && $0.changedText == "muy " })
    }

    @Test func wordReplacement() {
        let old = "El niño comió piña"
        let new = "El niño bebió piña"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .delete && $0.changedText == "comió " })
        #expect(ops.contains { $0.kind == .insert && $0.changedText == "bebió " })
    }

    @Test func punctuationChange() {
        let old = "Hola, mundo."
        let new = "Hola; mundo!"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .delete })
        #expect(ops.contains { $0.kind == .insert })
    }

    @Test func multilineParagraphs() {
        let old = """
        Intro.

        El niño comió piña en la playa.
        Luego volvió a casa.

        Fin.
        """
        let new = """
        Intro.

        El niño comió sandía en la playa.
        Luego volvió a casa.

        Fin.
        """
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.count < 10)
    }

    @Test func insertionOfWholeParagraph() {
        let old = "Primero.\n\nTercero."
        let new = "Primero.\n\nSegundo.\n\nTercero."
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .insert })
    }

    @Test func deletionOfWholeParagraph() {
        let old = "Primero.\n\nSegundo.\n\nTercero."
        let new = "Primero.\n\nTercero."
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .delete })
    }

    // MARK: - Unicode

    @Test func spanishAccentsArePreserved() {
        let old = "¿Qué tal? El niño comió piña y acción."
        let new = "¿Qué tal? El niño comió piñones y acción."
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.allSatisfy { $0.oldRange.location >= 0 && $0.newRange.location >= 0 })
    }

    @Test func emojiRangesFallOnGraphemeBoundaries() {
        let old = "Hola 👋 mundo 🇪🇸"
        let new = "Hola 👋🏽‍♂️ mundo 🇪🇸🌍"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)

        let oldBoundaries = graphemeBoundaries(in: old)
        let newBoundaries = graphemeBoundaries(in: new)
        for op in ops {
            #expect(oldBoundaries.contains(op.oldRange.location))
            #expect(oldBoundaries.contains(op.oldRange.end))
            #expect(newBoundaries.contains(op.newRange.location))
            #expect(newBoundaries.contains(op.newRange.end))
        }
    }

    @Test func onlyWhitespaceChanges() {
        let old = "uno  dos\ttres"
        let new = "uno dos tres"
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
    }

    @Test func windowsLineEndings() {
        let old = "Uno.\r\nDos.\r\nTres."
        let new = "Uno.\r\nDos y medio.\r\nTres."
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
    }

    // MARK: - Property tests

    @Test func randomMutationsAlwaysReconstruct() {
        var rng = LCG(state: 0xDEAD_BEEF_1234)
        let vocabulary = [
            "hola", "mundo", "niño", "piña", "acción", "¿qué?", "¡sí!", "coche",
            "de", "la", "😀", "🎬", "v1.2", "etc.", "[pausa]", "a", "b", "c",
            "Señor", "km/h", "3.5", "canción"
        ]
        let separators = [" ", " ", " ", "  ", "\n", "\n\n", "\t"]

        for iteration in 0..<300 {
            let old = randomText(vocabulary: vocabulary, separators: separators, rng: &rng)
            let new = randomMutation(of: old, vocabulary: vocabulary, separators: separators, rng: &rng)
            let ops = WordDiff.diff(old: old, new: new)
            verify(ops, old: old, new: new, context: "iteration \(iteration)")
        }
    }

    @Test func fullyDifferentTextsFallBackCorrectly() {
        let old = (0..<1_500).map { "viejo\($0)" }.joined(separator: " ")
        let new = (0..<1_500).map { "nuevo\($0)" }.joined(separator: " ")
        let ops = WordDiff.diff(old: old, new: new)
        verify(ops, old: old, new: new)
        #expect(ops.contains { $0.kind == .delete })
        #expect(ops.contains { $0.kind == .insert })
    }

    // MARK: - Performance

    @Test func performance20kWordsAcrossParagraphs() {
        let (old, new) = makeParagraphDocument(wordCount: 20_000)

        let clock = ContinuousClock()
        var ops: [DiffOp] = []
        let elapsed = clock.measure {
            ops = WordDiff.diff(old: old, new: new)
        }
        print("WordDiff 20k words (2k paragraphs): \(elapsed), \(ops.count) ops")

        verify(ops, old: old, new: new)
        #expect(elapsed < .seconds(10))
        #expect(ops.count < 200)
    }

    @Test func performance20kWordsSingleParagraph() {
        let words = (0..<20_000).map { "palabra\($0)" }
        let old = words.joined(separator: " ")
        var changed = words
        for index in stride(from: 500, to: changed.count, by: 3_500) {
            changed[index] = "cambiada\(index)"
        }
        let new = changed.joined(separator: " ")

        let clock = ContinuousClock()
        var ops: [DiffOp] = []
        let elapsed = clock.measure {
            ops = WordDiff.diff(old: old, new: new)
        }
        print("WordDiff 20k words (single paragraph): \(elapsed), \(ops.count) ops")

        verify(ops, old: old, new: new)
        #expect(elapsed < .seconds(10))
        #expect(ops.count < 100)
    }

    // MARK: - Helpers

    private func verify(
        _ ops: [DiffOp],
        old: String,
        new: String,
        context: String = ""
    ) {
        let nsOld = old as NSString
        let nsNew = new as NSString

        #expect(WordDiff.apply(ops, to: old) == new, "\(context): apply(old) must equal new")

        var oldCursor = 0
        var newCursor = 0
        for op in ops {
            #expect(
                op.oldRange.location == oldCursor,
                "\(context): old ranges must be contiguous"
            )
            #expect(
                op.newRange.location == newCursor,
                "\(context): new ranges must be contiguous"
            )
            switch op.kind {
            case .equal:
                #expect(op.oldRange.length == op.newRange.length, "\(context): equal lengths")
                let oldSlice = nsOld.substring(
                    with: NSRange(location: op.oldRange.location, length: op.oldRange.length)
                )
                let newSlice = nsNew.substring(
                    with: NSRange(location: op.newRange.location, length: op.newRange.length)
                )
                #expect(oldSlice == newSlice, "\(context): equal text must match")
                #expect(op.changedText == nil)
            case .insert:
                #expect(op.oldRange.length == 0, "\(context): insert has empty old range")
                #expect(op.newRange.length > 0, "\(context): insert has non-empty new range")
                let newSlice = nsNew.substring(
                    with: NSRange(location: op.newRange.location, length: op.newRange.length)
                )
                #expect(op.changedText == newSlice, "\(context): inserted text")
            case .delete:
                #expect(op.oldRange.length > 0, "\(context): delete has non-empty old range")
                #expect(op.newRange.length == 0, "\(context): delete has empty new range")
                let oldSlice = nsOld.substring(
                    with: NSRange(location: op.oldRange.location, length: op.oldRange.length)
                )
                #expect(op.changedText == oldSlice, "\(context): deleted text")
            }
            oldCursor = op.oldRange.end
            newCursor = op.newRange.end
        }

        #expect(oldCursor == nsOld.length, "\(context): old coverage")
        #expect(newCursor == nsNew.length, "\(context): new coverage")
    }

    private func graphemeBoundaries(in text: String) -> Set<Int> {
        var boundaries: Set<Int> = [0]
        var offset = 0
        for character in text {
            offset += String(character).utf16.count
            boundaries.insert(offset)
        }
        return boundaries
    }

    private func randomText(
        vocabulary: [String],
        separators: [String],
        rng: inout LCG
    ) -> String {
        let count = Int.random(in: 0...40, using: &rng)
        var parts: [String] = []
        parts.reserveCapacity(count)
        for _ in 0..<count {
            parts.append(vocabulary.randomElement(using: &rng) ?? "hola")
        }
        var result = ""
        for (index, part) in parts.enumerated() {
            result += part
            if index < parts.count - 1 {
                result += separators.randomElement(using: &rng) ?? " "
            }
        }
        return result
    }

    private func randomMutation(
        of text: String,
        vocabulary: [String],
        separators: [String],
        rng: inout LCG
    ) -> String {
        var parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let edits = Int.random(in: 0...8, using: &rng)
        for _ in 0..<edits {
            let operation = Int.random(in: 0...2, using: &rng)
            switch operation {
            case 0:
                if !parts.isEmpty {
                    let index = Int.random(in: 0..<parts.count, using: &rng)
                    parts.remove(at: index)
                }
            case 1:
                let index = Int.random(in: 0...(parts.count), using: &rng)
                parts.insert(vocabulary.randomElement(using: &rng) ?? "nuevo", at: index)
            default:
                if !parts.isEmpty {
                    let index = Int.random(in: 0..<parts.count, using: &rng)
                    parts[index] = vocabulary.randomElement(using: &rng) ?? "cambiado"
                }
            }
        }
        var result = ""
        for (index, part) in parts.enumerated() {
            result += part
            if index < parts.count - 1 {
                result += separators.randomElement(using: &rng) ?? " "
            }
        }
        return result
    }

    private func makeParagraphDocument(wordCount: Int) -> (String, String) {
        let vocabulary = [
            "el", "coche", "de", "carreras", "gira", "en", "la", "curva", "y",
            "el", "motor", "suena", "con", "fuerza", "mientras", "el", "piloto",
            "corrige", "con", "precisión", "la", "trayectoria", "del", "circuito"
        ]
        var lines: [String] = []
        lines.reserveCapacity(wordCount / 10)
        var produced = 0
        var lineIndex = 0
        while produced < wordCount {
            let take = min(10, wordCount - produced)
            var words: [String] = []
            for offset in 0..<take {
                let word = vocabulary[(lineIndex * 7 + offset) % vocabulary.count]
                words.append("\(word)\(lineIndex % 97)")
            }
            lines.append(words.joined(separator: " "))
            produced += take
            lineIndex += 1
        }
        let old = lines.joined(separator: "\n\n")

        var changedLines = lines
        for index in stride(from: 37, to: changedLines.count, by: 250) {
            changedLines[index] += " cambio\(index)"
        }
        let new = changedLines.joined(separator: "\n\n")
        return (old, new)
    }
}

/// Small deterministic generator so the property test is reproducible.
struct LCG: RandomNumberGenerator {
    var state: UInt64

    init(state: UInt64) {
        self.state = state
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
