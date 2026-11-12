import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class DocumentMappingTests: XCTestCase {
    func testEveryAppModelFieldSurvivesDocumentRoundTrip() throws {
        let project = try Self.makeFullProject()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentMappingTests-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }

        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)

        assertProject(loaded, equals: project)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(json?["fileVersion"] as? Int, 4)
    }

    func testLegacyVersionDocumentMapsToAppModel() throws {
        let project = try Self.makeFullProject()
        var document = FrameScriptFile(project: project)
        document.fileVersion = 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)

        let loaded = try FrameScriptFileStore.decodeProject(from: data)

        XCTAssertEqual(loaded.title, project.title)
        XCTAssertEqual(loaded.scenes.count, 1)
        XCTAssertEqual(loaded.scenes.first?.bRollItems.first?.mood, "calm")
        XCTAssertEqual(loaded.scenes.first?.editingItems.first?.status, .done)
    }

    private func assertProject(_ loaded: FrameProject, equals project: FrameProject, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(loaded.id, project.id, file: file, line: line)
        XCTAssertEqual(loaded.title, project.title, file: file, line: line)
        XCTAssertEqual(loaded.createdAt, project.createdAt, file: file, line: line)
        XCTAssertEqual(loaded.updatedAt, project.updatedAt, file: file, line: line)
        XCTAssertEqual(loaded.templateID, project.templateID, file: file, line: line)
        XCTAssertEqual(loaded.settingsOverride, project.settingsOverride, file: file, line: line)
        XCTAssertEqual(loaded.exportPresets, project.exportPresets, file: file, line: line)
        XCTAssertEqual(loaded.primaryLanguage, project.primaryLanguage, file: file, line: line)
        XCTAssertEqual(loaded.topic, project.topic, file: file, line: line)
        XCTAssertEqual(loaded.videoType, project.videoType, file: file, line: line)
        XCTAssertEqual(loaded.productionStatus, project.productionStatus, file: file, line: line)
        XCTAssertEqual(loaded.targetDate, project.targetDate, file: file, line: line)
        XCTAssertEqual(loaded.publishDate, project.publishDate, file: file, line: line)
        XCTAssertEqual(loaded.targetDuration, project.targetDuration, file: file, line: line)
        XCTAssertEqual(loaded.learnedWordsPerMinuteByLanguage, project.learnedWordsPerMinuteByLanguage, file: file, line: line)
        XCTAssertEqual(loaded.assets, project.assets, file: file, line: line)
        XCTAssertEqual(loaded.publishingPacks, project.publishingPacks, file: file, line: line)
        XCTAssertEqual(loaded.checklistTasks, project.checklistTasks, file: file, line: line)
        XCTAssertEqual(loaded.rhythmThresholdsOverride, project.rhythmThresholdsOverride, file: file, line: line)
        XCTAssertEqual(loaded.sources, project.sources, file: file, line: line)
        XCTAssertEqual(loaded.claims, project.claims, file: file, line: line)
        XCTAssertEqual(loaded.comparisonTables, project.comparisonTables, file: file, line: line)
        XCTAssertEqual(loaded.glossary, project.glossary, file: file, line: line)
        XCTAssertEqual(loaded.clips, project.clips, file: file, line: line)
        XCTAssertEqual(loaded.versionHistory, project.versionHistory, file: file, line: line)
        XCTAssertEqual(loaded.aiThreadMap, project.aiThreadMap, file: file, line: line)
        XCTAssertEqual(loaded.unparsedSections, project.unparsedSections, file: file, line: line)
        XCTAssertEqual(loaded.publishedVideos, project.publishedVideos, file: file, line: line)

        XCTAssertEqual(loaded.scenes.count, project.scenes.count, file: file, line: line)
        for (loadedScene, projectScene) in zip(loaded.scenes, project.scenes) {
            XCTAssertEqual(loadedScene.id, projectScene.id, file: file, line: line)
            XCTAssertEqual(loadedScene.order, projectScene.order, file: file, line: line)
            XCTAssertEqual(loadedScene.sectionType, projectScene.sectionType, file: file, line: line)
            XCTAssertEqual(loadedScene.title, projectScene.title, file: file, line: line)
            XCTAssertEqual(loadedScene.scriptText, projectScene.scriptText, file: file, line: line)
            XCTAssertEqual(loadedScene.notes, projectScene.notes, file: file, line: line)
            XCTAssertEqual(loadedScene.estimatedDuration, projectScene.estimatedDuration, file: file, line: line)
            XCTAssertEqual(loadedScene.targetDuration, projectScene.targetDuration, file: file, line: line)
            XCTAssertEqual(loadedScene.obsSceneName, projectScene.obsSceneName, file: file, line: line)
            XCTAssertEqual(loadedScene.takes, projectScene.takes, file: file, line: line)
            XCTAssertEqual(loadedScene.languageVariants, projectScene.languageVariants, file: file, line: line)

            XCTAssertEqual(loadedScene.textSegments.count, projectScene.textSegments.count, file: file, line: line)
            for (loadedSegment, projectSegment) in zip(loadedScene.textSegments, projectScene.textSegments) {
                XCTAssertEqual(loadedSegment.id, projectSegment.id, file: file, line: line)
                XCTAssertEqual(loadedSegment.sceneID, projectSegment.sceneID, file: file, line: line)
                XCTAssertEqual(loadedSegment.order, projectSegment.order, file: file, line: line)
                XCTAssertEqual(loadedSegment.sourceText, projectSegment.sourceText, file: file, line: line)
                XCTAssertEqual(loadedSegment.segmentType, projectSegment.segmentType, file: file, line: line)
                XCTAssertEqual(loadedSegment.timingEstimate, projectSegment.timingEstimate, file: file, line: line)
            }

            XCTAssertEqual(loadedScene.aiComments.count, projectScene.aiComments.count, file: file, line: line)
            for (loadedComment, projectComment) in zip(loadedScene.aiComments, projectScene.aiComments) {
                XCTAssertEqual(loadedComment.id, projectComment.id, file: file, line: line)
                XCTAssertEqual(loadedComment.sceneID, projectComment.sceneID, file: file, line: line)
                XCTAssertEqual(loadedComment.segmentID, projectComment.segmentID, file: file, line: line)
                XCTAssertEqual(loadedComment.type, projectComment.type, file: file, line: line)
                XCTAssertEqual(loadedComment.severity, projectComment.severity, file: file, line: line)
                XCTAssertEqual(loadedComment.message, projectComment.message, file: file, line: line)
                XCTAssertEqual(loadedComment.suggestion, projectComment.suggestion, file: file, line: line)
                XCTAssertEqual(loadedComment.status, projectComment.status, file: file, line: line)
            }

            XCTAssertEqual(loadedScene.bRollItems.count, projectScene.bRollItems.count, file: file, line: line)
            for (loadedItem, projectItem) in zip(loadedScene.bRollItems, projectScene.bRollItems) {
                XCTAssertEqual(loadedItem.id, projectItem.id, file: file, line: line)
                XCTAssertEqual(loadedItem.textAnchor, projectItem.textAnchor, file: file, line: line)
                XCTAssertEqual(loadedItem.linkedSegmentID, projectItem.linkedSegmentID, file: file, line: line)
                XCTAssertEqual(loadedItem.templateType, projectItem.templateType, file: file, line: line)
                XCTAssertEqual(loadedItem.sourceType, projectItem.sourceType, file: file, line: line)
                XCTAssertEqual(loadedItem.descriptionText, projectItem.descriptionText, file: file, line: line)
                XCTAssertEqual(loadedItem.mood, projectItem.mood, file: file, line: line)
                XCTAssertEqual(loadedItem.framing, projectItem.framing, file: file, line: line)
                XCTAssertEqual(loadedItem.motion, projectItem.motion, file: file, line: line)
                XCTAssertEqual(loadedItem.duration, projectItem.duration, file: file, line: line)
                XCTAssertEqual(loadedItem.notes, projectItem.notes, file: file, line: line)
                XCTAssertEqual(loadedItem.status, projectItem.status, file: file, line: line)
            }

            XCTAssertEqual(loadedScene.editingItems.count, projectScene.editingItems.count, file: file, line: line)
            for (loadedItem, projectItem) in zip(loadedScene.editingItems, projectScene.editingItems) {
                XCTAssertEqual(loadedItem.id, projectItem.id, file: file, line: line)
                XCTAssertEqual(loadedItem.textAnchor, projectItem.textAnchor, file: file, line: line)
                XCTAssertEqual(loadedItem.linkedSegmentID, projectItem.linkedSegmentID, file: file, line: line)
                XCTAssertEqual(loadedItem.templateType, projectItem.templateType, file: file, line: line)
                XCTAssertEqual(loadedItem.cutStyle, projectItem.cutStyle, file: file, line: line)
                XCTAssertEqual(loadedItem.transition, projectItem.transition, file: file, line: line)
                XCTAssertEqual(loadedItem.subtitleStyle, projectItem.subtitleStyle, file: file, line: line)
                XCTAssertEqual(loadedItem.emphasis, projectItem.emphasis, file: file, line: line)
                XCTAssertEqual(loadedItem.zoom, projectItem.zoom, file: file, line: line)
                XCTAssertEqual(loadedItem.sfx, projectItem.sfx, file: file, line: line)
                XCTAssertEqual(loadedItem.musicCue, projectItem.musicCue, file: file, line: line)
                XCTAssertEqual(loadedItem.graphics, projectItem.graphics, file: file, line: line)
                XCTAssertEqual(loadedItem.notes, projectItem.notes, file: file, line: line)
                XCTAssertEqual(loadedItem.status, projectItem.status, file: file, line: line)
            }
        }
    }

    static func makeFullProject() throws -> FrameProject {
        let projectID = UUID()
        let templateID = UUID()
        let sceneID = UUID()
        let segmentID = UUID()
        let commentID = UUID()
        let visualID = UUID()
        let editID = UUID()
        let sourceID = UUID()
        let assetID = UUID()
        let takeID = UUID()
        let variantTakeID = UUID()
        let clipID = UUID()
        let snapshotID = UUID()
        let chapterID = UUID()
        let thumbnailID = UUID()
        let taskID = UUID()
        let claimID = UUID()
        let tableID = UUID()
        let glossaryID = UUID()
        let presetID = UUID()

        let anchor = TextAnchor(
            startUTF16: 6,
            lengthUTF16: 6,
            selectedText: "target",
            prefixContext: "alpha ",
            suffixContext: " omega"
        )
        let take = Take(
            id: takeID,
            number: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_200),
            duration: 12.5,
            filePath: "/tmp/take.mov",
            bookmarkData: Data([0x01, 0x02]),
            rating: .good,
            note: "take note",
            languageCode: "es",
            readText: "alpha target omega",
            sceneTextHash: "scene-hash"
        )
        let variantTake = Take(
            id: variantTakeID,
            number: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            duration: 11,
            filePath: "/tmp/en.mov",
            bookmarkData: Data([0x03]),
            rating: .safe,
            note: "english take",
            languageCode: "en"
        )
        let asset = ProjectAsset(
            id: assetID,
            path: "/tmp/thumb.png",
            bookmarkData: Data([0x0a]),
            kind: .thumbnail,
            tags: ["cover"],
            linkedSceneIDs: [sceneID],
            linkedBRollItemIDs: [visualID],
            linkedTakeIDs: [takeID],
            isCopiedIntoProject: true,
            duration: 12.5,
            fileSize: 1_024,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_250),
            isLastKnownMissing: true
        )
        let chapter = ChapterOverride(
            id: chapterID,
            sceneID: sceneID,
            title: "Chapter",
            startSeconds: 10,
            isExcluded: true
        )
        let thumbnail = ThumbnailVariant(
            id: thumbnailID,
            assetID: assetID,
            pairedTitle: "Title A",
            isChosen: true
        )
        let pack = PublishingPack(
            titleCandidates: ["Title A", "Title B"],
            chosenTitle: "Title A",
            description: "Description",
            tags: ["tag"],
            hashtags: ["#tag"],
            pinnedComment: "Pinned",
            communityPost: "Community",
            chapterOverrides: [chapter],
            thumbnailVariants: [thumbnail],
            thumbnailConceptNotes: "Concept"
        )
        let task = ChecklistTask(
            id: taskID,
            text: "Record",
            kind: .record,
            isDone: true,
            sceneID: sceneID
        )
        let source = ProjectSource(
            id: sourceID,
            title: "Source",
            url: "https://example.com",
            note: "Note"
        )
        let claim = ProjectClaim(
            id: claimID,
            text: "Claim",
            status: .confirmed,
            sourceIDs: [sourceID],
            sceneIDs: [sceneID]
        )
        let table = ComparisonTable(
            id: tableID,
            title: "Table",
            header: ["A"],
            rows: [["1"]]
        )
        let glossaryTerm = GlossaryTerm(
            id: glossaryID,
            source: "Vantare",
            target: "Vantare",
            isProtected: false
        )
        let clip = ShortClip(
            id: clipID,
            title: "Clip",
            sourceSceneIDs: [sceneID],
            anchorSceneID: sceneID,
            anchor: anchor,
            hook: "Hook",
            adaptedText: "Adapted",
            targetSeconds: 45,
            format: .short,
            onScreenText: "On screen",
            description: "Clip description",
            hashtags: ["#clip"],
            sourceHash: "hash",
            languageCode: "en",
            sceneSourceHashes: [ClipSceneSourceHash(sceneID: sceneID, hash: "scene-hash")],
            status: .ready
        )
        let snapshot = VersionSnapshot(
            id: snapshotID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_400),
            name: "Snapshot",
            isAutomatic: false,
            label: "manual",
            compressedPayload: Data([0x1f, 0x8b])
        )
        let comparison = PublishedVideoComparison(
            videoID: "video-id",
            url: "https://example.com/video",
            title: "Published title",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_450),
            transcriptSegments: [TranscriptSegment(start: 1.5, end: 2, text: "Hello")],
            retentionPoints: [RetentionPoint(time: 5, percent: 100)],
            sceneResults: [
                PublishedSceneResult(
                    sceneID: sceneID,
                    realStart: 1,
                    realEnd: 8,
                    addedWords: 4,
                    removedWords: 2,
                    coverage: 0.9,
                    avgRetention: 0.8,
                    dropMagnitude: 0.15
                )
            ],
            learnings: "Keep the hook shorter.",
            importedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        let scene = Scene(
            id: sceneID,
            order: 1,
            sectionType: .explanation,
            title: "Scene",
            scriptText: "alpha target omega",
            notes: "Notes",
            estimatedDuration: 42,
            textSegments: [
                TextSegment(
                    id: segmentID,
                    sceneID: sceneID,
                    order: 0,
                    sourceText: "alpha target omega",
                    segmentType: .scene,
                    timingEstimate: 42
                )
            ],
            aiComments: [
                AIComment(
                    id: commentID,
                    sceneID: sceneID,
                    segmentID: segmentID,
                    type: "pacing",
                    severity: .important,
                    message: "Message",
                    suggestion: "Suggestion",
                    status: .applied
                )
            ],
            bRollItems: [
                BRollItem(
                    id: visualID,
                    textAnchor: anchor,
                    linkedSegmentID: segmentID,
                    templateType: "wide",
                    sourceType: .screenRecording,
                    descriptionText: "Visual",
                    mood: "calm",
                    framing: "close",
                    motion: "static",
                    duration: 8,
                    notes: "Visual notes",
                    status: .done
                )
            ],
            editingItems: [
                EditingItem(
                    id: editID,
                    textAnchor: anchor,
                    linkedSegmentID: segmentID,
                    templateType: "cut",
                    cutStyle: "hard cut",
                    transition: "fade",
                    subtitleStyle: "bold",
                    emphasis: "high",
                    zoom: "110%",
                    sfx: "whoosh",
                    musicCue: "drop",
                    graphics: "lower third",
                    notes: "Editing notes",
                    status: .done
                )
            ],
            targetDuration: 45,
            takes: [take],
            languageVariants: [
                SceneLanguageVariant(
                    languageCode: "en",
                    text: "alpha target omega translated",
                    sourceHash: "hash",
                    takes: [variantTake],
                    estimatedDuration: 40,
                    actualDuration: 11
                )
            ],
            obsSceneName: "Camera"
        )

        return FrameProject(
            id: projectID,
            title: "Full project",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
            templateID: templateID,
            scenes: [scene],
            settingsOverride: ProjectSettingsOverride(
                wordsPerMinute: 160,
                defaultSplitMode: .sentence
            ),
            exportPresets: [ExportPreset(id: presetID, name: "Preset", format: .csv)],
            primaryLanguage: "en",
            topic: "AC EVO",
            videoType: "review",
            productionStatus: .published,
            targetDate: Date(timeIntervalSince1970: 1_700_000_700),
            publishDate: Date(timeIntervalSince1970: 1_700_000_800),
            targetDuration: 720,
            learnedWordsPerMinuteByLanguage: ["es": 152.5, "en": 161],
            assets: [asset],
            publishingPacks: ["es": pack],
            checklistTasks: [task],
            rhythmThresholdsOverride: RhythmThresholds(
                longSentenceWordLimit: 28,
                uncoveredSecondsLimit: 5,
                sceneLengthRatioLimit: 1.8,
                hookSecondsLimit: 15
            ),
            sources: [source],
            claims: [claim],
            comparisonTables: [table],
            glossary: [glossaryTerm],
            clips: [clip],
            versionHistory: [snapshot],
            aiThreadMap: AIThreadMap(
                t3ProjectID: "t3-project",
                threadIDsByProviderModel: ["openai/gpt-4.1-mini": "thread-1"]
            ),
            unparsedSections: [UnparsedSection(heading: "Leftovers", body: "Body")],
            publishedVideos: ["es": comparison]
        )
    }
}
