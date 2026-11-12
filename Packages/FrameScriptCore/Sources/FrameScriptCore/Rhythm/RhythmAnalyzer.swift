import Foundation

/// Role of a scene inside the video. Hooks get a stricter length limit (F26).
public enum SceneRole: String, Sendable, Codable, CaseIterable {
    case hook
    case normal
}

/// Input for one scene analysis.
public struct RhythmSceneInput: Sendable, Equatable, Codable {
    public var id: String
    public var text: String
    /// Speaking rate used to estimate seconds. Values below `1`, non-finite or
    /// negative are treated as invalid: word-reading time contributes zero,
    /// while pause time is still counted (matching
    /// `ScriptMarkup.estimateDuration`).
    public var wordsPerMinute: Double
    /// UTF-16 offsets where an anchored B-roll item or cut begins.
    public var visualChangeOffsets: [Int]
    public var role: SceneRole

    public init(
        id: String,
        text: String,
        wordsPerMinute: Double = 150,
        visualChangeOffsets: [Int] = [],
        role: SceneRole = .normal
    ) {
        self.id = id
        self.text = text
        self.wordsPerMinute = wordsPerMinute
        self.visualChangeOffsets = visualChangeOffsets
        self.role = role
    }
}

/// Returns the total pause time inside a UTF-16 range. The app supplies this
/// from its pause marks; the default provider reports no pauses.
public typealias PauseDurationProvider = @Sendable (UTF16Span) -> TimeInterval

/// A numeric placeholder for the localized warning text.
public struct RhythmArgument: Sendable, Equatable, Hashable, Codable {
    public let name: String
    public let value: Double

    public init(_ name: String, _ value: Double) {
        self.name = name
        self.value = value
    }
}

/// Stable localization keys for rhythm warnings. The app owns the translated
/// strings (es/en/ru); the core package only emits the key and numeric args.
public enum RhythmMessageKey {
    public static let longSentence = "rhythm.longSentence"
    public static let noVisualChange = "rhythm.noVisualChange"
    public static let longHook = "rhythm.longHook"
    public static let sceneLengthOutlier = "rhythm.sceneLengthOutlier"
}

/// One rhythm warning with an exact UTF-16 range for editor underlining.
public struct RhythmWarning: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A sentence above the word or seconds limit.
        case longSentence
        /// Narration without an anchored visual change for too long.
        case noVisualChange
        /// Hook scene longer than `hookMaxSeconds`.
        case longHook
        /// Scene much longer than the project average.
        case sceneLengthOutlier
    }

    public let sceneID: String?
    public let kind: Kind
    public let range: UTF16Span
    public let messageKey: String
    public let arguments: [RhythmArgument]

    public init(
        sceneID: String?,
        kind: Kind,
        range: UTF16Span,
        messageKey: String,
        arguments: [RhythmArgument] = []
    ) {
        self.sceneID = sceneID
        self.kind = kind
        self.range = range
        self.messageKey = messageKey
        self.arguments = arguments
    }

    public var id: String {
        "\(sceneID ?? "-"):\(kind.rawValue):\(range.location):\(range.length)"
    }
}

/// Result for one scene.
public struct RhythmSceneAnalysis: Sendable, Equatable {
    public let sceneID: String
    public let utf16Length: Int
    public let wordCount: Int
    public let durationSeconds: Double
    public let sentences: [RhythmSentence]
    public let warnings: [RhythmWarning]

    public init(
        sceneID: String,
        utf16Length: Int,
        wordCount: Int,
        durationSeconds: Double,
        sentences: [RhythmSentence],
        warnings: [RhythmWarning]
    ) {
        self.sceneID = sceneID
        self.utf16Length = utf16Length
        self.wordCount = wordCount
        self.durationSeconds = durationSeconds
        self.sentences = sentences
        self.warnings = warnings
    }
}

/// Result for a whole project. `projectWarnings` holds only the cross-scene
/// outlier warnings; per-scene warnings live in `scenes`.
public struct RhythmProjectAnalysis: Sendable, Equatable {
    public let scenes: [RhythmSceneAnalysis]
    public let projectWarnings: [RhythmWarning]

    public init(scenes: [RhythmSceneAnalysis], projectWarnings: [RhythmWarning]) {
        self.scenes = scenes
        self.projectWarnings = projectWarnings
    }

    public var allWarnings: [RhythmWarning] {
        scenes.flatMap(\.warnings) + projectWarnings
    }
}

/// Local, offline rhythm review (F26).
///
/// Everything is pure and deterministic: text in, warnings out. Durations are
/// estimated as `words / wpm * 60` plus whatever the pause provider returns for
/// a range. A non-finite or sub-1 WPM disables reading time but pause time is
/// still counted; note the app normally supplies a valid rate.
public enum RhythmAnalyzer {
    /// Pause provider that reports no pauses.
    public static let noPauses: PauseDurationProvider = { _ in 0 }

    public static func analyze(
        scene: RhythmSceneInput,
        thresholds: RhythmThresholds = .default,
        pauseDuration: PauseDurationProvider = RhythmAnalyzer.noPauses
    ) -> RhythmSceneAnalysis {
        let text = scene.text
        let ns = text as NSString
        let utf16Length = ns.length
        let units = RhythmCharacterUnit.make(text)
        let cueMask = RhythmMarkupScan.cueMask(for: units)
        let urlMask = RhythmMarkupScan.urlMask(for: units)
        let wordSpans = RhythmWordCounter.wordSpans(
            in: units,
            cueMask: cueMask,
            urlMask: urlMask
        )
        let sentences = RhythmSentenceSplitter.makeSentences(
            in: text,
            units: units,
            cueMask: cueMask,
            urlMask: urlMask,
            wordSpans: wordSpans
        )
        let wordCount = wordSpans.count
        let rate = scene.wordsPerMinute
        let hasValidRate = rate.isFinite && rate >= 1

        func seconds(in range: UTF16Span) -> Double {
            let words = Double(RhythmWordCounter.count(in: range, spans: wordSpans))
            let narration = hasValidRate ? words / rate * 60.0 : 0
            let pause = pauseDuration(range)
            let safePause = pause.isFinite ? max(0, pause) : 0
            let total = narration + safePause
            return total.isFinite ? total : Double.greatestFiniteMagnitude
        }

        let wholeScene = UTF16Span(location: 0, length: utf16Length)
        let totalSeconds = seconds(in: wholeScene)
        var warnings: [RhythmWarning] = []

        if scene.role == .hook, totalSeconds > thresholds.hookMaxSeconds {
            warnings.append(RhythmWarning(
                sceneID: scene.id,
                kind: .longHook,
                range: wholeScene,
                messageKey: RhythmMessageKey.longHook,
                arguments: [
                    RhythmArgument("seconds", totalSeconds),
                    RhythmArgument("limit", thresholds.hookMaxSeconds)
                ]
            ))
        }

        for sentence in sentences {
            let sentenceSeconds = seconds(in: sentence.range)
            let tooManyWords = sentence.wordCount > thresholds.maxSentenceWords
            let tooSlow = sentenceSeconds > thresholds.maxSentenceSeconds
            guard tooManyWords || tooSlow else { continue }
            warnings.append(RhythmWarning(
                sceneID: scene.id,
                kind: .longSentence,
                range: sentence.range,
                messageKey: RhythmMessageKey.longSentence,
                arguments: [
                    RhythmArgument("words", Double(sentence.wordCount)),
                    RhythmArgument("seconds", sentenceSeconds),
                    RhythmArgument("maxWords", Double(thresholds.maxSentenceWords)),
                    RhythmArgument("maxSeconds", thresholds.maxSentenceSeconds)
                ]
            ))
        }

        let anchors = normalizedAnchors(scene.visualChangeOffsets, units: units)
        var previousBoundary = 0
        for boundary in anchors + [utf16Length] {
            guard boundary > previousBoundary else { continue }
            let range = UTF16Span(
                location: previousBoundary,
                length: boundary - previousBoundary
            )
            let stretchSeconds = seconds(in: range)
            if stretchSeconds > thresholds.maxSecondsWithoutVisualChange {
                warnings.append(RhythmWarning(
                    sceneID: scene.id,
                    kind: .noVisualChange,
                    range: range,
                    messageKey: RhythmMessageKey.noVisualChange,
                    arguments: [
                        RhythmArgument("seconds", stretchSeconds),
                        RhythmArgument("limit", thresholds.maxSecondsWithoutVisualChange)
                    ]
                ))
            }
            previousBoundary = boundary
        }

        sortWarnings(&warnings)

        return RhythmSceneAnalysis(
            sceneID: scene.id,
            utf16Length: utf16Length,
            wordCount: wordCount,
            durationSeconds: totalSeconds,
            sentences: sentences,
            warnings: warnings
        )
    }

    /// Analyzes every scene and adds the project-level "scene much longer than
    /// average" warnings. Empty scenes are ignored when computing the average.
    public static func analyzeProject(
        scenes: [RhythmSceneInput],
        thresholds: RhythmThresholds = .default,
        pauseDuration: PauseDurationProvider = RhythmAnalyzer.noPauses
    ) -> RhythmProjectAnalysis {
        let analyses = scenes.map {
            analyze(scene: $0, thresholds: thresholds, pauseDuration: pauseDuration)
        }
        var projectWarnings: [RhythmWarning] = []

        let nonEmptyDurations = analyses
            .map(\.durationSeconds)
            .filter { $0.isFinite && $0 > 0 }
        if nonEmptyDurations.count >= 2,
           thresholds.sceneLengthOutlierFactor.isFinite,
           thresholds.sceneLengthOutlierFactor > 0 {
            let average = nonEmptyDurations.reduce(0, +) / Double(nonEmptyDurations.count)
            if average.isFinite, average > 0 {
                for analysis in analyses {
                    let limit = average * thresholds.sceneLengthOutlierFactor
                    guard analysis.durationSeconds > limit else { continue }
                    projectWarnings.append(RhythmWarning(
                        sceneID: analysis.sceneID,
                        kind: .sceneLengthOutlier,
                        range: UTF16Span(location: 0, length: analysis.utf16Length),
                        messageKey: RhythmMessageKey.sceneLengthOutlier,
                        arguments: [
                            RhythmArgument("seconds", analysis.durationSeconds),
                            RhythmArgument("average", average),
                            RhythmArgument("factor", thresholds.sceneLengthOutlierFactor)
                        ]
                    ))
                }
            }
        }

        return RhythmProjectAnalysis(scenes: analyses, projectWarnings: projectWarnings)
    }

    private static func normalizedAnchors(
        _ offsets: [Int],
        units: [RhythmCharacterUnit]
    ) -> [Int] {
        guard let lastUnit = units.last, !offsets.isEmpty else { return [] }
        let length = lastUnit.end
        guard length > 0 else { return [] }

        // Every grapheme boundary, ascending. Anchors that land inside a
        // surrogate pair or a ZWJ sequence snap down to the character start so
        // warning ranges never slice a composed character.
        var boundaries: [Int] = []
        boundaries.reserveCapacity(units.count + 1)
        boundaries.append(0)
        for unit in units {
            boundaries.append(unit.end)
        }

        var seen = Set<Int>()
        var result: [Int] = []
        for offset in offsets where offset > 0 && offset < length {
            var low = 0
            var high = boundaries.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if boundaries[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            let snapped = boundaries[low]
            guard snapped > 0, snapped < length else { continue }
            if seen.insert(snapped).inserted { result.append(snapped) }
        }
        return result.sorted()
    }

    private static func sortWarnings(_ warnings: inout [RhythmWarning]) {
        warnings.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.range.length < rhs.range.length
        }
    }
}
