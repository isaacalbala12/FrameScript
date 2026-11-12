import Foundation

/// The single-pass parser behind ``ScriptMarkup``.
///
/// The scanner works on UTF-16 code units so token ranges are already in the
/// coordinate space TextKit uses (and so emoji cost their real width). It only
/// ever splits at ASCII markup characters, never inside a surrogate pair.
struct MarkupParser {
    private enum Unit {
        static let backslash: UInt16 = 0x5C
        static let asterisk: UInt16 = 0x2A
        static let slash: UInt16 = 0x2F
        static let openBracket: UInt16 = 0x5B
        static let closeBracket: UInt16 = 0x5D
        static let lineFeed: UInt16 = 0x0A
        static let carriageReturn: UInt16 = 0x0D
    }

    private let units: [UInt16]
    private let defaults: PauseDefaults
    private let blankLineStarts: [Int]

    init(text: String, defaults: PauseDefaults) {
        self.units = Array(text.utf16)
        self.defaults = defaults.sanitized
        self.blankLineStarts = Self.computeBlankLineStarts(in: units)
    }

    /// Scans the whole script, producing contiguous, non-overlapping tokens.
    func parse() -> [MarkupToken] {
        var tokens: [MarkupToken] = []
        tokens.reserveCapacity(16)
        var buffer: [UInt16] = []
        var segmentStart = 0
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]

            // Escapes are resolved into the text buffer, so they never become markers.
            if unit == Unit.backslash, index + 1 < count, isEscapable(units[index + 1]) {
                buffer.append(units[index + 1])
                index += 2
                continue
            }

            if unit == Unit.asterisk {
                if let result = emphasis(at: index) {
                    appendText(upTo: index, from: segmentStart, buffer: &buffer, into: &tokens)
                    tokens.append(result.token)
                    index = result.end
                    segmentStart = index
                    continue
                }
                // Consume the whole asterisk run so `***` or `**unclosed` can
                // never be re-read as a smaller, valid marker.
                let run = runLength(of: Unit.asterisk, from: index)
                for _ in 0 ..< run { buffer.append(unit) }
                index += run
                continue
            }

            if unit == Unit.slash {
                if let result = pause(at: index) {
                    appendText(upTo: index, from: segmentStart, buffer: &buffer, into: &tokens)
                    tokens.append(result.token)
                    index = result.end
                    segmentStart = index
                    continue
                }
                let run = runLength(of: Unit.slash, from: index)
                for _ in 0 ..< run { buffer.append(unit) }
                index += run
                continue
            }

            if unit == Unit.openBracket {
                if let result = bracket(at: index) {
                    appendText(upTo: index, from: segmentStart, buffer: &buffer, into: &tokens)
                    tokens.append(result.token)
                    index = result.end
                    segmentStart = index
                    continue
                }
                buffer.append(unit)
                index += 1
                continue
            }

            buffer.append(unit)
            index += 1
        }

        appendText(upTo: count, from: segmentStart, buffer: &buffer, into: &tokens)
        return tokens
    }

    // MARK: - Text

    private func appendText(
        upTo end: Int,
        from start: Int,
        buffer: inout [UInt16],
        into tokens: inout [MarkupToken]
    ) {
        guard end > start else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        let content = String(decoding: buffer, as: UTF16.self)
        tokens.append(
            MarkupToken(
                kind: .text,
                range: NSRange(location: start, length: end - start),
                markerRanges: [],
                text: content
            )
        )
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Pause shorthand

    private func pause(at start: Int) -> (token: MarkupToken, end: Int)? {
        let length = runLength(of: Unit.slash, from: start)
        guard length == 1 || length == 2 else { return nil }

        let end = start + length
        guard isLeftBoundary(at: start), isRightBoundary(at: end) else { return nil }

        let seconds = length == 1 ? defaults.short : defaults.long
        let range = NSRange(location: start, length: length)
        return (
            MarkupToken(
                kind: .pause(seconds: max(0, seconds), explicit: false),
                range: range,
                markerRanges: [range],
                text: ""
            ),
            end
        )
    }

    // MARK: - Emphasis

    private func emphasis(at start: Int) -> (token: MarkupToken, end: Int)? {
        let markerLength = runLength(of: Unit.asterisk, from: start)
        guard markerLength == 1 || markerLength == 2 else { return nil }

        let contentStart = start + markerLength
        guard contentStart < units.count else { return nil }
        guard !Self.isWhitespaceUnit(units[contentStart]) else { return nil }
        guard isOpeningBoundary(at: start) else { return nil }

        let limit = firstBlankLineStart(atOrAfter: contentStart) ?? units.count
        var cursor = contentStart

        while cursor < limit {
            let unit = units[cursor]

            if unit == Unit.backslash, cursor + 1 < limit, isEscapable(units[cursor + 1]) {
                cursor += 2
                continue
            }

            if unit == Unit.asterisk {
                let run = runLength(of: Unit.asterisk, from: cursor, limit: limit)
                if run == markerLength,
                   cursor > contentStart,
                   !Self.isWhitespaceUnit(units[cursor - 1]),
                   isClosingBoundary(at: cursor + run) {
                    let level: EmphasisLevel = markerLength == 1 ? .emphasis : .strong
                    let content = decodeEscapes(from: contentStart, to: cursor)
                    return (
                        MarkupToken(
                            kind: .emphasis(level),
                            range: NSRange(location: start, length: cursor + run - start),
                            markerRanges: [
                                NSRange(location: start, length: markerLength),
                                NSRange(location: cursor, length: run),
                            ],
                            text: content
                        ),
                        cursor + run
                    )
                }
                cursor += run
            } else {
                cursor += 1
            }
        }

        return nil
    }

    // MARK: - Brackets

    private func bracket(at start: Int) -> (token: MarkupToken, end: Int)? {
        var cursor = start + 1
        while cursor < units.count {
            let unit = units[cursor]
            if unit == Unit.closeBracket {
                guard let token = bracketToken(start: start, close: cursor) else { return nil }
                return (token, cursor + 1)
            }
            // Cues are single-line and never nest.
            if unit == Unit.openBracket || Self.isLineBreakUnit(unit) { return nil }
            cursor += 1
        }
        return nil
    }

    private func bracketToken(start: Int, close: Int) -> MarkupToken? {
        let raw = String(decoding: units[(start + 1) ..< close], as: UTF16.self)
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let markerRanges = [
            NSRange(location: start, length: 1),
            NSRange(location: close, length: 1),
        ]
        let fullRange = NSRange(location: start, length: close - start + 1)

        if let seconds = pauseSeconds(in: content) {
            return MarkupToken(
                kind: .pause(seconds: max(0, seconds), explicit: true),
                range: fullRange,
                markerRanges: markerRanges,
                text: ""
            )
        }

        let (label, payload) = splitCue(content)
        guard !label.isEmpty else { return nil }
        return MarkupToken(
            kind: .cue(label: label.uppercased(), payload: payload),
            range: fullRange,
            markerRanges: markerRanges,
            text: ""
        )
    }

    /// Recognises `pausa`, `pause`, `pausa 2s`, `2s`, `1,5s`, `1.5 s`, …
    ///
    /// A bare `pausa`/`pause` means the long default. Any other text falls
    /// through so the bracket can be reported as a cue instead of being lost.
    private func pauseSeconds(in content: String) -> TimeInterval? {
        let compact = content.lowercased().filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return nil }

        if compact == "pausa" || compact == "pause" {
            return defaults.long
        }
        if compact.hasPrefix("pausa"), let seconds = parseDuration(String(compact.dropFirst(5))) {
            return seconds
        }
        if compact.hasPrefix("pause"), let seconds = parseDuration(String(compact.dropFirst(5))) {
            return seconds
        }
        return parseDuration(compact)
    }

    /// Parses a non-negative decimal number followed by `s`/`S`.
    ///
    /// Both `1.5s` and `1,5s` are accepted (`1,5` is the Spanish convention;
    /// a comma is always a decimal separator here, never a thousands
    /// separator). Whitespace has already been removed by the caller. A number
    /// without the suffix is not a duration, so `[2]` stays a cue.
    private func parseDuration(_ raw: String) -> TimeInterval? {
        guard raw.count >= 2, raw.last == "s" else { return nil }
        let number = raw.dropLast()
        guard !number.isEmpty else { return nil }

        var sawDigit = false
        var sawSeparator = false
        for scalar in number.unicodeScalars {
            switch scalar.value {
            case 0x30 ... 0x39:
                sawDigit = true
            case 0x2E, 0x2C: // . or ,
                guard !sawSeparator else { return nil }
                sawSeparator = true
            default:
                return nil
            }
        }
        guard sawDigit else { return nil }

        let normalized = number.replacingOccurrences(of: ",", with: ".")
        guard let value = TimeInterval(normalized), value.isFinite, value >= 0 else {
            return nil
        }
        return value
    }

    private func splitCue(_ content: String) -> (label: String, payload: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":") {
            let label = trimmed[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = trimmed[trimmed.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (label, payload)
        }

        // A malformed pause such as `[pausa dos]` stays a cue, but keeping
        // PAUSA as the label and the rest as payload is more useful to an
        // importer than one long label.
        let pieces = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        if let first = pieces.first {
            let keyword = first.lowercased()
            if keyword == "pausa" || keyword == "pause" {
                let payload = pieces.count > 1
                    ? String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                return (String(first), payload)
            }
        }

        return (trimmed, "")
    }

    // MARK: - Boundary helpers

    private func isEscapable(_ unit: UInt16) -> Bool {
        unit == Unit.asterisk || unit == Unit.slash
    }

    /// `true` when a slash at `index` starts a standalone run: the previous
    /// character is whitespace or the text begins here.
    private func isLeftBoundary(at index: Int) -> Bool {
        index <= 0 || Self.isWhitespaceUnit(units[index - 1])
    }

    /// `true` when a slash run ending at `index` is standalone: the next
    /// character is whitespace or the text ends here.
    private func isRightBoundary(at index: Int) -> Bool {
        index >= units.count || Self.isWhitespaceUnit(units[index])
    }

    /// `true` when an emphasis marker may open here: the preceding character
    /// is whitespace or punctuation, or the text begins here. This keeps
    /// `5 * 3`, `2*3*4` and `a*b*` literal.
    private func isOpeningBoundary(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let unit = units[index - 1]
        return Self.isWhitespaceUnit(unit) || Self.isPunctuation(unit)
    }

    /// `true` when an emphasis marker may close here: the following character
    /// is whitespace or punctuation, or the text ends here.
    private func isClosingBoundary(at index: Int) -> Bool {
        guard index < units.count else { return true }
        let unit = units[index]
        return Self.isWhitespaceUnit(unit) || Self.isPunctuation(unit)
    }

    private func runLength(of unit: UInt16, from start: Int, limit: Int? = nil) -> Int {
        let end = min(limit ?? units.count, units.count)
        var cursor = start
        while cursor < end, units[cursor] == unit { cursor += 1 }
        return cursor - start
    }

    private func decodeEscapes(from start: Int, to end: Int) -> String {
        var output: [UInt16] = []
        output.reserveCapacity(max(0, end - start))
        var cursor = start
        while cursor < end {
            if units[cursor] == Unit.backslash,
               cursor + 1 < end,
               isEscapable(units[cursor + 1]) {
                output.append(units[cursor + 1])
                cursor += 2
            } else {
                output.append(units[cursor])
                cursor += 1
            }
        }
        return String(decoding: output, as: UTF16.self)
    }

    // MARK: - Paragraph limits

    private func firstBlankLineStart(atOrAfter index: Int) -> Int? {
        var low = 0
        var high = blankLineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if blankLineStarts[middle] < index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < blankLineStarts.count ? blankLineStarts[low] : nil
    }

    private static func computeBlankLineStarts(in units: [UInt16]) -> [Int] {
        var starts: [Int] = []
        var lineStart = 0
        var cursor = 0
        let count = units.count

        while cursor < count {
            if isLineBreakUnit(units[cursor]) {
                if isBlank(units, from: lineStart, to: cursor) {
                    starts.append(lineStart)
                }
                var next = cursor + 1
                if units[cursor] == Unit.carriageReturn, next < count, units[next] == Unit.lineFeed {
                    next += 1
                }
                lineStart = next
                cursor = next
            } else {
                cursor += 1
            }
        }

        if isBlank(units, from: lineStart, to: count) {
            starts.append(lineStart)
        }
        return starts
    }

    private static func isBlank(_ units: [UInt16], from start: Int, to end: Int) -> Bool {
        var cursor = start
        while cursor < end {
            if !isWhitespaceUnit(units[cursor]) { return false }
            cursor += 1
        }
        return true
    }

    private static func isLineBreakUnit(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    private static func isWhitespaceUnit(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09 ... 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000 ... 0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// ASCII punctuation plus the punctuation common in Spanish scripts.
    private static func isPunctuation(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x21 ... 0x2F, // ! " # $ % & ' ( ) * + , - . /
             0x3A ... 0x40, // : ; < = > ? @
             0x5B ... 0x60, // [ \ ] ^ _ `
             0x7B ... 0x7E, // { | } ~
             0x00A1, 0x00A7, 0x00B7, 0x00AB, 0x00BF, 0x00BB,
             0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x2039, 0x203A:
            return true
        default:
            return false
        }
    }
}
