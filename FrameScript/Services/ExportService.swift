import Foundation
import FrameScriptCore
import UniformTypeIdentifiers

protocol ExportServicing {
    func render(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String
    func render(project: FrameProject, format: ExportFormat, preferences: ExportPreferences, language: AppLanguage) -> String
}

struct ExportService: ExportServicing {
    func render(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String {
        render(project: project, format: preferences.defaultFormat, preferences: preferences, language: language)
    }

    func render(project: FrameProject, format: ExportFormat, preferences: ExportPreferences, language: AppLanguage) -> String {
        switch format {
        case .plainText:
            renderPlainText(project: project, preferences: preferences, language: language)
        case .markdown:
            renderMarkdown(project: project, preferences: preferences, language: language)
        case .productionOutline:
            renderProductionOutline(project: project, preferences: preferences, language: language)
        case .csv:
            renderCSV(project: project, preferences: preferences, language: language)
        }
    }

    private func renderPlainText(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String {
        project.scenes.sortedByOrder.map { scene in
            var output = ""
            if preferences.includeSectionNames {
                let timestamp = preferences.includeTimestamps ? " [\(DurationEstimator.formatted(scene.estimatedDuration))]" : ""
                output += "\(scene.title)\(timestamp)\n\n"
            }
            output += formattedScript(scene.scriptText, preferences: preferences)

            if preferences.includeBRoll, !scene.bRollItems.isEmpty {
                output += "\n\n\(label("export.label.broll", language: language)):\n"
                for item in scene.bRollItems {
                    output += "- \(label("brollSource.\(item.sourceType.rawValue)", language: language)): \(item.descriptionText)\n"
                }
            }

            if preferences.includeEditingNotes, !scene.editingItems.isEmpty {
                output += "\n\n\(label("export.label.editing", language: language)):\n"
                for item in scene.editingItems {
                    if !item.cutStyle.isEmpty { output += "- \(item.cutStyle)\n" }
                    if !item.notes.isEmpty { output += "  \(label("export.label.notes", language: language)): \(item.notes)\n" }
                }
            }

            if preferences.includeAINotes, !scene.aiComments.isEmpty {
                output += "\n\n\(label("export.label.aiNotes", language: language)):\n"
                for comment in scene.aiComments where comment.status == .new {
                    output += "- \(comment.message)"
                    if !comment.suggestion.isEmpty {
                        output += " \(label("export.label.suggestion", language: language)): \(comment.suggestion)"
                    }
                    output += "\n"
                }
            }
            return output
        }
        .joined(separator: "\n\n")
    }

    private func renderMarkdown(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String {
        var output = "# \(project.title)\n\n"
        for scene in project.scenes.sortedByOrder {
            if preferences.includeSectionNames {
                let timestamp = preferences.includeTimestamps ? " [\(DurationEstimator.formatted(scene.estimatedDuration))]" : ""
                output += "## \(scene.title)\(timestamp)\n\n"
            }
            output += "\(formattedScript(scene.scriptText, preferences: preferences))\n\n"

            output += renderSegmentProduction(scene: scene, preferences: preferences, language: language, headingPrefix: "### ")

            if preferences.includeAINotes, !scene.aiComments.isEmpty {
                output += "### \(label("export.label.aiNotes", language: language))\n"
                for comment in scene.aiComments where comment.status == .new {
                    output += "- \(comment.message)"
                    if !comment.suggestion.isEmpty {
                        output += " \(label("export.label.suggestion", language: language)): \(comment.suggestion)"
                    }
                    output += "\n"
                }
                output += "\n"
            }
        }
        return output
    }

    private func renderProductionOutline(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String {
        var output = "# \(project.title)\n\n"
        for (index, scene) in project.scenes.sortedByOrder.enumerated() {
            let sceneTitle = preferences.includeSectionNames ? scene.title : label("export.label.scene", language: language)
            output += "## \(label("export.label.scene", language: language)) \(String(format: "%02d", index + 1)) — \(sceneTitle)\n"
            if preferences.includeTimestamps {
                output += "\(label("export.label.estimatedDuration", language: language)): \(DurationEstimator.formatted(scene.estimatedDuration))\n\n"
            } else {
                output += "\n"
            }

            output += "\(label("export.label.script", language: language).uppercased()):\n"
            output += "\(formattedScript(scene.scriptText, preferences: preferences))\n\n"

            output += renderSegmentProduction(scene: scene, preferences: preferences, language: language, headingPrefix: "### ")

            if preferences.includeAINotes, !scene.aiComments.isEmpty {
                output += "\(label("export.label.aiNotes", language: language).uppercased()):\n"
                for comment in scene.aiComments where comment.status == .new {
                    output += "- \(comment.message)\n"
                    appendLine(&output, key: "export.label.suggestion", value: comment.suggestion, language: language, indent: "  ")
                }
                output += "\n"
            }
        }
        return output
    }

    private func renderCSV(project: FrameProject, preferences: ExportPreferences, language: AppLanguage) -> String {
        let headers = ["export.csv.sceneOrder", "export.label.title", "export.csv.segmentOrder", "export.csv.segmentText", "export.csv.itemType", "export.label.source", "export.label.description", "export.label.notes"].map { label($0, language: language) }
        var rows = [headers.map(csvEscape).joined(separator: ",")]
        for scene in project.scenes.sortedByOrder {
            let segments = scene.textSegments.sortedByOrder
            for segment in segments {
                if preferences.includeBRoll {
                    for item in scene.bRollItems where isLinked(item.textAnchor, to: segment, in: scene) {
                        rows.append(csvRow(scene: scene, segment: segment, type: label("export.label.broll", language: language), source: label("brollSource.\(item.sourceType.rawValue)", language: language), description: item.descriptionText, notes: item.notes))
                    }
                }
                if preferences.includeEditingNotes {
                    for item in scene.editingItems where isLinked(item.textAnchor, to: segment, in: scene) {
                        rows.append(csvRow(scene: scene, segment: segment, type: label("export.label.editing", language: language), source: "", description: item.cutStyle, notes: item.notes))
                    }
                }
            }
            if preferences.includeBRoll {
                for item in scene.bRollItems where item.textAnchor == nil {
                    rows.append(csvRow(scene: scene, segment: nil, type: label("export.label.broll", language: language), source: label("brollSource.\(item.sourceType.rawValue)", language: language), description: item.descriptionText, notes: item.notes))
                }
            }
            if preferences.includeEditingNotes {
                for item in scene.editingItems where item.textAnchor == nil {
                    rows.append(csvRow(scene: scene, segment: nil, type: label("export.label.editing", language: language), source: "", description: item.cutStyle, notes: item.notes))
                }
            }
        }
        return rows.joined(separator: "\n")
    }

    private func renderSegmentProduction(scene: Scene, preferences: ExportPreferences, language: AppLanguage, headingPrefix: String) -> String {
        let segments = scene.textSegments.sortedByOrder
        var output = ""
        for segment in segments {
            let bRoll = preferences.includeBRoll ? scene.bRollItems.filter { isLinked($0.textAnchor, to: segment, in: scene) } : []
            let editing = preferences.includeEditingNotes ? scene.editingItems.filter { isLinked($0.textAnchor, to: segment, in: scene) } : []
            guard !bRoll.isEmpty || !editing.isEmpty else { continue }
            output += "\(headingPrefix)\(label("export.csv.segmentText", language: language)): \(segmentPreview(segment.sourceText))\n"
            appendProductionItems(&output, bRoll: bRoll, editing: editing, language: language)
            output += "\n"
        }
        let unlinkedBRoll = preferences.includeBRoll ? scene.bRollItems.filter { $0.textAnchor == nil } : []
        let unlinkedEditing = preferences.includeEditingNotes ? scene.editingItems.filter { $0.textAnchor == nil } : []
        if !unlinkedBRoll.isEmpty || !unlinkedEditing.isEmpty {
            output += "\(headingPrefix)\(label("production.unlinked", language: language))\n"
            appendProductionItems(&output, bRoll: unlinkedBRoll, editing: unlinkedEditing, language: language)
            output += "\n"
        }
        return output
    }

    private func isLinked(_ anchor: TextAnchor?, to segment: TextSegment, in scene: Scene) -> Bool {
        guard let anchor else { return false }
        return TextAnchorRepair.isAnchor(anchor, in: segment, text: scene.scriptText)
    }

    private func appendProductionItems(_ output: inout String, bRoll: [BRollItem], editing: [EditingItem], language: AppLanguage) {
        for item in bRoll {
            output += "- **\(label("export.label.broll", language: language))**\n"
            appendLine(&output, key: "export.label.source", value: label("brollSource.\(item.sourceType.rawValue)", language: language), language: language, indent: "  ")
            appendLine(&output, key: "export.label.description", value: item.descriptionText, language: language, indent: "  ")
            appendLine(&output, key: "export.label.notes", value: item.notes, language: language, indent: "  ")
        }
        for item in editing {
            output += "- **\(label("export.label.editing", language: language))**\n"
            appendLine(&output, key: "export.label.description", value: item.cutStyle, language: language, indent: "  ")
            appendLine(&output, key: "export.label.notes", value: item.notes, language: language, indent: "  ")
        }
    }

    private func csvRow(scene: Scene, segment: TextSegment?, type: String, source: String, description: String, notes: String) -> String {
        ["\(scene.order + 1)", scene.title, segment.map { "\($0.order + 1)" } ?? "", segment?.sourceText ?? "", type, source, description, notes].map(csvEscape).joined(separator: ",")
    }

    private func segmentPreview(_ text: String) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return clean.count > 100 ? "\(clean.prefix(100))…" : clean
    }

    private func formattedScript(_ text: String, preferences: ExportPreferences) -> String {
        // F4: "sin marcas" removes pauses, cues, emphasis delimiters and
        // escapes. Markdown keeps the markers unless the export asks for the
        // clean variant, so a round trip through Markdown stays lossless.
        let source = preferences.cleanMarkup ? ScriptMarkup.spokenText(text) : text
        return preferences.teleprompterFormatting ? source.replacingOccurrences(of: ". ", with: ".\n\n") : source
    }

    private func appendLine(_ output: inout String, key: String, value: String, language: AppLanguage, indent: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        output += "\(indent)\(label(key, language: language)): \(value)\n"
    }

    private func label(_ key: String, language: AppLanguage) -> String {
        L10n.tr(key, language: language)
    }

    private func csvEscape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

extension ExportFormat {
    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .markdown, .productionOutline: "md"
        case .csv: "csv"
        }
    }

    var contentType: UTType {
        switch self {
        case .plainText: .plainText
        case .markdown, .productionOutline: UTType(filenameExtension: "md") ?? .plainText
        case .csv: UTType(filenameExtension: "csv") ?? .commaSeparatedText
        }
    }
}
