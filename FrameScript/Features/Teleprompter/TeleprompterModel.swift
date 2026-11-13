import Foundation
import FrameScriptCore
import OSLog

// MARK: - Rendering input

/// A scene-sized block of teleprompter content. Runs come from
/// `FrameScriptCore.ScriptMarkup`, so the teleprompter and the editor share one
/// parser.
struct TeleprompterSection: Identifiable, Equatable, Sendable {
    let sceneID: UUID
    let title: String
    let runs: [MarkupRun]

    var id: UUID { sceneID }

    /// `false` for scenes that only contain pauses or cues. The teleprompter
    /// still renders their header (plus an empty-scene placeholder), but they
    /// contribute no reading time and must never win the reading-position race.
    var hasVisibleText: Bool {
        runs.contains { run in
            switch run {
            case .text(let value), .emphasis(let value, _):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .pause, .cue:
                return false
            }
        }
    }
}

/// Produces ordered teleprompter sections. The app feeds it a snapshot of the
/// open project; the voice follower can reuse the same contract later.
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

/// Normalizes the text that follows a cue/pause block break. The renderer and
/// the voice follower must apply exactly the same rule or their character
/// offsets drift.
enum TeleprompterBlockText {
    /// Drops one separator line break and any indentation at the start of every
    /// line, so a parser run like `" / Es la fricción"` does not render a
    /// leading space and `"\n\nAfter"` keeps its intentional blank line.
    static func normalizedAfterBlockBreak(_ text: String) -> String {
        var value = text
        if value.hasPrefix("\r\n") {
            value.removeFirst(2)
        } else if value.hasPrefix("\n") || value.hasPrefix("\r") {
            value.removeFirst()
        }
        guard !value.isEmpty else { return value }

        var lines: [Substring] = []
        lines.reserveCapacity(8)
        for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
            var trimmed = line
            while let first = trimmed.first, first == " " || first == "\t" {
                trimmed = trimmed.dropFirst()
            }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n")
    }
}

enum TeleprompterContentBuilder {
    static func sections(
        from scenes: [TeleprompterSceneText],
        pauseDefaults: PauseDefaults = .standard
    ) -> [TeleprompterSection] {
        scenes.map { scene in
            TeleprompterSection(
                sceneID: scene.id,
                title: scene.title,
                runs: ScriptMarkup.runs(scene.text, defaults: pauseDefaults)
            )
        }
    }

    /// Opening the prompter on an empty scene used to show its header under the
    /// reading line while the counter claimed the last scene. Start at the
    /// selected scene when it has text; otherwise fall forward to the first
    /// scene with something to read, and only then keep the selection.
    static func startingIndex(in sections: [TeleprompterSection], selectedIndex: Int) -> Int {
        guard !sections.isEmpty else { return 0 }
        let selected = min(max(0, selectedIndex), sections.count - 1)
        if sections[selected].hasVisibleText {
            return selected
        }
        if let firstReadable = sections.firstIndex(where: \.hasVisibleText) {
            return firstReadable
        }
        return selected
    }

    static func startingIndex(
        in scenes: [TeleprompterSceneText],
        selectedIndex: Int
    ) -> Int {
        startingIndex(in: sections(from: scenes), selectedIndex: selectedIndex)
    }
}

/// A reading position that survives relayouts and live script edits. The
/// character offset indexes the visible (spoken) characters of the scene, so
/// changing the font or column width keeps the same words under the guide.
struct TeleprompterReadingAnchor: Equatable, Sendable {
    let sceneID: UUID
    let characterOffset: Int
}

/// Geometry reported by the AppKit renderer after laying out the text.
struct TeleprompterTextMetrics: Equatable, Sendable {
    var contentHeight: Double = 0
    var sectionStarts: [Double] = []
    var sectionHeights: [Double] = []
    var visibleCharacterCounts: [Int] = []
    /// Monotonic renderer generation, used to ignore metrics from a layout
    /// that a newer render already replaced.
    var generation: Int = 0
}

/// The scroll surface the model drives. The AppKit text view conforms to this
/// so 60 Hz scrolling never rebuilds a SwiftUI text tree.
@MainActor
protocol TeleprompterTextRendering: AnyObject {
    func setScrollOffset(_ offset: Double)
}

typealias TeleprompterSceneProvider = @MainActor () -> [TeleprompterSceneText]

// MARK: - Timing

enum TeleprompterTiming {
    /// Same rule as `ScriptMarkup.spokenWordCount`: a word is a
    /// whitespace-separated run containing at least one letter or digit, so a
    /// lone dash or an emoji does not inflate the reading time. Implemented on
    /// the runs (rather than re-parsing the text) because this is called for
    /// every section on every body evaluation.
    static func wordCount(in runs: [MarkupRun]) -> Int {
        var count = 0
        for run in runs {
            switch run {
            case .text(let value), .emphasis(let value, _):
                for word in value.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                where word.contains(where: { $0.isLetter || $0.isNumber }) {
                    count += 1
                }
            case .pause, .cue:
                break
            }
        }
        return count
    }

    static func pauseSeconds(in runs: [MarkupRun]) -> TimeInterval {
        runs.reduce(0) { total, run in
            guard case .pause(let seconds) = run else { return total }
            return total + seconds
        }
    }

    static func estimatedDuration(for runs: [MarkupRun], wordsPerMinute: Double) -> TimeInterval {
        let minutes = Double(wordCount(in: runs)) / max(1, wordsPerMinute)
        return minutes * 60 + pauseSeconds(in: runs)
    }

    static func estimatedDuration(for sections: [TeleprompterSection], wordsPerMinute: Double) -> TimeInterval {
        sections.reduce(0) { $0 + estimatedDuration(for: $1.runs, wordsPerMinute: wordsPerMinute) }
    }

    static func estimatedDurations(
        for sections: [TeleprompterSection],
        wordsPerMinute: Double
    ) -> [TimeInterval] {
        sections.map { estimatedDuration(for: $0.runs, wordsPerMinute: wordsPerMinute) }
    }

    /// Elapsed time for the words already under the reading line. Using the
    /// scroll-offset/max-offset ratio made a short script report zero elapsed
    /// time and a full remaining time while the guide was already inside the
    /// hook, and it made empty scenes jump the estimate to the end.
    static func elapsedEstimate(
        offset: Double,
        readingContentY: Double,
        starts: [Double],
        heights: [Double],
        hasVisibleText: [Bool],
        durations: [TimeInterval]
    ) -> TimeInterval {
        guard !starts.isEmpty, !durations.isEmpty else { return 0 }
        let index = TeleprompterLayout.currentSectionIndex(
            offset: offset,
            readingContentY: readingContentY,
            starts: starts,
            heights: heights,
            hasVisibleText: hasVisibleText
        )
        let clampedIndex = min(max(0, index), durations.count - 1)
        let completed = durations.prefix(clampedIndex).reduce(0, +)
        let height = heights.indices.contains(clampedIndex) ? heights[clampedIndex] : 0
        let progress = TeleprompterLayout.sceneProgress(
            offset: offset,
            readingContentY: readingContentY,
            start: starts[clampedIndex],
            height: height
        )
        return completed + durations[clampedIndex] * progress
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
    ///
    /// `heights` and `hasVisibleText` are optional so the older two-argument
    /// call sites (and their tests) keep working. With heights the mapping is
    /// range-aware: a guide parked below the end of a mostly empty script
    /// resolves to the last scene that actually contains text instead of the
    /// final header, and a guide that scrolls past the end never reports the
    /// last empty scene as current.
    static func currentSectionIndex(
        offset: Double,
        readingContentY: Double,
        starts: [Double],
        heights: [Double] = [],
        hasVisibleText: [Bool] = []
    ) -> Int {
        guard !starts.isEmpty else { return 0 }
        let readingPoint = offset + readingContentY
        if readingPoint < starts[0] {
            return 0
        }

        let completeGeometry = heights.count == starts.count
        if completeGeometry, let lastStart = starts.last, let lastHeight = heights.last {
            let contentEnd = lastStart + max(0, lastHeight)
            if readingPoint >= contentEnd {
                if hasVisibleText.count == starts.count {
                    return hasVisibleText.lastIndex(where: { $0 }) ?? 0
                }
                return starts.indices.last ?? 0
            }
        }

        var result = 0
        for (index, start) in starts.enumerated() where start <= readingPoint {
            result = index
        }
        return result
    }

    /// Content coordinate of the reading line.
    ///
    /// Vertically mirrored content is flipped around the viewport centre: the
    /// visual guide at `fraction` from the top corresponds to
    /// `1 - fraction` in content coordinates.
    static func readingContentY(
        viewportHeight: Double,
        fraction: Double,
        mirrorVertical: Bool
    ) -> Double {
        let clamped = min(1, max(0, fraction))
        return viewportHeight * (mirrorVertical ? 1 - clamped : clamped)
    }

    /// Offset that puts a scene header just above the reading line. The lead is
    /// signed because a vertically mirrored guide is approached from the other
    /// direction.
    static func offsetForSection(
        _ index: Int,
        starts: [Double],
        readingContentY: Double,
        mirrorVertical: Bool,
        lead: Double = 48
    ) -> Double {
        guard starts.indices.contains(index) else { return 0 }
        let signedLead = mirrorVertical ? -lead : lead
        return max(0, starts[index] - readingContentY + signedLead)
    }

    /// Fraction of the scene under the guide, used to derive a character
    /// anchor from the current scroll offset.
    static func sceneProgress(
        offset: Double,
        readingContentY: Double,
        start: Double,
        height: Double
    ) -> Double {
        guard height > 0 else { return 0 }
        let point = offset + readingContentY
        return min(1, max(0, (point - start) / height))
    }

    /// Inverse of ``sceneProgress``: where a character anchor sits in content
    /// coordinates.
    static func contentY(
        forCharacterOffset characterOffset: Int,
        characterCount: Int,
        start: Double,
        height: Double
    ) -> Double {
        guard characterCount > 0, height > 0 else { return start }
        let clamped = min(characterCount, max(0, characterOffset))
        return start + (Double(clamped) / Double(characterCount)) * height
    }
}

// MARK: - Settings

struct TeleprompterSettings: Codable, Equatable, Sendable {
    enum Limits {
        /// One shared reading-speed range for the whole app (`DurationEstimator`
        /// uses the same bounds for learned values).
        static let wordsPerMinute = 60.0...400.0
        static let fontSize = 24.0...160.0
        static let columnWidth = 320.0...1600.0
        /// Allows ⅔ and beyond, which beam-splitter users need for a low guide.
        static let readingLineFraction = 0.15...0.70
    }

    var wordsPerMinute: Double
    var fontSize: Double
    var columnWidth: Double
    var mirrorHorizontal: Bool
    var mirrorVertical: Bool
    var readingLineFraction: Double
    var countdownEnabled: Bool
    var preferredDisplayID: UInt32?
    /// UID of the remembered microphone. `nil` means the system default input.
    var preferredAudioInputUID: String?

    init(
        wordsPerMinute: Double = 150,
        fontSize: Double = 64,
        columnWidth: Double = 900,
        mirrorHorizontal: Bool = false,
        mirrorVertical: Bool = false,
        readingLineFraction: Double = 1.0 / 3.0,
        countdownEnabled: Bool = false,
        preferredDisplayID: UInt32? = nil,
        preferredAudioInputUID: String? = nil
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.fontSize = fontSize
        self.columnWidth = columnWidth
        self.mirrorHorizontal = mirrorHorizontal
        self.mirrorVertical = mirrorVertical
        self.readingLineFraction = readingLineFraction
        self.countdownEnabled = countdownEnabled
        self.preferredDisplayID = preferredDisplayID
        self.preferredAudioInputUID = preferredAudioInputUID
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
            preferredDisplayID: try container.decodeIfPresent(UInt32.self, forKey: .preferredDisplayID),
            preferredAudioInputUID: try container.decodeIfPresent(String.self, forKey: .preferredAudioInputUID)
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
            preferredDisplayID: preferredDisplayID,
            preferredAudioInputUID: preferredAudioInputUID
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
    /// Copy of a blob that could not be decoded. Kept so a hand-edited or
    /// newer-version file is never silently destroyed by the next save.
    static let unreadableSettingsKey = "teleprompter.settings.v1.unreadable"
    static let namespace = "teleprompter."

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "Teleprompter"
    )

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = AppEnvironment.defaults) {
        self.userDefaults = userDefaults
    }

    func load() -> TeleprompterSettings {
        guard let data = userDefaults.data(forKey: Self.settingsKey) else {
            return .defaults
        }
        do {
            return try JSONDecoder().decode(TeleprompterSettings.self, from: data).clamped()
        } catch {
            // Keep the raw blob before the first save can overwrite it.
            userDefaults.set(data, forKey: Self.unreadableSettingsKey)
            Self.logger.error(
                "Teleprompter settings could not be decoded; the original blob was kept under \(Self.unreadableSettingsKey, privacy: .public). detail=\(error.localizedDescription, privacy: .public)"
            )
            return .defaults
        }
    }

    func save(_ settings: TeleprompterSettings) {
        do {
            let data = try JSONEncoder().encode(settings.clamped())
            userDefaults.set(data, forKey: Self.settingsKey)
        } catch {
            Self.logger.error(
                "Teleprompter settings could not be encoded; the previous blob is unchanged. detail=\(error.localizedDescription, privacy: .public)"
            )
        }
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
