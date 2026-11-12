import Foundation

/// Shared identity remapping for project and scene duplication.
///
/// A copy must be independent: object identities and every cross-reference get
/// fresh IDs. String, date and enum payloads are copied verbatim.
struct ModelCopyContext {
    var sceneIDs: [UUID: UUID] = [:]
    var segmentIDs: [UUID: UUID] = [:]
    var visualIDs: [UUID: UUID] = [:]
    var takeIDs: [UUID: UUID] = [:]
    var assetIDs: [UUID: UUID] = [:]
    var sourceIDs: [UUID: UUID] = [:]

    mutating func prepare(project: FrameProject) {
        prepare(scenes: project.scenes)
        for asset in project.assets { assetIDs[asset.id] = UUID() }
        for source in project.sources { sourceIDs[source.id] = UUID() }
    }

    mutating func prepare(scenes: [Scene]) {
        for scene in scenes {
            sceneIDs[scene.id] = UUID()
            for segment in scene.textSegments { segmentIDs[segment.id] = UUID() }
            for item in scene.bRollItems { visualIDs[item.id] = UUID() }
            for take in scene.takes { takeIDs[take.id] = UUID() }
            for variant in scene.languageVariants {
                for take in variant.takes { takeIDs[take.id] = UUID() }
            }
        }
    }

    func sceneID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return sceneIDs[id] ?? id
    }

    func segmentID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return segmentIDs[id] ?? id
    }

    func visualID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return visualIDs[id] ?? id
    }

    func takeID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return takeIDs[id] ?? id
    }

    func assetID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return assetIDs[id] ?? id
    }

    func sourceID(_ id: UUID?) -> UUID? {
        guard let id else { return nil }
        return sourceIDs[id] ?? id
    }

    func sceneIDs(_ ids: [UUID]) -> [UUID] {
        ids.map { sceneIDs[$0] ?? $0 }
    }

    func visualIDs(_ ids: [UUID]) -> [UUID] {
        ids.map { visualIDs[$0] ?? $0 }
    }

    func takeIDs(_ ids: [UUID]) -> [UUID] {
        ids.map { takeIDs[$0] ?? $0 }
    }

    func sourceIDs(_ ids: [UUID]) -> [UUID] {
        ids.map { sourceIDs[$0] ?? $0 }
    }
}

extension FrameProject {
    func copied(title: String) -> FrameProject {
        var context = ModelCopyContext()
        context.prepare(project: self)

        return FrameProject(
            id: UUID(),
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            templateID: templateID,
            scenes: scenes.sortedByOrder.enumerated().map { index, scene in
                scene.copied(order: index, title: scene.title, context: &context)
            },
            settingsOverride: settingsOverride,
            exportPresets: exportPresets.map {
                ExportPreset(id: UUID(), name: $0.name, format: $0.format)
            },
            primaryLanguage: primaryLanguage,
            topic: topic,
            videoType: videoType,
            productionStatus: productionStatus,
            targetDate: targetDate,
            publishDate: publishDate,
            targetDuration: targetDuration,
            learnedWordsPerMinuteByLanguage: learnedWordsPerMinuteByLanguage,
            assets: assets.map { $0.copied(context: context) },
            publishingPacks: publishingPacks.mapValues { $0.copied(context: context) },
            checklistTasks: checklistTasks.map { $0.copied(context: context) },
            rhythmThresholdsOverride: rhythmThresholdsOverride,
            sources: sources.map { $0.copied(context: context) },
            claims: claims.map { $0.copied(context: context) },
            comparisonTables: comparisonTables.map { $0.copied() },
            glossary: glossary.map { $0.copied() },
            clips: clips.map { $0.copied(context: context) },
            versionHistory: versionHistory.map { $0.copied() },
            aiThreadMap: aiThreadMap,
            unparsedSections: unparsedSections,
            publishedVideos: publishedVideos.mapValues { $0.copied(context: context) }
        )
    }
}

extension Scene {
    func copied(order: Int, title: String) -> Scene {
        var context = ModelCopyContext()
        context.prepare(scenes: [self])
        return copied(order: order, title: title, context: &context)
    }

    func copied(order: Int, title: String, context: inout ModelCopyContext) -> Scene {
        let newSceneID = context.sceneIDs[id] ?? UUID()
        let sortedSegments = textSegments.sortedByOrder

        return Scene(
            id: newSceneID,
            order: order,
            sectionType: sectionType,
            title: title,
            scriptText: scriptText,
            notes: notes,
            estimatedDuration: estimatedDuration,
            textSegments: sortedSegments.enumerated().map { offset, segment in
                TextSegment(
                    id: context.segmentIDs[segment.id] ?? UUID(),
                    sceneID: newSceneID,
                    order: offset,
                    sourceText: segment.sourceText,
                    segmentType: segment.segmentType,
                    timingEstimate: segment.timingEstimate
                )
            },
            aiComments: aiComments.map {
                AIComment(
                    id: UUID(),
                    sceneID: newSceneID,
                    segmentID: context.segmentID($0.segmentID),
                    type: $0.type,
                    severity: $0.severity,
                    message: $0.message,
                    suggestion: $0.suggestion,
                    status: $0.status
                )
            },
            bRollItems: bRollItems.map {
                BRollItem(
                    id: context.visualIDs[$0.id] ?? UUID(),
                    textAnchor: $0.textAnchor,
                    linkedSegmentID: context.segmentID($0.linkedSegmentID),
                    templateType: $0.templateType,
                    sourceType: $0.sourceType,
                    descriptionText: $0.descriptionText,
                    mood: $0.mood,
                    framing: $0.framing,
                    motion: $0.motion,
                    duration: $0.duration,
                    notes: $0.notes,
                    status: $0.status
                )
            },
            editingItems: editingItems.map {
                EditingItem(
                    id: UUID(),
                    textAnchor: $0.textAnchor,
                    linkedSegmentID: context.segmentID($0.linkedSegmentID),
                    templateType: $0.templateType,
                    cutStyle: $0.cutStyle,
                    transition: $0.transition,
                    subtitleStyle: $0.subtitleStyle,
                    emphasis: $0.emphasis,
                    zoom: $0.zoom,
                    sfx: $0.sfx,
                    musicCue: $0.musicCue,
                    graphics: $0.graphics,
                    notes: $0.notes,
                    status: $0.status
                )
            },
            targetDuration: targetDuration,
            takes: takes.map { $0.copied(context: context) },
            languageVariants: languageVariants.map {
                SceneLanguageVariant(
                    languageCode: $0.languageCode,
                    text: $0.text,
                    sourceHash: $0.sourceHash,
                    takes: $0.takes.map { take in take.copied(context: context) },
                    estimatedDuration: $0.estimatedDuration,
                    actualDuration: $0.actualDuration
                )
            },
            obsSceneName: obsSceneName
        )
    }
}

extension Take {
    func copied(context: ModelCopyContext) -> Take {
        Take(
            id: context.takeIDs[id] ?? UUID(),
            number: number,
            startedAt: startedAt,
            duration: duration,
            filePath: filePath,
            bookmarkData: bookmarkData,
            rating: rating,
            note: note,
            languageCode: languageCode,
            readText: readText,
            sceneTextHash: sceneTextHash
        )
    }
}

extension ProjectAsset {
    func copied(context: ModelCopyContext) -> ProjectAsset {
        ProjectAsset(
            id: context.assetIDs[id] ?? UUID(),
            path: path,
            bookmarkData: bookmarkData,
            kind: kind,
            tags: tags,
            linkedSceneIDs: context.sceneIDs(linkedSceneIDs),
            linkedBRollItemIDs: context.visualIDs(linkedBRollItemIDs),
            linkedTakeIDs: context.takeIDs(linkedTakeIDs),
            isCopiedIntoProject: isCopiedIntoProject,
            duration: duration,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            isLastKnownMissing: isLastKnownMissing
        )
    }
}

extension PublishingPack {
    func copied(context: ModelCopyContext) -> PublishingPack {
        PublishingPack(
            titleCandidates: titleCandidates,
            chosenTitle: chosenTitle,
            description: description,
            tags: tags,
            hashtags: hashtags,
            pinnedComment: pinnedComment,
            communityPost: communityPost,
            chapterOverrides: chapterOverrides.map {
                ChapterOverride(
                    id: UUID(),
                    sceneID: context.sceneID($0.sceneID),
                    title: $0.title,
                    startSeconds: $0.startSeconds,
                    isExcluded: $0.isExcluded
                )
            },
            thumbnailVariants: thumbnailVariants.map {
                ThumbnailVariant(
                    id: UUID(),
                    assetID: context.assetID($0.assetID),
                    pairedTitle: $0.pairedTitle,
                    isChosen: $0.isChosen
                )
            },
            thumbnailConceptNotes: thumbnailConceptNotes
        )
    }
}

extension ChecklistTask {
    func copied(context: ModelCopyContext) -> ChecklistTask {
        ChecklistTask(
            id: UUID(),
            text: text,
            kind: kind,
            isDone: isDone,
            sceneID: context.sceneID(sceneID)
        )
    }
}

extension ProjectSource {
    func copied(context: ModelCopyContext) -> ProjectSource {
        ProjectSource(
            id: context.sourceIDs[id] ?? UUID(),
            title: title,
            url: url,
            note: note
        )
    }
}

extension ProjectClaim {
    func copied(context: ModelCopyContext) -> ProjectClaim {
        ProjectClaim(
            id: UUID(),
            text: text,
            status: status,
            sourceIDs: context.sourceIDs(sourceIDs),
            sceneIDs: context.sceneIDs(sceneIDs)
        )
    }
}

extension ComparisonTable {
    func copied() -> ComparisonTable {
        ComparisonTable(id: UUID(), title: title, header: header, rows: rows)
    }
}

extension GlossaryTerm {
    func copied() -> GlossaryTerm {
        GlossaryTerm(id: UUID(), source: source, target: target, isProtected: isProtected)
    }
}

extension ShortClip {
    func copied(context: ModelCopyContext) -> ShortClip {
        ShortClip(
            id: UUID(),
            title: title,
            sourceSceneIDs: context.sceneIDs(sourceSceneIDs),
            anchorSceneID: context.sceneID(anchorSceneID),
            anchor: anchor,
            hook: hook,
            adaptedText: adaptedText,
            targetSeconds: targetSeconds,
            format: format,
            onScreenText: onScreenText,
            description: description,
            hashtags: hashtags,
            sourceHash: sourceHash,
            languageCode: languageCode,
            sceneSourceHashes: sceneSourceHashes.map {
                ClipSceneSourceHash(sceneID: context.sceneID($0.sceneID) ?? $0.sceneID, hash: $0.hash)
            },
            status: status
        )
    }
}

extension VersionSnapshot {
    func copied() -> VersionSnapshot {
        VersionSnapshot(
            id: UUID(),
            createdAt: createdAt,
            name: name,
            isAutomatic: isAutomatic,
            label: label,
            compressedPayload: compressedPayload
        )
    }
}

extension PublishedVideoComparison {
    func copied(context: ModelCopyContext) -> PublishedVideoComparison {
        PublishedVideoComparison(
            videoID: videoID,
            url: url,
            title: title,
            publishedAt: publishedAt,
            transcriptSegments: transcriptSegments,
            retentionPoints: retentionPoints,
            sceneResults: sceneResults.map {
                PublishedSceneResult(
                    sceneID: context.sceneID($0.sceneID) ?? $0.sceneID,
                    realStart: $0.realStart,
                    realEnd: $0.realEnd,
                    addedWords: $0.addedWords,
                    removedWords: $0.removedWords,
                    coverage: $0.coverage,
                    avgRetention: $0.avgRetention,
                    dropMagnitude: $0.dropMagnitude
                )
            },
            learnings: learnings,
            importedAt: importedAt
        )
    }
}
