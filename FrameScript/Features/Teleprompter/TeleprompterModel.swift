import Foundation

// MARK: - Rendering input

/// One renderable piece of teleprompter text. The set is intentionally small so
/// a future `FrameScriptCore` markup pass can produce it without knowing how the
/// teleprompter window draws.
enum TeleprompterRun: Equatable, Sendable {
    case text(String)
    case emphasis(String, strong: Bool)
    case pause(seconds: TimeInterval)
    case cue(label: String)
}

/// A scene-sized block of teleprompter content.
struct TeleprompterSection: Identifiable, Equatable, Sendable {
    let sceneID: UUID
    let title: String
    let runs: [TeleprompterRun]

    var id: UUID { sceneID }
}

/// Produces ordered teleprompter sections. The app currently feeds it a
/// snapshot of the open project; the voice follower and the Markdown importer
/// can reuse the same contract later.
protocol TeleprompterSource {
    var sections: [TeleprompterSection] { get }
}

struct StaticTeleprompterSource: TeleprompterSource {
    let sections: [TeleprompterSection]
}

/// Minimal scene snapshot needed to build teleprompter content without
/// retaining the live `Scene` model.
struct TeleprompterSceneText: Equatable, Sendable {
    let id: UUID
    let title: String
    let text: String
}

// MARK: - Temporary local converter

/// Local stand-in for the FrameScriptCore markup parser (wave 2).
///
/// Recognised syntax:
/// - `*word*` / `**word**` emphasis
/// - ` / ` short pause (0.5 s), ` // ` long pause (1 s)
/// - `[2s]`, `[pausa 2s]`, `[pause 2]`, `[pausa]` explicit pauses
/// - whole `[LABEL: value]` lines as cues
// TEMP: replaced by FrameScriptCore Markup in wave 2.
enum TeleprompterConverter {
    static let shortPauseSeconds: TimeInterval = 0.5
    static let longPauseSeconds: TimeInterval = 1.0

    static func makeSections(from scenes: [TeleprompterSceneText]) -> [TeleprompterSection] {
        scenes.map { scene in
            TeleprompterSection(sceneID: scene.id, title: scene.title, runs: runs(from: scene.text))
        }
    }

    static func runs(from text: String) -> [TeleprompterRun] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var runs: [TeleprompterRun] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let cue = cueLabel(in: trimmed) {
                append(.cue(label: cue), to: &runs)
            } else if !trimmed.isEmpty {
                for run in inlineRuns(from: trimmed) {
                    append(run, to: &runs)
                }
            }
            if index < lines.count - 1 {
                append(.text("\n"), to: &runs)
            }
        }

        while case .text(let value)? = runs.last, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runs.removeLast()
        }
        return runs
    }

    private static func append(_ run: TeleprompterRun, to runs: inout [TeleprompterRun]) {
        if case .text(let value) = run {
            guard !value.isEmpty else { return }
            if case .text(let existing)? = runs.last {
                runs[runs.count - 1] = .text(existing + value)
                return
            }
        }
        runs.append(run)
    }

    private static func inlineRuns(from line: String) -> [TeleprompterRun] {
        let characters = Array(line)
        var runs: [TeleprompterRun] = []
        var buffer = ""
        var index = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            runs.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                let isStrong = index + 1 < characters.count && characters[index + 1] == "*"
                let markerLength = isStrong ? 2 : 1
                if let close = closingAsterisk(in: characters, from: index + markerLength, markerLength: markerLength),
                   close > index + markerLength {
                    flush()
                    let content = String(characters[(index + markerLength)..<close])
                    runs.append(.emphasis(content, strong: isStrong))
                    index = close + markerLength
                    continue
                }
            }

            if character == "/" {
                let previousIsWhitespace = index > 0 && characters[index - 1].isWhitespace
                if previousIsWhitespace {
                    if index + 2 < characters.count,
                       characters[index + 1] == "/",
                       characters[index + 2].isWhitespace {
                        trimTrailingWhitespace(&buffer)
                        flush()
                        runs.append(.pause(seconds: longPauseSeconds))
                        index += 2
                        while index < characters.count, characters[index].isWhitespace {
                            index += 1
                        }
                        continue
                    }
                    if index + 1 < characters.count, characters[index + 1].isWhitespace {
                        trimTrailingWhitespace(&buffer)
                        flush()
                        runs.append(.pause(seconds: shortPauseSeconds))
                        index += 1
                        while index < characters.count, characters[index].isWhitespace {
                            index += 1
                        }
                        continue
                    }
                }
            }

            if character == "[",
               let close = characters[index...].firstIndex(of: "]") {
                let inner = String(characters[(index + 1)..<close])
                if let seconds = explicitPauseSeconds(inner) {
                    flush()
                    runs.append(.pause(seconds: seconds))
                    index = close + 1
                    continue
                }
            }

            buffer.append(character)
            index += 1
        }

        flush()
        return runs
    }

    private static func trimTrailingWhitespace(_ buffer: inout String) {
        while buffer.last?.isWhitespace == true {
            buffer.removeLast()
        }
    }

    private static func closingAsterisk(
        in characters: [Character],
        from start: Int,
        markerLength: Int
    ) -> Int? {
        guard start < characters.count else { return nil }
        var index = start
        while index + markerLength <= characters.count {
            if characters[index] == "*" {
                if markerLength == 2 {
                    if index + 1 < characters.count, characters[index + 1] == "*" {
                        return index
                    }
                } else if !(index + 1 < characters.count && characters[index + 1] == "*") {
                    return index
                } else {
                    index += 2
                    continue
                }
            }
            index += 1
        }
        return nil
    }

    /// `[2s]`, `[pausa]`, `[pausa 2s]`, `[pause 1.5]`, `[3 segundos]`…
    /// Returns `nil` for every other bracketed token (cues, labels, notes).
    static func explicitPauseSeconds(_ inner: String) -> TimeInterval? {
        var body = inner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !body.isEmpty else { return nil }

        var hadKeyword = false
        for keyword in ["pausa", "pause"] where body.hasPrefix(keyword) {
            hadKeyword = true
            body = String(body.dropFirst(keyword.count))
            break
        }
        body = body.trimmingCharacters(in: .whitespaces)

        guard hadKeyword || body.first?.isNumber == true else { return nil }

        for suffix in ["segundos", "segundo", "seconds", "second", "segs", "seg", "s"] where body.hasSuffix(suffix) {
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        if body.isEmpty {
            return hadKeyword ? longPauseSeconds : nil
        }
        guard let value = Double(body.replacingOccurrences(of: ",", with: ".")), value > 0 else {
            return nil
        }
        return min(value, 10)
    }

    /// A whole line shaped like `[LABEL: value]` becomes a dimmed cue label.
    static func cueLabel(in line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return nil }
        let inner = String(line.dropFirst().dropLast())
        guard let colon = inner.firstIndex(of: ":") else { return nil }

        let label = inner[..<colon].trimmingCharacters(in: .whitespaces)
        let value = inner[inner.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }

        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " _-"))
        guard label.unicodeScalars.allSatisfy(allowed.contains) else { return nil }

        return value.isEmpty ? label : "\(label) · \(value)"
    }
}

// MARK: - Timing

enum TeleprompterTiming {
    static func wordCount(in runs: [TeleprompterRun]) -> Int {
        var count = 0
        for run in runs {
            switch run {
            case .text(let value), .emphasis(let value, _):
                count += value.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            case .pause, .cue:
                break
            }
        }
        return count
    }

    static func pauseSeconds(in runs: [TeleprompterRun]) -> TimeInterval {
        runs.reduce(0) { total, run in
            guard case .pause(let seconds) = run else { return total }
            return total + seconds
        }
    }

    static func estimatedDuration(for runs: [TeleprompterRun], wordsPerMinute: Double) -> TimeInterval {
        let minutes = Double(wordCount(in: runs)) / max(1, wordsPerMinute)
        return minutes * 60 + pauseSeconds(in: runs)
    }

    static func estimatedDuration(for sections: [TeleprompterSection], wordsPerMinute: Double) -> TimeInterval {
        sections.reduce(0) { $0 + estimatedDuration(for: $1.runs, wordsPerMinute: wordsPerMinute) }
    }
}

// MARK: - Speed math

/// Converts a words-per-minute setting into a pixel-per-second scroll rate.
/// The rate depends on typography: a narrow column or a big font means fewer
/// words per line, so each line has to travel faster for the same WPM.
enum TeleprompterSpeed {
    static let averageCharactersPerWord: Double = 5.5
    static let glyphWidthRatio: Double = 0.52
    static let lineHeightRatio: Double = 1.32

    static func wordsPerLine(fontSize: Double, columnWidth: Double) -> Double {
        let glyphWidth = max(1, fontSize) * glyphWidthRatio
        let wordWidth = glyphWidth * averageCharactersPerWord
        return max(1, floor(max(1, columnWidth) / wordWidth))
    }

    static func pointsPerSecond(wordsPerMinute: Double, fontSize: Double, columnWidth: Double) -> Double {
        let wordsPerSecond = max(0, wordsPerMinute) / 60
        let linesPerSecond = wordsPerSecond / wordsPerLine(fontSize: fontSize, columnWidth: columnWidth)
        return linesPerSecond * max(1, fontSize) * lineHeightRatio
    }
}

// MARK: - Layout math

enum TeleprompterLayout {
    /// Vertical start of every section in content coordinates.
    static func sectionStarts(heights: [Double], topInset: Double) -> [Double] {
        var starts: [Double] = []
        var cursor = topInset
        for height in heights {
            starts.append(cursor)
            cursor += max(0, height)
        }
        return starts
    }

    /// Section whose content is under the reading line.
    static func currentSectionIndex(offset: Double, readingLineY: Double, starts: [Double]) -> Int {
        guard !starts.isEmpty else { return 0 }
        let readingPoint = offset + readingLineY
        var result = 0
        for (index, start) in starts.enumerated() where start <= readingPoint {
            result = index
        }
        return result
    }

    /// Offset that puts a scene header just above the reading line.
    static func offsetForSection(
        _ index: Int,
        starts: [Double],
        readingLineY: Double,
        lead: Double = 48
    ) -> Double {
        guard starts.indices.contains(index) else { return 0 }
        return max(0, starts[index] - readingLineY + lead)
    }
}

// MARK: - Settings

struct TeleprompterSettings: Codable, Equatable, Sendable {
    enum Limits {
        static let wordsPerMinute = 60.0...300.0
        static let fontSize = 24.0...160.0
        static let columnWidth = 320.0...1600.0
        static let readingLineFraction = 0.15...0.60
    }

    var wordsPerMinute: Double
    var fontSize: Double
    var columnWidth: Double
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool
    var readingLineFraction: Double
    var countdownEnabled: Bool
    var preferredDisplayID: UInt32?

    init(
        wordsPerMinute: Double = 150,
        fontSize: Double = 64,
        columnWidth: Double = 900,
        mirrorHorizontal: Bool = false,
        mirrorVertical: Bool = false,
        readingLineFraction: Double = 1.0 / 3.0,
        countdownEnabled: Bool = false,
        preferredDisplayID: UInt32? = nil
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.fontSize = fontSize
        self.columnWidth = columnWidth
        self.mirrorHorizontal = mirrorHorizontal
        self.mirrorVertical = mirrorVertical
        self.readingLineFraction = readingLineFraction
        self.countdownEnabled = countdownEnabled
        self.preferredDisplayID = preferredDisplayID
    }

    static let defaults = TeleprompterSettings()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            wordsPerMinute: Self.clamp(
                try container.decodeIfPresent(Double.self, forKey: .wordsPerMinute),
                to: Limits.wordsPerMinute,
                fallback: 150
            ),
            fontSize: Self.clamp(
                try container.decodeIfPresent(Double.self, forKey: .fontSize),
                to: Limits.fontSize,
                fallback: 64
            ),
            columnWidth: Self.clamp(
                try container.decodeIfPresent(Double.self, forKey: .columnWidth),
                to: Limits.columnWidth,
                fallback: 900
            ),
            mirrorHorizontal: try container.decodeIfPresent(Bool.self, forKey: .mirrorHorizontal) ?? false,
            mirrorVertical: try container.decodeIfPresent(Bool.self, forKey: .mirrorVertical) ?? false,
            readingLineFraction: Self.clamp(
                try container.decodeIfPresent(Double.self, forKey: .readingLineFraction),
                to: Limits.readingLineFraction,
                fallback: 1.0 / 3.0
            ),
            countdownEnabled: try container.decodeIfPresent(Bool.self, forKey: .countdownEnabled) ?? false,
            preferredDisplayID: try container.decodeIfPresent(UInt32.self, forKey: .preferredDisplayID)
        )
    }

    func clamped() -> TeleprompterSettings {
        TeleprompterSettings(
            wordsPerMinute: Self.clamp(wordsPerMinute, to: Limits.wordsPerMinute, fallback: 150),
            fontSize: Self.clamp(fontSize, to: Limits.fontSize, fallback: 64),
            columnWidth: Self.clamp(columnWidth, to: Limits.columnWidth, fallback: 900),
            mirrorHorizontal: mirrorHorizontal,
            mirrorVertical: mirrorVertical,
            readingLineFraction: Self.clamp(readingLineFraction, to: Limits.readingLineFraction, fallback: 1.0 / 3.0),
            countdownEnabled: countdownEnabled,
            preferredDisplayID: preferredDisplayID
        )
    }

    private static func clamp(
        _ value: Double?,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let value, value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// UserDefaults-backed persistence. Deliberately separate from `AppSettings`,
/// which is owned by another feature area.
@MainActor
final class TeleprompterSettingsStore {
    static let settingsKey = "teleprompter.settings.v1"
    static let namespace = "teleprompter."

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> TeleprompterSettings {
        guard let data = userDefaults.data(forKey: Self.settingsKey),
              let decoded = try? JSONDecoder().decode(TeleprompterSettings.self, from: data) else {
            return .defaults
        }
        return decoded.clamped()
    }

    func save(_ settings: TeleprompterSettings) {
        guard let data = try? JSONEncoder().encode(settings.clamped()) else { return }
        userDefaults.set(data, forKey: Self.settingsKey)
    }
}

// MARK: - Scroll engine

/// Frame-rate independent scroll state. The caller feeds real timestamps, so a
/// stalled timer catches up by the elapsed delta (bounded to avoid jumps after
/// sleep). When `targetOffset` is set, timed scrolling is suspended and the
/// offset eases toward the external target — the hook the speech follower will
/// drive in wave 2.
struct TeleprompterScrollEngine: Equatable, Sendable {
    static let maximumFollowSpeed: Double = 2400
    static let maximumFrameDelta: TimeInterval = 0.25

    private(set) var offset: Double = 0
    var maxOffset: Double = 0
    var isPlaying: Bool = false
    var pointsPerSecond: Double = 0
    private(set) var targetOffset: Double?
    private(set) var lastTimestamp: TimeInterval?

    mutating func advance(to timestamp: TimeInterval) {
        guard let lastTimestamp else {
            self.lastTimestamp = timestamp
            return
        }
        let delta = min(max(timestamp - lastTimestamp, 0), Self.maximumFrameDelta)
        self.lastTimestamp = timestamp
        advance(by: delta)
    }

    mutating func advance(by delta: TimeInterval) {
        guard delta > 0 else { return }

        if let targetOffset {
            let remaining = targetOffset - offset
            if abs(remaining) <= 0.5 {
                offset = self.targetOffset ?? offset
                return
            }
            let step = min(abs(remaining), Self.maximumFollowSpeed * delta)
            offset = clamp(offset + (remaining < 0 ? -step : step))
            return
        }

        guard isPlaying, pointsPerSecond > 0 else { return }
        offset = clamp(offset + pointsPerSecond * delta)
        if offset >= maxOffset {
            offset = maxOffset
            isPlaying = false
        }
    }

    mutating func seek(to value: Double) {
        offset = clamp(value)
    }

    mutating func setTargetOffset(_ value: Double?) {
        targetOffset = value.map(clamp)
    }

    mutating func resetTimestamp() {
        lastTimestamp = nil
    }

    private func clamp(_ value: Double) -> Double {
        min(max(0, maxOffset), max(0, value))
    }
}
