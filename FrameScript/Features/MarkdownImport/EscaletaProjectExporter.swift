import Foundation
import FrameScriptCore

/// Project fields that the v4 app model keeps in free-text notes (`topic`).
/// The importer writes this labelled block and the exporter reads it back, so
/// the promise, thesis and other front matter survive a round-trip without
/// changing the frozen model or file schema.
struct EscaletaProjectNotes: Equatable, Sendable {
    var promise: String?
    var thesis: String?
    var versionNote: String?
    var scriptIntro: String?
    var pacingNotes: [String] = []

    static let promiseLabel = "Promesa:"
    static let thesisLabel = "Tesis:"
    static let versionLabel = "Nota de versión:"
    static let introLabel = "Entrada del guion:"
    static let pacingLabel = "Notas de ritmo:"

    var isEmpty: Bool {
        promise == nil && thesis == nil && versionNote == nil && scriptIntro == nil && pacingNotes.isEmpty
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
            case promiseLabel: notes.promise = value.isEmpty ? nil : value
            case thesisLabel: notes.thesis = value.isEmpty ? nil : value
            case versionLabel: notes.versionNote = value.isEmpty ? nil : value
            case introLabel: notes.scriptIntro = value.isEmpty ? nil : value
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
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sections.append("\(label)\n\(value.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

@MainActor
enum EscaletaProjectExporter {
    static func markdown(from project: FrameProject) -> String {
        EscaletaExporter.markdown(from: document(from: project))
    }

    static func document(from project: FrameProject) -> EscaletaDocument {
        let notes = EscaletaProjectNotes.decode(project.topic)
        let pack = project.publishingPacks[project.primaryLanguage] ?? PublishingPack()
        let unparsed = project.unparsedSections
        let tableNotes = unparsed.first { isHeading($0.heading, "notas de tabla") }
        let evidence = unparsed.first { isHeading($0.heading, "evidencia utilizada") }
        let plainUnparsed = unparsed.filter {
            !isHeading($0.heading, "notas de tabla") && !isHeading($0.heading, "evidencia utilizada")
        }

        var scenes: [EscaletaScene] = []
        var startSeconds = 0
        for scene in project.scenes.sortedByOrder {
            let duration = scene.targetDuration ?? scene.estimatedDuration
            let seconds = max(0, startSeconds)
            scenes.append(
                EscaletaScene(
                    startSeconds: seconds,
                    timestampText: formatTimestamp(seconds),
                    title: scene.title,
                    blocks: blocks(from: scene),
                    separator: "—"
                )
            )
            startSeconds = seconds + max(1, Int(duration.rounded()))
        }

        let commonTableHeading: String? = {
            let headings = Set(project.comparisonTables.map(\.title))
            return headings.count == 1 ? headings.first : nil
        }()

        let chapters = pack.chapterOverrides
            .sorted { ($0.startSeconds ?? 0) < ($1.startSeconds ?? 0) }
            .map { override in
                let seconds = Int((override.startSeconds ?? 0).rounded())
                return EscaletaChapter(
                    seconds: seconds,
                    timestamp: formatTimestamp(seconds),
                    title: override.title
                )
            }

        let verification = project.checklistTasks
            .filter { $0.kind == .research }
            .map { task in
                EscaletaVerificationItem(text: task.text)
            }

        let exportSources = sourcesForExport(project: project, pack: pack)

        let publishing = publishingPack(
            pack,
            chapters: chapters,
            evidence: evidence.map(\.body),
            title: project.title
        )

        return EscaletaDocument(
            kind: .escaleta,
            title: project.title,
            versionNote: notes.versionNote,
            separatorAfterIntro: notes.versionNote != nil,
            promise: notes.promise,
            thesis: notes.thesis,
            outlineHeading: scenes.isEmpty ? nil : "Escaleta",
            outline: scenes.enumerated().map { index, scene in
                EscaletaOutlineItem(marker: .numbered(index + 1), text: scene.title)
            },
            scriptHeading: scenes.isEmpty ? nil : "Guion completo",
            scriptSeparator: true,
            scriptIntro: notes.scriptIntro,
            pacingNotes: notes.pacingNotes,
            scenes: scenes,
            publishing: publishing,
            seoHeading: publishing == nil ? nil : "Paquete SEO",
            seoHeadingLevel: 1,
            seoLayout: .sectioned,
            comparisonTables: project.comparisonTables.map { table in
                .init(heading: table.title, header: table.header, rows: table.rows)
            },
            tableSectionHeading: commonTableHeading,
            tableSectionNotes: tableNotes?.body,
            verifyHeading: verification.isEmpty ? nil : "Verificar antes de grabar",
            verificationItems: verification,
            sourcesHeading: exportSources.isEmpty ? nil : "Fuentes principales",
            sources: exportSources.map(sourceEntry(from:)),
            sourcesPlacement: exportSources.isEmpty ? .none : .seoSection,
            unparsedSections: plainUnparsed.map {
                EscaletaUnparsedSection(level: 2, heading: $0.heading, body: $0.body, placement: .document)
            }
        )
    }

    // MARK: - Scenes and cues

    private static func blocks(from scene: Scene) -> [EscaletaSceneBlock] {
        let parsed = scriptParts(scene.scriptText)
        var before: [Int: [BRollItem]] = [:]
        var after: [Int: [BRollItem]] = [:]
        var dangling: [BRollItem] = []

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

        var blocks: [EscaletaSceneBlock] = []
        for (index, part) in parsed.enumerated() {
            for item in before[index, default: []] {
                blocks.append(.cue(cue(from: item)))
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
        }

        for item in dangling {
            blocks.append(.cue(cue(from: item)))
        }

        for note in scene.notes.components(separatedBy: "\n") {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("Nota de grabación:") {
                let payload = trimmed.dropFirst("Nota de grabación:".count).trimmingCharacters(in: .whitespaces)
                blocks.append(.cue(EscaletaCue(label: "NOTA DE GRABACIÓN", payload: payload, kind: .recordingNote)))
            } else if trimmed.hasPrefix("Cue desconocido [") {
                blocks.append(.cue(unknownCue(from: trimmed)))
            } else {
                blocks.append(.cue(EscaletaCue(label: "NOTA DE GRABACIÓN", payload: trimmed, kind: .recordingNote)))
            }
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
                var offset = location + leading
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
                offset += nsBody.length
            }
            location += (rawPart as NSString).length + 2
        }
        return parts
    }

    private static func paragraphIndex(for anchor: TextAnchor, in parts: [ScriptPart]) -> Int? {
        parts.firstIndex { NSLocationInRange(anchor.startUTF16, $0.range) || $0.range.location == anchor.startUTF16 }
    }

    private static func positionIsAfter(_ item: BRollItem) -> Bool {
        item.notes
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "Posición: después" }
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
        evidence: String?,
        title: String
    ) -> EscaletaPublishingPack? {
        var publishing = EscaletaPublishingPack()
        publishing.evidence = evidenceLines(evidence)
        publishing.primaryTitle = nonEmpty(pack.chosenTitle)
        publishing.titleCandidates = pack.titleCandidates
        publishing.thumbnailBrief = nonEmpty(pack.thumbnailConceptNotes)
        publishing.description = nonEmpty(pack.description)
        publishing.chapters = chapters
        publishing.tags = pack.tags
        publishing.hashtags = pack.hashtags
        publishing.pinnedComment = nonEmpty(pack.pinnedComment)
        publishing.communityPost = nonEmpty(pack.communityPost)
        publishing.chaptersPlacement = chapters.isEmpty ? .none : .section
        // Empty order lets the core exporter write only fields with content.
        publishing.fieldOrder = []
        publishing.boldLabelsColonInside = true
        return publishing.hasContent ? publishing : nil
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

    private static func sourceEntry(from source: ProjectSource) -> EscaletaSourceEntry {
        let raw: String
        if !source.note.isEmpty {
            raw = source.note
        } else if !source.url.isEmpty {
            raw = source.title.isEmpty ? source.url : "[\(source.title)](\(source.url))"
        } else {
            raw = source.title
        }
        var links: [EscaletaSourceLink] = []
        if !source.url.isEmpty {
            links.append(EscaletaSourceLink(title: nonEmpty(source.title), url: source.url))
        }
        return EscaletaSourceEntry(raw: raw, bullet: true, links: links, origin: .section)
    }

    /// Sources already present as the `Fuentes oficiales y referencias:`
    /// trailer in the description must not be written again as a section:
    /// the parser would count every URL twice.
    private static func sourcesForExport(project: FrameProject, pack: PublishingPack) -> [ProjectSource] {
        let description = pack.description
        guard description.localizedCaseInsensitiveContains("Fuentes oficiales y referencias") else {
            return project.sources
        }
        return project.sources.filter { source in
            source.url.isEmpty || !description.localizedCaseInsensitiveContains(source.url)
        }
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
