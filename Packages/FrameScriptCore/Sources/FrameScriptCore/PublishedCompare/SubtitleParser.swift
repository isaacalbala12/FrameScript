import Foundation

/// A word with its real timing from a subtitle stream.
public struct SubtitleWord: Sendable, Equatable, Hashable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A clean subtitle segment: one caption line (or one SRT cue) after removing
/// YouTube's rolling duplicates, with optional word-level timings.
public struct SubtitleSegment: Sendable, Equatable, Hashable, Codable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var words: [SubtitleWord]

    public init(start: TimeInterval, end: TimeInterval, text: String, words: [SubtitleWord] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    public init(words: [SubtitleWord]) {
        self.words = words
        self.start = words.first?.start ?? 0
        self.end = words.last?.end ?? self.start
        self.text = words.map(\.text).joined(separator: " ")
    }

    var duration: TimeInterval {
        max(0, end - start)
    }
}

public enum SubtitleFormat: String, Sendable, Equatable, CaseIterable, Codable {
    case srt
    case webVTT

    public static func detect(from text: String) -> SubtitleFormat {
        let firstLine = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.uppercased().hasPrefix("WEBVTT") ? .webVTT : .srt
    }
}

public enum SubtitleParserError: Error, Equatable, Sendable, LocalizedError {
    case emptyInput
    case noCuesFound
    case invalidTimestamp(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The subtitle file is empty."
        case .noCuesFound:
            return "No timed subtitle cues were found."
        case .invalidTimestamp(let value):
            return "Invalid subtitle timestamp: \(value)"
        }
    }
}

/// Parses SRT and WebVTT subtitle files.
///
/// YouTube's auto-generated WebVTT is supported explicitly: inline
/// `<00:00:01.234>` timestamps and `<c>...</c>` tags are understood, and the
/// duplicated rolling caption lines are folded into one clean segment per
/// spoken caption line.
public enum SubtitleParser {
    public static func parse(
        _ text: String,
        format: SubtitleFormat? = nil
    ) throws -> [SubtitleSegment] {
        let resolved = format ?? SubtitleFormat.detect(from: text)
        switch resolved {
        case .srt:
            return try parseSRT(text)
        case .webVTT:
            return try parseWebVTT(text)
        }
    }

    // MARK: - SRT

    public static func parseSRT(_ text: String) throws -> [SubtitleSegment] {
        let normalized = normalizeLineEndings(text)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw SubtitleParserError.emptyInput
        }

        var cues: [ParsedCue] = []
        var index = 0
        var expectedCueNumber = 1
        while index < lines.count {
            guard let timing = parseCueTimingLine(lines[index]) else {
                index += 1
                continue
            }

            var cueTextLines: [String] = []
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                if parseCueTimingLine(line) != nil { break }
                cueTextLines.append(line)
                index += 1
            }

            // Some files omit the blank line between cues. A bare cue number
            // immediately before the next timing line is not subtitle text, but
            // numeric payload (years, scores) must survive.
            if cueTextLines.count > 1,
               let last = cueTextLines.last?.trimmingCharacters(in: .whitespaces),
               !last.isEmpty,
               last.allSatisfy(\.isNumber),
               Int(last) == expectedCueNumber + 1,
               index < lines.count,
               parseCueTimingLine(lines[index]) != nil {
                cueTextLines.removeLast()
            }

            let plain = cueTextLines
                .map { stripMarkup($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { continue }
            let words = makeWords(from: plain, start: timing.start, end: timing.end)
            cues.append(ParsedCue(start: timing.start, end: timing.end, lines: [words], plainText: plain, hasInlineTimestamps: false))
            expectedCueNumber += 1
        }

        guard !cues.isEmpty else { throw SubtitleParserError.noCuesFound }
        return cues.map(makeSegment(from:))
    }

    // MARK: - WebVTT

    public static func parseWebVTT(_ text: String) throws -> [SubtitleSegment] {
        let normalized = normalizeLineEndings(text)
        let rawLines = normalized.components(separatedBy: "\n")
        let prepared = prepareWebVTTBlockSeparators(rawLines).joined(separator: "\n")
        let blocks = prepared
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !blocks.isEmpty else { throw SubtitleParserError.emptyInput }

        var cues: [ParsedCue] = []
        var sawYouTubeAutoStyle = false

        for block in blocks {
            let rawLines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let lines = rawLines.filter { !$0.isEmpty }
            guard let firstNonEmpty = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                continue
            }
            let upper = firstNonEmpty.trimmingCharacters(in: .whitespaces).uppercased()
            if upper.hasPrefix("NOTE") || upper.hasPrefix("STYLE") || upper.hasPrefix("REGION") {
                continue
            }
            if upper.hasPrefix("WEBVTT") && !block.contains("-->") {
                continue
            }

            guard let timingLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            guard let timing = parseCueTimingLine(lines[timingLineIndex]) else {
                throw SubtitleParserError.invalidTimestamp(lines[timingLineIndex])
            }
            let settings = timingLineSettings(lines[timingLineIndex])
            let looksAuto = settings.contains("align:start") && settings.contains("position:0%")
            let textLines = Array(
                lines[(timingLineIndex + 1)...].prefix { parseCueTimingLine($0) == nil }
            )
            guard !textLines.isEmpty else { continue }

            let parsedLines = textLines.compactMap { line -> CueLine? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                return parseVTTTextLine(trimmed, cueStart: timing.start, cueEnd: timing.end)
            }
            guard !parsedLines.isEmpty else { continue }

            let hasInline = parsedLines.contains(where: \.hasInlineTimestamps)
            if hasInline || looksAuto { sawYouTubeAutoStyle = true }

            let plain = parsedLines.map(\.plainText).joined(separator: " ")
            cues.append(
                ParsedCue(
                    start: timing.start,
                    end: timing.end,
                    lines: parsedLines.map(\.words),
                    plainText: plain,
                    hasInlineTimestamps: hasInline
                )
            )
        }

        guard !cues.isEmpty else { throw SubtitleParserError.noCuesFound }
        if sawYouTubeAutoStyle {
            return deduplicateYouTubeRollingCues(cues)
        }
        return cues.map(makeSegment(from:))
    }
}

// MARK: - Internal parsing types

struct ParsedCue {
    var start: TimeInterval
    var end: TimeInterval
    /// Non-empty display lines, each with word timings.
    var lines: [[SubtitleWord]]
    var plainText: String
    var hasInlineTimestamps: Bool
}

struct CueLine {
    var words: [SubtitleWord]
    var plainText: String
    var hasInlineTimestamps: Bool
}

extension SubtitleParser {
    static func normalizeLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// WebVTT blocks are separated by blank lines, but some files use a line
    /// containing only spaces. Keep a whitespace-only *caption placeholder*
    /// (YouTube auto-captions use one) and only turn it into a separator when
    /// the next meaningful line starts a cue.
    static func prepareWebVTTBlockSeparators(_ lines: [String]) -> [String] {
        var result = lines
        for index in lines.indices where !lines[index].isEmpty && isWhitespaceOnly(lines[index]) {
            if isWebVTTBlockBoundary(after: index, lines: lines) {
                result[index] = ""
            }
        }
        return result
    }

    static func isWebVTTBlockBoundary(after index: Int, lines: [String]) -> Bool {
        var next = index + 1
        while next < lines.count && isWhitespaceOnly(lines[next]) { next += 1 }
        guard next < lines.count else { return true }
        if lines[next].contains("-->") { return true }
        if next + 1 < lines.count,
           isCueIdentifierLine(lines[next]),
           lines[next + 1].contains("-->") {
            return true
        }
        return false
    }

    static func isWhitespaceOnly(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func isCueIdentifierLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains("-->"), !trimmed.contains("<") else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    static func parseCueTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startToken = parts[0].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let endToken = parts[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let start = parseTimecode(startToken), let end = parseTimecode(endToken) else { return nil }
        return (start, max(start, end))
    }

    static func timingLineSettings(_ line: String) -> String {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return "" }
        let afterEnd = parts[1].trimmingCharacters(in: .whitespaces)
        guard let firstSpace = afterEnd.firstIndex(where: \.isWhitespace) else { return "" }
        return String(afterEnd[afterEnd.index(after: firstSpace)...]).lowercased()
    }

    static func parseTimecode(_ raw: String) -> TimeInterval? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: ",", with: ".")
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        guard let seconds = Double(parts[parts.count - 1]), seconds >= 0 else { return nil }
        guard seconds < 60 else { return nil }

        let minutesPart = parts[parts.count - 2]
        guard let minutes = Double(minutesPart), minutes >= 0, minutes < 60 else { return nil }

        if parts.count == 2 {
            return minutes * 60 + seconds
        }

        guard let hours = Double(parts[0]), hours >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    static func stripMarkup(_ text: String) -> String {
        decodeEntities(removeAngleTags(text))
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeAngleTags(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<", let close = text[index...].firstIndex(of: ">") {
                let content = String(text[text.index(after: index)..<close])
                if isSubtitleTag(content) {
                    result.append(" ")
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    static func isSubtitleTag(_ rawContent: String) -> Bool {
        let content = rawContent.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return false }
        let body = content.hasPrefix("/") ? String(content.dropFirst()) : content
        let name = body.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? body
        guard !name.isEmpty else { return false }
        if name.contains(":") { return parseTimecode(name) != nil }
        let lower = name.lowercased()
        if lower.hasPrefix("c.") { return true }
        return subtitleTagNames.contains(lower)
    }

    static let subtitleTagNames: Set<String> = [
        "i", "b", "u", "c", "v", "lang", "font", "ruby", "rt",
        "em", "strong", "span", "br", "voice", "prosody"
    ]

    static func decodeEntities(_ text: String) -> String {
        let named: [String: String] = [
            "amp": "&",
            "lt": "<",
            "gt": ">",
            "quot": "\"",
            "apos": "'",
            "nbsp": " "
        ]
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                  let semicolon = text[index...].firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let body = String(text[text.index(after: index)..<semicolon])
            if let replacement = decodeEntityBody(body, named: named) {
                result.append(replacement)
                index = text.index(after: semicolon)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    static func decodeEntityBody(_ body: String, named: [String: String]) -> String? {
        if let value = named[body] { return value }
        guard body.hasPrefix("#") else { return nil }
        let digits = String(body.dropFirst())
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = UnicodeScalar(value) else { return nil }
        return String(scalar)
    }

    /// Distributes words across a cue proportionally to their character count.
    static func makeWords(from text: String, start: TimeInterval, end: TimeInterval) -> [SubtitleWord] {
        let words = PublishedCompareWordTokenizer.subtitleWords(in: text)
        guard !words.isEmpty else { return [] }
        let safeEnd = max(end, start)
        let totalWeight = max(1, words.reduce(0) { $0 + max(1, $1.count) })
        var weightsBefore = 0
        var result: [SubtitleWord] = []
        result.reserveCapacity(words.count)

        for (index, word) in words.enumerated() {
            let weight = max(1, word.count)
            let wordStart = start + (safeEnd - start) * (Double(weightsBefore) / Double(totalWeight))
            weightsBefore += weight
            let wordEnd: TimeInterval
            if index == words.count - 1 {
                wordEnd = safeEnd
            } else {
                wordEnd = start + (safeEnd - start) * (Double(weightsBefore) / Double(totalWeight))
            }
            result.append(SubtitleWord(text: word, start: max(start, wordStart), end: max(wordStart, wordEnd)))
        }
        return result
    }

    /// Parses a WebVTT payload line, preserving inline `<timestamp>` starts.
    static func parseVTTTextLine(
        _ line: String,
        cueStart: TimeInterval,
        cueEnd: TimeInterval
    ) -> CueLine {
        var chunks: [(text: String, start: TimeInterval?)] = []
        var current = ""
        var currentStart: TimeInterval?
        var hasInline = false
        var index = line.startIndex

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append((current, currentStart))
            current = ""
        }

        while index < line.endIndex {
            let character = line[index]
            if character == "<", let close = line[index...].firstIndex(of: ">") {
                let tag = String(line[line.index(after: index)..<close])
                if let timestamp = parseInlineTimestamp(tag) {
                    flush()
                    currentStart = timestamp
                    hasInline = true
                } else if isSubtitleTag(tag) {
                    // Non-timestamp tags separate words only when they sit
                    // between two word characters. This keeps punctuation
                    // attached (`<c>rápida</c>?` → `rápida?`).
                    let nextIndex = line.index(after: close)
                    let nextCharacter = nextIndex < line.endIndex ? line[nextIndex] : nil
                    if let last = current.last,
                       let next = nextCharacter,
                       isWordCharacter(last), isWordCharacter(next) {
                        current.append(" ")
                    }
                } else {
                    // Not a subtitle tag: keep the '<' as literal text.
                    current.append(character)
                    index = line.index(after: index)
                    continue
                }
                index = line.index(after: close)
                continue
            }
            current.append(character)
            index = line.index(after: index)
        }
        flush()

        guard !chunks.isEmpty else {
            return CueLine(words: [], plainText: "", hasInlineTimestamps: hasInline)
        }

        // Merge punctuation-only runs into the adjacent word run. This keeps
        // `¿` attached to the next word and a trailing `?` to the previous one.
        var mergedChunks: [(text: String, start: TimeInterval?)] = []
        var pendingPunctuation = ""
        for chunk in chunks {
            if chunk.text.contains(where: isWordCharacter) {
                mergedChunks.append((pendingPunctuation + chunk.text, chunk.start))
                pendingPunctuation = ""
            } else {
                pendingPunctuation += chunk.text
            }
        }
        if !pendingPunctuation.isEmpty, !mergedChunks.isEmpty {
            mergedChunks[mergedChunks.count - 1].text += pendingPunctuation
        }
        let effectiveChunks = mergedChunks.isEmpty ? chunks : mergedChunks

        var words: [SubtitleWord] = []
        for (chunkIndex, chunk) in effectiveChunks.enumerated() {
            let chunkStart = chunk.start ?? cueStart
            let nextStart = effectiveChunks.dropFirst(chunkIndex + 1).compactMap(\.start).first
            var chunkEnd = nextStart ?? cueEnd
            if chunkEnd < chunkStart { chunkEnd = max(chunkEnd, cueEnd) }
            if chunkEnd <= chunkStart { chunkEnd = chunkStart + 0.001 }
            let chunkWords = makeWords(from: decodeEntities(chunk.text), start: chunkStart, end: chunkEnd)
            words.append(contentsOf: chunkWords)
        }

        words.sort { $0.start < $1.start }
        let plain = words.map(\.text).joined(separator: " ")
        return CueLine(words: words, plainText: plain, hasInlineTimestamps: hasInline)
    }

    static func parseInlineTimestamp(_ tag: String) -> TimeInterval? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains(":"), !trimmed.contains(" ") else { return nil }
        return parseTimecode(trimmed)
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func makeSegment(from cue: ParsedCue) -> SubtitleSegment {
        let words = cue.lines.flatMap { $0 }
        let text = cue.plainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            return SubtitleSegment(
                start: words.first?.start ?? cue.start,
                end: words.last?.end ?? cue.end,
                text: text.isEmpty ? words.map(\.text).joined(separator: " ") : text,
                words: words
            )
        }
        return SubtitleSegment(start: cue.start, end: cue.end, text: cue.plainText)
    }

    /// YouTube auto-captions repeatedly display the previous caption line and
    /// then the new line, with a short "settle" cue in between. A cue is treated
    /// as rolling only when its earlier lines duplicate text already emitted;
    /// otherwise every line is real content (karaoke, two-line human captions).
    /// A full repeat is skipped only for a short settle cue.
    static func deduplicateYouTubeRollingCues(_ cues: [ParsedCue]) -> [SubtitleSegment] {
        var emittedKeys: [String] = []
        var segments: [SubtitleSegment] = []

        for cue in cues {
            guard !cue.lines.isEmpty else { continue }

            let candidate: [SubtitleWord]
            if cue.lines.count >= 2 {
                let prefixWords = cue.lines.dropLast().flatMap { $0 }
                let prefixKeys = prefixWords.map { ScriptNormalizer.key(forWord: $0.text) }
                let prefixOverlap = longestSuffixPrefixOverlap(suffix: emittedKeys, prefix: prefixKeys)
                if !prefixKeys.isEmpty, prefixOverlap == prefixKeys.count {
                    candidate = cue.lines[cue.lines.count - 1]
                } else {
                    candidate = cue.lines.flatMap { $0 }
                }
            } else {
                candidate = cue.lines[0]
            }

            guard !candidate.isEmpty else { continue }
            let candidateKeys = candidate.map { ScriptNormalizer.key(forWord: $0.text) }
            guard candidateKeys.contains(where: { !$0.isEmpty }) else { continue }

            let isSettleCue = (cue.end - cue.start) < 0.1 && cue.lines.count == 1
            if isSettleCue {
                let overlap = longestSuffixPrefixOverlap(suffix: emittedKeys, prefix: candidateKeys)
                if overlap == candidateKeys.count { continue }
            }

            emittedKeys.append(contentsOf: candidateKeys)
            var segment = SubtitleSegment(words: candidate)
            if segment.end < segment.start {
                segment.end = cue.end
            }
            segments.append(segment)
        }

        return segments
    }

    static func longestSuffixPrefixOverlap(suffix: [String], prefix: [String]) -> Int {
        let maximum = min(suffix.count, prefix.count)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if suffix.suffix(length).elementsEqual(prefix.prefix(length)) {
                return length
            }
        }
        return 0
    }
}
