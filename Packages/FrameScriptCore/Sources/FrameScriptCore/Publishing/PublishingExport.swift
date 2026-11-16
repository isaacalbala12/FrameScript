import Foundation

/// Everything the publishing pack needs to render. Kept independent from the
/// app model so the app and the Core tests build the same value.
public struct PublishingExportInput: Sendable, Equatable {
    public var projectTitle: String
    public var promise: String
    public var thesis: String
    public var title: String
    public var titleCandidates: [String]
    public var thumbnailNotes: String
    public var description: String
    public var chapters: [EscaletaChapter]
    public var tags: [String]
    public var hashtags: [String]
    public var pinnedComment: String
    public var communityPost: String
    public var sources: [PublishingSource]

    public init(
        projectTitle: String = "",
        promise: String = "",
        thesis: String = "",
        title: String = "",
        titleCandidates: [String] = [],
        thumbnailNotes: String = "",
        description: String = "",
        chapters: [EscaletaChapter] = [],
        tags: [String] = [],
        hashtags: [String] = [],
        pinnedComment: String = "",
        communityPost: String = "",
        sources: [PublishingSource] = []
    ) {
        self.projectTitle = projectTitle
        self.promise = promise
        self.thesis = thesis
        self.title = title
        self.titleCandidates = titleCandidates
        self.thumbnailNotes = thumbnailNotes
        self.description = description
        self.chapters = chapters
        self.tags = tags
        self.hashtags = hashtags
        self.pinnedComment = pinnedComment
        self.communityPost = communityPost
        self.sources = sources
    }
}

/// Markdown renderer for the publishing pack.
///
/// The `# Paquete SEO` block is produced by `EscaletaExporter`, so it uses the
/// exact section names and list shapes the Markdown importer already knows.
/// The plain YouTube Studio block is appended after it; a re-import keeps it as
/// an unknown SEO section instead of losing it.
public enum PublishingExport {
    public static let seoHeading = "Paquete SEO"
    public static let studioHeading = "YouTube Studio"
    public static let chaptersHeading = "Capítulos"
    public static let sourcesHeading = "Fuentes"

    public static func make(_ input: PublishingExportInput) -> String {
        var publishing = EscaletaPublishingPack()
        publishing.primaryTitle = PublishingText.nonEmpty(input.title)
        publishing.titleCandidates = input.titleCandidates
        publishing.thumbnailBrief = PublishingText.nonEmpty(input.thumbnailNotes)
        publishing.description = PublishingText.nonEmpty(input.description)
        publishing.chapters = input.chapters
        publishing.tags = input.tags
        publishing.hashtags = input.hashtags
        publishing.pinnedComment = PublishingText.nonEmpty(input.pinnedComment)
        publishing.communityPost = PublishingText.nonEmpty(input.communityPost)
        publishing.chaptersPlacement = input.chapters.isEmpty ? .none : .section
        publishing.fieldOrder = [
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

        let title = PublishingText.nonEmpty(input.projectTitle) ?? "Proyecto"
        let document = EscaletaDocument(
            kind: .escaleta,
            title: title,
            promise: PublishingText.nonEmpty(input.promise),
            thesis: PublishingText.nonEmpty(input.thesis),
            scenes: [],
            publishing: publishing,
            seoHeading: seoHeading,
            seoHeadingLevel: 1,
            seoLayout: .sectioned,
            sourcesHeading: input.sources.isEmpty ? nil : "Fuentes principales",
            sources: input.sources.map { source in
                let raw: String
                if !source.url.isEmpty {
                    raw = source.title.isEmpty
                        ? source.url
                        : "[\(source.title)](\(source.url))"
                } else {
                    raw = source.displayLine
                }
                return EscaletaSourceEntry(
                    raw: raw,
                    bullet: true,
                    links: source.url.isEmpty
                        ? []
                        : [EscaletaSourceLink(title: source.title, url: source.url)],
                    origin: .section
                )
            },
            sourcesPlacement: input.sources.isEmpty ? .none : .seoSection
        )

        var output = EscaletaExporter.markdown(from: document)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let studio = youtubeStudioBlock(input)
        if !studio.isEmpty {
            output += "\n\n" + studio
        }
        return output
    }

    /// The description a creator pastes into YouTube Studio: normal description,
    /// chapter timestamps and a source list.
    public static func studioDescription(_ input: PublishingExportInput) -> String {
        var parts: [String] = []
        let base = input.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            parts.append(base)
        }

        let chapters = input.chapters
            .map { "\(DurationFormat.clock(seconds: $0.seconds)) \($0.title)" }
            .joined(separator: "\n")
        // Compare every chapter line: a description that already mentions two
        // of six chapters must still receive the remaining four.
        let chaptersAlreadyPresent = !chapters.isEmpty && base.contains(chapters)
        if !chapters.isEmpty, !chaptersAlreadyPresent {
            parts.append("\(chaptersHeading)\n\(chapters)")
        }

        let sources = input.sources
            .map(\.displayLine)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Filter line by line: one source already in the description must not
        // hide the rest of the list.
        let missingSources = sources.filter { !base.contains($0) }
        if !missingSources.isEmpty {
            parts.append(
                "\(sourcesHeading)\n" + missingSources.map { "- \($0)" }.joined(separator: "\n")
            )
        }

        return parts.joined(separator: "\n\n")
    }

    /// Plain, label-only block for YouTube Studio. Labels are bold so the file
    /// stays readable, while the value under each one is paste-ready.
    public static func youtubeStudioBlock(_ input: PublishingExportInput) -> String {
        var lines: [String] = ["## \(studioHeading)"]

        func append(label: String, value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("")
            lines.append("**\(label)**")
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }

        append(label: "Título", value: input.title)
        append(label: "Descripción", value: studioDescription(input))
        append(label: "Etiquetas", value: input.tags.joined(separator: ", "))
        append(label: "Hashtags", value: input.hashtags.joined(separator: " "))
        append(label: "Comentario fijado", value: input.pinnedComment)
        return lines.joined(separator: "\n")
    }

    /// Value behind a per-field copy button.
    public static func fieldValue(_ field: PublishingField, input: PublishingExportInput) -> String {
        switch field {
        case .promise:
            return input.promise
        case .thesis:
            return input.thesis
        case .title:
            return input.title
        case .titleCandidates:
            return input.titleCandidates
                .enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        case .thumbnailConcept:
            return input.thumbnailNotes
        case .description:
            return studioDescription(input)
        case .chapters:
            return input.chapters
                .map { "\(DurationFormat.clock(seconds: $0.seconds)) \($0.title)" }
                .joined(separator: "\n")
        case .tags:
            return input.tags.joined(separator: ", ")
        case .hashtags:
            return input.hashtags.joined(separator: " ")
        case .pinnedComment:
            return input.pinnedComment
        case .communityPost:
            return input.communityPost
        }
    }
}
