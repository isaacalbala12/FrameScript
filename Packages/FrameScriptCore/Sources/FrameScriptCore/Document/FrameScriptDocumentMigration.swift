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
        guard anchor.startUTF16 >= 0,
              anchor.lengthUTF16 >= 0,
              anchor.startUTF16 + anchor.lengthUTF16 <= textLength else {
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

    /// The anchor repair rules from the pre-v4 reader. Kept identical so old
    /// files keep the same links after migration.
    public enum TextAnchorRepair {
        private static let contextLength = 48

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
            guard bounded.length > 0, NSMaxRange(bounded) <= full.length else { return nil }
            let selected = full.substring(with: bounded)
            return TextAnchor(
                startUTF16: bounded.location,
                lengthUTF16: bounded.length,
                selectedText: selected,
                prefixContext: full.substring(with: NSRange(
                    location: max(0, bounded.location - contextLength),
                    length: bounded.location - max(0, bounded.location - contextLength)
                )),
                suffixContext: full.substring(with: NSRange(
                    location: NSMaxRange(bounded),
                    length: min(contextLength, full.length - NSMaxRange(bounded))
                ))
            )
        }

        public static func repair(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
            guard let anchor else { return nil }
            let full = text as NSString
            guard anchor.lengthUTF16 >= 0, anchor.startUTF16 >= 0, !anchor.selectedText.isEmpty else { return nil }
            if let current = current(anchor, in: text) {
                return self.anchor(in: text, range: current.nsRange)
            }
            let matchingRanges = occurrences(of: anchor.selectedText, in: full)
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

        public static func current(_ anchor: TextAnchor?, in text: String) -> TextAnchor? {
            guard let anchor, anchor.lengthUTF16 > 0, !anchor.selectedText.isEmpty else { return nil }
            let full = text as NSString
            let range = anchor.nsRange
            guard range.location >= 0,
                  NSMaxRange(range) <= full.length,
                  full.substring(with: range) == anchor.selectedText else {
                return nil
            }
            return anchor
        }

        private static func occurrences(of value: String, in text: NSString) -> [NSRange] {
            let searchRange = NSRange(location: 0, length: text.length)
            var matches: [NSRange] = []
            var searchStart = searchRange.location
            let searchEnd = NSMaxRange(searchRange)
            guard !value.isEmpty else { return matches }
            while searchStart < searchEnd {
                let found = text.range(of: value, options: [], range: NSRange(location: searchStart, length: searchEnd - searchStart))
                guard found.location != NSNotFound else { break }
                matches.append(found)
                searchStart = max(NSMaxRange(found), found.location + 1)
            }
            return matches
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
                prefixes = occurrences(of: anchor.prefixContext, in: text).map(NSMaxRange)
            }
            let suffixes: [Int]
            if anchor.suffixContext.isEmpty {
                suffixes = [text.length]
            } else {
                suffixes = occurrences(of: anchor.suffixContext, in: text).map(\.location)
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
            guard location + length <= text.length else { return false }
            return text.substring(with: NSRange(location: location, length: length)) == anchor.suffixContext
        }

        private static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            let maxLength = max(0, length - location)
            return NSRange(location: location, length: min(max(0, range.length), maxLength))
        }
    }
}
