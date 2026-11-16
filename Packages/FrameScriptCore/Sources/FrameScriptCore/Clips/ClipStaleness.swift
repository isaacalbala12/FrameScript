import Foundation

/// One source scene that changed since the clip was created.
public struct ClipSceneChange: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// The scene text (or the anchored fragment) changed.
        case changed
        /// The scene was deleted from the project.
        case missingScene
        /// The anchored passage can no longer be found in its scene.
        case unresolvedAnchor
    }

    public let sceneID: UUID
    public let sceneTitle: String
    public let kind: Kind
    /// Source text stored when the clip was created.
    public let previousText: String
    /// Source text right now. Empty for deleted scenes and unresolved anchors.
    public let currentText: String
    /// Word-level redline between `previousText` and `currentText`.
    public let operations: [DiffOp]

    public init(
        sceneID: UUID,
        sceneTitle: String,
        kind: Kind,
        previousText: String,
        currentText: String,
        operations: [DiffOp] = []
    ) {
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.kind = kind
        self.previousText = previousText
        self.currentText = currentText
        self.operations = operations
    }

    public var hasOperations: Bool { !operations.isEmpty }

    /// Short human-readable list of inserted and removed chunks, capped so a
    /// full-scene rewrite cannot produce an unbounded UI string.
    public func changeSummary(limit: Int = 12) -> [ClipChangeChunk] {
        var chunks: [ClipChangeChunk] = []
        for operation in operations {
            switch operation.kind {
            case .equal:
                continue
            case .insert:
                guard let text = operation.insertedText, !text.isEmpty else { continue }
                chunks.append(ClipChangeChunk(kind: .inserted, text: text))
            case .delete:
                guard let text = operation.deletedText, !text.isEmpty else { continue }
                chunks.append(ClipChangeChunk(kind: .removed, text: text))
            }
            if chunks.count >= limit { break }
        }
        return chunks
    }
}

/// One word-diff chunk prepared for display.
public struct ClipChangeChunk: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case inserted
        case removed
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Result of comparing a clip's stored hashes with the current scenes.
public struct ClipStalenessReport: Sendable, Equatable {
    public let changes: [ClipSceneChange]
    /// True when the clip has an anchor but its passage is gone. The clip is
    /// stale in that case too, but the UI shows a specific message.
    public let hasUnresolvedAnchor: Bool

    public init(changes: [ClipSceneChange], hasUnresolvedAnchor: Bool = false) {
        self.changes = changes
        self.hasUnresolvedAnchor = hasUnresolvedAnchor
    }

    public static let clean = ClipStalenessReport(changes: [])

    public var isStale: Bool { !changes.isEmpty }
}

/// Detects rewritten source text and produces the redline shown in the clip
/// editor. Hash comparison is the cheap path used by list badges and summaries;
/// the full report adds a word diff only for scenes that actually changed.
public enum ClipStaleness {
    /// Fast check without building a diff.
    public static func isStale(
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> Bool {
        let fragments = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
        let currentByID = Dictionary(fragments.map { ($0.sceneID, $0) }, uniquingKeysWith: { first, _ in first })
        let scenesByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var storedIDs: Set<UUID> = []

        for stored in clip.sceneSourceHashes {
            storedIDs.insert(stored.sceneID)
            guard scenesByID[stored.sceneID] != nil,
                  let current = currentByID[stored.sceneID] else {
                return true
            }
            if FrameScriptDocument.TextHash.hash(current.text) != stored.hash {
                return true
            }
            if current.isAnchor, !current.isResolved {
                return true
            }
        }
        return fragments.contains { !storedIDs.contains($0.sceneID) }
    }

    public static func report(
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> ClipStalenessReport {
        let fragments = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
        let fragmentsByID = Dictionary(fragments.map { ($0.sceneID, $0) }, uniquingKeysWith: { first, _ in first })
        let scenesByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes: [ClipSceneChange] = []
        var storedIDs: Set<UUID> = []
        var hasUnresolvedAnchor = false

        for stored in clip.sceneSourceHashes {
            guard storedIDs.insert(stored.sceneID).inserted else { continue }
            guard let scene = scenesByID[stored.sceneID] else {
                changes.append(
                    ClipSceneChange(
                        sceneID: stored.sceneID,
                        sceneTitle: "",
                        kind: .missingScene,
                        previousText: stored.sourceText,
                        currentText: "",
                        operations: WordDiff.diff(old: stored.sourceText, new: "")
                    )
                )
                continue
            }
            guard let current = fragmentsByID[stored.sceneID] else {
                changes.append(
                    ClipSceneChange(
                        sceneID: scene.id,
                        sceneTitle: scene.title,
                        kind: .changed,
                        previousText: stored.sourceText,
                        currentText: "",
                        operations: WordDiff.diff(old: stored.sourceText, new: "")
                    )
                )
                continue
            }
            let currentHash = FrameScriptDocument.TextHash.hash(current.text)
            if current.isAnchor, !current.isResolved {
                hasUnresolvedAnchor = true
            }
            guard currentHash != stored.hash else { continue }
            let kind: ClipSceneChange.Kind = current.isAnchor && !current.isResolved
                ? .unresolvedAnchor
                : .changed
            changes.append(
                ClipSceneChange(
                    sceneID: scene.id,
                    sceneTitle: scene.title,
                    kind: kind,
                    previousText: stored.sourceText,
                    currentText: current.text,
                    operations: WordDiff.diff(old: stored.sourceText, new: current.text)
                )
            )
        }

        for fragment in fragments where !storedIDs.contains(fragment.sceneID) {
            changes.append(
                ClipSceneChange(
                    sceneID: fragment.sceneID,
                    sceneTitle: fragment.sceneTitle,
                    kind: fragment.isAnchor && !fragment.isResolved ? .unresolvedAnchor : .changed,
                    previousText: "",
                    currentText: fragment.text,
                    operations: WordDiff.diff(old: "", new: fragment.text)
                )
            )
            if fragment.isAnchor, !fragment.isResolved {
                hasUnresolvedAnchor = true
            }
        }

        return ClipStalenessReport(changes: changes, hasUnresolvedAnchor: hasUnresolvedAnchor)
    }

    /// Accepts the current source text as the new baseline and refreshes the
    /// stored anchor range when it can still be resolved.
    public static func markReviewed(
        _ clip: inout FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) {
        let fragments = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
        clip.sceneSourceHashes = ClipSourceHashing.sceneHashes(for: fragments)
        clip.sourceHash = ClipSourceHashing.combinedHash(clip.sceneSourceHashes)
        if let repaired = ClipSourceExtractor.repairedAnchor(clip: clip, scenes: scenes) {
            clip.anchor = repaired
        }
    }

    public static func reviewed(
        _ clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> FrameScriptDocument.ShortClip {
        var copy = clip
        markReviewed(&copy, scenes: scenes)
        return copy
    }
}
