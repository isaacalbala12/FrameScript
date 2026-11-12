import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Document format v4")
struct DocumentFormatTests {
    // MARK: Round-trip

    @Test("Every schema field survives a v4 encode/decode round-trip")
    func everyFieldRoundTrips() throws {
        let document = Self.fullDocument()
        let data = try FrameScriptDocumentCodec.encode(document)
        let decoded = try FrameScriptDocumentCodec.decode(data)

        #expect(decoded == document)
        #expect(decoded.fileVersion == 4)

        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["fileVersion"] as? Int == 4)
    }

    @Test("Writer always emits version 4 even when the input document says otherwise")
    func writerAlwaysWritesCurrentVersion() throws {
        var document = Self.minimalDocument()
        document.fileVersion = 1

        let data = try FrameScriptDocumentCodec.encode(document)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["fileVersion"] as? Int == 4)

        let decoded = try FrameScriptDocumentCodec.decode(data)
        #expect(decoded.fileVersion == 4)
    }

    @Test("Atomic write helper writes and reads the same document")
    func atomicWriteReadsBack() throws {
        let document = Self.fullDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptCore-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }

        try FrameScriptDocumentCodec.write(document, to: url)
        let decoded = try FrameScriptDocumentCodec.read(from: url)
        #expect(decoded == document)
    }

    // MARK: Migration

    @Test("v1 migrates legacy segment links to anchors")
    func v1MigratesLegacyLinks() throws {
        let document = try decodeFixture("v1-minimal.fscr")
        #expect(document.fileVersion == 4)

        let scene = try #require(document.project.scenes.first)
        let visual = try #require(scene.bRollItems.first)
        let edit = try #require(scene.editingItems.first)

        #expect(visual.textAnchor?.selectedText == "alpha target omega")
        #expect(visual.textAnchor?.startUTF16 == 0)
        #expect(visual.linkedSegmentID == scene.textSegments.first?.id)
        #expect(edit.textAnchor?.selectedText == "alpha target omega")
        #expect(edit.cutStyle == "legacy cut")
        #expect(edit.status == .pending)
        #expect(visual.status == .idea)
        #expect(document.project.productionStatus == .idea)
        #expect(document.project.learningRateIsEmpty)
    }

    @Test("v2 repairs shifted anchors and clears unrecoverable ones")
    func v2RepairsAnchors() throws {
        let document = try decodeFixture("v2-shifted-anchor.fscr")
        let scene = try #require(document.project.scenes.first)
        let visual = try #require(scene.bRollItems.first)
        let edit = try #require(scene.editingItems.first)

        #expect(visual.textAnchor?.startUTF16 == 4)
        #expect(visual.textAnchor?.lengthUTF16 == 12)
        #expect(visual.textAnchor?.selectedText == "alpha target")
        #expect(visual.status == .sourced)
        #expect(visual.mood == "energetic")
        #expect(edit.textAnchor == nil)
        #expect(edit.linkedSegmentID == nil)
        #expect(edit.cutStyle == "unrecoverable cut")
        #expect(document.project.settingsOverride?.wordsPerMinute == 155)
        #expect(document.project.exportPresets.first?.format == .markdown)
    }

    @Test("v3 repairs anchors and seeds v4 defaults")
    func v3SeedsV4Defaults() throws {
        let document = try decodeFixture("v3-full.fscr")
        let scene = try #require(document.project.scenes.first)
        let visual = try #require(scene.bRollItems.first)
        let edit = try #require(scene.editingItems.first)
        let comment = try #require(scene.aiComments.first)

        #expect(visual.textAnchor?.startUTF16 == 2)
        #expect(visual.textAnchor?.selectedText == "one")
        #expect(visual.mood == "tense")
        #expect(visual.framing == "wide")
        #expect(visual.motion == "tracking")
        #expect(visual.duration == 4.25)
        #expect(visual.status == .planned)

        #expect(edit.templateType == "cut")
        #expect(edit.cutStyle == "hard cut")
        #expect(edit.transition == "dip to black")
        #expect(edit.subtitleStyle == "bold")
        #expect(edit.emphasis == "high")
        #expect(edit.zoom == "105%")
        #expect(edit.sfx == "whoosh")
        #expect(edit.musicCue == "beat drop")
        #expect(edit.graphics == "lower third")
        #expect(edit.notes == "editing notes")
        #expect(edit.status == .pending)

        #expect(comment.severity == .suggestion)
        #expect(comment.status == .dismissed)

        #expect(scene.targetDuration == nil)
        #expect(scene.takes.isEmpty)
        #expect(scene.languageVariants.isEmpty)
        #expect(scene.obsSceneName == nil)
        #expect(document.project.productionStatus == .idea)
        #expect(document.project.assets.isEmpty)
        #expect(document.project.publishingPacks.isEmpty)
        #expect(document.project.publishedVideos.isEmpty)
        #expect(document.project.aiThreadMap.t3ProjectID.isEmpty)
        #expect(document.project.unparsedSections.isEmpty)
    }

    @Test("Unknown future fields at every level are ignored")
    func unknownFieldsAreIgnored() throws {
        let data = try FrameScriptDocumentCodec.encode(Self.minimalDocument())
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["futureRootField"] = ["unexpected": true]

        var project = try #require(root["project"] as? [String: Any])
        project["futureProjectField"] = "ignored"
        var scenes = try #require(project["scenes"] as? [[String: Any]])
        var scene = scenes[0]
        scene["futureSceneField"] = 42
        var bRollItems = try #require(scene["bRollItems"] as? [[String: Any]])
        var visual = bRollItems[0]
        visual["futureVisualField"] = "ignored"
        bRollItems[0] = visual
        scene["bRollItems"] = bRollItems
        scenes[0] = scene
        project["scenes"] = scenes
        root["project"] = project

        let mutated = try JSONSerialization.data(withJSONObject: root)
        let document = try FrameScriptDocumentCodec.decode(mutated)
        let loadedScene = try #require(document.project.scenes.first)
        let loadedVisual = try #require(loadedScene.bRollItems.first)

        #expect(document.project.title == "Minimal project")
        #expect(loadedVisual.descriptionText == "visual")
    }

    @Test("Newer file versions fail with a clear error")
    func newerVersionIsRejected() throws {
        let data = try FrameScriptDocumentCodec.encode(Self.minimalDocument())
        var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        root["fileVersion"] = 5
        let mutated = try JSONSerialization.data(withJSONObject: root)

        #expect(throws: FrameScriptDocumentError.unsupportedVersion(5)) {
            _ = try FrameScriptDocumentCodec.decode(mutated)
        }
        let message = FrameScriptDocumentError.unsupportedVersion(5).localizedDescription
        #expect(message.contains("newer version"))
    }

    @Test("Old file versions below one are rejected")
    func zeroVersionIsRejected() {
        #expect(throws: FrameScriptDocumentError.unsupportedVersion(0)) {
            _ = try FrameScriptDocument(project: Self.minimalDocument().project).migratedWithVersion(0)
        }
    }

    @Test("Text hashes drive stale translation detection")
    func textHashDetectsStaleVariants() {
        let original = "texto original"
        let variant = FrameScriptDocument.SceneLanguageVariant(
            languageCode: "en",
            text: "original text",
            sourceHash: FrameScriptDocument.TextHash.hash(original)
        )

        #expect(!variant.isStale(comparedToOriginal: original))
        #expect(variant.isStale(comparedToOriginal: "texto cambiado"))
    }

    // MARK: Fixtures and builders

    private func decodeFixture(_ name: String) throws -> FrameScriptDocument {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Document"))
        return try FrameScriptDocumentCodec.decode(Data(contentsOf: url))
    }

    private static func minimalDocument() -> FrameScriptDocument {
        let sceneID = UUID()
        let visualID = UUID()
        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 0,
            sectionType: .hook,
            title: "Scene",
            scriptText: "alpha target omega",
            bRollItems: [
                FrameScriptDocument.BRollItem(
                    id: visualID,
                    sourceType: .stockFootage,
                    descriptionText: "visual"
                )
            ]
        )
        return FrameScriptDocument(
            project: FrameScriptDocument.Project(title: "Minimal project", scenes: [scene])
        )
    }

    fileprivate static func fullDocument() -> FrameScriptDocument {
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

        let anchor = FrameScriptDocument.TextAnchor(
            startUTF16: 6,
            lengthUTF16: 6,
            selectedText: "target",
            prefixContext: "alpha ",
            suffixContext: " omega"
        )
        let take = FrameScriptDocument.Take(
            id: takeID,
            number: 3,
            startedAt: Date(timeIntervalSince1970: 1_700_000_200),
            duration: 12.75,
            filePath: "/tmp/take.mov",
            bookmarkData: Data([0x01, 0x02, 0x03]),
            rating: .good,
            note: "best take",
            languageCode: "es"
        )
        let variantTake = FrameScriptDocument.Take(
            id: variantTakeID,
            number: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_300),
            duration: 11.5,
            filePath: "/tmp/variant-take.mov",
            bookmarkData: Data([0x04, 0x05]),
            rating: .safe,
            note: "english take",
            languageCode: "en"
        )
        let asset = FrameScriptDocument.ProjectAsset(
            id: assetID,
            path: "/tmp/thumb.png",
            bookmarkData: Data([0x0a, 0x0b]),
            kind: .thumbnail,
            tags: ["thumbnail", "cover"],
            linkedSceneIDs: [sceneID],
            linkedBRollItemIDs: [visualID],
            linkedTakeIDs: [takeID],
            isCopiedIntoProject: true
        )
        let chapter = FrameScriptDocument.ChapterOverride(
            id: chapterID,
            sceneID: sceneID,
            title: "Custom chapter",
            startSeconds: 15,
            isExcluded: true
        )
        let thumbnail = FrameScriptDocument.ThumbnailVariant(
            id: thumbnailID,
            assetID: assetID,
            pairedTitle: "Paired title",
            isChosen: true
        )
        let pack = FrameScriptDocument.PublishingPack(
            titleCandidates: ["Title A", "Title B"],
            chosenTitle: "Title A",
            description: "Description",
            tags: ["simracing"],
            hashtags: ["#simracing"],
            pinnedComment: "Pinned",
            communityPost: "Community",
            chapterOverrides: [chapter],
            thumbnailVariants: [thumbnail],
            thumbnailConceptNotes: "Concept notes"
        )
        let task = FrameScriptDocument.ChecklistTask(
            id: taskID,
            text: "Record intro",
            kind: .record,
            isDone: true,
            sceneID: sceneID
        )
        let source = FrameScriptDocument.Source(
            id: sourceID,
            title: "Source title",
            url: "https://example.com",
            note: "Source note"
        )
        let claim = FrameScriptDocument.Claim(
            id: claimID,
            text: "The claim",
            status: .confirmed,
            sourceIDs: [sourceID],
            sceneIDs: [sceneID]
        )
        let table = FrameScriptDocument.ComparisonTable(
            id: tableID,
            title: "Comparison",
            header: ["A", "B"],
            rows: [["1", "2"], ["3", "4"]]
        )
        let glossaryTerm = FrameScriptDocument.GlossaryTerm(
            id: glossaryID,
            source: "AC EVO",
            target: "AC EVO",
            isProtected: false
        )
        let clip = FrameScriptDocument.ShortClip(
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
            hashtags: ["#short"],
            sourceHash: FrameScriptDocument.TextHash.hash("alpha target omega"),
            status: .ready
        )
        let snapshot = FrameScriptDocument.VersionSnapshot(
            id: snapshotID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_400),
            name: "Named snapshot",
            isAutomatic: false,
            label: "manual",
            compressedPayload: Data([0x1f, 0x8b, 0x08])
        )
        let comparison = FrameScriptDocument.PublishedVideoComparison(
            transcriptSegments: [
                FrameScriptDocument.TranscriptSegment(start: 1.5, end: 2.5, text: "Hello"),
                FrameScriptDocument.TranscriptSegment(start: 2.5, end: 5, text: "World")
            ],
            retentionPoints: [
                FrameScriptDocument.RetentionPoint(time: 5, percent: 100),
                FrameScriptDocument.RetentionPoint(time: 30, percent: 62.5)
            ],
            importedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        let scene = FrameScriptDocument.Scene(
            id: sceneID,
            order: 4,
            sectionType: .whyThisMatters,
            title: "Full scene",
            scriptText: "alpha target omega",
            notes: "Scene notes",
            estimatedDuration: 42.5,
            textSegments: [
                FrameScriptDocument.TextSegment(
                    id: segmentID,
                    sceneID: sceneID,
                    order: 2,
                    sourceText: "alpha target omega",
                    segmentType: .sentence,
                    timingEstimate: 42.5
                )
            ],
            aiComments: [
                FrameScriptDocument.AIComment(
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
                FrameScriptDocument.BRollItem(
                    id: visualID,
                    textAnchor: anchor,
                    linkedSegmentID: segmentID,
                    templateType: "wide",
                    sourceType: .screenRecording,
                    descriptionText: "Visual",
                    mood: "calm",
                    framing: "close",
                    motion: "static",
                    duration: 8.25,
                    notes: "Visual notes",
                    status: .done
                )
            ],
            editingItems: [
                FrameScriptDocument.EditingItem(
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
                FrameScriptDocument.SceneLanguageVariant(
                    languageCode: "en",
                    text: "alpha target omega translated",
                    sourceHash: FrameScriptDocument.TextHash.hash("alpha target omega"),
                    takes: [variantTake],
                    estimatedDuration: 40,
                    actualDuration: 11.5
                )
            ],
            obsSceneName: "Camera"
        )

        let project = FrameScriptDocument.Project(
            id: projectID,
            title: "Full project",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_600),
            templateID: templateID,
            settingsOverride: FrameScriptDocument.ProjectSettingsOverride(
                wordsPerMinute: 160,
                defaultSplitMode: .sentence,
                longSentenceWordLimit: 28,
                uncoveredSecondsLimit: 5,
                sceneLengthRatioLimit: 1.8,
                hookSecondsLimit: 15
            ),
            exportPresets: [
                FrameScriptDocument.ExportPreset(id: presetID, name: "Preset", format: .csv)
            ],
            scenes: [scene],
            topic: "AC EVO",
            videoType: "review",
            productionStatus: .edited,
            targetDate: Date(timeIntervalSince1970: 1_700_000_700),
            publishDate: Date(timeIntervalSince1970: 1_700_000_800),
            targetDuration: 720,
            learnedWordsPerMinuteByLanguage: ["es": 152.5, "en": 161],
            assets: [asset],
            publishingPacks: ["es": pack, "en": pack],
            checklistTasks: [task],
            sources: [source],
            claims: [claim],
            comparisonTables: [table],
            glossary: [glossaryTerm],
            clips: [clip],
            versionHistory: [snapshot],
            aiThreadMap: FrameScriptDocument.AIThreadMap(
                t3ProjectID: "t3-project",
                threadIDsByProviderModel: ["openai/gpt-4.1-mini": "thread-1"]
            ),
            unparsedSections: [
                FrameScriptDocument.UnparsedSection(heading: "Leftovers", body: "Do not lose this")
            ],
            publishedVideos: ["es": comparison]
        )

        return FrameScriptDocument(project: project)
    }
}

private extension FrameScriptDocument {
    func migratedWithVersion(_ version: Int) throws -> FrameScriptDocument {
        var copy = self
        copy.fileVersion = version
        return try copy.migrated()
    }
}

private extension FrameScriptDocument.Project {
    var learningRateIsEmpty: Bool {
        learnedWordsPerMinuteByLanguage.isEmpty
    }
}
