import Foundation
import FrameScriptCore

/// Structural information that the application model cannot represent without
/// changing the frozen v4 schema. It travels in `FrameProject.topic` as a
/// versioned, base64 JSON block inside `EscaletaProjectNotes`.
///
/// Only structure and small flags live here: text, cues, sources and tables
/// stay in their real model fields, so editing a project still changes the
/// export.
struct EscaletaRoundTripMetadata: Codable, Equatable, Sendable {
    var preTitleText: String?
    var separatorAfterIntro: Bool
    var outlineHeading: String?
    var outline: [OutlineItem]
    var scriptHeading: String?
    var scriptSeparator: Bool
    var seoHeading: String?
    var seoHeadingLevel: Int
    var seoLayout: String
    var hasPublishingSection: Bool
    var publishing: PublishingMetadata
    var comparisonTables: [TableMetadata]
    var tableSectionHeading: String?
    var tableSectionNotes: String?
    var verifyHeading: String?
    var verificationItems: [VerificationMetadata]
    var sourcesHeading: String?
    var sources: [SourceMetadata]
    var sourcesPlacement: String
    var unparsedSections: [UnparsedMetadata]
    var scenes: [SceneMetadata]

    struct OutlineItem: Codable, Equatable, Sendable {
        var style: String
        var number: Int?
        var text: String
        var indent: Int
    }

    struct PublishingMetadata: Codable, Equatable, Sendable {
        var hasPrimaryTitle: Bool
        /// Chosen title as it was mapped from the source, used to detect user
        /// edits when the source had candidates but no primary title.
        var originalChosenTitle: String
        var preamble: String?
        var evidence: [String]
        var extraFields: [LabeledBlockMetadata]
        var chapterNotes: [String]
        var fieldOrder: [String]
        var boldLabelsColonInside: Bool
        var chaptersPlacement: String
        var chapters: [ChapterMetadata]
    }

    struct LabeledBlockMetadata: Codable, Equatable, Sendable {
        var label: String
        var value: String
        var colonInsideBold: Bool
    }

    struct ChapterMetadata: Codable, Equatable, Sendable {
        var seconds: Int
        var timestamp: String
        var title: String
    }

    struct TableMetadata: Codable, Equatable, Sendable {
        var alignments: [String]
        var sceneIndex: Int?
    }

    struct VerificationMetadata: Codable, Equatable, Sendable {
        var label: String?
        var text: String
        var colonInsideBold: Bool
    }

    struct SourceMetadata: Codable, Equatable, Sendable {
        var raw: String
        var bullet: Bool
        var origin: String
        var links: [LinkMetadata]
    }

    struct LinkMetadata: Codable, Equatable, Sendable {
        var title: String?
        var url: String
    }

    struct UnparsedMetadata: Codable, Equatable, Sendable {
        var heading: String
        var body: String
        var level: Int
        var placement: String
    }

    struct SceneMetadata: Codable, Equatable, Sendable {
        var sceneID: String
        var startSeconds: Int?
        var timestampText: String?
        var separator: String
        var separatorAfter: Bool
        var isOutlineFallback: Bool
        var textBlockCount: Int
        var bRollCount: Int
        var editingCount: Int
        var noteCount: Int
        var tableCount: Int
        /// One slot per text block, plus a trailing slot. A slot lists the
        /// cue/table/note blocks that appeared before the text block.
        var slots: [[BlockRef]]
    }

    struct BlockRef: Codable, Equatable, Sendable {
        var kind: String
        var index: Int
    }
}

extension EscaletaRoundTripMetadata {
    init(document: EscaletaDocument, scenes: [SceneMetadata]) {
        preTitleText = document.preTitleText
        separatorAfterIntro = document.separatorAfterIntro
        outlineHeading = document.outlineHeading
        outline = document.outline.map { item in
            switch item.marker {
            case .numbered(let number):
                OutlineItem(style: "numbered", number: number, text: item.text, indent: item.indent)
            case .bullet:
                OutlineItem(style: "bullet", number: nil, text: item.text, indent: item.indent)
            case .plain:
                OutlineItem(style: "plain", number: nil, text: item.text, indent: item.indent)
            }
        }
        scriptHeading = document.scriptHeading
        scriptSeparator = document.scriptSeparator
        seoHeading = document.seoHeading
        seoHeadingLevel = document.seoHeadingLevel
        seoLayout = document.seoLayout.rawValue
        hasPublishingSection = document.publishing != nil
        comparisonTables = document.comparisonTables.map {
            TableMetadata(alignments: $0.alignments.map(\.rawValue), sceneIndex: $0.sceneIndex)
        }
        tableSectionHeading = document.tableSectionHeading
        tableSectionNotes = document.tableSectionNotes
        verifyHeading = document.verifyHeading
        verificationItems = document.verificationItems.map {
            VerificationMetadata(label: $0.label, text: $0.text, colonInsideBold: $0.colonInsideBold)
        }
        sourcesHeading = document.sourcesHeading
        sources = document.sources.map { source in
            SourceMetadata(
                raw: source.raw,
                bullet: source.bullet,
                origin: source.origin.rawValue,
                links: source.links.map { LinkMetadata(title: $0.title, url: $0.url) }
            )
        }
        sourcesPlacement = document.sourcesPlacement.rawValue
        unparsedSections = document.unparsedSections.map {
            UnparsedMetadata(
                heading: $0.heading,
                body: $0.body,
                level: $0.level,
                placement: $0.placement.rawValue
            )
        }
        self.scenes = scenes

        let pack = document.publishing
        publishing = PublishingMetadata(
            hasPrimaryTitle: pack?.primaryTitle != nil,
            originalChosenTitle: pack?.primaryTitle ?? pack?.titleCandidates.first ?? "",
            preamble: pack?.preamble,
            evidence: pack?.evidence ?? [],
            extraFields: pack?.extraFields.map {
                LabeledBlockMetadata(label: $0.label, value: $0.value, colonInsideBold: $0.colonInsideBold)
            } ?? [],
            chapterNotes: pack?.chapterNotes ?? [],
            fieldOrder: pack?.fieldOrder.map(\.rawValue) ?? [],
            boldLabelsColonInside: pack?.boldLabelsColonInside ?? true,
            chaptersPlacement: pack?.chaptersPlacement.rawValue ?? EscaletaChaptersPlacement.none.rawValue,
            chapters: pack?.chapters.map {
                ChapterMetadata(seconds: $0.seconds, timestamp: $0.timestamp, title: $0.title)
            } ?? []
        )
    }

    var coreOutline: [EscaletaOutlineItem] {
        outline.map { item in
            let marker: EscaletaOutlineMarker = switch item.style {
            case "numbered": .numbered(item.number ?? 1)
            case "bullet": .bullet
            default: .plain
            }
            return EscaletaOutlineItem(marker: marker, text: item.text, indent: item.indent)
        }
    }

    var coreSeoLayout: EscaletaSEOLayout {
        EscaletaSEOLayout(rawValue: seoLayout) ?? .sectioned
    }

    var coreSourcesPlacement: EscaletaSourcesPlacement {
        EscaletaSourcesPlacement(rawValue: sourcesPlacement) ?? .none
    }

    var coreChaptersPlacement: EscaletaChaptersPlacement {
        EscaletaChaptersPlacement(rawValue: publishing.chaptersPlacement) ?? .none
    }
}

/// `EscaletaProjectNotes` is the small human-readable note block stored in
/// `FrameProject.topic`; the round-trip metadata is an optional versioned line
/// in the same block.
struct EscaletaProjectNotes: Equatable, Sendable {
    var promise: String?
    var thesis: String?
    var versionNote: String?
    var scriptIntro: String?
    var pacingNotes: [String] = []
    var metadata: EscaletaRoundTripMetadata?

    static let promiseLabel = "Promesa:"
    static let thesisLabel = "Tesis:"
    static let versionLabel = "Nota de versión:"
    static let introLabel = "Entrada del guion:"
    static let pacingLabel = "Notas de ritmo:"
    static let metadataLabel = "__framescript_escaleta_metadata__:"

    var isEmpty: Bool {
        promise == nil
            && thesis == nil
            && versionNote == nil
            && scriptIntro == nil
            && pacingNotes.isEmpty
            && metadata == nil
    }

    func encoded() -> String {
        var sections: [String] = []
        append(label: Self.promiseLabel, value: promise, to: &sections)
        append(label: Self.thesisLabel, value: thesis, to: &sections)
        append(label: Self.versionLabel, value: versionNote, to: &sections)
        append(label: Self.introLabel, value: scriptIntro, to: &sections)
        if !pacingNotes.isEmpty {
            sections.append("\(Self.pacingLabel)\n" + pacingNotes.map { "- \($0)" }.joined(separator: "\n"))
        }
        if let metadata {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(metadata) {
                sections.append(Self.metadataLabel + data.base64EncodedString())
            }
        }
        return sections.joined(separator: "\n\n")
    }

    static func decode(_ text: String) -> EscaletaProjectNotes {
        var notes = EscaletaProjectNotes()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return notes }

        var currentLabel: String?
        var currentLines: [String] = []
        let knownLabels = Set([promiseLabel, thesisLabel, versionLabel, introLabel, pacingLabel])

        func flush() {
            guard let currentLabel else { return }
            let value = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            switch currentLabel {
            case promiseLabel: notes.promise = value
            case thesisLabel: notes.thesis = value
            case versionLabel: notes.versionNote = value
            case introLabel: notes.scriptIntro = value
            case pacingLabel:
                notes.pacingNotes = currentLines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map { line in
                        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                        return line
                    }
            default: break
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(metadataLabel) {
                flush()
                currentLabel = nil
                currentLines = []
                let encoded = String(trimmed.dropFirst(metadataLabel.count))
                if let data = Data(base64Encoded: encoded),
                   let metadata = try? JSONDecoder().decode(EscaletaRoundTripMetadata.self, from: data) {
                    notes.metadata = metadata
                }
                continue
            }
            if knownLabels.contains(trimmed) {
                flush()
                currentLabel = trimmed
                currentLines = []
            } else if currentLabel != nil {
                currentLines.append(line)
            }
        }
        flush()
        return notes
    }

    private func append(label: String, value: String?, to sections: inout [String]) {
        guard let value else { return }
        sections.append("\(label)\n\(value.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}
