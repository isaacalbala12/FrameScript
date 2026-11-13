import Foundation
import FrameScriptCore

@MainActor
enum EscaletaProjectExporter {
    static func markdown(from project: FrameProject) -> String {
        EscaletaExporter.markdown(from: document(from: project))
    }

    static func document(from project: FrameProject) -> EscaletaDocument {
        let notes = EscaletaProjectNotes.decode(project.topic)
        let metadata = notes.metadata
        let pack = project.publishingPacks[project.primaryLanguage] ?? PublishingPack()
        let sceneMetadata = Dictionary(
            uniqueKeysWithValues: (metadata?.scenes ?? []).map { ($0.sceneID, $0) }
        )

        var scenes: [EscaletaScene] = []
        var fallbackStart = 0
        for scene in project.scenes.sortedByOrder {
            let sceneMeta = sceneMetadata[scene.id.uuidString]
            let start = sceneMeta?.startSeconds ?? fallbackStart
            let timestamp = sceneMeta?.timestampText ?? formatTimestamp(start)
            scenes.append(
                EscaletaScene(
                    startSeconds: start,
                    timestampText: timestamp,
                    title: scene.title,
                    blocks: blocks(
                        from: scene,
                        metadata: sceneMeta,
                        project: project,
                        tableMetadata: metadata?.comparisonTables
                    ),
                    separator: sceneMeta?.separator ?? "—",
                    separatorAfter: sceneMeta?.separatorAfter ?? false,
                    isOutlineFallback: sceneMeta?.isOutlineFallback ?? false
                )
            )
            fallbackStart = start + max(1, Int((scene.targetDuration ?? scene.estimatedDuration).rounded()))
        }

        let legacyEvidence = metadata == nil
            ? project.unparsedSections.first { isHeading($0.heading, "evidencia utilizada") }
            : nil
        let legacyTableNotes = metadata == nil
            ? project.unparsedSections.first { isHeading($0.heading, "notas de tabla") }
            : nil
        let plainUnparsed = metadata == nil
            ? project.unparsedSections.filter {
                !isHeading($0.heading, "notas de tabla") && !isHeading($0.heading, "evidencia utilizada")
            }
            : project.unparsedSections

        let chapters = chapters(from: pack, metadata: metadata?.publishing.chapters)
        let verification = verificationItems(from: project, metadata: metadata?.verificationItems)
        let publishing = publishingPack(
            pack,
            chapters: chapters,
            metadata: metadata?.publishing,
            hasPublishingSection: metadata?.hasPublishingSection,
            fallbackEvidence: legacyEvidence?.body
        )
        let exportSources = sourcesForExport(
            project: project,
            pack: pack,
            metadata: metadata?.sources
        )
        let commonTableHeading: String? = {
            let headings = Set(project.comparisonTables.map(\.title))
            return headings.count == 1 ? headings.first : nil
        }()

        let outlineHeading: String?
        let outline: [EscaletaOutlineItem]
        let scriptHeading: String?
        let seoHeading: String?
        let tableSectionHeading: String?
        let tableSectionNotes: String?
        let verifyHeading: String?
        let sourcesHeading: String?
        if let metadata {
            outlineHeading = metadata.outlineHeading
            outline = metadata.coreOutline
            scriptHeading = metadata.scriptHeading
            seoHeading = metadata.seoHeading
            tableSectionHeading = metadata.tableSectionHeading
            tableSectionNotes = metadata.tableSectionNotes
            verifyHeading = metadata.verifyHeading
            sourcesHeading = metadata.sourcesHeading
        } else {
            outlineHeading = scenes.isEmpty ? nil : "Escaleta"
            outline = scenes.enumerated().map { index, scene in
                EscaletaOutlineItem(marker: .numbered(index + 1), text: scene.title)
            }
            scriptHeading = scenes.isEmpty ? nil : "Guion completo"
            seoHeading = publishing == nil ? nil : "Paquete SEO"
            tableSectionHeading = commonTableHeading
            tableSectionNotes = legacyTableNotes?.body
            verifyHeading = verification.isEmpty ? nil : "Verificar antes de grabar"
            sourcesHeading = exportSources.isEmpty ? nil : "Fuentes principales"
        }

        return EscaletaDocument(
            kind: .escaleta,
            preTitleText: metadata?.preTitleText,
            title: project.title,
            versionNote: notes.versionNote,
            separatorAfterIntro: metadata?.separatorAfterIntro ?? (notes.versionNote != nil),
            promise: notes.promise,
            thesis: notes.thesis,
            outlineHeading: outlineHeading,
            outline: outline,
            scriptHeading: scriptHeading,
            scriptSeparator: metadata?.scriptSeparator ?? true,
            scriptIntro: notes.scriptIntro,
            pacingNotes: notes.pacingNotes,
            scenes: scenes,
            publishing: publishing,
            seoHeading: seoHeading,
            seoHeadingLevel: metadata?.seoHeadingLevel ?? 1,
            seoLayout: metadata?.coreSeoLayout ?? .sectioned,
            comparisonTables: project.comparisonTables.enumerated().map { index, table in
                let tableMeta = tableMetadata(at: index, in: metadata?.comparisonTables)
                return .init(
                    heading: table.title,
                    header: table.header,
                    alignments: coreAlignments(tableMeta?.alignments ?? []),
                    rows: table.rows,
                    sceneIndex: tableMeta?.sceneIndex
                )
            },
            tableSectionHeading: tableSectionHeading,
            tableSectionNotes: tableSectionNotes,
            verifyHeading: verifyHeading,
            verificationItems: verification,
            sourcesHeading: sourcesHeading,
            sources: exportSources.map { sourceEntry(from: $0.source, metadata: $0.metadata) },
            sourcesPlacement: metadata?.coreSourcesPlacement ?? (exportSources.isEmpty ? .none : .seoSection),
            unparsedSections: plainUnparsed.map { section in
                let sectionMeta = metadata?.unparsedSections.first {
                    $0.heading == section.heading && $0.body == section.body
                }
                return EscaletaUnparsedSection(
                    level: sectionMeta?.level ?? 2,
                    heading: section.heading,
                    body: section.body,
                    placement: sectionMeta.flatMap { EscaletaUnparsedPlacement(rawValue: $0.placement) } ?? .document
                )
            }
        )
    }

    // MARK: - Scenes and cues

    private static func blocks(
        from scene: Scene,
        metadata: EscaletaRoundTripMetadata.SceneMetadata?,
        project: FrameProject,
        tableMetadata: [EscaletaRoundTripMetadata.TableMetadata]?
    ) -> [EscaletaSceneBlock] {
        let parsed = scriptParts(scene.scriptText)
        let notes = noteLines(scene)
        if let metadata,
           metadata.textBlockCount == parsed.count,
           metadata.bRollCount == scene.bRollItems.count,
           metadata.editingCount == scene.editingItems.count,
           metadata.noteCount == notes.count {
            return plannedBlocks(
                parsed: parsed,
                notes: notes,
                scene: scene,
                metadata: metadata,
                project: project,
                tableMetadata: tableMetadata
            )
        }
        return fallbackBlocks(from: scene)
    }

    private static func plannedBlocks(
        parsed: [ScriptPart],
        notes: [String],
        scene: Scene,
        metadata: EscaletaRoundTripMetadata.SceneMetadata,
        project: FrameProject,
        tableMetadata: [EscaletaRoundTripMetadata.TableMetadata]?
    ) -> [EscaletaSceneBlock] {
        var blocks: [EscaletaSceneBlock] = []
        for slotIndex in 0...metadata.textBlockCount {
            let references = metadata.slots.indices.contains(slotIndex) ? metadata.slots[slotIndex] : []
            for reference in references {
                switch reference.kind {
                case "broll":
                    guard scene.bRollItems.indices.contains(reference.index) else { continue }
                    blocks.append(.cue(cue(from: scene.bRollItems[reference.index])))
                case "editing":
                    guard scene.editingItems.indices.contains(reference.index) else { continue }
                    blocks.append(.cue(EscaletaCue(label: "RE-HOOK", kind: .rehook)))
                case "note":
                    guard notes.indices.contains(reference.index) else { continue }
                    blocks.append(.cue(cue(fromNote: notes[reference.index])))
                case "table":
                    guard project.comparisonTables.indices.contains(reference.index) else { continue }
                    let table = project.comparisonTables[reference.index]
                    let tableMeta = Self.tableMetadata(at: reference.index, in: tableMetadata)
                    blocks.append(
                        .table(
                            .init(
                                heading: table.title,
                                header: table.header,
                                alignments: coreAlignments(tableMeta?.alignments ?? []),
                                rows: table.rows,
                                sceneIndex: tableMeta?.sceneIndex
                            )
                        )
                    )
                default:
                    continue
                }
            }

            if parsed.indices.contains(slotIndex) {
                switch parsed[slotIndex].kind {
                case .paragraph(let text):
                    blocks.append(.paragraph(text))
                case .blockquote(let text):
                    blocks.append(.blockquote(text))
                case .rehook:
                    blocks.append(.cue(EscaletaCue(label: "RE-HOOK", kind: .rehook)))
                }
            }
        }
        return blocks
    }

    private static func fallbackBlocks(from scene: Scene) -> [EscaletaSceneBlock] {
        let parsed = scriptParts(scene.scriptText)
        var before: [Int: [BRollItem]] = [:]
        var after: [Int: [BRollItem]] = [:]
        var dangling: [BRollItem] = []
        var rehookBefore: [Int: [EditingItem]] = [:]
        var rehookAfter: [Int: [EditingItem]] = [:]
        var danglingRehooks: [EditingItem] = []

        for item in scene.bRollItems {
            guard let anchor = item.textAnchor,
                  let index = paragraphIndex(for: anchor, in: parsed) else {
                dangling.append(item)
                continue
            }
            if positionIsAfter(item) {
                after[index, default: []].append(item)
            } else {
                before[index, default: []].append(item)
            }
        }

        for item in scene.editingItems where isReHook(item) {
            guard let anchor = item.textAnchor,
                  let index = paragraphIndex(for: anchor, in: parsed) else {
                danglingRehooks.append(item)
                continue
            }
            if notesContainAfter(item.notes) {
                rehookAfter[index, default: []].append(item)
            } else {
                rehookBefore[index, default: []].append(item)
            }
        }

        var blocks: [EscaletaSceneBlock] = []
        for (index, part) in parsed.enumerated() {
            for item in before[index, default: []] {
                blocks.append(.cue(cue(from: item)))
            }
            for _ in rehookBefore[index, default: []] {
                blocks.append(.cue(EscaletaCue(label: "RE-HOOK", kind: .rehook)))
            }

            switch part.kind {
            case .paragraph(let text):
                blocks.append(.paragraph(text))
            case .blockquote(let text):
                blocks.append(.blockquote(text))
            case .rehook(let label):
                blocks.append(.cue(EscaletaCue(label: label, kind: .rehook)))
            }

            for item in after[index, default: []] {
                blocks.append(.cue(cue(from: item)))
            }
            for _ in rehookAfter[index, default: []] {
                blocks.append(.cue(EscaletaCue(label: "RE-HOOK", kind: .rehook)))
            }
        }

        for item in dangling {
            blocks.append(.cue(cue(from: item)))
        }
        for _ in danglingRehooks {
            blocks.append(.cue(EscaletaCue(label: "RE-HOOK", kind: .rehook)))
        }

        for note in noteLines(scene) {
            blocks.append(.cue(cue(fromNote: note)))
        }

        return blocks
    }

    private enum ScriptPartKind {
        case paragraph(String)
        case blockquote(String)
        case rehook(String)
    }

    private struct ScriptPart {
        let range: NSRange
        let kind: ScriptPartKind
    }

    private static func scriptParts(_ text: String) -> [ScriptPart] {
        var parts: [ScriptPart] = []
        var location = 0
        let rawParts = text.components(separatedBy: "\n\n")

        for rawPart in rawParts {
            let leading = rawPart.prefix { $0 == "\n" || $0 == " " || $0 == "\t" }.count
            let body = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                let offset = location + leading
                let nsBody = body as NSString
                let range = NSRange(location: offset, length: nsBody.length)
                let trimmedLine = body.trimmingCharacters(in: .whitespaces)
                if trimmedLine == "[RE-HOOK]" || trimmedLine == "[REHOOK]" {
                    parts.append(ScriptPart(range: range, kind: .rehook("RE-HOOK")))
                } else {
                    let lines = body.components(separatedBy: "\n")
                    if lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }) {
                        let unquoted = lines.map { line -> String in
                            let trimmed = line.trimmingCharacters(in: .whitespaces)
                            let withoutMarker = trimmed.dropFirst()
                            return withoutMarker.hasPrefix(" ") ? String(withoutMarker.dropFirst()) : String(withoutMarker)
                        }
                        parts.append(ScriptPart(range: range, kind: .blockquote(unquoted.joined(separator: "\n"))))
                    } else {
                        parts.append(ScriptPart(range: range, kind: .paragraph(body)))
                    }
                }
            }
            location += (rawPart as NSString).length + 2
        }
        return parts
    }

    private static func paragraphIndex(for anchor: TextAnchor, in parts: [ScriptPart]) -> Int? {
        parts.firstIndex { NSLocationInRange(anchor.startUTF16, $0.range) || $0.range.location == anchor.startUTF16 }
    }

    private static func positionIsAfter(_ item: BRollItem) -> Bool {
        notesContainAfter(item.notes)
    }

    private static func notesContainAfter(_ notes: String) -> Bool {
        notes
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Posición: después" }
    }

    private static func isReHook(_ item: EditingItem) -> Bool {
        item.cutStyle == "RE-HOOK" || item.notes.contains("Cue original: [RE-HOOK]")
    }

    private static func noteLines(_ scene: Scene) -> [String] {
        scene.notes
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func cue(fromNote note: String) -> EscaletaCue {
        if note.hasPrefix("Nota de grabación:") {
            let payload = note.dropFirst("Nota de grabación:".count).trimmingCharacters(in: .whitespaces)
            return EscaletaCue(label: "NOTA DE GRABACIÓN", payload: payload, kind: .recordingNote)
        }
        if note.hasPrefix("Cue desconocido [") {
            return unknownCue(from: note)
        }
        return EscaletaCue(label: "NOTA DE GRABACIÓN", payload: note, kind: .recordingNote)
    }

    private static func cue(from item: BRollItem) -> EscaletaCue {
        if let original = originalCueLine(in: item.notes) {
            return original
        }
        let label = defaultLabel(for: item.sourceType)
        let payload = item.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return EscaletaCue(
            label: label,
            payload: payload.isEmpty || payload == label ? nil : payload,
            kind: EscaletaCueKind(label: label)
        )
    }

    private static func originalCueLine(in notes: String) -> EscaletaCue? {
        for line in notes.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Cue original: ["), trimmed.hasSuffix("]") else { continue }
            var body = String(trimmed.dropFirst("Cue original: [".count))
            body.removeLast()
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let label = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { return nil }
            let payload = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            return EscaletaCue(label: label, payload: payload, kind: EscaletaCueKind(label: label))
        }
        return nil
    }

    private static func defaultLabel(for source: BRollSourceType) -> String {
        switch source {
        case .talkingHead: "GRABAR"
        case .textOnScreen: "RÓTULO"
        case .screenshot: "IMAGEN"
        case .infographic: "TABLA EN PANTALLA"
        case .screenRecording, .stockFootage, .animation, .memeInsert, .productShot, .custom: "B-ROLL"
        }
    }

    private static func unknownCue(from note: String) -> EscaletaCue {
        var body = String(note.dropFirst("Cue desconocido [".count))
        guard let closing = body.firstIndex(of: "]") else {
            return EscaletaCue(label: "NOTA", payload: note, kind: .unknown)
        }
        let label = String(body[..<closing])
        body = String(body[body.index(after: closing)...])
        if body.hasPrefix(":") { body.removeFirst() }
        let payload = body.trimmingCharacters(in: .whitespaces)
        return EscaletaCue(label: label, payload: payload.isEmpty ? nil : payload, kind: .unknown)
    }

    // MARK: - Publishing

    private static func publishingPack(
        _ pack: PublishingPack,
        chapters: [EscaletaChapter],
        metadata: EscaletaRoundTripMetadata.PublishingMetadata?,
        hasPublishingSection: Bool?,
        fallbackEvidence: String?
    ) -> EscaletaPublishingPack? {
        if let hasPublishingSection, !hasPublishingSection {
            return nil
        }
        var publishing = EscaletaPublishingPack()
        let hasPrimaryTitle = metadata.map {
            $0.hasPrimaryTitle || pack.chosenTitle != $0.originalChosenTitle
        } ?? !pack.chosenTitle.isEmpty
        publishing.primaryTitle = hasPrimaryTitle ? nonEmpty(pack.chosenTitle) : nil
        publishing.titleCandidates = pack.titleCandidates
        publishing.thumbnailBrief = nonEmpty(pack.thumbnailConceptNotes)
        publishing.description = nonEmpty(pack.description)
        publishing.chapters = chapters
        publishing.tags = pack.tags
        publishing.hashtags = pack.hashtags
        publishing.pinnedComment = nonEmpty(pack.pinnedComment)
        publishing.communityPost = nonEmpty(pack.communityPost)
        publishing.preamble = metadata?.preamble
        publishing.evidence = metadata?.evidence ?? evidenceLines(fallbackEvidence)
        publishing.extraFields = metadata?.extraFields.map {
            EscaletaLabeledBlock(
                label: $0.label,
                value: $0.value,
                colonInsideBold: $0.colonInsideBold
            )
        } ?? []
        publishing.chapterNotes = metadata?.chapterNotes ?? []
        publishing.fieldOrder = (metadata?.fieldOrder ?? []).compactMap(EscaletaPublishingField.init(rawValue:))
        publishing.boldLabelsColonInside = metadata?.boldLabelsColonInside ?? true
        publishing.chaptersPlacement = metadata.flatMap {
            EscaletaChaptersPlacement(rawValue: $0.chaptersPlacement)
        } ?? (chapters.isEmpty ? .none : .section)
        // Imported documents keep empty canonical sections verbatim. A pack
        // with metadata must survive even when every field is empty.
        return metadata != nil || publishing.hasContent ? publishing : nil
    }

    private static func chapters(
        from pack: PublishingPack,
        metadata: [EscaletaRoundTripMetadata.ChapterMetadata]?
    ) -> [EscaletaChapter] {
        pack.chapterOverrides
            .sorted { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }
            .enumerated()
            .map { index, override in
                let seconds = Int((override.startSeconds ?? 0).rounded())
                let original = metadata.flatMap {
                    $0.indices.contains(index) && $0[index].seconds == seconds && $0[index].title == override.title
                        ? $0[index]
                        : nil
                }
                return EscaletaChapter(
                    seconds: seconds,
                    timestamp: original?.timestamp ?? formatTimestamp(seconds),
                    title: override.title
                )
            }
    }

    private static func evidenceLines(_ body: String?) -> [String] {
        guard let body else { return [] }
        return body
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                return line
            }
    }

    // MARK: - Sources and verification

    private static func sourcesForExport(
        project: FrameProject,
        pack: PublishingPack,
        metadata: [EscaletaRoundTripMetadata.SourceMetadata]?
    ) -> [(source: ProjectSource, metadata: EscaletaRoundTripMetadata.SourceMetadata?)] {
        let all = project.sources.enumerated().map { index, source in
            let sourceMeta = metadata.flatMap { $0.indices.contains(index) ? $0[index] : nil }
            return (source: source, metadata: sourceMeta)
        }
        let description = pack.description
        guard description.localizedCaseInsensitiveContains("Fuentes oficiales y referencias") else {
            return all
        }
        return all.filter { pair in
            pair.source.url.isEmpty || !description.localizedCaseInsensitiveContains(pair.source.url)
        }
    }

    private static func sourceEntry(
        from source: ProjectSource,
        metadata: EscaletaRoundTripMetadata.SourceMetadata?
    ) -> EscaletaSourceEntry {
        let raw: String
        if !source.note.isEmpty {
            raw = source.note
        } else if !source.url.isEmpty {
            raw = source.title.isEmpty ? source.url : "[\(source.title)](\(source.url))"
        } else {
            raw = source.title
        }
        if let metadata, metadata.raw == raw {
            return EscaletaSourceEntry(
                raw: raw,
                bullet: metadata.bullet,
                links: metadata.links.map { EscaletaSourceLink(title: $0.title, url: $0.url) },
                origin: EscaletaSourceOrigin(rawValue: metadata.origin) ?? .section
            )
        }
        var links: [EscaletaSourceLink] = []
        if !source.url.isEmpty {
            links.append(EscaletaSourceLink(title: nonEmpty(source.title), url: source.url))
        }
        return EscaletaSourceEntry(raw: raw, bullet: true, links: links, origin: .section)
    }

    private static func verificationItems(
        from project: FrameProject,
        metadata: [EscaletaRoundTripMetadata.VerificationMetadata]?
    ) -> [EscaletaVerificationItem] {
        let tasks = project.checklistTasks.filter { $0.kind == .research }
        if let metadata,
           metadata.count == tasks.count,
           zip(metadata, tasks).allSatisfy({ combinedVerification($0.0) == $0.1.text }) {
            return metadata.map {
                EscaletaVerificationItem(
                    label: $0.label,
                    text: $0.text,
                    colonInsideBold: $0.colonInsideBold
                )
            }
        }
        return tasks.map { verificationFallback(from: $0.text) }
    }

    private static func combinedVerification(_ item: EscaletaRoundTripMetadata.VerificationMetadata) -> String {
        guard let label = item.label, !label.isEmpty else { return item.text }
        guard !item.text.isEmpty else { return "\(label):" }
        return "\(label): \(item.text)"
    }

    private static func verificationFallback(from text: String) -> EscaletaVerificationItem {
        if let colon = text.firstIndex(of: ":") {
            let label = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            let body = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty, !body.isEmpty, label.count < 80 {
                return EscaletaVerificationItem(label: label, text: body)
            }
        }
        return EscaletaVerificationItem(text: text)
    }

    // MARK: - Tables

    private static func tableMetadata(
        at index: Int,
        in metadata: [EscaletaRoundTripMetadata.TableMetadata]?
    ) -> EscaletaRoundTripMetadata.TableMetadata? {
        guard let metadata, metadata.indices.contains(index) else { return nil }
        return metadata[index]
    }

    private static func coreAlignments(_ raw: [String]) -> [EscaletaTableAlignment] {
        raw.map { EscaletaTableAlignment(rawValue: $0) ?? .none }
    }

    // MARK: - Helpers

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isHeading(_ heading: String, _ expected: String) -> Bool {
        heading
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
            .trimmingCharacters(in: .whitespacesAndNewlines) == expected
    }

    private static func formatTimestamp(_ seconds: Int) -> String {
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
