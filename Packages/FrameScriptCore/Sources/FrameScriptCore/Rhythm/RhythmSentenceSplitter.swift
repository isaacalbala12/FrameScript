import Foundation

/// One sentence found by `RhythmSentenceSplitter`.
public struct RhythmSentence: Sendable, Equatable {
    /// Exact UTF-16 span in the source text, including opening marks (`¿`, `¡`)
    /// and trailing closing punctuation, but excluding surrounding whitespace.
    public let range: UTF16Span
    public let text: String
    /// Words outside markup cues.
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
/// - common abbreviations (`p. ej.`, `etc.`, `Sr.`, `Dra.`, `a.m.`, `EE. UU.`,
///   …) and single-letter initials, with sentence-final abbreviations such as
///   `etc.` still ending a sentence before an uppercase word;
/// - decimal and grouped numbers (`3.5`, `1.000.000`), URLs and file names;
/// - the markup syntax shared with `ScriptMarkup`: single-line `[pausa]`,
///   `[2s]` and `[LABEL: …]` cues are skipped; emphasis `*` / `**` delimiters
///   are not words; standalone `/` and `//` pauses are not words; slashes
///   inside tokens (`km/h`, URLs, `and/or`) stay literal;
/// - blank-line paragraph breaks (a single line wrap does not cut a sentence),
///   including CRLF and CR line endings.
public enum RhythmSentenceSplitter {
    public static func sentences(in text: String) -> [RhythmSentence] {
        guard !text.isEmpty else { return [] }
        let units = RhythmCharacterUnit.make(text)
        guard !units.isEmpty else { return [] }
        let cueMask = RhythmMarkupScan.cueMask(for: units)
        let urlMask = RhythmMarkupScan.urlMask(for: units)
        let wordSpans = RhythmWordCounter.wordSpans(
            in: units,
            cueMask: cueMask,
            urlMask: urlMask
        )
        return makeSentences(
            in: text,
            units: units,
            cueMask: cueMask,
            urlMask: urlMask,
            wordSpans: wordSpans
        )
    }

    static func makeSentences(
        in text: String,
        units: [RhythmCharacterUnit],
        cueMask: [Bool],
        urlMask: [Bool],
        wordSpans: [UTF16Span]
    ) -> [RhythmSentence] {
        guard !units.isEmpty else { return [] }

        var ranges: [UTF16Span] = []
        var sentenceStart: Int?
        var lastContentEnd = 0
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

            if unit.character.isWhitespace {
                if unit.character.isNewline {
                    if previousWasLineBreak { flush() }
                    previousWasLineBreak = true
                }
                index += 1
                continue
            }

            if cueMask[index] {
                index += 1
                continue
            }

            previousWasLineBreak = false

            if isTerminator(unit.character) {
                let runEnd = terminatorRunEnd(from: index, units: units)
                guard sentenceStart != nil else {
                    // Stray punctuation, for example the dot after a removed
                    // `[B-roll: …]` cue, must not open a one-character sentence.
                    index = runEnd + 1
                    continue
                }
                if terminatorRunEndsSentence(
                    start: index,
                    end: runEnd,
                    units: units,
                    urlMask: urlMask
                ) {
                    var endIndex = runEnd
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
                    index = endIndex + 1
                } else {
                    lastContentEnd = units[runEnd].end
                    index = runEnd + 1
                }
                continue
            }

            if sentenceStart == nil { sentenceStart = unit.start }
            lastContentEnd = unit.end
            index += 1
        }
        flush()

        let ns = text as NSString
        return ranges.compactMap { range in
            let words = RhythmWordCounter.count(in: range, spans: wordSpans)
            guard words > 0 else { return nil }
            return RhythmSentence(
                range: range,
                text: ns.substring(with: NSRange(location: range.location, length: range.length)),
                wordCount: words
            )
        }
    }

    // MARK: - Terminators

    private static func isTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "…"
    }

    private static func terminatorRunEnd(
        from start: Int,
        units: [RhythmCharacterUnit]
    ) -> Int {
        var end = start
        while end + 1 < units.count,
              isTerminator(units[end + 1].character) {
            end += 1
        }
        return end
    }

    private static func terminatorRunEndsSentence(
        start: Int,
        end: Int,
        units: [RhythmCharacterUnit],
        urlMask: [Bool]
    ) -> Bool {
        var containsQuestionOrBang = false
        var containsEllipsis = false
        for index in start...end {
            switch units[index].character {
            case "!", "?":
                containsQuestionOrBang = true
            case "…":
                containsEllipsis = true
            default:
                break
            }
        }

        if containsQuestionOrBang {
            return !isInsideURLToken(at: start, units: units, urlMask: urlMask)
        }
        if containsEllipsis || end > start {
            return ellipsisEndsSentence(after: end, units: units)
        }
        return singleDotEndsSentence(at: start, units: units)
    }

    private static func singleDotEndsSentence(
        at index: Int,
        units: [RhythmCharacterUnit]
    ) -> Bool {
        let previous = index > 0 ? units[index - 1].character : nil
        let next = index + 1 < units.count ? units[index + 1].character : nil

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
        if abbreviations.contains(word) {
            if sentenceFinalAbbreviations.contains(word),
               followedByNewSentence(after: index, units: units) {
                return true
            }
            return false
        }
        // A single letter before a dot is an initial ("J. García").
        if word.count == 1, word.first?.isLetter == true { return false }

        return true
    }

    private static func ellipsisEndsSentence(
        after index: Int,
        units: [RhythmCharacterUnit]
    ) -> Bool {
        var cursor = index + 1
        while cursor < units.count, isTerminator(units[cursor].character) {
            cursor += 1
        }
        while cursor < units.count, isClosingPunctuation(units[cursor].character) {
            cursor += 1
        }
        while cursor < units.count, units[cursor].character.isWhitespace {
            if units[cursor].character.isNewline { return true }
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

    private static func followedByNewSentence(
        after index: Int,
        units: [RhythmCharacterUnit]
    ) -> Bool {
        var cursor = index + 1
        while cursor < units.count, isClosingPunctuation(units[cursor].character) {
            cursor += 1
        }
        while cursor < units.count, units[cursor].character.isWhitespace {
            if units[cursor].character.isNewline { return true }
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

    private static func isInsideURLToken(
        at index: Int,
        units: [RhythmCharacterUnit],
        urlMask: [Bool]
    ) -> Bool {
        guard index >= 0, index < urlMask.count, urlMask[index] else { return false }
        // A terminator at the very end of the URL token still ends the sentence.
        return index + 1 < units.count && !units[index + 1].character.isWhitespace
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        switch character {
        case "\"", "'", "»", "”", "’", ")", "]", "}", "*":
            return true
        default:
            return false
        }
    }

    private static func wordBefore(
        _ index: Int,
        units: [RhythmCharacterUnit]
    ) -> String {
        var cursor = index - 1
        var characters: [Character] = []
        while cursor >= 0 {
            let character = units[cursor].character
            if character.isLetter
                || character.isNumber
                || character == "/"
                || character == "-"
                || character == "." {
                characters.append(character)
                cursor -= 1
            } else {
                break
            }
        }
        var word = String(characters.reversed())
        while word.hasPrefix(".") { word.removeFirst() }
        while word.hasSuffix(".") { word.removeLast() }
        return word.lowercased()
    }

    private static let abbreviations: Set<String> = [
        "p", "ej", "etc", "etcétera", "sr", "sra", "srta", "dr", "dra", "ud",
        "uds", "vs", "ee", "uu", "num", "núm", "aprox", "max", "máx", "min",
        "mín", "a.m", "p.m", "d.c", "s.a", "cía", "cia", "tel", "pág", "pag",
        "cap", "vol", "art", "fig", "seg", "hr", "av", "ctra", "dpto", "ing",
        "lic", "prof", "gral", "sarg", "ten", "ltd", "co", "inc", "mr", "mrs",
        "ms", "st"
    ]

    /// Abbreviations that can also close a sentence. Titles (`Sr.`, `Dra.`) and
    /// initialisms (`EE. UU.`) never split, but `etc.` or `p.m.` followed by an
    /// uppercase word do.
    private static let sentenceFinalAbbreviations: Set<String> = [
        "etc", "etcétera", "a.m", "p.m"
    ]
}

// MARK: - Character units and markup scan

struct RhythmCharacterUnit {
    let character: Character
    let start: Int
    let end: Int

    static func make(_ text: String) -> [RhythmCharacterUnit] {
        var units: [RhythmCharacterUnit] = []
        units.reserveCapacity(text.count)
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            units.append(RhythmCharacterUnit(
                character: character,
                start: offset,
                end: offset + length
            ))
            offset += length
        }
        return units
    }
}

/// A lightweight scan of the `ScriptMarkup` syntax, without depending on the
/// markup module. Only the information rhythm review needs is produced:
/// matched bracket cues and URL tokens.
enum RhythmMarkupScan {
    /// Marks the characters of every valid bracket cue.
    ///
    /// Mirrors `ScriptMarkup`: cues are single-line, never nest, and must have
    /// non-empty content. Unmatched, nested or empty brackets stay literal.
    static func cueMask(for units: [RhythmCharacterUnit]) -> [Bool] {
        guard !units.isEmpty else { return [] }
        var mask = [Bool](repeating: false, count: units.count)
        var index = 0
        while index < units.count {
            guard units[index].character == "[" else {
                index += 1
                continue
            }
            var cursor = index + 1
            var close: Int?
            while cursor < units.count {
                let character = units[cursor].character
                if character == "]" {
                    close = cursor
                    break
                }
                if character == "[" || character.isNewline {
                    break
                }
                cursor += 1
            }
            guard let close else {
                index += 1
                continue
            }
            let hasContent = ((index + 1)..<close).contains {
                !units[$0].character.isWhitespace
            }
            guard hasContent else {
                index += 1
                continue
            }
            for position in index...close {
                mask[position] = true
            }
            index = close + 1
        }
        return mask
    }

    /// Marks characters that belong to a URL token (`scheme://…` or `www.…`).
    static func urlMask(for units: [RhythmCharacterUnit]) -> [Bool] {
        guard !units.isEmpty else { return [] }
        var mask = [Bool](repeating: false, count: units.count)
        var index = 0
        while index < units.count {
            if units[index].character.isWhitespace {
                index += 1
                continue
            }
            let start = index
            while index < units.count, !units[index].character.isWhitespace {
                index += 1
            }
            let end = index
            var token = ""
            token.reserveCapacity(end - start)
            for position in start..<end {
                token.append(units[position].character)
            }
            let lowered = token.lowercased()
            if lowered.contains("://") || lowered.hasPrefix("www.") {
                for position in start..<end {
                    mask[position] = true
                }
            }
        }
        return mask
    }
}

// MARK: - Word counting

/// Counts spoken words the same way `ScriptMarkup.spokenWordCount` does: a word
/// contains at least one letter or digit after bracket cues are removed.
/// Connectors inside a word (`km/h`, `1.000`, `and/or`, `don't`) keep it whole;
/// trailing punctuation is not part of the span. URL tokens count once.
enum RhythmWordCounter {
    static func wordSpans(in text: String) -> [UTF16Span] {
        guard !text.isEmpty else { return [] }
        let units = RhythmCharacterUnit.make(text)
        let cueMask = RhythmMarkupScan.cueMask(for: units)
        let urlMask = RhythmMarkupScan.urlMask(for: units)
        return wordSpans(in: units, cueMask: cueMask, urlMask: urlMask)
    }

    static func wordSpans(
        in units: [RhythmCharacterUnit],
        cueMask: [Bool],
        urlMask: [Bool]
    ) -> [UTF16Span] {
        guard !units.isEmpty else { return [] }
        var spans: [UTF16Span] = []
        var index = 0

        while index < units.count {
            if cueMask[index] || units[index].character.isWhitespace {
                index += 1
                continue
            }

            let runStart = index
            while index < units.count,
                  !cueMask[index],
                  !units[index].character.isWhitespace {
                index += 1
            }
            let runEnd = index

            if urlMask[runStart] {
                if let span = spanForURLRun(
                    start: runStart,
                    end: runEnd,
                    units: units
                ) {
                    spans.append(span)
                }
                continue
            }

            var cursor = runStart
            while cursor < runEnd {
                guard isWordCharacter(units[cursor].character) else {
                    cursor += 1
                    continue
                }
                let wordStart = cursor
                var wordEnd = cursor
                cursor += 1
                while cursor < runEnd {
                    let character = units[cursor].character
                    if isWordCharacter(character) {
                        wordEnd = cursor
                        cursor += 1
                        continue
                    }
                    if isConnector(character),
                       cursor + 1 < runEnd,
                       isWordCharacter(units[cursor + 1].character) {
                        cursor += 1
                        continue
                    }
                    break
                }
                spans.append(UTF16Span(
                    location: units[wordStart].start,
                    length: units[wordEnd].end - units[wordStart].start
                ))
            }
        }
        return spans
    }

    private static func spanForURLRun(
        start: Int,
        end: Int,
        units: [RhythmCharacterUnit]
    ) -> UTF16Span? {
        var firstWord: Int?
        var lastWord: Int?
        for index in start..<end where isWordCharacter(units[index].character) {
            if firstWord == nil { firstWord = index }
            lastWord = index
        }
        guard let first = firstWord, let last = lastWord else { return nil }
        return UTF16Span(
            location: units[first].start,
            length: units[last].end - units[first].start
        )
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

    /// Characters that join two word characters into one spoken word.
    private static func isConnector(_ character: Character) -> Bool {
        switch character {
        case "/", "-", ".", ",", "'", "’", "_", ":", "@", "&":
            return true
        default:
            return false
        }
    }
}
