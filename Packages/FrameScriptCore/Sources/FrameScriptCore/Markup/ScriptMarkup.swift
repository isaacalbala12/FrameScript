import Foundation

/// Parses the Markdown-style pause and emphasis markers that live directly in
/// a script.
///
/// The syntax is intentionally small and survives copy/paste, plain-text export
/// and AI editing:
///
/// | Syntax | Meaning |
/// |---|---|
/// | `/` between whitespace or at a line edge | short pause (`PauseDefaults.short`, 0.5 s) |
/// | `//` between whitespace or at a line edge | long pause (`PauseDefaults.long`, 1.0 s) |
/// | `[pausa]`, `[pause]` | long pause |
/// | `[pausa 2s]`, `[pausa 1,5s]`, `[2s]`, `[1.5 s]` | explicit pause in seconds |
/// | `*word*` or `*a few words*` | emphasis |
/// | `**word**` | strong emphasis |
/// | `[IMAGEN: …]`, `[RE-HOOK]`, `[B-ROLL]` | cue, not spoken |
///
/// Slashes inside tokens (`km/h`, `1/4`, `and/or`, `https://…`, `12/11`) stay
/// literal, runs of three or more slashes stay literal, and `\*` / `\/` escape
/// their marker. Emphasis delimiters must hug their content and may span line
/// breaks, but cannot cross a blank line. Inline emphasis does not
/// nest, but pauses and cues inside an emphasis span are still parsed: the span
/// is split into `.emphasis` segments around them, with the opening delimiter
/// on the first segment and the closing delimiter on the last.
///
/// Every range returned by ``parse(_:defaults:)`` is a UTF-16 `NSRange` into the
/// original string, ready for TextKit.
public enum ScriptMarkup {
    /// Parses a script into ordered, non-overlapping tokens covering the whole
    /// input.
    ///
    /// - Parameters:
    ///   - text: The script text, markers included.
    ///   - defaults: The configured short and long pause durations.
    /// - Returns: Tokens whose ranges use UTF-16 code units. Every character of
    ///   `text` belongs to exactly one token.
    public static func parse(_ text: String, defaults: PauseDefaults = .standard) -> [MarkupToken] {
        MarkupParser(text: text, defaults: defaults).parse()
    }

    /// Returns the script with all markers removed, suitable for clean export
    /// or speech.
    ///
    /// Escapes are resolved, pauses and cues disappear (leaving a word break
    /// where needed), line endings are normalised to `\n`, horizontal
    /// whitespace is collapsed, whitespace left before tight punctuation
    /// (`, . ; : ! ? ) ] } » ”`) by a removed marker is dropped, at most one
    /// blank line is kept between paragraphs and leading/trailing whitespace is
    /// trimmed. For marker-free text this is the original text modulo
    /// whitespace.
    public static func spokenText(_ text: String) -> String {
        spokenText(from: parse(text))
    }

    /// Counts the spoken words in a script, ignoring markers and cues.
    ///
    /// A word is a whitespace-separated run containing at least one letter or
    /// digit, so `km/h` counts once and a lone `—` or emoji does not count.
    public static func spokenWordCount(_ text: String) -> Int {
        wordCount(in: spokenText(text))
    }

    /// Estimates how long the script takes to read aloud.
    ///
    /// The result is `spokenWords / wordsPerMinute` minutes plus the sum of all
    /// pause durations. Cues and their payloads never count. A
    /// non-positive or non-finite `wordsPerMinute` contributes zero reading
    /// time while pauses are still counted.
    ///
    /// - Parameters:
    ///   - text: The script text, markers included.
    ///   - wordsPerMinute: Reading speed for the script's language.
    ///   - defaults: The configured short and long pause durations.
    /// - Returns: The estimated duration in seconds.
    public static func estimateDuration(
        _ text: String,
        wordsPerMinute: Double,
        defaults: PauseDefaults = .standard
    ) -> TimeInterval {
        estimate(text, wordsPerMinute: wordsPerMinute, defaults: defaults).duration
    }

    /// Word count and duration from a single parse.
    ///
    /// Consumers that show both numbers (the editor header, the app's debounced
    /// scene metrics) should use this instead of calling ``spokenWordCount(_:)``
    /// and ``estimateDuration(_:wordsPerMinute:defaults:)`` back to back, which
    /// would parse the whole script twice.
    ///
    /// - Parameters:
    ///   - text: The script text, markers included.
    ///   - wordsPerMinute: Reading speed for the script's language.
    ///   - defaults: The configured short and long pause durations.
    /// - Returns: The spoken word count and the estimated duration in seconds.
    public static func estimate(
        _ text: String,
        wordsPerMinute: Double,
        defaults: PauseDefaults = .standard
    ) -> MarkupEstimate {
        let tokens = parse(text, defaults: defaults)
        var seconds = 0.0
        for token in tokens {
            if case .pause(let pause, _) = token.kind {
                seconds += max(0, pause)
            }
        }
        let words = wordCount(in: spokenText(from: tokens))
        if wordsPerMinute.isFinite, wordsPerMinute > 0 {
            seconds += Double(words) / wordsPerMinute * 60
        }
        return MarkupEstimate(spokenWordCount: words, duration: seconds)
    }

    /// Flattens a script into display runs for a teleprompter.
    ///
    /// Adjacent plain-text tokens are merged. Emphasis keeps its visible text
    /// and level, pauses keep their duration in seconds, and cues keep only
    /// their canonical label. Empty emphasis segments (produced when a pause
    /// sits directly inside the delimiters, e.g. `*[pausa]*`) are skipped.
    ///
    /// - Parameters:
    ///   - text: The script text, markers included.
    ///   - defaults: The configured short and long pause durations.
    /// - Returns: The visible runs in reading order.
    public static func runs(_ text: String, defaults: PauseDefaults = .standard) -> [MarkupRun] {
        var result: [MarkupRun] = []
        for token in parse(text, defaults: defaults) {
            switch token.kind {
            case .text:
                guard !token.text.isEmpty else { continue }
                if case .text(let existing)? = result.last {
                    result[result.count - 1] = .text(existing + token.text)
                } else {
                    result.append(.text(token.text))
                }
            case .emphasis(let level):
                guard !token.text.isEmpty else { continue }
                result.append(.emphasis(token.text, level: level))
            case .pause(let seconds, _):
                result.append(.pause(seconds))
            case .cue(let label, _):
                result.append(.cue(label))
            }
        }
        return result
    }

    // MARK: - Shared text processing

    /// Builds the untidied spoken string from already-parsed tokens.
    ///
    /// When a marker is removed between a word and punctuation, the whitespace
    /// that surrounded it is dropped (`Hola [pausa], mundo` becomes
    /// `Hola, mundo`). Without markers, text spacing is left untouched.
    static func spokenText(from tokens: [MarkupToken]) -> String {
        var raw = String()
        raw.reserveCapacity(64)
        var pendingMarkerRemoval = false

        func appendAfterRemovedMarker(_ segment: String) {
            var dropped = 0
            for character in segment {
                if character.isWhitespace, !character.isNewline {
                    dropped += 1
                } else {
                    break
                }
            }
            let remainder = segment.dropFirst(dropped)

            if let first = remainder.first, isTightPunctuation(first) {
                while let last = raw.last, last.isWhitespace, !last.isNewline {
                    raw.removeLast()
                }
                raw.append(contentsOf: remainder)
            } else {
                if let last = raw.last, !last.isWhitespace,
                   let first = segment.first, !first.isWhitespace {
                    raw.append(" ")
                }
                raw.append(segment)
            }
        }

        for token in tokens {
            switch token.kind {
            case .text:
                if pendingMarkerRemoval {
                    pendingMarkerRemoval = false
                    appendAfterRemovedMarker(token.text)
                } else {
                    raw.append(token.text)
                }
            case .emphasis:
                guard !token.text.isEmpty else { break }
                if pendingMarkerRemoval {
                    pendingMarkerRemoval = false
                    appendAfterRemovedMarker(token.text)
                } else {
                    raw.append(token.text)
                }
            case .pause, .cue:
                pendingMarkerRemoval = true
            }
        }

        return tidyWhitespace(raw)
    }

    /// Normalises whitespace: LF line endings, single spaces inside a line, at
    /// most one blank line between paragraphs, no leading or trailing blanks.
    static func tidyWhitespace(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [String] = []
        var sawContent = false
        var pendingBlankLine = false

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = collapseHorizontalWhitespace(in: line)
            if collapsed.isEmpty {
                if sawContent { pendingBlankLine = true }
            } else {
                if pendingBlankLine { lines.append("") }
                pendingBlankLine = false
                sawContent = true
                lines.append(collapsed)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func collapseHorizontalWhitespace(in line: Substring) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var pendingSpace = false
        for character in line {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// Punctuation that must not be preceded by a space in clean output. When
    /// a marker is removed between a word and one of these characters, the
    /// surrounding whitespace would otherwise leave `Hola , mundo` or
    /// `Hola . Adiós.`.
    private static func isTightPunctuation(_ character: Character) -> Bool {
        switch character {
        case ",", ".", ";", ":", "!", "?", ")", "]", "}", "»", "”":
            return true
        default:
            return false
        }
    }

    /// Counts whitespace-separated runs that contain at least one letter or
    /// digit. Punctuation-only and emoji-only runs are not words.
    static func wordCount(in text: String) -> Int {
        var count = 0
        var runHasWordCharacter = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if runHasWordCharacter { count += 1 }
                runHasWordCharacter = false
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                runHasWordCharacter = true
            }
        }
        if runHasWordCharacter { count += 1 }
        return count
    }
}
