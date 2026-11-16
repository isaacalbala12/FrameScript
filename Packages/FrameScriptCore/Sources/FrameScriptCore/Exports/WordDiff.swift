import Foundation

/// The kind of a word-level diff operation.
public enum DiffKind: String, Sendable, Codable, CaseIterable {
    case equal
    case insert
    case delete
}

/// One step of a word-level diff.
///
/// Operations are ordered, non-overlapping and together cover both input
/// strings exactly. For `.equal` both ranges point at the same text in the old
/// and new string. For `.insert` `oldRange` is empty at the insertion point and
/// `changedText` holds the inserted text. For `.delete` `newRange` is empty and
/// `changedText` holds the removed text.
public struct DiffOp: Sendable, Hashable, Codable {
    public let kind: DiffKind
    public let oldRange: UTF16Span
    public let newRange: UTF16Span
    public let changedText: String?

    public init(kind: DiffKind, oldRange: UTF16Span, newRange: UTF16Span, changedText: String? = nil) {
        self.kind = kind
        self.oldRange = oldRange
        self.newRange = newRange
        self.changedText = changedText
    }

    public var isEqual: Bool { kind == .equal }

    public var insertedText: String? { kind == .insert ? changedText : nil }

    public var deletedText: String? { kind == .delete ? changedText : nil }
}

/// Word-level diff tuned for Spanish scripts.
///
/// The tokenizer splits text into chunks of non-whitespace characters with the
/// following whitespace attached. Concatenating the tokens reproduces the input
/// exactly, which lets the diff render a redline without normalising anything.
/// Token boundaries always fall on extended grapheme clusters, so accented
/// characters and multi-scalar emoji never get sliced in the middle.
///
/// A paragraph pre-pass (blank-line separated blocks, or lines when a script has
/// no blank separators) anchors equal regions and word-diffs only the changed
/// hunks. Within a hunk the implementation uses Myers' O(ND) algorithm with a
/// bounded edit distance, and falls back to patience-style unique-token anchors
/// plus a coarse replace when the inputs are too different for Myers' budget.
/// Large hunks still get a small Myers probe so a couple of edits in repetitive
/// 20k-word text stay tight instead of becoming a whole-hunk replace.
public enum WordDiff {
    /// Maximum number of tokens on each side for which Myers is attempted.
    public static let myersTokenLimit = 4_096
    /// Maximum edit distance explored by Myers before falling back to anchors.
    public static let myersMaxEditDistance = 512

    /// Diffs two strings word by word.
    ///
    /// - Returns: Ordered operations covering both inputs. Identical strings
    ///   produce a single `.equal` operation (or an empty array for two empty
    ///   strings).
    public static func diff(old: String, new: String) -> [DiffOp] {
        if old.isEmpty && new.isEmpty { return [] }
        if old == new {
            let length = (old as NSString).length
            guard length > 0 else { return [] }
            let span = UTF16Span(location: 0, length: length)
            return [DiffOp(kind: .equal, oldRange: span, newRange: span)]
        }
        if old.isEmpty {
            let span = UTF16Span(location: 0, length: (new as NSString).length)
            return [DiffOp(kind: .insert, oldRange: .zero, newRange: span, changedText: new)]
        }
        if new.isEmpty {
            let span = UTF16Span(location: 0, length: (old as NSString).length)
            return [DiffOp(kind: .delete, oldRange: span, newRange: .zero, changedText: old)]
        }
        return buildDiff(old: old, new: new)
    }

    /// Reconstructs the new text from the old text and a diff produced by
    /// `diff(old:new:)`.
    ///
    /// This is mainly useful for tests and for restoring a preview without
    /// keeping the new snapshot around; it fails closed (skipping malformed
    /// operations) rather than trapping.
    public static func apply(_ ops: [DiffOp], to old: String) -> String {
        let source = old as NSString
        var result = ""
        result.reserveCapacity(source.length)
        for op in ops {
            switch op.kind {
            case .equal:
                let range = NSRange(location: op.oldRange.location, length: op.oldRange.length)
                guard range.location >= 0, range.location + range.length <= source.length else { continue }
                result += source.substring(with: range)
            case .delete:
                break
            case .insert:
                result += op.changedText ?? ""
            }
        }
        return result
    }

    // MARK: - Internals

    fileprivate struct Token {
        let text: String
        let range: UTF16Span
    }

    fileprivate struct Block {
        let text: String
        let range: UTF16Span
    }

    fileprivate struct SeqOp {
        enum Kind {
            case equal
            case insert
            case delete
        }

        let kind: Kind
        let aStart: Int
        let aCount: Int
        let bStart: Int
        let bCount: Int
    }

    private static func buildDiff(old: String, new: String) -> [DiffOp] {
        let oldBlocks = splitBlocks(old)
        let newBlocks = splitBlocks(new)
        let blockIDs = intern(oldBlocks.map(\.text), newBlocks.map(\.text))
        let blockOps = SequenceDiff.diff(
            blockIDs.old,
            blockIDs.new,
            tokenLimit: myersTokenLimit,
            maxEditDistance: myersMaxEditDistance
        )

        let nsOld = old as NSString
        let nsNew = new as NSString
        var result: [DiffOp] = []
        result.reserveCapacity(blockOps.count)
        var oldCursor = 0
        var newCursor = 0
        var index = 0

        while index < blockOps.count {
            let op = blockOps[index]
            if op.kind == .equal {
                guard op.aCount > 0, op.bCount > 0 else {
                    index += 1
                    continue
                }
                let oldFirst = oldBlocks[op.aStart]
                let oldLast = oldBlocks[op.aStart + op.aCount - 1]
                let newFirst = newBlocks[op.bStart]
                let newLast = newBlocks[op.bStart + op.bCount - 1]
                let oldSpan = UTF16Span(
                    location: oldFirst.range.location,
                    length: oldLast.range.end - oldFirst.range.location
                )
                let newSpan = UTF16Span(
                    location: newFirst.range.location,
                    length: newLast.range.end - newFirst.range.location
                )
                result.append(DiffOp(kind: .equal, oldRange: oldSpan, newRange: newSpan))
                oldCursor = oldSpan.end
                newCursor = newSpan.end
                index += 1
                continue
            }

            var oldHunkEnd = oldCursor
            var newHunkEnd = newCursor
            while index < blockOps.count, blockOps[index].kind != .equal {
                let hunkOp = blockOps[index]
                if hunkOp.aCount > 0 {
                    let last = oldBlocks[hunkOp.aStart + hunkOp.aCount - 1]
                    oldHunkEnd = last.range.end
                }
                if hunkOp.bCount > 0 {
                    let last = newBlocks[hunkOp.bStart + hunkOp.bCount - 1]
                    newHunkEnd = last.range.end
                }
                index += 1
            }

            let oldSpan = UTF16Span(location: oldCursor, length: oldHunkEnd - oldCursor)
            let newSpan = UTF16Span(location: newCursor, length: newHunkEnd - newCursor)

            switch (oldSpan.isEmpty, newSpan.isEmpty) {
            case (true, true):
                break
            case (true, false):
                let range = NSRange(location: newSpan.location, length: newSpan.length)
                result.append(DiffOp(
                    kind: .insert,
                    oldRange: UTF16Span(location: oldCursor),
                    newRange: newSpan,
                    changedText: nsNew.substring(with: range)
                ))
            case (false, true):
                let range = NSRange(location: oldSpan.location, length: oldSpan.length)
                result.append(DiffOp(
                    kind: .delete,
                    oldRange: oldSpan,
                    newRange: UTF16Span(location: newCursor),
                    changedText: nsOld.substring(with: range)
                ))
            case (false, false):
                let oldRange = NSRange(location: oldSpan.location, length: oldSpan.length)
                let newRange = NSRange(location: newSpan.location, length: newSpan.length)
                let oldText = nsOld.substring(with: oldRange)
                let newText = nsNew.substring(with: newRange)
                result.append(contentsOf: wordDiff(
                    oldText: oldText,
                    newText: newText,
                    oldBase: oldSpan.location,
                    newBase: newSpan.location
                ))
            }

            oldCursor = oldSpan.end
            newCursor = newSpan.end
        }

        return coalesce(result)
    }

    private static func wordDiff(
        oldText: String,
        newText: String,
        oldBase: Int,
        newBase: Int
    ) -> [DiffOp] {
        let oldTokens = tokenize(oldText)
        let newTokens = tokenize(newText)
        let oldLength = oldTokens.last?.range.end ?? 0
        let newLength = newTokens.last?.range.end ?? 0

        let tokenIDs = intern(oldTokens.map(\.text), newTokens.map(\.text))
        let ops = SequenceDiff.diff(
            tokenIDs.old,
            tokenIDs.new,
            tokenLimit: myersTokenLimit,
            maxEditDistance: myersMaxEditDistance
        )

        var result: [DiffOp] = []
        result.reserveCapacity(ops.count)
        for op in ops {
            let oldSpan = span(
                in: oldTokens,
                start: op.aStart,
                count: op.aCount,
                textLength: oldLength,
                base: oldBase
            )
            let newSpan = span(
                in: newTokens,
                start: op.bStart,
                count: op.bCount,
                textLength: newLength,
                base: newBase
            )
            let changed: String?
            switch op.kind {
            case .equal:
                changed = nil
            case .insert:
                changed = joined(newTokens, start: op.bStart, count: op.bCount)
            case .delete:
                changed = joined(oldTokens, start: op.aStart, count: op.aCount)
            }
            result.append(DiffOp(
                kind: diffKind(op.kind),
                oldRange: oldSpan,
                newRange: newSpan,
                changedText: changed
            ))
        }
        return result
    }

    private static func diffKind(_ kind: SeqOp.Kind) -> DiffKind {
        switch kind {
        case .equal: .equal
        case .insert: .insert
        case .delete: .delete
        }
    }

    private static func span(
        in tokens: [Token],
        start: Int,
        count: Int,
        textLength: Int,
        base: Int
    ) -> UTF16Span {
        if count == 0 {
            let location = start < tokens.count ? tokens[start].range.location : textLength
            return UTF16Span(location: base + location)
        }
        let first = tokens[start]
        let last = tokens[start + count - 1]
        return UTF16Span(
            location: base + first.range.location,
            length: last.range.end - first.range.location
        )
    }

    private static func joined(_ tokens: [Token], start: Int, count: Int) -> String {
        guard count > 0 else { return "" }
        return tokens[start..<(start + count)].map(\.text).joined()
    }

    /// Splits text into tokens that partition it exactly. A token is a run of
    /// non-whitespace characters plus the whitespace that follows it; leading
    /// whitespace forms its own token.
    private static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = []
        tokens.reserveCapacity(max(1, text.count / 5))
        var buffer = ""
        var bufferStart = 0
        var offset = 0
        var bufferEndsWithWhitespace = false
        var hasContent = false

        func flush() {
            guard !buffer.isEmpty else { return }
            tokens.append(Token(
                text: buffer,
                range: UTF16Span(location: bufferStart, length: offset - bufferStart)
            ))
            buffer = ""
            bufferEndsWithWhitespace = false
            hasContent = false
        }

        for character in text {
            if character.isWhitespace {
                if buffer.isEmpty { bufferStart = offset }
                buffer.append(character)
                bufferEndsWithWhitespace = true
            } else {
                if bufferEndsWithWhitespace || (hasContent == false && !buffer.isEmpty) {
                    flush()
                }
                if buffer.isEmpty { bufferStart = offset }
                buffer.append(character)
                hasContent = true
                bufferEndsWithWhitespace = false
            }
            offset += String(character).utf16.count
        }
        flush()
        return tokens
    }

    /// Splits text into blank-line separated paragraph blocks. When a document
    /// has no blank separators but several lines (typical for a teleprompter
    /// script), each line becomes a block so the pre-pass still helps.
    private static func splitBlocks(_ text: String) -> [Block] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let length = ns.length
        var ranges: [Range<Int>] = []
        var lineCount = 0
        var sawBlankLine = false
        var index = 0

        while index < length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let upper = min(max(lineRange.upperBound, index + 1), length)
            let range = index..<upper
            let line = ns.substring(with: NSRange(location: range.lowerBound, length: range.count))
            let blank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lineCount += 1
            sawBlankLine = sawBlankLine || blank

            if let last = ranges.last, last.upperBound == range.lowerBound {
                // Merge lines of the same kind (paragraph lines or a run of
                // blank separator lines) into one block.
                let lastIsBlank = ns.substring(with: NSRange(location: last.lowerBound, length: last.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if lastIsBlank == blank {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                } else {
                    ranges.append(range)
                }
            } else {
                ranges.append(range)
            }
            index = upper
        }

        if !sawBlankLine && lineCount > 4 {
            return lineBlocks(ns: ns, length: length)
        }

        return ranges.map { range in
            Block(
                text: ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                range: UTF16Span(range)
            )
        }
    }

    private static func lineBlocks(ns: NSString, length: Int) -> [Block] {
        var blocks: [Block] = []
        blocks.reserveCapacity(max(1, length / 40))
        var index = 0
        while index < length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let upper = min(max(lineRange.upperBound, index + 1), length)
            let range = index..<upper
            blocks.append(Block(
                text: ns.substring(with: NSRange(location: range.lowerBound, length: range.count)),
                range: UTF16Span(range)
            ))
            index = upper
        }
        return blocks
    }

    private static func intern(
        _ oldValues: [String],
        _ newValues: [String]
    ) -> (old: [Int], new: [Int]) {
        var map: [String: Int] = [:]
        map.reserveCapacity(oldValues.count + newValues.count)
        func interned(_ value: String) -> Int {
            if let id = map[value] { return id }
            let id = map.count
            map[value] = id
            return id
        }
        return (oldValues.map(interned), newValues.map(interned))
    }

    private static func coalesce(_ ops: [DiffOp]) -> [DiffOp] {
        var result: [DiffOp] = []
        result.reserveCapacity(ops.count)
        for op in ops {
            guard let last = result.last,
                  last.kind == .equal,
                  op.kind == .equal,
                  last.oldRange.end == op.oldRange.location,
                  last.newRange.end == op.newRange.location
            else {
                result.append(op)
                continue
            }
            result[result.count - 1] = DiffOp(
                kind: .equal,
                oldRange: UTF16Span(
                    location: last.oldRange.location,
                    length: last.oldRange.length + op.oldRange.length
                ),
                newRange: UTF16Span(
                    location: last.newRange.location,
                    length: last.newRange.length + op.newRange.length
                )
            )
        }
        return result
    }
}

// MARK: - Myers

private enum MyersDiff {
    static func diff(_ a: [Int], _ b: [Int], maxDistance: Int) -> [WordDiff.SeqOp]? {
        let n = a.count
        let m = b.count
        if n == 0 {
            return m == 0 ? [] : [WordDiff.SeqOp(
                kind: .insert, aStart: 0, aCount: 0, bStart: 0, bCount: m
            )]
        }
        if m == 0 {
            return [WordDiff.SeqOp(
                kind: .delete, aStart: 0, aCount: n, bStart: 0, bCount: 0
            )]
        }

        let limit = min(max(0, maxDistance), n + m)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        trace.reserveCapacity(limit + 1)
        var finalDistance = -1

        outer: for distance in 0...limit {
            trace.append(v)
            var diagonal = -distance
            while diagonal <= distance {
                let index = offset + diagonal
                var x: Int
                if diagonal == -distance
                    || (diagonal != distance && v[index - 1] < v[index + 1]) {
                    x = v[index + 1]
                } else {
                    x = v[index - 1] + 1
                }
                var y = x - diagonal
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[index] = x
                if x >= n && y >= m {
                    finalDistance = distance
                    break outer
                }
                diagonal += 2
            }
        }

        guard finalDistance >= 0 else { return nil }
        return backtrack(
            trace: trace,
            aCount: n,
            bCount: m,
            distance: finalDistance,
            offset: offset
        )
    }

    private static func backtrack(
        trace: [[Int]],
        aCount n: Int,
        bCount m: Int,
        distance finalDistance: Int,
        offset: Int
    ) -> [WordDiff.SeqOp] {
        var ops: [WordDiff.SeqOp] = []
        var x = n
        var y = m
        var distance = finalDistance

        while distance >= 1 {
            let v = trace[distance]
            let diagonal = x - y
            let previousDiagonal: Int
            if diagonal == -distance
                || (diagonal != distance && v[offset + diagonal - 1] < v[offset + diagonal + 1]) {
                previousDiagonal = diagonal + 1
            } else {
                previousDiagonal = diagonal - 1
            }
            let previousX = v[offset + previousDiagonal]
            let previousY = previousX - previousDiagonal
            let dx = x - previousX
            let dy = y - previousY
            let diagonalSteps = min(dx, dy)

            // The snake follows the edit. For an insertion it starts one token
            // later on the b side; for a deletion, one token later on a.
            if dy > dx {
                if diagonalSteps > 0 {
                    ops.append(WordDiff.SeqOp(
                        kind: .equal,
                        aStart: previousX,
                        aCount: diagonalSteps,
                        bStart: previousY + 1,
                        bCount: diagonalSteps
                    ))
                }
                ops.append(WordDiff.SeqOp(
                    kind: .insert,
                    aStart: previousX,
                    aCount: 0,
                    bStart: previousY,
                    bCount: 1
                ))
            } else {
                if diagonalSteps > 0 {
                    ops.append(WordDiff.SeqOp(
                        kind: .equal,
                        aStart: previousX + 1,
                        aCount: diagonalSteps,
                        bStart: previousY,
                        bCount: diagonalSteps
                    ))
                }
                ops.append(WordDiff.SeqOp(
                    kind: .delete,
                    aStart: previousX,
                    aCount: 1,
                    bStart: previousY,
                    bCount: 0
                ))
            }

            x = previousX
            y = previousY
            distance -= 1
        }

        if distance == 0 {
            let count = min(x, y)
            if count > 0 {
                ops.append(WordDiff.SeqOp(
                    kind: .equal,
                    aStart: 0,
                    aCount: count,
                    bStart: 0,
                    bCount: count
                ))
            }
        }

        return ops.reversed()
    }
}

// MARK: - Anchored sequence diff

private enum SequenceDiff {
    /// Edit-distance budget used to probe hunks larger than `tokenLimit`.
    private static let largeInputProbeDistance = 64

    static func diff(
        _ a: [Int],
        _ b: [Int],
        tokenLimit: Int,
        maxEditDistance: Int
    ) -> [WordDiff.SeqOp] {
        var output: [WordDiff.SeqOp] = []
        append(
            a: a,
            aRange: 0..<a.count,
            b: b,
            bRange: 0..<b.count,
            tokenLimit: tokenLimit,
            maxEditDistance: maxEditDistance,
            depth: 0,
            into: &output
        )
        return coalesce(output)
    }

    private static func append(
        a: [Int],
        aRange: Range<Int>,
        b: [Int],
        bRange: Range<Int>,
        tokenLimit: Int,
        maxEditDistance: Int,
        depth: Int,
        into output: inout [WordDiff.SeqOp]
    ) {
        var aStart = aRange.lowerBound
        let aEnd = aRange.upperBound
        var bStart = bRange.lowerBound
        let bEnd = bRange.upperBound
        guard aStart < aEnd || bStart < bEnd else { return }

        var prefix = 0
        while aStart + prefix < aEnd,
              bStart + prefix < bEnd,
              a[aStart + prefix] == b[bStart + prefix] {
            prefix += 1
        }
        if prefix > 0 {
            output.append(WordDiff.SeqOp(
                kind: .equal,
                aStart: aStart,
                aCount: prefix,
                bStart: bStart,
                bCount: prefix
            ))
            aStart += prefix
            bStart += prefix
        }

        var suffix = 0
        while aEnd - suffix > aStart,
              bEnd - suffix > bStart,
              a[aEnd - 1 - suffix] == b[bEnd - 1 - suffix] {
            suffix += 1
        }
        let aMiddleEnd = aEnd - suffix
        let bMiddleEnd = bEnd - suffix
        defer {
            if suffix > 0 {
                output.append(WordDiff.SeqOp(
                    kind: .equal,
                    aStart: aMiddleEnd,
                    aCount: suffix,
                    bStart: bMiddleEnd,
                    bCount: suffix
                ))
            }
        }

        if aStart == aMiddleEnd {
            if bStart < bMiddleEnd {
                output.append(WordDiff.SeqOp(
                    kind: .insert,
                    aStart: aStart,
                    aCount: 0,
                    bStart: bStart,
                    bCount: bMiddleEnd - bStart
                ))
            }
            return
        }
        if bStart == bMiddleEnd {
            output.append(WordDiff.SeqOp(
                kind: .delete,
                aStart: aStart,
                aCount: aMiddleEnd - aStart,
                bStart: bStart,
                bCount: 0
            ))
            return
        }

        let aSlice = Array(a[aStart..<aMiddleEnd])
        let bSlice = Array(b[bStart..<bMiddleEnd])

        // Large hunks get a cheap small-distance Myers probe: O((N+M)·D) is
        // still linear when D is tiny, which is common in repetitive scripts
        // with edits only at the edges.
        let totalCount = aSlice.count + bSlice.count
        let distanceBudget = totalCount <= tokenLimit
            ? maxEditDistance
            : min(maxEditDistance, largeInputProbeDistance)
        if let ops = MyersDiff.diff(aSlice, bSlice, maxDistance: distanceBudget) {
            for op in ops {
                output.append(WordDiff.SeqOp(
                    kind: op.kind,
                    aStart: op.aStart + aStart,
                    aCount: op.aCount,
                    bStart: op.bStart + bStart,
                    bCount: op.bCount
                ))
            }
            return
        }

        if depth < 96 {
            let anchors = patienceAnchors(
                a: a,
                aRange: aStart..<aMiddleEnd,
                b: b,
                bRange: bStart..<bMiddleEnd
            )
            if !anchors.isEmpty {
                var previousA = aStart
                var previousB = bStart
                for (anchorA, anchorB) in anchors {
                    append(
                        a: a,
                        aRange: previousA..<anchorA,
                        b: b,
                        bRange: previousB..<anchorB,
                        tokenLimit: tokenLimit,
                        maxEditDistance: maxEditDistance,
                        depth: depth + 1,
                        into: &output
                    )
                    output.append(WordDiff.SeqOp(
                        kind: .equal,
                        aStart: anchorA,
                        aCount: 1,
                        bStart: anchorB,
                        bCount: 1
                    ))
                    previousA = anchorA + 1
                    previousB = anchorB + 1
                }
                append(
                    a: a,
                    aRange: previousA..<aMiddleEnd,
                    b: b,
                    bRange: previousB..<bMiddleEnd,
                    tokenLimit: tokenLimit,
                    maxEditDistance: maxEditDistance,
                    depth: depth + 1,
                    into: &output
                )
                return
            }
        }

        output.append(WordDiff.SeqOp(
            kind: .delete,
            aStart: aStart,
            aCount: aMiddleEnd - aStart,
            bStart: bStart,
            bCount: 0
        ))
        output.append(WordDiff.SeqOp(
            kind: .insert,
            aStart: aMiddleEnd,
            aCount: 0,
            bStart: bStart,
            bCount: bMiddleEnd - bStart
        ))
    }

    private static func patienceAnchors(
        a: [Int],
        aRange: Range<Int>,
        b: [Int],
        bRange: Range<Int>
    ) -> [(Int, Int)] {
        guard !aRange.isEmpty, !bRange.isEmpty else { return [] }

        var aCounts: [Int: Int] = [:]
        var aPositions: [Int: Int] = [:]
        for index in aRange {
            let id = a[index]
            aCounts[id, default: 0] += 1
            if aPositions[id] == nil { aPositions[id] = index }
        }
        var bCounts: [Int: Int] = [:]
        var bPositions: [Int: Int] = [:]
        for index in bRange {
            let id = b[index]
            bCounts[id, default: 0] += 1
            if bPositions[id] == nil { bPositions[id] = index }
        }

        var candidates: [(Int, Int)] = []
        candidates.reserveCapacity(min(aCounts.count, 128))
        for (id, count) in aCounts where count == 1 {
            guard bCounts[id] == 1,
                  let aIndex = aPositions[id],
                  let bIndex = bPositions[id] else { continue }
            candidates.append((aIndex, bIndex))
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.0 < $1.0 }

        // Longest increasing subsequence on the b positions.
        var tails: [Int] = []
        var predecessors = [Int](repeating: -1, count: candidates.count)
        for index in candidates.indices {
            let value = candidates[index].1
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if candidates[tails[middle]].1 < value {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 { predecessors[index] = tails[low - 1] }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }

        guard let last = tails.last else { return [] }
        var result: [(Int, Int)] = []
        var cursor = last
        while cursor >= 0 {
            result.append(candidates[cursor])
            cursor = predecessors[cursor]
        }
        return result.reversed()
    }

    private static func coalesce(_ ops: [WordDiff.SeqOp]) -> [WordDiff.SeqOp] {
        var result: [WordDiff.SeqOp] = []
        result.reserveCapacity(ops.count)
        for op in ops {
            guard let last = result.last,
                  last.kind == op.kind,
                  last.aStart + last.aCount == op.aStart,
                  last.bStart + last.bCount == op.bStart
            else {
                result.append(op)
                continue
            }
            result[result.count - 1] = WordDiff.SeqOp(
                kind: op.kind,
                aStart: last.aStart,
                aCount: last.aCount + op.aCount,
                bStart: last.bStart,
                bCount: last.bCount + op.bCount
            )
        }
        return result
    }
}
