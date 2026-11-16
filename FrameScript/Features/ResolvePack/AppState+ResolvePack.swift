import Foundation
import FrameScriptCore

@MainActor
extension AppState {
    /// Language the pack starts in: the project's original language, falling
    /// back to the interface language for a project without one.
    var resolvePackDefaultLanguageCode: String {
        let projectCode = DurationLanguage.normalized(project.primaryLanguage)
        if !projectCode.isEmpty { return projectCode }
        return currentLanguage.contentLanguageCode
    }

    /// Original language plus every translated variant that has text in at
    /// least one scene.
    var resolvePackLanguageOptions: [ResolvePackLanguageOption] {
        let original = resolvePackDefaultLanguageCode
        var codes: [String] = []
        func add(_ raw: String) {
            let code = DurationLanguage.normalized(raw)
            guard !code.isEmpty, !codes.contains(code) else { return }
            codes.append(code)
        }
        add(original)
        for scene in project.scenes {
            for variant in scene.languageVariants
            where !variant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(variant.languageCode)
            }
        }
        return codes.map { code in
            ResolvePackLanguageOption(
                code: code,
                isOriginal: code == DurationLanguage.normalized(original)
            )
        }
    }

    /// Current rhythm warnings from the shared review cache, keyed by scene.
    /// Reading `RhythmReviewCenter.shared.revision` when building a plan makes
    /// the sheet refresh when an analysis pass finishes.
    func resolvePackRhythmWarnings() -> [UUID: [RhythmWarning]] {
        var warnings: [UUID: [RhythmWarning]] = [:]
        for scene in project.scenes {
            let sceneWarnings = RhythmReviewCenter.shared.warnings(for: scene.id)
            let projectWarnings = RhythmReviewCenter.shared.projectWarnings(for: scene.id)
            if !sceneWarnings.isEmpty || !projectWarnings.isEmpty {
                warnings[scene.id] = sceneWarnings + projectWarnings
            }
        }
        return warnings
    }

    /// Builds the plan the sheet previews. Returns `nil` only for an invalid
    /// start timecode or an empty file selection.
    func makeResolvePackPlan(
        configuration: ResolvePackConfiguration,
        rhythmWarnings: [UUID: [RhythmWarning]]? = nil
    ) -> ResolvePackPlan? {
        guard hasOpenProject, let options = configuration.options() else { return nil }
        let normalized = DurationLanguage.normalized(configuration.languageCode)
        let language = normalized.isEmpty ? resolvePackDefaultLanguageCode : normalized
        let mapper = ResolveSceneMapper(
            languageCode: language,
            durationSource: configuration.durationSource,
            wordsPerMinute: effectiveWPM(language: language),
            pauseDefaults: DurationEstimator.pauseDefaults(settings: settings),
            frameRate: configuration.rate.frameRate,
            rhythmWarningsByScene: rhythmWarnings ?? resolvePackRhythmWarnings(),
            chapterOverrides: publishingCoreOverrides(
                publishingPack(language: language).chapterOverrides
            )
        )
        let mapping = mapper.map(project: project)
        let chapterPlan = publishingChapterPlan(language: language)
        let rate = configuration.rate.frameRate
        let chapters = ChapterList(
            chapters: chapterPlan.chapters.map { chapter in
                Chapter(
                    startFrame: Timecode(seconds: TimeInterval(chapter.startSeconds), rate: rate).frames,
                    startSeconds: chapter.startSeconds,
                    title: chapter.title,
                    position: chapter.position,
                    sceneID: chapter.sceneID
                )
            },
            text: chapterPlan.text,
            warnings: chapterPlan.warnings,
            videoEndSeconds: chapterPlan.videoEndSeconds
        )
        return ResolveDeliveryPack.plan(
            scenes: mapping.scenes,
            projectName: project.title,
            options: options,
            extraWarnings: mapping.warnings,
            extraWarningItems: mapping.warningItems,
            chapters: chapters
        )
    }

    /// Writes the pack into `<Project>_resolve/` under `parentFolder`.
    @discardableResult
    func exportResolvePack(_ plan: ResolvePackPlan, to parentFolder: URL) throws -> URL {
        try securityScope.withAccess(to: parentFolder) {
            try ResolveDeliveryPack.write(plan, to: parentFolder)
        }
    }

    /// Last-used export location for the folder chooser, when configured.
    var resolvePackDefaultFolder: URL? {
        resolvedDefaultExportFolder()
    }
}
