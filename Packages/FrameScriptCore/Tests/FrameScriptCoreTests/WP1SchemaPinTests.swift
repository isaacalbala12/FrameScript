import Foundation
import Testing
@testable import FrameScriptCore

/// Pins the persisted field set of every document type.
///
/// `FormatSchemaTests` proves that the published schema and the encoder agree in
/// both directions, so this list is an effective pin on every `CodingKeys` set.
/// When you add or remove a persisted field:
/// 1. bump `FrameScriptFormat.currentFileVersion`,
/// 2. add a migration branch for the older version,
/// 3. update `docs/format/fscr-v4.schema.json` (or publish the next schema),
/// 4. update this list.
///
/// Updating this list without doing the rest is exactly the drift the test
/// exists to make visible.
@Suite("WP1 schema pin")
struct WP1SchemaPinTests {
    private static let pinnedVersion = 4

    private static let pinnedProperties: [String: Set<String>] = [
        "AIComment": ["id", "message", "sceneID", "segmentID", "severity", "status", "suggestion", "type"],
        "AICommentSeverity": [],
        "AICommentStatus": [],
        "AIThreadMap": ["t3ProjectID", "threadIDsByProviderModel"],
        "AssetKind": [],
        "BRollItem": ["descriptionText", "duration", "framing", "id", "linkedSegmentID", "mood", "motion", "notes", "sourceType", "status", "templateType", "textAnchor"],
        "BRollSourceType": [],
        "BRollStatus": [],
        "ChapterOverride": ["id", "isExcluded", "sceneID", "startSeconds", "title"],
        "ChecklistTask": ["id", "isDone", "kind", "sceneID", "text"],
        "ChecklistTaskKind": [],
        "Claim": ["id", "sceneIDs", "sourceIDs", "status", "text"],
        "ClaimStatus": [],
        "ComparisonTable": ["header", "id", "rows", "title"],
        "EditingItem": ["cutStyle", "description", "emphasis", "graphics", "id", "linkedSegmentID", "musicCue", "notes", "sfx", "status", "subtitleStyle", "templateType", "textAnchor", "transition", "zoom"],
        "EditingStatus": [],
        "ExportFormat": [],
        "ExportPreset": ["format", "id", "name"],
        "FrameScriptDocument": ["fileVersion", "project"],
        "GlossaryTerm": ["id", "isProtected", "source", "target"],
        "ProductionStatus": [],
        "Project": ["aiThreadMap", "assets", "checklistTasks", "claims", "clips", "comparisonTables", "createdAt", "exportPresets", "glossary", "id", "learnedWordsPerMinuteByLanguage", "learnedWordsPerMinuteResetAtByLanguage", "primaryLanguage", "productionStatus", "publishDate", "publishedVideos", "publishingPacks", "rhythmThresholdsOverride", "scenes", "settingsOverride", "sources", "targetDate", "targetDuration", "templateID", "title", "topic", "unparsedSections", "updatedAt", "versionHistory", "videoType"],
        "ProjectAsset": ["bookmarkData", "duration", "fileSize", "id", "isCopiedIntoProject", "isLastKnownMissing", "kind", "linkedBRollItemIDs", "linkedSceneIDs", "linkedTakeIDs", "modifiedAt", "path", "tags"],
        "ProjectSettingsOverride": ["defaultSplitMode", "wordsPerMinute"],
        "PublishedVideoComparison": ["importedAt", "learnings", "publishedAt", "retentionPoints", "sceneResults", "title", "transcriptSegments", "url", "videoID"],
        "PublishedVideoComparisonSceneResult": ["addedWords", "avgRetention", "coverage", "dropMagnitude", "realEnd", "realStart", "removedWords", "sceneID"],
        "PublishingPack": ["chapterOverrides", "chosenTitle", "communityPost", "description", "hashtags", "pinnedComment", "tags", "thumbnailConceptNotes", "thumbnailVariants", "titleCandidates"],
        "RetentionPoint": ["percent", "time"],
        "RhythmThresholds": ["hookSecondsLimit", "longSentenceWordLimit", "sceneLengthRatioLimit", "uncoveredSecondsLimit"],
        "Scene": ["aiComments", "bRollItems", "editingItems", "estimatedDuration", "id", "languageVariants", "notes", "obsSceneName", "order", "scriptText", "sectionType", "takes", "targetDuration", "textSegments", "title"],
        "SceneLanguageVariant": ["actualDuration", "estimatedDuration", "languageCode", "sourceHash", "takes", "text"],
        "SectionType": [],
        "SegmentType": [],
        "ShortClip": ["adaptedText", "anchor", "anchorSceneID", "description", "format", "hashtags", "hook", "id", "languageCode", "onScreenText", "sceneSourceHashes", "sourceHash", "sourceSceneIDs", "status", "targetSeconds", "title"],
        "ShortClipFormat": [],
        "ShortClipSceneSourceHash": ["hash", "sceneID"],
        "ShortClipStatus": [],
        "Source": ["id", "note", "title", "url"],
        "Take": ["bookmarkData", "duration", "filePath", "id", "languageCode", "note", "number", "rating", "readText", "sceneTextHash", "startedAt"],
        "TakeRating": [],
        "TextAnchor": ["lengthUTF16", "prefixContext", "selectedText", "startUTF16", "suffixContext"],
        "TextSegment": ["id", "order", "sceneID", "segmentType", "sourceText", "timingEstimate"],
        "ThumbnailVariant": ["assetID", "id", "isChosen", "pairedTitle"],
        "TranscriptSegment": ["end", "start", "text"],
        "UnparsedSection": ["body", "heading"],
        "VersionSnapshot": ["compressedPayload", "createdAt", "id", "isAutomatic", "label", "name"]
    ]

    @Test("The file version is pinned; a schema change must bump it")
    func fileVersionIsPinned() {
        #expect(FrameScriptFormat.currentFileVersion == Self.pinnedVersion)
    }

    @Test("Every persisted type still has exactly the pinned fields")
    func schemaPropertiesMatchThePin() throws {
        let schema = try Self.loadSchema()
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let actualNames = Set(definitions.keys)
        #expect(actualNames == Set(Self.pinnedProperties.keys), "schema types drifted: \(actualNames.symmetricDifference(Set(Self.pinnedProperties.keys)).sorted())")

        for (name, pinned) in Self.pinnedProperties {
            let definition = try #require(definitions[name] as? [String: Any], "missing \(name)")
            let properties = definition["properties"] as? [String: Any] ?? [:]
            #expect(Set(properties.keys) == pinned, "\(name) fields drifted: \(Set(properties.keys).symmetricDifference(pinned).sorted())")
        }
    }

    @Test("The maximal document still encodes every pinned field")
    func maximalDocumentEncodesThePinnedFields() throws {
        let document = DocumentFormatTests.fullDocument()
        let data = try FrameScriptDocumentCodec.encode(document)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let project = try #require(root["project"] as? [String: Any])
        let scene = try #require((project["scenes"] as? [[String: Any]])?.first)

        #expect(Set(root.keys) == Self.pinnedProperties["FrameScriptDocument"])
        #expect(Set(project.keys) == Self.pinnedProperties["Project"])
        #expect(Set(scene.keys) == Self.pinnedProperties["Scene"])
    }

    private static func loadSchema() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("docs/format/fscr-v4.schema.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: candidate))
                return try #require(object as? [String: Any])
            }
            directory.deleteLastPathComponent()
        }
        throw SchemaPinError.fileNotFound
    }

    private enum SchemaPinError: Error {
        case fileNotFound
    }
}
