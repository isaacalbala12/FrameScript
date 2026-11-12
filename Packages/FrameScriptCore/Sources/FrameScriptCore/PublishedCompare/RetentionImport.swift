import Foundation

/// One point of the audience-retention curve. `retention` is a fraction:
/// `1.0` means 100 %. Values above 1.0 are valid because rewatches can make the
/// absolute audience ratio exceed 100 %.
public struct RetentionSample: Sendable, Equatable, Hashable, Codable {
    public var position: TimeInterval
    public var retention: Double

    public init(position: TimeInterval, retention: Double) {
        self.position = position
        self.retention = retention
    }
}

public enum RetentionDelimiter: String, Sendable, Equatable, Codable {
    case comma
    case semicolon
    case tab
    case whitespace

    var character: Character? {
        switch self {
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\t"
        case .whitespace: return nil
        }
    }
}

public enum RetentionPositionUnit: String, Sendable, Equatable, Codable {
    case timecode
    case seconds
    case ratio
    case percent
}

public enum RetentionValueUnit: String, Sendable, Equatable, Codable {
    case ratio
    case percent
}

public struct RetentionImport: Sendable, Equatable, Codable {
    public var samples: [RetentionSample]
    public var delimiter: RetentionDelimiter
    public var positionColumn: String?
    public var retentionColumn: String?
    public var positionUnit: RetentionPositionUnit
    public var retentionUnit: RetentionValueUnit
    public var videoDuration: TimeInterval?
    public var warnings: [String]

    public init(
        samples: [RetentionSample],
        delimiter: RetentionDelimiter,
        positionColumn: String? = nil,
        retentionColumn: String? = nil,
        positionUnit: RetentionPositionUnit,
        retentionUnit: RetentionValueUnit,
        videoDuration: TimeInterval? = nil,
        warnings: [String] = []
    ) {
        self.samples = samples
        self.delimiter = delimiter
        self.positionColumn = positionColumn
        self.retentionColumn = retentionColumn
        self.positionUnit = positionUnit
        self.retentionUnit = retentionUnit
        self.videoDuration = videoDuration
        self.warnings = warnings
    }
}

public enum RetentionImportError: Error, Equatable, Sendable, LocalizedError {
    case emptyInput
    case noColumnsDetected
    case relativeRetentionOnly
    case missingVideoDuration
    case noRetentionData

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The retention file is empty."
        case .noColumnsDetected:
            return "Could not find a video-position column and an audience-retention column."
        case .relativeRetentionOnly:
            return "This export only contains relative audience retention. Export absolute audience retention instead."
        case .missingVideoDuration:
            return "This view is normalized (ratios or percentages), so the published video's duration is required."
        case .noRetentionData:
            return "No usable audience-retention rows were found."
        }
    }
}

/// Tolerant importer for YouTube Studio retention exports and pasted curves.
///
/// It accepts comma, semicolon and tab delimiters, English and Spanish headers,
/// decimal commas, positions as timecode / seconds / percent / ratio, and
/// retention as percent or ratio. Rows may be preceded by report metadata.
public enum RetentionCSVParser {
    public static func parse(
        _ text: String,
        videoDuration: TimeInterval? = nil
    ) throws -> RetentionImport {
        try parseInternal(text, videoDuration: videoDuration, isPaste: false)
    }

    /// Imports two columns copied straight from a table, with or without a
    /// header. Columns may be separated by tabs, semicolons, commas or runs of
    /// spaces.
    public static func parsePastedColumns(
        _ text: String,
        videoDuration: TimeInterval? = nil
    ) throws -> RetentionImport {
        try parseInternal(text, videoDuration: videoDuration, isPaste: true)
    }
}

// MARK: - Implementation

private extension RetentionCSVParser {
    struct HeaderMatch {
        var rowIndex: Int
        var positionIndex: Int
        var retentionIndex: Int
        var positionScore: Int
        var retentionScore: Int
        var positionCell: String
        var retentionCell: String
    }

    struct ColumnChoice {
        var delimiter: RetentionDelimiter
        var rows: [[String]]
        var header: HeaderMatch?
        var positionIndex: Int
        var retentionIndex: Int
        var score: Int
    }

    enum RawPosition {
        case timecode(Double)
        case percent(Double)
        case number(Double)

        var value: Double {
            switch self {
            case .timecode(let value), .percent(let value), .number(let value): return value
            }
        }
    }

    enum RawRetention {
        case percent(Double)
        case number(Double)

        var value: Double {
            switch self {
            case .percent(let value), .number(let value): return value
            }
        }
    }

    static func parseInternal(
        _ text: String,
        videoDuration: TimeInterval?,
        isPaste: Bool
    ) throws -> RetentionImport {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { throw RetentionImportError.emptyInput }

        let duration = videoDuration.flatMap { $0 > 0 ? $0 : nil }
        let choice = try chooseColumns(lines: lines, isPaste: isPaste)
        var warnings: [String] = []

        if let header = choice.header, header.retentionScore <= 5 {
            let canonical = canonicalHeader(header.retentionCell)
            if canonical.contains("relative") || canonical.contains("relativa") {
                throw RetentionImportError.relativeRetentionOnly
            }
        }

        let dataRows: ArraySlice<[String]>
        if let header = choice.header {
            dataRows = choice.rows[(header.rowIndex + 1)...]
        } else {
            dataRows = choice.rows[...]
        }

        var rawPositions: [RawPosition] = []
        var rawRetentions: [RawRetention] = []
        var skipped = 0

        for row in dataRows {
            guard row.count > max(choice.positionIndex, choice.retentionIndex) else {
                if !row.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { skipped += 1 }
                continue
            }
            let positionCell = row[choice.positionIndex]
            let retentionCell = row[choice.retentionIndex]
            guard let position = parseRawPosition(positionCell, delimiter: choice.delimiter),
                  let retention = parseRawRetention(retentionCell, delimiter: choice.delimiter) else {
                if !positionCell.isEmpty || !retentionCell.isEmpty { skipped += 1 }
                continue
            }
            rawPositions.append(position)
            rawRetentions.append(retention)
        }

        guard !rawPositions.isEmpty else { throw RetentionImportError.noRetentionData }
        if skipped > 0 {
            warnings.append("Skipped \(skipped) row\(skipped == 1 ? "" : "s") that did not contain a position and a retention value.")
        }

        let positionUnit = inferPositionUnit(
            rawPositions,
            headerCell: choice.header?.positionCell,
            videoDuration: duration
        )
        let retentionUnit = inferRetentionUnit(
            rawRetentions,
            headerCell: choice.header?.retentionCell
        )

        if (positionUnit == .ratio || positionUnit == .percent) && duration == nil {
            throw RetentionImportError.missingVideoDuration
        }

        var samples: [RetentionSample] = []
        var outsideRange = 0
        var aboveFull = 0

        for (position, retention) in zip(rawPositions, rawRetentions) {
            let seconds: Double
            switch positionUnit {
            case .timecode, .seconds:
                seconds = position.value
            case .ratio:
                seconds = position.value * (duration ?? 0)
            case .percent:
                seconds = position.value / 100 * (duration ?? 0)
            }

            let fraction: Double
            switch retentionUnit {
            case .ratio:
                fraction = retention.value
            case .percent:
                fraction = retention.value / 100
            }

            guard seconds.isFinite, fraction.isFinite, seconds >= 0, fraction >= 0 else {
                skipped += 1
                continue
            }
            if let duration {
                let tolerance = max(1.0, duration * 0.01)
                if seconds > duration + tolerance {
                    outsideRange += 1
                    continue
                }
            }
            if fraction > 1.5 { aboveFull += 1 }
            samples.append(RetentionSample(position: seconds, retention: fraction))
        }

        guard !samples.isEmpty else { throw RetentionImportError.noRetentionData }
        if outsideRange > 0 {
            warnings.append("Dropped \(outsideRange) point\(outsideRange == 1 ? "" : "s") beyond the video duration.")
        }
        if aboveFull > 0 {
            warnings.append("\(aboveFull) point\(aboveFull == 1 ? "" : "s") exceed 150 % retention; this usually means rewatches, not an import error.")
        }

        samples.sort { $0.position < $1.position }
        let deduplicated = mergeDuplicatePositions(samples)
        if deduplicated.count < samples.count {
            warnings.append("Merged \(samples.count - deduplicated.count) duplicate position\(samples.count - deduplicated.count == 1 ? "" : "s").")
        }
        guard !deduplicated.isEmpty else { throw RetentionImportError.noRetentionData }

        return RetentionImport(
            samples: deduplicated,
            delimiter: choice.delimiter,
            positionColumn: choice.header?.positionCell,
            retentionColumn: choice.header?.retentionCell,
            positionUnit: positionUnit,
            retentionUnit: retentionUnit,
            videoDuration: duration,
            warnings: warnings
        )
    }

    // MARK: Column detection

    static func chooseColumns(lines: [String], isPaste: Bool) throws -> ColumnChoice {
        var candidates: [ColumnChoice] = []
        var delimiters: [RetentionDelimiter] = [.tab, .semicolon, .comma]
        if isPaste { delimiters.append(.whitespace) }

        for delimiter in delimiters {
            let rows = lines.map { splitLine($0, delimiter: delimiter) }
            if let header = findHeader(in: rows, delimiter: delimiter) {
                let validDataRows = countValidDataRows(rows: rows, header: header, delimiter: delimiter)
                guard validDataRows >= 2 else { continue }
                let score = 10_000 + header.positionScore + header.retentionScore + min(validDataRows, 500) * 20
                candidates.append(
                    ColumnChoice(
                        delimiter: delimiter,
                        rows: rows,
                        header: header,
                        positionIndex: header.positionIndex,
                        retentionIndex: header.retentionIndex,
                        score: score
                    )
                )
                continue
            }

            if let pair = bestHeaderlessColumns(rows: rows, delimiter: delimiter) {
                candidates.append(
                    ColumnChoice(
                        delimiter: delimiter,
                        rows: rows,
                        header: nil,
                        positionIndex: pair.position,
                        retentionIndex: pair.retention,
                        score: pair.score
                    )
                )
            }
        }

        if candidates.isEmpty && !isPaste {
            // Last resort: a pasted list without a header.
            let rows = lines.map { splitLine($0, delimiter: .whitespace) }
            if let pair = bestHeaderlessColumns(rows: rows, delimiter: .whitespace) {
                candidates.append(
                    ColumnChoice(
                        delimiter: .whitespace,
                        rows: rows,
                        header: nil,
                        positionIndex: pair.position,
                        retentionIndex: pair.retention,
                        score: pair.score
                    )
                )
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            throw RetentionImportError.noColumnsDetected
        }
        if let header = best.header, header.retentionScore <= 5 {
            let canonical = canonicalHeader(header.retentionCell)
            if canonical.contains("relative") || canonical.contains("relativa") {
                throw RetentionImportError.relativeRetentionOnly
            }
        }
        return best
    }

    static func findHeader(in rows: [[String]], delimiter: RetentionDelimiter) -> HeaderMatch? {
        var best: HeaderMatch?
        for (rowIndex, row) in rows.enumerated() {
            guard row.count >= 2 else { continue }
            var positionIndex = -1
            var positionScore = 0
            var retentionIndex = -1
            var retentionScore = 0

            for (cellIndex, cell) in row.enumerated() {
                let canonical = canonicalHeader(cell)
                let pScore = positionAliasScore(canonical)
                let rScore = retentionAliasScore(canonical)
                if pScore > positionScore {
                    positionScore = pScore
                    positionIndex = cellIndex
                }
                if rScore > retentionScore {
                    retentionScore = rScore
                    retentionIndex = cellIndex
                }
            }

            guard positionScore >= 50, retentionScore > 0, positionIndex != retentionIndex else { continue }
            // A data row must never be mistaken for a header.
            if parseRawPosition(row[positionIndex], delimiter: delimiter) != nil,
               parseRawRetention(row[retentionIndex], delimiter: delimiter) != nil {
                continue
            }
            let match = HeaderMatch(
                rowIndex: rowIndex,
                positionIndex: positionIndex,
                retentionIndex: retentionIndex,
                positionScore: positionScore,
                retentionScore: retentionScore,
                positionCell: row[positionIndex],
                retentionCell: row[retentionIndex]
            )
            if let current = best {
                if (match.positionScore + match.retentionScore) > (current.positionScore + current.retentionScore) {
                    best = match
                }
            } else {
                best = match
            }
        }
        return best
    }

    static func countValidDataRows(
        rows: [[String]],
        header: HeaderMatch,
        delimiter: RetentionDelimiter
    ) -> Int {
        let requiredIndex = max(header.positionIndex, header.retentionIndex)
        var valid = 0
        for row in rows.dropFirst(header.rowIndex + 1) {
            guard row.count > requiredIndex else { continue }
            guard parseRawPosition(row[header.positionIndex], delimiter: delimiter) != nil,
                  parseRawRetention(row[header.retentionIndex], delimiter: delimiter) != nil else { continue }
            valid += 1
        }
        return valid
    }

    static func bestHeaderlessColumns(
        rows: [[String]],
        delimiter: RetentionDelimiter
    ) -> (position: Int, retention: Int, score: Int)? {
        guard let columnCount = rows.map(\.count).max(), columnCount >= 2 else { return nil }
        var best: (position: Int, retention: Int, score: Int)?

        for positionIndex in 0..<(min(columnCount, 4) - 1) {
            for retentionIndex in (positionIndex + 1)..<min(columnCount, 5) {
                var valid = 0
                var inversions = 0
                var lastPosition: Double?
                var plausibleRetention = 0

                for row in rows where row.count > retentionIndex {
                    guard let position = parseRawPosition(row[positionIndex], delimiter: delimiter),
                          let retention = parseRawRetention(row[retentionIndex], delimiter: delimiter) else { continue }
                    valid += 1
                    let value = position.value
                    if let lastPosition, value + 0.0001 < lastPosition { inversions += 1 }
                    lastPosition = value
                    if retention.value >= 0 { plausibleRetention += 1 }
                }

                guard valid >= 2, valid >= (rows.count / 2) else { continue }
                let score = valid * 10 + plausibleRetention + (inversions == 0 ? 40 : 0) - inversions * 15
                guard score > 0 else { continue }
                if best == nil || score > (best?.score ?? Int.min) {
                    best = (positionIndex, retentionIndex, score)
                }
            }
        }
        return best
    }

    static func canonicalHeader(_ cell: String) -> String {
        ScriptNormalizer.fold(cell)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func positionAliasScore(_ canonical: String) -> Int {
        if canonical == "elapsedvideotimeratio" || canonical == "elapsed video time ratio" { return 100 }
        if canonical.contains("video position") || canonical.contains("posicion del video") { return 95 }
        if canonical == "position" || canonical == "posicion" { return 85 }
        if canonical.contains("position") || canonical.contains("posicion") { return 80 }
        if canonical.contains("timestamp") || canonical.contains("marca de tiempo") { return 70 }
        if canonical == "time" || canonical == "tiempo"
            || canonical.hasPrefix("time ") || canonical.hasPrefix("tiempo ") { return 70 }
        if canonical.contains("seconds") || canonical.contains("segundos") { return 65 }
        if canonical.contains("elapsed") { return 60 }
        return 0
    }

    static func retentionAliasScore(_ canonical: String) -> Int {
        if canonical.contains("relative") || canonical.contains("relativa") { return 5 }
        if canonical.contains("absolute audience retention") || canonical.contains("retencion de audiencia absoluta") { return 100 }
        if canonical == "audiencewatchratio" || canonical.contains("audience watch ratio") { return 100 }
        if canonical.contains("audience retention") || canonical.contains("retencion de audiencia") { return 90 }
        if canonical == "retention" || canonical == "retencion" { return 85 }
        if canonical.contains("watch ratio") || canonical.contains("ratio de audiencia") { return 80 }
        if canonical.contains("retention") || canonical.contains("retencion") { return 70 }
        if canonical.contains("percentage viewed") || canonical.contains("porcentaje visto") { return 60 }
        return 0
    }

    // MARK: Cell splitting

    static func splitLine(_ line: String, delimiter: RetentionDelimiter) -> [String] {
        guard let character = delimiter.character else {
            return line.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        var cells: [String] = []
        var current = ""
        var quoted = false
        var index = line.startIndex

        while index < line.endIndex {
            let characterAtIndex = line[index]
            if characterAtIndex == "\"" {
                let next = line.index(after: index)
                if quoted, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
                index = next
                continue
            }
            if characterAtIndex == character, !quoted {
                cells.append(current)
                current = ""
            } else {
                current.append(characterAtIndex)
            }
            index = line.index(after: index)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Value parsing

    static func parseRawPosition(_ raw: String, delimiter: RetentionDelimiter) -> RawPosition? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\"", with: "")
        if value.contains(":") {
            guard let seconds = parseTimecode(value) else { return nil }
            return .timecode(seconds)
        }
        let explicitPercent = value.contains("%")
        guard let number = parseNumber(value, delimiter: delimiter, isPosition: true) else { return nil }
        return explicitPercent ? .percent(number) : .number(number)
    }

    static func parseRawRetention(_ raw: String, delimiter: RetentionDelimiter) -> RawRetention? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "\"", with: "")
        let explicitPercent = value.contains("%")
        guard let number = parseNumber(value, delimiter: delimiter, isPosition: false) else { return nil }
        return explicitPercent ? .percent(number) : .number(number)
    }

    static func parseNumber(
        _ raw: String,
        delimiter: RetentionDelimiter,
        isPosition: Bool
    ) -> Double? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: "\u{2009}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\"", with: "")
        guard !value.isEmpty else { return nil }

        let commaCount = value.filter { $0 == "," }.count
        let dotCount = value.filter { $0 == "." }.count

        if commaCount > 0 && dotCount > 0 {
            if let lastComma = value.lastIndex(of: ","), let lastDot = value.lastIndex(of: ".") {
                if lastComma > lastDot {
                    value = value.replacingOccurrences(of: ".", with: "")
                    value = value.replacingOccurrences(of: ",", with: ".")
                } else {
                    value = value.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if commaCount > 0 {
            value = normalizeSeparator(
                value,
                separator: ",",
                isPosition: isPosition,
                delimiter: delimiter
            )
        } else if dotCount > 0 {
            value = normalizeSeparator(
                value,
                separator: ".",
                isPosition: isPosition,
                delimiter: delimiter
            )
        }

        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }

    static func normalizeSeparator(
        _ value: String,
        separator: Character,
        isPosition: Bool,
        delimiter: RetentionDelimiter
    ) -> String {
        let parts = value.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return value }

        if parts.count > 2 {
            // Multiple identical separators are grouping separators in every
            // real retention export ("1.234.567").
            return parts.joined()
        }

        let integerPartCount = parts.first?.count ?? 0
        let digitsAfter = parts.last?.count ?? 0
        let looksGrouped = isPosition
            && digitsAfter == 3
            && integerPartCount <= 3
            && ((separator == "." && delimiter == .semicolon)
                || (separator == "," && delimiter == .comma))
        if looksGrouped {
            return parts.joined()
        }
        return parts.joined(separator: ".")
    }

    static func parseTimecode(_ raw: String) -> TimeInterval? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: ",", with: ".")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let seconds = Double(parts.last ?? ""), seconds >= 0, seconds < 60 else { return nil }
        guard let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        if parts.count == 2 {
            return minutes * 60 + seconds
        }
        guard let hours = Double(parts[0]), hours >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: Unit inference

    static func inferPositionUnit(
        _ positions: [RawPosition],
        headerCell: String?,
        videoDuration: TimeInterval?
    ) -> RetentionPositionUnit {
        if positions.contains(where: { if case .timecode = $0 { return true } else { return false } }) {
            return .timecode
        }
        if let headerCell {
            let canonical = canonicalHeader(headerCell)
            let raw = headerCell.lowercased()
            if canonical.contains("ratio") || raw.contains("ratio") {
                return .ratio
            }
            if raw.contains("%") || canonical.contains("percent") || canonical.contains("porcentaje") {
                return .percent
            }
            if canonical.contains("seconds") || canonical.contains("segundos") || raw.contains("(s)") {
                return .seconds
            }
        }
        if positions.contains(where: { if case .percent = $0 { return true } else { return false } }) {
            return .percent
        }

        let values = positions.map(\.value)
        let maximum = values.max() ?? 0
        if maximum <= 1.001 {
            // A one-second video is not a realistic published comparison.
            return .ratio
        }
        if let videoDuration, videoDuration > 1, maximum <= 100.5 {
            // A 90-second export whose last position is 90 is seconds, not
            // 90 %. Percent exports finish at (or near) 100.
            if maximum <= videoDuration * 1.02, abs(maximum - 100) > 2 {
                return .seconds
            }
            return .percent
        }
        if maximum <= 100.5 {
            return .percent
        }
        return .seconds
    }

    static func inferRetentionUnit(
        _ retentions: [RawRetention],
        headerCell: String?
    ) -> RetentionValueUnit {
        if retentions.contains(where: { if case .percent = $0 { return true } else { return false } }) {
            return .percent
        }
        if let headerCell {
            let canonical = canonicalHeader(headerCell)
            let raw = headerCell.lowercased()
            if raw.contains("%") || canonical.contains("percent") || canonical.contains("porcentaje") {
                return .percent
            }
            if canonical.contains("ratio") || canonical.contains("watch ratio") {
                return .ratio
            }
        }
        let values = retentions.map(\.value)
        let maximum = values.max() ?? 0
        if maximum <= 1.5 {
            return .ratio
        }
        return .percent
    }

    static func mergeDuplicatePositions(_ samples: [RetentionSample]) -> [RetentionSample] {
        var merged: [Int: (sum: Double, count: Int)] = [:]
        for sample in samples {
            let key = Int((sample.position * 1000).rounded())
            if var existing = merged[key] {
                existing.sum += sample.retention
                existing.count += 1
                merged[key] = existing
            } else {
                merged[key] = (sample.retention, 1)
            }
        }
        return merged.keys.sorted().compactMap { key in
            guard let value = merged[key] else { return nil }
            return RetentionSample(position: Double(key) / 1000, retention: value.sum / Double(value.count))
        }
    }
}
