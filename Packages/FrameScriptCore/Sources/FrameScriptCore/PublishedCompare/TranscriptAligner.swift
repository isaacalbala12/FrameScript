import Foundation

/// One scene of the written script, in order.
public struct SceneScript: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public enum AlignmentDeviationKind: String, Sendable, Equatable, Codable {
    case inserted
    case removed
}

/// A long run of words that exists only in the published video (`inserted`) or
/// only in the script (`removed`).
public struct AlignmentDeviation: Sendable, Equatable, Hashable, Codable {
    public var kind: AlignmentDeviationKind
    public var text: String
    public var wordCount: Int
    public var start: TimeInterval?
    public var end: TimeInterval?

    public init(
        kind: AlignmentDeviationKind,
        text: String,
        wordCount: Int,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.kind = kind
        self.text = text
        self.wordCount = wordCount
        self.start = start
        self.end = end
    }
}

public struct SceneAlignment: Sendable, Equatable, Identifiable, Codable {
    public var sceneID: String
    public var start: TimeInterval?
    public var end: TimeInterval?
    /// Number of normalized script tokens (contractions can count twice).
    public var scriptWordCount: Int
    public var matchedWordCount: Int
    public var addedWordCount: Int
    public var removedWordCount: Int
    /// Matched script words divided by script words. 0…1.
    public var coverage: Double
    /// True when the timing was interpolated because the scene was cut, or
    /// when no script word in the scene matched the transcript.
    public var timingIsEstimated: Bool
    public var deviations: [AlignmentDeviation]

    public var id: String { sceneID }

    public init(
        sceneID: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil,
        scriptWordCount: Int,
        matchedWordCount: Int,
        addedWordCount: Int,
        removedWordCount: Int,
        coverage: Double,
        timingIsEstimated: Bool,
        deviations: [AlignmentDeviation] = []
    ) {
        self.sceneID = sceneID
        self.start = start
        self.end = end
        self.scriptWordCount = scriptWordCount
        self.matchedWordCount = matchedWordCount
        self.addedWordCount = addedWordCount
        self.removedWordCount = removedWordCount
        self.coverage = coverage
        self.timingIsEstimated = timingIsEstimated
        self.deviations = deviations
    }

    public var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return max(0, end - start)
    }
}

public struct TranscriptAlignment: Sendable, Equatable, Codable {
    public var scenes: [SceneAlignment]
    public var totalScriptWords: Int
    public var totalMatchedWords: Int
    public var totalAddedWords: Int
    public var totalRemovedWords: Int
    public var coverage: Double
    public var transcriptDuration: TimeInterval
    public var transcriptWordCount: Int

    public init(
        scenes: [SceneAlignment],
        totalScriptWords: Int,
        totalMatchedWords: Int,
        totalAddedWords: Int,
        totalRemovedWords: Int,
        coverage: Double,
        transcriptDuration: TimeInterval,
        transcriptWordCount: Int
    ) {
        self.scenes = scenes
        self.totalScriptWords = totalScriptWords
        self.totalMatchedWords = totalMatchedWords
        self.totalAddedWords = totalAddedWords
        self.totalRemovedWords = totalRemovedWords
        self.coverage = coverage
        self.transcriptDuration = transcriptDuration
        self.transcriptWordCount = transcriptWordCount
    }
}

/// Aligns a published video's transcript to the written scenes with a global
/// sequence alignment. It tolerates ad-libs (insertions), cuts (deletions) and
/// substitutions without drifting scene boundaries.
public struct TranscriptAligner: Sendable {
    /// Minimum number of consecutive words for a span to be reported as a
    /// notable deviation.
    public var minimumDeviationWordCount: Int
    /// Largest dynamic-programming region before the aligner switches to
    /// anchor-based splitting. 250k cells is roughly 1 MB of traceback state.
    public var maximumDynamicProgrammingCells: Int

    public init(
        minimumDeviationWordCount: Int = 4,
        maximumDynamicProgrammingCells: Int = 250_000
    ) {
        self.minimumDeviationWordCount = minimumDeviationWordCount
        self.maximumDynamicProgrammingCells = maximumDynamicProgrammingCells
    }

    public func align(
        scenes: [SceneScript],
        transcript: [SubtitleSegment]
    ) -> TranscriptAlignment {
        let scriptTokens = Self.makeScriptTokens(from: scenes)
        let transcriptTokens = Self.makeTranscriptTokens(from: transcript)
        var pairs = Self.computePairs(
            script: scriptTokens,
            transcript: transcriptTokens,
            maximumCells: maximumDynamicProgrammingCells
        )

        let transcriptDuration = transcriptTokens.map(\.end).max() ?? 0
        guard !scenes.isEmpty else {
            return TranscriptAlignment(
                scenes: [],
                totalScriptWords: scriptTokens.count,
                totalMatchedWords: pairs.count,
                totalAddedWords: max(0, transcriptTokens.count - pairs.count),
                totalRemovedWords: max(0, scriptTokens.count - pairs.count),
                coverage: scriptTokens.isEmpty ? 1 : 0,
                transcriptDuration: transcriptDuration,
                transcriptWordCount: transcriptTokens.count
            )
        }

        let sceneScriptIndices = Self.groupScriptIndices(scriptTokens, sceneCount: scenes.count)
        let sceneKeySets = sceneScriptIndices.map { indices in
            Set(indices.map { scriptTokens[$0].key })
        }
        let contentKeys = Set(scriptTokens.map(\.key)).subtracting(Self.anchorStopwords)

        let assignment = Self.assignScenes(
            scenes: scenes.count,
            scriptTokens: scriptTokens,
            transcriptTokens: transcriptTokens,
            pairs: pairs,
            sceneKeySets: sceneKeySets,
            contentKeys: contentKeys
        )
        pairs = Self.addLocalPairsForUnmatchedScenes(
            scriptTokens: scriptTokens,
            transcriptTokens: transcriptTokens,
            assignment: assignment,
            sceneScriptIndices: sceneScriptIndices,
            pairs: pairs,
            maximumCells: maximumDynamicProgrammingCells
        )
        let pairedScript = Set(pairs.map(\.scriptIndex))
        let pairedTranscript = Set(pairs.map(\.transcriptIndex))

        var matchedCounts = [Int](repeating: 0, count: scenes.count)
        for pair in pairs {
            let scene = scriptTokens[pair.scriptIndex].sceneIndex
            if matchedCounts.indices.contains(scene) { matchedCounts[scene] += 1 }
        }

        var rawTimings: [(start: TimeInterval, end: TimeInterval)?] = Array(repeating: nil, count: scenes.count)
        var assignedIndices = [[Int]](repeating: [], count: scenes.count)
        for (transcriptIndex, sceneIndex) in assignment.enumerated() {
            guard let sceneIndex, assignedIndices.indices.contains(sceneIndex) else { continue }
            assignedIndices[sceneIndex].append(transcriptIndex)
        }

        for sceneIndex in scenes.indices {
            let indices = assignedIndices[sceneIndex]
            guard let first = indices.first, let last = indices.last else { continue }
            rawTimings[sceneIndex] = (transcriptTokens[first].start, transcriptTokens[last].end)
        }

        var sceneResults: [SceneAlignment] = []
        sceneResults.reserveCapacity(scenes.count)

        for sceneIndex in scenes.indices {
            var start: TimeInterval?
            var end: TimeInterval?
            var estimated = false

            if let timing = rawTimings[sceneIndex] {
                start = timing.start
                end = max(timing.start, timing.end)
                if matchedCounts[sceneIndex] == 0 { estimated = true }
            } else if !transcriptTokens.isEmpty {
                estimated = true
                let previousEnd = rawTimings[..<sceneIndex].reversed().compactMap { $0?.end }.first
                let nextStart = rawTimings[(sceneIndex + 1)...].compactMap { $0?.start }.first
                switch (previousEnd, nextStart) {
                case let (previous?, next?):
                    let midpoint = (previous + next) / 2
                    start = midpoint
                    end = midpoint
                case let (previous?, nil):
                    start = previous
                    end = previous
                case let (nil, next?):
                    start = next
                    end = next
                case (nil, nil):
                    start = nil
                    end = nil
                }
            } else {
                estimated = true
            }

            if let value = start { start = min(max(0, value), transcriptDuration) }
            if let value = end { end = min(max(0, value), transcriptDuration) }
            if let s = start, let e = end, e < s { end = s }

            let scriptIndices = sceneScriptIndices[sceneIndex]
            let scriptCount = scriptIndices.count
            let matched = matchedCounts[sceneIndex]
            let removed = max(0, scriptCount - matched)
            let added = assignedIndices[sceneIndex].reduce(into: 0) { count, index in
                if !pairedTranscript.contains(index) { count += 1 }
            }
            let coverage = scriptCount == 0 ? 1 : Double(matched) / Double(scriptCount)
            let deviations = makeDeviations(
                scriptIndices: scriptIndices,
                scriptTokens: scriptTokens,
                transcriptTokens: transcriptTokens,
                assignedIndices: assignedIndices[sceneIndex],
                pairedScript: pairedScript,
                pairedTranscript: pairedTranscript
            )

            sceneResults.append(
                SceneAlignment(
                    sceneID: scenes[sceneIndex].id,
                    start: start,
                    end: end,
                    scriptWordCount: scriptCount,
                    matchedWordCount: matched,
                    addedWordCount: added,
                    removedWordCount: removed,
                    coverage: coverage,
                    timingIsEstimated: estimated,
                    deviations: deviations
                )
            )
        }

        let totalScript = scriptTokens.count
        let totalMatched = pairs.count
        return TranscriptAlignment(
            scenes: sceneResults,
            totalScriptWords: totalScript,
            totalMatchedWords: totalMatched,
            totalAddedWords: max(0, transcriptTokens.count - totalMatched),
            totalRemovedWords: max(0, totalScript - totalMatched),
            coverage: totalScript == 0 ? 1 : Double(totalMatched) / Double(totalScript),
            transcriptDuration: transcriptDuration,
            transcriptWordCount: transcriptTokens.count
        )
    }
}

// MARK: - Tokens

private extension TranscriptAligner {
    struct ScriptToken {
        var key: String
        var display: String
        var sceneIndex: Int
    }

    struct TranscriptToken {
        var key: String
        var display: String
        var start: TimeInterval
        var end: TimeInterval
    }

    struct Pair {
        var scriptIndex: Int
        var transcriptIndex: Int
    }

    static func makeScriptTokens(from scenes: [SceneScript]) -> [ScriptToken] {
        var result: [ScriptToken] = []
        for (sceneIndex, scene) in scenes.enumerated() {
            for token in ScriptNormalizer.tokenize(scene.text) {
                result.append(ScriptToken(key: token.key, display: token.display, sceneIndex: sceneIndex))
            }
        }
        return result
    }

    static func groupScriptIndices(_ tokens: [ScriptToken], sceneCount: Int) -> [[Int]] {
        var groups = [[Int]](repeating: [], count: max(0, sceneCount))
        for (index, token) in tokens.enumerated() where groups.indices.contains(token.sceneIndex) {
            groups[token.sceneIndex].append(index)
        }
        return groups
    }

    static func makeTranscriptTokens(from segments: [SubtitleSegment]) -> [TranscriptToken] {
        var result: [TranscriptToken] = []
        for segment in segments {
            let words: [SubtitleWord]
            if segment.words.isEmpty {
                words = SubtitleParser.makeWords(from: segment.text, start: segment.start, end: segment.end)
            } else {
                words = segment.words
            }
            for word in words {
                let keys = ScriptNormalizer.keys(forWord: word.text)
                guard !keys.isEmpty else { continue }
                let display = word.text.trimmingCharacters(in: .punctuationCharacters)
                for key in keys {
                    result.append(
                        TranscriptToken(
                            key: key,
                            display: display.isEmpty ? key : display,
                            start: word.start,
                            end: max(word.start, word.end)
                        )
                    )
                }
            }
        }
        return result
    }
}

// MARK: - Scene assignment

private extension TranscriptAligner {
    /// Assigns every transcript token to one scene. Matched tokens use their
    /// script scene. Unmatched runs are matched to the scene whose vocabulary
    /// they share; if that is ambiguous, leading/trailing runs go to the
    /// adjacent matched scene and boundary runs are split in half.
    static func assignScenes(
        scenes: Int,
        scriptTokens: [ScriptToken],
        transcriptTokens: [TranscriptToken],
        pairs: [Pair],
        sceneKeySets: [Set<String>],
        contentKeys: Set<String>
    ) -> [Int?] {
        var assignment = [Int?](repeating: nil, count: transcriptTokens.count)
        guard scenes > 0, !transcriptTokens.isEmpty else { return assignment }

        let orderedPairs = pairs.sorted { $0.transcriptIndex < $1.transcriptIndex }
        if orderedPairs.isEmpty {
            let whole = 0..<transcriptTokens.count
            let scene = bestMatchingScene(
                for: whole,
                transcriptTokens: transcriptTokens,
                sceneKeySets: sceneKeySets,
                contentKeys: contentKeys
            ) ?? 0
            for index in assignment.indices { assignment[index] = scene }
            return assignment
        }

        for pair in orderedPairs {
            guard scriptTokens.indices.contains(pair.scriptIndex),
                  assignment.indices.contains(pair.transcriptIndex) else { continue }
            assignment[pair.transcriptIndex] = scriptTokens[pair.scriptIndex].sceneIndex
        }

        // Before the first matched word.
        if let first = orderedPairs.first {
            let range = 0..<first.transcriptIndex
            let fallback = scriptTokens[first.scriptIndex].sceneIndex
            let scene = bestMatchingScene(
                for: range,
                transcriptTokens: transcriptTokens,
                sceneKeySets: sceneKeySets,
                contentKeys: contentKeys
            ) ?? fallback
            for index in range { assignment[index] = scene }
        }

        // Between matched words.
        for (left, right) in zip(orderedPairs, orderedPairs.dropFirst()) {
            let leftScene = scriptTokens[left.scriptIndex].sceneIndex
            let rightScene = scriptTokens[right.scriptIndex].sceneIndex
            let start = left.transcriptIndex + 1
            let end = right.transcriptIndex
            guard start < end else { continue }
            let range = start..<end

            if leftScene == rightScene {
                for index in range { assignment[index] = leftScene }
                continue
            }

            let leftScore = matchCoverage(
                range,
                sceneKeys: sceneKeySets.indices.contains(leftScene) ? sceneKeySets[leftScene] : [],
                contentKeys: contentKeys,
                transcriptTokens: transcriptTokens
            )
            let rightScore = matchCoverage(
                range,
                sceneKeys: sceneKeySets.indices.contains(rightScene) ? sceneKeySets[rightScene] : [],
                contentKeys: contentKeys,
                transcriptTokens: transcriptTokens
            )
            if leftScore >= 0.6, leftScore >= rightScore + 0.2 {
                for index in range { assignment[index] = leftScene }
            } else if rightScore >= 0.6, rightScore >= leftScore + 0.2 {
                for index in range { assignment[index] = rightScene }
            } else {
                let split = start + (end - start) / 2
                for index in start..<split { assignment[index] = leftScene }
                for index in split..<end { assignment[index] = rightScene }
            }
        }

        // After the last matched word.
        if let last = orderedPairs.last {
            let range = (last.transcriptIndex + 1)..<assignment.count
            let fallback = scriptTokens[last.scriptIndex].sceneIndex
            let scene = bestMatchingScene(
                for: range,
                transcriptTokens: transcriptTokens,
                sceneKeySets: sceneKeySets,
                contentKeys: contentKeys
            ) ?? fallback
            for index in range { assignment[index] = scene }
        }

        // Any remaining tokens (possible with empty/odd pairs) belong to the
        // first scene.
        for index in assignment.indices where assignment[index] == nil {
            assignment[index] = 0
        }
        return assignment
    }

    static func bestMatchingScene(
        for range: Range<Int>,
        transcriptTokens: [TranscriptToken],
        sceneKeySets: [Set<String>],
        contentKeys: Set<String>
    ) -> Int? {
        guard !range.isEmpty else { return nil }
        var best: (scene: Int, score: Double)?
        for scene in sceneKeySets.indices {
            let score = matchCoverage(
                range,
                sceneKeys: sceneKeySets[scene],
                contentKeys: contentKeys,
                transcriptTokens: transcriptTokens
            )
            if score >= 0.6, score > (best?.score ?? 0) {
                best = (scene, score)
            }
        }
        return best?.scene
    }

    static func matchCoverage(
        _ range: Range<Int>,
        sceneKeys: Set<String>,
        contentKeys: Set<String>,
        transcriptTokens: [TranscriptToken]
    ) -> Double {
        let runKeys = Set(range.map { transcriptTokens[$0].key })
        let content = runKeys.intersection(contentKeys)
        guard content.count >= 2 else { return 0 }
        return Double(content.intersection(sceneKeys).count) / Double(content.count)
    }

    func makeDeviations(
        scriptIndices: [Int],
        scriptTokens: [ScriptToken],
        transcriptTokens: [TranscriptToken],
        assignedIndices: [Int],
        pairedScript: Set<Int>,
        pairedTranscript: Set<Int>
    ) -> [AlignmentDeviation] {
        var deviations: [AlignmentDeviation] = []

        var removedRun: [ScriptToken] = []
        func flushRemoved() {
            guard removedRun.count >= minimumDeviationWordCount else {
                removedRun.removeAll(keepingCapacity: true)
                return
            }
            deviations.append(
                AlignmentDeviation(
                    kind: .removed,
                    text: removedRun.map(\.display).joined(separator: " "),
                    wordCount: removedRun.count
                )
            )
            removedRun.removeAll(keepingCapacity: true)
        }

        for index in scriptIndices {
            guard scriptTokens.indices.contains(index) else { continue }
            if pairedScript.contains(index) {
                flushRemoved()
            } else {
                removedRun.append(scriptTokens[index])
            }
        }
        flushRemoved()

        var insertedRun: [TranscriptToken] = []
        func flushInserted() {
            guard insertedRun.count >= minimumDeviationWordCount else {
                insertedRun.removeAll(keepingCapacity: true)
                return
            }
            deviations.append(
                AlignmentDeviation(
                    kind: .inserted,
                    text: insertedRun.map(\.display).joined(separator: " "),
                    wordCount: insertedRun.count,
                    start: insertedRun.first?.start,
                    end: insertedRun.last?.end
                )
            )
            insertedRun.removeAll(keepingCapacity: true)
        }

        for index in assignedIndices {
            guard transcriptTokens.indices.contains(index) else { continue }
            if pairedTranscript.contains(index) {
                flushInserted()
            } else {
                insertedRun.append(transcriptTokens[index])
            }
        }
        flushInserted()

        return deviations.sorted {
            if $0.wordCount != $1.wordCount { return $0.wordCount > $1.wordCount }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }
}

// MARK: - Sequence alignment

private extension TranscriptAligner {
    static func computePairs(
        script: [ScriptToken],
        transcript: [TranscriptToken],
        maximumCells: Int
    ) -> [Pair] {
        guard !script.isEmpty, !transcript.isEmpty else { return [] }
        var pairs: [Pair] = []
        alignRegion(
            scriptRange: 0..<script.count,
            transcriptRange: 0..<transcript.count,
            script: script,
            transcript: transcript,
            maximumCells: max(10_000, maximumCells),
            pairs: &pairs
        )
        pairs.sort {
            if $0.scriptIndex != $1.scriptIndex { return $0.scriptIndex < $1.scriptIndex }
            return $0.transcriptIndex < $1.transcriptIndex
        }
        return pairs
    }

    static func addLocalPairsForUnmatchedScenes(
        scriptTokens: [ScriptToken],
        transcriptTokens: [TranscriptToken],
        assignment: [Int?],
        sceneScriptIndices: [[Int]],
        pairs: [Pair],
        maximumCells: Int
    ) -> [Pair] {
        guard !sceneScriptIndices.isEmpty else { return pairs }
        var result = pairs
        var pairedScript = Set(result.map(\.scriptIndex))
        var pairedTranscript = Set(result.map(\.transcriptIndex))
        var matchedCounts = [Int](repeating: 0, count: sceneScriptIndices.count)
        for pair in result {
            let scene = scriptTokens[pair.scriptIndex].sceneIndex
            if matchedCounts.indices.contains(scene) { matchedCounts[scene] += 1 }
        }

        var transcriptGroups = [[Int]](repeating: [], count: sceneScriptIndices.count)
        for (transcriptIndex, sceneIndex) in assignment.enumerated() {
            guard let sceneIndex, transcriptGroups.indices.contains(sceneIndex) else { continue }
            transcriptGroups[sceneIndex].append(transcriptIndex)
        }

        for scene in sceneScriptIndices.indices where matchedCounts[scene] == 0 {
            let scriptIndices = sceneScriptIndices[scene]
            let transcriptIndices = transcriptGroups[scene]
            guard !scriptIndices.isEmpty, !transcriptIndices.isEmpty else { continue }

            let local = localPairs(
                scriptIndices: scriptIndices,
                transcriptIndices: transcriptIndices,
                scriptTokens: scriptTokens,
                transcriptTokens: transcriptTokens,
                maximumCells: maximumCells
            )
            for pair in local {
                guard !pairedScript.contains(pair.scriptIndex),
                      !pairedTranscript.contains(pair.transcriptIndex) else { continue }
                result.append(pair)
                pairedScript.insert(pair.scriptIndex)
                pairedTranscript.insert(pair.transcriptIndex)
                matchedCounts[scene] += 1
            }
        }
        return result
    }

    static func localPairs(
        scriptIndices: [Int],
        transcriptIndices: [Int],
        scriptTokens: [ScriptToken],
        transcriptTokens: [TranscriptToken],
        maximumCells: Int
    ) -> [Pair] {
        guard !scriptIndices.isEmpty, !transcriptIndices.isEmpty else { return [] }
        let scriptKeys = scriptIndices.map { scriptTokens[$0].key }
        let transcriptKeys = transcriptIndices.map { transcriptTokens[$0].key }
        let cells = scriptKeys.count * transcriptKeys.count
        let local: [(Int, Int)]
        if cells <= max(10_000, maximumCells) {
            local = needlemanWunschKeys(scriptKeys, transcriptKeys)
        } else {
            local = greedyKeyPairs(scriptKeys, transcriptKeys)
        }
        return local.map {
            Pair(scriptIndex: scriptIndices[$0.0], transcriptIndex: transcriptIndices[$0.1])
        }
    }

    static func alignRegion(
        scriptRange: Range<Int>,
        transcriptRange: Range<Int>,
        script: [ScriptToken],
        transcript: [TranscriptToken],
        maximumCells: Int,
        pairs: inout [Pair]
    ) {
        guard !scriptRange.isEmpty, !transcriptRange.isEmpty else { return }
        let cells = scriptRange.count * transcriptRange.count
        if cells <= maximumCells {
            pairs.append(contentsOf: needlemanWunsch(
                scriptRange: scriptRange,
                transcriptRange: transcriptRange,
                script: script,
                transcript: transcript
            ))
            return
        }

        let anchors = uniqueAnchors(
            scriptRange: scriptRange,
            transcriptRange: transcriptRange,
            script: script,
            transcript: transcript
        )
        guard !anchors.isEmpty else {
            pairs.append(contentsOf: greedyPairs(
                scriptRange: scriptRange,
                transcriptRange: transcriptRange,
                script: script,
                transcript: transcript
            ))
            return
        }

        var scriptStart = scriptRange.lowerBound
        var transcriptStart = transcriptRange.lowerBound
        for anchor in anchors {
            if anchor.scriptIndex > scriptStart && anchor.transcriptIndex > transcriptStart {
                alignRegion(
                    scriptRange: scriptStart..<anchor.scriptIndex,
                    transcriptRange: transcriptStart..<anchor.transcriptIndex,
                    script: script,
                    transcript: transcript,
                    maximumCells: maximumCells,
                    pairs: &pairs
                )
            }
            pairs.append(anchor)
            scriptStart = anchor.scriptIndex + 1
            transcriptStart = anchor.transcriptIndex + 1
        }

        if scriptStart < scriptRange.upperBound && transcriptStart < transcriptRange.upperBound {
            alignRegion(
                scriptRange: scriptStart..<scriptRange.upperBound,
                transcriptRange: transcriptStart..<transcriptRange.upperBound,
                script: script,
                transcript: transcript,
                maximumCells: maximumCells,
                pairs: &pairs
            )
        }
    }

    static func uniqueAnchors(
        scriptRange: Range<Int>,
        transcriptRange: Range<Int>,
        script: [ScriptToken],
        transcript: [TranscriptToken]
    ) -> [Pair] {
        var scriptPositions: [String: [Int]] = [:]
        for index in scriptRange {
            let key = script[index].key
            guard key.count >= 3, !anchorStopwords.contains(key) else { continue }
            scriptPositions[key, default: []].append(index)
        }
        guard !scriptPositions.isEmpty else { return [] }

        var transcriptPositions: [String: [Int]] = [:]
        for index in transcriptRange {
            let key = transcript[index].key
            guard scriptPositions[key] != nil else { continue }
            transcriptPositions[key, default: []].append(index)
        }

        var candidates: [Pair] = []
        for (key, indices) in scriptPositions where indices.count == 1 {
            guard let transcriptIndices = transcriptPositions[key], transcriptIndices.count == 1 else { continue }
            candidates.append(Pair(scriptIndex: indices[0], transcriptIndex: transcriptIndices[0]))
        }
        candidates.sort { $0.scriptIndex < $1.scriptIndex }
        return longestIncreasingSubsequence(candidates)
    }

    static func longestIncreasingSubsequence(_ pairs: [Pair]) -> [Pair] {
        guard !pairs.isEmpty else { return [] }
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)

        for index in pairs.indices {
            let value = pairs[index].transcriptIndex
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].transcriptIndex < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }

        var result: [Pair] = []
        var current = tails.last ?? -1
        while current >= 0 {
            result.append(pairs[current])
            current = previous[current]
        }
        return result.reversed()
    }

    static func needlemanWunsch(
        scriptRange: Range<Int>,
        transcriptRange: Range<Int>,
        script: [ScriptToken],
        transcript: [TranscriptToken]
    ) -> [Pair] {
        let scriptKeys = scriptRange.map { script[$0].key }
        let transcriptKeys = transcriptRange.map { transcript[$0].key }
        return needlemanWunschKeys(scriptKeys, transcriptKeys).map {
            Pair(
                scriptIndex: scriptRange.lowerBound + $0.0,
                transcriptIndex: transcriptRange.lowerBound + $0.1
            )
        }
    }

    static func needlemanWunschKeys(
        _ scriptKeys: [String],
        _ transcriptKeys: [String]
    ) -> [(Int, Int)] {
        let rows = scriptKeys.count
        let columns = transcriptKeys.count
        guard rows > 0, columns > 0 else { return [] }

        let width = columns + 1
        var previous = [Int32](repeating: 0, count: width)
        var current = [Int32](repeating: 0, count: width)
        var directions = [UInt8](repeating: 0, count: (rows + 1) * width)

        for column in 0...columns {
            directions[column] = 2 // left: transcript-only step
            previous[column] = Int32(-column)
        }
        for row in 1...rows {
            current[0] = Int32(-row)
            directions[row * width] = 1 // up: script-only step
            for column in 1...columns {
                let diagonal = previous[column - 1] + (scriptKeys[row - 1] == transcriptKeys[column - 1] ? 2 : -1)
                let up = previous[column] - 1
                let left = current[column - 1] - 1
                let best = max(diagonal, max(up, left))
                current[column] = best
                if best == diagonal {
                    directions[row * width + column] = 0
                } else if best == up {
                    directions[row * width + column] = 1
                } else {
                    directions[row * width + column] = 2
                }
            }
            swap(&previous, &current)
        }

        var pairs: [(Int, Int)] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            let direction = directions[row * width + column]
            if row > 0 && column > 0 && direction == 0 {
                if scriptKeys[row - 1] == transcriptKeys[column - 1] {
                    pairs.append((row - 1, column - 1))
                }
                row -= 1
                column -= 1
            } else if row > 0 && (column == 0 || direction == 1) {
                row -= 1
            } else {
                column -= 1
            }
        }
        return pairs.reversed()
    }

    static func greedyKeyPairs(_ scriptKeys: [String], _ transcriptKeys: [String]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        var scriptIndex = 0
        var transcriptIndex = 0

        while scriptIndex < scriptKeys.count && transcriptIndex < transcriptKeys.count {
            if scriptKeys[scriptIndex] == transcriptKeys[transcriptIndex] {
                pairs.append((scriptIndex, transcriptIndex))
                scriptIndex += 1
                transcriptIndex += 1
                continue
            }

            var advanced = false
            for lookahead in 1...4 {
                if scriptIndex + lookahead < scriptKeys.count,
                   scriptKeys[scriptIndex + lookahead] == transcriptKeys[transcriptIndex] {
                    scriptIndex += lookahead
                    advanced = true
                    break
                }
                if transcriptIndex + lookahead < transcriptKeys.count,
                   scriptKeys[scriptIndex] == transcriptKeys[transcriptIndex + lookahead] {
                    transcriptIndex += lookahead
                    advanced = true
                    break
                }
            }
            if !advanced {
                scriptIndex += 1
                transcriptIndex += 1
            }
        }
        return pairs
    }

    static func greedyPairs(
        scriptRange: Range<Int>,
        transcriptRange: Range<Int>,
        script: [ScriptToken],
        transcript: [TranscriptToken]
    ) -> [Pair] {
        var pairs: [Pair] = []
        var scriptIndex = scriptRange.lowerBound
        var transcriptIndex = transcriptRange.lowerBound

        while scriptIndex < scriptRange.upperBound && transcriptIndex < transcriptRange.upperBound {
            if script[scriptIndex].key == transcript[transcriptIndex].key {
                pairs.append(Pair(scriptIndex: scriptIndex, transcriptIndex: transcriptIndex))
                scriptIndex += 1
                transcriptIndex += 1
                continue
            }

            var advanced = false
            for lookahead in 1...4 {
                if scriptIndex + lookahead < scriptRange.upperBound,
                   script[scriptIndex + lookahead].key == transcript[transcriptIndex].key {
                    scriptIndex += lookahead
                    advanced = true
                    break
                }
                if transcriptIndex + lookahead < transcriptRange.upperBound,
                   script[scriptIndex].key == transcript[transcriptIndex + lookahead].key {
                    transcriptIndex += lookahead
                    advanced = true
                    break
                }
            }
            if !advanced {
                scriptIndex += 1
                transcriptIndex += 1
            }
        }
        return pairs
    }

    /// Common words are poor anchors because their uniqueness is accidental.
    static let anchorStopwords: Set<String> = [
        "the", "and", "that", "this", "with", "you", "for", "are", "was", "were",
        "have", "has", "had", "not", "but", "they", "their", "from", "what", "when",
        "where", "which", "who", "how", "all", "can", "will", "just", "into", "out",
        "about", "over", "after", "before", "more", "than", "then", "them", "its",
        "like", "get", "got", "one", "two", "our", "your", "his", "her", "she",
        "him", "too", "very", "also", "because", "while", "there", "here", "now",
        "new", "use", "using", "dont", "didnt", "doesnt", "im", "ive", "youre",
        "que", "los", "las", "una", "uno", "unos", "unas", "del", "por", "para",
        "con", "sin", "como", "mas", "pero", "sus", "este", "esta", "estos", "estas",
        "ese", "esa", "esos", "esas", "hay", "fue", "son", "esta", "estan", "muy",
        "todo", "toda", "todos", "todas", "cuando", "donde", "desde", "hasta",
        "entre", "sobre", "tambien", "porque", "aunque", "tiene", "tienen", "hacer",
        "hace", "ser", "ver", "bien", "aqui", "ahi", "asi", "ahora", "luego",
        "despues", "antes", "durante", "cada", "otro", "otra", "otros", "otras",
        "mismo", "misma", "gran", "poco", "mucha", "mucho", "muchos", "muchas"
    ]
}
