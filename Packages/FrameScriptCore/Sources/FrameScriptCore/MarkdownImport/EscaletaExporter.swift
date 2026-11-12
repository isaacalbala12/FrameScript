import Foundation

/// Renders an `EscaletaDocument` back to Isaac's Markdown contract.
///
/// The exporter writes the canonical layout of §3.9. Documents that follow the
/// contract round-trip to text that is identical modulo whitespace; documents
/// with unknown sections keep them verbatim in `unparsedSections`.
public enum EscaletaExporter {
    public static func markdown(from document: EscaletaDocument) -> String {
        if document.kind == .thumbnailConcepts, let thumbnail = document.thumbnailConcepts {
            return renderThumbnail(document: document, thumbnail: thumbnail)
        }

        var writer = Writer()

        if let preTitle = document.preTitleText, !preTitle.isEmpty {
            writer.raw(preTitle)
            writer.blank()
        }

        if !document.title.isEmpty {
            writer.line("# \(document.title)")
        }

        if let note = document.versionNote, !note.isEmpty {
            writer.blank()
            writer.raw(note)
        }

        if document.separatorAfterIntro {
            writer.blank()
            writer.line("---")
        }

        if let promise = document.promise {
            writer.blank()
            writer.line("## Promesa del vídeo")
            if !promise.isEmpty {
                writer.blank()
                writer.raw(promise)
            }
        }

        if let thesis = document.thesis {
            writer.blank()
            writer.line("## Tesis")
            if !thesis.isEmpty {
                writer.blank()
                writer.raw(thesis)
            }
        }

        if document.outlineHeading != nil || !document.outline.isEmpty {
            writer.blank()
            writer.line("## \(document.outlineHeading ?? "Escaleta")")
            if !document.outline.isEmpty {
                writer.blank()
                writer.outline(document.outline)
            }
        }

        writeUnparsed(document.unparsedSections, placement: .preamble, to: &writer)

        let timestampedScenes = document.scenes.filter { !$0.isOutlineFallback }
        if let scriptHeading = document.scriptHeading {
            writer.blank()
            if document.scriptSeparator, !document.separatorAfterIntro {
                writer.line("---")
                writer.blank()
            }
            writer.line("# \(scriptHeading)")

            for note in document.pacingNotes {
                writer.blank()
                writer.blockquote(note)
            }

            if let intro = document.scriptIntro, !intro.isEmpty {
                writer.blank()
                writer.raw(intro)
            }

            for scene in timestampedScenes {
                writer.blank()
                writer.scene(scene)
            }
        } else if !timestampedScenes.isEmpty
            || document.scriptIntro != nil
            || !document.pacingNotes.isEmpty {
            // Scene-only documents keep their source shape: no synthetic H1.
            for note in document.pacingNotes {
                writer.blank()
                writer.blockquote(note)
            }
            if let intro = document.scriptIntro, !intro.isEmpty {
                writer.blank()
                writer.raw(intro)
            }
            for scene in timestampedScenes {
                writer.blank()
                writer.scene(scene)
            }
        }

        writeTables(document: document, to: &writer)
        writeVerification(document: document, to: &writer)
        writeUnparsed(document.unparsedSections, placement: .document, to: &writer)
        writeSEO(document: document, to: &writer)
        writeSources(document: document, to: &writer)

        return writer.finish()
    }

    // MARK: - Sections

    private static func writeUnparsed(
        _ sections: [EscaletaUnparsedSection],
        placement: EscaletaUnparsedPlacement,
        to writer: inout Writer
    ) {
        for section in sections where section.placement == placement {
            writer.blank()
            writer.heading(level: section.level, text: section.heading)
            if !section.body.isEmpty {
                writer.blank()
                writer.raw(section.body)
            }
        }
    }

    private static func writeTables(document: EscaletaDocument, to writer: inout Writer) {
        let tables = document.comparisonTables.filter { $0.sceneIndex == nil }
        guard !tables.isEmpty
            || document.tableSectionNotes != nil
            || document.tableSectionHeading != nil else {
            return
        }

        writer.blank()
        writer.line("---")

        let sectionHeading = document.tableSectionHeading
        let usesSingleHeading = sectionHeading != nil
            && (tables.isEmpty || tables.allSatisfy { $0.heading == sectionHeading })

        if usesSingleHeading, let heading = sectionHeading {
            writer.blank()
            writer.line("## \(heading)")
            if let notes = document.tableSectionNotes, !notes.isEmpty {
                writer.blank()
                writer.raw(notes)
            }
            for table in tables {
                writer.blank()
                writer.table(table)
            }
            return
        }

        if let notes = document.tableSectionNotes, !notes.isEmpty {
            writer.blank()
            writer.raw(notes)
        }

        var lastHeading: String?
        for table in tables {
            if let heading = table.heading, heading != lastHeading {
                writer.blank()
                writer.line("## \(heading)")
                lastHeading = heading
            }
            writer.blank()
            writer.table(table)
        }
    }

    private static func writeVerification(document: EscaletaDocument, to writer: inout Writer) {
        guard document.verifyHeading != nil || !document.verificationItems.isEmpty else { return }

        writer.blank()
        writer.line("---")
        writer.blank()
        writer.line("## \(document.verifyHeading ?? "Verificar antes de grabar")")

        if !document.verificationItems.isEmpty {
            writer.blank()
            for item in document.verificationItems {
                writer.verificationItem(item)
            }
        }
    }

    // MARK: - SEO

    private static func writeSEO(document: EscaletaDocument, to writer: inout Writer) {
        guard let publishing = document.publishing else { return }
        let heading = document.seoHeading ?? "Paquete SEO"

        let hasVerification = document.verifyHeading != nil || !document.verificationItems.isEmpty
        if !hasVerification {
            writer.blank()
            writer.line("---")
        }

        writer.blank()
        let prefix = String(repeating: "#", count: max(1, min(document.seoHeadingLevel, 6)))
        writer.line("\(prefix) \(heading)")

        if let preamble = publishing.preamble, !preamble.isEmpty {
            writer.blank()
            writer.raw(preamble)
        }

        switch document.seoLayout {
        case .sectioned:
            for field in orderedFields(publishing) {
                guard shouldWriteField(field, publishing: publishing) else { continue }
                writer.blank()
                writer.line("## \(sectionTitle(for: field))")
                writer.blank()
                writeFieldValue(field, publishing: publishing, to: &writer)
            }
            for extra in publishing.extraFields {
                writer.blank()
                writer.labeledBlock(extra, colonInsideBold: publishing.boldLabelsColonInside)
            }

        case .boldLabels:
            for field in orderedFields(publishing) {
                guard shouldWriteField(field, publishing: publishing) else { continue }
                writer.blank()
                writeBoldField(
                    field,
                    publishing: publishing,
                    colonInsideBold: publishing.boldLabelsColonInside,
                    to: &writer
                )
            }
            for extra in publishing.extraFields {
                writer.blank()
                writer.labeledBlock(extra, colonInsideBold: extra.colonInsideBold)
            }
        }

        writeUnparsed(document.unparsedSections, placement: .seo, to: &writer)
    }

    private static func writeSources(document: EscaletaDocument, to writer: inout Writer) {
        let entries = document.sources.filter { $0.origin == .section }
        // A description trailer does not suppress an explicit sources section:
        // the two origins coexist.
        guard !entries.isEmpty || document.sourcesHeading != nil else { return }

        writer.blank()
        writer.line("## \(document.sourcesHeading ?? "Fuentes principales")")

        if !entries.isEmpty {
            writer.blank()
            for entry in entries {
                writer.sourceEntry(entry)
            }
        }
    }

    private static func orderedFields(_ publishing: EscaletaPublishingPack) -> [EscaletaPublishingField] {
        var order = publishing.fieldOrder
        if order.isEmpty {
            order = EscaletaPublishingField.defaultOrder
        }
        for field in EscaletaPublishingField.defaultOrder where !order.contains(field) {
            order.append(field)
        }
        return order
    }

    /// Fields recorded in the source keep their heading even when empty, so an
    /// empty section is not silently deleted. Fields appended only to complete
    /// the canonical order are written only when they have content.
    private static func shouldWriteField(
        _ field: EscaletaPublishingField,
        publishing: EscaletaPublishingPack
    ) -> Bool {
        if publishing.fieldOrder.contains(field) { return true }
        return fieldHasContent(field, publishing: publishing)
    }

    private static func fieldHasContent(
        _ field: EscaletaPublishingField,
        publishing: EscaletaPublishingPack
    ) -> Bool {
        switch field {
        case .evidence:
            return !publishing.evidence.isEmpty
        case .primaryTitle:
            return publishing.primaryTitle != nil
        case .titleCandidates:
            return !publishing.titleCandidates.isEmpty
        case .thumbnailBrief:
            return publishing.thumbnailBrief != nil
        case .description:
            return publishing.description != nil
        case .chapters:
            // Chapters extracted from the description stay inline: writing a
            // separate section would duplicate them and change the document.
            guard publishing.chaptersPlacement != .inlineDescription else { return false }
            return !publishing.chapters.isEmpty || !publishing.chapterNotes.isEmpty
        case .tags:
            return !publishing.tags.isEmpty
        case .hashtags:
            return !publishing.hashtags.isEmpty
        case .pinnedComment:
            return publishing.pinnedComment != nil
        case .communityPost:
            return publishing.communityPost != nil
        }
    }

    private static func sectionTitle(for field: EscaletaPublishingField) -> String {
        switch field {
        case .evidence: return "Evidencia utilizada"
        case .primaryTitle: return "Título recomendado"
        case .titleCandidates: return "Variantes"
        case .thumbnailBrief: return "Concepto de miniatura"
        case .description: return "Descripción"
        case .chapters: return "Capítulos"
        case .tags: return "Etiquetas"
        case .hashtags: return "Hashtags"
        case .pinnedComment: return "Comentario fijado"
        case .communityPost: return "Texto para comunidad"
        }
    }

    private static func boldTitle(for field: EscaletaPublishingField) -> String {
        switch field {
        case .evidence: return "Evidencia utilizada"
        case .primaryTitle: return "Título recomendado"
        case .titleCandidates: return "Títulos (elige uno)"
        case .thumbnailBrief: return "Miniatura"
        case .description: return "Descripción (borrador)"
        case .chapters: return "Capítulos"
        case .tags: return "Etiquetas"
        case .hashtags: return "Hashtags"
        case .pinnedComment: return "Comentario fijado"
        case .communityPost: return "Texto para comunidad"
        }
    }

    private static func writeBoldField(
        _ field: EscaletaPublishingField,
        publishing: EscaletaPublishingPack,
        colonInsideBold: Bool,
        to writer: inout Writer
    ) {
        let title = boldTitle(for: field)
        switch field {
        case .titleCandidates:
            writer.boldLabelLine(title, value: nil, colonInsideBold: colonInsideBold)
            for (index, candidate) in publishing.titleCandidates.enumerated() {
                writer.line("\(index + 1). \(candidate)")
            }
        case .evidence:
            writer.boldLabelLine(title, value: nil, colonInsideBold: colonInsideBold)
            for item in publishing.evidence {
                writer.bulletLines(item)
            }
        case .chapters:
            writer.boldLabelLine(title, value: nil, colonInsideBold: colonInsideBold)
            for chapter in publishing.chapters {
                writer.line("\(chapter.timestamp) \(chapter.title)")
            }
            for note in publishing.chapterNotes {
                writer.line(note)
            }
        case .description:
            writer.boldLabelLine(
                title,
                value: publishing.description,
                colonInsideBold: colonInsideBold
            )
        case .tags:
            writer.boldLabelLine(
                title,
                value: publishing.tags.joined(separator: ", "),
                colonInsideBold: colonInsideBold
            )
        case .hashtags:
            writer.boldLabelLine(
                title,
                value: publishing.hashtags.joined(separator: " "),
                colonInsideBold: colonInsideBold
            )
        case .primaryTitle:
            writer.boldLabelLine(
                title,
                value: publishing.primaryTitle,
                colonInsideBold: colonInsideBold
            )
        case .thumbnailBrief:
            writer.boldLabelLine(
                title,
                value: publishing.thumbnailBrief,
                colonInsideBold: colonInsideBold
            )
        case .pinnedComment:
            writer.boldLabelLine(
                title,
                value: publishing.pinnedComment,
                colonInsideBold: colonInsideBold
            )
        case .communityPost:
            writer.boldLabelLine(
                title,
                value: publishing.communityPost,
                colonInsideBold: colonInsideBold
            )
        }
    }

    private static func writeFieldValue(
        _ field: EscaletaPublishingField,
        publishing: EscaletaPublishingPack,
        to writer: inout Writer
    ) {
        switch field {
        case .evidence:
            for item in publishing.evidence {
                writer.bulletLines(item)
            }
        case .primaryTitle:
            if let value = publishing.primaryTitle {
                writer.raw(value)
            }
        case .titleCandidates:
            for (index, candidate) in publishing.titleCandidates.enumerated() {
                writer.line("\(index + 1). \(candidate)")
            }
        case .thumbnailBrief:
            if let value = publishing.thumbnailBrief {
                writer.raw(value)
            }
        case .description:
            if let value = publishing.description {
                writer.raw(value)
            }
        case .chapters:
            for chapter in publishing.chapters {
                writer.line("\(chapter.timestamp) \(chapter.title)")
            }
            for note in publishing.chapterNotes {
                writer.line(note)
            }
        case .tags:
            writer.line(publishing.tags.joined(separator: ", "))
        case .hashtags:
            writer.line(publishing.hashtags.joined(separator: " "))
        case .pinnedComment:
            if let value = publishing.pinnedComment {
                writer.raw(value)
            }
        case .communityPost:
            if let value = publishing.communityPost {
                writer.raw(value)
            }
        }
    }

    // MARK: - Thumbnail concepts

    private static func renderThumbnail(
        document: EscaletaDocument,
        thumbnail: ThumbnailConceptsDocument
    ) -> String {
        var writer = Writer()
        if !document.title.isEmpty {
            writer.line("# \(document.title)")
        }
        if let intro = thumbnail.intro, !intro.isEmpty {
            writer.blank()
            writer.raw(intro)
        }
        if thumbnail.separatorAfterIntro {
            writer.blank()
            writer.line("---")
        }

        for group in thumbnail.groups {
            if !group.title.isEmpty {
                writer.blank()
                writer.line("# \(group.title)")
            }
            if let preamble = group.preamble, !preamble.isEmpty {
                writer.blank()
                writer.raw(preamble)
            }
            if let reference = group.referenceTitle {
                writer.blank()
                writer.line("Título de referencia: **\(reference)**")
            }
            for concept in group.concepts {
                writer.blank()
                writer.concept(concept)
            }
            if let heading = group.abTestHeading {
                writer.blank()
                writer.line("## \(heading)")
                if !group.abTestItems.isEmpty {
                    writer.blank()
                    for (index, item) in group.abTestItems.enumerated() {
                        writer.line("\(index + 1). \(item)")
                    }
                }
                if let note = group.abTestNote, !note.isEmpty {
                    writer.blank()
                    writer.raw(note)
                }
            }
            for section in group.unparsedSections {
                writer.blank()
                writer.heading(level: section.level, text: section.heading)
                if !section.body.isEmpty {
                    writer.blank()
                    writer.raw(section.body)
                }
            }
            if group.separatorAfter {
                writer.blank()
                writer.line("---")
            }
        }

        if let heading = thumbnail.sharedRulesHeading {
            writer.blank()
            writer.line("# \(heading)")
            if let notes = thumbnail.sharedRulesNotes, !notes.isEmpty {
                writer.blank()
                writer.raw(notes)
            }
            if !thumbnail.sharedRules.isEmpty {
                writer.blank()
                for (index, rule) in thumbnail.sharedRules.enumerated() {
                    writer.line("\(index + 1). \(rule)")
                }
            }
        }

        for section in thumbnail.unparsedSections {
            writer.blank()
            writer.heading(level: section.level, text: section.heading)
            if !section.body.isEmpty {
                writer.blank()
                writer.raw(section.body)
            }
        }

        return writer.finish()
    }

    // MARK: - Writer

    private struct Writer {
        var lines: [String] = []

        mutating func line(_ value: String) {
            lines.append(value)
        }

        mutating func blank() {
            if lines.last != "" {
                lines.append("")
            }
        }

        mutating func raw(_ text: String) {
            guard !text.isEmpty else { return }
            for line in text.components(separatedBy: "\n") {
                lines.append(line)
            }
        }

        mutating func heading(level: Int, text: String) {
            let safeLevel = max(1, min(level, 6))
            lines.append("\(String(repeating: "#", count: safeLevel)) \(text)")
        }

        mutating func blockquote(_ text: String) {
            for line in text.components(separatedBy: "\n") {
                lines.append(line.isEmpty ? ">" : "> \(line)")
            }
        }

        mutating func bulletLines(_ text: String) {
            let parts = text.components(separatedBy: "\n")
            guard let first = parts.first else { return }
            lines.append("- \(first)")
            for part in parts.dropFirst() {
                lines.append(part)
            }
        }

        mutating func outline(_ items: [EscaletaOutlineItem]) {
            for item in items {
                let indent = String(repeating: "  ", count: max(0, item.indent))
                let marker: String
                switch item.marker {
                case .numbered(let number):
                    marker = "\(number). "
                case .bullet:
                    marker = "- "
                case .plain:
                    marker = ""
                }
                let parts = item.text.components(separatedBy: "\n")
                guard let first = parts.first else { continue }
                lines.append(indent + marker + first)
                for part in parts.dropFirst() {
                    lines.append(indent + part)
                }
            }
        }

        mutating func scene(_ scene: EscaletaScene) {
            let timestamp = scene.timestampText ?? Self.timestamp(from: scene.startSeconds ?? 0)
            lines.append("## \(timestamp) \(scene.separator) \(scene.title)")

            for block in scene.blocks {
                blank()
                switch block {
                case .paragraph(let text):
                    raw(text)
                case .cue(let cue):
                    line(Self.cueLine(cue))
                case .blockquote(let text):
                    blockquote(text)
                case .table(let table):
                    appendTable(table)
                }
            }

            if scene.separatorAfter {
                blank()
                line("---")
            }
        }

        mutating func table(_ table: ComparisonTable) {
            appendTable(table)
        }

        mutating func appendTable(_ table: ComparisonTable) {
            if !table.header.isEmpty {
                lines.append(Self.tableRow(table.header))
            }
            let columnCount = max(table.header.count, table.alignments.count)
            var separatorCells: [String] = []
            for index in 0..<columnCount {
                let alignment = index < table.alignments.count ? table.alignments[index] : .none
                switch alignment {
                case .none: separatorCells.append("---")
                case .leading: separatorCells.append(":---")
                case .center: separatorCells.append(":---:")
                case .trailing: separatorCells.append("---:")
                }
            }
            lines.append("|" + separatorCells.joined(separator: "|") + "|")
            for row in table.rows {
                lines.append(Self.tableRow(row))
            }
        }

        static func tableRow(_ cells: [String]) -> String {
            "|" + cells.map { $0.isEmpty ? " |" : " \($0) |" }.joined()
        }

        mutating func concept(_ concept: ThumbnailConcept) {
            var heading = "## Concepto \(concept.label) — \(concept.text)"
            if concept.recommended {
                heading += " — Recomendado"
            }
            lines.append(heading)

            if let idea = concept.idea, !idea.isEmpty {
                blank()
                boldLabelLine("Idea", value: idea, colonInsideBold: true)
            }
            if !concept.composition.isEmpty {
                blank()
                for item in concept.composition {
                    bulletLines(item)
                }
            }
            if let why = concept.whyItWorks, !why.isEmpty {
                blank()
                boldLabelLine("Por qué funciona", value: why, colonInsideBold: true)
            }
            if let extra = concept.extraText, !extra.isEmpty {
                blank()
                raw(extra)
            }
        }

        mutating func verificationItem(_ item: EscaletaVerificationItem) {
            if let label = item.label {
                let bold = item.colonInsideBold ? "**\(label):**" : "**\(label)**:"
                lines.append("- \(bold)\(item.text.isEmpty ? "" : " \(item.text)")")
            } else {
                bulletLines(item.text)
            }
        }

        mutating func sourceEntry(_ entry: EscaletaSourceEntry) {
            if entry.bullet {
                lines.append("- \(entry.raw)")
            } else {
                lines.append(entry.raw)
            }
        }

        mutating func boldLabelLine(_ label: String, value: String?, colonInsideBold: Bool) {
            let bold = colonInsideBold ? "**\(label):**" : "**\(label)**:"
            guard let value, !value.isEmpty else {
                lines.append(bold)
                return
            }
            if value.contains("\n") {
                lines.append(bold)
                raw(value)
            } else {
                lines.append("\(bold) \(value)")
            }
        }

        mutating func labeledBlock(_ block: EscaletaLabeledBlock, colonInsideBold: Bool) {
            boldLabelLine(block.label, value: block.value, colonInsideBold: colonInsideBold)
        }

        func finish() -> String {
            var result = lines
            while result.first == "" { result.removeFirst() }
            while result.last == "" { result.removeLast() }
            guard !result.isEmpty else { return "" }
            return result.joined(separator: "\n") + "\n"
        }

        static func cueLine(_ cue: EscaletaCue) -> String {
            if let payload = cue.payload, !payload.isEmpty {
                return "[\(cue.label): \(payload)]"
            }
            return "[\(cue.label)]"
        }

        static func timestamp(from seconds: Int) -> String {
            let safe = max(0, seconds)
            let hours = safe / 3600
            let minutes = (safe % 3600) / 60
            let secs = safe % 60
            if hours > 0 {
                return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
            }
            return "\(minutes):\(String(format: "%02d", secs))"
        }
    }
}
