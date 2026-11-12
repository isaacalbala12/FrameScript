import Foundation

// MARK: - Import result

/// Result of parsing a Markdown escaleta.
///
/// The document is the lossless, structural representation. Warnings are kept
/// next to it (and not inside it) because their line numbers describe the
/// source text, not the document: re-exporting a document renumbers lines and
/// must not change equality.
public struct EscaletaImportResult: Equatable, Sendable {
    public var document: EscaletaDocument
    public var warnings: [EscaletaWarning]

    public init(document: EscaletaDocument, warnings: [EscaletaWarning] = []) {
        self.document = document
        self.warnings = warnings
    }
}

// MARK: - Warnings

public struct EscaletaWarning: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case missingTitle
        case noScenes
        case emptySection
        case outlineFallback
        case descendingTimestamp
        case invalidTimestamp
        case emptySceneTitle
        case unknownCue
        case inlineCue
        case unknownSection
        case seoMissingTitle
        case seoMissingDescription
        case duplicateTag
        case malformedTable
        case thumbnailTextLength
    }

    public var kind: Kind
    public var message: String
    public var line: Int?

    public init(kind: Kind, message: String, line: Int? = nil) {
        self.kind = kind
        self.message = message
        self.line = line
    }
}

// MARK: - Document

public enum EscaletaDocumentKind: String, Sendable, CaseIterable {
    case escaleta
    case thumbnailConcepts
    case researchDossier
    case other
}

public enum EscaletaSEOLayout: String, Sendable, CaseIterable {
    /// `# Paquete SEO` + `## Campo` sections.
    case sectioned
    /// `## SEO` + `**Campo:**` bold labels.
    case boldLabels
}

public enum EscaletaSourcesPlacement: String, Sendable, CaseIterable {
    case none
    /// A `## Fuentes principales` section next to the SEO block.
    case seoSection
    /// URLs found after `Fuentes oficiales y referencias:` inside the description.
    case descriptionTrailer
}

public enum EscaletaChaptersPlacement: String, Sendable, CaseIterable {
    case none
    case section
    case inlineDescription
}

public struct EscaletaDocument: Equatable, Sendable {
    public var kind: EscaletaDocumentKind
    /// Text before the first H1, preserved verbatim.
    public var preTitleText: String?
    public var title: String
    public var versionNote: String?
    /// The source had a horizontal rule after the title/version note.
    public var separatorAfterIntro: Bool
    public var promise: String?
    public var thesis: String?
    public var outlineHeading: String?
    public var outline: [EscaletaOutlineItem]
    public var scriptHeading: String?
    /// Whether the source had a horizontal rule immediately before the script H1.
    public var scriptSeparator: Bool
    public var scriptIntro: String?
    public var pacingNotes: [String]
    public var scenes: [EscaletaScene]
    public var publishing: EscaletaPublishingPack?
    public var seoHeading: String?
    public var seoHeadingLevel: Int
    public var seoLayout: EscaletaSEOLayout
    public var comparisonTables: [ComparisonTable]
    /// Heading of the comparison-table section, kept even when it is empty.
    public var tableSectionHeading: String?
    /// Non-table text found under a `## Tabla comparativa` heading.
    public var tableSectionNotes: String?
    public var verifyHeading: String?
    public var verificationItems: [EscaletaVerificationItem]
    public var sourcesHeading: String?
    public var sources: [EscaletaSourceEntry]
    public var sourcesPlacement: EscaletaSourcesPlacement
    public var thumbnailConcepts: ThumbnailConceptsDocument?
    /// Everything that could not be mapped, kept verbatim so no content is lost.
    public var unparsedSections: [EscaletaUnparsedSection]

    public init(
        kind: EscaletaDocumentKind = .other,
        preTitleText: String? = nil,
        title: String = "",
        versionNote: String? = nil,
        separatorAfterIntro: Bool = false,
        promise: String? = nil,
        thesis: String? = nil,
        outlineHeading: String? = nil,
        outline: [EscaletaOutlineItem] = [],
        scriptHeading: String? = nil,
        scriptSeparator: Bool = false,
        scriptIntro: String? = nil,
        pacingNotes: [String] = [],
        scenes: [EscaletaScene] = [],
        publishing: EscaletaPublishingPack? = nil,
        seoHeading: String? = nil,
        seoHeadingLevel: Int = 1,
        seoLayout: EscaletaSEOLayout = .sectioned,
        comparisonTables: [ComparisonTable] = [],
        tableSectionHeading: String? = nil,
        tableSectionNotes: String? = nil,
        verifyHeading: String? = nil,
        verificationItems: [EscaletaVerificationItem] = [],
        sourcesHeading: String? = nil,
        sources: [EscaletaSourceEntry] = [],
        sourcesPlacement: EscaletaSourcesPlacement = .none,
        thumbnailConcepts: ThumbnailConceptsDocument? = nil,
        unparsedSections: [EscaletaUnparsedSection] = []
    ) {
        self.kind = kind
        self.preTitleText = preTitleText
        self.title = title
        self.versionNote = versionNote
        self.separatorAfterIntro = separatorAfterIntro
        self.promise = promise
        self.thesis = thesis
        self.outlineHeading = outlineHeading
        self.outline = outline
        self.scriptHeading = scriptHeading
        self.scriptSeparator = scriptSeparator
        self.scriptIntro = scriptIntro
        self.pacingNotes = pacingNotes
        self.scenes = scenes
        self.publishing = publishing
        self.seoHeading = seoHeading
        self.seoHeadingLevel = seoHeadingLevel
        self.seoLayout = seoLayout
        self.comparisonTables = comparisonTables
        self.tableSectionHeading = tableSectionHeading
        self.tableSectionNotes = tableSectionNotes
        self.verifyHeading = verifyHeading
        self.verificationItems = verificationItems
        self.sourcesHeading = sourcesHeading
        self.sources = sources
        self.sourcesPlacement = sourcesPlacement
        self.thumbnailConcepts = thumbnailConcepts
        self.unparsedSections = unparsedSections
    }
}

// MARK: - Outline

public enum EscaletaOutlineMarker: Equatable, Sendable {
    case numbered(Int)
    case bullet
    case plain
}

public struct EscaletaOutlineItem: Equatable, Sendable {
    public var marker: EscaletaOutlineMarker
    public var text: String
    /// Two-space indentation levels (0 = top level).
    public var indent: Int

    public init(marker: EscaletaOutlineMarker, text: String, indent: Int = 0) {
        self.marker = marker
        self.text = text
        self.indent = indent
    }
}

// MARK: - Scenes

public struct EscaletaScene: Equatable, Sendable {
    public var startSeconds: Int?
    public var timestampText: String?
    public var title: String
    public var blocks: [EscaletaSceneBlock]
    /// Original dash between timestamp and title (`—`, `–` or `-`).
    public var separator: String
    /// A horizontal rule followed this scene before the next scene/unknown section.
    public var separatorAfter: Bool
    /// Scenes synthesised from `## Escaleta` when the document has no timestamps.
    /// They are not written back as timestamped scenes by the exporter.
    public var isOutlineFallback: Bool

    public init(
        startSeconds: Int? = nil,
        timestampText: String? = nil,
        title: String,
        blocks: [EscaletaSceneBlock] = [],
        separator: String = "—",
        separatorAfter: Bool = false,
        isOutlineFallback: Bool = false
    ) {
        self.startSeconds = startSeconds
        self.timestampText = timestampText
        self.title = title
        self.blocks = blocks
        self.separator = separator
        self.separatorAfter = separatorAfter
        self.isOutlineFallback = isOutlineFallback
    }

    public var bodyParagraphs: [String] {
        blocks.compactMap {
            if case .paragraph(let text) = $0 { return text }
            return nil
        }
    }

    public var cues: [EscaletaCue] {
        blocks.compactMap {
            if case .cue(let cue) = $0 { return cue }
            return nil
        }
    }

    public var isRehook: Bool {
        cues.contains { $0.kind == .rehook }
    }

    /// Notes derived from `[NOTA DE GRABACIÓN: ...]` and unknown full-line cues.
    /// They are read-only: the source of truth is `blocks`, so export never
    /// duplicates a cue as a note.
    public var notes: [String] {
        blocks.compactMap { block in
            guard case .cue(let cue) = block else { return nil }
            switch cue.kind {
            case .recordingNote:
                return cue.payload ?? ""
            case .unknown:
                return cue.payload.map { "\(cue.label): \($0)" } ?? cue.label
            default:
                return nil
            }
        }
    }

    /// Spoken text only (paragraph blocks, no cues or blockquotes).
    public var text: String {
        bodyParagraphs.joined(separator: "\n\n")
    }
}

public enum EscaletaSceneBlock: Equatable, Sendable {
    case paragraph(String)
    case cue(EscaletaCue)
    case blockquote(String)
    case table(ComparisonTable)
}

public enum EscaletaCueKind: String, Sendable, CaseIterable {
    case image
    case bRoll
    case capture
    case test
    case testOnScreen
    case proposedTest
    case record
    case comparison
    case lowerThird
    case graphic
    case screenTable
    case recordingNote
    case rehook
    case unknown

    /// True for cues that the app turns into B-roll items.
    public var isBRoll: Bool {
        switch self {
        case .image, .bRoll, .capture, .test, .testOnScreen, .proposedTest,
             .record, .comparison, .lowerThird, .graphic, .screenTable:
            return true
        case .recordingNote, .rehook, .unknown:
            return false
        }
    }

    public var needsRecording: Bool {
        switch self {
        case .test, .testOnScreen, .proposedTest:
            return true
        default:
            return false
        }
    }
}

public struct EscaletaCue: Equatable, Sendable {
    public var label: String
    public var payload: String?
    public var line: Int
    public var kind: EscaletaCueKind

    public init(label: String, payload: String? = nil, line: Int = 0, kind: EscaletaCueKind? = nil) {
        self.label = label
        self.payload = payload
        self.line = line
        self.kind = kind ?? EscaletaCueKind(label: label)
    }

    /// Source line numbers are diagnostics; they are excluded from equality so
    /// parse → export → parse stays structurally lossless.
    public static func == (lhs: EscaletaCue, rhs: EscaletaCue) -> Bool {
        lhs.label == rhs.label && lhs.payload == rhs.payload && lhs.kind == rhs.kind
    }
}

public extension EscaletaCueKind {
    init(label: String) {
        let normalized = label
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .uppercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        switch normalized {
        case "IMAGEN", "IMAGE":
            self = .image
        case "B-ROLL", "B ROLL", "BROLL":
            self = .bRoll
        case "CAPTURA", "CAPTURE":
            self = .capture
        case "PRUEBA":
            self = .test
        case "PRUEBA EN PANTALLA":
            self = .testOnScreen
        case "PRUEBA PROPUESTA":
            self = .proposedTest
        case "GRABAR", "GRABACION":
            self = .record
        case "COMPARATIVA", "COMPARACION":
            self = .comparison
        case "ROTULO", "LOWER THIRD":
            self = .lowerThird
        case "GRAFICA", "GRAFICO":
            self = .graphic
        case "TABLA EN PANTALLA":
            self = .screenTable
        case "NOTA DE GRABACION", "NOTA DE GRABAR":
            self = .recordingNote
        case "RE-HOOK", "REHOOK", "RE HOOK":
            self = .rehook
        default:
            if normalized.hasPrefix("PRUEBA") {
                if normalized.contains("PANTALLA") { self = .testOnScreen }
                else if normalized.contains("PROPUESTA") { self = .proposedTest }
                else { self = .test }
            } else {
                self = .unknown
            }
        }
    }
}

// MARK: - Tables

public enum EscaletaTableAlignment: String, Sendable, CaseIterable {
    case none
    case leading
    case center
    case trailing
}

public struct ComparisonTable: Equatable, Sendable {
    public var heading: String?
    public var header: [String]
    public var alignments: [EscaletaTableAlignment]
    public var rows: [[String]]
    public var line: Int
    /// Nil for tables that live in their own section; the scene index for
    /// tables embedded in a scene body.
    public var sceneIndex: Int?

    public init(
        heading: String? = nil,
        header: [String] = [],
        alignments: [EscaletaTableAlignment] = [],
        rows: [[String]] = [],
        line: Int = 0,
        sceneIndex: Int? = nil
    ) {
        self.heading = heading
        self.header = header
        self.alignments = alignments
        self.rows = rows
        self.line = line
        self.sceneIndex = sceneIndex
    }

    public static func == (lhs: ComparisonTable, rhs: ComparisonTable) -> Bool {
        lhs.heading == rhs.heading
            && lhs.header == rhs.header
            && lhs.alignments == rhs.alignments
            && lhs.rows == rhs.rows
            && lhs.sceneIndex == rhs.sceneIndex
    }
}

// MARK: - Publishing / SEO

public enum EscaletaPublishingField: String, Sendable, CaseIterable {
    case evidence
    case primaryTitle
    case titleCandidates
    case thumbnailBrief
    case description
    case chapters
    case tags
    case hashtags
    case pinnedComment
    case communityPost

    public static let defaultOrder: [EscaletaPublishingField] = [
        .evidence,
        .primaryTitle,
        .titleCandidates,
        .thumbnailBrief,
        .description,
        .chapters,
        .tags,
        .hashtags,
        .pinnedComment,
        .communityPost,
    ]
}

public struct EscaletaChapter: Equatable, Sendable {
    public var seconds: Int
    /// Original spelling, e.g. `0:00` or `00:00`.
    public var timestamp: String
    public var title: String

    public init(seconds: Int, timestamp: String, title: String) {
        self.seconds = seconds
        self.timestamp = timestamp
        self.title = title
    }
}

public struct EscaletaLabeledBlock: Equatable, Sendable {
    public var label: String
    public var value: String
    public var colonInsideBold: Bool
    public var line: Int

    public init(label: String, value: String, colonInsideBold: Bool = true, line: Int = 0) {
        self.label = label
        self.value = value
        self.colonInsideBold = colonInsideBold
        self.line = line
    }

    public static func == (lhs: EscaletaLabeledBlock, rhs: EscaletaLabeledBlock) -> Bool {
        lhs.label == rhs.label && lhs.value == rhs.value && lhs.colonInsideBold == rhs.colonInsideBold
    }
}

public struct EscaletaPublishingPack: Equatable, Sendable {
    /// Text between the SEO heading and the first field, kept verbatim.
    public var preamble: String?
    public var evidence: [String]
    public var primaryTitle: String?
    public var titleCandidates: [String]
    public var thumbnailBrief: String?
    public var description: String?
    public var chapters: [EscaletaChapter]
    /// Lines under `## Capítulos` that were not chapter lines.
    public var chapterNotes: [String]
    public var tags: [String]
    public var hashtags: [String]
    public var pinnedComment: String?
    public var communityPost: String?
    public var extraFields: [EscaletaLabeledBlock]
    /// Order in which canonical fields appeared in the source.
    public var fieldOrder: [EscaletaPublishingField]
    public var boldLabelsColonInside: Bool
    public var chaptersPlacement: EscaletaChaptersPlacement

    public init(
        preamble: String? = nil,
        evidence: [String] = [],
        primaryTitle: String? = nil,
        titleCandidates: [String] = [],
        thumbnailBrief: String? = nil,
        description: String? = nil,
        chapters: [EscaletaChapter] = [],
        chapterNotes: [String] = [],
        tags: [String] = [],
        hashtags: [String] = [],
        pinnedComment: String? = nil,
        communityPost: String? = nil,
        extraFields: [EscaletaLabeledBlock] = [],
        fieldOrder: [EscaletaPublishingField] = EscaletaPublishingField.defaultOrder,
        boldLabelsColonInside: Bool = true,
        chaptersPlacement: EscaletaChaptersPlacement = .none
    ) {
        self.preamble = preamble
        self.evidence = evidence
        self.primaryTitle = primaryTitle
        self.titleCandidates = titleCandidates
        self.thumbnailBrief = thumbnailBrief
        self.description = description
        self.chapters = chapters
        self.chapterNotes = chapterNotes
        self.tags = tags
        self.hashtags = hashtags
        self.pinnedComment = pinnedComment
        self.communityPost = communityPost
        self.extraFields = extraFields
        self.fieldOrder = fieldOrder
        self.boldLabelsColonInside = boldLabelsColonInside
        self.chaptersPlacement = chaptersPlacement
    }

    public var hasContent: Bool {
        !evidence.isEmpty
            || primaryTitle != nil
            || !titleCandidates.isEmpty
            || thumbnailBrief != nil
            || description != nil
            || !chapters.isEmpty
            || !chapterNotes.isEmpty
            || !tags.isEmpty
            || !hashtags.isEmpty
            || pinnedComment != nil
            || communityPost != nil
            || !extraFields.isEmpty
            || preamble != nil
    }
}

// MARK: - Verification and sources

public struct EscaletaVerificationItem: Equatable, Sendable {
    public var label: String?
    public var text: String
    public var colonInsideBold: Bool
    public var line: Int

    public init(label: String? = nil, text: String, colonInsideBold: Bool = true, line: Int = 0) {
        self.label = label
        self.text = text
        self.colonInsideBold = colonInsideBold
        self.line = line
    }

    public static func == (lhs: EscaletaVerificationItem, rhs: EscaletaVerificationItem) -> Bool {
        lhs.label == rhs.label && lhs.text == rhs.text && lhs.colonInsideBold == rhs.colonInsideBold
    }
}

public enum EscaletaSourceOrigin: String, Sendable, CaseIterable {
    case section
    case descriptionTrailer
}

public struct EscaletaSourceLink: Equatable, Sendable {
    public var title: String?
    public var url: String

    public init(title: String? = nil, url: String) {
        self.title = title
        self.url = url
    }
}

public struct EscaletaSourceEntry: Equatable, Sendable {
    /// The source line without its bullet marker. Kept verbatim so links,
    /// separators (`·`) and surrounding prose survive a round-trip.
    public var raw: String
    public var bullet: Bool
    public var links: [EscaletaSourceLink]
    public var origin: EscaletaSourceOrigin
    public var line: Int

    public init(
        raw: String,
        bullet: Bool = false,
        links: [EscaletaSourceLink] = [],
        origin: EscaletaSourceOrigin = .section,
        line: Int = 0
    ) {
        self.raw = raw
        self.bullet = bullet
        self.links = links
        self.origin = origin
        self.line = line
    }

    public static func == (lhs: EscaletaSourceEntry, rhs: EscaletaSourceEntry) -> Bool {
        lhs.raw == rhs.raw
            && lhs.bullet == rhs.bullet
            && lhs.links == rhs.links
            && lhs.origin == rhs.origin
    }
}

// MARK: - Unparsed content

public enum EscaletaUnparsedPlacement: String, Sendable, CaseIterable {
    /// After the title/front matter and before the script.
    case preamble
    /// After scenes/tables/verification and before the SEO block.
    case document
    /// Inside the SEO block.
    case seo
    /// Inside a thumbnail-concept group.
    case thumbnailGroup
}

public struct EscaletaUnparsedSection: Equatable, Sendable {
    public var level: Int
    public var heading: String
    public var body: String
    public var placement: EscaletaUnparsedPlacement
    public var line: Int

    public init(
        level: Int,
        heading: String,
        body: String,
        placement: EscaletaUnparsedPlacement = .document,
        line: Int = 0
    ) {
        self.level = level
        self.heading = heading
        self.body = body
        self.placement = placement
        self.line = line
    }

    public static func == (lhs: EscaletaUnparsedSection, rhs: EscaletaUnparsedSection) -> Bool {
        lhs.level == rhs.level && lhs.heading == rhs.heading && lhs.body == rhs.body && lhs.placement == rhs.placement
    }
}

// MARK: - Thumbnail concepts (§3.6)

public struct ThumbnailConceptsDocument: Equatable, Sendable {
    public var intro: String?
    public var separatorAfterIntro: Bool
    public var groups: [ThumbnailGroup]
    public var sharedRulesHeading: String?
    /// Non-list prose under the shared-rules heading, preserved verbatim.
    public var sharedRulesNotes: String?
    public var sharedRules: [String]
    public var unparsedSections: [EscaletaUnparsedSection]

    public init(
        intro: String? = nil,
        separatorAfterIntro: Bool = false,
        groups: [ThumbnailGroup] = [],
        sharedRulesHeading: String? = nil,
        sharedRulesNotes: String? = nil,
        sharedRules: [String] = [],
        unparsedSections: [EscaletaUnparsedSection] = []
    ) {
        self.intro = intro
        self.separatorAfterIntro = separatorAfterIntro
        self.groups = groups
        self.sharedRulesHeading = sharedRulesHeading
        self.sharedRulesNotes = sharedRulesNotes
        self.sharedRules = sharedRules
        self.unparsedSections = unparsedSections
    }
}

public struct ThumbnailGroup: Equatable, Sendable {
    public var title: String
    public var preamble: String?
    public var referenceTitle: String?
    public var concepts: [ThumbnailConcept]
    public var abTestHeading: String?
    public var abTestItems: [String]
    public var abTestNote: String?
    public var unparsedSections: [EscaletaUnparsedSection]
    public var separatorAfter: Bool

    public init(
        title: String,
        preamble: String? = nil,
        referenceTitle: String? = nil,
        concepts: [ThumbnailConcept] = [],
        abTestHeading: String? = nil,
        abTestItems: [String] = [],
        abTestNote: String? = nil,
        unparsedSections: [EscaletaUnparsedSection] = [],
        separatorAfter: Bool = false
    ) {
        self.title = title
        self.preamble = preamble
        self.referenceTitle = referenceTitle
        self.concepts = concepts
        self.abTestHeading = abTestHeading
        self.abTestItems = abTestItems
        self.abTestNote = abTestNote
        self.unparsedSections = unparsedSections
        self.separatorAfter = separatorAfter
    }
}

public struct ThumbnailConcept: Equatable, Sendable {
    public var label: String
    public var text: String
    public var recommended: Bool
    public var idea: String?
    public var composition: [String]
    public var whyItWorks: String?
    public var extraText: String?
    public var line: Int

    public init(
        label: String,
        text: String,
        recommended: Bool = false,
        idea: String? = nil,
        composition: [String] = [],
        whyItWorks: String? = nil,
        extraText: String? = nil,
        line: Int = 0
    ) {
        self.label = label
        self.text = text
        self.recommended = recommended
        self.idea = idea
        self.composition = composition
        self.whyItWorks = whyItWorks
        self.extraText = extraText
        self.line = line
    }

    public static func == (lhs: ThumbnailConcept, rhs: ThumbnailConcept) -> Bool {
        lhs.label == rhs.label
            && lhs.text == rhs.text
            && lhs.recommended == rhs.recommended
            && lhs.idea == rhs.idea
            && lhs.composition == rhs.composition
            && lhs.whyItWorks == rhs.whyItWorks
            && lhs.extraText == rhs.extraText
    }
}
