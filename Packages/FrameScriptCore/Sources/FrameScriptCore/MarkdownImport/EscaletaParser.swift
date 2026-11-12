import Foundation

/// Parses Isaac's Markdown escaleta contract (02-propuesta §3) into a
/// structural document. The parser is deliberately forgiving: unknown content
/// is preserved in `unparsedSections` and problems become warnings.
public enum EscaletaParser {
    public static func parse(_ markdown: String) -> EscaletaImportResult {
        var parser = Parser(markdown: markdown)
        return parser.run()
    }
}

private struct Parser {
    let lines: [String]
    var warnings: [EscaletaWarning] = []
    var document = EscaletaDocument()
    var sawTimestampScene = false
    var previousSceneStart: Int?

    init(markdown: String) {
        lines = MarkdownParsingSupport.normalizedLines(markdown)
    }

    mutating func run() -> EscaletaImportResult {
        guard !lines.isEmpty, !lines.allSatisfy({ MarkdownParsingSupport.isBlank($0) }) else {
            warnings.append(
                EscaletaWarning(kind: .missingTitle, message: "El documento está vacío o no tiene título.")
            )
            document.kind = .other
            return result()
        }

        let tree = MarkdownNode.buildTree(lines)
        guard let titleNode = tree.first(where: { $0.level == 1 }) else {
            warnings.append(
                EscaletaWarning(kind: .missingTitle, message: "No se encontró ningún título de nivel 1.")
            )
            document.title = lines.first(where: { !MarkdownParsingSupport.isBlank($0) })
                .map(MarkdownParsingSupport.trimmed) ?? ""
            document.kind = .other
            return result()
        }

        document.title = titleNode.heading
        parseIntro(titleNode)

        if isThumbnailDocument(tree: tree) {
            var thumbnailParser = ThumbnailConceptsParser(
                lines: lines,
                tree: tree,
                titleNode: titleNode
            )
            let thumbnail = thumbnailParser.parse()
            document.kind = .thumbnailConcepts
            document.versionNote = nil
            document.separatorAfterIntro = false
            document.thumbnailConcepts = thumbnail.document
            warnings.append(contentsOf: thumbnail.warnings)
            return result()
        }

        for child in titleNode.children {
            parseFrontMatterSection(child)
        }

        for node in tree where node.lineIndex != titleNode.lineIndex {
            parseTopLevel(node)
        }

        if !sawTimestampScene, !document.outline.isEmpty {
            document.scenes = document.outline.enumerated().map { index, item in
                EscaletaScene(
                    startSeconds: nil,
                    timestampText: nil,
                    title: item.text,
                    blocks: [],
                    isOutlineFallback: true
                )
            }
            warnings.append(
                EscaletaWarning(
                    kind: .outlineFallback,
                    message: "No había escenas con timestamp; se usó la escaleta como respaldo (\(document.scenes.count) escenas).",
                    line: document.outlineHeading.flatMap(lineNumber(ofHeading:))
                )
            )
        }

        validate()
        document.kind = detectKind()
        return result()
    }

    // MARK: - Front matter

    mutating func parseIntro(_ titleNode: MarkdownNode) {
        let range = titleNode.preambleRange()
        guard !range.isEmpty else { return }
        let preamble = Array(lines[range])
        let stripped = MarkdownParsingSupport.strippingTrailingRule(preamble)
        document.versionNote = stripped.body.isEmpty ? nil : stripped.body
        document.separatorAfterIntro = stripped.hadRule
    }

    mutating func parseFrontMatterSection(_ node: MarkdownNode) {
        if MarkdownParsingSupport.sceneHeading(lines[node.lineIndex]) != nil {
            _ = parseScene(node)
            return
        }

        let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
        switch normalized {
        case "promesa del video", "promesa":
            let body = sectionBody(node)
            if body.isEmpty {
                warnEmptySection(node)
                if document.promise == nil { document.promise = "" }
            } else {
                document.promise = mergeText(document.promise, body)
            }
        case "tesis", "idea central":
            let body = sectionBody(node)
            if body.isEmpty {
                warnEmptySection(node)
                if document.thesis == nil { document.thesis = "" }
            } else {
                document.thesis = mergeText(document.thesis, body)
            }
        case "escaleta":
            parseOutline(node)
        case "seo", "paquete seo":
            parseSEO(node)
        default:
            if isTableSection(normalized) {
                parseTableSection(node)
            } else if isVerificationSection(normalized) {
                parseVerificationSection(node)
            } else if isSourcesSection(normalized) {
                parseSourcesSection(node)
            } else if MarkdownParsingSupport.looksLikeSceneHeading(lines[node.lineIndex]) {
                warnUnrecognizedSceneHeading(node)
                appendUnparsed(node, placement: .preamble)
            } else {
                appendUnparsed(node, placement: .preamble)
            }
        }
    }

    // MARK: - Top level

    mutating func parseTopLevel(_ node: MarkdownNode) {
        if node.level == 1 {
            let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
            if isScriptHeading(normalized) {
                parseScript(node)
            } else if isSEOHeading(normalized) {
                parseSEO(node)
            } else {
                appendUnparsed(node, placement: .document)
            }
            return
        }

        if MarkdownParsingSupport.sceneHeading(lines[node.lineIndex]) != nil {
            _ = parseScene(node)
            return
        }

        let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
        if isTableSection(normalized) {
            parseTableSection(node)
        } else if isVerificationSection(normalized) {
            parseVerificationSection(node)
        } else if isSourcesSection(normalized) {
            parseSourcesSection(node)
        } else if isSEOHeading(normalized) {
            parseSEO(node)
        } else {
            if MarkdownParsingSupport.looksLikeSceneHeading(lines[node.lineIndex]) {
                warnUnrecognizedSceneHeading(node)
            }
            let placement: EscaletaUnparsedPlacement = document.scriptHeading == nil ? .preamble : .document
            appendUnparsed(node, placement: placement)
        }
    }

    // MARK: - Script

    mutating func parseScript(_ node: MarkdownNode) {
        if document.scriptHeading == nil {
            document.scriptHeading = node.heading
        }

        let preamble = Array(lines[node.preambleRange()])
        parseScriptPreamble(preamble, startLine: node.lineIndex + 2)

        var annexStarted = false
        var hasSeenScene = false
        for child in node.children {
            if !annexStarted, let scene = parseScene(child) {
                _ = scene
                hasSeenScene = true
                continue
            }

            if isAnnexHeading(child) {
                annexStarted = true
                parseAnnex(child)
                continue
            }

            if MarkdownParsingSupport.looksLikeSceneHeading(lines[child.lineIndex]) {
                warnUnrecognizedSceneHeading(child)
            }
            appendUnparsed(child, placement: annexStarted || hasSeenScene ? .document : .preamble)
        }
    }

    mutating func parseScriptPreamble(_ preamble: [String], startLine: Int) {
        var introLines: [String] = []
        var index = 0
        while index < preamble.count {
            let line = preamble[index]
            if MarkdownParsingSupport.isHorizontalRule(line) {
                index += 1
                continue
            }
            if MarkdownParsingSupport.trimmed(line).hasPrefix(">") {
                var noteLines: [String] = []
                while index < preamble.count, MarkdownParsingSupport.trimmed(preamble[index]).hasPrefix(">") {
                    var content = MarkdownParsingSupport.trimmed(preamble[index])
                    content.removeFirst()
                    if content.hasPrefix(" ") { content.removeFirst() }
                    noteLines.append(content)
                    index += 1
                }
                let note = MarkdownParsingSupport.trimmedBlock(noteLines)
                if !note.isEmpty {
                    document.pacingNotes.append(note)
                }
            } else {
                if !MarkdownParsingSupport.isBlank(line) {
                    introLines.append(line)
                } else if !introLines.isEmpty {
                    introLines.append(line)
                }
                index += 1
            }
        }

        let intro = MarkdownParsingSupport.trimmedBlock(introLines)
        if !intro.isEmpty {
            document.scriptIntro = mergeText(document.scriptIntro, intro)
        }
    }

    mutating func parseAnnex(_ node: MarkdownNode) {
        let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
        if isTableSection(normalized) {
            parseTableSection(node)
        } else if isVerificationSection(normalized) {
            parseVerificationSection(node)
        } else if isSourcesSection(normalized) {
            parseSourcesSection(node)
        } else if isSEOHeading(normalized) {
            parseSEO(node)
        } else if normalized.contains("concepto de miniatura"), var pack = document.publishing {
            let body = sectionBody(node)
            if !body.isEmpty {
                pack.thumbnailBrief = mergeText(pack.thumbnailBrief, body)
                document.publishing = pack
            } else {
                appendUnparsed(node, placement: .document)
            }
        } else {
            appendUnparsed(node, placement: .document)
        }
    }

    mutating func parseScene(_ node: MarkdownNode) -> EscaletaScene? {
        guard let heading = MarkdownParsingSupport.sceneHeading(lines[node.lineIndex]) else {
            return nil
        }

        let body = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))
        let sceneIndex = document.scenes.count
        let blocks = parseSceneBlocks(
            body,
            absoluteStartLine: node.lineIndex + 2,
            sceneIndex: sceneIndex
        )

        let scene = EscaletaScene(
            startSeconds: heading.seconds,
            timestampText: heading.timestampText,
            title: heading.title,
            blocks: blocks,
            separator: heading.separator
        )

        if let previous = previousSceneStart, heading.seconds < previous {
            warnings.append(
                EscaletaWarning(
                    kind: .descendingTimestamp,
                    message: "El timestamp \(heading.timestampText) (\(heading.title)) no es ascendente respecto al anterior.",
                    line: node.lineIndex + 1
                )
            )
        }
        previousSceneStart = heading.seconds
        sawTimestampScene = true
        document.scenes.append(scene)

        if body.allSatisfy({ MarkdownParsingSupport.isBlank($0) }) {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La escena \(heading.timestampText) no tiene cuerpo.",
                    line: node.lineIndex + 1
                )
            )
        }
        return scene
    }

    mutating func parseSceneBlocks(
        _ body: [String],
        absoluteStartLine: Int,
        sceneIndex: Int
    ) -> [EscaletaSceneBlock] {
        var blocks: [EscaletaSceneBlock] = []
        var paragraph: [String] = []
        var paragraphStart = absoluteStartLine
        var index = 0

        while index < body.count {
            let line = body[index]
            let absoluteLine = absoluteStartLine + index

            if MarkdownParsingSupport.isBlank(line) {
                flushParagraph(&paragraph, startLine: paragraphStart, into: &blocks)
                index += 1
                continue
            }

            if let parsedCue = MarkdownParsingSupport.cue(line) {
                flushParagraph(&paragraph, startLine: paragraphStart, into: &blocks)
                let cue = EscaletaCue(
                    label: parsedCue.label,
                    payload: parsedCue.payload,
                    line: absoluteLine
                )
                blocks.append(.cue(cue))
                if cue.kind == .unknown {
                    warnings.append(
                        EscaletaWarning(
                            kind: .unknownCue,
                            message: "Cue desconocido conservado en notas: [\(cue.label)].",
                            line: absoluteLine
                        )
                    )
                }
                index += 1
                continue
            }

            if MarkdownParsingSupport.isTableRow(line),
               let parsedTable = MarkdownParsingSupport.parseTable(
                   lines: body,
                   start: index,
                   heading: nil,
                   sceneIndex: sceneIndex
               ) {
                flushParagraph(&paragraph, startLine: paragraphStart, into: &blocks)
                blocks.append(.table(parsedTable.table))
                document.comparisonTables.append(parsedTable.table)
                for message in parsedTable.rowWarnings {
                    warnings.append(
                        EscaletaWarning(kind: .malformedTable, message: message, line: absoluteLine)
                    )
                }
                index = parsedTable.end
                continue
            }

            if MarkdownParsingSupport.trimmed(line).hasPrefix(">"), paragraph.isEmpty {
                flushParagraph(&paragraph, startLine: paragraphStart, into: &blocks)
                var noteLines: [String] = []
                var noteIndex = index
                while noteIndex < body.count,
                      MarkdownParsingSupport.trimmed(body[noteIndex]).hasPrefix(">") {
                    var content = MarkdownParsingSupport.trimmed(body[noteIndex])
                    content.removeFirst()
                    if content.hasPrefix(" ") { content.removeFirst() }
                    noteLines.append(content)
                    noteIndex += 1
                }
                let note = MarkdownParsingSupport.trimmedBlock(noteLines)
                if !note.isEmpty {
                    blocks.append(.blockquote(note))
                }
                index = noteIndex
                continue
            }

            if paragraph.isEmpty {
                paragraphStart = absoluteLine
            }
            paragraph.append(line)
            index += 1
        }

        flushParagraph(&paragraph, startLine: paragraphStart, into: &blocks)
        return blocks
    }

    mutating func flushParagraph(
        _ paragraph: inout [String],
        startLine: Int,
        into blocks: inout [EscaletaSceneBlock]
    ) {
        guard !paragraph.isEmpty else { return }
        let text = MarkdownParsingSupport.trimmedBlock(paragraph)
        paragraph.removeAll()
        guard !text.isEmpty else { return }
        blocks.append(.paragraph(text))
        if let label = MarkdownParsingSupport.inlineCue(in: text) {
            warnings.append(
                EscaletaWarning(
                    kind: .inlineCue,
                    message: "Cue en línea conservado en el guion: [\(label)].",
                    line: startLine
                )
            )
        }
    }

    // MARK: - Outline

    mutating func parseOutline(_ node: MarkdownNode) {
        if document.outlineHeading == nil {
            document.outlineHeading = node.heading
        }
        let items = MarkdownParsingSupport.parseOutlineItems(
            MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange])),
            startingAt: node.lineIndex + 2
        )
        if items.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» está vacía.",
                    line: node.lineIndex + 1
                )
            )
        }
        document.outline.append(contentsOf: items)
    }

    // MARK: - SEO

    mutating func parseSEO(_ node: MarkdownNode) {
        var pack = document.publishing ?? EscaletaPublishingPack(fieldOrder: [])
        if document.publishing == nil {
            pack.fieldOrder = []
        }

        let contentLines = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))
        let hasChildren = !node.children.isEmpty
        let hasBoldLabels = contentLines.contains { MarkdownParsingSupport.boldLabel($0) != nil }

        let layout: EscaletaSEOLayout
        if node.level == 2 || (!hasChildren && hasBoldLabels) {
            layout = .boldLabels
        } else {
            layout = .sectioned
        }

        if document.seoHeading == nil {
            document.seoHeading = node.heading
            document.seoHeadingLevel = node.level
            document.seoLayout = layout
        }

        switch layout {
        case .sectioned:
            let preamble = Array(lines[node.preambleRange()])
            let preambleText = MarkdownParsingSupport.trimmedBlock(preamble)
            if !preambleText.isEmpty {
                pack.preamble = mergeText(pack.preamble, preambleText)
            }

            for child in node.children {
                let normalized = MarkdownParsingSupport.normalizedHeading(child.heading)
                if isTableSection(normalized) {
                    parseTableSection(child)
                } else if isVerificationSection(normalized) {
                    parseVerificationSection(child)
                } else if isSourcesSection(normalized) {
                    parseSourcesSection(child)
                } else if let field = publishingField(for: normalized) {
                    applyField(
                        field,
                        lines: Array(lines[child.contentRange]),
                        lineStart: child.lineIndex + 2,
                        pack: &pack
                    )
                } else {
                    appendUnparsed(child, placement: .seo)
                }
            }

        case .boldLabels:
            parseBoldSEOBody(
                contentLines,
                startLine: node.lineIndex + 2,
                pack: &pack
            )
        }

        if !pack.hasContent, pack.preamble == nil {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» no contiene campos reconocibles.",
                    line: node.lineIndex + 1
                )
            )
        }

        document.publishing = pack
    }

    mutating func parseBoldSEOBody(
        _ content: [String],
        startLine: Int,
        pack: inout EscaletaPublishingPack
    ) {
        var index = 0
        var preambleLines: [String] = []
        var sawLabel = false

        while index < content.count {
            guard let bold = MarkdownParsingSupport.boldLabel(content[index]) else {
                if !sawLabel {
                    preambleLines.append(content[index])
                }
                index += 1
                continue
            }

            sawLabel = true
            var valueLines: [String] = []
            if !bold.value.isEmpty {
                valueLines.append(bold.value)
            }
            var next = index + 1
            while next < content.count, MarkdownParsingSupport.boldLabel(content[next]) == nil {
                valueLines.append(content[next])
                next += 1
            }

            let line = startLine + index
            if let field = publishingField(for: MarkdownParsingSupport.normalizedHeading(bold.label)) {
                applyField(field, lines: valueLines, lineStart: line, pack: &pack)
            } else {
                let value = MarkdownParsingSupport.trimmedBlock(valueLines)
                pack.extraFields.append(
                    EscaletaLabeledBlock(
                        label: bold.label,
                        value: value,
                        colonInsideBold: bold.colonInsideBold,
                        line: line
                    )
                )
            }
            pack.boldLabelsColonInside = pack.boldLabelsColonInside && bold.colonInsideBold
            index = next
        }

        let preamble = MarkdownParsingSupport.trimmedBlock(preambleLines)
        if !preamble.isEmpty {
            pack.preamble = mergeText(pack.preamble, preamble)
        }
    }

    mutating func applyField(
        _ field: EscaletaPublishingField,
        lines fieldLines: [String],
        lineStart: Int,
        pack: inout EscaletaPublishingPack
    ) {
        if !pack.fieldOrder.contains(field) {
            pack.fieldOrder.append(field)
        }

        let cleanedLines = MarkdownParsingSupport.linesWithoutTrailingRule(fieldLines)
        let raw = MarkdownParsingSupport.trimmedBlock(cleanedLines)
        if raw.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "El campo SEO «\(field.rawValue)» está vacío.",
                    line: lineStart
                )
            )
            return
        }

        switch field {
        case .evidence:
            let items = MarkdownParsingSupport.parseListItems(cleanedLines)
            pack.evidence.append(contentsOf: items.isEmpty ? [raw] : items)

        case .primaryTitle:
            pack.primaryTitle = mergeText(pack.primaryTitle, raw)

        case .titleCandidates:
            let items = MarkdownParsingSupport.parseListItems(cleanedLines)
            pack.titleCandidates.append(contentsOf: items.isEmpty ? [raw] : items)

        case .thumbnailBrief:
            pack.thumbnailBrief = mergeText(pack.thumbnailBrief, raw)

        case .description:
            pack.description = mergeText(pack.description, raw)
            extractDescriptionExtras(cleanedLines, startLine: lineStart, pack: &pack)

        case .chapters:
            let parsed = parseChapterLines(cleanedLines)
            if !parsed.chapters.isEmpty {
                pack.chapters = mergeChapters(pack.chapters, parsed.chapters)
                pack.chaptersPlacement = .section
            }
            pack.chapterNotes.append(contentsOf: parsed.notes)

        case .tags:
            let parsed = parseTagList(raw)
            if parsed.hadDuplicates {
                warnings.append(
                    EscaletaWarning(
                        kind: .duplicateTag,
                        message: "Se eliminaron etiquetas duplicadas.",
                        line: lineStart
                    )
                )
            }
            pack.tags = mergeUnique(pack.tags, parsed.tags, caseInsensitive: true)

        case .hashtags:
            pack.hashtags = mergeUnique(pack.hashtags, parseHashtagList(raw), caseInsensitive: false)

        case .pinnedComment:
            pack.pinnedComment = mergeText(pack.pinnedComment, raw)

        case .communityPost:
            pack.communityPost = mergeText(pack.communityPost, raw)
        }
    }

    mutating func extractDescriptionExtras(
        _ fieldLines: [String],
        startLine: Int,
        pack: inout EscaletaPublishingPack
    ) {
        for line in fieldLines {
            if let chapter = MarkdownParsingSupport.chapter(line) {
                pack.chapters = mergeChapters(pack.chapters, [chapter])
                if pack.chaptersPlacement == .none {
                    pack.chaptersPlacement = .inlineDescription
                }
            }
        }

        var insideSources = false
        for (offset, line) in fieldLines.enumerated() {
            let normalized = MarkdownParsingSupport.normalizedHeading(line)
            if normalized.hasPrefix("fuentes oficiales y referencias") {
                insideSources = true
                continue
            }
            guard insideSources else { continue }
            if MarkdownParsingSupport.isBlank(line) || MarkdownParsingSupport.trimmed(line).hasPrefix("#") {
                insideSources = false
                continue
            }
            let entry = sourceEntry(
                from: line,
                origin: .descriptionTrailer,
                lineNumber: startLine + offset
            )
            if !entry.links.isEmpty {
                document.sources.append(entry)
                document.sourcesPlacement = .descriptionTrailer
            }
        }
    }

    // MARK: - Tables / verification / sources

    mutating func parseTableSection(_ node: MarkdownNode) {
        if document.tableSectionHeading == nil {
            document.tableSectionHeading = node.heading
        }
        let sectionLines = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))
        var notes: [String] = []
        var index = 0
        var tableCount = 0

        while index < sectionLines.count {
            let line = sectionLines[index]
            if MarkdownParsingSupport.isTableRow(line),
               let parsed = MarkdownParsingSupport.parseTable(
                   lines: sectionLines,
                   start: index,
                   heading: node.heading,
                   sceneIndex: nil
               ) {
                document.comparisonTables.append(parsed.table)
                tableCount += 1
                for message in parsed.rowWarnings {
                    warnings.append(
                        EscaletaWarning(
                            kind: .malformedTable,
                            message: message,
                            line: node.lineIndex + 2 + index
                        )
                    )
                }
                index = parsed.end
                continue
            }
            if !MarkdownParsingSupport.isBlank(line) {
                notes.append(line)
            }
            index += 1
        }

        if !notes.isEmpty {
            let text = MarkdownParsingSupport.trimmedBlock(notes)
            document.tableSectionNotes = mergeText(document.tableSectionNotes, text)
        }
        if tableCount == 0 {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» no contiene ninguna tabla válida.",
                    line: node.lineIndex + 1
                )
            )
        }
    }

    mutating func parseVerificationSection(_ node: MarkdownNode) {
        if document.verifyHeading == nil {
            document.verifyHeading = node.heading
        }
        let items = parseVerificationItems(
            MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange])),
            startLine: node.lineIndex + 2
        )
        if items.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» está vacía.",
                    line: node.lineIndex + 1
                )
            )
        }
        document.verificationItems.append(contentsOf: items)
    }

    mutating func parseSourcesSection(_ node: MarkdownNode) {
        if document.sourcesHeading == nil {
            document.sourcesHeading = node.heading
        }
        let entries = parseSourceEntries(
            MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange])),
            origin: .section,
            startLine: node.lineIndex + 2
        )
        if entries.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» no contiene fuentes.",
                    line: node.lineIndex + 1
                )
            )
        }
        document.sources.append(contentsOf: entries)
        document.sourcesPlacement = .seoSection
    }

    mutating func parseVerificationItems(
        _ fieldLines: [String],
        startLine: Int
    ) -> [EscaletaVerificationItem] {
        var items: [EscaletaVerificationItem] = []

        for (offset, line) in fieldLines.enumerated() {
            if MarkdownParsingSupport.isBlank(line) { continue }
            let absolute = startLine + offset

            if let item = MarkdownParsingSupport.listItem(line, lineNumber: absolute) {
                if let bold = MarkdownParsingSupport.boldLabel(item.text),
                   bold.colonInsideBold || item.text.contains("**:") {
                    items.append(
                        EscaletaVerificationItem(
                            label: bold.label,
                            text: bold.value,
                            colonInsideBold: bold.colonInsideBold,
                            line: absolute
                        )
                    )
                } else {
                    // Bold prose such as **Note** (parenthetical): text is not
                    // a label; keep the whole line so punctuation survives.
                    items.append(EscaletaVerificationItem(text: item.text, line: absolute))
                }
            } else if items.isEmpty {
                items.append(
                    EscaletaVerificationItem(text: MarkdownParsingSupport.trimmed(line), line: absolute)
                )
            } else {
                items[items.count - 1].text += "\n" + MarkdownParsingSupport.trimmed(line)
            }
        }

        return items
    }

    mutating func parseSourceEntries(
        _ fieldLines: [String],
        origin: EscaletaSourceOrigin,
        startLine: Int
    ) -> [EscaletaSourceEntry] {
        var entries: [EscaletaSourceEntry] = []
        for (offset, line) in fieldLines.enumerated() {
            if MarkdownParsingSupport.isBlank(line) { continue }
            entries.append(
                sourceEntry(from: line, origin: origin, lineNumber: startLine + offset)
            )
        }
        return entries
    }

    func sourceEntry(
        from line: String,
        origin: EscaletaSourceOrigin,
        lineNumber: Int
    ) -> EscaletaSourceEntry {
        let listed = MarkdownParsingSupport.listItem(line, lineNumber: lineNumber)
        let raw = listed?.text ?? MarkdownParsingSupport.trimmed(line)
        let bullet = listed != nil

        let markdownLinks = MarkdownParsingSupport.linkMatches(in: raw)
        let bare = MarkdownParsingSupport.bareURLs(in: raw)
        var links = markdownLinks

        if markdownLinks.isEmpty, bare.count == 1, let url = bare.first {
            links.append(
                EscaletaSourceLink(title: titlePrefix(in: raw, before: url), url: url)
            )
        } else {
            for url in bare {
                links.append(EscaletaSourceLink(title: nil, url: url))
            }
        }

        return EscaletaSourceEntry(
            raw: raw,
            bullet: bullet,
            links: links,
            origin: origin,
            line: lineNumber
        )
    }

    func titlePrefix(in raw: String, before url: String) -> String? {
        guard let range = raw.range(of: url) else { return nil }
        var prefix = MarkdownParsingSupport.trimmed(String(raw[raw.startIndex..<range.lowerBound]))
        while prefix.hasSuffix(":") || prefix.hasSuffix("·") || prefix.hasSuffix("-") {
            prefix.removeLast()
            prefix = MarkdownParsingSupport.trimmed(prefix)
        }
        return prefix.isEmpty ? nil : prefix
    }

    // MARK: - Shared helpers

    func sectionBody(_ node: MarkdownNode) -> String {
        MarkdownParsingSupport.strippingTrailingRule(Array(lines[node.contentRange])).body
    }

    mutating func warnEmptySection(_ node: MarkdownNode) {
        warnings.append(
            EscaletaWarning(
                kind: .emptySection,
                message: "La sección «\(node.heading)» está vacía.",
                line: node.lineIndex + 1
            )
        )
    }

    func mergeText(_ existing: String?, _ value: String) -> String {
        guard let existing, !existing.isEmpty else { return value }
        guard !value.isEmpty else { return existing }
        if existing.contains(value) { return existing }
        if value.contains(existing) { return value }
        return existing + "\n\n" + value
    }

    func mergeUnique(_ existing: [String], _ value: [String], caseInsensitive: Bool) -> [String] {
        var result = existing
        var seen = Set(existing.map { caseInsensitive ? $0.lowercased() : $0 })
        for item in value {
            let key = caseInsensitive ? item.lowercased() : item
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    func mergeChapters(_ existing: [EscaletaChapter], _ value: [EscaletaChapter]) -> [EscaletaChapter] {
        var result = existing
        var seen = Set(existing.map { "\($0.seconds)|\($0.title.lowercased())" })
        for chapter in value {
            let key = "\(chapter.seconds)|\(chapter.title.lowercased())"
            if seen.insert(key).inserted {
                result.append(chapter)
            }
        }
        return result
    }

    func parseChapterLines(_ fieldLines: [String]) -> (chapters: [EscaletaChapter], notes: [String]) {
        var chapters: [EscaletaChapter] = []
        var notes: [String] = []
        for line in fieldLines {
            if MarkdownParsingSupport.isBlank(line) { continue }
            if let chapter = MarkdownParsingSupport.chapter(line) {
                chapters.append(chapter)
            } else {
                notes.append(MarkdownParsingSupport.trimmed(line))
            }
        }
        return (chapters, notes)
    }

    func parseTagList(_ raw: String) -> (tags: [String], hadDuplicates: Bool) {
        let cleaned = raw.replacingOccurrences(of: "**", with: "")
        var tags: [String] = []
        var seen = Set<String>()
        var duplicates = false
        for piece in cleaned.split(separator: ",") {
            var tag = MarkdownParsingSupport.trimmed(String(piece))
            while tag.hasSuffix(".") || tag.hasSuffix(";") {
                tag.removeLast()
                tag = MarkdownParsingSupport.trimmed(tag)
            }
            guard !tag.isEmpty else { continue }
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                tags.append(tag)
            } else {
                duplicates = true
            }
        }
        return (tags, duplicates)
    }

    func parseHashtagList(_ raw: String) -> [String] {
        var hashtags: [String] = []
        var seen = Set<String>()
        for piece in raw.split(whereSeparator: { $0.isWhitespace }) {
            var tag = MarkdownParsingSupport.trimmed(String(piece))
            guard !tag.isEmpty else { continue }
            if !tag.hasPrefix("#") { tag = "#" + tag }
            if seen.insert(tag).inserted {
                hashtags.append(tag)
            }
        }
        return hashtags
    }

    // MARK: - Classification

    func isScriptHeading(_ normalized: String) -> Bool {
        (normalized.contains("guion") || normalized.contains("script")) && !normalized.contains("seo")
    }

    func isSEOHeading(_ normalized: String) -> Bool {
        normalized == "seo" || normalized.contains("paquete seo")
    }

    func isTableSection(_ normalized: String) -> Bool {
        normalized.contains("tabla comparativa")
    }

    func isVerificationSection(_ normalized: String) -> Bool {
        normalized == "verificar antes de grabar"
            || normalized == "pruebas recomendadas antes de grabar"
            || normalized.contains("verificar antes de grabar")
    }

    func isSourcesSection(_ normalized: String) -> Bool {
        normalized == "fuentes principales"
            || normalized == "fuentes oficiales y referencias"
    }

    func isAnnexHeading(_ node: MarkdownNode) -> Bool {
        let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
        return isTableSection(normalized)
            || isVerificationSection(normalized)
            || isSourcesSection(normalized)
            || isSEOHeading(normalized)
            || normalized.contains("concepto de miniatura")
    }

    func publishingField(for normalized: String) -> EscaletaPublishingField? {
        let value = normalized.hasSuffix(":") ? String(normalized.dropLast()) : normalized
        switch value {
        case "evidencia utilizada":
            return .evidence
        case "titulo recomendado", "titulo principal":
            return .primaryTitle
        case "variantes", "titulos (elige uno)", "titulos":
            return .titleCandidates
        case "concepto de miniatura", "miniatura":
            return .thumbnailBrief
        case "descripcion", "descripcion (borrador)":
            return .description
        case "capitulos":
            return .chapters
        case "etiquetas":
            return .tags
        case "hashtags":
            return .hashtags
        case "comentario fijado":
            return .pinnedComment
        case "texto para comunidad":
            return .communityPost
        default:
            return nil
        }
    }

    mutating func warnUnrecognizedSceneHeading(_ node: MarkdownNode) {
        let line = lines[node.lineIndex]
        let kind: EscaletaWarning.Kind = MarkdownParsingSupport.looksLikeEmptySceneTitle(line)
            ? .emptySceneTitle
            : .invalidTimestamp
        let message = kind == .emptySceneTitle
            ? "La escena de la línea \(node.lineIndex + 1) no tiene título."
            : "El encabezado «\(node.heading)» parece una escena pero no se pudo interpretar."
        warnings.append(
            EscaletaWarning(kind: kind, message: message, line: node.lineIndex + 1)
        )
    }

    mutating func appendUnparsed(_ node: MarkdownNode, placement: EscaletaUnparsedPlacement) {
        let body = unparsedBody(node)
        document.unparsedSections.append(
            EscaletaUnparsedSection(
                level: node.level,
                heading: node.heading,
                body: body,
                placement: placement,
                line: node.lineIndex + 1
            )
        )
        warnings.append(
            EscaletaWarning(
                kind: .unknownSection,
                message: "Sección no reconocida conservada: «\(node.heading)».",
                line: node.lineIndex + 1
            )
        )
    }

    func unparsedBody(_ node: MarkdownNode) -> String {
        let raw = Array(lines[node.contentRange])
        let stripped = MarkdownParsingSupport.strippingTrailingRule(raw)
        guard stripped.hadRule,
              node.contentRange.upperBound < lines.count,
              let next = MarkdownParsingSupport.heading(lines[node.contentRange.upperBound]) else {
            return MarkdownParsingSupport.trimmedBlock(raw)
        }

        let normalized = MarkdownParsingSupport.normalizedHeading(next.text)
        let nextIsKnown: Bool
        if next.level == 1 {
            // Top-level H1 annexes are not parsed as verification/sources
            // sections; only script and SEO have canonical separators.
            nextIsKnown = isScriptHeading(normalized) || isSEOHeading(normalized)
        } else {
            nextIsKnown = isTableSection(normalized)
                || isVerificationSection(normalized)
                || isSourcesSection(normalized)
                || isSEOHeading(normalized)
        }
        // A rule immediately before a known section belongs to that section's
        // canonical separator; keeping it in an unknown body would duplicate it.
        return nextIsKnown ? stripped.body : MarkdownParsingSupport.trimmedBlock(raw)
    }

    func isThumbnailDocument(tree: [MarkdownNode]) -> Bool {
        let normalizedTitle = MarkdownParsingSupport.normalizedHeading(document.title)
        if normalizedTitle.contains("conceptos de miniatura") {
            return true
        }
        let conceptCount = flatten(tree).filter {
            MarkdownParsingSupport.thumbnailConceptHeading($0.heading) != nil
        }.count
        return conceptCount >= 2
    }

    func flatten(_ nodes: [MarkdownNode]) -> [MarkdownNode] {
        nodes.reduce(into: []) { result, node in
            result.append(node)
            result.append(contentsOf: flatten(node.children))
        }
    }

    func detectKind() -> EscaletaDocumentKind {
        if document.thumbnailConcepts != nil {
            return .thumbnailConcepts
        }
        if document.scriptHeading != nil
            || document.outlineHeading != nil
            || document.publishing != nil
            || sawTimestampScene {
            return .escaleta
        }
        for section in document.unparsedSections where section.level == 1 {
            let heading = section.heading.trimmingCharacters(in: .whitespaces)
            if let first = heading.first, first.isNumber, heading.contains(".") {
                return .researchDossier
            }
        }
        return .other
    }

    func lineNumber(ofHeading heading: String) -> Int? {
        lines.firstIndex { line in
            MarkdownParsingSupport.heading(line)?.text == heading
        }.map { $0 + 1 }
    }

    mutating func validate() {
        if document.title.isEmpty {
            warnings.append(
                EscaletaWarning(kind: .missingTitle, message: "El documento no tiene título.")
            )
        }

        if document.scenes.isEmpty, document.outline.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .noScenes,
                    message: "No se encontraron escenas ni una escaleta de respaldo."
                )
            )
        }

        if let publishing = document.publishing {
            let seoLine = document.seoHeading.flatMap(lineNumber(ofHeading:))
            if publishing.primaryTitle == nil, publishing.titleCandidates.isEmpty {
                warnings.append(
                    EscaletaWarning(
                        kind: .seoMissingTitle,
                        message: "El bloque SEO no tiene título principal ni variantes.",
                        line: seoLine
                    )
                )
            }
            if publishing.description == nil || publishing.description?.isEmpty == true {
                warnings.append(
                    EscaletaWarning(
                        kind: .seoMissingDescription,
                        message: "El bloque SEO no tiene descripción.",
                        line: seoLine
                    )
                )
            }
        }
    }

    func result() -> EscaletaImportResult {
        EscaletaImportResult(document: document, warnings: warnings)
    }
}
