import Foundation

/// One scene as the chapter planner sees it. Durations come from the app: the
/// best real take when one exists, otherwise the learned-WPM estimate.
public struct ChapterSceneInput: Sendable, Equatable, Identifiable {
    public var sceneID: UUID
    public var title: String
    public var duration: TimeInterval
    /// A hand-written chapter title. Empty/nil falls back to `title`.
    public var overrideTitle: String?
    public var isExcluded: Bool

    public var id: UUID { sceneID }

    public init(
        sceneID: UUID,
        title: String,
        duration: TimeInterval,
        overrideTitle: String? = nil,
        isExcluded: Bool = false
    ) {
        self.sceneID = sceneID
        self.title = title
        self.duration = duration
        self.overrideTitle = overrideTitle
        self.isExcluded = isExcluded
    }
}

/// A generated chapter list with the scene identity preserved. `ChapterList`
/// alone loses the link back to the scene, which the panel needs for inline
/// title editing.
public struct ChapterPlan: Sendable, Equatable {
    public let chapters: [Chapter]
    public let text: String
    public let warnings: [ChapterWarning]
    public let videoEndSeconds: Int
    public let isValidForYouTube: Bool

    public init(
        chapters: [Chapter],
        text: String,
        warnings: [ChapterWarning],
        videoEndSeconds: Int,
        isValidForYouTube: Bool
    ) {
        self.chapters = chapters
        self.text = text
        self.warnings = warnings
        self.videoEndSeconds = videoEndSeconds
        self.isValidForYouTube = isValidForYouTube
    }
}

/// One old → new title pair shown in the regeneration confirmation sheet.
public struct ChapterTitleChange: Sendable, Hashable, Identifiable {
    public let sceneID: UUID?
    public let oldTitle: String
    public let newTitle: String

    public var id: String {
        "\(sceneID?.uuidString ?? "imported").\(oldTitle).\(newTitle)"
    }

    public init(sceneID: UUID?, oldTitle: String, newTitle: String) {
        self.sceneID = sceneID
        self.oldTitle = oldTitle
        self.newTitle = newTitle
    }
}

/// A regeneration that would overwrite hand-edited titles. The panel shows
/// this diff and asks before applying it.
public struct ChapterRegenerationDiff: Sendable, Equatable {
    public let titleChanges: [ChapterTitleChange]
    /// Imported chapters with no scene cannot be regenerated; the sheet lists
    /// them so the user knows they disappear if the regenerated list is used.
    public let removedImportedTitles: [String]

    public var hasChanges: Bool {
        !titleChanges.isEmpty || !removedImportedTitles.isEmpty
    }

    public init(
        titleChanges: [ChapterTitleChange] = [],
        removedImportedTitles: [String] = []
    ) {
        self.titleChanges = titleChanges
        self.removedImportedTitles = removedImportedTitles
    }

    public static let empty = ChapterRegenerationDiff()
}

public enum PublishingChapters {
    /// Builds start positions from consecutive scene durations and delegates
    /// the YouTube rules (0:00, ≥3 chapters, ≥10 s, title sanitizing and short
    /// scene merging) to the existing `YouTubeChapters` generator.
    public static func plan(
        scenes: [ChapterSceneInput],
        rate: FrameRate = .fps25
    ) -> ChapterPlan {
        var cursor: TimeInterval = 0
        var exportScenes: [ExportScene] = []
        exportScenes.reserveCapacity(scenes.count)

        for input in scenes {
            let duration = input.duration.isFinite ? max(0, input.duration) : 0
            exportScenes.append(
                ExportScene(
                    id: input.sceneID,
                    title: input.title,
                    start: cursor,
                    duration: duration,
                    chapterTitle: PublishingText.nonEmpty(input.overrideTitle ?? ""),
                    includesInChapters: !input.isExcluded && duration > 0
                )
            )
            cursor += duration
        }

        let list = YouTubeChapters.make(scenes: exportScenes, rate: rate)
        return ChapterPlan(
            chapters: list.chapters,
            text: list.text,
            warnings: list.warnings,
            videoEndSeconds: list.videoEndSeconds,
            isValidForYouTube: list.isValidForYouTube
        )
    }

    /// Produces the overrides that make the plan survive a save and the
    /// escaleta export. Excluded scenes keep their exclusion, and regenerating
    /// with `keepingEditedTitles == false` replaces every title.
    public static func overrides(
        from plan: ChapterPlan,
        existing: [FrameScriptDocument.ChapterOverride],
        keepingEditedTitles: Bool
    ) -> [FrameScriptDocument.ChapterOverride] {
        var existingByScene: [UUID: FrameScriptDocument.ChapterOverride] = [:]
        for override in existing {
            guard let sceneID = override.sceneID, existingByScene[sceneID] == nil else { continue }
            existingByScene[sceneID] = override
        }

        var result: [FrameScriptDocument.ChapterOverride] = []
        var generatedSceneIDs = Set<UUID>()

        for chapter in plan.chapters {
            guard let sceneID = chapter.sceneID else { continue }
            generatedSceneIDs.insert(sceneID)
            let oldTitle = PublishingText.nonEmpty(existingByScene[sceneID]?.title ?? "")
            let title = keepingEditedTitles ? (oldTitle ?? chapter.title) : chapter.title
            let cleaned = ExportTextSanitizer.chapterTitle(
                title,
                limit: PublishingLimits.chapterTitleMaximum
            ).text
            result.append(
                FrameScriptDocument.ChapterOverride(
                    sceneID: sceneID,
                    title: cleaned,
                    startSeconds: TimeInterval(chapter.startSeconds),
                    isExcluded: false
                )
            )
        }

        // An excluded scene has no generated chapter, so its override would be
        // lost on regeneration. Keep the exclusion marker and its title.
        for override in existing where override.isExcluded {
            guard let sceneID = override.sceneID,
                  !generatedSceneIDs.contains(sceneID),
                  !result.contains(where: { $0.sceneID == sceneID }) else { continue }
            result.append(
                FrameScriptDocument.ChapterOverride(
                    id: override.id,
                    sceneID: sceneID,
                    title: override.title,
                    startSeconds: override.startSeconds,
                    isExcluded: true
                )
            )
        }

        return result.sorted { lhs, rhs in
            let left = lhs.startSeconds ?? 0
            let right = rhs.startSeconds ?? 0
            if left == right {
                return (lhs.sceneID?.uuidString ?? "") < (rhs.sceneID?.uuidString ?? "")
            }
            return left < right
        }
    }

    /// Compares the stored overrides with a fresh plan. Only titles that were
    /// actually changed by the user count; a generated title repeated by a new
    /// generation is not a conflict.
    public static func diff(
        existing: [FrameScriptDocument.ChapterOverride],
        plan: ChapterPlan
    ) -> ChapterRegenerationDiff {
        var generatedByScene: [UUID: String] = [:]
        for chapter in plan.chapters {
            guard let sceneID = chapter.sceneID, generatedByScene[sceneID] == nil else { continue }
            generatedByScene[sceneID] = chapter.title
        }

        var changes: [ChapterTitleChange] = []
        for override in existing {
            guard let sceneID = override.sceneID,
                  let newTitle = generatedByScene[sceneID] else { continue }
            let oldTitle = override.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oldTitle.isEmpty else { continue }
            let cleanedOld = ExportTextSanitizer.chapterTitle(
                oldTitle,
                limit: PublishingLimits.chapterTitleMaximum
            ).text
            guard cleanedOld != newTitle else { continue }
            changes.append(
                ChapterTitleChange(sceneID: sceneID, oldTitle: cleanedOld, newTitle: newTitle)
            )
        }

        let imported = existing.compactMap { override -> String? in
            guard override.sceneID == nil else { return nil }
            return PublishingText.nonEmpty(override.title)
        }

        return ChapterRegenerationDiff(
            titleChanges: changes,
            removedImportedTitles: imported
        )
    }

    /// Current overrides keyed by scene, for the inline editor and for the
    /// per-scene include switch.
    public static func overridesByScene(
        _ overrides: [FrameScriptDocument.ChapterOverride]
    ) -> [UUID: FrameScriptDocument.ChapterOverride] {
        var result: [UUID: FrameScriptDocument.ChapterOverride] = [:]
        for override in overrides {
            guard let sceneID = override.sceneID, result[sceneID] == nil else { continue }
            result[sceneID] = override
        }
        return result
    }
}
