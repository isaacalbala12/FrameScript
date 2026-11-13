import Foundation

/// Chooses where a re-hook belongs.
///
/// Two rules drive the choice:
/// - a scene longer than `longSceneThresholdSeconds` gets bridges around 40%
///   and 60% of its own spoken duration;
/// - a shorter scene still gets one when it covers the 40–60% window of the
///   whole video, at the sentence nearest the video midpoint.
///
/// Targets are first mapped to a spoken word offset using each sentence's real
/// start time, then the nearest sentence start is selected by word offset.
/// Keeping the comparison in words avoids the drift a duration fraction causes
/// when a scene contains pauses.
///
/// The anchor is always an existing sentence inside the scene, never the first
/// or last one. If the scene cannot provide a safe sentence, no position is
/// returned and the caller should not call the model at all.
public enum RehookPlanner {
    public static func positions(
        in text: String,
        wordsPerMinute: Double = 150,
        sceneStartSeconds: TimeInterval = 0,
        videoDurationSeconds: TimeInterval? = nil,
        longSceneThresholdSeconds: TimeInterval = HookLimits.defaultLongSceneSeconds,
        defaults: PauseDefaults = .standard
    ) -> [RehookPosition] {
        let sentences = RhythmSentenceSplitter.sentences(in: text)
        guard sentences.count >= 3 else { return [] }

        let totalWords = sentences.reduce(0) { $0 + $1.wordCount }
        guard totalWords > 0 else { return [] }

        let rate = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 150
        let duration = ScriptMarkup.estimateDuration(text, wordsPerMinute: rate, defaults: defaults)
        guard duration > 0 else { return [] }

        let starts = sentenceStarts(
            in: text,
            sentences: sentences,
            wordsPerMinute: rate,
            defaults: defaults
        )

        var targets: [(time: TimeInterval, reason: RehookPosition.Reason)] = []
        if duration > longSceneThresholdSeconds {
            targets = [
                (duration * 0.4, .longScene),
                (duration * 0.6, .longScene)
            ]
        } else if let videoDurationSeconds,
                  videoDurationSeconds.isFinite,
                  videoDurationSeconds > 0 {
            let sceneEnd = sceneStartSeconds + duration
            let windowStart = videoDurationSeconds * HookLimits.videoMidpointRange.lowerBound
            let windowEnd = videoDurationSeconds * HookLimits.videoMidpointRange.upperBound
            if sceneStartSeconds < windowEnd, sceneEnd > windowStart {
                let midpoint = videoDurationSeconds * 0.5
                let point = min(max(midpoint, sceneStartSeconds), sceneEnd)
                let localTime = min(max(point - sceneStartSeconds, 0), duration)
                targets = [(localTime, .videoMidpoint)]
            }
        }

        guard !targets.isEmpty else { return [] }

        var selected = Set<Int>()
        var positions: [RehookPosition] = []

        for target in targets {
            let targetWord = wordOffset(at: target.time, starts: starts, totalWords: totalWords)
            var best: (index: Int, distance: Double)?

            for start in starts {
                guard start.index > 0, start.index < sentences.count - 1 else { continue }
                let distance = abs(Double(start.wordOffset) - targetWord)
                if let current = best {
                    if distance < current.distance {
                        best = (start.index, distance)
                    }
                } else {
                    best = (start.index, distance)
                }
            }

            guard let index = best?.index, selected.insert(index).inserted else { continue }
            let sentence = sentences[index]
            positions.append(RehookPosition(
                anchor: sentence.text,
                anchorRange: sentence.range,
                sentenceIndex: index,
                reason: target.reason
            ))
        }

        return positions.sorted { $0.anchorRange.location < $1.anchorRange.location }
    }

    // MARK: - Word/time mapping

    private struct SentenceStart {
        let index: Int
        let wordOffset: Int
        let timeOffset: TimeInterval
    }

    private static func sentenceStarts(
        in text: String,
        sentences: [RhythmSentence],
        wordsPerMinute: Double,
        defaults: PauseDefaults
    ) -> [SentenceStart] {
        let nsText = text as NSString
        var starts: [SentenceStart] = []
        var wordOffset = 0
        starts.reserveCapacity(sentences.count)

        for (index, sentence) in sentences.enumerated() {
            let prefix = nsText.substring(to: min(sentence.range.location, nsText.length))
            let timeOffset = ScriptMarkup.estimateDuration(
                prefix,
                wordsPerMinute: wordsPerMinute,
                defaults: defaults
            )
            starts.append(SentenceStart(
                index: index,
                wordOffset: wordOffset,
                timeOffset: timeOffset
            ))
            wordOffset += sentence.wordCount
        }
        return starts
    }

    /// Interpolates a word offset for a real spoken time. With no pauses this
    /// is exactly `time / duration * totalWords`; pauses are counted in the
    /// time axis and do not move the word target.
    private static func wordOffset(
        at time: TimeInterval,
        starts: [SentenceStart],
        totalWords: Int
    ) -> Double {
        guard let first = starts.first, let last = starts.last else { return 0 }
        if time <= first.timeOffset { return Double(first.wordOffset) }
        if time >= last.timeOffset { return Double(totalWords) }

        for index in 1..<starts.count {
            let previous = starts[index - 1]
            let current = starts[index]
            guard time <= current.timeOffset else { continue }
            let span = current.timeOffset - previous.timeOffset
            guard span > 0 else { return Double(current.wordOffset) }
            let ratio = (time - previous.timeOffset) / span
            return Double(previous.wordOffset)
                + Double(current.wordOffset - previous.wordOffset) * ratio
        }
        return Double(totalWords)
    }
}
