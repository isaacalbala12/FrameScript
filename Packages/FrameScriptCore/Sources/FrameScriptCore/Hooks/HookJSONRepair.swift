import Foundation

/// Best-effort extraction and repair for JSON-shaped model output.
///
/// Models routinely return fenced blocks, prose around the payload, smart
/// quotes, single-quoted JSON, raw newlines inside strings or trailing commas.
/// The repair is deliberately conservative: each transformation is only tried
/// when the previous form failed to parse.
enum HookJSONRepair {
    // MARK: - Candidates

    static func candidates(from response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var values: [String] = [trimmed]
        let blocks = fencedBlocks(in: trimmed)
        values.append(contentsOf: blocks)
        for source in [trimmed] + blocks {
            values.append(contentsOf: balancedSegments(in: source))
            // A payload wrapped in typographic quotes is not balanced from the
            // scanner's point of view because the wrapper looks like a string.
            for (opening, closing) in [("{", "}"), ("[", "]")] {
                if let start = source.firstIndex(of: Character(opening)),
                   let end = source.lastIndex(of: Character(closing)),
                   start < end {
                    values.append(String(source[start...end]))
                }
            }
        }

        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Returns every fenced block separately. A schema example in the first
    /// block must not swallow the real answer in the second block.
    static func fencedBlocks(in text: String) -> [String] {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 2 else { return [] }

        // An unclosed final fence still has usable content.
        let upperBound = parts.count % 2 == 1 ? parts.count - 1 : parts.count
        var blocks: [String] = []
        var index = 1
        while index < upperBound {
            var block = parts[index]
            if let newline = block.firstIndex(of: "\n") {
                let firstLine = block[..<newline].trimmingCharacters(in: .whitespaces)
                if !firstLine.isEmpty,
                   !firstLine.contains("{"),
                   !firstLine.contains("[") {
                    block = String(block[block.index(after: newline)...])
                }
            } else {
                let trimmed = block.trimmingCharacters(in: .whitespaces)
                if let space = trimmed.firstIndex(of: " "),
                   !trimmed[..<space].contains("{"),
                   !trimmed[..<space].contains("[") {
                    block = String(trimmed[trimmed.index(after: space)...])
                } else {
                    block = trimmed
                }
            }
            let value = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { blocks.append(value) }
            index += 2
        }
        return blocks
    }

    /// Collects balanced `{…}` and `[…]` segments from prose, every nesting
    /// level included. Longest segments come first so the complete object is
    /// tried before its children.
    static func balancedSegments(in text: String) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }

        var segments: [String] = []
        var stack: [Character] = []
        var starts: [Int] = []
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if escaped {
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    escaped = true
                    index += 1
                    continue
                }
                if (currentQuote == "'" || currentQuote == "’"),
                   (character == "'" || character == "’"),
                   isApostrophe(index, characters) {
                    index += 1
                    continue
                }
                if isClosingQuote(character, for: currentQuote) {
                    quote = nil
                } else if currentQuote == "\"",
                          (character == "”" || character == "»"),
                          nextMeaningfulIsStructural(after: index, characters) {
                    quote = nil
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                quote = "\""
            case "“", "”":
                quote = "”"
            case "«", "»":
                quote = "»"
            case "'", "’":
                if !isApostrophe(index, characters) {
                    quote = character
                }
            case "{", "[":
                stack.append(character)
                starts.append(index)
            case "}", "]":
                guard let last = stack.last,
                      matches(last, character),
                      let start = starts.last else {
                    stack.removeAll()
                    starts.removeAll()
                    index += 1
                    continue
                }
                stack.removeLast()
                starts.removeLast()
                segments.append(String(characters[start...index]))
            default:
                break
            }
            index += 1
        }

        var seen = Set<String>()
        return segments
            .filter { seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Variants

    static func variants(of candidate: String) -> [String] {
        var values: [String] = [candidate]
        var current = candidate

        let quoteNormalized = normalizedSmartQuotes(current)
        appendIfNew(quoteNormalized, to: &values, current: &current)

        let controlEscaped = escapingControlCharacters(inStrings: current)
        appendIfNew(controlEscaped, to: &values, current: &current)

        let commaFree = removingTrailingCommas(current)
        appendIfNew(commaFree, to: &values, current: &current)

        let singleQuoteConverted = convertingSingleQuotedJSON(current)
        appendIfNew(singleQuoteConverted, to: &values, current: &current)

        return values
    }

    private static func appendIfNew(
        _ value: String,
        to values: inout [String],
        current: inout String
    ) {
        guard value != current else { return }
        values.append(value)
        current = value
    }

    // MARK: - Smart quotes

    static func normalizedSmartQuotes(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if escaped {
                    result.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    result.append(character)
                    escaped = true
                    index += 1
                    continue
                }
                if currentQuote == "\"" {
                    if character == "\"" {
                        result.append(character)
                        quote = nil
                    } else if (character == "”" || character == "»"),
                              nextMeaningfulIsStructural(after: index, characters) {
                        result.append("\"")
                        quote = nil
                    } else {
                        result.append(character)
                    }
                } else if currentQuote == "”" {
                    if character == "”" || character == "“" {
                        result.append("\"")
                        quote = nil
                    } else {
                        result.append(character)
                    }
                } else if currentQuote == "»" {
                    if character == "»" || character == "«" {
                        result.append("\"")
                        quote = nil
                    } else {
                        result.append(character)
                    }
                } else {
                    result.append(character)
                }
                index += 1
                continue
            }

            switch character {
            case "\"":
                quote = "\""
                result.append(character)
            case "“", "”":
                quote = "”"
                result.append("\"")
            case "«", "»":
                quote = "»"
                result.append("\"")
            default:
                result.append(character)
            }
            index += 1
        }
        return result
    }

    // MARK: - Control characters

    static func escapingControlCharacters(inStrings text: String) -> String {
        let characters = Array(text)
        var result = ""
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if escaped {
                    result.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    result.append(character)
                    escaped = true
                    index += 1
                    continue
                }
                if (currentQuote == "'" || currentQuote == "’"),
                   (character == "'" || character == "’"),
                   isApostrophe(index, characters) {
                    result.append(character)
                    index += 1
                    continue
                }
                if isClosingQuote(character, for: currentQuote) {
                    result.append(character)
                    quote = nil
                    index += 1
                    continue
                }
                switch character {
                case "\n":
                    result.append("\\n")
                case "\r":
                    result.append("\\r")
                case "\t":
                    result.append("\\t")
                default:
                    if let scalar = character.unicodeScalars.first, scalar.value < 0x20 {
                        result.append(String(format: "\\u%04X", scalar.value))
                    } else {
                        result.append(character)
                    }
                }
                index += 1
                continue
            }

            if character == "\"" {
                quote = "\""
                result.append(character)
            } else if (character == "'" || character == "’"),
                      !isApostrophe(index, characters) {
                quote = character
                result.append(character)
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    // MARK: - Trailing commas

    static func removingTrailingCommas(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if escaped {
                    result.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    result.append(character)
                    escaped = true
                    index += 1
                    continue
                }
                if (currentQuote == "'" || currentQuote == "’"),
                   (character == "'" || character == "’"),
                   isApostrophe(index, characters) {
                    result.append(character)
                    index += 1
                    continue
                }
                if isClosingQuote(character, for: currentQuote) {
                    quote = nil
                }
                result.append(character)
                index += 1
                continue
            }

            if character == "\"" {
                quote = "\""
                result.append(character)
                index += 1
                continue
            }
            if (character == "'" || character == "’"),
               !isApostrophe(index, characters) {
                quote = character
                result.append(character)
                index += 1
                continue
            }
            if character == "," {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace {
                    next += 1
                }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" {
                    index += 1
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }

    // MARK: - Single quotes

    static func convertingSingleQuotedJSON(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var quote: Character?
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if let currentQuote = quote {
                if escaped {
                    result.append(character)
                    escaped = false
                    index += 1
                    continue
                }
                if character == "\\" {
                    result.append(character)
                    escaped = true
                    index += 1
                    continue
                }
                if currentQuote == "\"" {
                    if character == "\"" {
                        result.append(character)
                        quote = nil
                    } else {
                        result.append(character)
                    }
                    index += 1
                    continue
                }

                // Single-quoted string: convert its delimiters and escape any
                // internal double quote.
                if (character == "'" || character == "’"),
                   !isApostrophe(index, characters) {
                    result.append("\"")
                    quote = nil
                } else if character == "\"" {
                    result.append("\\\"")
                } else {
                    result.append(character)
                }
                index += 1
                continue
            }

            if character == "\"" {
                quote = "\""
                result.append(character)
            } else if (character == "'" || character == "’"),
                      !isApostrophe(index, characters) {
                quote = character
                result.append("\"")
            } else {
                result.append(character)
            }
            index += 1
        }
        return result
    }

    // MARK: - Shared helpers

    private static func matches(_ opening: Character, _ closing: Character) -> Bool {
        (opening == "{" && closing == "}") || (opening == "[" && closing == "]")
    }

    private static func isClosingQuote(_ character: Character, for quote: Character) -> Bool {
        switch quote {
        case "\"":
            return character == "\""
        case "”":
            return character == "”" || character == "“"
        case "»":
            return character == "»" || character == "«"
        case "'":
            return character == "'" || character == "’"
        case "’":
            return character == "’" || character == "'"
        default:
            return false
        }
    }

    private static func isApostrophe(_ index: Int, _ characters: [Character]) -> Bool {
        guard index > 0, index + 1 < characters.count else { return false }
        return characters[index - 1].isLetter && characters[index + 1].isLetter
    }

    private static func nextMeaningfulIsStructural(after index: Int, _ characters: [Character]) -> Bool {
        var next = index + 1
        while next < characters.count, characters[next].isWhitespace {
            next += 1
        }
        guard next < characters.count else { return true }
        switch characters[next] {
        case ":", ",", "}", "]":
            return true
        default:
            return false
        }
    }
}
