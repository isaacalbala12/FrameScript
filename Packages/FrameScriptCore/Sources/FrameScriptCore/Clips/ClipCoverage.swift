import Foundation

/// One take that belongs to a clip's source range.
public struct ClipTakeCoverage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sceneID: UUID
    public let sceneTitle: String
    public let take: FrameScriptDocument.Take
    public let languageCode: String
    /// For anchored clips: whether the take's teleprompter text contains the
    /// selected passage. `nil` means the take has no read text, so coverage is
    /// unknown rather than false.
    public let coversAnchor: Bool?

    public init(
        id: UUID,
        sceneID: UUID,
        sceneTitle: String,
        take: FrameScriptDocument.Take,
        languageCode: String,
        coversAnchor: Bool?
    ) {
        self.id = id
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.take = take
        self.languageCode = languageCode
        self.coversAnchor = coversAnchor
    }
}

/// Reuses the long video's takes and assets for a clip.
public enum ClipCoverage {
    /// Every scene take and translated-variant take for the clip's scenes.
    /// Takes are ordered by scene order and then by take number.
    public static func takes(
        for clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene],
        primaryLanguage: String
    ) -> [ClipTakeCoverage] {
        let fragments = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
        let anchorText = fragments.first(where: \.isAnchor).map(\.text)
        let orderedScenes = fragments.compactMap { fragment in
            scenes.first { $0.id == fragment.sceneID }
        }

        var coverage: [ClipTakeCoverage] = []
        for scene in orderedScenes {
            for take in scene.takes {
                coverage.append(
                    ClipTakeCoverage(
                        id: take.id,
                        sceneID: scene.id,
                        sceneTitle: scene.title,
                        take: take,
                        languageCode: resolvedLanguage(take.languageCode, primaryLanguage: primaryLanguage),
                        coversAnchor: anchorCoverage(take: take, anchorText: anchorText)
                    )
                )
            }
            for variant in scene.languageVariants {
                for take in variant.takes {
                    coverage.append(
                        ClipTakeCoverage(
                            id: take.id,
                            sceneID: scene.id,
                            sceneTitle: scene.title,
                            take: take,
                            languageCode: resolvedLanguage(variant.languageCode, primaryLanguage: primaryLanguage),
                            coversAnchor: anchorCoverage(take: take, anchorText: anchorText)
                        )
                    )
                }
            }
        }

        return coverage.sorted { lhs, rhs in
            let lhsScene = orderedScenes.firstIndex { $0.id == lhs.sceneID } ?? Int.max
            let rhsScene = orderedScenes.firstIndex { $0.id == rhs.sceneID } ?? Int.max
            if lhsScene != rhsScene { return lhsScene < rhsScene }
            if lhs.take.number != rhs.take.number { return lhs.take.number < rhs.take.number }
            return lhs.take.startedAt < rhs.take.startedAt
        }
    }

    /// Assets explicitly linked to the clip's scenes or to its takes.
    public static func assets(
        for clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene],
        assets: [FrameScriptDocument.ProjectAsset]
    ) -> [FrameScriptDocument.ProjectAsset] {
        let sceneIDs = Set(ClipSourceExtractor.fragments(clip: clip, scenes: scenes).map(\.sceneID))
        let takeIDs = Set(takes(for: clip, scenes: scenes, primaryLanguage: "").map(\.take.id))
        return assets
            .filter { asset in
                !sceneIDs.isDisjoint(with: asset.linkedSceneIDs)
                    || !takeIDs.isDisjoint(with: asset.linkedTakeIDs)
            }
            .sorted { $0.path < $1.path }
    }

    private static func resolvedLanguage(_ code: String, primaryLanguage: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? primaryLanguage : trimmed
    }

    private static func anchorCoverage(
        take: FrameScriptDocument.Take,
        anchorText: String?
    ) -> Bool? {
        guard let anchorText,
              !anchorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let readText = take.readText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readText.isEmpty else { return nil }
        let spokenRead = normalize(ScriptMarkup.spokenText(readText))
        let spokenAnchor = normalize(ScriptMarkup.spokenText(anchorText))
        guard !spokenAnchor.isEmpty else { return nil }
        return spokenRead.contains(spokenAnchor)
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
