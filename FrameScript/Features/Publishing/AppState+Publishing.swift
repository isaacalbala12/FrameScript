import AppKit
import Foundation
import FrameScriptCore
import SwiftUI

// MARK: - Publishing state for the app

@MainActor
extension AppState {
    // MARK: - Presentation

    func showPublishingPanel() {
        PublishingPresentation.shared.resetTitleGeneration()
        PublishingPresentation.shared.isPresented = true
    }

    // MARK: - Languages

    /// Primary language, every translated variant and every language that
    /// already has a pack. Case-insensitive duplicates keep the first spelling.
    var publishingAvailableLanguageCodes: [String] {
        var seen = Set<String>()
        var codes: [String] = []
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = DurationLanguage.normalized(trimmed)
            guard seen.insert(key).inserted else { return }
            codes.append(trimmed)
        }

        append(project.primaryLanguage)
        for scene in project.scenes.sortedByOrder {
            for variant in scene.languageVariants {
                append(variant.languageCode)
            }
        }
        for code in project.publishingPacks.keys.sorted() {
            append(code)
        }
        if codes.isEmpty { codes = ["es"] }
        return codes
    }

    func publishingLanguageDisplayName(_ code: String) -> String {
        let locale = Locale(identifier: currentLanguage.contentLanguageCode)
        let name = locale.localizedString(forLanguageCode: code)?.capitalized(with: locale)
        return "\(name ?? code.uppercased()) (\(code))"
    }

    func publishingStorageKey(for language: String) -> String {
        let normalized = DurationLanguage.normalized(language)
        if let existing = project.publishingPacks.keys.first(where: {
            DurationLanguage.normalized($0) == normalized
        }) {
            return existing
        }
        return language
    }

    // MARK: - Pack access

    func publishingPack(language: String) -> PublishingPack {
        let normalized = DurationLanguage.normalized(language)
        if let pack = project.publishingPacks[language] { return pack }
        if let key = project.publishingPacks.keys.first(where: {
            DurationLanguage.normalized($0) == normalized
        }) {
            return project.publishingPacks[key] ?? PublishingPack()
        }
        return PublishingPack()
    }

    func updatePublishingPack(language: String, _ mutate: (inout PublishingPack) -> Void) {
        let key = publishingStorageKey(for: language)
        var pack = project.publishingPacks[key] ?? PublishingPack()
        mutate(&pack)
        project.publishingPacks[key] = pack
        touchProject()
    }

    func publishingStringBinding(
        _ keyPath: WritableKeyPath<PublishingPack, String>,
        language: String
    ) -> Binding<String> {
        Binding(
            get: { self.publishingPack(language: language)[keyPath: keyPath] },
            set: { value in
                self.updatePublishingPack(language: language) { $0[keyPath: keyPath] = value }
            }
        )
    }

    func publishingArrayBinding(
        _ keyPath: WritableKeyPath<PublishingPack, [String]>,
        language: String
    ) -> Binding<[String]> {
        Binding(
            get: { self.publishingPack(language: language)[keyPath: keyPath] },
            set: { value in
                self.updatePublishingPack(language: language) { $0[keyPath: keyPath] = value }
            }
        )
    }

    // MARK: - Promise and thesis

    var publishingNotes: EscaletaProjectNotes {
        EscaletaProjectNotes.decode(project.topic)
    }

    var publishingPromise: String {
        publishingNotes.promise ?? ""
    }

    var publishingThesis: String {
        publishingNotes.thesis ?? ""
    }

    func setPublishingPromise(_ value: String) {
        var notes = publishingNotes
        notes.promise = PublishingText.nonEmpty(value)
        project.topic = notes.encoded()
        touchProject()
    }

    func setPublishingThesis(_ value: String) {
        var notes = publishingNotes
        notes.thesis = PublishingText.nonEmpty(value)
        project.topic = notes.encoded()
        touchProject()
    }

    // MARK: - Chapters

    func publishingChapterPlan(language: String, ignoringOverrideTitles: Bool = false) -> ChapterPlan {
        let overrides = PublishingChapters.overridesByScene(
            publishingCoreOverrides(publishingPack(language: language).chapterOverrides)
        )
        let inputs = project.scenes.sortedByOrder.map { scene in
            let override = overrides[scene.id]
            return ChapterSceneInput(
                sceneID: scene.id,
                title: scene.title,
                duration: publishingSceneDuration(scene: scene, language: language),
                overrideTitle: ignoringOverrideTitles
                    ? nil
                    : PublishingText.nonEmpty(override?.title ?? ""),
                isExcluded: override?.isExcluded ?? false
            )
        }
        return PublishingChapters.plan(scenes: inputs)
    }

    func publishingChapterDiff(language: String) -> ChapterRegenerationDiff {
        let pack = publishingPack(language: language)
        return PublishingChapters.diff(
            existing: publishingCoreOverrides(pack.chapterOverrides),
            plan: publishingChapterPlan(language: language, ignoringOverrideTitles: true)
        )
    }

    func applyPublishingChapterPlan(
        _ plan: ChapterPlan,
        language: String,
        keepingEditedTitles: Bool
    ) {
        updatePublishingPack(language: language) { pack in
            let generated = PublishingChapters.overrides(
                from: plan,
                existing: self.publishingCoreOverrides(pack.chapterOverrides),
                keepingEditedTitles: keepingEditedTitles
            )
            pack.chapterOverrides = generated.map(Self.appChapterOverride)
        }
    }

    func setPublishingChapterIncluded(_ included: Bool, sceneID: UUID, language: String) {
        updatePublishingPack(language: language) { pack in
            if let index = pack.chapterOverrides.firstIndex(where: { $0.sceneID == sceneID }) {
                pack.chapterOverrides[index].isExcluded = !included
            } else {
                pack.chapterOverrides.append(
                    ChapterOverride(sceneID: sceneID, title: "", isExcluded: !included)
                )
            }
        }
    }

    func setPublishingChapterTitle(_ title: String, sceneID: UUID, language: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updatePublishingPack(language: language) { pack in
            if let index = pack.chapterOverrides.firstIndex(where: { $0.sceneID == sceneID }) {
                pack.chapterOverrides[index].title = trimmed
            } else {
                pack.chapterOverrides.append(
                    ChapterOverride(sceneID: sceneID, title: trimmed, isExcluded: false)
                )
            }
        }
    }

    func resetPublishingChapterTitle(sceneID: UUID, language: String) {
        updatePublishingPack(language: language) { pack in
            guard let index = pack.chapterOverrides.firstIndex(where: { $0.sceneID == sceneID }) else {
                return
            }
            pack.chapterOverrides[index].title = ""
        }
    }

    func publishingChapterOverride(sceneID: UUID, language: String) -> ChapterOverride? {
        publishingPack(language: language).chapterOverrides.first { $0.sceneID == sceneID }
    }

    /// Duration the planner uses for one scene, with its provenance for the UI.
    func publishingSceneDurationInfo(
        scene: Scene,
        language: String
    ) -> (duration: TimeInterval, isReal: Bool) {
        let summary = sceneDurationSummary(for: scene, language: language)
        if let real = summary.real {
            return (max(0, real), true)
        }
        return (publishingSceneDuration(scene: scene, language: language), false)
    }

    // MARK: - Checklist

    func publishingChecklistIsDone(_ item: PublishingChecklistItem) -> Bool {
        project.checklistTasks.first { $0.text == item.taskToken }?.isDone ?? false
    }

    func setPublishingChecklist(_ item: PublishingChecklistItem, done: Bool) {
        if let index = project.checklistTasks.firstIndex(where: { $0.text == item.taskToken }) {
            project.checklistTasks[index].isDone = done
        } else {
            project.checklistTasks.append(
                ChecklistTask(text: item.taskToken, kind: .other, isDone: done)
            )
        }
        touchProject()
    }

    var publishingChecklistProgress: (done: Int, total: Int) {
        let done = PublishingChecklistItem.allCases.filter { publishingChecklistIsDone($0) }.count
        return (done, PublishingChecklistItem.allCases.count)
    }

    // MARK: - Thumbnails

    func publishingThumbnailURL(for variant: ThumbnailVariant) -> URL? {
        guard let assetID = variant.assetID,
              let asset = project.assets.first(where: { $0.id == assetID }) else {
            return nil
        }
        let path = asset.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        guard let directory = projectStore.currentFileURL?.deletingLastPathComponent() else {
            return nil
        }
        return ThumbnailAssetPath.resolvedURL(relativePath: path, projectDirectory: directory)
    }

    @discardableResult
    func addPublishingThumbnail(from url: URL, language: String) throws -> ThumbnailVariant {
        guard let fileURL = projectStore.currentFileURL else {
            throw ThumbnailFileStoreError.projectNotSaved
        }
        let projectName = fileURL.deletingPathExtension().lastPathComponent
        let result = try ThumbnailFileStore().copyThumbnail(
            from: url,
            projectName: projectName,
            projectDirectory: fileURL.deletingLastPathComponent(),
            existingPaths: Set(project.assets.map(\.path))
        )

        project.assets.append(result.asset)
        var pack = publishingPack(language: language)
        let variant = ThumbnailVariant(
            assetID: result.asset.id,
            pairedTitle: pack.chosenTitle,
            isChosen: pack.thumbnailVariants.isEmpty
        )
        pack.thumbnailVariants.append(variant)
        project.publishingPacks[publishingStorageKey(for: language)] = pack
        touchProject()
        return variant
    }

    func setPublishingThumbnailChosen(_ variantID: UUID, language: String) {
        updatePublishingPack(language: language) { pack in
            for index in pack.thumbnailVariants.indices {
                pack.thumbnailVariants[index].isChosen = pack.thumbnailVariants[index].id == variantID
            }
        }
    }

    func setPublishingThumbnailTitle(_ title: String, variantID: UUID, language: String) {
        updatePublishingPack(language: language) { pack in
            guard let index = pack.thumbnailVariants.firstIndex(where: { $0.id == variantID }) else {
                return
            }
            pack.thumbnailVariants[index].pairedTitle = title
        }
    }

    func removePublishingThumbnail(variantID: UUID, language: String) {
        updatePublishingPack(language: language) { pack in
            guard let index = pack.thumbnailVariants.firstIndex(where: { $0.id == variantID }) else {
                return
            }
            let wasChosen = pack.thumbnailVariants[index].isChosen
            pack.thumbnailVariants.remove(at: index)
            if wasChosen, !pack.thumbnailVariants.isEmpty {
                pack.thumbnailVariants[0].isChosen = true
            }
        }
    }

    func publishingThumbnailNotes(language: String) -> PublishingThumbnailNotes {
        PublishingThumbnailNotes.parse(publishingPack(language: language).thumbnailConceptNotes)
    }

    func setPublishingThumbnailNotes(_ notes: PublishingThumbnailNotes, language: String) {
        updatePublishingPack(language: language) { pack in
            pack.thumbnailConceptNotes = notes.rendered()
        }
    }

    // MARK: - Validation and export

    func publishingValidationIssues(language: String) -> [PublishingValidationIssue] {
        let pack = publishingPack(language: language)
        let concepts = PublishingThumbnailNotes.parse(pack.thumbnailConceptNotes).concepts
        return PublishingValidator.issues(
            for: PublishingValidationInput(
                title: pack.chosenTitle,
                description: pack.description,
                tags: pack.tags,
                hashtags: pack.hashtags,
                pinnedComment: pack.pinnedComment,
                thumbnailTexts: concepts.map(\.text)
            )
        )
    }

    func publishingExportInput(language: String) -> PublishingExportInput {
        let pack = publishingPack(language: language)
        let plan = publishingChapterPlan(language: language)
        return PublishingExportInput(
            projectTitle: project.title,
            promise: publishingPromise,
            thesis: publishingThesis,
            title: pack.chosenTitle,
            titleCandidates: pack.titleCandidates.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            thumbnailNotes: pack.thumbnailConceptNotes,
            description: pack.description,
            chapters: publishingEscaletaChapters(pack: pack, plan: plan),
            tags: pack.tags,
            hashtags: pack.hashtags,
            pinnedComment: pack.pinnedComment,
            communityPost: pack.communityPost,
            sources: project.sources.map { source in
                PublishingSource(
                    id: source.id,
                    title: source.title,
                    url: source.url,
                    note: source.note
                )
            }
        )
    }

    func publishingExportMarkdown(language: String) -> String {
        PublishingExport.make(publishingExportInput(language: language))
    }

    func publishingStudioDescription(language: String) -> String {
        PublishingExport.studioDescription(publishingExportInput(language: language))
    }

    func copyPublishingValue(_ field: PublishingField, language: String) {
        let value = PublishingExport.fieldValue(field, input: publishingExportInput(language: language))
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func copyPublishingText(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func savePublishingExport(language: String, to url: URL) {
        do {
            try publishingExportMarkdown(language: language).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorCenter.present(
                AppError(
                    kind: .export,
                    context: AppErrorContext(fileName: url.lastPathComponent),
                    recoveryAction: .chooseExportFolder
                )
            )
        }
    }

    // MARK: - AI titles

    func generatePublishingTitles(language: String) async {
        let presentation = PublishingPresentation.shared
        let provider = settings.aiPreferences.provider
        guard provider != .disabled else {
            errorCenter.present(AppError(kind: .aiConfiguration, recoveryAction: .openAISettings))
            return
        }
        guard !presentation.isGeneratingTitles else { return }

        presentation.isGeneratingTitles = true
        presentation.titleSuggestions = []
        presentation.titleGenerationError = nil
        defer { presentation.isGeneratingTitles = false }

        let ordered = project.scenes.sortedByOrder
        let opening = ordered.first?.scriptText ?? ""
        let context = PublishingTitleContext(
            projectTitle: project.title,
            promise: publishingPromise,
            thesis: publishingThesis,
            videoType: project.videoType,
            targetDuration: project.targetDuration.map(DurationEstimator.formatted) ?? "",
            sceneTitles: ordered.map(\.title),
            openingText: String(opening.prefix(2_000))
        )

        do {
            let apiKey = provider.isSubscriptionBacked
                ? ""
                : try providerAPIKey(for: provider)
            let response = try await dependencies.llmProvider.complete(
                request: LLMRequest(
                    task: .titlesSEO,
                    provider: provider,
                    baseURL: settings.aiPreferences.baseURL,
                    systemPrompt: PublishingTitlePrompt.systemPrompt(
                        languageName: publishingPromptLanguageName(language)
                    ),
                    userPrompt: PublishingTitlePrompt.userPrompt(context),
                    model: settings.aiPreferences.model,
                    temperature: settings.aiPreferences.temperature,
                    maxTokens: max(600, settings.aiPreferences.maxTokens)
                ),
                apiKey: apiKey
            )
            try Task.checkCancellation()
            let titles = PublishingTitleParser.parse(response.text)
            guard !titles.isEmpty else { throw GenerationError.invalidJSON }
            presentation.titleSuggestions = titles
        } catch is CancellationError {
            return
        } catch {
            if let appError = AppError.ai(error) {
                presentation.titleGenerationError = appError.presentation(language: currentLanguage).message
                errorCenter.present(appError)
            } else {
                presentation.titleGenerationError = error.localizedDescription
            }
        }
    }

    func addPublishingTitleSuggestions(_ titles: [String], language: String) {
        guard !titles.isEmpty else { return }
        updatePublishingPack(language: language) { pack in
            var seen = Set(pack.titleCandidates.map { $0.lowercased() })
            for title in titles {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert(trimmed.lowercased()).inserted else { continue }
                pack.titleCandidates.append(trimmed)
            }
        }
    }

    func usePublishingTitle(_ title: String, language: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updatePublishingPack(language: language) { pack in
            pack.chosenTitle = trimmed
            if !pack.titleCandidates.contains(where: {
                $0.caseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                pack.titleCandidates.append(trimmed)
            }
        }
    }

    // MARK: - Private helpers

    private func publishingCoreOverrides(
        _ overrides: [ChapterOverride]
    ) -> [FrameScriptDocument.ChapterOverride] {
        overrides.map { override in
            FrameScriptDocument.ChapterOverride(
                id: override.id,
                sceneID: override.sceneID,
                title: override.title,
                startSeconds: override.startSeconds,
                isExcluded: override.isExcluded
            )
        }
    }

    private static func appChapterOverride(
        _ override: FrameScriptDocument.ChapterOverride
    ) -> ChapterOverride {
        ChapterOverride(
            id: override.id,
            sceneID: override.sceneID,
            title: override.title,
            startSeconds: override.startSeconds,
            isExcluded: override.isExcluded
        )
    }

    private func publishingSceneDuration(scene: Scene, language: String) -> TimeInterval {
        let summary = sceneDurationSummary(for: scene, language: language)
        if let real = summary.real {
            return max(0, real)
        }

        let normalized = DurationLanguage.normalized(language)
        let primary = DurationLanguage.normalized(project.primaryLanguage)
        if normalized == primary {
            return max(0, summary.estimated)
        }
        if let variant = scene.languageVariants.first(where: {
            DurationLanguage.normalized($0.languageCode) == normalized
        }), !variant.text.isEmpty {
            return max(
                0,
                DurationEstimator.estimate(
                    text: variant.text,
                    configuration: durationConfiguration(forLanguage: language)
                )
            )
        }
        return max(0, summary.estimated)
    }

    private func publishingEscaletaChapters(
        pack: PublishingPack,
        plan: ChapterPlan
    ) -> [EscaletaChapter] {
        if !plan.chapters.isEmpty {
            return plan.chapters.map { chapter in
                EscaletaChapter(
                    seconds: chapter.startSeconds,
                    timestamp: DurationFormat.clock(seconds: chapter.startSeconds),
                    title: chapter.title
                )
            }
        }
        return pack.chapterOverrides
            .sorted { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }
            .compactMap { override in
                guard let start = override.startSeconds else { return nil }
                let seconds = Int(start.rounded())
                return EscaletaChapter(
                    seconds: seconds,
                    timestamp: DurationFormat.clock(seconds: seconds),
                    title: override.title
                )
            }
    }

    private func publishingPromptLanguageName(_ language: String) -> String {
        let appLanguage = HookContextBuilder.appLanguage(forPrimaryLanguageCode: language)
            ?? currentLanguage
        switch appLanguage {
        case .spanish: return "Spanish"
        case .russian: return "Russian"
        default: return "English"
        }
    }
}
