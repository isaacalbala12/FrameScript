import Foundation

/// The horizontal tracks drawn by the script timeline (F18).
public enum TimelineTrack: String, Sendable, CaseIterable, Hashable {
    /// One block per scene.
    case scenes
    /// One block per paragraph.
    case narration
    /// Inline pause markers (`[pausa Ns]`, `/`, `//`).
    case pauses
    /// Anchored B-roll items.
    case bRoll
    /// Anchored editing notes.
    case editing
    /// Recorded takes, one lane per take index.
    case takes
    /// Rhythm-review warnings, drawn as stripes.
    case warnings
}

/// Rating of a take, mirrored so the core package does not depend on the app
/// model. The app maps its `TakeRating` at the boundary.
public enum TimelineTakeRating: String, Sendable, CaseIterable, Hashable {
    case good
    case bad
    case safe
    case unrated
}

/// A recorded take as the timeline needs it.
public struct TimelineTakeInput: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var number: Int
    public var duration: TimeInterval
    /// True for the take the duration UI selected as the scene's real take.
    public var isSelected: Bool
    public var rating: TimelineTakeRating

    public init(
        id: UUID,
        number: Int,
        duration: TimeInterval,
        isSelected: Bool = false,
        rating: TimelineTakeRating = .unrated
    ) {
        self.id = id
        self.number = number
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.isSelected = isSelected
        self.rating = rating
    }
}

/// A B-roll item or editing note anchored to a UTF-16 offset in its scene.
public struct TimelineMarkerInput: Sendable, Equatable, Identifiable {
    public var id: UUID
    /// `nil` for an item that lost its anchor. It is drawn at the scene start.
    public var anchorUTF16: Int?
    /// Planned length in seconds. Editing notes use `0` and draw as markers.
    public var duration: TimeInterval
    public var label: String

    public init(
        id: UUID,
        anchorUTF16: Int?,
        duration: TimeInterval = 0,
        label: String = ""
    ) {
        self.id = id
        self.anchorUTF16 = anchorUTF16
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.label = label
    }
}

/// A rhythm warning reduced to the range the timeline needs.
public struct TimelineWarningInput: Sendable, Equatable {
    public var kind: RhythmWarning.Kind
    /// UTF-16 location into the scene text.
    public var location: Int
    /// UTF-16 length. Zero-length ranges become thin marker stripes.
    public var length: Int

    public init(kind: RhythmWarning.Kind, location: Int, length: Int) {
        self.kind = kind
        self.location = max(0, location)
        self.length = max(0, length)
    }
}

/// Everything the layout needs from one scene.
public struct TimelineSceneInput: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var text: String
    public var takes: [TimelineTakeInput]
    public var bRoll: [TimelineMarkerInput]
    public var editing: [TimelineMarkerInput]
    public var warnings: [TimelineWarningInput]

    public init(
        id: UUID,
        title: String,
        text: String,
        takes: [TimelineTakeInput] = [],
        bRoll: [TimelineMarkerInput] = [],
        editing: [TimelineMarkerInput] = [],
        warnings: [TimelineWarningInput] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.takes = takes
        self.bRoll = bRoll
        self.editing = editing
        self.warnings = warnings
    }
}

/// Duration inputs shared by every scene: the learned speaking rate and the
/// configured pause lengths. These are the same values `ScriptMarkup` uses, so
/// the timeline never invents a second estimator.
public struct TimelineConfiguration: Sendable, Equatable {
    public var wordsPerMinute: Double
    public var pauseDefaults: PauseDefaults

    public init(wordsPerMinute: Double, pauseDefaults: PauseDefaults = .standard) {
        self.wordsPerMinute = wordsPerMinute.isFinite ? max(0, wordsPerMinute) : 0
        self.pauseDefaults = pauseDefaults
    }

    public static let standard = TimelineConfiguration(wordsPerMinute: 150)
}

/// The complete project input for one layout pass.
public struct TimelineProjectInput: Sendable, Equatable {
    public var scenes: [TimelineSceneInput]
    public var configuration: TimelineConfiguration

    public init(scenes: [TimelineSceneInput], configuration: TimelineConfiguration) {
        self.scenes = scenes
        self.configuration = configuration
    }
}

/// A UTF-16 range into the scene script.
public struct TimelineSourceRange: Sendable, Equatable, Hashable {
    public var location: Int
    public var length: Int

    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public var end: Int { location + length }
}

/// A scene positioned on the global timeline.
public struct TimelineScene: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var order: Int
    public var start: TimeInterval
    public var end: TimeInterval
    /// Markup-aware estimate from `ScriptMarkup`, even when a take wins.
    public var estimatedDuration: TimeInterval
    /// Selected real take duration, when one exists.
    public var realDuration: TimeInterval?
    public var takeCount: Int
    public var paragraphCount: Int

    public init(
        id: UUID,
        title: String,
        order: Int,
        start: TimeInterval,
        end: TimeInterval,
        estimatedDuration: TimeInterval,
        realDuration: TimeInterval?,
        takeCount: Int,
        paragraphCount: Int
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.start = start
        self.end = end
        self.estimatedDuration = estimatedDuration
        self.realDuration = realDuration
        self.takeCount = takeCount
        self.paragraphCount = paragraphCount
    }

    public var duration: TimeInterval { max(0, end - start) }

    public var hasRealTake: Bool { realDuration != nil }
}

/// One block on one track. Times are global seconds on the project timeline.
public struct TimelineBlock: Sendable, Equatable, Identifiable {
    public var id: String
    public var sceneID: UUID
    public var track: TimelineTrack
    public var start: TimeInterval
    public var end: TimeInterval
    /// Zero-based sub-row inside the track. Only takes use more than one lane.
    public var lane: Int
    /// The underlying B-roll item, editing note or take, when there is one.
    public var itemID: UUID?
    /// UTF-16 range in the scene script, for jumping back into the editor.
    public var sourceRange: TimelineSourceRange?
    public var label: String
    public var isSelected: Bool
    public var warningKind: RhythmWarning.Kind?
    /// Duration of the pause marker, before the real-take proportional scale.
    public var pauseSeconds: TimeInterval?
    /// False for a B-roll/editing item with no usable anchor.
    public var isAnchored: Bool
    /// Rating of a take block, mirrored for the canvas palette.
    public var takeRating: TimelineTakeRating?

    public init(
        id: String,
        sceneID: UUID,
        track: TimelineTrack,
        start: TimeInterval,
        end: TimeInterval,
        lane: Int = 0,
        itemID: UUID? = nil,
        sourceRange: TimelineSourceRange? = nil,
        label: String = "",
        isSelected: Bool = false,
        warningKind: RhythmWarning.Kind? = nil,
        pauseSeconds: TimeInterval? = nil,
        isAnchored: Bool = true,
        takeRating: TimelineTakeRating? = nil
    ) {
        self.id = id
        self.sceneID = sceneID
        self.track = track
        self.start = start
        self.end = max(start, end)
        self.lane = lane
        self.itemID = itemID
        self.sourceRange = sourceRange
        self.label = label
        self.isSelected = isSelected
        self.warningKind = warningKind
        self.pauseSeconds = pauseSeconds
        self.isAnchored = isAnchored
        self.takeRating = takeRating
    }

    /// Visible width in seconds. Zero for editing markers and degenerate
    /// ranges; the app still draws those with a minimum width.
    public var duration: TimeInterval { max(0, end - start) }
}

/// The complete, immutable timeline geometry for one project revision.
public struct TimelineLayout: Sendable, Equatable {
    public var scenes: [TimelineScene]
    public var blocks: [TimelineBlock]
    public var totalDuration: TimeInterval

    public init(scenes: [TimelineScene] = [], blocks: [TimelineBlock] = [], totalDuration: TimeInterval = 0) {
        self.scenes = scenes
        self.blocks = blocks
        self.totalDuration = totalDuration.isFinite ? max(0, totalDuration) : 0
    }

    public static let empty = TimelineLayout()

    public var isEmpty: Bool { scenes.isEmpty }

    public func blocks(on track: TimelineTrack) -> [TimelineBlock] {
        blocks.filter { $0.track == track }
    }

    public func block(id: String) -> TimelineBlock? {
        blocks.first { $0.id == id }
    }

    public func scene(id: UUID) -> TimelineScene? {
        scenes.first { $0.id == id }
    }

    public func scene(containing time: TimeInterval) -> TimelineScene? {
        scenes.first { time >= $0.start && time < $0.end }
    }

    /// Highest lane used by a track, so the canvas can size take rows.
    public func maximumLane(on track: TimelineTrack) -> Int {
        blocks(on: track).map(\.lane).max() ?? 0
    }
}

/// Builds the timeline geometry from scenes and a duration configuration.
///
/// All duration math goes through `ScriptMarkup.estimate` and
/// `ScriptMarkup.parse`; this type only places the resulting seconds on a
/// shared axis.
public enum TimelineLayoutBuilder {
    /// Duration given to a B-roll item without a planned length.
    public static let defaultBRollDuration: TimeInterval = 2
    /// Empty scenes still need a clickable block on the scene track.
    public static let minimumSceneDuration: TimeInterval = 0.5
    /// Takes are grouped into this many sub-lanes before they overlap.
    public static let maximumTakeLanes = 3
    /// Longest label copied from a paragraph or item.
    public static let maximumLabelLength = 160

    public static func build(_ input: TimelineProjectInput) -> TimelineLayout {
        var scenes: [TimelineScene] = []
        var blocks: [TimelineBlock] = []
        var cursor = 0.0

        for (order, scene) in input.scenes.enumerated() {
            let durationData = TimelineSceneDuration(
                text: scene.text,
                configuration: input.configuration,
                selectedTake: scene.takes.first(where: \.isSelected)
            )
            let effectiveDuration = max(
                durationData.effectiveDuration,
                durationData.effectiveDuration <= 0 ? minimumSceneDuration : 0
            )
            let sceneStart = cursor
            let sceneEnd = sceneStart + effectiveDuration
            let scale = durationData.scale

            let paragraphs = TimelineText.paragraphs(in: scene.text)

            blocks.append(TimelineBlock(
                id: "scene-\(scene.id.uuidString)",
                sceneID: scene.id,
                track: .scenes,
                start: sceneStart,
                end: sceneEnd,
                itemID: scene.id,
                sourceRange: TimelineSourceRange(
                    location: 0,
                    length: (scene.text as NSString).length
                ),
                label: scene.title
            ))

            for (index, paragraph) in paragraphs.enumerated() {
                let rawStart = durationData.time(atOffset: paragraph.range.location)
                let rawEnd = durationData.time(atOffset: paragraph.range.end)
                guard rawEnd > rawStart else { continue }
                blocks.append(TimelineBlock(
                    id: "narration-\(scene.id.uuidString)-\(index)",
                    sceneID: scene.id,
                    track: .narration,
                    start: sceneStart + rawStart * scale,
                    end: sceneStart + rawEnd * scale,
                    sourceRange: paragraph.range,
                    // What you will say: cues, pauses and emphasis marks are removed.
                    // A paragraph that is only a cue gets an empty label.
                    label: excerpt(ScriptMarkup.spokenText(paragraph.text))
                ))
            }

            for (index, pause) in durationData.pauses.enumerated() {
                let start = sceneStart + pause.start * scale
                let seconds = pause.seconds * scale
                guard seconds > 0 else { continue }
                blocks.append(TimelineBlock(
                    id: "pause-\(scene.id.uuidString)-\(index)",
                    sceneID: scene.id,
                    track: .pauses,
                    start: start,
                    end: start + seconds,
                    sourceRange: pause.sourceRange,
                    pauseSeconds: pause.seconds
                ))
            }

            for item in scene.bRoll {
                let anchor = item.anchorUTF16
                let rawStart = anchor.map { durationData.time(atOffset: $0) } ?? 0
                let start = sceneStart + rawStart * scale
                let length = item.duration > 0 ? item.duration : defaultBRollDuration
                blocks.append(TimelineBlock(
                    id: "broll-\(item.id.uuidString)",
                    sceneID: scene.id,
                    track: .bRoll,
                    start: start,
                    end: min(start + length, sceneEnd),
                    itemID: item.id,
                    label: excerpt(item.label),
                    isAnchored: anchor != nil
                ))
            }

            for item in scene.editing {
                let anchor = item.anchorUTF16
                let rawStart = anchor.map { durationData.time(atOffset: $0) } ?? 0
                let start = sceneStart + rawStart * scale
                blocks.append(TimelineBlock(
                    id: "editing-\(item.id.uuidString)",
                    sceneID: scene.id,
                    track: .editing,
                    start: start,
                    end: start,
                    itemID: item.id,
                    label: excerpt(item.label),
                    isAnchored: anchor != nil
                ))
            }

            var takeLane = 0
            for take in scene.takes where take.duration > 0 {
                let lane = min(takeLane, maximumTakeLanes - 1)
                takeLane += 1
                blocks.append(TimelineBlock(
                    id: "take-\(take.id.uuidString)",
                    sceneID: scene.id,
                    track: .takes,
                    start: sceneStart,
                    end: min(sceneStart + take.duration, sceneEnd),
                    lane: lane,
                    itemID: take.id,
                    label: "T\(take.number)",
                    isSelected: take.isSelected,
                    takeRating: take.rating
                ))
            }

            for (index, warning) in scene.warnings.enumerated() {
                let textLength = (scene.text as NSString).length
                let location = min(max(0, warning.location), textLength)
                let endOffset = min(location + warning.length, textLength)
                let rawStart = durationData.time(atOffset: location)
                let rawEnd = durationData.time(atOffset: endOffset)
                blocks.append(TimelineBlock(
                    id: "warning-\(scene.id.uuidString)-\(index)",
                    sceneID: scene.id,
                    track: .warnings,
                    start: sceneStart + rawStart * scale,
                    end: sceneStart + max(rawStart, rawEnd) * scale,
                    sourceRange: TimelineSourceRange(location: location, length: endOffset - location),
                    label: warning.kind.rawValue,
                    warningKind: warning.kind
                ))
            }

            scenes.append(TimelineScene(
                id: scene.id,
                title: scene.title,
                order: order,
                start: sceneStart,
                end: sceneEnd,
                estimatedDuration: durationData.estimate,
                realDuration: durationData.realDuration,
                takeCount: scene.takes.filter { $0.duration > 0 }.count,
                paragraphCount: paragraphs.count
            ))
            cursor = sceneEnd
        }

        return TimelineLayout(scenes: scenes, blocks: blocks, totalDuration: cursor)
    }

    public static func build(
        scenes: [TimelineSceneInput],
        configuration: TimelineConfiguration
    ) -> TimelineLayout {
        build(TimelineProjectInput(scenes: scenes, configuration: configuration))
    }

    static func excerpt(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maximumLabelLength else { return collapsed }
        // Cut at a word boundary so a wide block never shows a half word; the
        // app truncates further on whole words when the block is narrower.
        var cut = String(collapsed.prefix(maximumLabelLength))
        let next = collapsed[collapsed.index(collapsed.startIndex, offsetBy: maximumLabelLength)]
        if next != " ", let space = cut.lastIndex(of: " ") {
            cut = String(cut[..<space])
        }
        return cut.trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Scene duration

    private struct TimelineSceneDuration {
        let estimate: TimeInterval
        let realDuration: TimeInterval?
        let scale: Double
        let timeMap: TimelineTextTimeMap
        let pauses: [TimelinePause]

        init(text: String, configuration: TimelineConfiguration, selectedTake: TimelineTakeInput?) {
            let estimate = ScriptMarkup.estimate(
                text,
                wordsPerMinute: configuration.wordsPerMinute,
                defaults: configuration.pauseDefaults
            ).duration
            let safeEstimate = estimate.isFinite ? max(0, estimate) : 0

            let selectedDuration = selectedTake.flatMap { take -> TimeInterval? in
                guard take.duration.isFinite, take.duration > 0 else { return nil }
                return take.duration
            }

            let scale: Double
            if let selectedDuration, safeEstimate > 0 {
                let value = selectedDuration / safeEstimate
                scale = value.isFinite && value > 0 ? value : 1
            } else {
                scale = 1
            }

            self.estimate = safeEstimate
            self.realDuration = selectedDuration
            self.scale = scale
            self.timeMap = TimelineTextTimeMap(
                text: text,
                configuration: configuration,
                estimate: safeEstimate
            )
            self.pauses = timeMap.pauses
        }

        var effectiveDuration: TimeInterval {
            realDuration ?? estimate
        }

        func time(atOffset offset: Int) -> TimeInterval {
            timeMap.time(atOffset: offset)
        }
    }
}

// MARK: - Paragraphs

/// One paragraph of a script, with its UTF-16 range.
public struct TimelineParagraph: Sendable, Equatable {
    public var range: TimelineSourceRange
    public var text: String

    public init(range: TimelineSourceRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// Splits a script into paragraphs. Blank lines separate paragraphs; single
/// line breaks stay inside one paragraph. Leading and trailing whitespace is
/// trimmed from every range.
public enum TimelineText {
    public static func paragraphs(in text: String) -> [TimelineParagraph] {
        let full = text as NSString
        guard full.length > 0 else { return [] }

        var result: [TimelineParagraph] = []
        var paragraphStart: Int?
        var paragraphEnd = 0
        var index = 0

        while index < full.length {
            let lineRange = full.lineRange(for: NSRange(location: index, length: 0))
            var contentEnd = lineRange.location + lineRange.length
            while contentEnd > lineRange.location {
                let character = full.character(at: contentEnd - 1)
                if character == 0x0A || character == 0x0D {
                    contentEnd -= 1
                } else {
                    break
                }
            }

            let trimmed = trimmedRange(
                NSRange(location: lineRange.location, length: contentEnd - lineRange.location),
                in: full
            )

            if trimmed.length == 0 {
                flush(&result, full: full, start: &paragraphStart, end: paragraphEnd)
            } else {
                if paragraphStart == nil {
                    paragraphStart = trimmed.location
                }
                paragraphEnd = trimmed.location + trimmed.length
            }

            let advance = max(1, lineRange.length)
            index = lineRange.location + advance
        }

        flush(&result, full: full, start: &paragraphStart, end: paragraphEnd)
        return result
    }

    private static func flush(
        _ result: inout [TimelineParagraph],
        full: NSString,
        start: inout Int?,
        end: Int
    ) {
        guard let location = start, end > location else {
            start = nil
            return
        }
        let range = NSRange(location: location, length: end - location)
        result.append(TimelineParagraph(
            range: TimelineSourceRange(location: range.location, length: range.length),
            text: full.substring(with: range)
        ))
        start = nil
    }

    private static func trimmedRange(_ range: NSRange, in full: NSString) -> NSRange {
        var location = range.location
        var end = range.location + range.length
        while location < end, isWhitespace(full.character(at: location)) {
            location += 1
        }
        while end > location, isWhitespace(full.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: location, length: end - location)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }
}

// MARK: - Text offset to time

/// A pause marker positioned in raw scene time (before any real-take scale).
struct TimelinePause: Sendable, Equatable {
    let start: TimeInterval
    let seconds: TimeInterval
    let sourceRange: TimelineSourceRange
}

/// Maps UTF-16 offsets to seconds inside one scene.
///
/// Narration seconds are distributed by spoken word count across markup tokens;
/// pauses occupy their marker range. This is the only text-to-time mapping in
/// the timeline and is shared by paragraphs, anchors and warnings.
struct TimelineTextTimeMap: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let range: TimelineSourceRange
        let start: TimeInterval
        let end: TimeInterval
        let isPause: Bool
        /// Spoken word spans inside `range`, in UTF-16 source coordinates.
        let wordSpans: [TimelineSourceRange]
    }

    let length: Int
    let segments: [Segment]
    let total: TimeInterval
    let pauses: [TimelinePause]

    init(text: String, configuration: TimelineConfiguration, estimate: TimeInterval) {
        let tokens = ScriptMarkup.parse(text, defaults: configuration.pauseDefaults)
        let full = text as NSString
        let utf16Length = full.length

        var tokenWords: [[TimelineSourceRange]] = []
        tokenWords.reserveCapacity(tokens.count)
        var totalWords = 0
        var totalPauseSeconds = 0.0
        var pauseMarkers: [TimelinePause] = []

        for token in tokens {
            switch token.kind {
            case .text, .emphasis:
                let spans = Self.wordSpans(in: full, range: token.range)
                tokenWords.append(spans)
                totalWords += spans.count
            case .pause(let seconds, _):
                tokenWords.append([])
                totalPauseSeconds += max(0, seconds)
                pauseMarkers.append(TimelinePause(
                    start: 0,
                    seconds: max(0, seconds),
                    sourceRange: TimelineSourceRange(
                        location: token.range.location,
                        length: token.range.length
                    )
                ))
            case .cue:
                tokenWords.append([])
            }
        }

        let narration = max(0, estimate - totalPauseSeconds)
        var segments: [Segment] = []
        segments.reserveCapacity(tokens.count)
        var cursor = 0.0
        var pauseIndex = 0

        for (index, token) in tokens.enumerated() {
            let start = cursor
            switch token.kind {
            case .pause(let seconds, _):
                let duration = max(0, seconds)
                cursor += duration
                if pauseIndex < pauseMarkers.count {
                    let marker = pauseMarkers[pauseIndex]
                    pauseMarkers[pauseIndex] = TimelinePause(
                        start: start,
                        seconds: duration,
                        sourceRange: marker.sourceRange
                    )
                    pauseIndex += 1
                }
                segments.append(Segment(
                    range: TimelineSourceRange(location: token.range.location, length: token.range.length),
                    start: start,
                    end: cursor,
                    isPause: true,
                    wordSpans: []
                ))
            case .text, .emphasis:
                let spans = tokenWords[index]
                let duration = totalWords > 0 ? narration * Double(spans.count) / Double(totalWords) : 0
                cursor += duration
                segments.append(Segment(
                    range: TimelineSourceRange(location: token.range.location, length: token.range.length),
                    start: start,
                    end: cursor,
                    isPause: false,
                    wordSpans: spans
                ))
            case .cue:
                segments.append(Segment(
                    range: TimelineSourceRange(location: token.range.location, length: token.range.length),
                    start: start,
                    end: start,
                    isPause: false,
                    wordSpans: []
                ))
            }
        }

        self.length = utf16Length
        self.segments = segments
        self.total = estimate
        self.pauses = pauseMarkers
    }

    /// Maps an offset to elapsed seconds. Offsets advance one equal share per
    /// spoken word, so a short word and a long one take the same speaking time
    /// until the reader is inside the word; inside a word the time advances
    /// with its UTF-16 progress.
    func time(atOffset offset: Int) -> TimeInterval {
        guard !segments.isEmpty else { return 0 }
        guard offset > 0 else { return 0 }
        let clamped = min(offset, length)
        guard clamped < length else { return total }

        for segment in segments where clamped < segment.range.end {
            if segment.isPause || segment.range.length <= 0 || segment.wordSpans.isEmpty {
                return segment.start
            }
            let count = segment.wordSpans.count
            let duration = segment.end - segment.start
            let wordDuration = duration / Double(count)

            for (index, span) in segment.wordSpans.enumerated() {
                if clamped < span.location {
                    return segment.start + Double(index) * wordDuration
                }
                if clamped < span.end {
                    let fraction = Double(clamped - span.location) / Double(max(1, span.length))
                    return segment.start + (Double(index) + min(max(0, fraction), 1)) * wordDuration
                }
            }
            return segment.end
        }
        return total
    }

    /// UTF-16 spans of whitespace-separated runs containing at least one
    /// letter or digit, matching `ScriptMarkup`'s word rule.
    static func wordSpans(in full: NSString, range: NSRange) -> [TimelineSourceRange] {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= full.length else {
            return []
        }
        let substring = full.substring(with: range)
        var spans: [TimelineSourceRange] = []
        var runStart: Int?
        var runHasWord = false
        var offset = 0

        for scalar in substring.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if scalar.properties.isWhitespace {
                if let start = runStart, runHasWord {
                    spans.append(TimelineSourceRange(location: range.location + start, length: offset - start))
                }
                runStart = nil
                runHasWord = false
            } else {
                if runStart == nil { runStart = offset }
                if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                    runHasWord = true
                }
            }
            offset += width
        }

        if let start = runStart, runHasWord {
            spans.append(TimelineSourceRange(location: range.location + start, length: offset - start))
        }
        return spans
    }
}
