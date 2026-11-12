import Foundation

/// The two configurable pause durations used by inline pause markers.
///
/// A single isolated `/` produces ``short`` seconds and `//` produces ``long``
/// seconds. A bare `[pausa]` / `[pause]` also uses ``long``. Users can change
/// these values in Settings; the parser never mutates them and clamps negative
/// values to zero when it builds tokens.
public struct PauseDefaults: Codable, Sendable, Hashable {
    /// Duration in seconds of a short pause (a single `/`).
    public var short: TimeInterval
    /// Duration in seconds of a long pause (`//`, `[pausa]` or `[pause]`).
    public var long: TimeInterval

    /// Creates a pair of pause durations.
    ///
    /// - Parameters:
    ///   - short: The short pause, in seconds. Defaults to `0.5`.
    ///   - long: The long pause, in seconds. Defaults to `1.0`.
    public init(short: TimeInterval = 0.5, long: TimeInterval = 1.0) {
        self.short = short
        self.long = long
    }

    /// The defaults described by the design document: 0.5 s and 1.0 s.
    public static let standard = PauseDefaults()

    /// A copy with negative durations replaced by zero.
    var sanitized: PauseDefaults {
        PauseDefaults(short: max(0, short), long: max(0, long))
    }
}

/// How strongly a span of text should be delivered.
public enum EmphasisLevel: Int, Codable, Sendable, Hashable, CaseIterable, Comparable {
    /// `*word*`: normal emphasis.
    case emphasis = 1
    /// `**word**`: strong emphasis.
    case strong = 2

    public static func < (lhs: EmphasisLevel, rhs: EmphasisLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One piece of a parsed script, with UTF-16 ranges into the original text.
///
/// Tokens are ordered by their position in the source and never overlap. Every
/// character of the original string belongs to exactly one token, which makes
/// the ranges safe to feed to TextKit for highlighting. For a token with
/// delimiters (emphasis, pause or cue), ``range`` covers the whole construct
/// including its delimiters while ``markerRanges`` contains the delimiters
/// alone so an editor can dim them.
public struct MarkupToken: Sendable, Equatable {
    /// The semantic kind of a token.
    public enum Kind: Sendable, Equatable {
        /// Plain, spoken text. ``MarkupToken/text`` is the text itself.
        case text
        /// Text wrapped in `*` (``EmphasisLevel/emphasis``) or `**` (``EmphasisLevel/strong``).
        case emphasis(_ level: EmphasisLevel)
        /// A pause.
        ///
        /// - Parameters:
        ///   - seconds: The pause duration in seconds.
        ///   - explicit: `true` for bracket pauses (`[pausa]`, `[2s]`, …),
        ///     `false` for the `/` / `//` shorthand.
        case pause(seconds: TimeInterval, explicit: Bool)
        /// Any other single-line bracket cue, such as `[IMAGEN: …]`, `[RE-HOOK]`
        /// or `[B-ROLL]`.
        ///
        /// - Parameters:
        ///   - label: The canonical uppercased label (`IMAGEN`, `RE-HOOK`, …).
        ///   - payload: Everything after the first colon, trimmed, or `""`.
        case cue(label: String, payload: String)
    }

    /// What this token means.
    public let kind: Kind

    /// The token's full extent, in UTF-16 code units, into the original text.
    public let range: NSRange

    /// The delimiter ranges (markers), in UTF-16 code units, into the original text.
    ///
    /// Sorted and contained by ``range``. Empty for plain text. For emphasis
    /// these are the opening and closing asterisks, for bracket pauses and cues
    /// the two square brackets, and for slash pauses the slash run itself.
    public let markerRanges: [NSRange]

    /// The semantic text of the token.
    ///
    /// For ``Kind/text`` this is the source text with `\*` and `\/` escapes
    /// resolved. For ``Kind/emphasis(_:)`` it is the emphasized content with
    /// escapes resolved. Pauses and cues have no spoken text and use `""`.
    public let text: String

    /// Creates a token. Primarily useful for tests and previews.
    public init(kind: Kind, range: NSRange, markerRanges: [NSRange] = [], text: String = "") {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.text = text
    }

    /// `true` when the token came from a marker and therefore carries delimiters.
    public var isMarker: Bool {
        !markerRanges.isEmpty
    }
}

/// A simplified display run for a teleprompter or any other consumer that only
/// needs the visible words plus pause/cue signals.
///
/// Unlike ``MarkupToken``, runs carry the visible strings directly and contain
/// no ranges. Adjacent plain-text tokens are merged into one ``text(_:)`` run.
public enum MarkupRun: Sendable, Equatable {
    /// Plain spoken text, including its original spacing.
    case text(String)
    /// Emphasized text and how strongly to display it.
    case emphasis(_ text: String, level: EmphasisLevel)
    /// A pause of the given duration, in seconds.
    case pause(_ seconds: TimeInterval)
    /// A non-pause bracket cue. Only the canonical label is kept.
    case cue(_ label: String)
}
