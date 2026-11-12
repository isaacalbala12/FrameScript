import Foundation

/// Small, dependency-free Markdown helpers shared by the escaleta and
/// thumbnail parsers.
enum MarkdownParsingSupport {
    // MARK: Normalisation

    static func normalizedLines(_ text: String) -> [String] {
        var value = text
        if value.unicodeScalars.first?.value == 0xFEFF {
            value.removeFirst()
        }
        value = value.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        if value.hasSuffix("\n") {
            value.removeLast()
        }
        return value.components(separatedBy: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    static func trimmedBlock(_ lines: ArraySlice<String>) -> String {
        var start = lines.startIndex
        var end = lines.endIndex
        while start < end, isBlank(lines[start]) { start += 1 }
        while end > start, isBlank(lines[end - 1]) { end -= 1 }
        guard start < end else { return "" }
        return lines[start..<end].joined(separator: "\n")
    }

    static func trimmedBlock(_ lines: [String]) -> String {
        trimmedBlock(lines[...])
    }

    /// Removes trailing blank lines and a final horizontal rule. Known sections
    /// use this so the separator between sections does not leak into content.
    static func linesWithoutTrailingRule(_ lines: [String]) -> [String] {
        var end = lines.count
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        if end > 0, isHorizontalRule(lines[end - 1]) { end -= 1 }
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        return Array(lines[0..<end])
    }

    // MARK: Headings

    static func heading(_ line: String) -> (level: Int, text: String)? {
        guard let match = line.wholeMatch(of: #/^\s{0,3}(#{1,6})\s+(.+?)\s*$/#) else {
            return nil
        }
        return (match.1.count, text(match.2))
    }

    static func isHorizontalRule(_ line: String) -> Bool {
        line.wholeMatch(of: #/^\s{0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/#) != nil
    }

    /// Removes a trailing horizontal rule from a block, reporting whether it
    /// was there. It is used to keep section separators out of content while
    /// still being able to write them back.
    static func strippingTrailingRule(_ lines: [String]) -> (body: String, hadRule: Bool) {
        var end = lines.count
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        guard end > 0, isHorizontalRule(lines[end - 1]) else {
            return (trimmedBlock(lines), false)
        }
        end -= 1
        while end > 0, isBlank(lines[end - 1]) { end -= 1 }
        return (trimmedBlock(Array(lines[0..<end])), true)
    }

    // MARK: Scene heading

    static func sceneHeading(
        _ line: String
    ) -> (timestampText: String, seconds: Int, separator: String, title: String)? {
        guard let match = line.wholeMatch(
            of: #/^\s{0,3}##\s+(\d{1,2}:\d{2}(?::\d{2})?)\s*([—–-])\s*(.+?)\s*$/#
        ) else {
            return nil
        }
        let stamp = text(match.1)
        guard let seconds = seconds(fromTimestamp: stamp) else { return nil }
        return (stamp, seconds, text(match.2), text(match.3))
    }

    static func looksLikeSceneHeading(_ line: String) -> Bool {
        line.firstMatch(of: #/^\s{0,3}##\s+\d{1,2}:\d{2}/#) != nil
    }

    static func looksLikeEmptySceneTitle(_ line: String) -> Bool {
        line.wholeMatch(of: #/^\s{0,3}##\s+\d{1,2}:\d{2}(?::\d{2})?\s*[—–-]\s*$/#) != nil
    }

    static func seconds(fromTimestamp timestamp: String) -> Int? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let first = Int(parts[0]), let second = Int(parts[1]) else { return nil }
        if parts.count == 2 {
            guard second < 60 else { return nil }
            return first * 60 + second
        }
        guard let third = Int(parts[2]), second < 60, third < 60 else { return nil }
        return first * 3600 + second * 60 + third
    }

    // MARK: Chapters

    static func chapter(_ line: String) -> EscaletaChapter? {
        guard let match = line.wholeMatch(of: #/^\s*(\d{1,2}):(\d{2})(?::(\d{2}))?\s+(.+?)\s*$/#),
              let minutes = Int(match.1),
              let secondsPart = Int(match.2) else {
            return nil
        }
        let title = text(match.4)
        guard !title.isEmpty else { return nil }

        if let hoursPart = match.3 {
            guard let hours = Int(match.1), let mins = Int(match.2), let secs = Int(hoursPart),
                  mins < 60, secs < 60 else { return nil }
            return EscaletaChapter(
                seconds: hours * 3600 + mins * 60 + secs,
                timestamp: "\(text(match.1)):\(text(match.2)):\(text(hoursPart))",
                title: title
            )
        }
        guard secondsPart < 60 else { return nil }
        return EscaletaChapter(
            seconds: minutes * 60 + secondsPart,
            timestamp: "\(text(match.1)):\(text(match.2))",
            title: title
        )
    }

    // MARK: Cues

    static func cue(_ line: String) -> (label: String, payload: String?)? {
        guard let match = line.wholeMatch(of: #/^\s*\[([A-ZÁÉÍÓÚÜÑ0-9 /-]+?)(?::\s*(.*?))?\]\s*$/#) else {
            return nil
        }
        let label = text(match.1)
        let payload = match.2.map { text($0) }
        return (label, payload?.isEmpty == true ? nil : payload)
    }

    static func inlineCue(in line: String) -> String? {
        guard let match = line.firstMatch(of: #/\[([A-ZÁÉÍÓÚÜÑ][A-ZÁÉÍÓÚÜÑ0-9 /-]{1,40})(?::[^\]]*)?\]/#) else {
            return nil
        }
        return text(match.1)
    }

    // MARK: Bold labels

    static func boldLabel(_ line: String) -> (label: String, value: String, colonInsideBold: Bool)? {
        guard let match = line.wholeMatch(of: #/^\s*\*\*(.+?)\*\*\s*:?\s*(.*)$/#) else {
            return nil
        }
        var label = text(match.1)
        let colonInside = label.hasSuffix(":")
        if colonInside {
            label.removeLast()
            label = label.trimmingCharacters(in: .whitespaces)
        }
        guard !label.isEmpty else { return nil }
        return (label, text(match.2), colonInside)
    }

    // MARK: Lists

    struct ListItem {
        var text: String
        var marker: EscaletaOutlineMarker
        var indent: Int
        var line: Int
    }

    static func listItem(_ line: String, lineNumber: Int) -> ListItem? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.filter { $0 == " " }.count / 2
        let body = String(line.dropFirst(leading.count))

        if let match = body.wholeMatch(of: #/^(\d{1,2})[.)]\s+(.+?)\s*$/#), let number = Int(match.1) {
            return ListItem(text: text(match.2), marker: .numbered(number), indent: indent, line: lineNumber)
        }
        if let match = body.wholeMatch(of: #/^[-*+]\s+(.+?)\s*$/#) {
            return ListItem(text: text(match.1), marker: .bullet, indent: indent, line: lineNumber)
        }
        return nil
    }

    /// Parses a block of bullets / numbered items, folding continuation lines
    /// into the previous item.
    static func parseListItems(_ lines: [String]) -> [String] {
        var items: [String] = []
        for line in lines {
            if isBlank(line) { continue }
            if let item = listItem(line, lineNumber: 0) {
                items.append(item.text)
            } else if items.isEmpty {
                items.append(trimmed(line))
            } else {
                items[items.count - 1] += "\n" + trimmed(line)
            }
        }
        return items
    }

    static func parseOutlineItems(_ lines: [String], startingAt firstLine: Int) -> [EscaletaOutlineItem] {
        var items: [EscaletaOutlineItem] = []
        for (offset, line) in lines.enumerated() {
            if isBlank(line) { continue }
            if let item = listItem(line, lineNumber: firstLine + offset) {
                items.append(EscaletaOutlineItem(marker: item.marker, text: item.text, indent: item.indent))
            } else if items.isEmpty {
                items.append(EscaletaOutlineItem(marker: .plain, text: trimmed(line), indent: 0))
            } else {
                items[items.count - 1].text += "\n" + trimmed(line)
            }
        }
        return items
    }

    // MARK: Tables

    static func isTableRow(_ line: String) -> Bool {
        let value = trimmed(line)
        return value.count >= 2 && value.hasPrefix("|") && value.hasSuffix("|")
    }

    static func tableCells(_ line: String) -> [String] {
        var value = trimmed(line)
        guard value.hasPrefix("|"), value.hasSuffix("|"), value.count >= 2 else { return [] }
        value.removeFirst()
        value.removeLast()
        return value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { trimmed(String($0)) }
    }

    static func isSeparatorCell(_ cell: String) -> Bool {
        cell.wholeMatch(of: #/^:?-{3,}:?$/#) != nil
    }

    static func alignment(for cell: String) -> EscaletaTableAlignment {
        let hasLeading = cell.hasPrefix(":")
        let hasTrailing = cell.hasSuffix(":")
        switch (hasLeading, hasTrailing) {
        case (true, true): return .center
        case (true, false): return .leading
        case (false, true): return .trailing
        case (false, false): return .none
        }
    }

    static func parseTable(
        lines: [String],
        start: Int,
        heading: String?,
        sceneIndex: Int?
    ) -> (table: ComparisonTable, end: Int, rowWarnings: [String])? {
        guard start < lines.count, isTableRow(lines[start]) else { return nil }

        var end = start
        while end < lines.count, isTableRow(lines[end]) { end += 1 }
        guard end - start >= 2 else { return nil }

        let header = tableCells(lines[start])
        let separator = tableCells(lines[start + 1])
        guard !header.isEmpty,
              !separator.isEmpty,
              separator.count >= header.count,
              separator.allSatisfy(isSeparatorCell) else {
            return nil
        }

        var rows: [[String]] = []
        var rowWarnings: [String] = []
        for index in (start + 2)..<end {
            let cells = tableCells(lines[index])
            if cells.count != header.count {
                rowWarnings.append("La fila \(index + 1) tiene \(cells.count) columnas; la cabecera tiene \(header.count).")
            }
            rows.append(cells)
        }

        let table = ComparisonTable(
            heading: heading,
            header: header,
            alignments: separator.map(alignment(for:)),
            rows: rows,
            line: start + 1,
            sceneIndex: sceneIndex
        )
        return (table, end, rowWarnings)
    }

    // MARK: Links

    // Computed properties: `Regex` is not Sendable, so a stored static let
    // would trip Swift 6 strict concurrency.
    static var markdownLinkRegex: Regex<(Substring, Substring, Substring)> {
        #/\[([^\]]+)\]\(([^)]+)\)/#
    }

    static var bareURLRegex: Regex<Substring> {
        #/https?:\/\/[^\s<>"']+/#
    }

    static func linkMatches(in line: String) -> [EscaletaSourceLink] {
        line.matches(of: markdownLinkRegex).map { match in
            EscaletaSourceLink(title: text(match.1), url: text(match.2))
        }
    }

    static func bareURLs(in line: String) -> [String] {
        var masked = line
        let matches = Array(line.matches(of: markdownLinkRegex))
        for match in matches.reversed() {
            let length = masked.distance(from: match.range.lowerBound, to: match.range.upperBound)
            masked.replaceSubrange(match.range, with: String(repeating: " ", count: length))
        }

        return masked.matches(of: bareURLRegex).compactMap { match in
            var url = text(match.0)
            while let last = url.last, ".,;:!?)]}".contains(last) {
                url.removeLast()
            }
            return url.isEmpty ? nil : url
        }
    }

    // MARK: Thumbnail concepts

    static func thumbnailConceptHeading(_ heading: String) -> (label: String, text: String, recommended: Bool)? {
        guard let match = heading.wholeMatch(of: #/^Concepto\s+([A-Z])\s*[—–-]\s*(.+?)(?:\s*[—–-]\s*(Recomendado))?\s*$/#) else {
            return nil
        }
        return (text(match.1), text(match.2), match.3 != nil)
    }

    // MARK: Text helpers

    static func text(_ value: Substring) -> String {
        String(value).trimmingCharacters(in: .whitespaces)
    }

    static func normalizedHeading(_ heading: String) -> String {
        heading
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// A heading in the source tree. H1/H2 nodes are materialised; deeper headings
/// stay inside their parent's raw body so unknown content is never lost.
struct MarkdownNode {
    let level: Int
    let heading: String
    let lineIndex: Int
    let contentRange: Range<Int>
    let children: [MarkdownNode]

    static func buildTree(_ lines: [String]) -> [MarkdownNode] {
        buildNodes(lines, in: 0..<lines.count, parentLevel: 0)
    }

    private static func buildNodes(
        _ lines: [String],
        in range: Range<Int>,
        parentLevel: Int
    ) -> [MarkdownNode] {
        var nodes: [MarkdownNode] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard let heading = MarkdownParsingSupport.heading(lines[index]),
                  heading.level > parentLevel,
                  heading.level <= 2 else {
                index += 1
                continue
            }

            var end = index + 1
            while end < range.upperBound {
                if let next = MarkdownParsingSupport.heading(lines[end]), next.level <= heading.level {
                    break
                }
                end += 1
            }

            let contentRange = (index + 1)..<end
            let children = buildNodes(lines, in: contentRange, parentLevel: heading.level)
            nodes.append(
                MarkdownNode(
                    level: heading.level,
                    heading: heading.text,
                    lineIndex: index,
                    contentRange: contentRange,
                    children: children
                )
            )
            index = end
        }
        return nodes
    }

    /// Lines between this heading and the first child heading (or the end).
    func preambleRange() -> Range<Int> {
        let end = children.first?.lineIndex ?? contentRange.upperBound
        return (lineIndex + 1)..<max(lineIndex + 1, end)
    }
}
