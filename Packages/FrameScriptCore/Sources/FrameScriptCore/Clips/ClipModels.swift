import Foundation

/// Bounds and choices shared by the clip editor and the document.
///
/// The document stores whatever the user picked, so every value that reaches a
/// comparison, a formatter or a frame conversion is sanitized here first.
public enum ClipLimits {
    public static let minimumTarget: TimeInterval = 5
    public static let maximumTarget: TimeInterval = 600
    public static let defaultTargetSeconds: TimeInterval = 30

    /// A spoken hook is meant to fit in one to three seconds.
    public static let hookMinimumSeconds: TimeInterval = 1
    public static let hookMaximumSeconds: TimeInterval = 3

    /// Target buttons shown in the clip editor.
    public static let targetOptions: [TimeInterval] = [15, 30, 60, 90]

    public static func sanitizedTarget(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return min(max(value, minimumTarget), maximumTarget)
    }

    public static func sanitizedTarget(_ value: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
        sanitizedTarget(value) ?? fallback
    }
}

/// One piece of source text a clip is derived from.
///
/// A whole-scene clip has one fragment per scene. An anchored clip has exactly
/// one fragment and its text is the selected passage, not the whole scene.
public struct ClipSourceFragment: Sendable, Equatable {
    public let sceneID: UUID
    public let sceneTitle: String
    public let text: String
    public let isAnchor: Bool
    /// False when the anchor can no longer be found in the scene. The clip is
    /// then stale even if the rest of the scene is unchanged.
    public let isResolved: Bool

    public init(
        sceneID: UUID,
        sceneTitle: String,
        text: String,
        isAnchor: Bool,
        isResolved: Bool = true
    ) {
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.text = text
        self.isAnchor = isAnchor
        self.isResolved = isResolved
    }
}

/// Extracts the current source text for a clip without touching the document.
public enum ClipSourceExtractor {
    /// Fragments in `sourceSceneIDs` order. The anchor scene is inserted first
    /// when a hand-edited clip forgot to list it.
    public static func fragments(
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> [ClipSourceFragment] {
        let scenesByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var orderedIDs = clip.sourceSceneIDs
        if let anchorSceneID = clip.anchorSceneID, !orderedIDs.contains(anchorSceneID) {
            orderedIDs.insert(anchorSceneID, at: 0)
        }

        var seen: Set<UUID> = []
        return orderedIDs.compactMap { sceneID in
            guard seen.insert(sceneID).inserted, let scene = scenesByID[sceneID] else { return nil }
            guard clip.anchorSceneID == sceneID, let anchor = clip.anchor else {
                return ClipSourceFragment(
                    sceneID: sceneID,
                    sceneTitle: scene.title,
                    text: scene.scriptText,
                    isAnchor: false
                )
            }
            guard let repaired = FrameScriptDocument.TextAnchorRepair.repair(anchor, in: scene.scriptText) else {
                return ClipSourceFragment(
                    sceneID: sceneID,
                    sceneTitle: scene.title,
                    text: "",
                    isAnchor: true,
                    isResolved: false
                )
            }
            return ClipSourceFragment(
                sceneID: sceneID,
                sceneTitle: scene.title,
                text: repaired.selectedText,
                isAnchor: true
            )
        }
    }

    /// The fragment for one scene, even when the clip lists several scenes.
    public static func fragment(
        forSceneID sceneID: UUID,
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> ClipSourceFragment? {
        fragments(clip: clip, scenes: scenes).first { $0.sceneID == sceneID }
    }

    /// The repaired anchor for the anchor scene, or nil when it cannot be
    /// resolved. Used by "mark as reviewed" to refresh the stored range.
    public static func repairedAnchor(
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> FrameScriptDocument.TextAnchor? {
        guard let anchorSceneID = clip.anchorSceneID,
              let anchor = clip.anchor,
              let scene = scenes.first(where: { $0.id == anchorSceneID }) else {
            return nil
        }
        return FrameScriptDocument.TextAnchorRepair.repair(anchor, in: scene.scriptText)
    }

    /// All fragments joined for the AI prompt and for exports.
    public static func sourceText(
        clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene]
    ) -> String {
        fragments(clip: clip, scenes: scenes)
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }
}

/// Per-scene hashes plus the text needed to show a word diff after a rewrite.
public enum ClipSourceHashing {
    public static func sceneHashes(
        for fragments: [ClipSourceFragment]
    ) -> [FrameScriptDocument.ShortClip.SceneSourceHash] {
        fragments.map { fragment in
            FrameScriptDocument.ShortClip.SceneSourceHash(
                sceneID: fragment.sceneID,
                hash: FrameScriptDocument.TextHash.hash(fragment.text),
                sourceText: fragment.text
            )
        }
    }

    /// A cheap combined value for the clip's `sourceHash` field. It hashes the
    /// same joined source text `ClipSourceExtractor.sourceText` returns, so
    /// `ShortClip.isStale(comparedToSourceText:)` stays meaningful.
    public static func combinedHash(
        _ hashes: [FrameScriptDocument.ShortClip.SceneSourceHash]
    ) -> String {
        let joined = hashes
            .map(\.sourceText)
            .joined(separator: "\n\n")
        return FrameScriptDocument.TextHash.hash(joined)
    }
}

/// Builds a clip from whole scenes or from one anchored passage.
public enum ClipFactory {
    /// Creates a clip whose adapted text starts as the source text, so the
    /// editor can shorten it instead of writing from a blank page.
    public static func make(
        title: String,
        sceneIDs: [UUID],
        anchorSceneID: UUID? = nil,
        anchor: FrameScriptDocument.TextAnchor? = nil,
        targetSeconds: TimeInterval = ClipLimits.defaultTargetSeconds,
        format: FrameScriptDocument.ShortClipFormat = .reel,
        languageCode: String = "",
        status: FrameScriptDocument.ShortClipStatus = .idea,
        scenes: [FrameScriptDocument.Scene]
    ) -> FrameScriptDocument.ShortClip {
        let existingSceneIDs = Set(scenes.map(\.id))
        var orderedIDs: [UUID] = []
        var seen: Set<UUID> = []
        let requestedIDs = sceneIDs.filter(existingSceneIDs.contains)
        let resolvedAnchorSceneID: UUID? = {
            guard anchor != nil,
                  let anchorSceneID,
                  existingSceneIDs.contains(anchorSceneID) else {
                return nil
            }
            return anchorSceneID
        }()
        let resolvedAnchor = resolvedAnchorSceneID == nil ? nil : anchor
        if let resolvedAnchorSceneID {
            orderedIDs.append(resolvedAnchorSceneID)
            seen.insert(resolvedAnchorSceneID)
        }
        for sceneID in requestedIDs where seen.insert(sceneID).inserted {
            orderedIDs.append(sceneID)
        }

        var clip = FrameScriptDocument.ShortClip(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Clip" : title,
            sourceSceneIDs: orderedIDs,
            anchorSceneID: resolvedAnchorSceneID,
            anchor: resolvedAnchor,
            targetSeconds: ClipLimits.sanitizedTarget(targetSeconds, fallback: ClipLimits.defaultTargetSeconds),
            format: format,
            languageCode: languageCode,
            status: status
        )
        let fragments = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
        clip.sceneSourceHashes = ClipSourceHashing.sceneHashes(for: fragments)
        clip.sourceHash = ClipSourceHashing.combinedHash(clip.sceneSourceHashes)
        clip.adaptedText = fragments
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return clip
    }
}
