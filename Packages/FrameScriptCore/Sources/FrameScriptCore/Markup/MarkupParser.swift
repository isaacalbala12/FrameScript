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
        self.defaults = defaults
        self.blankLineStarts = Self.computeBlankLineStarts(in: units)
    }

    /// Scans the whole script into tokens.
    ///
    /// The work is done in three linear passes: atomisation (text, asterisk
    /// runs, pauses and cues), emphasis matching (one active opener at a time)
    /// and token assembly (splitting emphasis around inner pauses/cues).
    func parse() -> [MarkupToken] {
        let atoms = atomize()
        let matches = matchEmphasis(in: atoms)
        return buildTokens(from: atoms, matches: matches)
    }

    // MARK: - Atomisation

    private enum Atom {
        case text(NSRange)
        case asterisks(range: NSRange, canOpen: Bool, canClose: Bool)
        case token(MarkupToken)

        var range: NSRange {
            switch self {
            case .text(let range), .asterisks(let range, _, _):
                return range
            case .token(let token):
                return token.range
            }
        }

        var token: MarkupToken? {
            if case .token(let token) = self { return token }
            return nil
        }
    }

    private func atomize() -> [Atom] {
        var atoms: [Atom] = []
        atoms.reserveCapacity(16)
        var textStart = 0
        var index = 0
        let count = units.count

        func flushText(upTo end: Int) {
            if end > textStart {
                atoms.append(.text(NSRange(location: textStart, length: end - textStart)))
            }
            textStart = end
        }

        while index < count {
            let unit = units[index]

            if unit == Unit.backslash, index + 1 < count, isEscapable(units[index + 1]) {
                index += 2 // stays inside the current text span
                continue
            }

            if unit == Unit.asterisk {
                let run = runLength(of: Unit.asterisk, from: index)
                flushText(upTo: index)

                let isDelimiterRun = run == 1 || run == 2
                let canOpen = isDelimiterRun
                    && isOpeningBoundary(at: index)
                    && index + run < count
                    && !Self.isWhitespaceUnit(units[index + run])
                let canClose = isDelimiterRun
                    && index > 0
                    && !Self.isWhitespaceUnit(units[index - 1])
                    && isClosingBoundary(at: index + run)

                atoms.append(
                    .asterisks(
                        range: NSRange(location: index, length: run),
                        canOpen: canOpen,
                        canClose: canClose
                    )
                )
                index += run
                textStart = index
                continue
            }

            if unit == Unit.slash {
                if let result = pause(at: index) {
                    flushText(upTo: index)
                    atoms.append(.token(result.token))
                    index = result.end
                    textStart = index
                    continue
                }
                index += runLength(of: Unit.slash, from: index)
                continue
            }

            if unit == Unit.openBracket, let result = bracket(at: index) {
                flushText(upTo: index)
                atoms.append(.token(result.token))
                index = result.end
                textStart = index
                continue
            }

            index += 1
        }

        flushText(upTo: count)
        return atoms
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

    // MARK: - Emphasis matching

    private struct EmphasisMatch {
        let closeIndex: Int
        let level: EmphasisLevel
    }

    /// Matches at most one emphasis span at a time.
    ///
    /// Inline markup does not nest, so a single active opener is enough. Each
    /// asterisk run is examined once and an unmatched opener never triggers a
    /// rescan, which keeps this pass linear even for scripts full of unclosed
    /// `*word` markers.
    private func matchEmphasis(in atoms: [Atom]) -> [Int: EmphasisMatch] {
        var matches: [Int: EmphasisMatch] = [:]
        var active: (index: Int, range: NSRange, limit: Int)?

        for (atomIndex, atom) in atoms.enumerated() {
            guard case .asterisks(let range, let canOpen, let canClose) = atom else { continue }

            if let opener = active, range.location >= opener.limit {
                active = nil // paragraph break: the opener stays literal
            }

            guard let opener = active else {
                if canOpen {
                    let limit = firstBlankLineStart(atOrAfter: NSMaxRange(range)) ?? units.count
                    active = (atomIndex, range, limit)
                }
                continue
            }

            if range.length == opener.range.length, canClose {
                matches[opener.index] = EmphasisMatch(
                    closeIndex: atomIndex,
                    level: opener.range.length == 1 ? .emphasis : .strong
                )
                active = nil
            }
        }

        return matches
    }

    // MARK: - Token assembly

    private func buildTokens(from atoms: [Atom], matches: [Int: EmphasisMatch]) -> [MarkupToken] {
        var tokens: [MarkupToken] = []
        tokens.reserveCapacity(atoms.count)
        var pendingTextStart: Int?
        var pendingTextEnd = 0

        func flushText() {
            guard let start = pendingTextStart else { return }
            if pendingTextEnd > start {
                let range = NSRange(location: start, length: pendingTextEnd - start)
                tokens.append(
                    MarkupToken(
                        kind: .text,
                        range: range,
                        markerRanges: [],
                        escapeRanges: escapeRanges(in: range),
                        text: decodeEscapes(from: range.location, to: NSMaxRange(range))
                    )
                )
            }
            pendingTextStart = nil
        }

        func appendLiteral(_ range: NSRange) {
            if pendingTextStart == nil {
                pendingTextStart = range.location
                pendingTextEnd = NSMaxRange(range)
            } else if range.location == pendingTextEnd {
                pendingTextEnd = NSMaxRange(range)
            } else {
                flushText()
                pendingTextStart = range.location
                pendingTextEnd = NSMaxRange(range)
            }
        }

        var index = 0
        while index < atoms.count {
            if let match = matches[index] {
                flushText()

                let openRange = atoms[index].range
                let closeRange = atoms[match.closeIndex].range
                var cursor = openRange.location
                var contentStart = NSMaxRange(openRange)
                var ownsOpening = true

                var innerIndex = index + 1
                while innerIndex < match.closeIndex {
                    if let innerToken = atoms[innerIndex].token {
                        // Skip an empty segment between two adjacent inner
                        // markers: it carries no text and owns no delimiter.
                        if innerToken.range.location > cursor {
                            tokens.append(
                                emphasisToken(
                                    level: match.level,
                                    rangeStart: cursor,
                                    contentStart: contentStart,
                                    contentEnd: innerToken.range.location,
                                    rangeEnd: innerToken.range.location,
                                    openingMarker: ownsOpening ? openRange : nil,
                                    closingMarker: nil
                                )
                            )
                        }
                        tokens.append(innerToken)
                        cursor = NSMaxRange(innerToken.range)
                        contentStart = cursor
                        ownsOpening = false
                    }
                    innerIndex += 1
                }

                tokens.append(
                    emphasisToken(
                        level: match.level,
                        rangeStart: cursor,
                        contentStart: contentStart,
                        contentEnd: closeRange.location,
                        rangeEnd: NSMaxRange(closeRange),
                        openingMarker: ownsOpening ? openRange : nil,
                        closingMarker: closeRange
                    )
                )

                index = match.closeIndex + 1
                continue
            }

            switch atoms[index] {
            case .text(let range), .asterisks(let range, _, _):
                appendLiteral(range)
            case .token(let token):
                flushText()
                tokens.append(token)
            }
            index += 1
        }

        flushText()
        return tokens
    }

    /// Builds one emphasis segment. `rangeStart...rangeEnd` is the segment's
    /// full extent (delimiters included when owned); the spoken content is
    /// `contentStart..<contentEnd`.
    private func emphasisToken(
        level: EmphasisLevel,
        rangeStart: Int,
        contentStart: Int,
        contentEnd: Int,
        rangeEnd: Int,
        openingMarker: NSRange?,
        closingMarker: NSRange?
    ) -> MarkupToken {
        var markers: [NSRange] = []
        if let openingMarker { markers.append(openingMarker) }
        if let closingMarker { markers.append(closingMarker) }

        let safeContentEnd = max(contentStart, contentEnd)
        let contentRange = NSRange(location: contentStart, length: safeContentEnd - contentStart)
        return MarkupToken(
            kind: .emphasis(level),
            range: NSRange(location: rangeStart, length: max(0, rangeEnd - rangeStart)),
            markerRanges: markers,
            escapeRanges: escapeRanges(in: contentRange),
            text: decodeEscapes(from: contentStart, to: safeContentEnd)
        )
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

    private func runLength(of unit: UInt16, from start: Int) -> Int {
        var cursor = start
        while cursor < units.count, units[cursor] == unit { cursor += 1 }
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

    /// The backslash positions of `\*` / `\/` escapes inside `range`. The
    /// escaped character itself is normal content and is not included.
    private func escapeRanges(in range: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            if units[cursor] == Unit.backslash,
               cursor + 1 < end,
               isEscapable(units[cursor + 1]) {
                result.append(NSRange(location: cursor, length: 1))
                cursor += 2
            } else {
                cursor += 1
            }
        }
        return result
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
