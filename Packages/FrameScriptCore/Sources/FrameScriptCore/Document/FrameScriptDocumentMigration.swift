import Foundation

extension FrameScriptDocument {
    /// Validates the version, runs the migration branches for v1-v3 and returns
    /// a version-4 document. Version-4 documents only get validation.
    public func migrated() throws -> FrameScriptDocument {
        guard FrameScriptFormat.supportedFileVersions.contains(fileVersion) else {
            throw FrameScriptDocumentError.unsupportedVersion(fileVersion)
        }

        var document = self
        switch fileVersion {
        case 1:
            document.migrateLegacySegmentLinks()
            document.migrateV2ToV3()
            document.migrateV3ToV4()
        case 2:
            // v2 files could still carry a segment-only link (the old reader
            // migrated it unconditionally), so keep that behavior here too.
            document.migrateLegacySegmentLinks()
            document.migrateV2ToV3()
            document.migrateV3ToV4()
        case 3:
            document.migrateLegacySegmentLinks()
            document.migrateV3ToV4()
        default:
            // v4 is the current format. Reading it must be lossless: validate
            // anchors but never rewrite them. Legacy repair belongs to v1-v3.
            break
        }
        document.fileVersion = FrameScriptFormat.currentFileVersion
        try document.validateSceneIdentifiers()
        try document.validateAnchors()
        return document
    }

    // MARK: Legacy segment links (v1 -> v2, kept for v2/v3 too)

    /// v1 could store a segment link without an anchor. Turn that link into the
    /// anchor the current editors expect, and clear links that cannot resolve.
    private mutating func migrateLegacySegmentLinks() {
        for sceneIndex in project.scenes.indices {
            var scene = project.scenes[sceneIndex]
            for index in scene.bRollItems.indices {
                migrateLegacyLink(&scene.bRollItems[index], scene: scene)
            }
            for index in scene.editingItems.indices {
                migrateLegacyLink(&scene.editingItems[index], scene: scene)
            }
            project.scenes[sceneIndex] = scene
        }
    }

    private func migrateLegacyLink(_ item: inout BRollItem, scene: Scene) {
        guard item.textAnchor == nil else { return }
        guard let linkedID = item.linkedSegmentID,
              let segment = scene.textSegments.first(where: { $0.id == linkedID }),
              let anchor = TextAnchorRepair.anchor(for: segment, in: scene.scriptText) else {
            item.linkedSegmentID = nil
            return
        }
        item.textAnchor = anchor
    }

    private func migrateLegacyLink(_ item: inout EditingItem, scene: Scene) {
        guard item.textAnchor == nil else { return }
        guard let linkedID = item.linkedSegmentID,
              let segment = scene.textSegments.first(where: { $0.id == linkedID }),
              let anchor = TextAnchorRepair.anchor(for: segment, in: scene.scriptText) else {
            item.linkedSegmentID = nil
            return
        }
        item.textAnchor = anchor
    }

    // MARK: v2 -> v3

    /// v2 already had anchors, but they could be stale after external edits.
    /// The pre-v4 reader repaired every anchor on load; keep that behavior.
    private mutating func migrateV2ToV3() {
        repairAnchors()
    }

    // MARK: v3 -> v4

    /// v3 is the last pre-v4 schema. Repair any stale anchors (same behavior as
    /// the old reader), then drop cross-references that cannot resolve now that
    /// assets, claims, takes and clips are persisted together.
    private mutating func migrateV3ToV4() {
        repairAnchors()
        normalizeCrossReferences()
    }

    private mutating func repairAnchors() {
        for sceneIndex in project.scenes.indices {
            var scene = project.scenes[sceneIndex]
            for index in scene.bRollItems.indices {
                guard scene.bRollItems[index].textAnchor != nil else { continue }
                guard let repaired = TextAnchorRepair.repair(scene.bRollItems[index].textAnchor, in: scene.scriptText) else {
                    scene.bRollItems[index].textAnchor = nil
                    scene.bRollItems[index].linkedSegmentID = nil
                    continue
                }
                scene.bRollItems[index].textAnchor = repaired
            }
            for index in scene.editingItems.indices {
                guard scene.editingItems[index].textAnchor != nil else { continue }
                guard let repaired = TextAnchorRepair.repair(scene.editingItems[index].textAnchor, in: scene.scriptText) else {
                    scene.editingItems[index].textAnchor = nil
                    scene.editingItems[index].linkedSegmentID = nil
                    continue
                }
                scene.editingItems[index].textAnchor = repaired
            }
            project.scenes[sceneIndex] = scene
        }
    }

    private mutating func normalizeCrossReferences() {
        let sceneIDs = Set(project.scenes.map(\.id))
        let bRollIDs = Set(project.scenes.flatMap(\.bRollItems).map(\.id))
        let takeIDs = Set(
            project.scenes.flatMap(\.takes).map(\.id)
                + project.scenes.flatMap(\.languageVariants).flatMap(\.takes).map(\.id)
        )
        let sourceIDs = Set(project.sources.map(\.id))

        for index in project.assets.indices {
            project.assets[index].linkedSceneIDs = Self.uniqued(project.assets[index].linkedSceneIDs.filter(sceneIDs.contains))
            project.assets[index].linkedBRollItemIDs = Self.uniqued(project.assets[index].linkedBRollItemIDs.filter(bRollIDs.contains))
            project.assets[index].linkedTakeIDs = Self.uniqued(project.assets[index].linkedTakeIDs.filter(takeIDs.contains))
        }
        for index in project.claims.indices {
            project.claims[index].sourceIDs = Self.uniqued(project.claims[index].sourceIDs.filter(sourceIDs.contains))
            project.claims[index].sceneIDs = Self.uniqued(project.claims[index].sceneIDs.filter(sceneIDs.contains))
        }
        for index in project.clips.indices {
            project.clips[index].sourceSceneIDs = Self.uniqued(project.clips[index].sourceSceneIDs.filter(sceneIDs.contains))
            if let anchorSceneID = project.clips[index].anchorSceneID, !sceneIDs.contains(anchorSceneID) {
                project.clips[index].anchorSceneID = nil
                project.clips[index].anchor = nil
            }
        }
    }

    private static func uniqued<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Validation

    private func validateSceneIdentifiers() throws {
        var seen: Set<UUID> = []
        for scene in project.scenes {
            if !seen.insert(scene.id).inserted {
                throw FrameScriptDocumentError.duplicateSceneID(scene.id)
            }
        }
    }

    private func validateAnchors() throws {
        for scene in project.scenes {
            let textLength = (scene.scriptText as NSString).length
            for item in scene.bRollItems {
                try validate(item.textAnchor, textLength: textLength)
            }
            for item in scene.editingItems {
                try validate(item.textAnchor, textLength: textLength)
            }
        }
    }

    private func validate(_ anchor: TextAnchor?, textLength: Int) throws {
        guard let anchor else { return }
        // Subtraction instead of addition so Int.max cannot overflow.
        guard anchor.startUTF16 >= 0,
              anchor.lengthUTF16 >= 0,
              anchor.startUTF16 <= textLength,
              anchor.lengthUTF16 <= textLength - anchor.startUTF16 else {
            throw FrameScriptDocumentError.invalidAnchor
        }
    }
}

// MARK: - Text splitting used by legacy-link migration

extension FrameScriptDocument {
    /// Mirrors the app's `TextSegmenter` so v1 segment links resolve against the
    /// same text ranges the old build used.
    public enum TextSegmenter {
        public static func segmentTexts(in text: String, splitMode: SegmentType) -> [String] {
            switch splitMode {
            case .scene:
                let trimmed = trimmed(text)
                return trimmed.isEmpty ? [] : [trimmed]
            case .paragraph:
                return text
                    .components(separatedBy: CharacterSet.newlines)
                    .map(trimmed)
                    .filter { !$0.isEmpty }
            case .sentence:
                return sentenceTexts(in: text)
            }
        }

        public static func normalized(_ text: String) -> String {
            trimmed(text)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .lowercased()
        }

        private static func sentenceTexts(in text: String) -> [String] {
            var sentences: [String] = []
            var current = ""
            var previousWasTerminator = false
            let terminators = CharacterSet(charactersIn: ".!?…")
            let closers = CharacterSet(charactersIn: "\"'»”’)]}")

            for scalar in text.unicodeScalars {
                current.unicodeScalars.append(scalar)
                if terminators.contains(scalar) {
                    previousWasTerminator = true
                    continue
                }
                if previousWasTerminator, closers.contains(scalar) {
                    continue
                }
                if previousWasTerminator, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    appendTrimmed(current, to: &sentences)
                    current = ""
                    previousWasTerminator = false
                    continue
                }
                previousWasTerminator = false
            }

            appendTrimmed(current, to: &sentences)
            return sentences
        }

        private static func appendTrimmed(_ text: String, to sentences: inout [String]) {
            let value = trimmed(text)
            if !value.isEmpty {
                sentences.append(value)
            }
        }

        private static func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The anchor repair rules shared by the app and the document reader.
    /// Legacy migrations are the only callers that rewrite anchors; v4 reads
    /// validate without mutating.
    public enum TextAnchorRepair {
        /// Number of UTF-16 units captured on each side of an anchor.
        public static let contextLength = 48

        /// Upper bound on how many matches a single repair inspects. A script
        /// that repeats a phrase this often is treated as unrepairable instead
        /// of blocking the reader.
        public static let maximumOccurrences = 512

        public static func anchor(for segment: TextSegment, in text: String) -> TextAnchor? {
            let full = text as NSString
            guard full.length > 0, !segment.sourceText.isEmpty else { return nil }
            var searchStart = 0
            let candidates = TextSegmenter.segmentTexts(in: text, splitMode: segment.segmentType)
            for (index, candidate) in candidates.enumerated() {
                let searchRange = NSRange(location: searchStart, length: max(0, full.length - searchStart))
                let found = full.range(of: candidate, options: [], range: searchRange)
                guard found.location != NSNotFound else { return nil }
                if index == segment.order,
                   TextSegmenter.normalized(candidate) == TextSegmenter.normalized(segment.sourceText) {
                    return anchor(in: text, range: found)
                }
                searchStart = NSMaxRange(found)
            }
            return nil
        }

        public static func anchor(in text: String, range: NSRange) -> TextAnchor? {
            let full = text as NSString
            let bounded = clamp(range, toLength: full.length)
            guard bounded.length > 0,
                  bounded.location >= 0,
                  bounded.length <= full.length - bounded.location else {
                return nil
            }
            let selected = full.substring(with: bounded)
            return TextAnchor(
                startUTF16: bounded.location,
                lengthUTF16: bounded.length,
                selectedText: selected,
                prefixContext: contextBefore(full, location: bounded.location),
                suffixContext: contextAfter(full, location: NSMaxRange(bounded))
            )
        }

        public static func repair(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
            guard let anchor else { return nil }
            let full = text as NSString
            guard anchor.lengthUTF16 >= 0,
                  anchor.startUTF16 >= 0,
                  !anchor.selectedText.isEmpty else {
                return nil
            }
            if let current = current(anchor, in: text) {
                return self.anchor(in: text, range: current.nsRange)
            }
            let matchingRanges = occurrences(of: anchor.selectedText, in: full)
            guard matchingRanges.count < maximumOccurrences else { return nil }
            let exactCandidates = matchingRanges
                .filter { hasAdjacentBoundary(anchor: anchor, text: full, range: $0) }
            if exactCandidates.count == 1, let exact = exactCandidates.first {
                return self.anchor(in: text, range: exact)
            }
            guard matchingRanges.isEmpty,
                  let repairedRange = uniqueBoundaryRange(for: anchor, in: full) else {
                return nil
            }
            return self.anchor(in: text, range: repairedRange)
        }

        public static func repair(_ anchor: TextAnchor?, from previousText: String, to text: String) -> TextAnchor? {
            guard let anchor,
                  let current = current(anchor, in: previousText) else { return nil }
            guard previousText != text else { return self.anchor(in: text, range: current.nsRange) }
            let previous = previousText as NSString
            let updated = text as NSString
            let edit = contiguousEdit(from: previous, to: updated)
            let start = current.startUTF16
            let end = start + current.lengthUTF16
            let oldStart = edit.oldRange.location
            let oldEnd = NSMaxRange(edit.oldRange)
            let newEnd = NSMaxRange(edit.newRange)
            let delta = edit.newRange.length - edit.oldRange.length

            let repairedRange: NSRange?
            if oldEnd <= start {
                repairedRange = NSRange(location: start + delta, length: current.lengthUTF16)
            } else if oldStart >= end {
                repairedRange = current.nsRange
            } else if oldStart > start, oldEnd < end {
                repairedRange = NSRange(location: start, length: current.lengthUTF16 + delta)
            } else if oldStart <= start, oldEnd < end {
                repairedRange = NSRange(location: oldStart, length: end + delta - oldStart)
            } else if oldStart > start, oldEnd >= end {
                repairedRange = NSRange(location: start, length: newEnd - start)
            } else {
                repairedRange = nil
            }
            guard let repairedRange,
                  repairedRange.location >= 0,
                  repairedRange.length > 0,
                  repairedRange.location <= updated.length,
                  repairedRange.length <= updated.length - repairedRange.location else {
                return nil
            }
            return self.anchor(in: text, range: repairedRange)
        }

        public static func current(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
            guard let anchor,
                  anchor.lengthUTF16 > 0,
                  anchor.startUTF16 >= 0,
                  !anchor.selectedText.isEmpty else {
                return nil
            }
            let full = text as NSString
            let range = anchor.nsRange
            guard range.location >= 0,
                  range.location <= full.length,
                  range.length <= full.length - range.location,
                  full.substring(with: range) == anchor.selectedText else {
                return nil
            }
            return anchor
        }

        public static func isAnchor(_ anchor: TextAnchor, in segment: TextSegment, text: String) -> Bool {
            guard let segmentAnchor = self.anchor(for: segment, in: text) else { return false }
            return NSLocationInRange(anchor.startUTF16, segmentAnchor.nsRange)
        }

        private static func contextBefore(_ text: NSString, location: Int) -> String {
            guard location > 0 else { return "" }
            let start = max(0, location - contextLength)
            guard start < location else { return "" }
            let snapped = text.rangeOfComposedCharacterSequences(
                for: NSRange(location: start, length: location - start)
            )
            let snappedStart = max(0, snapped.location)
            let snappedEnd = NSMaxRange(snapped)
            // If the anchor starts inside a cluster, drop that partial cluster
            // rather than cutting a surrogate pair or grapheme.
            let end = snappedEnd <= location ? snappedEnd : snapped.location
            guard end > snappedStart else { return "" }
            return text.substring(with: NSRange(location: snappedStart, length: end - snappedStart))
        }

        private static func contextAfter(_ text: NSString, location: Int) -> String {
            guard location >= 0, location < text.length else { return "" }
            let length = min(contextLength, text.length - location)
            guard length > 0 else { return "" }
            let snapped = text.rangeOfComposedCharacterSequences(
                for: NSRange(location: location, length: length)
            )
            let start = max(0, snapped.location)
            let end = min(text.length, NSMaxRange(snapped))
            guard end > start else { return "" }
            return text.substring(with: NSRange(location: start, length: end - start))
        }

        private static func occurrences(of value: String, in text: NSString) -> [NSRange] {
            let searchRange = NSRange(location: 0, length: text.length)
            var matches: [NSRange] = []
            var searchStart = searchRange.location
            let searchEnd = NSMaxRange(searchRange)
            guard !value.isEmpty else { return matches }
            while searchStart < searchEnd, matches.count < maximumOccurrences {
                let found = text.range(of: value, options: [], range: NSRange(location: searchStart, length: searchEnd - searchStart))
                guard found.location != NSNotFound else { break }
                matches.append(found)
                searchStart = max(NSMaxRange(found), found.location + 1)
            }
            return matches
        }

        private static func contiguousEdit(from old: NSString, to new: NSString) -> (oldRange: NSRange, newRange: NSRange) {
            let commonLimit = min(old.length, new.length)
            var prefix = 0
            while prefix < commonLimit, old.character(at: prefix) == new.character(at: prefix) {
                prefix += 1
            }
            var suffix = 0
            while suffix < old.length - prefix,
                  suffix < new.length - prefix,
                  old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
                suffix += 1
            }
            return (
                NSRange(location: prefix, length: old.length - prefix - suffix),
                NSRange(location: prefix, length: new.length - prefix - suffix)
            )
        }

        private static func hasAdjacentBoundary(anchor: TextAnchor, text: NSString, range: NSRange) -> Bool {
            hasPrefixBoundary(anchor, text: text, before: range.location)
                || hasSuffixBoundary(anchor, text: text, after: NSMaxRange(range))
        }

        private static func uniqueBoundaryRange(for anchor: TextAnchor, in text: NSString) -> NSRange? {
            let prefixes: [Int]
            if anchor.prefixContext.isEmpty {
                prefixes = [0]
            } else {
                let matches = occurrences(of: anchor.prefixContext, in: text)
                guard matches.count < maximumOccurrences else { return nil }
                prefixes = matches.map(NSMaxRange)
            }
            let suffixes: [Int]
            if anchor.suffixContext.isEmpty {
                suffixes = [text.length]
            } else {
                let matches = occurrences(of: anchor.suffixContext, in: text)
                guard matches.count < maximumOccurrences else { return nil }
                suffixes = matches.map(\.location)
            }
            let candidates: [NSRange] = prefixes.flatMap { prefixEnd in
                suffixes.compactMap { suffixStart in
                    guard prefixEnd < suffixStart else { return nil }
                    return NSRange(location: prefixEnd, length: suffixStart - prefixEnd)
                }
            }
            guard candidates.count == 1, let range = candidates.first else { return nil }
            return range
        }

        private static func hasPrefixBoundary(_ anchor: TextAnchor, text: NSString, before location: Int) -> Bool {
            guard !anchor.prefixContext.isEmpty else { return location == 0 }
            let length = (anchor.prefixContext as NSString).length
            guard location >= length else { return false }
            return text.substring(with: NSRange(location: location - length, length: length)) == anchor.prefixContext
        }

        private static func hasSuffixBoundary(_ anchor: TextAnchor, text: NSString, after location: Int) -> Bool {
            guard !anchor.suffixContext.isEmpty else { return location == text.length }
            let length = (anchor.suffixContext as NSString).length
            guard location >= 0, location <= text.length, length <= text.length - location else { return false }
            return text.substring(with: NSRange(location: location, length: length)) == anchor.suffixContext
        }

        private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            let maxLength = max(0, length - location)
            return NSRange(location: location, length: min(max(0, range.length), maxLength))
        }
    }
}
