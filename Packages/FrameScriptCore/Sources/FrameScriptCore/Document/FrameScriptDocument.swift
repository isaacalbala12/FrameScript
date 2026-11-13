import Foundation

/// Duration values read from disk are untrusted input. Keep them inside the
/// range the duration UI can safely format and compare.
private let maximumStoredDuration: TimeInterval = 86_400

private func sanitizedStoredDuration(
    _ value: TimeInterval,
    minimum: TimeInterval = 0,
    rejectingValuesAboveMaximum: Bool = false
) -> TimeInterval {
    guard value.isFinite else { return minimum }
    guard value <= maximumStoredDuration else {
        return rejectingValuesAboveMaximum ? minimum : maximumStoredDuration
    }
    return max(value, minimum)
}

private func sanitizedStoredTarget(_ value: TimeInterval?) -> TimeInterval? {
    guard let value, value.isFinite, value >= 0.1, value <= maximumStoredDuration else {
        return nil
    }
    return value
}

/// Version metadata for the `.fscr` project file.
public enum FrameScriptFormat {
    /// Files written by this build always use schema version 4.
    public static let currentFileVersion = 4
    /// Readers can open every schema version from the first public release.
    public static let supportedFileVersions: ClosedRange<Int> = 1...currentFileVersion
}

/// The on-disk `.fscr` document.
///
/// This is a value-only representation of a project. The app keeps its
/// `@Observable` model classes and maps them to this document at the file
/// boundary; the `framescript` CLI and the MCP server use the document directly.
///
/// Nested types are namespaced under this document so they never collide with
/// app model types (`SectionType`, `BRollItem`, ...).
public struct FrameScriptDocument: Codable, Sendable, Equatable {
    public var fileVersion: Int
    public var project: Project

    public init(fileVersion: Int = FrameScriptFormat.currentFileVersion, project: Project) {
        self.fileVersion = fileVersion
        self.project = project
    }

    enum CodingKeys: String, CodingKey {
        case fileVersion
        case project
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileVersion = try container.decode(Int.self, forKey: .fileVersion)
        project = try container.decode(Project.self, forKey: .project)
    }
}

/// Everything the schema needs beyond the original v3 fields.
///
/// All new fields are optional or defaulted so v1-v3 files still open. Raw
/// values for the legacy enums must never change: they are persisted.
extension FrameScriptDocument {
    // MARK: Legacy enums (raw values are persisted, do not rename)

    public enum SectionType: String, Codable, Sendable, CaseIterable {
        case hook = "Hook"
        case problem = "Problem"
        case whyThisMatters = "Why this matters"
        case explanation = "Explanation"
        case example = "Example"
        case takeaway = "Takeaway"
        case cta = "CTA"
        case custom = "Custom"
    }

    public enum SegmentType: String, Codable, Sendable, CaseIterable {
        case scene
        case paragraph
        case sentence
    }

    public enum BRollSourceType: String, Codable, Sendable, CaseIterable {
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
    }

    public enum BRollStatus: String, Codable, Sendable, CaseIterable {
        case idea = "Idea"
        case planned = "Planned"
        case sourced = "Sourced"
        case done = "Done"
    }

    public enum AICommentStatus: String, Codable, Sendable, CaseIterable {
        case new
        case dismissed
        case applied
    }

    public enum AICommentSeverity: String, Codable, Sendable, CaseIterable {
        case note
        case suggestion
        case important
    }

    public enum ExportFormat: String, Codable, Sendable, CaseIterable {
        case plainText = "Plain text"
        case markdown = "Markdown"
        case csv = "CSV"
        case productionOutline = "Production outline"
    }

    // MARK: v4 enums

    /// Pending/done state for an editing annotation (D7 / F16).
    public enum EditingStatus: String, Codable, Sendable, CaseIterable {
        case pending
        case done
    }

    /// Production status shown on the video dashboard (F25).
    public enum ProductionStatus: String, Codable, Sendable, CaseIterable {
        case idea
        case outline
        case script
        case recorded
        case edited
        case published
    }

    /// How a recorded take was rated while recording (F10).
    public enum TakeRating: String, Codable, Sendable, CaseIterable {
        case good
        case bad
        case safe
        case unrated
    }

    /// Source tag for a project asset (F14).
    public enum AssetKind: String, Codable, Sendable, CaseIterable {
        case camera = "CAM"
        case obs = "OBS"
        case screenshot
        case web
        case music
        case graphic
        case thumbnail
    }

    /// Verification state for a claim (F20).
    public enum ClaimStatus: String, Codable, Sendable, CaseIterable {
        case confirmed
        case probable
        case rumor
    }

    /// Manual production task category (F16).
    public enum ChecklistTaskKind: String, Codable, Sendable, CaseIterable {
        case record
        case acquire
        case edit
        case research
        case other
    }

    /// Short-form clip format (F24).
    public enum ShortClipFormat: String, Codable, Sendable, CaseIterable {
        case reel
        case short
        case story
    }

    /// Short-form clip lifecycle (F24).
    public enum ShortClipStatus: String, Codable, Sendable, CaseIterable {
        case idea
        case draft
        case ready
        case published
    }

    // MARK: Shared value types

    public struct TextAnchor: Codable, Sendable, Equatable, Hashable {
        public var startUTF16: Int
        public var lengthUTF16: Int
        public var selectedText: String
        public var prefixContext: String
        public var suffixContext: String

        public init(
            startUTF16: Int,
            lengthUTF16: Int,
            selectedText: String,
            prefixContext: String = "",
            suffixContext: String = ""
        ) {
            self.startUTF16 = max(0, startUTF16)
            self.lengthUTF16 = max(0, lengthUTF16)
            self.selectedText = selectedText
            self.prefixContext = prefixContext
            self.suffixContext = suffixContext
        }

        public var nsRange: NSRange {
            NSRange(location: startUTF16, length: lengthUTF16)
        }

        enum CodingKeys: String, CodingKey {
            case startUTF16
            case lengthUTF16
            case selectedText
            case prefixContext
            case suffixContext
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Keep raw values here. Migration and validation reject unsafe
            // ranges; clamping would hide corrupt input.
            startUTF16 = try container.decodeIfPresent(Int.self, forKey: .startUTF16) ?? 0
            lengthUTF16 = try container.decodeIfPresent(Int.self, forKey: .lengthUTF16) ?? 0
            selectedText = try container.decodeIfPresent(String.self, forKey: .selectedText) ?? ""
            prefixContext = try container.decodeIfPresent(String.self, forKey: .prefixContext) ?? ""
            suffixContext = try container.decodeIfPresent(String.self, forKey: .suffixContext) ?? ""
        }
    }

    public struct ProjectSettingsOverride: Codable, Sendable, Equatable {
        public var wordsPerMinute: Int?
        public var defaultSplitMode: SegmentType?

        public init(
            wordsPerMinute: Int? = nil,
            defaultSplitMode: SegmentType? = nil
        ) {
            self.wordsPerMinute = wordsPerMinute
            self.defaultSplitMode = defaultSplitMode
        }

        enum CodingKeys: String, CodingKey {
            case wordsPerMinute
            case defaultSplitMode
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wordsPerMinute = try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute)
            defaultSplitMode = try container.decodeIfPresent(SegmentType.self, forKey: .defaultSplitMode)
        }
    }

    /// Per-project rhythm-review thresholds (F26). `nil` fields use app defaults.
    public struct RhythmThresholds: Codable, Sendable, Equatable {
        public var longSentenceWordLimit: Int?
        public var uncoveredSecondsLimit: TimeInterval?
        public var sceneLengthRatioLimit: Double?
        public var hookSecondsLimit: TimeInterval?

        public init(
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            longSentenceWordLimit = try container.decodeIfPresent(Int.self, forKey: .longSentenceWordLimit)
            uncoveredSecondsLimit = try container.decodeIfPresent(TimeInterval.self, forKey: .uncoveredSecondsLimit)
            sceneLengthRatioLimit = try container.decodeIfPresent(Double.self, forKey: .sceneLengthRatioLimit)
            hookSecondsLimit = try container.decodeIfPresent(TimeInterval.self, forKey: .hookSecondsLimit)
        }
    }

    public struct ExportPreset: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var name: String
        public var format: ExportFormat

        public init(id: UUID = UUID(), name: String, format: ExportFormat) {
            self.id = id
            self.name = name
            self.format = format
        }

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case format
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
            format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? .productionOutline
        }
    }

    public struct TextSegment: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var sceneID: UUID
        public var order: Int
        public var sourceText: String
        public var segmentType: SegmentType
        public var timingEstimate: TimeInterval

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case sceneID
            case order
            case sourceText
            case segmentType
            case timingEstimate
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sceneID = try container.decode(UUID.self, forKey: .sceneID)
            order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
            sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText) ?? ""
            segmentType = try container.decodeIfPresent(SegmentType.self, forKey: .segmentType) ?? .scene
            timingEstimate = try container.decodeIfPresent(TimeInterval.self, forKey: .timingEstimate) ?? 0
        }
    }

    public struct AIComment: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var sceneID: UUID?
        public var segmentID: UUID?
        public var type: String
        public var severity: AICommentSeverity
        public var message: String
        public var suggestion: String
        public var status: AICommentStatus

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case sceneID
            case segmentID
            case type
            case severity
            case message
            case suggestion
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sceneID = try container.decodeIfPresent(UUID.self, forKey: .sceneID)
            segmentID = try container.decodeIfPresent(UUID.self, forKey: .segmentID)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
            severity = try container.decodeIfPresent(AICommentSeverity.self, forKey: .severity) ?? .note
            message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            suggestion = try container.decodeIfPresent(String.self, forKey: .suggestion) ?? ""
            status = try container.decodeIfPresent(AICommentStatus.self, forKey: .status) ?? .new
        }
    }

    public struct BRollItem: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var textAnchor: TextAnchor?
        public var linkedSegmentID: UUID?
        public var templateType: String
        public var sourceType: BRollSourceType
        public var descriptionText: String
        public var mood: String
        public var framing: String
        public var motion: String
        public var duration: TimeInterval
        public var notes: String
        public var status: BRollStatus

        public init(
            id: UUID = UUID(),
            textAnchor: TextAnchor? = nil,
            linkedSegmentID: UUID? = nil,
            templateType: String = "",
            sourceType: BRollSourceType = .custom,
            descriptionText: String = "",
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

        enum CodingKeys: String, CodingKey {
            case id
            case textAnchor
            case linkedSegmentID
            case templateType
            case sourceType
            case descriptionText
            case mood
            case framing
            case motion
            case duration
            case notes
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            textAnchor = try container.decodeIfPresent(TextAnchor.self, forKey: .textAnchor)
            linkedSegmentID = try container.decodeIfPresent(UUID.self, forKey: .linkedSegmentID)
            templateType = try container.decodeIfPresent(String.self, forKey: .templateType) ?? ""
            sourceType = try container.decodeIfPresent(BRollSourceType.self, forKey: .sourceType) ?? .custom
            descriptionText = try container.decodeIfPresent(String.self, forKey: .descriptionText) ?? ""
            mood = try container.decodeIfPresent(String.self, forKey: .mood) ?? ""
            framing = try container.decodeIfPresent(String.self, forKey: .framing) ?? ""
            motion = try container.decodeIfPresent(String.self, forKey: .motion) ?? ""
            duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
            notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
            status = try container.decodeIfPresent(BRollStatus.self, forKey: .status) ?? .idea
        }
    }

    public struct EditingItem: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var textAnchor: TextAnchor?
        public var linkedSegmentID: UUID?
        public var templateType: String
        public var cutStyle: String
        public var transition: String
        public var subtitleStyle: String
        public var emphasis: String
        public var zoom: String
        public var sfx: String
        public var musicCue: String
        public var graphics: String
        public var notes: String
        public var status: EditingStatus

        public init(
            id: UUID = UUID(),
            textAnchor: TextAnchor? = nil,
            linkedSegmentID: UUID? = nil,
            templateType: String = "",
            cutStyle: String = "",
            transition: String = "",
            subtitleStyle: String = "",
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

        enum CodingKeys: String, CodingKey {
            case id
            case textAnchor
            case linkedSegmentID
            case templateType
            /// v1-v3 wrote `cutStyle` under the key `description`.
            case description
            /// Read-only legacy alias for `description`.
            case cutStyle
            case transition
            case subtitleStyle
            case emphasis
            case zoom
            case sfx
            case musicCue
            case graphics
            case notes
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            textAnchor = try container.decodeIfPresent(TextAnchor.self, forKey: .textAnchor)
            linkedSegmentID = try container.decodeIfPresent(UUID.self, forKey: .linkedSegmentID)
            templateType = try container.decodeIfPresent(String.self, forKey: .templateType) ?? ""
            cutStyle = try container.decodeIfPresent(String.self, forKey: .description)
                ?? container.decodeIfPresent(String.self, forKey: .cutStyle)
                ?? ""
            transition = try container.decodeIfPresent(String.self, forKey: .transition) ?? ""
            subtitleStyle = try container.decodeIfPresent(String.self, forKey: .subtitleStyle) ?? ""
            emphasis = try container.decodeIfPresent(String.self, forKey: .emphasis) ?? ""
            zoom = try container.decodeIfPresent(String.self, forKey: .zoom) ?? ""
            sfx = try container.decodeIfPresent(String.self, forKey: .sfx) ?? ""
            musicCue = try container.decodeIfPresent(String.self, forKey: .musicCue) ?? ""
            graphics = try container.decodeIfPresent(String.self, forKey: .graphics) ?? ""
            notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
            status = try container.decodeIfPresent(EditingStatus.self, forKey: .status) ?? .pending
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encodeIfPresent(textAnchor, forKey: .textAnchor)
            try container.encodeIfPresent(linkedSegmentID, forKey: .linkedSegmentID)
            try container.encode(templateType, forKey: .templateType)
            // Keep the historical key so v1-v3 tooling can still read the value.
            try container.encode(cutStyle, forKey: .description)
            try container.encode(transition, forKey: .transition)
            try container.encode(subtitleStyle, forKey: .subtitleStyle)
            try container.encode(emphasis, forKey: .emphasis)
            try container.encode(zoom, forKey: .zoom)
            try container.encode(sfx, forKey: .sfx)
            try container.encode(musicCue, forKey: .musicCue)
            try container.encode(graphics, forKey: .graphics)
            try container.encode(notes, forKey: .notes)
            try container.encode(status, forKey: .status)
        }
    }

    // MARK: Recording (F10, F11)

    public struct Take: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var number: Int
        public var startedAt: Date
        public var duration: TimeInterval
        public var filePath: String
        public var bookmarkData: Data?
        public var rating: TakeRating
        public var note: String
        /// BCP-47-ish language code (`es`, `en`, ...). Empty means the scene's original language.
        public var languageCode: String
        /// Text shown in the teleprompter when this take was recorded (F10).
        public var readText: String
        /// Hash of the scene text used for this take (F10/F11).
        public var sceneTextHash: String

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case number
            case startedAt
            case duration
            case filePath
            case bookmarkData
            case rating
            case note
            case languageCode
            case readText
            case sceneTextHash
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 1
            startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
            duration = sanitizedStoredDuration(
                try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0,
                rejectingValuesAboveMaximum: true
            )
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath) ?? ""
            bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
            rating = try container.decodeIfPresent(TakeRating.self, forKey: .rating) ?? .unrated
            note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
            languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
            readText = try container.decodeIfPresent(String.self, forKey: .readText) ?? ""
            sceneTextHash = try container.decodeIfPresent(String.self, forKey: .sceneTextHash) ?? ""
        }
    }

    /// One translated variant of a scene (D1 / F22).
    ///
    /// B-roll and editing notes are shared with the original scene and stay
    /// anchored to it. Takes, durations and text are per language. A variant is
    /// stale when `sourceHash` no longer matches the original text; callers
    /// derive that with `isStale(comparedToOriginal:)`.
    public struct SceneLanguageVariant: Codable, Sendable, Equatable {
        public var languageCode: String
        public var text: String
        public var sourceHash: String
        public var takes: [Take]
        public var estimatedDuration: TimeInterval
        public var actualDuration: TimeInterval

        public init(
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

        enum CodingKeys: String, CodingKey {
            case languageCode
            case text
            case sourceHash
            case takes
            case estimatedDuration
            case actualDuration
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            sourceHash = try container.decodeIfPresent(String.self, forKey: .sourceHash) ?? ""
            takes = try container.decodeIfPresent([Take].self, forKey: .takes) ?? []
            estimatedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedDuration) ?? 0
            actualDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .actualDuration) ?? 0
        }

        public func isStale(comparedToOriginal text: String) -> Bool {
            sourceHash != FrameScriptDocument.TextHash.hash(text)
        }
    }

    // MARK: Scene

    public struct Scene: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var order: Int
        public var sectionType: SectionType
        public var title: String
        public var scriptText: String
        public var notes: String
        public var estimatedDuration: TimeInterval
        public var textSegments: [TextSegment]
        public var aiComments: [AIComment]
        public var bRollItems: [BRollItem]
        public var editingItems: [EditingItem]
        public var targetDuration: TimeInterval?
        public var takes: [Take]
        public var languageVariants: [SceneLanguageVariant]
        /// OBS scene to switch to when recording this scene (F10).
        public var obsSceneName: String?

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case order
            case sectionType
            case title
            case scriptText
            case notes
            case estimatedDuration
            case textSegments
            case aiComments
            case bRollItems
            case editingItems
            case targetDuration
            case takes
            case languageVariants
            case obsSceneName
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
            sectionType = try container.decodeIfPresent(SectionType.self, forKey: .sectionType) ?? .custom
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            scriptText = try container.decodeIfPresent(String.self, forKey: .scriptText) ?? ""
            notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
            estimatedDuration = sanitizedStoredDuration(
                try container.decodeIfPresent(TimeInterval.self, forKey: .estimatedDuration) ?? 0
            )
            textSegments = try container.decodeIfPresent([TextSegment].self, forKey: .textSegments) ?? []
            aiComments = try container.decodeIfPresent([AIComment].self, forKey: .aiComments) ?? []
            bRollItems = try container.decodeIfPresent([BRollItem].self, forKey: .bRollItems) ?? []
            editingItems = try container.decodeIfPresent([EditingItem].self, forKey: .editingItems) ?? []
            targetDuration = sanitizedStoredTarget(
                try container.decodeIfPresent(TimeInterval.self, forKey: .targetDuration)
            )
            takes = try container.decodeIfPresent([Take].self, forKey: .takes) ?? []
            languageVariants = try container.decodeIfPresent([SceneLanguageVariant].self, forKey: .languageVariants) ?? []
            obsSceneName = try container.decodeIfPresent(String.self, forKey: .obsSceneName)
        }
    }

    // MARK: Production data

    public struct ProjectAsset: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var path: String
        public var bookmarkData: Data?
        public var kind: AssetKind
        public var tags: [String]
        public var linkedSceneIDs: [UUID]
        public var linkedBRollItemIDs: [UUID]
        public var linkedTakeIDs: [UUID]
        public var isCopiedIntoProject: Bool
        public var duration: TimeInterval?
        public var fileSize: Int64?
        public var modifiedAt: Date?
        /// True when the last filesystem check could not find the referenced file.
        public var isLastKnownMissing: Bool

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case path
            case bookmarkData
            case kind
            case tags
            case linkedSceneIDs
            case linkedBRollItemIDs
            case linkedTakeIDs
            case isCopiedIntoProject
            case duration
            case fileSize
            case modifiedAt
            case isLastKnownMissing
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
            bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
            kind = try container.decodeIfPresent(AssetKind.self, forKey: .kind) ?? .web
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            linkedSceneIDs = try container.decodeIfPresent([UUID].self, forKey: .linkedSceneIDs) ?? []
            linkedBRollItemIDs = try container.decodeIfPresent([UUID].self, forKey: .linkedBRollItemIDs) ?? []
            linkedTakeIDs = try container.decodeIfPresent([UUID].self, forKey: .linkedTakeIDs) ?? []
            isCopiedIntoProject = try container.decodeIfPresent(Bool.self, forKey: .isCopiedIntoProject) ?? false
            duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
            modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
            isLastKnownMissing = try container.decodeIfPresent(Bool.self, forKey: .isLastKnownMissing) ?? false
        }
    }

    public struct ChapterOverride: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var sceneID: UUID?
        public var title: String
        public var startSeconds: TimeInterval?
        public var isExcluded: Bool

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case sceneID
            case title
            case startSeconds
            case isExcluded
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            sceneID = try container.decodeIfPresent(UUID.self, forKey: .sceneID)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            startSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .startSeconds)
            isExcluded = try container.decodeIfPresent(Bool.self, forKey: .isExcluded) ?? false
        }
    }

    public struct ThumbnailVariant: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var assetID: UUID?
        public var pairedTitle: String
        public var isChosen: Bool

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case assetID
            case pairedTitle
            case isChosen
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            assetID = try container.decodeIfPresent(UUID.self, forKey: .assetID)
            pairedTitle = try container.decodeIfPresent(String.self, forKey: .pairedTitle) ?? ""
            isChosen = try container.decodeIfPresent(Bool.self, forKey: .isChosen) ?? false
        }
    }

    /// Publishing data for one language (F15 / F22).
    public struct PublishingPack: Codable, Sendable, Equatable {
        public var titleCandidates: [String]
        public var chosenTitle: String
        public var description: String
        public var tags: [String]
        public var hashtags: [String]
        public var pinnedComment: String
        public var communityPost: String
        public var chapterOverrides: [ChapterOverride]
        public var thumbnailVariants: [ThumbnailVariant]
        public var thumbnailConceptNotes: String

        public init(
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

        enum CodingKeys: String, CodingKey {
            case titleCandidates
            case chosenTitle
            case description
            case tags
            case hashtags
            case pinnedComment
            case communityPost
            case chapterOverrides
            case thumbnailVariants
            case thumbnailConceptNotes
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            titleCandidates = try container.decodeIfPresent([String].self, forKey: .titleCandidates) ?? []
            chosenTitle = try container.decodeIfPresent(String.self, forKey: .chosenTitle) ?? ""
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
            hashtags = try container.decodeIfPresent([String].self, forKey: .hashtags) ?? []
            pinnedComment = try container.decodeIfPresent(String.self, forKey: .pinnedComment) ?? ""
            communityPost = try container.decodeIfPresent(String.self, forKey: .communityPost) ?? ""
            chapterOverrides = try container.decodeIfPresent([ChapterOverride].self, forKey: .chapterOverrides) ?? []
            thumbnailVariants = try container.decodeIfPresent([ThumbnailVariant].self, forKey: .thumbnailVariants) ?? []
            thumbnailConceptNotes = try container.decodeIfPresent(String.self, forKey: .thumbnailConceptNotes) ?? ""
        }
    }

    public struct ChecklistTask: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var text: String
        public var kind: ChecklistTaskKind
        public var isDone: Bool
        public var sceneID: UUID?

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case kind
            case isDone
            case sceneID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            kind = try container.decodeIfPresent(ChecklistTaskKind.self, forKey: .kind) ?? .other
            isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
            sceneID = try container.decodeIfPresent(UUID.self, forKey: .sceneID)
        }
    }

    public struct Source: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var url: String
        public var note: String

        public init(id: UUID = UUID(), title: String, url: String = "", note: String = "") {
            self.id = id
            self.title = title
            self.url = url
            self.note = note
        }

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case url
            case note
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        }
    }

    public struct Claim: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var text: String
        public var status: ClaimStatus
        public var sourceIDs: [UUID]
        public var sceneIDs: [UUID]

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case text
            case status
            case sourceIDs
            case sceneIDs
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            status = try container.decodeIfPresent(ClaimStatus.self, forKey: .status) ?? .probable
            sourceIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceIDs) ?? []
            sceneIDs = try container.decodeIfPresent([UUID].self, forKey: .sceneIDs) ?? []
        }
    }

    public struct ComparisonTable: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var header: [String]
        public var rows: [[String]]

        public init(id: UUID = UUID(), title: String, header: [String] = [], rows: [[String]] = []) {
            self.id = id
            self.title = title
            self.header = header
            self.rows = rows
        }

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case header
            case rows
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            header = try container.decodeIfPresent([String].self, forKey: .header) ?? []
            rows = try container.decodeIfPresent([[String]].self, forKey: .rows) ?? []
        }
    }

    public struct GlossaryTerm: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var source: String
        public var target: String
        public var isProtected: Bool

        public init(id: UUID = UUID(), source: String, target: String = "", isProtected: Bool = true) {
            self.id = id
            self.source = source
            self.target = target
            self.isProtected = isProtected
        }

        enum CodingKeys: String, CodingKey {
            case id
            case source
            case target
            case isProtected
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
            target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
            isProtected = try container.decodeIfPresent(Bool.self, forKey: .isProtected) ?? true
        }
    }

    /// A derived short-form clip (F24).
    public struct ShortClip: Codable, Sendable, Equatable, Identifiable {
        public struct SceneSourceHash: Codable, Sendable, Equatable {
            public var sceneID: UUID
            public var hash: String

            public init(sceneID: UUID, hash: String) {
                self.sceneID = sceneID
                self.hash = hash
            }

            enum CodingKeys: String, CodingKey {
                case sceneID
                case hash
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                sceneID = try container.decode(UUID.self, forKey: .sceneID)
                hash = try container.decodeIfPresent(String.self, forKey: .hash) ?? ""
            }
        }

        public var id: UUID
        public var title: String
        public var sourceSceneIDs: [UUID]
        public var anchorSceneID: UUID?
        public var anchor: TextAnchor?
        public var hook: String
        public var adaptedText: String
        public var targetSeconds: TimeInterval
        public var format: ShortClipFormat
        public var onScreenText: String
        public var description: String
        public var hashtags: [String]
        public var sourceHash: String
        public var languageCode: String
        public var sceneSourceHashes: [SceneSourceHash]
        public var status: ShortClipStatus

        public init(
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
            sceneSourceHashes: [SceneSourceHash] = [],
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

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case sourceSceneIDs
            case anchorSceneID
            case anchor
            case hook
            case adaptedText
            case targetSeconds
            case format
            case onScreenText
            case description
            case hashtags
            case sourceHash
            case languageCode
            case sceneSourceHashes
            case status
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            sourceSceneIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceSceneIDs) ?? []
            anchorSceneID = try container.decodeIfPresent(UUID.self, forKey: .anchorSceneID)
            anchor = try container.decodeIfPresent(TextAnchor.self, forKey: .anchor)
            hook = try container.decodeIfPresent(String.self, forKey: .hook) ?? ""
            adaptedText = try container.decodeIfPresent(String.self, forKey: .adaptedText) ?? ""
            targetSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .targetSeconds) ?? 30
            format = try container.decodeIfPresent(ShortClipFormat.self, forKey: .format) ?? .reel
            onScreenText = try container.decodeIfPresent(String.self, forKey: .onScreenText) ?? ""
            description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
            hashtags = try container.decodeIfPresent([String].self, forKey: .hashtags) ?? []
            sourceHash = try container.decodeIfPresent(String.self, forKey: .sourceHash) ?? ""
            languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode) ?? ""
            sceneSourceHashes = try container.decodeIfPresent([SceneSourceHash].self, forKey: .sceneSourceHashes) ?? []
            status = try container.decodeIfPresent(ShortClipStatus.self, forKey: .status) ?? .idea
        }

        public func isStale(comparedToSourceText text: String) -> Bool {
            sourceHash != FrameScriptDocument.TextHash.hash(text)
        }
    }

    /// Snapshot stored inside the project file (D4 / F21).
    public struct VersionSnapshot: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var createdAt: Date
        public var name: String?
        public var isAutomatic: Bool
        public var label: String
        /// zlib-compressed payload, base64-encoded by JSONEncoder.
        public var compressedPayload: Data

        public init(
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

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt
            case name
            case isAutomatic
            case label
            case compressedPayload
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? true
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            compressedPayload = try container.decodeIfPresent(Data.self, forKey: .compressedPayload) ?? Data()
        }
    }

    /// T3 thread reuse map (D2 / F12).
    public struct AIThreadMap: Codable, Sendable, Equatable {
        public var t3ProjectID: String
        public var threadIDsByProviderModel: [String: String]

        public init(t3ProjectID: String = "", threadIDsByProviderModel: [String: String] = [:]) {
            self.t3ProjectID = t3ProjectID
            self.threadIDsByProviderModel = threadIDsByProviderModel
        }

        enum CodingKeys: String, CodingKey {
            case t3ProjectID
            case threadIDsByProviderModel
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            t3ProjectID = try container.decodeIfPresent(String.self, forKey: .t3ProjectID) ?? ""
            threadIDsByProviderModel = try container.decodeIfPresent([String: String].self, forKey: .threadIDsByProviderModel) ?? [:]
        }
    }

    public struct UnparsedSection: Codable, Sendable, Equatable {
        public var heading: String
        public var body: String

        public init(heading: String, body: String) {
            self.heading = heading
            self.body = body
        }

        enum CodingKeys: String, CodingKey {
            case heading
            case body
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heading = try container.decodeIfPresent(String.self, forKey: .heading) ?? ""
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        }
    }

    // MARK: Published-video comparison (F28)

    public struct TranscriptSegment: Codable, Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case text
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try container.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
            end = try container.decodeIfPresent(TimeInterval.self, forKey: .end) ?? 0
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        }
    }

    public struct RetentionPoint: Codable, Sendable, Equatable {
        /// Seconds since the start of the published video.
        public var time: TimeInterval
        /// Percentage of viewers still watching, 0...100.
        public var percent: Double

        public init(time: TimeInterval, percent: Double) {
            self.time = time
            self.percent = percent
        }

        enum CodingKeys: String, CodingKey {
            case time
            case percent
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decodeIfPresent(TimeInterval.self, forKey: .time) ?? 0
            percent = try container.decodeIfPresent(Double.self, forKey: .percent) ?? 0
        }
    }

    public struct PublishedVideoComparison: Codable, Sendable, Equatable {
        public struct SceneResult: Codable, Sendable, Equatable {
            public var sceneID: UUID
            public var realStart: TimeInterval
            public var realEnd: TimeInterval
            public var addedWords: Int
            public var removedWords: Int
            public var coverage: Double
            public var avgRetention: Double
            public var dropMagnitude: Double

            public init(
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

            enum CodingKeys: String, CodingKey {
                case sceneID
                case realStart
                case realEnd
                case addedWords
                case removedWords
                case coverage
                case avgRetention
                case dropMagnitude
            }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                sceneID = try container.decode(UUID.self, forKey: .sceneID)
                realStart = try container.decodeIfPresent(TimeInterval.self, forKey: .realStart) ?? 0
                realEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .realEnd) ?? 0
                addedWords = try container.decodeIfPresent(Int.self, forKey: .addedWords) ?? 0
                removedWords = try container.decodeIfPresent(Int.self, forKey: .removedWords) ?? 0
                coverage = try container.decodeIfPresent(Double.self, forKey: .coverage) ?? 0
                avgRetention = try container.decodeIfPresent(Double.self, forKey: .avgRetention) ?? 0
                dropMagnitude = try container.decodeIfPresent(Double.self, forKey: .dropMagnitude) ?? 0
            }
        }

        public var videoID: String
        public var url: String
        public var title: String
        public var publishedAt: Date?
        public var transcriptSegments: [TranscriptSegment]
        public var retentionPoints: [RetentionPoint]
        public var sceneResults: [SceneResult]
        public var learnings: String
        public var importedAt: Date

        public init(
            videoID: String = "",
            url: String = "",
            title: String = "",
            publishedAt: Date? = nil,
            transcriptSegments: [TranscriptSegment] = [],
            retentionPoints: [RetentionPoint] = [],
            sceneResults: [SceneResult] = [],
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

        enum CodingKeys: String, CodingKey {
            case videoID
            case url
            case title
            case publishedAt
            case transcriptSegments
            case retentionPoints
            case sceneResults
            case learnings
            case importedAt
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            videoID = try container.decodeIfPresent(String.self, forKey: .videoID) ?? ""
            url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
            transcriptSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
            retentionPoints = try container.decodeIfPresent([RetentionPoint].self, forKey: .retentionPoints) ?? []
            sceneResults = try container.decodeIfPresent([SceneResult].self, forKey: .sceneResults) ?? []
            learnings = try container.decodeIfPresent(String.self, forKey: .learnings) ?? ""
            importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    // MARK: Project

    public struct Project: Codable, Sendable, Equatable, Identifiable {
        public var id: UUID
        public var title: String
        public var createdAt: Date
        public var updatedAt: Date
        public var templateID: UUID?
        public var settingsOverride: ProjectSettingsOverride?
        public var exportPresets: [ExportPreset]
        public var scenes: [Scene]
        /// Original script language. Everything else is keyed by language code.
        public var primaryLanguage: String

        // F25 classification
        public var topic: String
        public var videoType: String
        public var productionStatus: ProductionStatus
        public var targetDate: Date?
        public var publishDate: Date?

        // F11 durations and learned speech rate
        public var targetDuration: TimeInterval?
        public var learnedWordsPerMinuteByLanguage: [String: Double]
        /// Per-language reset timestamps. Takes recorded at or before the reset
        /// stop teaching the learner until new takes arrive.
        public var learnedWordsPerMinuteResetAtByLanguage: [String: Date]

        // F14 assets
        public var assets: [ProjectAsset]

        // F15 / F22 publishing, keyed by language code
        public var publishingPacks: [String: PublishingPack]

        // F16 / F26 per-project overrides
        public var checklistTasks: [ChecklistTask]
        public var rhythmThresholdsOverride: RhythmThresholds?

        // F20 sources and claims
        public var sources: [Source]
        public var claims: [Claim]
        public var comparisonTables: [ComparisonTable]

        // F22 translation glossary
        public var glossary: [GlossaryTerm]

        // F24 short clips
        public var clips: [ShortClip]

        // F21 version history
        public var versionHistory: [VersionSnapshot]

        // F12 / D2 T3 thread map
        public var aiThreadMap: AIThreadMap

        // F6 Markdown import leftovers
        public var unparsedSections: [UnparsedSection]

        // F28 published-video comparison, keyed by language code
        public var publishedVideos: [String: PublishedVideoComparison]

        public init(
            id: UUID = UUID(),
            title: String,
            createdAt: Date = Date(),
            updatedAt: Date = Date(),
            templateID: UUID? = nil,
            settingsOverride: ProjectSettingsOverride? = nil,
            exportPresets: [ExportPreset] = [],
            scenes: [Scene] = [],
            primaryLanguage: String = "es",
            topic: String = "",
            videoType: String = "",
            productionStatus: ProductionStatus = .idea,
            targetDate: Date? = nil,
            publishDate: Date? = nil,
            targetDuration: TimeInterval? = nil,
            learnedWordsPerMinuteByLanguage: [String: Double] = [:],
            learnedWordsPerMinuteResetAtByLanguage: [String: Date] = [:],
            assets: [ProjectAsset] = [],
            publishingPacks: [String: PublishingPack] = [:],
            checklistTasks: [ChecklistTask] = [],
            rhythmThresholdsOverride: RhythmThresholds? = nil,
            sources: [Source] = [],
            claims: [Claim] = [],
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
            self.settingsOverride = settingsOverride
            self.exportPresets = exportPresets
            self.scenes = scenes
            self.primaryLanguage = primaryLanguage
            self.topic = topic
            self.videoType = videoType
            self.productionStatus = productionStatus
            self.targetDate = targetDate
            self.publishDate = publishDate
            self.targetDuration = targetDuration
            self.learnedWordsPerMinuteByLanguage = learnedWordsPerMinuteByLanguage
            self.learnedWordsPerMinuteResetAtByLanguage = learnedWordsPerMinuteResetAtByLanguage
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

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case createdAt
            case updatedAt
            case templateID
            case settingsOverride
            case exportPresets
            case scenes
            case primaryLanguage
            case topic
            case videoType
            case productionStatus
            case targetDate
            case publishDate
            case targetDuration
            case learnedWordsPerMinuteByLanguage
            case learnedWordsPerMinuteResetAtByLanguage
            case assets
            case publishingPacks
            case checklistTasks
            case rhythmThresholdsOverride
            case sources
            case claims
            case comparisonTables
            case glossary
            case clips
            case versionHistory
            case aiThreadMap
            case unparsedSections
            case publishedVideos
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
            templateID = try container.decodeIfPresent(UUID.self, forKey: .templateID)
            settingsOverride = try container.decodeIfPresent(ProjectSettingsOverride.self, forKey: .settingsOverride)
            exportPresets = try container.decodeIfPresent([ExportPreset].self, forKey: .exportPresets) ?? []
            scenes = try container.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
            primaryLanguage = try container.decodeIfPresent(String.self, forKey: .primaryLanguage) ?? "es"
            topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
            videoType = try container.decodeIfPresent(String.self, forKey: .videoType) ?? ""
            productionStatus = try container.decodeIfPresent(ProductionStatus.self, forKey: .productionStatus) ?? .idea
            targetDate = try container.decodeIfPresent(Date.self, forKey: .targetDate)
            publishDate = try container.decodeIfPresent(Date.self, forKey: .publishDate)
            targetDuration = sanitizedStoredTarget(
                try container.decodeIfPresent(TimeInterval.self, forKey: .targetDuration)
            )
            learnedWordsPerMinuteByLanguage = (try container.decodeIfPresent(
                [String: Double].self,
                forKey: .learnedWordsPerMinuteByLanguage
            ) ?? [:]).filter { $0.value.isFinite && (30...400).contains($0.value) }
            learnedWordsPerMinuteResetAtByLanguage = try container.decodeIfPresent(
                [String: Date].self,
                forKey: .learnedWordsPerMinuteResetAtByLanguage
            ) ?? [:]
            assets = try container.decodeIfPresent([ProjectAsset].self, forKey: .assets) ?? []
            publishingPacks = try container.decodeIfPresent([String: PublishingPack].self, forKey: .publishingPacks) ?? [:]
            checklistTasks = try container.decodeIfPresent([ChecklistTask].self, forKey: .checklistTasks) ?? []
            rhythmThresholdsOverride = try container.decodeIfPresent(RhythmThresholds.self, forKey: .rhythmThresholdsOverride)
            sources = try container.decodeIfPresent([Source].self, forKey: .sources) ?? []
            claims = try container.decodeIfPresent([Claim].self, forKey: .claims) ?? []
            comparisonTables = try container.decodeIfPresent([ComparisonTable].self, forKey: .comparisonTables) ?? []
            glossary = try container.decodeIfPresent([GlossaryTerm].self, forKey: .glossary) ?? []
            clips = try container.decodeIfPresent([ShortClip].self, forKey: .clips) ?? []
            versionHistory = try container.decodeIfPresent([VersionSnapshot].self, forKey: .versionHistory) ?? []
            aiThreadMap = try container.decodeIfPresent(AIThreadMap.self, forKey: .aiThreadMap) ?? AIThreadMap()
            unparsedSections = try container.decodeIfPresent([UnparsedSection].self, forKey: .unparsedSections) ?? []
            publishedVideos = try container.decodeIfPresent([String: PublishedVideoComparison].self, forKey: .publishedVideos) ?? [:]
        }
    }

    // MARK: Stable text hash (stale variant detection)

    /// FNV-1a 64-bit text hash. Stable across processes and platforms, unlike
    /// `String.hashValue`. Used to detect stale translations and clips.
    public enum TextHash {
        public static func hash(_ text: String) -> String {
            var value: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                value ^= UInt64(byte)
                value = value &* 0x0000_0100_0000_01b3
            }
            return String(value, radix: 16)
        }
    }
}
