import Foundation

/// Chooses where a re-hook belongs.
///
/// Two rules drive the choice:
/// - a scene longer than `longSceneThresholdSeconds` gets bridges around 40%
///   and 60% of its own spoken duration;
/// - a shorter scene still gets one when it covers the 40–60% window of the
///   whole video, at the sentence nearest the video midpoint.
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

        var targets: [(fraction: Double, reason: RehookPosition.Reason)] = []
        if duration > longSceneThresholdSeconds {
            targets = [(0.4, .longScene), (0.6, .longScene)]
        } else if let videoDurationSeconds,
                  videoDurationSeconds.isFinite,
                  videoDurationSeconds > 0 {
            let sceneEnd = sceneStartSeconds + duration
            let windowStart = videoDurationSeconds * HookLimits.videoMidpointRange.lowerBound
            let windowEnd = videoDurationSeconds * HookLimits.videoMidpointRange.upperBound
            if sceneStartSeconds < windowEnd, sceneEnd > windowStart {
                let midpoint = videoDurationSeconds * 0.5
                let point = min(max(midpoint, sceneStartSeconds), sceneEnd)
                let fraction = (point - sceneStartSeconds) / duration
                targets = [(min(max(fraction, 0.25), 0.75), .videoMidpoint)]
            }
        }

        guard !targets.isEmpty else { return [] }

        var selected = Set<Int>()
        var positions: [RehookPosition] = []

        for target in targets {
            let targetWord = Double(totalWords) * target.fraction
            var cumulative = 0
            var best: (index: Int, distance: Double)?

            for (index, sentence) in sentences.enumerated() {
                defer { cumulative += sentence.wordCount }
                guard index > 0, index < sentences.count - 1 else { continue }
                let distance = abs(Double(cumulative) - targetWord)
                if let current = best {
                    if distance < current.distance {
                        best = (index, distance)
                    }
                } else {
                    best = (index, distance)
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
}
