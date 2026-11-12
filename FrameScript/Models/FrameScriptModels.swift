import Foundation
import FrameScriptCore
import Observation

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable {
    case script = "Script"
    case bRoll = "B-Roll"
    case editing = "Editing"

    var id: String { rawValue }

}

enum SectionType: String, Codable, CaseIterable, Identifiable {
    case hook = "Hook"
    case problem = "Problem"
    case whyThisMatters = "Why this matters"
    case explanation = "Explanation"
    case example = "Example"
    case takeaway = "Takeaway"
    case cta = "CTA"
    case custom = "Custom"

    var id: String { rawValue }
}

enum SegmentType: String, Codable, CaseIterable, Identifiable {
    case scene
    case paragraph
    case sentence

    var id: String { rawValue }
}

enum BRollSourceType: String, Codable, CaseIterable, Identifiable {
    case stockFootage = "Stock footage"
    case talkingHead = "Talking head"
    case screenRecording = "Screen recording"
    case animation = "Animation"
    case infographic = "Infographic"
    case textOnScreen = "Text on screen"
    case memeInsert = "Meme / insert"
    case productShot = "Product shot"
    case screenshot = "Screenshot"
    case custom = "Custom"

    var id: String { rawValue }
}

enum BRollStatus: String, Codable, CaseIterable, Identifiable {
    case idea = "Idea"
    case planned = "Planned"
    case sourced = "Sourced"
    case done = "Done"

    var id: String { rawValue }
}

enum AICommentStatus: String, Codable, CaseIterable {
    case new
    case dismissed
    case applied
}

enum AICommentSeverity: String, Codable, CaseIterable {
    case note
    case suggestion
    case important
}

enum TemplateCategory: String, Codable, CaseIterable, Identifiable {
    case script
    case bRoll
    case editing

    var id: String { rawValue }
}

enum EditingStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case done

    var id: String { rawValue }
}

enum ProductionStatus: String, Codable, CaseIterable, Identifiable {
    case idea
    case outline
    case script
    case recorded
    case edited
    case published

    var id: String { rawValue }
}

enum TakeRating: String, Codable, CaseIterable, Identifiable {
    case good
    case bad
    case safe
    case unrated

    var id: String { rawValue }
}

enum AssetKind: String, Codable, CaseIterable, Identifiable {
    case camera = "CAM"
    case obs = "OBS"
    case screenshot
    case web
    case music
    case graphic
    case thumbnail

    var id: String { rawValue }
}

enum ClaimStatus: String, Codable, CaseIterable, Identifiable {
    case confirmed
    case probable
    case rumor

    var id: String { rawValue }
}

enum ChecklistTaskKind: String, Codable, CaseIterable, Identifiable {
    case record
    case acquire
    case edit
    case research
    case other

    var id: String { rawValue }
}

enum ShortClipFormat: String, Codable, CaseIterable, Identifiable {
    case reel
    case short
    case story

    var id: String { rawValue }
}

enum ShortClipStatus: String, Codable, CaseIterable, Identifiable {
    case idea
    case draft
    case ready
    case published

    var id: String { rawValue }
}

struct TextAnchor: Codable, Hashable {
    var startUTF16: Int
    var lengthUTF16: Int
    var selectedText: String
    var prefixContext: String
    var suffixContext: String

    var nsRange: NSRange {
        NSRange(location: startUTF16, length: lengthUTF16)
    }

    init(startUTF16: Int, lengthUTF16: Int, selectedText: String, prefixContext: String = "", suffixContext: String = "") {
        self.startUTF16 = max(0, startUTF16)
        self.lengthUTF16 = max(0, lengthUTF16)
        self.selectedText = selectedText
        self.prefixContext = prefixContext
        self.suffixContext = suffixContext
    }
}

/// A recorded take for a scene or a language variant (F10).
struct Take: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var number: Int
    var startedAt: Date
    var duration: TimeInterval
    var filePath: String
    var bookmarkData: Data?
    var rating: TakeRating
    var note: String
    /// Empty means the scene's original language.
    var languageCode: String
    /// Text shown in the teleprompter when this take was recorded (F10).
    var readText: String
    /// Hash of the scene text used for this take (F10/F11).
    var sceneTextHash: String

    init(
        id: UUID = UUID(),
        number: Int,
        startedAt: Date,
        duration: TimeInterval = 0,
        filePath: String = "",
        bookmarkData: Data? = nil,
        rating: TakeRating = .unrated,
        note: String = "",
        languageCode: String = "",
        readText: String = "",
        sceneTextHash: String = ""
    ) {
        self.id = id
        self.number = number
        self.startedAt = startedAt
        self.duration = duration
        self.filePath = filePath
        self.bookmarkData = bookmarkData
        self.rating = rating
        self.note = note
        self.languageCode = languageCode
        self.readText = readText
        self.sceneTextHash = sceneTextHash
    }
}

/// One translated variant of a scene (D1 / F22). B-roll and editing notes stay
/// shared with the original scene; text, takes and durations are per language.
struct SceneLanguageVariant: Codable, Hashable, Sendable {
    var languageCode: String
    var text: String
    var sourceHash: String
    var takes: [Take]
    var estimatedDuration: TimeInterval
    var actualDuration: TimeInterval

    init(
        languageCode: String,
        text: String = "",
        sourceHash: String = "",
        takes: [Take] = [],
        estimatedDuration: TimeInterval = 0,
        actualDuration: TimeInterval = 0
    ) {
        self.languageCode = languageCode
        self.text = text
        self.sourceHash = sourceHash
        self.takes = takes
        self.estimatedDuration = estimatedDuration
        self.actualDuration = actualDuration
    }

    func isStale(comparedToOriginal text: String) -> Bool {
        sourceHash != FrameScriptDocument.TextHash.hash(text)
    }
}

/// An asset referenced by the project (F14). Only thumbnails are copied into
/// the sibling `<Name> assets/` folder.
struct ProjectAsset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var path: String
    var bookmarkData: Data?
    var kind: AssetKind
    var tags: [String]
    var linkedSceneIDs: [UUID]
    var linkedBRollItemIDs: [UUID]
    var linkedTakeIDs: [UUID]
    var isCopiedIntoProject: Bool
    var duration: TimeInterval?
    var fileSize: Int64?
    var modifiedAt: Date?
    /// True when the last filesystem check could not find the referenced file.
    var isLastKnownMissing: Bool

    init(
        id: UUID = UUID(),
        path: String,
        bookmarkData: Data? = nil,
        kind: AssetKind = .web,
        tags: [String] = [],
        linkedSceneIDs: [UUID] = [],
        linkedBRollItemIDs: [UUID] = [],
        linkedTakeIDs: [UUID] = [],
        isCopiedIntoProject: Bool = false,
        duration: TimeInterval? = nil,
        fileSize: Int64? = nil,
        modifiedAt: Date? = nil,
        isLastKnownMissing: Bool = false
    ) {
        self.id = id
        self.path = path
        self.bookmarkData = bookmarkData
        self.kind = kind
        self.tags = tags
        self.linkedSceneIDs = linkedSceneIDs
        self.linkedBRollItemIDs = linkedBRollItemIDs
        self.linkedTakeIDs = linkedTakeIDs
        self.isCopiedIntoProject = isCopiedIntoProject
        self.duration = duration
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.isLastKnownMissing = isLastKnownMissing
    }
}

struct ChapterOverride: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var sceneID: UUID?
    var title: String
    var startSeconds: TimeInterval?
    var isExcluded: Bool

    init(
        id: UUID = UUID(),
        sceneID: UUID? = nil,
        title: String = "",
        startSeconds: TimeInterval? = nil,
        isExcluded: Bool = false
    ) {
        self.id = id
        self.sceneID = sceneID
        self.title = title
        self.startSeconds = startSeconds
        self.isExcluded = isExcluded
    }
}

struct ThumbnailVariant: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var assetID: UUID?
    var pairedTitle: String
    var isChosen: Bool

    init(
        id: UUID = UUID(),
        assetID: UUID? = nil,
        pairedTitle: String = "",
        isChosen: Bool = false
    ) {
        self.id = id
        self.assetID = assetID
        self.pairedTitle = pairedTitle
        self.isChosen = isChosen
    }
}

/// Publishing data for one language (F15 / F22).
struct PublishingPack: Codable, Hashable, Sendable {
    var titleCandidates: [String]
    var chosenTitle: String
    var description: String
    var tags: [String]
    var hashtags: [String]
    var pinnedComment: String
    var communityPost: String
    var chapterOverrides: [ChapterOverride]
    var thumbnailVariants: [ThumbnailVariant]
    var thumbnailConceptNotes: String

    init(
        titleCandidates: [String] = [],
        chosenTitle: String = "",
        description: String = "",
        tags: [String] = [],
        hashtags: [String] = [],
        pinnedComment: String = "",
        communityPost: String = "",
        chapterOverrides: [ChapterOverride] = [],
        thumbnailVariants: [ThumbnailVariant] = [],
        thumbnailConceptNotes: String = ""
    ) {
        self.titleCandidates = titleCandidates
        self.chosenTitle = chosenTitle
        self.description = description
        self.tags = tags
        self.hashtags = hashtags
        self.pinnedComment = pinnedComment
        self.communityPost = communityPost
        self.chapterOverrides = chapterOverrides
        self.thumbnailVariants = thumbnailVariants
        self.thumbnailConceptNotes = thumbnailConceptNotes
    }
}

struct ChecklistTask: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var kind: ChecklistTaskKind
    var isDone: Bool
    var sceneID: UUID?

    init(
        id: UUID = UUID(),
        text: String,
        kind: ChecklistTaskKind = .other,
        isDone: Bool = false,
        sceneID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.isDone = isDone
        self.sceneID = sceneID
    }
}

struct ProjectSource: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var url: String
    var note: String

    init(id: UUID = UUID(), title: String, url: String = "", note: String = "") {
        self.id = id
        self.title = title
        self.url = url
        self.note = note
    }
}

struct ProjectClaim: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var text: String
    var status: ClaimStatus
    var sourceIDs: [UUID]
    var sceneIDs: [UUID]

    init(
        id: UUID = UUID(),
        text: String,
        status: ClaimStatus = .probable,
        sourceIDs: [UUID] = [],
        sceneIDs: [UUID] = []
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.sourceIDs = sourceIDs
        self.sceneIDs = sceneIDs
    }
}

struct ComparisonTable: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var header: [String]
    var rows: [[String]]

    init(id: UUID = UUID(), title: String, header: [String] = [], rows: [[String]] = []) {
        self.id = id
        self.title = title
        self.header = header
        self.rows = rows
    }
}

struct GlossaryTerm: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var source: String
    var target: String
    var isProtected: Bool

    init(id: UUID = UUID(), source: String, target: String = "", isProtected: Bool = true) {
        self.id = id
        self.source = source
        self.target = target
        self.isProtected = isProtected
    }
}

struct ClipSceneSourceHash: Codable, Hashable, Sendable {
    var sceneID: UUID
    var hash: String

    init(sceneID: UUID, hash: String) {
        self.sceneID = sceneID
        self.hash = hash
    }
}

/// A derived short-form clip (F24).
struct ShortClip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var sourceSceneIDs: [UUID]
    var anchorSceneID: UUID?
    var anchor: TextAnchor?
    var hook: String
    var adaptedText: String
    var targetSeconds: TimeInterval
    var format: ShortClipFormat
    var onScreenText: String
    var description: String
    var hashtags: [String]
    var sourceHash: String
    var languageCode: String
    var sceneSourceHashes: [ClipSceneSourceHash]
    var status: ShortClipStatus

    init(
        id: UUID = UUID(),
        title: String,
        sourceSceneIDs: [UUID] = [],
        anchorSceneID: UUID? = nil,
        anchor: TextAnchor? = nil,
        hook: String = "",
        adaptedText: String = "",
        targetSeconds: TimeInterval = 30,
        format: ShortClipFormat = .reel,
        onScreenText: String = "",
        description: String = "",
        hashtags: [String] = [],
        sourceHash: String = "",
        languageCode: String = "",
        sceneSourceHashes: [ClipSceneSourceHash] = [],
        status: ShortClipStatus = .idea
    ) {
        self.id = id
        self.title = title
        self.sourceSceneIDs = sourceSceneIDs
        self.anchorSceneID = anchorSceneID
        self.anchor = anchor
        self.hook = hook
        self.adaptedText = adaptedText
        self.targetSeconds = targetSeconds
        self.format = format
        self.onScreenText = onScreenText
        self.description = description
        self.hashtags = hashtags
        self.sourceHash = sourceHash
        self.languageCode = languageCode
        self.sceneSourceHashes = sceneSourceHashes
        self.status = status
    }

    func isStale(comparedToSourceText text: String) -> Bool {
        sourceHash != FrameScriptDocument.TextHash.hash(text)
    }
}

/// Snapshot stored inside the project file (D4 / F21).
struct VersionSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var name: String?
    var isAutomatic: Bool
    var label: String
    /// zlib-compressed payload.
    var compressedPayload: Data

    init(
        id: UUID = UUID(),
        createdAt: Date,
        name: String? = nil,
        isAutomatic: Bool = true,
        label: String = "",
        compressedPayload: Data = Data()
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.isAutomatic = isAutomatic
        self.label = label
        self.compressedPayload = compressedPayload
    }
}

/// T3 thread reuse map (D2 / F12).
struct AIThreadMap: Codable, Hashable, Sendable {
    var t3ProjectID: String
    var threadIDsByProviderModel: [String: String]

    init(t3ProjectID: String = "", threadIDsByProviderModel: [String: String] = [:]) {
        self.t3ProjectID = t3ProjectID
        self.threadIDsByProviderModel = threadIDsByProviderModel
    }
}

struct UnparsedSection: Codable, Hashable, Sendable {
    var heading: String
    var body: String

    init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

struct RetentionPoint: Codable, Hashable, Sendable {
    /// Seconds since the start of the published video.
    var time: TimeInterval
    /// Percentage of viewers still watching, 0...100.
    var percent: Double

    init(time: TimeInterval, percent: Double) {
        self.time = time
        self.percent = percent
    }
}

struct PublishedSceneResult: Codable, Hashable, Sendable {
    var sceneID: UUID
    var realStart: TimeInterval
    var realEnd: TimeInterval
    var addedWords: Int
    var removedWords: Int
    var coverage: Double
    var avgRetention: Double
    var dropMagnitude: Double

    init(
        sceneID: UUID,
        realStart: TimeInterval = 0,
        realEnd: TimeInterval = 0,
        addedWords: Int = 0,
        removedWords: Int = 0,
        coverage: Double = 0,
        avgRetention: Double = 0,
        dropMagnitude: Double = 0
    ) {
        self.sceneID = sceneID
        self.realStart = realStart
        self.realEnd = realEnd
        self.addedWords = addedWords
        self.removedWords = removedWords
        self.coverage = coverage
        self.avgRetention = avgRetention
        self.dropMagnitude = dropMagnitude
    }
}

struct PublishedVideoComparison: Codable, Hashable, Sendable {
    var videoID: String
    var url: String
    var title: String
    var publishedAt: Date?
    var transcriptSegments: [TranscriptSegment]
    var retentionPoints: [RetentionPoint]
    var sceneResults: [PublishedSceneResult]
    var learnings: String
    var importedAt: Date

    init(
        videoID: String = "",
        url: String = "",
        title: String = "",
        publishedAt: Date? = nil,
        transcriptSegments: [TranscriptSegment] = [],
        retentionPoints: [RetentionPoint] = [],
        sceneResults: [PublishedSceneResult] = [],
        learnings: String = "",
        importedAt: Date = Date()
    ) {
        self.videoID = videoID
        self.url = url
        self.title = title
        self.publishedAt = publishedAt
        self.transcriptSegments = transcriptSegments
        self.retentionPoints = retentionPoints
        self.sceneResults = sceneResults
        self.learnings = learnings
        self.importedAt = importedAt
    }
}

@Observable
final class FrameProject: Identifiable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var templateID: UUID?
    var settingsOverride: ProjectSettingsOverride?
    var exportPresets: [ExportPreset]
    var scenes: [Scene]
    /// Original script language. Everything else is keyed by language code.
    var primaryLanguage: String

    var topic: String
    var videoType: String
    var productionStatus: ProductionStatus
    var targetDate: Date?
    var publishDate: Date?
    var targetDuration: TimeInterval?
    var learnedWordsPerMinuteByLanguage: [String: Double]
    var assets: [ProjectAsset]
    /// Keyed by language code.
    var publishingPacks: [String: PublishingPack]
    var checklistTasks: [ChecklistTask]
    var rhythmThresholdsOverride: RhythmThresholds?
    var sources: [ProjectSource]
    var claims: [ProjectClaim]
    var comparisonTables: [ComparisonTable]
    var glossary: [GlossaryTerm]
    var clips: [ShortClip]
    var versionHistory: [VersionSnapshot]
    var aiThreadMap: AIThreadMap
    var unparsedSections: [UnparsedSection]
    /// Keyed by language code.
    var publishedVideos: [String: PublishedVideoComparison]

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        templateID: UUID? = nil,
        scenes: [Scene] = [],
        settingsOverride: ProjectSettingsOverride? = nil,
        exportPresets: [ExportPreset] = [],
        primaryLanguage: String = "es",
        topic: String = "",
        videoType: String = "",
        productionStatus: ProductionStatus = .idea,
        targetDate: Date? = nil,
        publishDate: Date? = nil,
        targetDuration: TimeInterval? = nil,
        learnedWordsPerMinuteByLanguage: [String: Double] = [:],
        assets: [ProjectAsset] = [],
        publishingPacks: [String: PublishingPack] = [:],
        checklistTasks: [ChecklistTask] = [],
        rhythmThresholdsOverride: RhythmThresholds? = nil,
        sources: [ProjectSource] = [],
        claims: [ProjectClaim] = [],
        comparisonTables: [ComparisonTable] = [],
        glossary: [GlossaryTerm] = [],
        clips: [ShortClip] = [],
        versionHistory: [VersionSnapshot] = [],
        aiThreadMap: AIThreadMap = AIThreadMap(),
        unparsedSections: [UnparsedSection] = [],
        publishedVideos: [String: PublishedVideoComparison] = [:]
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.templateID = templateID
        self.scenes = scenes
        self.settingsOverride = settingsOverride
        self.exportPresets = exportPresets
        self.primaryLanguage = primaryLanguage
        self.topic = topic
        self.videoType = videoType
        self.productionStatus = productionStatus
        self.targetDate = targetDate
        self.publishDate = publishDate
        self.targetDuration = targetDuration
        self.learnedWordsPerMinuteByLanguage = learnedWordsPerMinuteByLanguage
        self.assets = assets
        self.publishingPacks = publishingPacks
        self.checklistTasks = checklistTasks
        self.rhythmThresholdsOverride = rhythmThresholdsOverride
        self.sources = sources
        self.claims = claims
        self.comparisonTables = comparisonTables
        self.glossary = glossary
        self.clips = clips
        self.versionHistory = versionHistory
        self.aiThreadMap = aiThreadMap
        self.unparsedSections = unparsedSections
        self.publishedVideos = publishedVideos
    }
}

@Observable
final class Scene: Identifiable {
    var id: UUID
    var order: Int
    var sectionType: SectionType
    var title: String
    var scriptText: String
    var notes: String
    var estimatedDuration: TimeInterval
    var textSegments: [TextSegment]
    var aiComments: [AIComment]
    var bRollItems: [BRollItem]
    var editingItems: [EditingItem]
    var targetDuration: TimeInterval?
    var takes: [Take]
    var languageVariants: [SceneLanguageVariant]
    /// OBS scene to switch to when recording this scene (F10).
    var obsSceneName: String?

    init(
        id: UUID = UUID(),
        order: Int,
        sectionType: SectionType,
        title: String,
        scriptText: String,
        notes: String = "",
        estimatedDuration: TimeInterval = 0,
        textSegments: [TextSegment] = [],
        aiComments: [AIComment] = [],
        bRollItems: [BRollItem] = [],
        editingItems: [EditingItem] = [],
        targetDuration: TimeInterval? = nil,
        takes: [Take] = [],
        languageVariants: [SceneLanguageVariant] = [],
        obsSceneName: String? = nil
    ) {
        self.id = id
        self.order = order
        self.sectionType = sectionType
        self.title = title
        self.scriptText = scriptText
        self.notes = notes
        self.estimatedDuration = estimatedDuration
        self.textSegments = textSegments
        self.aiComments = aiComments
        self.bRollItems = bRollItems
        self.editingItems = editingItems
        self.targetDuration = targetDuration
        self.takes = takes
        self.languageVariants = languageVariants
        self.obsSceneName = obsSceneName
    }
}

@Observable
final class TextSegment: Identifiable {
    var id: UUID
    var sceneID: UUID
    var order: Int
    var sourceText: String
    var segmentType: SegmentType
    var timingEstimate: TimeInterval

    init(
        id: UUID = UUID(),
        sceneID: UUID,
        order: Int,
        sourceText: String,
        segmentType: SegmentType,
        timingEstimate: TimeInterval = 0
    ) {
        self.id = id
        self.sceneID = sceneID
        self.order = order
        self.sourceText = sourceText
        self.segmentType = segmentType
        self.timingEstimate = timingEstimate
    }
}

@Observable
final class BRollItem: Identifiable {
    var id: UUID
    var textAnchor: TextAnchor?
    var linkedSegmentID: UUID?
    var templateType: String
    var sourceType: BRollSourceType
    var descriptionText: String
    var mood: String
    var framing: String
    var motion: String
    var duration: TimeInterval
    var notes: String
    var status: BRollStatus

    init(
        id: UUID = UUID(),
        textAnchor: TextAnchor? = nil,
        linkedSegmentID: UUID? = nil,
        templateType: String,
        sourceType: BRollSourceType,
        descriptionText: String,
        mood: String = "",
        framing: String = "",
        motion: String = "",
        duration: TimeInterval = 0,
        notes: String = "",
        status: BRollStatus = .idea
    ) {
        self.id = id
        self.textAnchor = textAnchor
        self.linkedSegmentID = linkedSegmentID
        self.templateType = templateType
        self.sourceType = sourceType
        self.descriptionText = descriptionText
        self.mood = mood
        self.framing = framing
        self.motion = motion
        self.duration = duration
        self.notes = notes
        self.status = status
    }
}

@Observable
final class EditingItem: Identifiable {
    var id: UUID
    var textAnchor: TextAnchor?
    var linkedSegmentID: UUID?
    var templateType: String
    var cutStyle: String
    var transition: String
    var subtitleStyle: String
    var emphasis: String
    var zoom: String
    var sfx: String
    var musicCue: String
    var graphics: String
    var notes: String
    var status: EditingStatus

    init(
        id: UUID = UUID(),
        textAnchor: TextAnchor? = nil,
        linkedSegmentID: UUID? = nil,
        templateType: String,
        cutStyle: String,
        transition: String,
        subtitleStyle: String,
        emphasis: String = "",
        zoom: String = "",
        sfx: String = "",
        musicCue: String = "",
        graphics: String = "",
        notes: String = "",
        status: EditingStatus = .pending
    ) {
        self.id = id
        self.textAnchor = textAnchor
        self.linkedSegmentID = linkedSegmentID
        self.templateType = templateType
        self.cutStyle = cutStyle
        self.transition = transition
        self.subtitleStyle = subtitleStyle
        self.emphasis = emphasis
        self.zoom = zoom
        self.sfx = sfx
        self.musicCue = musicCue
        self.graphics = graphics
        self.notes = notes
        self.status = status
    }
}

@Observable
final class AIComment: Identifiable {
    var id: UUID
    var sceneID: UUID?
    var segmentID: UUID?
    var type: String
    var severity: AICommentSeverity
    var message: String
    var suggestion: String
    var status: AICommentStatus

    init(
        id: UUID = UUID(),
        sceneID: UUID? = nil,
        segmentID: UUID? = nil,
        type: String,
        severity: AICommentSeverity,
        message: String,
        suggestion: String = "",
        status: AICommentStatus = .new
    ) {
        self.id = id
        self.sceneID = sceneID
        self.segmentID = segmentID
        self.type = type
        self.severity = severity
        self.message = message
        self.suggestion = suggestion
        self.status = status
    }
}

struct FrameTemplate: Identifiable, Codable, Hashable {
    var id: UUID
    var category: TemplateCategory
    var name: String
    var builtIn: Bool
    var structureDefinition: [String]
    var customFields: [String]
    var builtInSourceName: String? = nil

    var isCustomizedBuiltIn: Bool {
        builtInSourceName != nil
    }

    var isBlank: Bool {
        category == .script && (builtInSourceName ?? name) == "Blank"
    }
}

struct AppSettings: Codable, Hashable {
    var generalPreferences: GeneralPreferences
    var theme: AppearanceTheme
    var accentColor: AccentPalette
    var editorPreferences: EditorPreferences
    var aiPreferences: AIPreferences
    var voicePreferences: VoicePreferences
    var exportPreferences: ExportPreferences
    var windowPreferences: WindowPreferences
    /// Rhythm-review defaults keyed by video type (F26). App preference, never
    /// written to project files.
    var rhythmThresholdsByVideoType: [String: RhythmThresholds] = [:]
    /// User bindings are application preferences and never belong in project files.
    var shortcutOverrides: [ShortcutCommand: ShortcutOverride] = [:]

    enum CodingKeys: String, CodingKey {
        case generalPreferences, theme, accentColor, editorPreferences, aiPreferences
        case voicePreferences, exportPreferences, windowPreferences, rhythmThresholdsByVideoType
        case shortcutOverrides
    }

    init(
        generalPreferences: GeneralPreferences,
        theme: AppearanceTheme,
        accentColor: AccentPalette,
        editorPreferences: EditorPreferences,
        aiPreferences: AIPreferences,
        voicePreferences: VoicePreferences,
        exportPreferences: ExportPreferences,
        windowPreferences: WindowPreferences,
        rhythmThresholdsByVideoType: [String: RhythmThresholds] = [:],
        shortcutOverrides: [ShortcutCommand: ShortcutOverride] = [:]
    ) {
        self.generalPreferences = generalPreferences
        self.theme = theme
        self.accentColor = accentColor
        self.editorPreferences = editorPreferences
        self.aiPreferences = aiPreferences
        self.voicePreferences = voicePreferences
        self.exportPreferences = exportPreferences
        self.windowPreferences = windowPreferences
        self.rhythmThresholdsByVideoType = rhythmThresholdsByVideoType
        self.shortcutOverrides = shortcutOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing sections fall back to defaults instead of throwing and
        // wiping every preference. Existing keys and raw values are unchanged.
        generalPreferences = try container.decodeIfPresent(GeneralPreferences.self, forKey: .generalPreferences)
            ?? GeneralPreferences.defaults
        theme = container.decodeSettingsEnum(AppearanceTheme.self, forKey: .theme, default: .system)
        accentColor = container.decodeSettingsEnum(AccentPalette.self, forKey: .accentColor, default: .sage)
        editorPreferences = try container.decodeIfPresent(EditorPreferences.self, forKey: .editorPreferences)
            ?? EditorPreferences.defaults
        aiPreferences = try container.decodeIfPresent(AIPreferences.self, forKey: .aiPreferences)
            ?? AIPreferences.defaults
        voicePreferences = try container.decodeIfPresent(VoicePreferences.self, forKey: .voicePreferences)
            ?? VoicePreferences.defaults
        exportPreferences = try container.decodeIfPresent(ExportPreferences.self, forKey: .exportPreferences)
            ?? ExportPreferences.defaults
        windowPreferences = try container.decodeIfPresent(WindowPreferences.self, forKey: .windowPreferences)
            ?? WindowPreferences.defaults
        // Existing installations did not encode shortcut preferences. Unknown
        // command raw values are dropped instead of failing the whole blob.
        let rawOverrides = (try? container.decodeIfPresent(ShortcutOverridesPayload.self, forKey: .shortcutOverrides))?.values ?? [:]
        let decodedOverrides: [ShortcutCommand: ShortcutOverride] = Dictionary(
            uniqueKeysWithValues: rawOverrides.compactMap { (key: String, value: ShortcutOverride) -> (ShortcutCommand, ShortcutOverride)? in
                guard let command = ShortcutCommand(rawValue: key) else { return nil }
                return (command, value)
            }
        )
        shortcutOverrides = ShortcutRegistry.normalizedOverrides(decodedOverrides)
        rhythmThresholdsByVideoType = (try? container.decodeIfPresent(
            [String: RhythmThresholdsPayload].self,
            forKey: .rhythmThresholdsByVideoType
        ))?.mapValues(\.value) ?? [:]
    }
}

struct GeneralPreferences: Codable, Hashable {
    var launchBehavior: LaunchBehavior
    var language: AppLanguage
    var autosaveEnabled: Bool
    var autosaveIntervalSeconds: Int
    var defaultNewProjectTemplate: String
    var blankProjectStart: BlankProjectStart
    var defaultSplitMode: SegmentType
    var confirmBeforeDeleting: Bool

    init(
        launchBehavior: LaunchBehavior,
        language: AppLanguage = .system,
        autosaveEnabled: Bool,
        autosaveIntervalSeconds: Int,
        defaultNewProjectTemplate: String,
        blankProjectStart: BlankProjectStart = .oneEmptyScene,
        defaultSplitMode: SegmentType,
        confirmBeforeDeleting: Bool
    ) {
        self.launchBehavior = launchBehavior
        self.language = language
        self.autosaveEnabled = autosaveEnabled
        self.autosaveIntervalSeconds = autosaveIntervalSeconds
        self.defaultNewProjectTemplate = defaultNewProjectTemplate
        self.blankProjectStart = blankProjectStart
        self.defaultSplitMode = defaultSplitMode
        self.confirmBeforeDeleting = confirmBeforeDeleting
    }

    enum CodingKeys: String, CodingKey {
        case launchBehavior
        // Legacy keys are read only to migrate existing settings files.
        case showProjectBrowserOnLaunch
        case restoreLastProjectOnLaunch
        case language
        case autosaveEnabled
        case autosaveIntervalSeconds
        case defaultNewProjectTemplate
        case blankProjectStart
        case defaultSplitMode
        case confirmBeforeDeleting
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let behavior = container.decodeSettingsEnumIfPresent(LaunchBehavior.self, forKey: .launchBehavior) {
            launchBehavior = behavior
        } else {
            let restoreLastProject = try container.decodeIfPresent(Bool.self, forKey: .restoreLastProjectOnLaunch) ?? false
            let showProjectBrowser = try container.decodeIfPresent(Bool.self, forKey: .showProjectBrowserOnLaunch) ?? true
            launchBehavior = restoreLastProject && !showProjectBrowser ? .restoreLastProject : .showProjectBrowser
        }
        language = container.decodeSettingsEnum(AppLanguage.self, forKey: .language, default: .system)
        autosaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autosaveEnabled) ?? true
        autosaveIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .autosaveIntervalSeconds) ?? 10
        defaultNewProjectTemplate = try container.decodeIfPresent(String.self, forKey: .defaultNewProjectTemplate) ?? "Blank"
        blankProjectStart = container.decodeSettingsEnum(BlankProjectStart.self, forKey: .blankProjectStart, default: .oneEmptyScene)
        defaultSplitMode = container.decodeSettingsEnum(SegmentType.self, forKey: .defaultSplitMode, default: .paragraph)
        confirmBeforeDeleting = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDeleting) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchBehavior, forKey: .launchBehavior)
        try container.encode(language, forKey: .language)
        try container.encode(autosaveEnabled, forKey: .autosaveEnabled)
        try container.encode(autosaveIntervalSeconds, forKey: .autosaveIntervalSeconds)
        try container.encode(defaultNewProjectTemplate, forKey: .defaultNewProjectTemplate)
        try container.encode(blankProjectStart, forKey: .blankProjectStart)
        try container.encode(defaultSplitMode, forKey: .defaultSplitMode)
        try container.encode(confirmBeforeDeleting, forKey: .confirmBeforeDeleting)
    }
}

enum LaunchBehavior: String, Codable, CaseIterable, Identifiable {
    case showProjectBrowser
    case restoreLastProject

    var id: String { rawValue }

    func shouldRestoreLastProject(hasOpenProject: Bool, hasRecentProject: Bool) -> Bool {
        self == .restoreLastProject && !hasOpenProject && hasRecentProject
    }
}

enum BlankProjectStart: String, Codable, CaseIterable, Identifiable {
    case noScenes = "No scenes"
    case oneEmptyScene = "One empty scene"

    var id: String { rawValue }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case russian

    var id: String { rawValue }

    /// Native name of the language. `.system` has no native name and is
    /// localized through `displayName(in:)` in the language picker.
    var displayName: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .spanish: "Español"
        case .russian: "Русский"
        }
    }

    func displayName(in interfaceLanguage: AppLanguage) -> String {
        guard self == .system else { return displayName }
        return L10n.tr("language.system", language: interfaceLanguage)
    }
}

struct ProjectSettingsOverride: Codable, Hashable {
    var wordsPerMinute: Int?
    var defaultSplitMode: SegmentType?

    init(wordsPerMinute: Int? = nil, defaultSplitMode: SegmentType? = nil) {
        self.wordsPerMinute = wordsPerMinute
        self.defaultSplitMode = defaultSplitMode
    }

    enum CodingKeys: String, CodingKey {
        case wordsPerMinute
        case defaultSplitMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wordsPerMinute = try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute)
        defaultSplitMode = try container.decodeIfPresent(SegmentType.self, forKey: .defaultSplitMode)
    }
}

/// Per-project and per-video-type rhythm-review thresholds (F26).
struct RhythmThresholds: Codable, Hashable, Sendable {
    var longSentenceWordLimit: Int?
    var uncoveredSecondsLimit: TimeInterval?
    var sceneLengthRatioLimit: Double?
    var hookSecondsLimit: TimeInterval?

    init(
        longSentenceWordLimit: Int? = nil,
        uncoveredSecondsLimit: TimeInterval? = nil,
        sceneLengthRatioLimit: Double? = nil,
        hookSecondsLimit: TimeInterval? = nil
    ) {
        self.longSentenceWordLimit = longSentenceWordLimit
        self.uncoveredSecondsLimit = uncoveredSecondsLimit
        self.sceneLengthRatioLimit = sceneLengthRatioLimit
        self.hookSecondsLimit = hookSecondsLimit
    }

    enum CodingKeys: String, CodingKey {
        case longSentenceWordLimit
        case uncoveredSecondsLimit
        case sceneLengthRatioLimit
        case hookSecondsLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        longSentenceWordLimit = try container.decodeIfPresent(Int.self, forKey: .longSentenceWordLimit)
        uncoveredSecondsLimit = try container.decodeIfPresent(TimeInterval.self, forKey: .uncoveredSecondsLimit)
        sceneLengthRatioLimit = try container.decodeIfPresent(Double.self, forKey: .sceneLengthRatioLimit)
        hookSecondsLimit = try container.decodeIfPresent(TimeInterval.self, forKey: .hookSecondsLimit)
    }
}

struct EditorPreferences: Codable, Hashable {
    var wordsPerMinute: Int
    var fontSize: Double
    var spellcheck: Bool
    var smartQuotes: Bool
    var showWordCount: Bool
    var showSceneDuration: Bool
    var showAIReviewPanel: Bool
    var defaultNotesVisibility: NotesDefaultVisibility

    init(
        wordsPerMinute: Int,
        fontSize: Double,
        spellcheck: Bool,
        smartQuotes: Bool,
        showWordCount: Bool,
        showSceneDuration: Bool,
        showAIReviewPanel: Bool,
        defaultNotesVisibility: NotesDefaultVisibility = .collapsed
    ) {
        self.wordsPerMinute = wordsPerMinute
        self.fontSize = fontSize
        self.spellcheck = spellcheck
        self.smartQuotes = smartQuotes
        self.showWordCount = showWordCount
        self.showSceneDuration = showSceneDuration
        self.showAIReviewPanel = showAIReviewPanel
        self.defaultNotesVisibility = defaultNotesVisibility
    }

    enum CodingKeys: String, CodingKey {
        case wordsPerMinute
        case fontSize
        case spellcheck
        case smartQuotes
        case showWordCount
        case showSceneDuration
        case showAIReviewPanel
        case defaultNotesVisibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wordsPerMinute = try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? 150
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 22
        spellcheck = try container.decodeIfPresent(Bool.self, forKey: .spellcheck) ?? true
        smartQuotes = try container.decodeIfPresent(Bool.self, forKey: .smartQuotes) ?? true
        showWordCount = try container.decodeIfPresent(Bool.self, forKey: .showWordCount) ?? true
        showSceneDuration = try container.decodeIfPresent(Bool.self, forKey: .showSceneDuration) ?? true
        showAIReviewPanel = try container.decodeIfPresent(Bool.self, forKey: .showAIReviewPanel) ?? true
        defaultNotesVisibility = container.decodeSettingsEnum(NotesDefaultVisibility.self, forKey: .defaultNotesVisibility, default: .collapsed)
    }
}

enum NotesDefaultVisibility: String, Codable, CaseIterable, Identifiable {
    case collapsed = "Collapsed"
    case expanded = "Expanded"

    var id: String { rawValue }
}

struct AIPreferences: Codable, Hashable {
    var provider: AIProviderKind
    var model: String
    var baseURL: String
    var temperature: Double
    var maxTokens: Int
    var privacyMode: Bool
    var enableInlineAutocomplete: Bool

    enum CodingKeys: String, CodingKey {
        case provider
        case model
        case baseURL
        case temperature
        case maxTokens
        case privacyMode
        case enableInlineAutocomplete
    }

    init(
        provider: AIProviderKind,
        model: String,
        baseURL: String,
        temperature: Double,
        maxTokens: Int,
        privacyMode: Bool,
        enableInlineAutocomplete: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.baseURL = baseURL
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.privacyMode = privacyMode
        self.enableInlineAutocomplete = enableInlineAutocomplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = container.decodeSettingsEnum(AIProviderKind.self, forKey: .provider, default: .disabled)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4.1-mini"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.4
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 420
        privacyMode = try container.decodeIfPresent(Bool.self, forKey: .privacyMode) ?? true
        enableInlineAutocomplete = try container.decodeIfPresent(Bool.self, forKey: .enableInlineAutocomplete) ?? true
    }
}

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case disabled = "Disabled"
    case openAICompatible = "OpenAI-compatible"
    case openRouter = "OpenRouter"
    case groq = "Groq"
    case googleAIStudio = "Google AI Studio"

    var id: String { rawValue }

    var keychainAccount: String {
        switch self {
        case .googleAIStudio: "FrameScript.GoogleAIStudio"
        default: rawValue
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AIProviderKind(rawValue: value) ?? .disabled
    }
}

struct VoicePreferences: Codable, Hashable {
    var provider: VoiceProviderKind
    var voiceIdentifier: String
    var speed: Double
    var pitch: Double
    var pausesEnabled: Bool
    var exportFormat: String

    enum CodingKeys: String, CodingKey {
        case provider
        case voiceIdentifier
        case speed
        case pitch
        case pausesEnabled
        case exportFormat
    }

    init(
        provider: VoiceProviderKind,
        voiceIdentifier: String,
        speed: Double,
        pitch: Double,
        pausesEnabled: Bool,
        exportFormat: String
    ) {
        self.provider = provider
        self.voiceIdentifier = voiceIdentifier
        self.speed = speed
        self.pitch = pitch
        self.pausesEnabled = pausesEnabled
        self.exportFormat = exportFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = container.decodeSettingsEnum(VoiceProviderKind.self, forKey: .provider, default: .system)
        voiceIdentifier = try container.decodeIfPresent(String.self, forKey: .voiceIdentifier) ?? ""
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        pitch = try container.decodeIfPresent(Double.self, forKey: .pitch) ?? 1
        pausesEnabled = try container.decodeIfPresent(Bool.self, forKey: .pausesEnabled) ?? true
        exportFormat = try container.decodeIfPresent(String.self, forKey: .exportFormat) ?? "m4a"
    }
}

enum VoiceProviderKind: String, Codable, CaseIterable, Identifiable {
    case system = "macOS System Voice"
    case ai = "AI TTS Provider"

    var id: String { rawValue }
}

struct ExportPreferences: Codable, Hashable {
    var defaultFormat: ExportFormat
    var includeTimestamps: Bool
    var includeSectionNames: Bool
    var includeBRoll: Bool
    var includeEditingNotes: Bool
    var includeAINotes: Bool
    var teleprompterFormatting: Bool
    var defaultExportFolder: String
    var defaultExportFolderBookmarkData: Data?

    enum CodingKeys: String, CodingKey {
        case defaultFormat
        case includeTimestamps
        case includeSectionNames
        case includeBRoll
        case includeEditingNotes
        case includeAINotes
        case teleprompterFormatting
        case defaultExportFolder
        case defaultExportFolderBookmarkData
    }

    init(
        defaultFormat: ExportFormat,
        includeTimestamps: Bool,
        includeSectionNames: Bool,
        includeBRoll: Bool,
        includeEditingNotes: Bool,
        includeAINotes: Bool,
        teleprompterFormatting: Bool,
        defaultExportFolder: String,
        defaultExportFolderBookmarkData: Data?
    ) {
        self.defaultFormat = defaultFormat
        self.includeTimestamps = includeTimestamps
        self.includeSectionNames = includeSectionNames
        self.includeBRoll = includeBRoll
        self.includeEditingNotes = includeEditingNotes
        self.includeAINotes = includeAINotes
        self.teleprompterFormatting = teleprompterFormatting
        self.defaultExportFolder = defaultExportFolder
        self.defaultExportFolderBookmarkData = defaultExportFolderBookmarkData
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultFormat = container.decodeSettingsEnum(ExportFormat.self, forKey: .defaultFormat, default: .productionOutline)
        includeTimestamps = try container.decodeIfPresent(Bool.self, forKey: .includeTimestamps) ?? true
        includeSectionNames = try container.decodeIfPresent(Bool.self, forKey: .includeSectionNames) ?? true
        includeBRoll = try container.decodeIfPresent(Bool.self, forKey: .includeBRoll) ?? true
        includeEditingNotes = try container.decodeIfPresent(Bool.self, forKey: .includeEditingNotes) ?? true
        includeAINotes = try container.decodeIfPresent(Bool.self, forKey: .includeAINotes) ?? false
        teleprompterFormatting = try container.decodeIfPresent(Bool.self, forKey: .teleprompterFormatting) ?? false
        defaultExportFolder = try container.decodeIfPresent(String.self, forKey: .defaultExportFolder) ?? ""
        defaultExportFolderBookmarkData = try container.decodeIfPresent(Data.self, forKey: .defaultExportFolderBookmarkData)
    }
}

struct WindowPreferences: Codable, Hashable {
    var sidebarDefaultVisible: Bool
    var sidebarWidth: Double
    var focusModeBehavior: FocusModeBehavior

    enum CodingKeys: String, CodingKey {
        case sidebarDefaultVisible
        case sidebarWidth
        case focusModeBehavior
    }

    init(sidebarDefaultVisible: Bool, sidebarWidth: Double, focusModeBehavior: FocusModeBehavior) {
        self.sidebarDefaultVisible = sidebarDefaultVisible
        self.sidebarWidth = sidebarWidth
        self.focusModeBehavior = focusModeBehavior
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sidebarDefaultVisible = try container.decodeIfPresent(Bool.self, forKey: .sidebarDefaultVisible) ?? true
        sidebarWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 195
        focusModeBehavior = container.decodeSettingsEnum(FocusModeBehavior.self, forKey: .focusModeBehavior, default: .hidePanels)
    }
}

enum FocusModeBehavior: String, Codable, CaseIterable, Identifiable {
    case hidePanels = "Hide panels"
    case keepSidebar = "Keep sidebar"

    var id: String { rawValue }
}

enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case plainText = "Plain text"
    case markdown = "Markdown"
    case csv = "CSV"
    case productionOutline = "Production outline"

    var id: String { rawValue }
}

struct ExportPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var format: ExportFormat
}

extension GeneralPreferences {
    static let defaults = GeneralPreferences(
        launchBehavior: .showProjectBrowser,
        language: .system,
        autosaveEnabled: true,
        autosaveIntervalSeconds: 10,
        defaultNewProjectTemplate: "Blank",
        blankProjectStart: .oneEmptyScene,
        defaultSplitMode: .paragraph,
        confirmBeforeDeleting: true
    )
}

extension EditorPreferences {
    static let defaults = EditorPreferences(
        wordsPerMinute: 150,
        fontSize: 22,
        spellcheck: true,
        smartQuotes: true,
        showWordCount: true,
        showSceneDuration: true,
        showAIReviewPanel: true,
        defaultNotesVisibility: .collapsed
    )
}

extension AIPreferences {
    static let defaults = AIPreferences(
        provider: .disabled,
        model: "gpt-4.1-mini",
        baseURL: "",
        temperature: 0.4,
        maxTokens: 420,
        privacyMode: true,
        enableInlineAutocomplete: true
    )
}

extension VoicePreferences {
    static let defaults = VoicePreferences(
        provider: .system,
        voiceIdentifier: "",
        speed: 1.0,
        pitch: 1.0,
        pausesEnabled: true,
        exportFormat: "m4a"
    )
}

extension ExportPreferences {
    static let defaults = ExportPreferences(
        defaultFormat: .productionOutline,
        includeTimestamps: true,
        includeSectionNames: true,
        includeBRoll: true,
        includeEditingNotes: true,
        includeAINotes: false,
        teleprompterFormatting: false,
        defaultExportFolder: "",
        defaultExportFolderBookmarkData: nil
    )
}

extension WindowPreferences {
    static let defaults = WindowPreferences(
        sidebarDefaultVisible: true,
        sidebarWidth: 195,
        focusModeBehavior: .hidePanels
    )
}

extension AppSettings {
    static let defaults = AppSettings(
        generalPreferences: .defaults,
        theme: .system,
        accentColor: .sage,
        editorPreferences: .defaults,
        aiPreferences: .defaults,
        voicePreferences: .defaults,
        exportPreferences: .defaults,
        windowPreferences: .defaults
    )
}

// Settings must survive an enum case that this build does not know yet. The
// keys and raw values themselves stay unchanged; only decoding is lossy.
private extension KeyedDecodingContainer {
    func decodeSettingsEnum<T>(
        _ type: T.Type,
        forKey key: Key,
        default defaultValue: @autoclosure () -> T
    ) -> T where T: RawRepresentable, T.RawValue == String {
        decodeSettingsEnumIfPresent(type, forKey: key) ?? defaultValue()
    }

    func decodeSettingsEnumIfPresent<T>(
        _ type: T.Type,
        forKey key: Key
    ) -> T? where T: RawRepresentable, T.RawValue == String {
        guard let raw = try? decodeIfPresent(String.self, forKey: key) else { return nil }
        return T(rawValue: raw)
    }
}

/// Shortcut overrides were historically encoded as an array of alternating
/// command/value pairs because `ShortcutCommand` is a dictionary key. Accept
/// both that legacy array and a plain object, dropping unknown commands.
private struct ShortcutOverridesPayload: Decodable {
    var values: [String: ShortcutOverride]

    private struct LossyOverride: Decodable {
        let value: ShortcutOverride

        init(from decoder: Decoder) throws {
            value = (try? ShortcutOverride(from: decoder)) ?? .unassigned
        }
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.singleValueContainer().decode([String: LossyOverride].self) {
            values = object.mapValues(\.value)
            return
        }

        var container = try decoder.unkeyedContainer()
        var result: [String: ShortcutOverride] = [:]
        while !container.isAtEnd {
            let key = try container.decode(String.self)
            let value = try container.decode(LossyOverride.self)
            result[key] = value.value
        }
        values = result
    }
}

/// One malformed video-type threshold map entry must not discard the others.
private struct RhythmThresholdsPayload: Decodable {
    var value: RhythmThresholds

    init(from decoder: Decoder) throws {
        value = (try? RhythmThresholds(from: decoder)) ?? RhythmThresholds()
    }
}
