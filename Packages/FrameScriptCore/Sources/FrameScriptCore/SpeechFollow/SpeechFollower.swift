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
    /// Recognizer task generation, when known. `SFSpeechRecognizer` tasks are
    /// replaced roughly once a minute and the new transcript starts from empty;
    /// a changed value tells the follower to keep its position and ignore
    /// backward-only evidence until the new segment moves forward.
    public let segment: Int?

    public init(
        text: String,
        timestamp: TimeInterval,
        isFinal: Bool = false,
        segment: Int? = nil
    ) {
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
        self.segment = segment
    }
}

/// Tuning knobs for ``SpeechFollower``.
public struct SpeechFollowConfiguration: Sendable, Equatable, Codable {
    /// How many recognized words (from the end of the hypothesis) are used as
    /// alignment evidence.
    public var maximumRecognizedWords: Int = 14
    /// Below this confidence a candidate is not allowed to move the position.
    public var minimumConfidence: Double = 0.4
    /// Confidence required before a long non-contiguous forward jump is
    /// considered.
    public var strongConfidence: Double = 0.72
    /// Backward moves need much stronger evidence than forward moves. A short
    /// revision of three or four words must never drag the teleprompter back.
    public var backwardConfidence: Double = 0.85
    /// Minimum number of matched words in an alignment.
    public var minimumMatchedWords: Int = 3
    /// Minimum matched words for a backward move.
    public var minimumBackwardMatchedWords: Int = 5
    /// Short suffixes get a lower confidence so a two-word coincidence cannot
    /// move the teleprompter. Five words of evidence saturate the factor.
    public var evidenceSaturationWords: Int = 5
    /// Hard limit: never go back more than this many sentences.
    public var maximumBackwardSentences: Int = 1
    /// Forward jumps up to this many sentences are accepted immediately when
    /// they are not a contiguous continuation of the current reading path.
    public var maximumForwardSentences: Int = 2
    /// A non-contiguous jump beyond `maximumForwardSentences` is allowed up to
    /// this many sentences, and only after sustained strong matches.
    public var confirmedForwardSentences: Int = 5
    /// Deep recovery search limit. Candidates beyond `confirmedForwardSentences`
    /// can still win when re-acquiring, or when they beat the local match by at
    /// least two matched words; the actual move still requires sustained strong
    /// evidence.
    public var recoveryForwardSentences: Int = 12
    /// How long confidence must be low before deep recovery candidates can
    /// override a strong local match without the two-word coverage advantage.
    public var reacquisitionDelay: TimeInterval = 1.0
    /// Alignment window limits in tokens, independent of sentence length. They
    /// keep per-update work bounded on very long sentences.
    public var maximumBackwardTokens: Int = 48
    public var maximumForwardTokens: Int = 320
    /// A candidate whose alignment starts this close after the current token is
    /// a contiguous continuation, i.e. normal reading, not a jump.
    public var continuationStartToleranceTokens: Int = 2
    /// A continuation may overlap this many already-read words.
    public var continuationMaximumOverlapTokens: Int = 5
    /// A continuation may skip at most this many script words (recognizer or
    /// speaker dropped a word); more than this is a jump, not reading.
    public var continuationMaximumGaps: Int = 2
    /// Number of consecutive distinct strong hypotheses required to confirm a
    /// long non-contiguous jump.
    public var forwardConfirmationUpdates: Int = 3
    /// Silence or sustained low confidence for this long puts the follower in
    /// the `lost` state so the UI can fall back to timed scrolling.
    public var lostAfterSeconds: TimeInterval = 3.0
    /// Scores this close are treated as a tie, where coverage and then the
    /// nearest forward match decide (useful when a phrase repeats).
    public var preferAheadTolerance: Double = 0.05
    /// A long forward match must beat the best local match by this margin, or
    /// have at least two more matched words, to be considered a jump.
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
    private var currentSegment: Int?
    private var segmentRestartNeedsForwardProgress: Bool

    private struct PendingForwardJump: Sendable, Equatable {
        let sentenceIndex: Int
        let tokenIndex: Int
        let streak: Int
    }

    private struct Candidate: Sendable, Equatable {
        let tokenIndex: Int
        let firstTokenIndex: Int
        let sentenceIndex: Int
        let confidence: Double
        let matchedWordCount: Int
        let scriptGapCount: Int
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
        self.currentSegment = nil
        self.segmentRestartNeedsForwardProgress = false
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
        currentSegment = nil
        segmentRestartNeedsForwardProgress = false
    }

    /// Move the anchor to a script word without replaying the script.
    ///
    /// The teleprompter uses this when voice following starts mid-scene and
    /// when live script edits re-tokenize the document: the new follower keeps
    /// the reader's word instead of starting again at the top of the script.
    public mutating func seek(toToken index: Int, at timestamp: TimeInterval? = nil) {
        guard !script.isEmpty else {
            reset(at: timestamp ?? lastTimestamp)
            return
        }
        let clamped = min(max(0, index), script.tokens.count - 1)
        anchorTokenIndex = clamped
        furthestSentenceIndex = script.tokens[clamped].sentenceIndex
        lastConfidence = 0
        lastMatchedWordCount = 0
        lastHypothesisText = nil
        pendingForwardJump = nil
        lowConfidenceSince = nil
        lost = false
        segmentRestartNeedsForwardProgress = false
        if let timestamp {
            lastTimestamp = max(lastTimestamp, timestamp)
        }
    }

    /// Feed one full partial transcript. Returns the resulting position.
    @discardableResult
    public mutating func process(_ hypothesis: SpeechHypothesis) -> SpeechFollowState {
        sessionStartedAt = sessionStartedAt ?? hypothesis.timestamp
        lastTimestamp = max(lastTimestamp, hypothesis.timestamp)
        lastHypothesisAt = hypothesis.timestamp

        if let segment = hypothesis.segment {
            if let currentSegment, currentSegment != segment {
                beginRecognitionSegment(at: hypothesis.timestamp)
            }
            currentSegment = segment
        }

        // Identical hypotheses must not move the teleprompter or count as
        // sustained evidence for a long jump.
        if let lastHypothesisText, lastHypothesisText == hypothesis.text {
            updateLiveness(at: lastTimestamp)
            return state
        }
        lastHypothesisText = hypothesis.text

        guard !script.isEmpty else {
            pendingForwardJump = nil
            lastConfidence = 0
            lastMatchedWordCount = 0
            updateLiveness(at: lastTimestamp)
            return state
        }

        let recognizedWords = ScriptTokenizer
            .normalizedWords(in: hypothesis.text, language: script.language)
        let tail = Array(recognizedWords.suffix(max(1, configuration.maximumRecognizedWords)))

        guard !tail.isEmpty else {
            // An empty partial right after a recognizer restart is not evidence
            // against the current position; keep it and let liveness decide.
            pendingForwardJump = nil
            lastConfidence = 0
            lastMatchedWordCount = 0
            updateLiveness(at: lastTimestamp)
            return state
        }

        let candidates = alignmentCandidates(for: tail)
        decide(candidates: candidates, at: lastTimestamp)
        updateLiveness(at: lastTimestamp)
        return state
    }

    @discardableResult
    public mutating func process(
        text: String,
        at timestamp: TimeInterval,
        isFinal: Bool = false,
        segment: Int? = nil
    ) -> SpeechFollowState {
        process(
            SpeechHypothesis(
                text: text,
                timestamp: timestamp,
                isFinal: isFinal,
                segment: segment
            )
        )
    }

    /// Convenience for the live pipeline: forwards the event's segment so a
    /// recognizer task replacement keeps the current position.
    @discardableResult
    public mutating func process(_ event: SpeechRecognitionEvent) -> SpeechFollowState {
        process(
            SpeechHypothesis(
                text: event.text,
                timestamp: event.timestamp,
                isFinal: event.isFinal,
                segment: event.segment
            )
        )
    }

    /// Tell the follower that the recognizer replaced its task and the new
    /// transcript starts from empty (see `SpeechRecognitionEvent.segment`).
    ///
    /// The current position is kept. Until the new segment moves forward, a
    /// short backward-looking partial cannot drag the teleprompter back; a
    /// contiguous continuation advances normally.
    @discardableResult
    public mutating func beginRecognitionSegment(at timestamp: TimeInterval) -> SpeechFollowState {
        lastTimestamp = max(lastTimestamp, timestamp)
        segmentRestartNeedsForwardProgress = true
        lastHypothesisText = nil
        pendingForwardJump = nil
        return state
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
        // Search the full recovery range even when not yet flagged as lost: a
        // repeated opening phrase can keep local confidence high while the
        // reader has actually skipped ahead. The move still requires sustained
        // strong evidence in `decide`.
        let lastSentence = min(
            script.sentenceCount - 1,
            currentSentence + max(
                configuration.confirmedForwardSentences,
                configuration.recoveryForwardSentences
            )
        )
        guard let sentenceRange = script.tokenRange(
            fromSentence: firstSentence,
            throughSentence: lastSentence
        ) else {
            return []
        }

        // Token caps keep the DP bounded even when a "sentence" is a 5,000-word
        // paragraph. They are much wider than any natural 10-15 word update.
        let start = max(sentenceRange.lowerBound, anchorTokenIndex - configuration.maximumBackwardTokens)
        let end = min(
            sentenceRange.upperBound,
            anchorTokenIndex + configuration.maximumForwardTokens + 1
        )
        guard start < end else { return [] }

        let windowRange = start..<end
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
        var firstMatched = [[Int]](
            repeating: [Int](repeating: -1, count: m + 1),
            count: n + 1
        )
        var matchedCounts = [[Int]](
            repeating: [Int](repeating: 0, count: m + 1),
            count: n + 1
        )
        var scriptGaps = [[Int]](
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
                let diagonalFirst: Int
                if isMatch {
                    let previousFirst = firstMatched[i - 1][j - 1]
                    diagonalFirst = previousFirst >= 0 ? previousFirst : (j - 1)
                } else {
                    diagonalFirst = firstMatched[i - 1][j - 1]
                }
                let diagonalMatches = matchedCounts[i - 1][j - 1] + (isMatch ? 1 : 0)

                let upwardScore = scores[i - 1][j] + skipRecognizedPenalty
                let upwardLast = lastMatched[i - 1][j]
                let upwardFirst = firstMatched[i - 1][j]
                let upwardMatches = matchedCounts[i - 1][j]
                let upwardGaps = scriptGaps[i - 1][j]

                let leftScore = scores[i][j - 1] + skipScriptPenalty
                let leftLast = lastMatched[i][j - 1]
                let leftFirst = firstMatched[i][j - 1]
                let leftMatches = matchedCounts[i][j - 1]
                let leftGaps = scriptGaps[i][j - 1]

                // Prefer a real match on ties so the anchor advances.
                if diagonalScore >= upwardScore, diagonalScore >= leftScore {
                    scores[i][j] = diagonalScore
                    lastMatched[i][j] = diagonalLast
                    firstMatched[i][j] = diagonalFirst
                    matchedCounts[i][j] = diagonalMatches
                    scriptGaps[i][j] = scriptGaps[i - 1][j - 1]
                } else if upwardScore >= leftScore {
                    scores[i][j] = upwardScore
                    lastMatched[i][j] = upwardLast
                    firstMatched[i][j] = upwardFirst
                    matchedCounts[i][j] = upwardMatches
                    scriptGaps[i][j] = upwardGaps
                } else {
                    scores[i][j] = leftScore
                    lastMatched[i][j] = leftLast
                    firstMatched[i][j] = leftFirst
                    matchedCounts[i][j] = leftMatches
                    scriptGaps[i][j] = leftGaps + 1
                }
            }
        }

        for j in 0...m {
            let relativeAnchor = lastMatched[n][j]
            let relativeFirst = firstMatched[n][j]
            guard relativeAnchor >= 0, relativeFirst >= 0 else { continue }
            guard matchedCounts[n][j] > 0 else { continue }

            let quality = max(0, scores[n][j]) / (matchScore * Double(n))
            let confidence = min(1, quality * evidence)
            let absoluteAnchor = windowStart + relativeAnchor
            let absoluteFirst = windowStart + relativeFirst
            guard script.tokens.indices.contains(absoluteAnchor),
                  script.tokens.indices.contains(absoluteFirst) else { continue }

            let candidate = Candidate(
                tokenIndex: absoluteAnchor,
                firstTokenIndex: absoluteFirst,
                sentenceIndex: script.tokens[absoluteAnchor].sentenceIndex,
                confidence: confidence,
                matchedWordCount: matchedCounts[n][j],
                scriptGapCount: scriptGaps[n][j]
            )
            if let existing = best[absoluteAnchor] {
                let existingIsContinuation = looksLikeContinuation(existing)
                let candidateIsContinuation = looksLikeContinuation(candidate)
                if existingIsContinuation != candidateIsContinuation {
                    if candidateIsContinuation {
                        best[absoluteAnchor] = candidate
                    }
                    continue
                }
                if existing.confidence > confidence { continue }
                if abs(existing.confidence - confidence) <= 0.000_001,
                   existing.matchedWordCount >= candidate.matchedWordCount {
                    continue
                }
            }
            best[absoluteAnchor] = candidate
        }
    }

    private func looksLikeContinuation(_ candidate: Candidate) -> Bool {
        guard candidate.tokenIndex > anchorTokenIndex else { return false }
        return candidate.firstTokenIndex
                <= anchorTokenIndex + configuration.continuationStartToleranceTokens
            && candidate.firstTokenIndex
                >= anchorTokenIndex - configuration.continuationMaximumOverlapTokens
            && candidate.scriptGapCount <= configuration.continuationMaximumGaps
    }

    private func substitutionScore(_ recognized: String, _ scriptWord: String) -> Double {
        if recognized == scriptWord { return 3.0 }
        if areSimilar(recognized, scriptWord) { return 1.8 }
        return -1.2
    }

    private func areSimilar(_ lhs: String, _ rhs: String) -> Bool {
        // Numbers must match exactly: "linea1" and "linea9", or "2025" and
        // "2026", are different words, not spelling corrections.
        if lhs.contains(where: \.isNumber) || rhs.contains(where: \.isNumber) {
            return false
        }

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

    private mutating func decide(candidates: [Candidate], at timestamp: TimeInterval) {
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
        let recoveryForwardSentence = currentSentence + configuration.recoveryForwardSentences
        let reacquiring = isReacquiring(at: timestamp)
        let backwardTokenFloor = anchorTokenIndex - configuration.maximumBackwardTokens

        var continuationCandidates: [Candidate] = []
        var nearCandidates: [Candidate] = []
        var farCandidates: [Candidate] = []
        var deepFarCandidates: [Candidate] = []

        for candidate in candidates {
            guard candidate.matchedWordCount >= configuration.minimumMatchedWords else {
                continue
            }
            guard candidate.tokenIndex >= backwardTokenFloor else { continue }
            guard candidate.sentenceIndex >= firstAllowedSentence else { continue }

            let isForward = candidate.tokenIndex > anchorTokenIndex
            let startsNear = candidate.firstTokenIndex
                <= anchorTokenIndex + configuration.continuationStartToleranceTokens
            let overlapsReasonable = candidate.firstTokenIndex
                >= anchorTokenIndex - configuration.continuationMaximumOverlapTokens
            let isContiguous = candidate.scriptGapCount <= configuration.continuationMaximumGaps
            let isContinuation = isForward && startsNear && overlapsReasonable && isContiguous

            if isContinuation {
                // Matching the text that comes right after the current word is
                // normal reading, not a jump. It may span several sentences
                // when a 10-15 word update lands after a pause.
                if candidate.confidence < configuration.minimumConfidence {
                    continue
                }
                continuationCandidates.append(candidate)
                continue
            }

            guard candidate.sentenceIndex <= recoveryForwardSentence else { continue }

            if candidate.confidence < configuration.minimumConfidence {
                continue
            }

            if candidate.tokenIndex < anchorTokenIndex {
                // After a recognizer restart the new transcript starts from
                // empty. Backward-looking partials must not move the position.
                let canMoveBack = !segmentRestartNeedsForwardProgress
                    && candidate.confidence >= configuration.backwardConfidence
                    && candidate.matchedWordCount >= configuration.minimumBackwardMatchedWords
                if !canMoveBack {
                    continue
                }
            }

            // A non-contiguous jump over more than one sentence needs strong
            // evidence. A three-word 0.6-confidence coincidence is not enough.
            let sentencesAhead = candidate.sentenceIndex - currentSentence
            if sentencesAhead > 1,
               candidate.confidence < configuration.strongConfidence {
                continue
            }

            if candidate.sentenceIndex <= normalForwardSentence {
                nearCandidates.append(candidate)
            } else if candidate.confidence >= configuration.strongConfidence {
                if candidate.sentenceIndex <= confirmedForwardSentence {
                    farCandidates.append(candidate)
                } else {
                    deepFarCandidates.append(candidate)
                }
            }
        }

        if let continuation = bestContinuation(in: continuationCandidates) {
            pendingForwardJump = nil
            accept(continuation)
            return
        }

        let nearBest = bestCandidate(in: nearCandidates)
        let eligibleDeep = deepFarCandidates.filter { candidate in
            reacquiring
                || nearBest == nil
                || candidate.matchedWordCount >= (nearBest?.matchedWordCount ?? 0) + 2
        }
        let farBest = bestCandidate(in: farCandidates + eligibleDeep)

        let farBeatsNear: Bool
        if let far = farBest {
            if let near = nearBest {
                farBeatsNear = far.confidence > near.confidence + configuration.farMustBeatNearBy
                    || far.matchedWordCount >= near.matchedWordCount + 2
            } else {
                farBeatsNear = true
            }
        } else {
            farBeatsNear = false
        }

        if let far = farBest, farBeatsNear {
            let streak = notePendingForwardJump(far)
            if streak >= configuration.forwardConfirmationUpdates {
                pendingForwardJump = nil
                accept(far)
                return
            }
        } else {
            pendingForwardJump = nil
            if let near = nearBest {
                accept(near)
                return
            }
        }

        // No accepted move. Report zero confidence: an unconfirmed far jump or
        // a rejected backward revision must not look trustworthy while the
        // teleprompter is actually stuck.
        lastConfidence = 0
        lastMatchedWordCount = 0
    }

    private mutating func accept(_ candidate: Candidate) {
        let movedForward = candidate.tokenIndex > anchorTokenIndex
        if candidate.tokenIndex < anchorTokenIndex {
            pendingForwardJump = nil
        }
        anchorTokenIndex = candidate.tokenIndex
        furthestSentenceIndex = max(furthestSentenceIndex, candidate.sentenceIndex)
        lastConfidence = candidate.confidence
        lastMatchedWordCount = candidate.matchedWordCount
        if movedForward {
            segmentRestartNeedsForwardProgress = false
        }
    }

    private func isReacquiring(at timestamp: TimeInterval) -> Bool {
        if lost { return true }
        guard let since = lowConfidenceSince else { return false }
        return timestamp - since >= configuration.reacquisitionDelay
    }

    private func bestContinuation(in candidates: [Candidate]) -> Candidate? {
        candidates.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            if candidate.matchedWordCount != best.matchedWordCount {
                return candidate.matchedWordCount > best.matchedWordCount ? candidate : best
            }
            if candidate.tokenIndex != best.tokenIndex {
                return candidate.tokenIndex > best.tokenIndex ? candidate : best
            }
            if abs(candidate.confidence - best.confidence) > 0.000_001 {
                return candidate.confidence > best.confidence ? candidate : best
            }
            return candidate.firstTokenIndex < best.firstTokenIndex ? candidate : best
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

        // Equal-confidence longer coverage is the phrase that continues the
        // current reading path, even when a shorter local match is closer.
        if candidate.matchedWordCount != current.matchedWordCount {
            return candidate.matchedWordCount > current.matchedWordCount
        }

        let candidateDistance = abs(candidate.tokenIndex - anchorTokenIndex)
        let currentDistance = abs(current.tokenIndex - anchorTokenIndex)
        if candidateDistance != currentDistance {
            return candidateDistance < currentDistance
        }

        if abs(candidate.confidence - current.confidence) > 0.000_001 {
            return candidate.confidence > current.confidence
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
