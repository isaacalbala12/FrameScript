import Foundation

/// A problem found while editing or pasting a comparison table. Indices are
/// zero-based; the UI adds one before showing them to a person.
public enum ComparisonTableIssue: Sendable, Equatable, Hashable {
    case noColumns
    case noRows
    case emptyHeader(column: Int)
    case duplicateHeader(column: Int)
    case emptyCell(row: Int, column: Int)
    case raggedRow(row: Int, expected: Int, actual: Int)
    case raggedHeader(expected: Int, actual: Int)

    public var isBlocking: Bool {
        switch self {
        case .noColumns: true
        case .noRows, .emptyHeader, .duplicateHeader, .emptyCell, .raggedRow, .raggedHeader: false
        }
    }
}

public enum ComparisonTablePasteFormat: String, Sendable, Equatable {
    case markdown
    case tsv
    case csv
}

public struct ComparisonTablePasteResult: Sendable, Equatable {
    public var header: [String]
    public var rows: [[String]]
    public var format: ComparisonTablePasteFormat
    public var issues: [ComparisonTableIssue]

    public init(
        header: [String],
        rows: [[String]],
        format: ComparisonTablePasteFormat,
        issues: [ComparisonTableIssue] = []
    ) {
        self.header = header
        self.rows = rows
        self.format = format
        self.issues = issues
    }

    public var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    public func table(title: String) -> FrameScriptDocument.ComparisonTable {
        FrameScriptDocument.ComparisonTable(title: title, header: header, rows: rows)
    }
}

public enum ComparisonTablePasteError: Error, Sendable, Equatable {
    case empty
    case unsupported
    case noColumns
}

/// Pure grid operations. Every function tolerates fewer cells than the header
/// and never traps on an out-of-range index.
public enum ComparisonTableEditing {
    public static func columnCount(_ table: FrameScriptDocument.ComparisonTable) -> Int {
        max(table.header.count, table.rows.map(\.count).max() ?? 0)
    }

    /// Pads the header and every row to one common width. Intentional blanks
    /// stay blank; the caller can still surface empty-cell warnings.
    public static func normalized(
        _ table: FrameScriptDocument.ComparisonTable
    ) -> FrameScriptDocument.ComparisonTable {
        let width = columnCount(table)
        var result = table
        if result.header.count != width {
            result.header = padded(result.header, to: width)
        }
        result.rows = result.rows.map { padded($0, to: width) }
        return result
    }

    public static func addRow(
        _ table: FrameScriptDocument.ComparisonTable
    ) -> FrameScriptDocument.ComparisonTable {
        var result = normalized(table)
        let width = columnCount(result)
        result.rows.append(Array(repeating: "", count: width))
        return result
    }

    public static func removeRow(
        _ table: FrameScriptDocument.ComparisonTable,
        at index: Int
    ) -> FrameScriptDocument.ComparisonTable {
        guard table.rows.indices.contains(index) else { return table }
        var result = table
        result.rows.remove(at: index)
        return result
    }

    public static func addColumn(
        _ table: FrameScriptDocument.ComparisonTable,
        title: String = ""
    ) -> FrameScriptDocument.ComparisonTable {
        var result = normalized(table)
        result.header.append(title)
        result.rows = result.rows.map { $0 + [""] }
        return result
    }

    public static func removeColumn(
        _ table: FrameScriptDocument.ComparisonTable,
        at index: Int
    ) -> FrameScriptDocument.ComparisonTable {
        var result = normalized(table)
        guard result.header.indices.contains(index) else { return table }
        result.header.remove(at: index)
        result.rows = result.rows.map { row in
            guard row.indices.contains(index) else { return row }
            var copy = row
            copy.remove(at: index)
            return copy
        }
        return result
    }

    public static func setCell(
        _ table: FrameScriptDocument.ComparisonTable,
        row: Int,
        column: Int,
        value: String
    ) -> FrameScriptDocument.ComparisonTable {
        guard table.rows.indices.contains(row) else { return table }
        var result = normalized(table)
        guard result.rows[row].indices.contains(column) else { return table }
        result.rows[row][column] = value
        return result
    }

    public static func setHeader(
        _ table: FrameScriptDocument.ComparisonTable,
        column: Int,
        value: String
    ) -> FrameScriptDocument.ComparisonTable {
        var result = normalized(table)
        guard result.header.indices.contains(column) else { return table }
        result.header[column] = value
        return result
    }

    /// Replaces the table body from a paste, keeping the current title, scene
    /// link and identity. An empty paste leaves the table untouched.
    public static func applyingPaste(
        _ result: ComparisonTablePasteResult,
        to table: FrameScriptDocument.ComparisonTable
    ) -> FrameScriptDocument.ComparisonTable {
        var updated = table
        updated.header = result.header
        updated.rows = result.rows
        return normalized(updated)
    }

    private static func padded(_ values: [String], to count: Int) -> [String] {
        guard values.count < count else { return values }
        return values + Array(repeating: "", count: count - values.count)
    }
}

public enum ComparisonTableValidation {
    public static func issues(
        in table: FrameScriptDocument.ComparisonTable
    ) -> [ComparisonTableIssue] {
        let width = ComparisonTableEditing.columnCount(table)
        guard width > 0 else { return [.noColumns] }

        var issues: [ComparisonTableIssue] = []
        if table.rows.isEmpty { issues.append(.noRows) }
        if table.header.count != width {
            issues.append(.raggedHeader(expected: width, actual: table.header.count))
        }

        var seenHeaders: Set<String> = []
        for column in 0..<width {
            let title = column < table.header.count ? table.header[column] : ""
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyHeader(column: column))
            } else if !seenHeaders.insert(title.lowercased()).inserted {
                issues.append(.duplicateHeader(column: column))
            }
        }

        for (rowIndex, row) in table.rows.enumerated() {
            if row.count != width {
                issues.append(.raggedRow(row: rowIndex, expected: width, actual: row.count))
            }
            for column in 0..<width {
                let value = column < row.count ? row[column] : ""
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.emptyCell(row: rowIndex, column: column))
                }
            }
        }
        return issues
    }
}

public enum ComparisonTablePaste {
    /// Accepts a GitHub-flavoured Markdown table, tab-separated cells or CSV.
    /// Rows are padded to the widest row and every ragged row is reported.
    public static func parse(_ input: String) throws -> ComparisonTablePasteResult {
        let normalizedInput = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = normalizedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ComparisonTablePasteError.empty }

        let lines = normalizedInput
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let parsed: (header: [String], rows: [[String]], format: ComparisonTablePasteFormat)
        if isMarkdown(lines) {
            parsed = try parseMarkdown(lines)
        } else if lines.contains(where: { $0.contains("\t") }) {
            parsed = (header: splitTSV(lines.first ?? ""), rows: lines.dropFirst().map(splitTSV), format: .tsv)
        } else if lines.contains(where: { $0.contains(",") || $0.contains("\"") }) {
            let rows = parseCSV(normalizedInput)
            guard let first = rows.first else { throw ComparisonTablePasteError.empty }
            parsed = (header: first, rows: Array(rows.dropFirst()), format: .csv)
        } else {
            throw ComparisonTablePasteError.unsupported
        }

        let width = max(parsed.header.count, parsed.rows.map(\.count).max() ?? 0)
        guard width > 0 else { throw ComparisonTablePasteError.noColumns }

        var issues: [ComparisonTableIssue] = []
        if parsed.header.count != width {
            issues.append(.raggedHeader(expected: width, actual: parsed.header.count))
        }
        let header = pad(parsed.header, to: width)
        let rows = parsed.rows.enumerated().map { index, row -> [String] in
            if row.count != width {
                issues.append(.raggedRow(row: index, expected: width, actual: row.count))
            }
            return pad(row, to: width)
        }

        for column in 0..<width where header[column].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyHeader(column: column))
        }
        for (rowIndex, row) in rows.enumerated() {
            for column in 0..<width where row[column].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyCell(row: rowIndex, column: column))
            }
        }

        return ComparisonTablePasteResult(
            header: header,
            rows: rows,
            format: parsed.format,
            issues: issues
        )
    }

    // MARK: Markdown

    private static func isMarkdown(_ lines: [String]) -> Bool {
        guard let first = lines.first else { return false }
        return first.contains("|") && splitMarkdownRow(first).count >= 2
    }

    private static func parseMarkdown(
        _ lines: [String]
    ) throws -> (header: [String], rows: [[String]], format: ComparisonTablePasteFormat) {
        let rows = lines.map(splitMarkdownRow)
        guard !rows.isEmpty else { throw ComparisonTablePasteError.empty }

        var header = rows[0]
        var body: [[String]] = []
        var skippedSeparator = false
        for (index, row) in rows.enumerated() {
            if index == 0 { continue }
            if !skippedSeparator, isSeparator(row) {
                skippedSeparator = true
                continue
            }
            body.append(row)
        }
        if isSeparator(header), body.isEmpty {
            header = []
        }
        if !skippedSeparator, !body.isEmpty {
            // A pasted pipe table without a separator still reads as a table:
            // the first row is the header.
            return (header: header, rows: body, format: .markdown)
        }
        return (header: header, rows: body, format: .markdown)
    }

    private static func isSeparator(_ row: [String]) -> Bool {
        guard !row.isEmpty else { return false }
        return row.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return false }
            let dashes = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return dashes.count >= 1 && dashes.allSatisfy { $0 == "-" }
        }
    }

    private static func splitMarkdownRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in line {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            cells.removeFirst()
        }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") {
            cells.removeLast()
        }
        return cells
    }

    // MARK: TSV / CSV

    private static func splitTSV(_ line: String) -> [String] {
        line.components(separatedBy: "\t").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// RFC-4180-style parser: quoted fields may contain commas, doubled quotes
    /// and line breaks. Unquoted newlines separate rows.
    private static func parseCSV(_ input: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if inQuotes {
                if character == "\"" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\"" {
                        field.append("\"")
                        index = input.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                case "\n":
                    row.append(field.trimmingCharacters(in: .whitespaces))
                    field = ""
                    rows.append(row)
                    row = []
                default:
                    field.append(character)
                }
            }
            index = input.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: .whitespaces))
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy { $0.isEmpty } }
    }

    private static func pad(_ values: [String], to count: Int) -> [String] {
        guard values.count < count else { return values }
        return values + Array(repeating: "", count: count - values.count)
    }
}

public enum ComparisonTableRender {
    public static func markdown(
        _ table: FrameScriptDocument.ComparisonTable
    ) -> String {
        let normalized = ComparisonTableEditing.normalized(table)
        let width = normalized.header.count
        guard width > 0 else { return "" }

        let header = "| " + normalized.header.map(escapeMarkdownCell).joined(separator: " | ") + " |"
        let separator = "| " + Array(repeating: "---", count: width).joined(separator: " | ") + " |"
        let body = normalized.rows.map { row in
            "| " + row.prefix(width).map(escapeMarkdownCell).joined(separator: " | ") + " |"
        }
        return ([header, separator] + body).joined(separator: "\n")
    }

    public static func markdownDocument(
        title: String,
        table: FrameScriptDocument.ComparisonTable
    ) -> String {
        let body = markdown(table)
        guard !body.isEmpty else { return "" }
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? body + "\n" : "## \(heading)\n\n\(body)\n"
    }

    public static func csv(
        _ table: FrameScriptDocument.ComparisonTable
    ) -> String {
        let normalized = ComparisonTableEditing.normalized(table)
        guard !normalized.header.isEmpty else { return "" }
        var rows = [normalized.header] + normalized.rows
        rows = rows.map { $0.map(escapeCSVCell) }
        return rows.map { $0.joined(separator: ",") }.joined(separator: "\n")
    }

    private static func escapeMarkdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escapeCSVCell(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
