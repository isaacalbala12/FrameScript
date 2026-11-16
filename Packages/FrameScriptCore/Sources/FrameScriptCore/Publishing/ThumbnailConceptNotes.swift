import Foundation

/// A text-first thumbnail concept: the on-screen words plus the idea, the
/// composition and why it should work. The importer writes these inside
/// `PublishingPack.thumbnailConceptNotes`; the panel edits them structurally and
/// renders them back to that same text, so imported concepts round-trip without
/// a new format field.
public struct PublishingThumbnailConcept: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var text: String
    public var idea: String
    public var composition: [String]
    public var whyItWorks: String
    public var isRecommended: Bool

    public init(
        id: UUID = UUID(),
        label: String = "",
        text: String = "",
        idea: String = "",
        composition: [String] = [],
        whyItWorks: String = "",
        isRecommended: Bool = false
    ) {
        self.id = id
        self.label = label
        self.text = text
        self.idea = idea
        self.composition = composition
        self.whyItWorks = whyItWorks
        self.isRecommended = isRecommended
    }

    public var wordCount: Int {
        PublishingText.wordCount(text)
    }
}

public struct PublishingThumbnailNotes: Sendable, Equatable {
    public var concepts: [PublishingThumbnailConcept]
    /// Anything outside the structured concept blocks. Kept verbatim so an
    /// imported `## Concepto de miniatura` note or a free-form paragraph is
    /// never lost.
    public var notes: String

    public init(
        concepts: [PublishingThumbnailConcept] = [],
        notes: String = ""
    ) {
        self.concepts = concepts
        self.notes = notes
    }

    public static func parse(_ value: String) -> PublishingThumbnailNotes {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return PublishingThumbnailNotes() }

        let lines = value.components(separatedBy: "\n")
        let headingIndices = lines.indices.filter { isConceptHeading(lines[$0]) }
        guard let firstHeading = headingIndices.first else {
            return PublishingThumbnailNotes(notes: raw)
        }

        var concepts: [PublishingThumbnailConcept] = []
        var looseLines: [String] = []
        looseLines.append(contentsOf: lines[0..<firstHeading])

        for (position, headingIndex) in headingIndices.enumerated() {
            let end = position + 1 < headingIndices.count ? headingIndices[position + 1] : lines.count
            let body = Array(lines[(headingIndex + 1)..<end])
            concepts.append(parseConcept(heading: lines[headingIndex], body: body, loose: &looseLines))
        }

        let notes = looseLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PublishingThumbnailNotes(concepts: concepts, notes: notes)
    }

    public func rendered() -> String {
        guard !concepts.isEmpty else {
            return notes.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var lines: [String] = []
        for (index, concept) in concepts.enumerated() {
            let label = concept.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveLabel = label.isEmpty ? "\(index + 1)" : label
            let text = concept.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var heading = "### Concepto \(effectiveLabel)"
            if !text.isEmpty {
                heading += " — \(text)"
            }
            if concept.isRecommended {
                heading += " — Recomendado"
            }
            lines.append(heading)

            let idea = concept.idea.trimmingCharacters(in: .whitespacesAndNewlines)
            if !idea.isEmpty {
                lines.append("Idea: \(idea)")
            }
            let composition = concept.composition
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !composition.isEmpty {
                lines.append("Composición:")
                lines.append(contentsOf: composition.map { line in
                    line.hasPrefix("- ") ? line : "- \(line)"
                })
            }
            let why = concept.whyItWorks.trimmingCharacters(in: .whitespacesAndNewlines)
            if !why.isEmpty {
                lines.append("Por qué funciona: \(why)")
            }
            if index + 1 < concepts.count {
                lines.append("")
            }
        }

        let extra = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty {
            lines.append("")
            lines.append(extra)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    private static func isConceptHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("##") else { return false }
        let heading = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return heading.lowercased().hasPrefix("concepto ")
    }

    private static func parseConcept(
        heading: String,
        body: [String],
        loose: inout [String]
    ) -> PublishingThumbnailConcept {
        let trimmedHeading = heading.trimmingCharacters(in: .whitespaces)
        var title = String(trimmedHeading.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespaces)
        if title.lowercased().hasPrefix("concepto ") {
            title = String(title.dropFirst("concepto ".count))
                .trimmingCharacters(in: .whitespaces)
        }

        var isRecommended = false
        for suffix in [" — Recomendado", " – Recomendado", " - Recomendado", " — Recommended"] {
            if title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespaces)
                isRecommended = true
                break
            }
        }

        let parts = splitLabelAndText(title)
        var concept = PublishingThumbnailConcept(
            label: parts.label,
            text: parts.text,
            isRecommended: isRecommended
        )

        var readingComposition = false
        for rawLine in body {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                readingComposition = false
                continue
            }
            let lower = line.lowercased()
            if lower.hasPrefix("idea:") {
                concept.idea = String(line.dropFirst("idea:".count))
                    .trimmingCharacters(in: .whitespaces)
                readingComposition = false
                continue
            }
            if lower.hasPrefix("composición:") || lower.hasPrefix("composicion:") {
                readingComposition = true
                continue
            }
            if lower.hasPrefix("por qué funciona:") || lower.hasPrefix("por que funciona:") {
                if let colon = line.firstIndex(of: ":") {
                    concept.whyItWorks = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                readingComposition = false
                continue
            }
            if readingComposition {
                concept.composition.append(
                    line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
                )
                continue
            }
            loose.append(rawLine)
        }

        return concept
    }

    /// `Concepto A — El título engaña` → ("A", "El título engaña").
    private static func splitLabelAndText(_ value: String) -> (label: String, text: String) {
        let separators = [" — ", " – ", " - "]
        for separator in separators {
            if let range = value.range(of: separator) {
                let label = String(value[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let text = String(value[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (label, text)
            }
        }
        return ("", value.trimmingCharacters(in: .whitespaces))
    }
}
