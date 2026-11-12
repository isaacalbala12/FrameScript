import Foundation

struct ThumbnailParseResult {
    var document: ThumbnailConceptsDocument
    var warnings: [EscaletaWarning]
}

/// Parser for the `Conceptos de miniatura` file format (§3.6).
struct ThumbnailConceptsParser {
    let lines: [String]
    let tree: [MarkdownNode]
    let titleNode: MarkdownNode

    private var warnings: [EscaletaWarning] = []
    private var document = ThumbnailConceptsDocument()

    init(lines: [String], tree: [MarkdownNode], titleNode: MarkdownNode) {
        self.lines = lines
        self.tree = tree
        self.titleNode = titleNode
    }

    mutating func parse() -> ThumbnailParseResult {
        parseIntro()

        for node in tree where node.lineIndex != titleNode.lineIndex {
            guard node.level == 1 else {
                document.unparsedSections.append(unparsed(node, placement: .document))
                continue
            }

            let normalized = MarkdownParsingSupport.normalizedHeading(node.heading)
            if normalized.contains("jerarquia visual comun") {
                parseSharedRules(node)
            } else {
                document.groups.append(parseGroup(node))
            }
        }

        // A file without group H1s but with concept H2s under the title still
        // gets a single anonymous group, so nothing is lost.
        if document.groups.isEmpty {
            let conceptChildren = titleNode.children.filter {
                MarkdownParsingSupport.thumbnailConceptHeading($0.heading) != nil
            }
            if !conceptChildren.isEmpty {
                document.groups.append(parseGroup(titleNode, anonymous: true))
            }
        }

        return ThumbnailParseResult(document: document, warnings: warnings)
    }

    // MARK: - Intro

    private mutating func parseIntro() {
        let preamble = Array(lines[titleNode.preambleRange()])
        let stripped = MarkdownParsingSupport.strippingTrailingRule(preamble)
        document.intro = stripped.body.isEmpty ? nil : stripped.body
        document.separatorAfterIntro = stripped.hadRule
    }

    // MARK: - Groups

    private mutating func parseGroup(_ node: MarkdownNode, anonymous: Bool = false) -> ThumbnailGroup {
        var group = ThumbnailGroup(title: anonymous ? "" : node.heading)

        if !anonymous {
            let preamble = Array(lines[node.preambleRange()])
            let stripped = MarkdownParsingSupport.strippingTrailingRule(preamble)
            var preambleLines: [String] = []

            for line in stripped.body.components(separatedBy: "\n") {
                if let reference = referenceTitle(from: line) {
                    group.referenceTitle = reference
                } else if !MarkdownParsingSupport.isBlank(line) {
                    preambleLines.append(line)
                }
            }
            if !preambleLines.isEmpty {
                group.preamble = MarkdownParsingSupport.trimmedBlock(preambleLines)
            }
        }

        group.separatorAfter = anonymous ? false : hasTrailingRule(Array(lines[node.contentRange]))

        for child in node.children {
            if let conceptHeading = MarkdownParsingSupport.thumbnailConceptHeading(child.heading) {
                group.concepts.append(
                    parseConcept(child, heading: conceptHeading)
                )
            } else {
                let normalized = MarkdownParsingSupport.normalizedHeading(child.heading)
                if normalized.contains("prueba a/b") || normalized.contains("prueba ab") {
                    parseABTest(child, into: &group)
                } else {
                    group.unparsedSections.append(unparsed(child, placement: .thumbnailGroup))
                    warnings.append(
                        EscaletaWarning(
                            kind: .unknownSection,
                            message: "Sección no reconocida conservada en el grupo de miniaturas: «\(child.heading)».",
                            line: child.lineIndex + 1
                        )
                    )
                }
            }
        }

        if group.concepts.isEmpty, group.abTestItems.isEmpty, group.preamble == nil, group.referenceTitle == nil {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "El grupo de miniaturas «\(node.heading)» está vacío.",
                    line: node.lineIndex + 1
                )
            )
        }

        return group
    }

    private func referenceTitle(from line: String) -> String? {
        let normalized = MarkdownParsingSupport.normalizedHeading(line)
        guard normalized.hasPrefix("titulo de referencia") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var value = String(line[line.index(after: colon)...])
        value = value.replacingOccurrences(of: "**", with: "")
        value = MarkdownParsingSupport.trimmed(value)
        return value.isEmpty ? nil : value
    }

    private mutating func parseConcept(
        _ node: MarkdownNode,
        heading: (label: String, text: String, recommended: Bool)
    ) -> ThumbnailConcept {
        let body = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))

        enum CurrentField { case none, idea, why }
        var current: CurrentField = .none
        var idea: String?
        var why: String?
        var composition: [String] = []
        var extraLines: [String] = []

        for line in body {
            if MarkdownParsingSupport.isBlank(line) {
                current = .none
                continue
            }

            if let bold = MarkdownParsingSupport.boldLabel(line) {
                let key = MarkdownParsingSupport.normalizedHeading(bold.label)
                if key == "idea" {
                    current = .idea
                    if !bold.value.isEmpty {
                        idea = merge(idea, bold.value)
                    }
                } else if key == "por que funciona" {
                    current = .why
                    if !bold.value.isEmpty {
                        why = merge(why, bold.value)
                    }
                } else {
                    current = .none
                    extraLines.append(line)
                }
                continue
            }

            if let item = MarkdownParsingSupport.listItem(line, lineNumber: node.lineIndex + 1) {
                composition.append(item.text)
                current = .none
                continue
            }

            switch current {
            case .idea:
                idea = merge(idea, MarkdownParsingSupport.trimmed(line))
            case .why:
                why = merge(why, MarkdownParsingSupport.trimmed(line))
            case .none:
                extraLines.append(line)
            }
        }

        let extra = MarkdownParsingSupport.trimmedBlock(extraLines)
        if MarkdownParsingSupport.wordCount(heading.text) > 3 {
            warnings.append(
                EscaletaWarning(
                    kind: .thumbnailTextLength,
                    message: "El texto de la miniatura «\(heading.text)» tiene más de 3 palabras.",
                    line: node.lineIndex + 1
                )
            )
        }
        if heading.text.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "El concepto \(heading.label) no tiene texto de miniatura.",
                    line: node.lineIndex + 1
                )
            )
        }

        return ThumbnailConcept(
            label: heading.label,
            text: heading.text,
            recommended: heading.recommended,
            idea: idea,
            composition: composition,
            whyItWorks: why,
            extraText: extra.isEmpty ? nil : extra,
            line: node.lineIndex + 1
        )
    }

    private mutating func parseABTest(_ node: MarkdownNode, into group: inout ThumbnailGroup) {
        group.abTestHeading = node.heading
        let body = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))

        var noteLines: [String] = []
        for line in body {
            if MarkdownParsingSupport.isBlank(line) { continue }
            if let item = MarkdownParsingSupport.listItem(line, lineNumber: node.lineIndex + 1) {
                group.abTestItems.append(item.text)
            } else {
                noteLines.append(line)
            }
        }
        let note = MarkdownParsingSupport.trimmedBlock(noteLines)
        if !note.isEmpty {
            group.abTestNote = note
        }
    }

    private mutating func parseSharedRules(_ node: MarkdownNode) {
        document.sharedRulesHeading = node.heading
        let body = MarkdownParsingSupport.linesWithoutTrailingRule(Array(lines[node.contentRange]))
        var notes: [String] = []
        for line in body {
            if let item = MarkdownParsingSupport.listItem(line, lineNumber: node.lineIndex + 1) {
                document.sharedRules.append(item.text)
            } else if !MarkdownParsingSupport.isBlank(line) {
                notes.append(line)
            }
        }
        let noteText = MarkdownParsingSupport.trimmedBlock(notes)
        if !noteText.isEmpty {
            document.sharedRulesNotes = noteText
        }
        if document.sharedRules.isEmpty {
            warnings.append(
                EscaletaWarning(
                    kind: .emptySection,
                    message: "La sección «\(node.heading)» está vacía.",
                    line: node.lineIndex + 1
                )
            )
        }
    }

    // MARK: - Helpers

    private func hasTrailingRule(_ content: [String]) -> Bool {
        var end = content.count
        while end > 0, MarkdownParsingSupport.isBlank(content[end - 1]) { end -= 1 }
        return end > 0 && MarkdownParsingSupport.isHorizontalRule(content[end - 1])
    }

    private func unparsed(
        _ node: MarkdownNode,
        placement: EscaletaUnparsedPlacement
    ) -> EscaletaUnparsedSection {
        EscaletaUnparsedSection(
            level: node.level,
            heading: node.heading,
            body: MarkdownParsingSupport.trimmedBlock(Array(lines[node.contentRange])),
            placement: placement,
            line: node.lineIndex + 1
        )
    }

    private func merge(_ existing: String?, _ value: String) -> String {
        guard let existing, !existing.isEmpty else { return value }
        guard !value.isEmpty else { return existing }
        return existing + "\n" + value
    }
}
