import Foundation

/// One alignable word of a script.
///
/// `range` is a UTF-16 range into the original script text, which is what
/// `NSTextView`/`NSAttributedString` use for selections and highlighting.
public struct ScriptToken: Sendable, Hashable, Codable {
    /// Zero-based index among the alignable words of the script.
    public let index: Int
    /// Lowercased, diacritic-free, punctuation-free canonical form.
    ///
    /// Number words and digit strings share the same canonical form: both
    /// `"veinte"` and `"20"` become `"20"`, and `"dos mil veintiséis"` and
    /// `"2026"` become `"2026"`.
    public let normalized: String
    /// Original text covered by this token (may span several words for numbers).
    public let source: String
    /// UTF-16 offset range in the original script text.
    public let range: Range<Int>
    /// Index of the sentence this token belongs to.
    public let sentenceIndex: Int

    public init(
        index: Int,
        normalized: String,
        source: String,
        range: Range<Int>,
        sentenceIndex: Int
    ) {
        self.index = index
        self.normalized = normalized
        self.source = source
        self.range = range
        self.sentenceIndex = sentenceIndex
    }
}

/// A script prepared for fuzzy alignment against recognizer hypotheses.
public struct TokenizedScript: Sendable, Equatable, Codable {
    /// The exact text that was tokenized.
    public let source: String
    public let language: SpeechLanguage
    public let tokens: [ScriptToken]
    /// Token-index ranges of each sentence, ascending and non-overlapping.
    public let sentenceRanges: [Range<Int>]

    public init(
        source: String,
        language: SpeechLanguage,
        tokens: [ScriptToken],
        sentenceRanges: [Range<Int>]
    ) {
        self.source = source
        self.language = language
        self.tokens = tokens
        self.sentenceRanges = sentenceRanges
    }

    public var isEmpty: Bool { tokens.isEmpty }
    public var wordCount: Int { tokens.count }
    public var sentenceCount: Int { sentenceRanges.count }

    public func token(at index: Int) -> ScriptToken? {
        guard tokens.indices.contains(index) else { return nil }
        return tokens[index]
    }

    public func sentenceIndex(forTokenAt index: Int) -> Int? {
        token(at: index)?.sentenceIndex
    }

    public func tokenRange(forSentence sentence: Int) -> Range<Int>? {
        guard sentenceRanges.indices.contains(sentence) else { return nil }
        return sentenceRanges[sentence]
    }

    /// Token range spanning `first...last`, clamped to the available sentences.
    public func tokenRange(fromSentence first: Int, throughSentence last: Int) -> Range<Int>? {
        guard !sentenceRanges.isEmpty else { return nil }
        let lower = min(max(first, 0), sentenceRanges.count - 1)
        let upper = min(max(last, lower), sentenceRanges.count - 1)
        let start = sentenceRanges[lower].lowerBound
        let end = sentenceRanges[upper].upperBound
        return start..<end
    }

    public func utf16Offset(forTokenAt index: Int) -> Int? {
        token(at: index)?.range.lowerBound
    }
}

/// Turns a script into alignable words.
///
/// This is deliberately a small, local markup skip rule, not the full F4
/// parser. It ignores pause markers (`/`, `//`, `[pausa]`, `[2s]`), label cues
/// (`[LABEL: …]`) and emphasis delimiters (`*`, `**`) while preserving the
/// words inside emphasis.
public enum ScriptTokenizer {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func tokenize(
        _ text: String,
        language: SpeechLanguage = .spanish
    ) -> TokenizedScript {
        let rawWords = scanWords(in: text)
        let mergedWords = mergeNumbers(in: rawWords, source: text, language: language)
        let tokens = mergedWords.enumerated().map { index, word in
            ScriptToken(
                index: index,
                normalized: word.normalized,
                source: substring(of: text, utf16Range: word.range),
                range: word.range,
                sentenceIndex: word.sentenceIndex
            )
        }
        return TokenizedScript(
            source: text,
            language: language,
            tokens: tokens,
            sentenceRanges: sentenceRanges(for: tokens)
        )
    }

    /// Convenience for callers that only need the canonical words (for
    /// example, to turn a recognizer hypothesis into alignment input).
    public static func normalizedWords(
        in text: String,
        language: SpeechLanguage
    ) -> [String] {
        tokenize(text, language: language).tokens.map(\.normalized)
    }

    // MARK: - Raw scanning

    private struct RawWord {
        let normalized: String
        let range: Range<Int>
        let sentenceIndex: Int
        let isAllDigits: Bool
    }

    private struct CharactersAndRanges {
        let characters: [Character]
        let ranges: [Range<Int>]
    }

    private static func split(_ text: String) -> CharactersAndRanges {
        var characters: [Character] = []
        var ranges: [Range<Int>] = []
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            characters.append(character)
            ranges.append(offset..<(offset + length))
            offset += length
        }
        return CharactersAndRanges(characters: characters, ranges: ranges)
    }

    private static func scanWords(in text: String) -> [RawWord] {
        let scanned = split(text)
        let characters = scanned.characters
        let ranges = scanned.ranges

        var words: [RawWord] = []
        var sentence = 0
        var pendingSentenceBreak = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                // A newline is a script line boundary. Teleprompter scripts
                // commonly put one sentence or one scene line per line without
                // terminal punctuation; treating a soft newline as one giant
                // sentence would make all jump limits vacuous.
                if character.isNewline {
                    pendingSentenceBreak = true
                }
                index += 1
                continue
            }

            if character == "[" {
                if let closing = characters[(index + 1)...].firstIndex(of: "]") {
                    let content = String(characters[(index + 1)..<closing])
                    if isCue(content) {
                        index = closing + 1
                        continue
                    }
                }
                index += 1
                continue
            }

            if isWordCharacter(character) {
                let start = index
                var end = index + 1
                while end < characters.count {
                    let candidate = characters[end]
                    if isWordCharacter(candidate) {
                        end += 1
                        continue
                    }
                    if isApostrophe(candidate),
                       end > start,
                       end + 1 < characters.count,
                       isWordCharacter(characters[end - 1]),
                       isWordCharacter(characters[end + 1]) {
                        end += 1
                        continue
                    }
                    break
                }

                let raw = String(characters[start..<end])
                let normalized = normalize(raw)
                if !normalized.isEmpty {
                    if pendingSentenceBreak {
                        if !words.isEmpty { sentence += 1 }
                        pendingSentenceBreak = false
                    }
                    let range = ranges[start].lowerBound..<ranges[end - 1].upperBound
                    words.append(
                        RawWord(
                            normalized: normalized,
                            range: range,
                            sentenceIndex: sentence,
                            isAllDigits: isASCIIInteger(normalized)
                        )
                    )
                }
                index = end
                continue
            }

            if character == "." || character == "!" || character == "?" || character == "…" {
                var shouldBreak = true
                if character == "." {
                    let isDecimalPoint = index > 0
                        && index + 1 < characters.count
                        && characters[index - 1].isNumber
                        && characters[index + 1].isNumber
                    let followsKnownAbbreviation = index > 0
                        && !characters[index - 1].isWhitespace
                        && words.last.map { abbreviations.contains($0.normalized) } == true
                    if isDecimalPoint || followsKnownAbbreviation {
                        shouldBreak = false
                    }
                }
                if shouldBreak {
                    pendingSentenceBreak = true
                }
            }

            index += 1
        }

        return words
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static let abbreviations: Set<String> = [
        "sr", "sra", "srta", "dr", "dra", "prof", "ud", "uds", "etc", "ej",
        "aprox", "nro", "num", "p", "pp", "ee", "uu", "vs", "mr", "mrs",
        "ms", "st", "av", "ct", "tel"
    ]

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "’" || character == "‘"
    }

    private static func isASCIIInteger(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func normalize(_ raw: String) -> String {
        let folded = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
            .lowercased(with: posixLocale)
        let characters = folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map { Character($0) }
        return String(characters)
    }

    // MARK: - Markup cues

    private static func isCue(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let folded = trimmed
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posixLocale)
            .lowercased(with: posixLocale)

        if folded == "pausa" || folded.hasPrefix("pausa ") || folded.hasPrefix("pausa:") {
            return true
        }
        if isDurationCue(folded) {
            return true
        }
        if let colon = trimmed.firstIndex(of: ":") {
            let label = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            if !label.isEmpty,
               label.count <= 24,
               !label.contains(where: { $0.isWhitespace }) {
                return true
            }
        }
        return false
    }

    private static func isDurationCue(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let suffixes = [
            "milisegundos", "milisegundo", "milliseconds", "millisecond",
            "segundos", "segundo", "seconds", "second", "segs", "seg", "ms", "s"
        ]
        for suffix in suffixes {
            guard compact.hasSuffix(suffix) else { continue }
            let numberText = compact
                .dropLast(suffix.count)
                .replacingOccurrences(of: ",", with: ".")
            if let value = Double(numberText), value >= 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Numbers

    private static func mergeNumbers(
        in words: [RawWord],
        source: String,
        language: SpeechLanguage
    ) -> [RawWord] {
        var merged: [RawWord] = []
        merged.reserveCapacity(words.count)

        var index = 0
        while index < words.count {
            let word = words[index]

            if word.isAllDigits,
               let expression = parseDigitExpression(
                   words,
                   start: index,
                   source: source,
                   language: language
               ) {
                let last = words[index + expression.count - 1]
                merged.append(
                    RawWord(
                        normalized: expression.canonical,
                        range: word.range.lowerBound..<last.range.upperBound,
                        sentenceIndex: word.sentenceIndex,
                        isAllDigits: false
                    )
                )
                index += expression.count
                continue
            }

            if let expression = parseSpokenDecimalExpression(
                words,
                start: index,
                language: language
            ) {
                let last = words[index + expression.count - 1]
                merged.append(
                    RawWord(
                        normalized: expression.canonical,
                        range: word.range.lowerBound..<last.range.upperBound,
                        sentenceIndex: word.sentenceIndex,
                        isAllDigits: false
                    )
                )
                index += expression.count
                continue
            }

            if word.isAllDigits {
                merged.append(
                    RawWord(
                        normalized: canonicalDigits(word.normalized),
                        range: word.range,
                        sentenceIndex: word.sentenceIndex,
                        isAllDigits: true
                    )
                )
                index += 1
                continue
            }

            var sameSentenceEnd = index
            let maximumLookahead = min(words.count, index + 8)
            while sameSentenceEnd < maximumLookahead,
                  words[sameSentenceEnd].sentenceIndex == word.sentenceIndex {
                sameSentenceEnd += 1
            }

            let normalizedSlice = words[index..<sameSentenceEnd].map(\.normalized)
            if let parsed = parseNumberWords(normalizedSlice, language: language),
               parsed.count > 0 {
                let last = words[index + parsed.count - 1]
                let range = word.range.lowerBound..<last.range.upperBound
                merged.append(
                    RawWord(
                        normalized: String(parsed.value),
                        range: range,
                        sentenceIndex: word.sentenceIndex,
                        isAllDigits: true
                    )
                )
                index += parsed.count
                continue
            }

            merged.append(word)
            index += 1
        }

        return merged
    }

    private static func parseNumberWords(
        _ words: [String],
        language: SpeechLanguage
    ) -> (value: Int, count: Int)? {
        switch language {
        case .spanish:
            parseSpanishNumber(words)
        case .english:
            parseEnglishNumber(words)
        }
    }

    /// Parses digit expressions with locale-aware separators:
    /// `1,5` and `1.5` → `1.5`; `1.500` (Spanish) and `1,500` (English) → `1500`.
    private static func parseDigitExpression(
        _ words: [RawWord],
        start: Int,
        source: String,
        language: SpeechLanguage
    ) -> (canonical: String, count: Int)? {
        guard words.indices.contains(start), words[start].isAllDigits else { return nil }

        let sentence = words[start].sentenceIndex
        var integerPart = words[start].normalized
        var fractionPart: String?
        var index = start + 1

        while index < words.count,
              words[index].sentenceIndex == sentence,
              words[index].isAllDigits {
            let separatorText = substring(
                of: source,
                utf16Range: words[index - 1].range.upperBound..<words[index].range.lowerBound
            )
            guard separatorText.count == 1,
                  let separator = separatorText.first,
                  separator == "." || separator == "," else {
                break
            }

            let group = words[index].normalized
            if fractionPart != nil { break }

            if separator == decimalSeparator(for: language) {
                fractionPart = group
                index += 1
                break
            }

            if group.count == 3 {
                integerPart += group
                index += 1
                continue
            }

            // Forgiving fallback: a non-native separator with a short group is
            // almost certainly a decimal comma/point typed by a non-native app.
            fractionPart = group
            index += 1
            break
        }

        var canonical = canonicalDigits(integerPart)
        if let fractionPart {
            let normalizedFraction = normalizedFractionDigits(fractionPart)
            if !normalizedFraction.isEmpty {
                canonical += "." + normalizedFraction
            }
        }
        return (canonical, index - start)
    }

    /// Parses spoken decimals: `uno coma cinco`, `cero coma cero cinco`,
    /// `one point five`, `25 coma 4`.
    private static func parseSpokenDecimalExpression(
        _ words: [RawWord],
        start: Int,
        language: SpeechLanguage
    ) -> (canonical: String, count: Int)? {
        guard words.indices.contains(start) else { return nil }
        let sentence = words[start].sentenceIndex

        let whole: Int
        let wholeCount: Int
        if words[start].isAllDigits, let value = Int(words[start].normalized) {
            whole = value
            wholeCount = 1
        } else {
            var end = start
            let maximum = min(words.count, start + 8)
            while end < maximum, words[end].sentenceIndex == sentence {
                end += 1
            }
            let slice = words[start..<end].map(\.normalized)
            guard let parsed = parseNumberWords(slice, language: language) else { return nil }
            whole = parsed.value
            wholeCount = parsed.count
        }

        let separatorIndex = start + wholeCount
        guard separatorIndex < words.count,
              words[separatorIndex].sentenceIndex == sentence,
              isDecimalSeparatorWord(words[separatorIndex].normalized, language: language) else {
            return nil
        }

        let fractionStart = separatorIndex + 1
        guard fractionStart < words.count,
              words[fractionStart].sentenceIndex == sentence else {
            return nil
        }

        var fractionDigits: String
        var fractionCount: Int

        if words[fractionStart].isAllDigits {
            fractionDigits = words[fractionStart].normalized
            fractionCount = 1
        } else if let sequence = parseUnitDigitSequence(
            words,
            start: fractionStart,
            language: language
        ) {
            fractionDigits = sequence.digits
            fractionCount = sequence.count
        } else {
            var end = fractionStart
            let maximum = min(words.count, fractionStart + 8)
            while end < maximum, words[end].sentenceIndex == sentence {
                end += 1
            }
            let slice = words[fractionStart..<end].map(\.normalized)
            guard let parsed = parseNumberWords(slice, language: language) else { return nil }
            fractionDigits = String(parsed.value)
            fractionCount = parsed.count
        }

        let normalizedFraction = normalizedFractionDigits(fractionDigits)
        let canonical = normalizedFraction.isEmpty
            ? String(whole)
            : "\(whole).\(normalizedFraction)"
        return (canonical, wholeCount + 1 + fractionCount)
    }

    private static func parseUnitDigitSequence(
        _ words: [RawWord],
        start: Int,
        language: SpeechLanguage
    ) -> (digits: String, count: Int)? {
        let sentence = words[start].sentenceIndex
        var digits = ""
        var index = start
        while index < words.count,
              index < start + 6,
              words[index].sentenceIndex == sentence,
              let digit = unitDigit(words[index].normalized, language: language) {
            digits += String(digit)
            index += 1
        }
        guard digits.count >= 2 else { return nil }
        return (digits, index - start)
    }

    private static func unitDigit(_ word: String, language: SpeechLanguage) -> Int? {
        switch language {
        case .spanish:
            spanishUnits[word]
        case .english:
            englishUnits[word]
        }
    }

    private static func isDecimalSeparatorWord(
        _ word: String,
        language: SpeechLanguage
    ) -> Bool {
        switch language {
        case .spanish:
            word == "coma" || word == "punto"
        case .english:
            word == "point"
        }
    }

    private static func decimalSeparator(for language: SpeechLanguage) -> Character {
        switch language {
        case .spanish: ","
        case .english: "."
        }
    }

    private static func canonicalDigits(_ digits: String) -> String {
        let trimmed = digits.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func normalizedFractionDigits(_ digits: String) -> String {
        var result = digits
        while result.count > 1, result.last == "0" {
            result.removeLast()
        }
        return result == "0" ? "" : result
    }

    private static func substring(of text: String, utf16Range: Range<Int>) -> String {
        let utf16 = text.utf16
        guard let start = utf16.index(
                utf16.startIndex,
                offsetBy: utf16Range.lowerBound,
                limitedBy: utf16.endIndex
              ),
              let end = utf16.index(
                utf16.startIndex,
                offsetBy: utf16Range.upperBound,
                limitedBy: utf16.endIndex
              ),
              start <= end else {
            return ""
        }
        return String(text[start..<end])
    }

    private static func sentenceRanges(for tokens: [ScriptToken]) -> [Range<Int>] {
        guard let first = tokens.first else { return [] }
        var ranges: [Range<Int>] = []
        var sentence = first.sentenceIndex
        var start = 0
        for (index, token) in tokens.enumerated() where token.sentenceIndex != sentence {
            ranges.append(start..<index)
            sentence = token.sentenceIndex
            start = index
        }
        ranges.append(start..<tokens.count)
        return ranges
    }

    // MARK: - Spanish number grammar (0...9999)

    private static let spanishUnits: [String: Int] = [
        "cero": 0, "un": 1, "uno": 1, "una": 1, "dos": 2, "tres": 3,
        "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7, "ocho": 8, "nueve": 9
    ]

    private static let spanishTeens: [String: Int] = [
        "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14,
        "quince": 15, "dieciseis": 16, "diecisiete": 17, "dieciocho": 18,
        "diecinueve": 19
    ]

    private static let spanishTwenties: [String: Int] = [
        "veinte": 20, "veintiuno": 21, "veintiun": 21, "veintiuna": 21,
        "veintidos": 22, "veintitres": 23, "veinticuatro": 24,
        "veinticinco": 25, "veintiseis": 26, "veintisiete": 27,
        "veintiocho": 28, "veintinueve": 29
    ]

    private static let spanishTens: [String: Int] = [
        "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60,
        "setenta": 70, "ochenta": 80, "noventa": 90
    ]

    private static let spanishHundreds: [String: Int] = [
        "doscientos": 200, "trescientos": 300, "cuatrocientos": 400,
        "quinientos": 500, "seiscientos": 600, "setecientos": 700,
        "ochocientos": 800, "novecientos": 900
    ]

    private static func parseSpanishNumber(_ words: [String]) -> (value: Int, count: Int)? {
        guard !words.isEmpty else { return nil }

        var total = 0
        var index = 0

        if words[0] == "mil" {
            total = 1_000
            index = 1
        } else if let unit = spanishUnits[words[0]],
                  (1...9).contains(unit),
                  words.count > 1,
                  words[1] == "mil" {
            total = unit * 1_000
            index = 2
        }

        if index < words.count,
           let (tail, consumed) = parseSpanishBelowThousand(Array(words[index...])) {
            total += tail
            index += consumed
        }

        guard index > 0, total >= 0, total <= 9_999 else { return nil }
        return (total, index)
    }

    private static func parseSpanishBelowThousand(_ words: [String]) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }

        if first == "cien" {
            return (100, 1)
        }

        if first == "ciento" {
            var value = 100
            var index = 1
            if index < words.count,
               let (tail, consumed) = parseSpanishTensUnits(Array(words[index...])) {
                value += tail
                index += consumed
            }
            return (value, index)
        }

        if let hundreds = spanishHundreds[first] {
            var value = hundreds
            var index = 1
            if index < words.count,
               let (tail, consumed) = parseSpanishTensUnits(Array(words[index...])) {
                value += tail
                index += consumed
            }
            guard value < 1_000 else { return nil }
            return (value, index)
        }

        return parseSpanishTensUnits(words)
    }

    private static func parseSpanishTensUnits(_ words: [String]) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }

        if let teen = spanishTeens[first] { return (teen, 1) }
        if let twenty = spanishTwenties[first] { return (twenty, 1) }
        if let unit = spanishUnits[first] { return (unit, 1) }

        if let tens = spanishTens[first] {
            var value = tens
            var index = 1
            if index + 1 < words.count,
               words[index] == "y",
               let unit = spanishUnits[words[index + 1]],
               (1...9).contains(unit) {
                value += unit
                index += 2
            }
            guard value < 100 else { return nil }
            return (value, index)
        }

        return nil
    }

    // MARK: - English number grammar (0...9999)

    private static let englishUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    private static let englishTeens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19
    ]

    private static let englishTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    private static let englishNumberComponents: Set<String> = {
        Set(englishUnits.keys)
            .union(englishTeens.keys)
            .union(englishTens.keys)
            .union(["hundred", "thousand", "and"])
    }()

    private static func parseEnglishNumber(_ words: [String]) -> (value: Int, count: Int)? {
        guard !words.isEmpty else { return nil }

        if let year = parseEnglishYearStyle(words) {
            return year
        }

        var total = 0
        var index = 0

        if words[0] == "thousand" {
            total = 1_000
            index = 1
        } else if (words[0] == "a" || words[0] == "an"),
                  words.count > 1,
                  words[1] == "thousand" {
            total = 1_000
            index = 2
        } else if let unit = englishUnits[words[0]],
                  (1...9).contains(unit),
                  words.count > 1,
                  words[1] == "thousand" {
            total = unit * 1_000
            index = 2
        }

        if index < words.count,
           words[index] == "and",
           index + 1 < words.count,
           let (tail, consumed) = parseEnglishBelowThousand(Array(words[(index + 1)...])) {
            total += tail
            index += 1 + consumed
        } else if index < words.count,
                  let (tail, consumed) = parseEnglishBelowThousand(Array(words[index...])) {
            total += tail
            index += consumed
        }

        guard index > 0, total >= 0, total <= 9_999 else { return nil }
        return (total, index)
    }

    /// "twenty twenty-six" and "nineteen eighty-four" are years, not sums.
    private static func parseEnglishYearStyle(_ words: [String]) -> (value: Int, count: Int)? {
        guard words.count >= 2,
              let (first, firstCount) = parseEnglishTwoDigitGroup(words) else {
            return nil
        }
        guard let (second, secondCount) = parseEnglishTwoDigitGroup(
            Array(words[firstCount...])
        ) else {
            return nil
        }
        let consumed = firstCount + secondCount
        if consumed < words.count, englishNumberComponents.contains(words[consumed]) {
            return nil
        }
        let value = first * 100 + second
        guard value <= 9_999 else { return nil }
        return (value, consumed)
    }

    private static func parseEnglishTwoDigitGroup(_ words: [String]) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }
        if let teen = englishTeens[first] { return (teen, 1) }
        if let tens = englishTens[first] {
            var value = tens
            var index = 1
            if index < words.count,
               let unit = englishUnits[words[index]],
               (1...9).contains(unit) {
                value += unit
                index += 1
            }
            return (value, index)
        }
        return nil
    }

    private static func parseEnglishBelowThousand(_ words: [String]) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }

        if first == "hundred" {
            var value = 100
            var index = 1
            if index < words.count,
               words[index] == "and",
               index + 1 < words.count,
               let (tail, consumed) = parseEnglishTensUnits(Array(words[(index + 1)...])) {
                value += tail
                index += 1 + consumed
            } else if index < words.count,
                      let (tail, consumed) = parseEnglishTensUnits(Array(words[index...])) {
                value += tail
                index += consumed
            }
            return (value, index)
        }

        if (first == "a" || first == "an"), words.count > 1, words[1] == "hundred" {
            var value = 100
            var index = 2
            if index < words.count,
               words[index] == "and",
               index + 1 < words.count,
               let (tail, consumed) = parseEnglishTensUnits(Array(words[(index + 1)...])) {
                value += tail
                index += 1 + consumed
            } else if index < words.count,
                      let (tail, consumed) = parseEnglishTensUnits(Array(words[index...])) {
                value += tail
                index += consumed
            }
            return (value, index)
        }

        if let unit = englishUnits[first],
           (1...9).contains(unit),
           words.count > 1,
           words[1] == "hundred" {
            var value = unit * 100
            var index = 2
            if index < words.count,
               words[index] == "and",
               index + 1 < words.count,
               let (tail, consumed) = parseEnglishTensUnits(Array(words[(index + 1)...])) {
                value += tail
                index += 1 + consumed
            } else if index < words.count,
                      let (tail, consumed) = parseEnglishTensUnits(Array(words[index...])) {
                value += tail
                index += consumed
            }
            return (value, index)
        }

        return parseEnglishTensUnits(words)
    }

    private static func parseEnglishTensUnits(_ words: [String]) -> (value: Int, count: Int)? {
        guard let first = words.first else { return nil }

        if let teen = englishTeens[first] { return (teen, 1) }
        if let unit = englishUnits[first] { return (unit, 1) }

        if let tens = englishTens[first] {
            var value = tens
            var index = 1
            if index < words.count,
               let unit = englishUnits[words[index]],
               (1...9).contains(unit) {
                value += unit
                index += 1
            }
            return (value, index)
        }

        return nil
    }
}
