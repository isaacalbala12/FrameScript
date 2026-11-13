import Foundation
import FrameScriptCore

/// Visual treatment of one parsed markup run.
///
/// The planner never changes the text: delimiters stay visible and only their
/// color is dimmed. The AppKit layer maps each style to fonts and colors.
enum MarkupHighlightStyle: String, Equatable, Sendable, CaseIterable {
    /// `*palabra*`.
    case emphasis
    /// `**palabra**`.
    case strongEmphasis
    /// A single `/` pause.
    case shortPause
    /// A `//` or bare `[pausa]` pause.
    case longPause
    /// `[2s]`, `[pausa 1,5s]`.
    case explicitPause
    /// A bracket cue such as `[IMAGEN: coche]`.
    case cue
    /// Markup delimiters (`*`, `[`, `]`, escaped backslashes) drawn dimmed.
    case delimiter
}

/// One UTF-16 range and how an editor should paint it. Runs are sorted and
/// non-overlapping.
struct MarkupHighlightRun: Equatable, Sendable {
    let range: NSRange
    let style: MarkupHighlightStyle
}

/// Builds the attribute plan for the script editor.
///
/// This is deliberately pure and AppKit-free so it can be tested without a
/// window. `MarkupEditorStyler` turns these runs into fonts and colors.
enum MarkupHighlightPlanner {
    /// Plans every markup run in `text`.
    static func highlightRuns(
        text: String,
        pauseDefaults: PauseDefaults
    ) -> [MarkupHighlightRun] {
        let length = (text as NSString).length
        return highlightRuns(
            text: text,
            pauseDefaults: pauseDefaults,
            in: NSRange(location: 0, length: length)
        )
    }

    /// Plans the runs inside `range`.
    ///
    /// The range is parsed as its own string, so callers should extend it to
    /// whole paragraphs (``extendedParagraphRange(around:in:)``) before calling
    /// this. Runs are returned in the coordinates of the full `text`.
    static func highlightRuns(
        text: String,
        pauseDefaults: PauseDefaults,
        in range: NSRange
    ) -> [MarkupHighlightRun] {
        let nsText = text as NSString
        let clamped = clamp(range, toLength: nsText.length)
        guard clamped.length > 0 else { return [] }

        let fragment = nsText.substring(with: clamped)
        var runs: [MarkupHighlightRun] = []

        for token in ScriptMarkup.parse(fragment, defaults: pauseDefaults) {
            let tokenRange = offset(token.range, by: clamped.location)
            switch token.kind {
            case .text:
                break
            case .emphasis(let level):
                let markerRanges = token.markerRanges.map { offset($0, by: clamped.location) }
                let style: MarkupHighlightStyle = level == .strong ? .strongEmphasis : .emphasis
                for contentRange in subtract(markerRanges, from: tokenRange) {
                    runs.append(MarkupHighlightRun(range: contentRange, style: style))
                }
                for markerRange in markerRanges {
                    runs.append(MarkupHighlightRun(range: markerRange, style: .delimiter))
                }
            case .pause(let seconds, let explicit):
                let style: MarkupHighlightStyle
                if explicit {
                    style = .explicitPause
                } else if token.range.length > 1 || seconds > pauseDefaults.short + 0.001 {
                    style = .longPause
                } else {
                    style = .shortPause
                }
                runs.append(MarkupHighlightRun(range: tokenRange, style: style))
            case .cue:
                runs.append(MarkupHighlightRun(range: tokenRange, style: .cue))
            }

            for escapeRange in token.escapeRanges {
                runs.append(MarkupHighlightRun(
                    range: offset(escapeRange, by: clamped.location),
                    style: .delimiter
                ))
            }
        }

        return normalizedRuns(runs, limit: nsText.length)
    }

    /// Largest slice the editor re-highlights synchronously after a keystroke.
    /// The editor schedules a full pass once typing pauses so markers outside
    /// the window still refresh.
    static let maximumIncrementalLength = 8_000

    /// Whole blank-line-separated block around `range`, capped to
    /// ``maximumIncrementalLength``.
    ///
    /// Emphasis cannot cross a blank line (it may span any number of ordinary
    /// line breaks), so every delimiter that can reach the edit lives inside
    /// the same block. Expanding to block boundaries keeps typing latency
    /// independent of document size; a block bigger than the cap falls back to
    /// a window around the edit plus a deferred full pass.
    static func extendedParagraphRange(around range: NSRange, in text: NSString) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = clamp(range, toLength: text.length)
        let location = min(clamped.location, max(0, text.length - 1))
        let endProbe = min(max(location, NSMaxRange(clamped) - 1), max(0, text.length - 1))
        let firstParagraph = paragraphRange(at: location, in: text)
        let lastParagraph = paragraphRange(at: endProbe, in: text)
        var start = firstParagraph.location
        var end = max(NSMaxRange(firstParagraph), NSMaxRange(lastParagraph))

        // Walk to blank-line boundaries, but stop as soon as the block is
        // already as large as the incremental cap so a giant paragraph costs
        // bounded work per keystroke.
        while start > 0, end - start < maximumIncrementalLength {
            let previous = paragraphRange(at: start - 1, in: text)
            guard !isBlankParagraph(previous, in: text) else { break }
            start = previous.location
        }
        while end < text.length, end - start < maximumIncrementalLength {
            let next = paragraphRange(at: end, in: text)
            guard !isBlankParagraph(next, in: text) else { break }
            end = NSMaxRange(next)
        }

        // Include one blank-line paragraph on each side. Typing the blank line
        // that splits a block must keep the old delimiters highlighted.
        if start > 0 {
            start = paragraphRange(at: start - 1, in: text).location
        }
        if end < text.length {
            end = NSMaxRange(paragraphRange(at: end, in: text))
        }

        let expanded = NSRange(location: start, length: end - start)
        guard expanded.length > maximumIncrementalLength else { return expanded }

        let half = maximumIncrementalLength / 2
        var windowStart = max(expanded.location, clamped.location - half)
        let windowEnd = min(NSMaxRange(expanded), windowStart + maximumIncrementalLength)
        if windowEnd - windowStart < maximumIncrementalLength {
            windowStart = max(expanded.location, windowEnd - maximumIncrementalLength)
        }
        guard windowEnd > windowStart else { return expanded }
        return NSRange(location: windowStart, length: windowEnd - windowStart)
    }

    /// True when the edit is inside a block larger than the incremental cap
    /// and the editor should follow up with a full pass once typing stops.
    static func needsDeferredFullRefresh(around range: NSRange, in text: NSString) -> Bool {
        extendedParagraphRange(around: range, in: text).length >= maximumIncrementalLength
    }

    /// Whether an edit (for example a multi-paragraph paste) is fully covered
    /// by the incremental window around the caret.
    ///
    /// When it is not, the editor must re-highlight the whole document instead
    /// of leaving the pasted markers unstyled.
    static func incrementalWindowCoversEdit(
        _ edit: NSRange,
        around caret: NSRange,
        in text: NSString
    ) -> Bool {
        let window = extendedParagraphRange(around: caret, in: text)
        let safeEdit = clamp(edit, toLength: text.length)
        return safeEdit.location >= window.location
            && NSMaxRange(safeEdit) <= NSMaxRange(window)
    }

    private static func paragraphRange(at location: Int, in text: NSString) -> NSRange {
        text.paragraphRange(for: NSRange(
            location: min(max(0, location), max(0, text.length - 1)),
            length: 0
        ))
    }

    private static func isBlankParagraph(_ range: NSRange, in text: NSString) -> Bool {
        text.substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Clamps a range, never returning a location beyond `length`.
    static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), length - location))
    }

    // MARK: - Helpers

    private static func offset(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    /// Ranges inside `range` that are not covered by any entry in `holes`.
    private static func subtract(_ holes: [NSRange], from range: NSRange) -> [NSRange] {
        guard !holes.isEmpty else { return [range] }
        let sortedHoles = holes
            .filter { $0.length > 0 && NSIntersectionRange($0, range).length > 0 }
            .sorted { $0.location < $1.location }
        var result: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        for hole in sortedHoles {
            let holeStart = max(cursor, hole.location)
            let holeEnd = min(end, NSMaxRange(hole))
            if holeStart > cursor {
                result.append(NSRange(location: cursor, length: holeStart - cursor))
            }
            cursor = max(cursor, holeEnd)
            if cursor >= end { break }
        }
        if cursor < end {
            result.append(NSRange(location: cursor, length: end - cursor))
        }
        return result
    }

    /// Drops empty/out-of-bounds runs, merges adjacent equal styles and sorts.
    private static func normalizedRuns(
        _ runs: [MarkupHighlightRun],
        limit: Int
    ) -> [MarkupHighlightRun] {
        let valid = runs.compactMap { run -> MarkupHighlightRun? in
            let range = clamp(run.range, toLength: limit)
            guard range.length > 0 else { return nil }
            return MarkupHighlightRun(range: range, style: run.style)
        }.sorted { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            return lhs.range.length > rhs.range.length
        }

        var merged: [MarkupHighlightRun] = []
        for run in valid {
            if let last = merged.last,
               last.style == run.style,
               NSMaxRange(last.range) == run.range.location {
                merged[merged.count - 1] = MarkupHighlightRun(
                    range: NSRange(location: last.range.location, length: last.range.length + run.range.length),
                    style: run.style
                )
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}

/// One rhythm warning painted as a wavy underline. `message` is already
/// localized and resolved by the app.
struct RhythmEditorUnderline: Equatable, Sendable {
    let range: NSRange
    let kind: RhythmWarning.Kind
    let message: String
}

/// Maps analyzer warnings to editor ranges, clamped to the current text.
enum RhythmUnderlinePlanner {
    static func underlines(
        warnings: [RhythmWarning],
        textLength: Int,
        message: (RhythmWarning) -> String
    ) -> [RhythmEditorUnderline] {
        warnings.compactMap { warning in
            let range = MarkupHighlightPlanner.clamp(
                NSRange(location: warning.range.location, length: warning.range.length),
                toLength: textLength
            )
            guard range.length > 0 else { return nil }
            return RhythmEditorUnderline(range: range, kind: warning.kind, message: message(warning))
        }
    }
}
