import Foundation

/// Maps a UTF-16 text offset to its estimated time on the timeline.
///
/// Production anchors (B-roll, editing notes, rhythm warnings) live in the
/// script as UTF-16 ranges. To place a marker in Resolve, the pack needs the
/// moment that text is spoken. This uses the same parser and pace as
/// `ScriptMarkup.estimate`, so an anchor at the end of a scene lands on the
/// scene's estimated duration instead of drifting.
public enum TimelineAnchoring {
    /// Seconds from the start of `text` to `utf16Offset`.
    ///
    /// Tokens that end before the offset contribute their full duration (word
    /// time plus any pause). A token cut by the offset contributes only the
    /// words in the visible prefix. Cues never count, exactly as in
    /// `ScriptMarkup.estimate`.
    public static func seconds(
        text: String,
        utf16Offset: Int,
        wordsPerMinute: Double,
        defaults: PauseDefaults = .standard
    ) -> TimeInterval {
        guard utf16Offset > 0 else { return 0 }
        let nsText = text as NSString
        let limit = min(utf16Offset, nsText.length)
        guard limit > 0 else { return 0 }

        let pace = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 0
        var seconds: TimeInterval = 0

        for token in ScriptMarkup.parse(text, defaults: defaults) {
            let start = token.range.location
            let end = NSMaxRange(token.range)

            if end <= limit {
                switch token.kind {
                case .pause(let duration, _):
                    seconds += max(0, duration)
                case .text, .emphasis:
                    seconds += speakingSeconds(token.text, pace: pace)
                case .cue:
                    break
                }
            } else if start < limit {
                switch token.kind {
                case .text, .emphasis:
                    let prefix = nsText.substring(
                        with: NSRange(location: start, length: limit - start)
                    )
                    seconds += speakingSeconds(prefix, pace: pace)
                case .pause, .cue:
                    // A pause that has not closed yet has not happened, and
                    // cue text is never spoken.
                    break
                }
                break
            } else {
                break
            }
        }

        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Batch version of ``seconds(text:utf16Offset:wordsPerMinute:defaults:)``.
    ///
    /// The scene is parsed once and every offset is answered from the same
    /// token walk, so a scene with dozens of anchors costs one parse instead of
    /// one parse per cue. Results are returned in the caller's order and match
    /// the single-offset API exactly.
    public static func seconds(
        text: String,
        utf16Offsets: [Int],
        wordsPerMinute: Double,
        defaults: PauseDefaults = .standard
    ) -> [TimeInterval] {
        guard !utf16Offsets.isEmpty else { return [] }
        let nsText = text as NSString
        let pace = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 0
        let tokens = ScriptMarkup.parse(text, defaults: defaults)

        struct Request {
            let index: Int
            let limit: Int
        }
        let requests = utf16Offsets.enumerated()
            .map { Request(index: $0.offset, limit: min(max(0, $0.element), nsText.length)) }
            .sorted { $0.limit < $1.limit }

        var results = Array(repeating: TimeInterval(0), count: utf16Offsets.count)
        var tokenIndex = 0
        var secondsBeforeToken: TimeInterval = 0

        for request in requests {
            guard request.limit > 0 else { continue }
            while tokenIndex < tokens.count {
                let token = tokens[tokenIndex]
                let start = token.range.location
                let end = NSMaxRange(token.range)

                if end <= request.limit {
                    switch token.kind {
                    case .pause(let duration, _):
                        secondsBeforeToken += max(0, duration)
                    case .text, .emphasis:
                        secondsBeforeToken += speakingSeconds(token.text, pace: pace)
                    case .cue:
                        break
                    }
                    tokenIndex += 1
                    continue
                }

                if start < request.limit {
                    var value = secondsBeforeToken
                    switch token.kind {
                    case .text, .emphasis:
                        let prefix = nsText.substring(
                            with: NSRange(location: start, length: request.limit - start)
                        )
                        value += speakingSeconds(prefix, pace: pace)
                    case .pause, .cue:
                        break
                    }
                    results[request.index] = value
                } else {
                    results[request.index] = secondsBeforeToken
                }
                break
            }
            if tokenIndex >= tokens.count {
                results[request.index] = secondsBeforeToken
            }
        }

        return results.map { $0.isFinite ? max(0, $0) : 0 }
    }

    private static func speakingSeconds(_ text: String, pace: Double) -> TimeInterval {
        guard pace > 0 else { return 0 }
        return Double(ScriptMarkup.spokenWordCount(text)) / pace * 60
    }
}
