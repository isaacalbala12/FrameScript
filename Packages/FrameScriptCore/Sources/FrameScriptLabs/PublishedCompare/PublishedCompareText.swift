import Foundation

/// Text helpers shared by the published-video comparison feature.
///
/// The normalization here is deliberately small and predictable: it is used for
/// matching script words against transcript words, never for display.
public enum ScriptNormalizer {
    /// Normalizes a script or transcript string into lowercase, accent-free words.
    ///
    /// FrameScript markup is ignored:
    /// - bracketed cue/pause markup such as `[risas]`, `[...]`, `[0:12]`;
    /// - emphasis delimiters (`*text*`, `**text**`);
    /// - pause markers (`/`, `//`).
    ///
    /// Punctuation is converted to a word boundary. Digits are preserved.
    public static func normalize(_ text: String) -> [String] {
        tokenize(text).map(\.key)
    }

    /// Returns normalized keys together with a readable original word.
    ///
    /// A single source word can produce more than one key (for example
    /// `AC/EVO` produces `ac` and `evo`). In that case the first token keeps the
    /// readable original and the remaining keys are their own display text.
    static func tokenize(_ text: String) -> [(key: String, display: String)] {
        let cleaned = prepareForTokenization(text)
        var result: [(key: String, display: String)] = []

        for rawWord in cleaned.split(whereSeparator: \.isWhitespace) {
            let display = String(rawWord).trimmingCharacters(in: .punctuationCharacters)
            let keys = keys(forWord: String(rawWord))
            for (index, key) in keys.enumerated() {
                let shown = index == 0 && !display.isEmpty ? display : key
                result.append((key, shown))
            }
        }
        return result
    }

    /// Lowercase, accent-free form of a single word, split on punctuation.
    static func keys(forWord word: String) -> [String] {
        fold(word)
            .split(whereSeparator: { !isWordCharacter($0) })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func key(forWord word: String) -> String {
        keys(forWord: word).joined(separator: " ")
    }

    /// Removes bracket markup, emphasis markup and pause markers, then folds
    /// case/diacritics while keeping punctuation for the splitter.
    private static func prepareForTokenization(_ text: String) -> String {
        let withoutBrackets = removingBracketedSpans(text)
        var result = ""
        result.reserveCapacity(withoutBrackets.count)

        for character in withoutBrackets {
            switch character {
            case "*", "/", "…":
                result.append(" ")
            default:
                result.append(character)
            }
        }
        return result
    }

    /// Removes every `[...]` span, including nested brackets.
    static func removingBracketedSpans(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "[" {
                depth += 1
                continue
            }
            if character == "]" {
                if depth > 0 { depth -= 1 }
                continue
            }
            if depth == 0 { result.append(character) }
        }
        return result
    }

    static func fold(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nonLocalizedLocale)
            .lowercased(with: nonLocalizedLocale)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static let nonLocalizedLocale = Locale(identifier: "en_US_POSIX")
}

/// Splits subtitle/script text into display words, dropping punctuation-only
/// tokens and placeholder markers.
enum PublishedCompareWordTokenizer {
    static func words(in text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { word in
                word.contains { $0.isLetter || $0.isNumber }
            }
    }

    /// Subtitle variant: keeps sentence punctuation attached to its word
    /// (`¿vamos?`, not `vamos`).
    static func subtitleWords(in text: String) -> [String] {
        let rawWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let attachable = CharacterSet(charactersIn: ".,;:!?¡¿\"'“”‘’…-–—")
        let openers = CharacterSet(charactersIn: "¿¡\"'“‘")

        var result: [String] = []
        var pendingPrefix = ""

        for token in rawWords {
            let hasWord = token.contains { $0.isLetter || $0.isNumber }
            if hasWord {
                result.append(pendingPrefix + token)
                pendingPrefix = ""
                continue
            }

            let isAttachable = token.unicodeScalars.allSatisfy { attachable.contains($0) }
            guard isAttachable else { continue }

            let startsWithOpener = token.unicodeScalars.contains { openers.contains($0) }
            if startsWithOpener || result.isEmpty {
                pendingPrefix += token
            } else if let last = result.last {
                result[result.count - 1] = last + token
            }
        }

        if !pendingPrefix.isEmpty, !result.isEmpty {
            result[result.count - 1] += pendingPrefix
        }
        return result
    }
}
