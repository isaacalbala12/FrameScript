import Foundation
import FrameScriptCore
import UniformTypeIdentifiers

extension UTType {
    static let frameScript = UTType(exportedAs: "com.drashko.framescript.project", conformingTo: .json)
    static let frameScriptLegacy = UTType(filenameExtension: "framescript") ?? UTType(importedAs: "com.drashko.framescript.legacy-project", conformingTo: .json)
}

/// The app keeps its `@Observable` model classes; the on-disk document lives in
/// `FrameScriptCore`. These aliases keep the file-facing names used by the app
/// and its tests while the format itself has a single owner.
typealias FrameScriptFile = FrameScriptDocument
typealias FrameScriptFileError = FrameScriptDocumentError

// App model types, disambiguated from the nested document types inside the
// mapping extensions below.
typealias AppTextAnchor = TextAnchor
typealias AppTextSegment = TextSegment
typealias AppAIComment = AIComment
typealias AppBRollItem = BRollItem
typealias AppEditingItem = EditingItem
typealias AppScene = Scene
typealias AppTake = Take
typealias AppSceneLanguageVariant = SceneLanguageVariant
typealias AppProjectAsset = ProjectAsset
typealias AppChapterOverride = ChapterOverride
typealias AppThumbnailVariant = ThumbnailVariant
typealias AppPublishingPack = PublishingPack
typealias AppChecklistTask = ChecklistTask
typealias AppClaim = ProjectClaim
typealias AppComparisonTable = ComparisonTable
typealias AppGlossaryTerm = GlossaryTerm
typealias AppShortClip = ShortClip
typealias AppVersionSnapshot = VersionSnapshot
typealias AppPublishedVideoComparison = PublishedVideoComparison
typealias AppTranscriptSegment = TranscriptSegment
typealias AppRetentionPoint = RetentionPoint
typealias AppProjectSettingsOverride = ProjectSettingsOverride
typealias AppExportPreset = ExportPreset
typealias AppAIThreadMap = AIThreadMap
typealias AppUnparsedSection = UnparsedSection

typealias AppSectionType = SectionType
typealias AppSegmentType = SegmentType
typealias AppBRollSourceType = BRollSourceType
typealias AppBRollStatus = BRollStatus
typealias AppAICommentStatus = AICommentStatus
typealias AppAICommentSeverity = AICommentSeverity
typealias AppEditingStatus = EditingStatus
typealias AppProductionStatus = ProductionStatus
typealias AppTakeRating = TakeRating
typealias AppAssetKind = AssetKind
typealias AppClaimStatus = ClaimStatus
typealias AppChecklistTaskKind = ChecklistTaskKind
typealias AppShortClipFormat = ShortClipFormat
typealias AppShortClipStatus = ShortClipStatus
typealias AppExportFormat = ExportFormat

// MARK: - Project document <-> app model

extension FrameScriptDocument {
    init(project: FrameProject) {
        self.init(
            fileVersion: FrameScriptFormat.currentFileVersion,
            project: FrameScriptDocument.Project(project: project)
        )
    }

    /// Migrates legacy versions, then maps the document to the app model.
    func makeProject() throws -> FrameProject {
        try migrated().project.makeProject()
    }
}

extension FrameScriptDocument.Project {
    init(project: FrameProject) {
        self.init(
            id: project.id,
            title: project.title,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            templateID: project.templateID,
            settingsOverride: project.settingsOverride.map(FrameScriptDocument.ProjectSettingsOverride.init(override:)),
            exportPresets: project.exportPresets.map(FrameScriptDocument.ExportPreset.init(preset:)),
            scenes: project.scenes.sortedByOrder.map(FrameScriptDocument.Scene.init(scene:)),
            topic: project.topic,
            videoType: project.videoType,
            productionStatus: FrameScriptDocument.ProductionStatus(rawValue: project.productionStatus.rawValue) ?? .idea,
            targetDate: project.targetDate,
            publishDate: project.publishDate,
            targetDuration: project.targetDuration,
            learnedWordsPerMinuteByLanguage: project.learnedWordsPerMinuteByLanguage,
            assets: project.assets.map(FrameScriptDocument.ProjectAsset.init(asset:)),
            publishingPacks: project.publishingPacks.mapValues(FrameScriptDocument.PublishingPack.init(pack:)),
            checklistTasks: project.checklistTasks.map(FrameScriptDocument.ChecklistTask.init(task:)),
            sources: project.sources.map(FrameScriptDocument.Source.init(source:)),
            claims: project.claims.map(FrameScriptDocument.Claim.init(claim:)),
            comparisonTables: project.comparisonTables.map(FrameScriptDocument.ComparisonTable.init(table:)),
            glossary: project.glossary.map(FrameScriptDocument.GlossaryTerm.init(term:)),
            clips: project.clips.map(FrameScriptDocument.ShortClip.init(clip:)),
            versionHistory: project.versionHistory.map(FrameScriptDocument.VersionSnapshot.init(snapshot:)),
            aiThreadMap: FrameScriptDocument.AIThreadMap(
                t3ProjectID: project.aiThreadMap.t3ProjectID,
                threadIDsByProviderModel: project.aiThreadMap.threadIDsByProviderModel
            ),
            unparsedSections: project.unparsedSections.map(FrameScriptDocument.UnparsedSection.init(section:)),
            publishedVideos: project.publishedVideos.mapValues(FrameScriptDocument.PublishedVideoComparison.init(comparison:))
        )
    }

    func makeProject() -> FrameProject {
        FrameProject(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            templateID: templateID,
            scenes: scenes.map { $0.makeScene() },
            settingsOverride: settingsOverride.map { $0.makeOverride() },
            exportPresets: exportPresets.map { $0.makePreset() },
            topic: topic,
            videoType: videoType,
            productionStatus: AppProductionStatus(rawValue: productionStatus.rawValue) ?? .idea,
            targetDate: targetDate,
            publishDate: publishDate,
            targetDuration: targetDuration,
            learnedWordsPerMinuteByLanguage: learnedWordsPerMinuteByLanguage,
            assets: assets.map { $0.makeAsset() },
            publishingPacks: publishingPacks.mapValues { $0.makePack() },
            checklistTasks: checklistTasks.map { $0.makeTask() },
            sources: sources.map { $0.makeSource() },
            claims: claims.map { $0.makeClaim() },
            comparisonTables: comparisonTables.map { $0.makeTable() },
            glossary: glossary.map { $0.makeTerm() },
            clips: clips.map { $0.makeClip() },
            versionHistory: versionHistory.map { $0.makeSnapshot() },
            aiThreadMap: AppAIThreadMap(
                t3ProjectID: aiThreadMap.t3ProjectID,
                threadIDsByProviderModel: aiThreadMap.threadIDsByProviderModel
            ),
            unparsedSections: unparsedSections.map { AppUnparsedSection(heading: $0.heading, body: $0.body) },
            publishedVideos: publishedVideos.mapValues { $0.makeComparison() }
        )
    }
}

// MARK: - Scene

extension FrameScriptDocument.Scene {
    init(scene: AppScene) {
        self.init(
            id: scene.id,
            order: scene.order,
            sectionType: FrameScriptDocument.SectionType(rawValue: scene.sectionType.rawValue) ?? .custom,
            title: scene.title,
            scriptText: scene.scriptText,
            notes: scene.notes,
            estimatedDuration: scene.estimatedDuration,
            textSegments: scene.textSegments.sortedByOrder.map(FrameScriptDocument.TextSegment.init(segment:)),
            aiComments: scene.aiComments.map(FrameScriptDocument.AIComment.init(comment:)),
            bRollItems: scene.bRollItems.map(FrameScriptDocument.BRollItem.init(item:)),
            editingItems: scene.editingItems.map(FrameScriptDocument.EditingItem.init(item:)),
            targetDuration: scene.targetDuration,
            takes: scene.takes.map(FrameScriptDocument.Take.init(take:)),
            languageVariants: scene.languageVariants.map(FrameScriptDocument.SceneLanguageVariant.init(variant:)),
            obsSceneName: scene.obsSceneName
        )
    }

    func makeScene() -> AppScene {
        AppScene(
            id: id,
            order: order,
            sectionType: AppSectionType(rawValue: sectionType.rawValue) ?? .custom,
            title: title,
            scriptText: scriptText,
            notes: notes,
            estimatedDuration: estimatedDuration,
            textSegments: textSegments.map { $0.makeSegment() },
            aiComments: aiComments.map { $0.makeComment() },
            bRollItems: bRollItems.map { $0.makeBRollItem() },
            editingItems: editingItems.map { $0.makeEditingItem() },
            targetDuration: targetDuration,
            takes: takes.map { $0.makeTake() },
            languageVariants: languageVariants.map { $0.makeVariant() },
            obsSceneName: obsSceneName
        )
    }
}

// MARK: - Script data

extension FrameScriptDocument.TextAnchor {
    init(anchor: AppTextAnchor) {
        self.init(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
    }

    func makeAnchor() -> AppTextAnchor {
        AppTextAnchor(
            startUTF16: startUTF16,
            lengthUTF16: lengthUTF16,
            selectedText: selectedText,
            prefixContext: prefixContext,
            suffixContext: suffixContext
        )
    }
}

extension FrameScriptDocument.TextSegment {
    init(segment: AppTextSegment) {
        self.init(
            id: segment.id,
            sceneID: segment.sceneID,
            order: segment.order,
            sourceText: segment.sourceText,
            segmentType: FrameScriptDocument.SegmentType(rawValue: segment.segmentType.rawValue) ?? .scene,
            timingEstimate: segment.timingEstimate
        )
    }

    func makeSegment() -> AppTextSegment {
        AppTextSegment(
            id: id,
            sceneID: sceneID,
            order: order,
            sourceText: sourceText,
            segmentType: AppSegmentType(rawValue: segmentType.rawValue) ?? .scene,
            timingEstimate: timingEstimate
        )
    }
}

extension FrameScriptDocument.AIComment {
    init(comment: AppAIComment) {
        self.init(
            id: comment.id,
            sceneID: comment.sceneID,
            segmentID: comment.segmentID,
            type: comment.type,
            severity: FrameScriptDocument.AICommentSeverity(rawValue: comment.severity.rawValue) ?? .note,
            message: comment.message,
            suggestion: comment.suggestion,
            status: FrameScriptDocument.AICommentStatus(rawValue: comment.status.rawValue) ?? .new
        )
    }

    func makeComment() -> AppAIComment {
        AppAIComment(
            id: id,
            sceneID: sceneID,
            segmentID: segmentID,
            type: type,
            severity: AppAICommentSeverity(rawValue: severity.rawValue) ?? .note,
            message: message,
            suggestion: suggestion,
            status: AppAICommentStatus(rawValue: status.rawValue) ?? .new
        )
    }
}

// MARK: - Visuals and editing

extension FrameScriptDocument.BRollItem {
    init(item: AppBRollItem) {
        self.init(
            id: item.id,
            textAnchor: item.textAnchor.map(FrameScriptDocument.TextAnchor.init(anchor:)),
            linkedSegmentID: item.linkedSegmentID,
            templateType: item.templateType,
            sourceType: FrameScriptDocument.BRollSourceType(rawValue: item.sourceType.rawValue) ?? .custom,
            descriptionText: item.descriptionText,
            mood: item.mood,
            framing: item.framing,
            motion: item.motion,
            duration: item.duration,
            notes: item.notes,
            status: FrameScriptDocument.BRollStatus(rawValue: item.status.rawValue) ?? .idea
        )
    }

    func makeBRollItem() -> AppBRollItem {
        AppBRollItem(
            id: id,
            textAnchor: textAnchor?.makeAnchor(),
            linkedSegmentID: linkedSegmentID,
            templateType: templateType,
            sourceType: AppBRollSourceType(rawValue: sourceType.rawValue) ?? .custom,
            descriptionText: descriptionText,
            mood: mood,
            framing: framing,
            motion: motion,
            duration: duration,
            notes: notes,
            status: AppBRollStatus(rawValue: status.rawValue) ?? .idea
        )
    }
}

extension FrameScriptDocument.EditingItem {
    init(item: AppEditingItem) {
        self.init(
            id: item.id,
            textAnchor: item.textAnchor.map(FrameScriptDocument.TextAnchor.init(anchor:)),
            linkedSegmentID: item.linkedSegmentID,
            templateType: item.templateType,
            cutStyle: item.cutStyle,
            transition: item.transition,
            subtitleStyle: item.subtitleStyle,
            emphasis: item.emphasis,
            zoom: item.zoom,
            sfx: item.sfx,
            musicCue: item.musicCue,
            graphics: item.graphics,
            notes: item.notes,
            status: FrameScriptDocument.EditingStatus(rawValue: item.status.rawValue) ?? .pending
        )
    }

    func makeEditingItem() -> AppEditingItem {
        AppEditingItem(
            id: id,
            textAnchor: textAnchor?.makeAnchor(),
            linkedSegmentID: linkedSegmentID,
            templateType: templateType,
            cutStyle: cutStyle,
            transition: transition,
            subtitleStyle: subtitleStyle,
            emphasis: emphasis,
            zoom: zoom,
            sfx: sfx,
            musicCue: musicCue,
            graphics: graphics,
            notes: notes,
            status: AppEditingStatus(rawValue: status.rawValue) ?? .pending
        )
    }
}

// MARK: - Recording and variants

extension FrameScriptDocument.Take {
    init(take: AppTake) {
        self.init(
            id: take.id,
            number: take.number,
            startedAt: take.startedAt,
            duration: take.duration,
            filePath: take.filePath,
            bookmarkData: take.bookmarkData,
            rating: FrameScriptDocument.TakeRating(rawValue: take.rating.rawValue) ?? .unrated,
            note: take.note,
            languageCode: take.languageCode
        )
    }

    func makeTake() -> AppTake {
        AppTake(
            id: id,
            number: number,
            startedAt: startedAt,
            duration: duration,
            filePath: filePath,
            bookmarkData: bookmarkData,
            rating: AppTakeRating(rawValue: rating.rawValue) ?? .unrated,
            note: note,
            languageCode: languageCode
        )
    }
}

extension FrameScriptDocument.SceneLanguageVariant {
    init(variant: AppSceneLanguageVariant) {
        self.init(
            languageCode: variant.languageCode,
            text: variant.text,
            sourceHash: variant.sourceHash,
            takes: variant.takes.map(FrameScriptDocument.Take.init(take:)),
            estimatedDuration: variant.estimatedDuration,
            actualDuration: variant.actualDuration
        )
    }

    func makeVariant() -> AppSceneLanguageVariant {
        AppSceneLanguageVariant(
            languageCode: languageCode,
            text: text,
            sourceHash: sourceHash,
            takes: takes.map { $0.makeTake() },
            estimatedDuration: estimatedDuration,
            actualDuration: actualDuration
        )
    }
}

// MARK: - Production assets and publishing

extension FrameScriptDocument.ProjectAsset {
    init(asset: AppProjectAsset) {
        self.init(
            id: asset.id,
            path: asset.path,
            bookmarkData: asset.bookmarkData,
            kind: FrameScriptDocument.AssetKind(rawValue: asset.kind.rawValue) ?? .web,
            tags: asset.tags,
            linkedSceneIDs: asset.linkedSceneIDs,
            linkedBRollItemIDs: asset.linkedBRollItemIDs,
            linkedTakeIDs: asset.linkedTakeIDs,
            isCopiedIntoProject: asset.isCopiedIntoProject
        )
    }

    func makeAsset() -> AppProjectAsset {
        AppProjectAsset(
            id: id,
            path: path,
            bookmarkData: bookmarkData,
            kind: AppAssetKind(rawValue: kind.rawValue) ?? .web,
            tags: tags,
            linkedSceneIDs: linkedSceneIDs,
            linkedBRollItemIDs: linkedBRollItemIDs,
            linkedTakeIDs: linkedTakeIDs,
            isCopiedIntoProject: isCopiedIntoProject
        )
    }
}

extension FrameScriptDocument.ChapterOverride {
    init(override: AppChapterOverride) {
        self.init(
            id: override.id,
            sceneID: override.sceneID,
            title: override.title,
            startSeconds: override.startSeconds,
            isExcluded: override.isExcluded
        )
    }

    func makeOverride() -> AppChapterOverride {
        AppChapterOverride(
            id: id,
            sceneID: sceneID,
            title: title,
            startSeconds: startSeconds,
            isExcluded: isExcluded
        )
    }
}

extension FrameScriptDocument.ThumbnailVariant {
    init(variant: AppThumbnailVariant) {
        self.init(
            id: variant.id,
            assetID: variant.assetID,
            pairedTitle: variant.pairedTitle,
            isChosen: variant.isChosen
        )
    }

    func makeVariant() -> AppThumbnailVariant {
        AppThumbnailVariant(
            id: id,
            assetID: assetID,
            pairedTitle: pairedTitle,
            isChosen: isChosen
        )
    }
}

extension FrameScriptDocument.PublishingPack {
    init(pack: AppPublishingPack) {
        self.init(
            titleCandidates: pack.titleCandidates,
            chosenTitle: pack.chosenTitle,
            description: pack.description,
            tags: pack.tags,
            hashtags: pack.hashtags,
            pinnedComment: pack.pinnedComment,
            communityPost: pack.communityPost,
            chapterOverrides: pack.chapterOverrides.map(FrameScriptDocument.ChapterOverride.init(override:)),
            thumbnailVariants: pack.thumbnailVariants.map(FrameScriptDocument.ThumbnailVariant.init(variant:)),
            thumbnailConceptNotes: pack.thumbnailConceptNotes
        )
    }

    func makePack() -> AppPublishingPack {
        AppPublishingPack(
            titleCandidates: titleCandidates,
            chosenTitle: chosenTitle,
            description: description,
            tags: tags,
            hashtags: hashtags,
            pinnedComment: pinnedComment,
            communityPost: communityPost,
            chapterOverrides: chapterOverrides.map { $0.makeOverride() },
            thumbnailVariants: thumbnailVariants.map { $0.makeVariant() },
            thumbnailConceptNotes: thumbnailConceptNotes
        )
    }
}

// MARK: - Checklist, research and comparison

extension FrameScriptDocument.ChecklistTask {
    init(task: AppChecklistTask) {
        self.init(
            id: task.id,
            text: task.text,
            kind: FrameScriptDocument.ChecklistTaskKind(rawValue: task.kind.rawValue) ?? .other,
            isDone: task.isDone,
            sceneID: task.sceneID
        )
    }

    func makeTask() -> AppChecklistTask {
        AppChecklistTask(
            id: id,
            text: text,
            kind: AppChecklistTaskKind(rawValue: kind.rawValue) ?? .other,
            isDone: isDone,
            sceneID: sceneID
        )
    }
}

extension FrameScriptDocument.Source {
    init(source: ProjectSource) {
        self.init(id: source.id, title: source.title, url: source.url, note: source.note)
    }

    func makeSource() -> ProjectSource {
        ProjectSource(id: id, title: title, url: url, note: note)
    }
}

extension FrameScriptDocument.Claim {
    init(claim: AppClaim) {
        self.init(
            id: claim.id,
            text: claim.text,
            status: FrameScriptDocument.ClaimStatus(rawValue: claim.status.rawValue) ?? .probable,
            sourceIDs: claim.sourceIDs,
            sceneIDs: claim.sceneIDs
        )
    }

    func makeClaim() -> AppClaim {
        AppClaim(
            id: id,
            text: text,
            status: AppClaimStatus(rawValue: status.rawValue) ?? .probable,
            sourceIDs: sourceIDs,
            sceneIDs: sceneIDs
        )
    }
}

extension FrameScriptDocument.ComparisonTable {
    init(table: AppComparisonTable) {
        self.init(id: table.id, title: table.title, header: table.header, rows: table.rows)
    }

    func makeTable() -> AppComparisonTable {
        AppComparisonTable(id: id, title: title, header: header, rows: rows)
    }
}

extension FrameScriptDocument.GlossaryTerm {
    init(term: AppGlossaryTerm) {
        self.init(id: term.id, source: term.source, target: term.target, isProtected: term.isProtected)
    }

    func makeTerm() -> AppGlossaryTerm {
        AppGlossaryTerm(id: id, source: source, target: target, isProtected: isProtected)
    }
}

// MARK: - Short clips

extension FrameScriptDocument.ShortClip {
    init(clip: AppShortClip) {
        self.init(
            id: clip.id,
            title: clip.title,
            sourceSceneIDs: clip.sourceSceneIDs,
            anchorSceneID: clip.anchorSceneID,
            anchor: clip.anchor.map(FrameScriptDocument.TextAnchor.init(anchor:)),
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            targetSeconds: clip.targetSeconds,
            format: FrameScriptDocument.ShortClipFormat(rawValue: clip.format.rawValue) ?? .reel,
            onScreenText: clip.onScreenText,
            description: clip.description,
            hashtags: clip.hashtags,
            sourceHash: clip.sourceHash,
            status: FrameScriptDocument.ShortClipStatus(rawValue: clip.status.rawValue) ?? .idea
        )
    }

    func makeClip() -> AppShortClip {
        AppShortClip(
            id: id,
            title: title,
            sourceSceneIDs: sourceSceneIDs,
            anchorSceneID: anchorSceneID,
            anchor: anchor?.makeAnchor(),
            hook: hook,
            adaptedText: adaptedText,
            targetSeconds: targetSeconds,
            format: AppShortClipFormat(rawValue: format.rawValue) ?? .reel,
            onScreenText: onScreenText,
            description: description,
            hashtags: hashtags,
            sourceHash: sourceHash,
            status: AppShortClipStatus(rawValue: status.rawValue) ?? .idea
        )
    }
}

// MARK: - History, AI threads and import leftovers

extension FrameScriptDocument.VersionSnapshot {
    init(snapshot: AppVersionSnapshot) {
        self.init(
            id: snapshot.id,
            createdAt: snapshot.createdAt,
            name: snapshot.name,
            isAutomatic: snapshot.isAutomatic,
            label: snapshot.label,
            compressedPayload: snapshot.compressedPayload
        )
    }

    func makeSnapshot() -> AppVersionSnapshot {
        AppVersionSnapshot(
            id: id,
            createdAt: createdAt,
            name: name,
            isAutomatic: isAutomatic,
            label: label,
            compressedPayload: compressedPayload
        )
    }
}

extension FrameScriptDocument.UnparsedSection {
    init(section: UnparsedSection) {
        self.init(heading: section.heading, body: section.body)
    }
}

// MARK: - Published-video comparison

extension FrameScriptDocument.TranscriptSegment {
    init(segment: AppTranscriptSegment) {
        self.init(start: segment.start, end: segment.end, text: segment.text)
    }

    func makeSegment() -> AppTranscriptSegment {
        AppTranscriptSegment(start: start, end: end, text: text)
    }
}

extension FrameScriptDocument.RetentionPoint {
    init(point: AppRetentionPoint) {
        self.init(time: point.time, percent: point.percent)
    }

    func makePoint() -> AppRetentionPoint {
        AppRetentionPoint(time: time, percent: percent)
    }
}

extension FrameScriptDocument.PublishedVideoComparison {
    init(comparison: AppPublishedVideoComparison) {
        self.init(
            transcriptSegments: comparison.transcriptSegments.map(FrameScriptDocument.TranscriptSegment.init(segment:)),
            retentionPoints: comparison.retentionPoints.map(FrameScriptDocument.RetentionPoint.init(point:)),
            importedAt: comparison.importedAt
        )
    }

    func makeComparison() -> AppPublishedVideoComparison {
        AppPublishedVideoComparison(
            transcriptSegments: transcriptSegments.map { $0.makeSegment() },
            retentionPoints: retentionPoints.map { $0.makePoint() },
            importedAt: importedAt
        )
    }
}

// MARK: - Settings override and export presets

extension FrameScriptDocument.ProjectSettingsOverride {
    init(override: AppProjectSettingsOverride) {
        self.init(
            wordsPerMinute: override.wordsPerMinute,
            defaultSplitMode: override.defaultSplitMode.flatMap { FrameScriptDocument.SegmentType(rawValue: $0.rawValue) },
            longSentenceWordLimit: override.longSentenceWordLimit,
            uncoveredSecondsLimit: override.uncoveredSecondsLimit,
            sceneLengthRatioLimit: override.sceneLengthRatioLimit,
            hookSecondsLimit: override.hookSecondsLimit
        )
    }

    func makeOverride() -> AppProjectSettingsOverride {
        AppProjectSettingsOverride(
            wordsPerMinute: wordsPerMinute,
            defaultSplitMode: defaultSplitMode.flatMap { AppSegmentType(rawValue: $0.rawValue) },
            longSentenceWordLimit: longSentenceWordLimit,
            uncoveredSecondsLimit: uncoveredSecondsLimit,
            sceneLengthRatioLimit: sceneLengthRatioLimit,
            hookSecondsLimit: hookSecondsLimit
        )
    }
}

extension FrameScriptDocument.ExportPreset {
    init(preset: AppExportPreset) {
        self.init(
            id: preset.id,
            name: preset.name,
            format: FrameScriptDocument.ExportFormat(rawValue: preset.format.rawValue) ?? .productionOutline
        )
    }

    func makePreset() -> AppExportPreset {
        AppExportPreset(
            id: id,
            name: name,
            format: AppExportFormat(rawValue: format.rawValue) ?? .productionOutline
        )
    }
}

// MARK: - Store facade

enum FrameScriptFileStore {
    static var encoder: JSONEncoder {
        FrameScriptDocumentCodec.makeEncoder()
    }

    static var decoder: JSONDecoder {
        FrameScriptDocumentCodec.makeDecoder()
    }

    static func write(project: FrameProject, to url: URL) throws {
        try FrameScriptDocumentCodec.write(FrameScriptDocument(project: project), to: url)
    }

    static func read(from url: URL) throws -> FrameProject {
        try FrameScriptDocumentCodec.read(from: url).project.makeProject()
    }

    static func encode(project: FrameProject) throws -> Data {
        try FrameScriptDocumentCodec.encode(FrameScriptDocument(project: project))
    }

    static func decodeProject(from data: Data) throws -> FrameProject {
        try FrameScriptDocumentCodec.decode(data).project.makeProject()
    }
}
