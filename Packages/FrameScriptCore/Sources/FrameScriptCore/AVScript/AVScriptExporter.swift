import Foundation

/// Localized column and field labels for AV script exports. The defaults are
/// Spanish because FrameScript's production vocabulary is Spanish-first; the
/// app passes the active interface language instead.
public struct AVScriptExportLabels: Sendable, Hashable {
    public var documentTitle: String
    public var narration: String
    public var annotations: String
    public var scene: String
    public var unanchored: String
    public var bRoll: String
    public var editing: String
    public var source: String
    public var status: String
    public var empty: String
    public var notAnchored: String

    public var csvScene: String
    public var csvParagraph: String
    public var csvNarration: String
    public var csvType: String
    public var csvDescription: String
    public var csvSource: String
    public var csvStatus: String
    public var csvAnchor: String

    public init(
        documentTitle: String = "Guion AV",
        narration: String = "Narración",
        annotations: String = "Visuales y montaje",
        scene: String = "Escena",
        unanchored: String = "Sin anclar",
        bRoll: String = "Visual",
        editing: String = "Montaje",
        source: String = "Fuente",
        status: String = "Estado",
        empty: String = "Sin escenas.",
        notAnchored: String = "sin anclar",
        csvScene: String = "Escena",
        csvParagraph: String = "Parrafo",
        csvNarration: String = "Narracion",
        csvType: String = "Tipo",
        csvDescription: String = "Descripcion",
        csvSource: String = "Fuente",
        csvStatus: String = "Estado",
        csvAnchor: String = "Anclaje"
    ) {
        self.documentTitle = documentTitle
        self.narration = narration
        self.annotations = annotations
        self.scene = scene
        self.unanchored = unanchored
        self.bRoll = bRoll
        self.editing = editing
        self.source = source
        self.status = status
        self.empty = empty
        self.notAnchored = notAnchored
        self.csvScene = csvScene
        self.csvParagraph = csvParagraph
        self.csvNarration = csvNarration
        self.csvType = csvType
        self.csvDescription = csvDescription
        self.csvSource = csvSource
        self.csvStatus = csvStatus
        self.csvAnchor = csvAnchor
    }
}

/// Renders an ``AVScriptDocument`` as a two-column Markdown table or as a
/// structured CSV (one row per paragraph or annotation).
public enum AVScriptExporter {
    // MARK: Markdown

    public static func markdown(document: AVScriptDocument, labels: AVScriptExportLabels = AVScriptExportLabels()) -> String {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = title.isEmpty ? "FrameScript" : title

        var lines: [String] = [
            "# \(markdownCell(labels.documentTitle)) — \(markdownCell(displayTitle))",
            "",
            "| \(markdownCell(labels.narration)) | \(markdownCell(labels.annotations)) |",
            "| --- | --- |",
        ]

        guard !document.scenes.isEmpty else {
            lines.append("| \(markdownCell(labels.empty)) | |")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for (index, scene) in document.scenes.enumerated() {
            let number = String(format: "%02d", index + 1)
            lines.append(tableRow(
                "**\(markdownCell(labels.scene)) \(number) — \(markdownCell(scene.title))**",
                ""
            ))

            for row in scene.rows {
                let narration = row.paragraph.map { markdownCell($0.text) } ?? "*\(markdownCell(labels.unanchored))*"
                let annotations = row.annotations
                    .map { markdownAnnotationLine($0, labels: labels, showsExcerpt: row.isUnanchored) }
                    .joined(separator: "<br>")
                lines.append(tableRow(narration, annotations))
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func markdownAnnotationLine(
        _ annotation: AVScriptAnnotation,
        labels: AVScriptExportLabels,
        showsExcerpt: Bool
    ) -> String {
        let kind = markdownCell(annotation.kind == .bRoll ? labels.bRoll : labels.editing)
        var line = "**\(kind)**"
        let text = markdownCell(annotation.text.trimmingCharacters(in: .whitespacesAndNewlines))
        if !text.isEmpty {
            line += " — \(text)"
        }
        let source = markdownCell(annotation.source.trimmingCharacters(in: .whitespacesAndNewlines))
        if !source.isEmpty {
            line += " · \(markdownCell(labels.source)): \(source)"
        }
        let status = markdownCell(annotation.status.trimmingCharacters(in: .whitespacesAndNewlines))
        if !status.isEmpty {
            line += " · \(markdownCell(labels.status)): \(status)"
        }
        if showsExcerpt {
            let excerpt = markdownCell(annotation.anchorExcerpt.trimmingCharacters(in: .whitespacesAndNewlines))
            if !excerpt.isEmpty {
                line += " · «\(excerpt)»"
            }
        }
        return line
    }

    private static func tableRow(_ left: String, _ right: String) -> String {
        right.isEmpty ? "| \(left) | |" : "| \(left) | \(right) |"
    }

    /// Escapes a value for a GFM table cell: HTML is neutralised, pipes are
    /// escaped and line breaks become `<br>` so one row stays one line.
    public static func markdownCell(_ value: String) -> String {
        var text = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "&", with: "&amp;")
        text = text.replacingOccurrences(of: "<", with: "&lt;")
        text = text.replacingOccurrences(of: ">", with: "&gt;")
        text = text.replacingOccurrences(of: "|", with: "\\|")
        text = text.replacingOccurrences(of: "\n", with: "<br>")
        return text
    }

    // MARK: CSV

    public static func csv(
        document: AVScriptDocument,
        labels: AVScriptExportLabels = AVScriptExportLabels(),
        escapeFormulas: Bool = false,
        includesBOM: Bool = false
    ) -> String {
        let header = [
            labels.csvScene,
            labels.csvParagraph,
            labels.csvNarration,
            labels.csvType,
            labels.csvDescription,
            labels.csvSource,
            labels.csvStatus,
            labels.csvAnchor,
        ]
        var rows: [String] = [
            header
                .map { ShotListCSV.escape($0, escapeFormulas: escapeFormulas) }
                .joined(separator: ",")
        ]

        for scene in document.scenes {
            for row in scene.rows {
                let paragraphNumber = row.paragraph.map { String($0.index + 1) } ?? ""
                let narration = row.paragraph?.text ?? ""
                let anchor = row.isUnanchored
                    ? labels.notAnchored
                    : ""

                if row.annotations.isEmpty {
                    rows.append(csvRow(
                        scene: scene.title,
                        paragraph: paragraphNumber,
                        narration: narration,
                        type: "",
                        description: "",
                        source: "",
                        status: "",
                        anchor: anchor,
                        escapeFormulas: escapeFormulas
                    ))
                    continue
                }

                for annotation in row.annotations {
                    let kind = annotation.kind == .bRoll ? labels.bRoll : labels.editing
                    var anchorValue = anchor
                    if row.isUnanchored, !annotation.anchorExcerpt.isEmpty {
                        anchorValue += ": \(annotation.anchorExcerpt)"
                    }
                    rows.append(csvRow(
                        scene: scene.title,
                        paragraph: paragraphNumber,
                        narration: narration,
                        type: kind,
                        description: annotation.text,
                        source: annotation.source,
                        status: annotation.status,
                        anchor: anchorValue,
                        escapeFormulas: escapeFormulas
                    ))
                }
            }
        }

        let csv = rows.joined(separator: "\r\n") + "\r\n"
        // The header carries Spanish accents, so Excel needs the BOM to pick
        // UTF-8 instead of the legacy code page.
        return includesBOM ? "\u{FEFF}" + csv : csv
    }

    private static func csvRow(
        scene: String,
        paragraph: String,
        narration: String,
        type: String,
        description: String,
        source: String,
        status: String,
        anchor: String,
        escapeFormulas: Bool
    ) -> String {
        [
            scene,
            paragraph,
            narration,
            type,
            description,
            source,
            status,
            anchor,
        ]
        .map { ShotListCSV.escape($0, escapeFormulas: escapeFormulas) }
        .joined(separator: ",")
    }
}
