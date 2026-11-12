import Foundation

/// One streaming recognizer update.
///
/// `SFSpeechRecognizer` reports partial results as a full transcript that may
/// revise previously recognized words. `text` is therefore the complete
/// hypothesis, not a delta. Timestamps must be monotonically increasing (for
/// example `ProcessInfo.processInfo.systemUptime`).
public struct SpeechHypothesis: Sendable, Equatable {
    public let text: String
    public let timestamp: TimeInterval
    public let isFinal: Bool

    public init(text: String, timestamp: TimeInterval, isFinal: Bool = false) {
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}

/// Tuning knobs for ``SpeechFollower``.
public struct SpeechFollowConfiguration: Sendable, Equatable, Codable {
    /// How many recognized words (from the end of the hypothesis) are used as
    /// alignment evidence.
    public var maximumRecognizedWords: Int = 14
    /// Below this confidence a candidate is not allowed to move the position.
    public var minimumConfidence: Double = 0.4
    /// Confidence required before a long forward jump is considered.
    public var strongConfidence: Double = 0.72
    /// Backward moves need more evidence than forward moves to avoid jitter.
    public var backwardConfidence: Double = 0.6
    /// Minimum number of matched words in an alignment.
    public var minimumMatchedWords: Int = 3
    /// Short suffixes get a lower confidence so a two-word coincidence cannot
    /// move the teleprompter. Five words of evidence saturate the factor.
    public var evidenceSaturationWords: Int = 5
    /// Hard limit: never go back more than this many sentences.
    public var maximumBackwardSentences: Int = 1
    /// Forward jumps up to this many sentences are accepted immediately.
    public var maximumForwardSentences: Int = 2
    /// A jump beyond `maximumForwardSentences` is allowed only up to this many
    /// sentences, and only after sustained strong matches.
    public var confirmedForwardSentences: Int = 5
    /// Number of consecutive distinct strong hypotheses required to confirm a
    /// long forward jump.
    public var forwardConfirmationUpdates: Int = 3
    /// Silence or sustained low confidence for this long puts the follower in
    /// the `lost` state so the UI can fall back to timed scrolling.
    public var lostAfterSeconds: TimeInterval = 3.0
    /// Scores this close are treated as a tie, where the nearest forward match
    /// wins (useful when the same phrase appears twice).
    public var preferAheadTolerance: Double = 0.05
    /// A long forward match must beat the best local match by this margin.
    public var farMustBeatNearBy: Double = 0.15

    public init() {}
}

/// Where the reader currently is in the script.
public struct SpeechFollowState: Sendable, Equatable {
    /// Index of the last script word considered spoken. `nil` for an empty script.
    public let tokenIndex: Int?
    /// UTF-16 offset of the start of that word in the script.
    public let utf16Offset: Int
    /// Sentence containing that word, if any.
    public let sentenceIndex: Int?
    /// Confidence in the reported position, `0...1`.
    public let confidence: Double
    /// True when confidence has been too low for too long (or recognition has
    /// gone silent). The UI should switch to timed scrolling but keep listening.
    public let isLost: Bool
    /// Number of matched words backing the last alignment.
    public let matchedWordCount: Int
    /// Timestamp of the last processed hypothesis or tick.
    public let timestamp: TimeInterval
}

/// Aligns full recognizer hypotheses with a script.
///
/// The follower is a pure value type: feed it hypotheses in order and it
/// returns the new position. It never performs I/O and is fully deterministic,
/// which makes the F9 rules directly testable.
public struct SpeechFollower: Sendable {
    public let script: TokenizedScript
    public let configuration: SpeechFollowConfiguration

    private var anchorTokenIndex: Int
    private var furthestSentenceIndex: Int
    private var lastConfidence: Double
    private var lastMatchedWordCount: Int
    private var lastTimestamp: TimeInterval
    private var sessionStartedAt: TimeInterval?
    private var lastHypothesisAt: TimeInterval?
    private var lowConfidenceSince: TimeInterval?
    private var lost: Bool
    private var lastHypothesisText: String?
    private var pendingForwardJump: PendingForwardJump?

    private struct PendingForwardJump: Sendable, Equatable {
        let sentenceIndex: Int
        let tokenIndex: Int
        let streak: Int
    }

    private struct Candidate: Sendable, Equatable {
        let tokenIndex: Int
        let sentenceIndex: Int
        let confidence: Double
        let matchedWordCount: Int
    }

    public init(
        script: TokenizedScript,
        configuration: SpeechFollowConfiguration = SpeechFollowConfiguration()
    ) {
        self.script = script
        self.configuration = configuration
        self.anchorTokenIndex = 0
        self.furthestSentenceIndex = 0
        self.lastConfidence = 0
        self.lastMatchedWordCount = 0
        self.lastTimestamp = 0
        self.lost = false
    }

    public var state: SpeechFollowState {
        let token = script.token(at: anchorTokenIndex)
        return SpeechFollowState(
            tokenIndex: token?.index,
            utf16Offset: token?.range.lowerBound ?? 0,
            sentenceIndex: token?.sentenceIndex,
            confidence: min(1, max(0, lastConfidence)),
            isLost: lost,
            matchedWordCount: lastMatchedWordCount,
            timestamp: lastTimestamp
        )
    }

    public mutating func reset(at timestamp: TimeInterval = 0) {
        anchorTokenIndex = 0
        furthestSentenceIndex = 0
        lastConfidence = 0
        lastMatchedWordCount = 0
        lastTimestamp = timestamp
        sessionStartedAt = nil
        lastHypothesisAt = nil
        lowConfidenceSince = nil
        lost = false
        lastHypothesisText = nil
        pendingForwardJump = nil
    }

    /// Feed one full partial transcript. Returns the resulting position.
    @discardableResult
    public mutating func process(_ hypothesis: SpeechHypothesis) -> SpeechFollowState {
        sessionStartedAt = sessionStartedAt ?? hypothesis.timestamp
        lastTimestamp = max(lastTimestamp, hypothesis.timestamp)
        lastHypothesisAt = hypothesis.timestamp

        // Identical hypotheses must not move the teleprompter or count as
        // sustained evidence for a long jump.
        if let lastHypothesisText, lastHypothesisText == hypothesis.text {
            updateLiveness(at: lastTimestamp)
            return state
        }
        lastHypothesisText = hypothesis.text

        let recognizedWords = ScriptTokenizer
            .normalizedWords(in: hypothesis.text, language: script.language)
        let tail = Array(recognizedWords.suffix(max(1, configuration.maximumRecognizedWords)))

        guard !script.isEmpty, !tail.isEmpty else {
            pendingForwardJump = nil
            lastConfidence = 0
            lastMatchedWordCount = 0
            updateLiveness(at: lastTimestamp)
            return state
        }

        let candidates = alignmentCandidates(for: tail)
        decide(candidates: candidates)
        updateLiveness(at: lastTimestamp)
        return state
    }

    @discardableResult
    public mutating func process(
        text: String,
        at timestamp: TimeInterval,
        isFinal: Bool = false
    ) -> SpeechFollowState {
        process(SpeechHypothesis(text: text, timestamp: timestamp, isFinal: isFinal))
    }

    /// Time-based liveness check. Call this periodically (for example 4 times
    /// per second) when no recognizer hypothesis arrives. If no hypothesis has
    /// arrived for `lostAfterSeconds`, the follower reports `lost` so the UI can
    /// scroll on its own.
    @discardableResult
    public mutating func tick(at timestamp: TimeInterval) -> SpeechFollowState {
        if sessionStartedAt == nil {
            sessionStartedAt = timestamp
        }
        lastTimestamp = max(lastTimestamp, timestamp)

        if let lastSignal = lastHypothesisAt ?? sessionStartedAt,
           timestamp - lastSignal >= configuration.lostAfterSeconds {
            lastConfidence = 0
            if lowConfidenceSince == nil {
                lowConfidenceSince = lastSignal
            }
        }
        updateLiveness(at: lastTimestamp)
        return state
    }

    /// Explicit silence signal, for callers that have an audio level meter and
    /// want to enter the fallback state without waiting for a stale hypothesis.
    @discardableResult
    public mutating func reportSilence(at timestamp: TimeInterval) -> SpeechFollowState {
        sessionStartedAt = sessionStartedAt ?? timestamp
        lastHypothesisAt = timestamp
        lastTimestamp = max(lastTimestamp, timestamp)
        lastConfidence = 0
        lastMatchedWordCount = 0
        updateLiveness(at: lastTimestamp)
        return state
    }

    // MARK: - Alignment

    private func alignmentCandidates(for tail: [String]) -> [Candidate] {
        guard !tail.isEmpty, !script.isEmpty else { return [] }

        let currentSentence = script.sentenceIndex(forTokenAt: anchorTokenIndex) ?? 0
        let firstSentence = max(0, currentSentence - configuration.maximumBackwardSentences)
        let lastSentence = min(
            script.sentenceCount - 1,
            currentSentence + configuration.confirmedForwardSentences
        )
        guard let windowRange = script.tokenRange(
            fromSentence: firstSentence,
            throughSentence: lastSentence
        ) else {
            return []
        }

        let windowTokens = Array(script.tokens[windowRange])
        guard !windowTokens.isEmpty else { return [] }

        var best: [Int: Candidate] = [:]
        let minimumSuffix = min(
            max(1, configuration.minimumMatchedWords),
            tail.count
        )

        for suffixLength in minimumSuffix...tail.count {
            let suffix = Array(tail.suffix(suffixLength))
            let evidence = min(
                1,
                Double(suffixLength) / Double(max(1, configuration.evidenceSaturationWords))
            )
            accumulateCandidates(
                suffix: suffix,
                scriptTokens: windowTokens,
                windowStart: windowRange.lowerBound,
                evidence: evidence,
                into: &best
            )
        }

        return Array(best.values)
    }

    private func accumulateCandidates(
        suffix: [String],
        scriptTokens: [ScriptToken],
        windowStart: Int,
        evidence: Double,
        into best: inout [Int: Candidate]
    ) {
        let n = suffix.count
        let m = scriptTokens.count
        guard n > 0, m > 0 else { return }

        let matchScore = 3.0
        let skipRecognizedPenalty = -1.5
        let skipScriptPenalty = -1.5

        // Semiglobal alignment: the script prefix is free (the speech tail can
        // start anywhere in the window), each recognized word is consumed, and
        // skipped words on either side pay a gap penalty.
        var scores = [[Double]](
            repeating: [Double](repeating: 0, count: m + 1),
            count: n + 1
        )
        var lastMatched = [[Int]](
            repeating: [Int](repeating: -1, count: m + 1),
            count: n + 1
        )
        var matchedCounts = [[Int]](
            repeating: [Int](repeating: 0, count: m + 1),
            count: n + 1
        )

        for i in 1...n {
            scores[i][0] = scores[i - 1][0] + skipRecognizedPenalty
            lastMatched[i][0] = lastMatched[i - 1][0]
            matchedCounts[i][0] = matchedCounts[i - 1][0]
        }

        for i in 1...n {
            let recognized = suffix[i - 1]
            for j in 1...m {
                let scriptWord = scriptTokens[j - 1].normalized
                let substitution = substitutionScore(recognized, scriptWord)
                let isMatch = substitution > 0

                let diagonalScore = scores[i - 1][j - 1] + substitution
                let diagonalLast = isMatch ? (j - 1) : lastMatched[i - 1][j - 1]
                let diagonalMatches = matchedCounts[i - 1][j - 1] + (isMatch ? 1 : 0)

                let upwardScore = scores[i - 1][j] + skipRecognizedPenalty
                let upwardLast = lastMatched[i - 1][j]
                let upwardMatches = matchedCounts[i - 1][j]

                let leftScore = scores[i][j - 1] + skipScriptPenalty
                let leftLast = lastMatched[i][j - 1]
                let leftMatches = matchedCounts[i][j - 1]

                // Prefer a real match on ties so the anchor advances.
                if diagonalScore >= upwardScore, diagonalScore >= leftScore {
                    scores[i][j] = diagonalScore
                    lastMatched[i][j] = diagonalLast
                    matchedCounts[i][j] = diagonalMatches
                } else if upwardScore >= leftScore {
                    scores[i][j] = upwardScore
                    lastMatched[i][j] = upwardLast
                    matchedCounts[i][j] = upwardMatches
                } else {
                    scores[i][j] = leftScore
                    lastMatched[i][j] = leftLast
                    matchedCounts[i][j] = leftMatches
                }
            }
        }

        for j in 0...m {
            let relativeAnchor = lastMatched[n][j]
            guard relativeAnchor >= 0 else { continue }
            guard matchedCounts[n][j] > 0 else { continue }

            let quality = max(0, scores[n][j]) / (matchScore * Double(n))
            let confidence = min(1, quality * evidence)
            let absoluteAnchor = windowStart + relativeAnchor
            guard script.tokens.indices.contains(absoluteAnchor) else { continue }

            let candidate = Candidate(
                tokenIndex: absoluteAnchor,
                sentenceIndex: script.tokens[absoluteAnchor].sentenceIndex,
                confidence: confidence,
                matchedWordCount: matchedCounts[n][j]
            )
            if let existing = best[absoluteAnchor], existing.confidence >= confidence {
                continue
            }
            best[absoluteAnchor] = candidate
        }
    }

    private func substitutionScore(_ recognized: String, _ scriptWord: String) -> Double {
        if recognized == scriptWord { return 3.0 }
        if areSimilar(recognized, scriptWord) { return 1.8 }
        return -1.2
    }

    private func areSimilar(_ lhs: String, _ rhs: String) -> Bool {
        let shorter = lhs.count <= rhs.count ? lhs : rhs
        let longer = lhs.count <= rhs.count ? rhs : lhs
        guard shorter.count >= 3, longer.count >= 4 else { return false }

        if longer.hasPrefix(shorter) || longer.hasSuffix(shorter) {
            return longer.count - shorter.count <= 2
        }
        if abs(lhs.count - rhs.count) <= 2,
           levenshteinDistance(lhs, rhs) <= 1 {
            return true
        }
        return false
    }

    private func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)
        if lhsCharacters.isEmpty { return rhsCharacters.count }
        if rhsCharacters.isEmpty { return lhsCharacters.count }

        var previous = Array(0...rhsCharacters.count)
        var current = [Int](repeating: 0, count: rhsCharacters.count + 1)

        for i in 1...lhsCharacters.count {
            current[0] = i
            for j in 1...rhsCharacters.count {
                let cost = lhsCharacters[i - 1] == rhsCharacters[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[rhsCharacters.count]
    }

    // MARK: - Position decision

    private mutating func decide(candidates: [Candidate]) {
        guard !candidates.isEmpty else {
            pendingForwardJump = nil
            lastConfidence = 0
            lastMatchedWordCount = 0
            return
        }

        let currentSentence = script.sentenceIndex(forTokenAt: anchorTokenIndex) ?? 0
        // The hard F9 rule is relative to the furthest sentence reached, so a
        // sequence of weak revisions cannot walk the teleprompter backwards.
        let firstAllowedSentence = max(
            0,
            furthestSentenceIndex - configuration.maximumBackwardSentences
        )
        let normalForwardSentence = currentSentence + configuration.maximumForwardSentences
        let confirmedForwardSentence = currentSentence + configuration.confirmedForwardSentences

        var nearCandidates: [Candidate] = []
        var farCandidates: [Candidate] = []
        var belowCandidates: [Candidate] = []

        for candidate in candidates {
            guard candidate.matchedWordCount >= configuration.minimumMatchedWords else {
                continue
            }
            guard candidate.sentenceIndex >= firstAllowedSentence,
                  candidate.sentenceIndex <= confirmedForwardSentence else {
                continue
            }

            if candidate.confidence < configuration.minimumConfidence {
                belowCandidates.append(candidate)
                continue
            }

            if candidate.tokenIndex < anchorTokenIndex,
               candidate.confidence < configuration.backwardConfidence {
                continue
            }

            if candidate.sentenceIndex <= normalForwardSentence {
                nearCandidates.append(candidate)
            } else if candidate.confidence >= configuration.strongConfidence {
                farCandidates.append(candidate)
            }
        }

        let nearBest = bestCandidate(in: nearCandidates)
        let farBest = bestCandidate(in: farCandidates)

        var accepted: Candidate?
        let farBeatsNear: Bool
        if let far = farBest {
            if let near = nearBest {
                farBeatsNear = far.confidence > near.confidence + configuration.farMustBeatNearBy
            } else {
                farBeatsNear = true
            }
        } else {
            farBeatsNear = false
        }

        if let far = farBest, farBeatsNear {
            let streak = notePendingForwardJump(far)
            if streak >= configuration.forwardConfirmationUpdates {
                accepted = far
                pendingForwardJump = nil
            }
        } else {
            pendingForwardJump = nil
            accepted = nearBest
        }

        if let accepted {
            if accepted.tokenIndex < anchorTokenIndex {
                pendingForwardJump = nil
            }
            anchorTokenIndex = accepted.tokenIndex
            furthestSentenceIndex = max(furthestSentenceIndex, accepted.sentenceIndex)
            lastConfidence = accepted.confidence
            lastMatchedWordCount = accepted.matchedWordCount
        } else if let far = farBest {
            // A strong long jump is pending confirmation. Report its
            // confidence so a short confirmation window does not look "lost".
            lastConfidence = far.confidence
            lastMatchedWordCount = far.matchedWordCount
        } else if let below = bestCandidate(in: belowCandidates) {
            lastConfidence = below.confidence
            lastMatchedWordCount = below.matchedWordCount
        } else {
            lastConfidence = 0
            lastMatchedWordCount = 0
        }
    }

    private mutating func notePendingForwardJump(_ candidate: Candidate) -> Int {
        let continues = pendingForwardJump.map {
            abs($0.sentenceIndex - candidate.sentenceIndex) <= 1
        } ?? false
        let streak = continues ? (pendingForwardJump?.streak ?? 0) + 1 : 1
        pendingForwardJump = PendingForwardJump(
            sentenceIndex: candidate.sentenceIndex,
            tokenIndex: candidate.tokenIndex,
            streak: streak
        )
        return streak
    }

    /// Picks the best candidate deterministically, independent of dictionary
    /// iteration order. Candidates within the "prefer ahead" tolerance of the
    /// highest confidence are considered a tie; among those, a forward match
    /// wins, then the nearest one. This is what makes a phrase that appears
    /// twice resolve to the nearest occurrence ahead.
    private func bestCandidate(in candidates: [Candidate]) -> Candidate? {
        guard let maximumConfidence = candidates.map(\.confidence).max() else {
            return nil
        }
        let tolerance = max(0, configuration.preferAheadTolerance)
        let competitive = candidates.filter { $0.confidence >= maximumConfidence - tolerance }
        return competitive.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return isPreferred(candidate, over: best) ? candidate : best
        }
    }

    private func isPreferred(_ candidate: Candidate, over current: Candidate) -> Bool {
        let candidateIsAhead = candidate.tokenIndex >= anchorTokenIndex
        let currentIsAhead = current.tokenIndex >= anchorTokenIndex
        if candidateIsAhead != currentIsAhead {
            return candidateIsAhead
        }

        let candidateDistance = abs(candidate.tokenIndex - anchorTokenIndex)
        let currentDistance = abs(current.tokenIndex - anchorTokenIndex)
        if candidateDistance != currentDistance {
            return candidateDistance < currentDistance
        }

        if abs(candidate.confidence - current.confidence) > 0.000_001 {
            return candidate.confidence > current.confidence
        }
        if candidate.matchedWordCount != current.matchedWordCount {
            return candidate.matchedWordCount > current.matchedWordCount
        }
        return candidate.tokenIndex < current.tokenIndex
    }

    private mutating func updateLiveness(at timestamp: TimeInterval) {
        if lastConfidence >= configuration.minimumConfidence {
            lowConfidenceSince = nil
            lost = false
            return
        }

        if lowConfidenceSince == nil {
            lowConfidenceSince = timestamp
        }
        if let since = lowConfidenceSince,
           timestamp - since >= configuration.lostAfterSeconds {
            lost = true
        }
    }
}
