import Foundation

/// The two configurable pause durations used by inline pause markers.
///
/// A single isolated `/` produces ``short`` seconds and `//` produces ``long``
/// seconds. A bare `[pausa]` / `[pause]` also uses ``long``. Users can change
/// these values in Settings.
///
/// Values are sanitised at every entry point (initialiser, mutation and
/// `Codable` decoding):
/// - negative values become `0`;
/// - values above ``maximumDuration`` are clamped to it;
/// - non-finite values (`NaN`, `±infinity`) fall back to the standard value
///   for that field (`0.5` or `1.0`).
public struct PauseDefaults: Codable, Sendable, Hashable {
    /// Largest accepted pause duration, in seconds. Longer explicit pauses
    /// (`[pausa 120s]`) are still honoured by the parser; this cap only
    /// constrains the configurable defaults.
    public static let maximumDuration: TimeInterval = 60

    /// Duration in seconds of a short pause (a single `/`), clamped to
    /// `0...60` and never non-finite.
    public var short: TimeInterval {
        didSet { short = Self.sanitize(short, fallback: 0.5) }
    }
    /// Duration in seconds of a long pause (`//`, `[pausa]` or `[pause]`),
    /// clamped to `0...60` and never non-finite.
    public var long: TimeInterval {
        didSet { long = Self.sanitize(long, fallback: 1.0) }
    }

    private enum CodingKeys: String, CodingKey {
        case short
        case long
    }

    /// Creates a pair of pause durations.
    ///
    /// - Parameters:
    ///   - short: The short pause, in seconds. Defaults to `0.5` when omitted
    ///     or non-finite, clamps to `0...60`.
    ///   - long: The long pause, in seconds. Defaults to `1.0` when omitted or
    ///     non-finite, clamps to `0...60`.
    public init(short: TimeInterval = 0.5, long: TimeInterval = 1.0) {
        self.short = Self.sanitize(short, fallback: 0.5)
        self.long = Self.sanitize(long, fallback: 1.0)
    }

    /// Decodes persisted settings, sanitising values written by older or
    /// hand-edited files.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let short = try container.decodeIfPresent(TimeInterval.self, forKey: .short) ?? 0.5
        let long = try container.decodeIfPresent(TimeInterval.self, forKey: .long) ?? 1.0
        self.init(short: short, long: long)
    }

    /// Encodes the sanitised values.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(short, forKey: .short)
        try container.encode(long, forKey: .long)
    }

    /// The defaults described by the design document: 0.5 s and 1.0 s.
    public static let standard = PauseDefaults()

    private static func sanitize(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(0, value), maximumDuration)
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

/// The spoken word count and estimated duration of a script, from one parse.
///
/// Use `ScriptMarkup.estimate(_:wordsPerMinute:defaults:)` to produce it when a
/// view needs both numbers; this avoids parsing the whole script twice.
public struct MarkupEstimate: Sendable, Equatable {
    /// Spoken words only. Cues, pauses and delimiters never count.
    public let spokenWordCount: Int
    /// Spoken words at the requested rate plus all pause durations, in seconds.
    public let duration: TimeInterval

    public init(spokenWordCount: Int, duration: TimeInterval) {
        self.spokenWordCount = spokenWordCount
        self.duration = duration
    }
}

/// One piece of a parsed script, with UTF-16 ranges into the original text.
///
/// Tokens are ordered by their position in the source and never overlap. Every
/// character of the original string belongs to exactly one token, which makes
/// the ranges safe to feed to TextKit for highlighting.
///
/// ## Editor contract
/// - ``range`` is the token's whole extent.
/// - ``markerRanges`` are the syntax delimiters an editor should dim or hide.
/// - ``escapeRanges`` are the backslashes of `\*` / `\/`; dim the backslash
///   while keeping the escaped character visible, because ``text`` already has
///   the escape resolved.
///
/// An emphasis span that contains a pause or cue is split into several
/// `.emphasis` tokens: the first owns the opening delimiter, the last owns the
/// closing one, and the pause/cue tokens sit between them.
public struct MarkupToken: Sendable, Equatable {
    /// The semantic kind of a token.
    public enum Kind: Sendable, Equatable {
        /// Plain, spoken text. ``MarkupToken/text`` is the text itself.
        case text
        /// Text wrapped in `*` (``EmphasisLevel/emphasis``) or `**` (``EmphasisLevel/strong``).
        ///
        /// A span containing pauses or cues is emitted as several emphasis
        /// segments, each carrying its own text and any delimiters it owns.
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
    /// these are the opening and closing asterisks (split spans put the opening
    /// delimiter on the first segment and the closing delimiter on the last),
    /// for bracket pauses and cues the two square brackets, and for slash
    /// pauses the slash run itself.
    public let markerRanges: [NSRange]

    /// The backslash ranges of resolved `\*` / `\/` escapes, in UTF-16 code
    /// units into the original text.
    ///
    /// Only the backslash is included: the escaped character is literal
    /// content, remains visible and appears in ``text`` without its backslash.
    /// Empty for tokens without escapes (and for pause/cue tokens).
    public let escapeRanges: [NSRange]

    /// The semantic text of the token.
    ///
    /// For ``Kind/text`` this is the source text with `\*` and `\/` escapes
    /// resolved. For ``Kind/emphasis(_:)`` it is the emphasized content with
    /// escapes resolved; segments emitted around pauses/cues hold the text
    /// between those markers. Pauses and cues have no spoken text and use `""`.
    public let text: String

    /// Creates a token. Primarily useful for tests and previews.
    public init(
        kind: Kind,
        range: NSRange,
        markerRanges: [NSRange] = [],
        escapeRanges: [NSRange] = [],
        text: String = ""
    ) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.escapeRanges = escapeRanges
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
