import Foundation

/// One sentence found by `RhythmSentenceSplitter`.
public struct RhythmSentence: Sendable, Equatable {
    /// Exact UTF-16 span in the source text, including opening marks (`¿`, `¡`)
    /// and trailing closing punctuation, but excluding surrounding whitespace.
    public let range: UTF16Span
    public let text: String
    /// Words outside `[bracket]` markup cues.
    public let wordCount: Int

    public init(range: UTF16Span, text: String, wordCount: Int) {
        self.range = range
        self.text = text
        self.wordCount = wordCount
    }
}

/// Sentence segmentation for Spanish narration.
///
/// Handles:
/// - `¿?` and `¡!` pairs (opening marks never terminate, closing marks do);
/// - ellipsis (`…` and `...`), only terminating when the next meaningful
///   character starts a new sentence (uppercase, opening mark, newline or end);
/// - common abbreviations (`p. ej.`, `etc.`, `Sr.`, `Dra.`, `km/h`, `EE. UU.`,
///   `a.m.`, …) and single-letter initials;
/// - decimal and grouped numbers (`3.5`, `1.000.000`), URLs and file names;
/// - `[markup cues]`, whose contents are ignored for both splitting and word
///   counting;
/// - blank-line paragraph breaks (a single line wrap does not cut a sentence).
public enum RhythmSentenceSplitter {
    public static func sentences(in text: String) -> [RhythmSentence] {
        let wordSpans = RhythmWordCounter.wordSpans(in: text)
        return makeSentences(in: text, wordSpans: wordSpans)
    }

    static func makeSentences(in text: String, wordSpans: [UTF16Span]) -> [RhythmSentence] {
        guard !text.isEmpty else { return [] }
        let units = makeUnits(text)
        guard !units.isEmpty else { return [] }

        var ranges: [UTF16Span] = []
        var sentenceStart: Int?
        var lastContentEnd = 0
        var bracketDepth = 0
        var previousWasLineBreak = false
        var index = 0

        func flush() {
            if let start = sentenceStart, lastContentEnd > start {
                ranges.append(UTF16Span(location: start, length: lastContentEnd - start))
            }
            sentenceStart = nil
            lastContentEnd = 0
        }

        while index < units.count {
            let unit = units[index]

            if bracketDepth > 0 {
                if unit.character == "[" {
                    bracketDepth += 1
                } else if unit.character == "]" {
                    bracketDepth -= 1
                }
                index += 1
                continue
            }
            if unit.character == "[" {
                bracketDepth = 1
                index += 1
                continue
            }
            if unit.character == "]" {
                index += 1
                continue
            }

            if unit.character.isWhitespace {
                if isLineBreak(unit.character, next: nextCharacter(after: index, in: units)) {
                    if previousWasLineBreak { flush() }
                    previousWasLineBreak = true
                }
                index += 1
                continue
            }

            previousWasLineBreak = false
            if sentenceStart == nil, isTerminator(unit.character) {
                // Stray closing punctuation (for example the dot after a
                // `[markup]` cue) must not open a one-character sentence.
                index += 1
                continue
            }
            if sentenceStart == nil { sentenceStart = unit.start }
            lastContentEnd = unit.end

            if isTerminator(unit.character),
               terminatorEndsSentence(at: index, units: units) {
                var endIndex = index
                while endIndex + 1 < units.count,
                      isTerminator(units[endIndex + 1].character) {
                    endIndex += 1
                }
                while endIndex + 1 < units.count,
                      isClosingPunctuation(units[endIndex + 1].character) {
                    endIndex += 1
                }
                if let start = sentenceStart, units[endIndex].end > start {
                    ranges.append(UTF16Span(
                        location: start,
                        length: units[endIndex].end - start
                    ))
                }
                sentenceStart = nil
                lastContentEnd = 0
                previousWasLineBreak = false
                index = endIndex + 1
                continue
            }

            index += 1
        }
        flush()

        let ns = text as NSString
        return ranges.map { range in
            RhythmSentence(
                range: range,
                text: ns.substring(with: NSRange(location: range.location, length: range.length)),
                wordCount: RhythmWordCounter.count(in: range, spans: wordSpans)
            )
        }
    }

    // MARK: - Character units

    fileprivate struct CharacterUnit {
        let character: Character
        let start: Int
        let end: Int
    }

    fileprivate static func makeUnits(_ text: String) -> [CharacterUnit] {
        var units: [CharacterUnit] = []
        units.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            units.append(CharacterUnit(
                character: character,
                start: offset,
                end: offset + length
            ))
            offset += length
        }
        return units
    }

    private static func nextCharacter(
        after index: Int,
        in units: [CharacterUnit]
    ) -> Character? {
        index + 1 < units.count ? units[index + 1].character : nil
    }

    private static func isLineBreak(_ character: Character, next: Character?) -> Bool {
        if character == "\n" { return true }
        if character == "\r" { return next != "\n" }
        return false
    }

    private static func isTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "…"
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        switch character {
        case "\"", "'", "»", "”", "’", ")", "]", "}":
            return true
        default:
            return false
        }
    }

    // MARK: - Dot / ellipsis decisions

    private static func terminatorEndsSentence(
        at index: Int,
        units: [CharacterUnit]
    ) -> Bool {
        switch units[index].character {
        case ".":
            return dotEndsSentence(at: index, units: units)
        case "…":
            return ellipsisEndsSentence(after: index, units: units)
        case "!", "?":
            return true
        default:
            return false
        }
    }

    private static func dotEndsSentence(at index: Int, units: [CharacterUnit]) -> Bool {
        var runEnd = index
        while runEnd + 1 < units.count, units[runEnd + 1].character == "." {
            runEnd += 1
        }
        if runEnd > index || (index > 0 && units[index - 1].character == ".") {
            return ellipsisEndsSentence(after: runEnd, units: units)
        }

        let previous = index > 0 ? units[index - 1].character : nil
        let next = nextCharacter(after: index, in: units)
        if previous == "…" || next == "…" {
            return ellipsisEndsSentence(after: runEnd, units: units)
        }

        // Decimal, thousands separator and version-like constructions.
        if let previous, let next,
           previous.isNumber, next.isNumber {
            return false
        }
        // File names, domains and dotted identifiers.
        if let next, next.isLetter || next.isNumber || next == "/" {
            return false
        }

        let word = wordBefore(index, units: units)
        if abbreviations.contains(word) { return false }
        // A single letter before a dot is an initial ("J. García").
        if word.count == 1, word.first?.isLetter == true { return false }

        return true
    }

    private static func ellipsisEndsSentence(
        after index: Int,
        units: [CharacterUnit]
    ) -> Bool {
        var cursor = index + 1
        while cursor < units.count, isTerminator(units[cursor].character) {
            cursor += 1
        }
        while cursor < units.count, isClosingPunctuation(units[cursor].character) {
            cursor += 1
        }
        while cursor < units.count, units[cursor].character.isWhitespace {
            if isLineBreak(units[cursor].character, next: nextCharacter(after: cursor, in: units)) {
                return true
            }
            cursor += 1
        }
        guard cursor < units.count else { return true }
        let next = units[cursor].character
        return next.isUppercase
            || next == "¿"
            || next == "¡"
            || next == "«"
            || next == "\""
            || next == "”"
    }

    private static func wordBefore(_ index: Int, units: [CharacterUnit]) -> String {
        var cursor = index - 1
        var characters: [Character] = []
        while cursor >= 0 {
            let character = units[cursor].character
            if character.isLetter || character.isNumber || character == "/" || character == "-" {
                characters.append(character)
                cursor -= 1
            } else {
                break
            }
        }
        return String(characters.reversed()).lowercased()
    }

    private static let abbreviations: Set<String> = [
        "p", "ej", "etc", "sr", "sra", "srta", "dr", "dra", "ud", "uds", "vs",
        "ee", "uu", "num", "núm", "aprox", "max", "máx", "min", "mín",
        "a.m", "p.m", "d.c", "s.a", "cía", "cia", "tel", "pág", "pag", "cap",
        "vol", "art", "fig", "seg", "hr", "av", "ctra", "dpto", "ing", "lic",
        "prof", "gral", "sarg", "ten", "ltd", "co", "inc", "mr", "mrs", "ms", "st"
    ]
}

// MARK: - Word counting

enum RhythmWordCounter {
    static func wordSpans(in text: String) -> [UTF16Span] {
        guard !text.isEmpty else { return [] }
        var spans: [UTF16Span] = []
        spans.reserveCapacity(max(1, text.count / 6))
        var offset = 0
        var bracketDepth = 0
        var wordStart: Int?

        func flushWord(at end: Int) {
            if let start = wordStart {
                spans.append(UTF16Span(location: start, length: end - start))
                wordStart = nil
            }
        }

        for character in text {
            if character == "[" {
                flushWord(at: offset)
                bracketDepth += 1
            } else if character == "]" {
                flushWord(at: offset)
                if bracketDepth > 0 { bracketDepth -= 1 }
            } else if bracketDepth == 0 {
                if isWordCharacter(character) {
                    if wordStart == nil { wordStart = offset }
                } else {
                    flushWord(at: offset)
                }
            }
            offset += String(character).utf16.count
        }
        flushWord(at: offset)
        return spans
    }

    static func count(in range: UTF16Span, spans: [UTF16Span]) -> Int {
        guard !range.isEmpty, !spans.isEmpty else { return 0 }
        let lower = lowerBound(spans, offset: range.location)
        let upper = lowerBound(spans, offset: range.end)
        return max(0, upper - lower)
    }

    private static func lowerBound(_ spans: [UTF16Span], offset: Int) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].location < offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return character.unicodeScalars.allSatisfy { scalar in
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                return true
            default:
                return false
            }
        }
    }
}
