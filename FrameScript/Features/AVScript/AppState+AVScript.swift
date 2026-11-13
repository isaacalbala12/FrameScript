import AppKit
import Foundation
import FrameScriptCore
import UniformTypeIdentifiers

/// File formats offered by the AV script export.
enum AVScriptExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case csv

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .csv: "csv"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .csv: UTType(filenameExtension: "csv") ?? .commaSeparatedText
        }
    }
}

@MainActor
extension AppState {
    /// The current project as an AV script, with every visual and editing note
    /// paired to the paragraph that contains its anchor.
    func avScriptDocument() -> AVScriptDocument {
        AVScriptBuilder.document(
            title: project.title,
            scenes: project.scenes.sortedByOrder.map(avScriptSceneInput)
        )
    }

    func avScriptScene(_ scene: Scene) -> AVScriptScene {
        AVScriptBuilder.scene(avScriptSceneInput(scene))
    }

    private func avScriptSceneInput(_ scene: Scene) -> AVScriptSceneInput {
        AVScriptSceneInput(
            id: scene.id,
            title: scene.title,
            scriptText: scene.scriptText,
            annotations: avScriptAnnotations(for: scene)
        )
    }

    /// Replaces one paragraph in the scene and runs the same commit path as the
    /// script editor, so undo, autosave, metrics, rhythm and anchor repair keep
    /// working. The range and previous text guard against a stale row.
    func commitAVParagraph(
        sceneID: UUID,
        paragraphRange: NSRange,
        previousText: String,
        text: String
    ) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        let source = scene.scriptText as NSString
        guard paragraphRange.location >= 0,
              paragraphRange.length >= 0,
              paragraphRange.location <= source.length,
              paragraphRange.length <= source.length - paragraphRange.location,
              source.substring(with: paragraphRange) == previousText else {
            return
        }
        let updated = source.replacingCharacters(in: paragraphRange, with: text)
        guard updated != scene.scriptText else { return }
        commitScriptTextChange(sceneID: sceneID, previousText: scene.scriptText, text: updated)
    }

    func avScriptExportLabels() -> AVScriptExportLabels {
        AVScriptExportLabels(
            documentTitle: localized("avScript.export.documentTitle"),
            narration: localized("avScript.export.narration"),
            annotations: localized("avScript.export.annotations"),
            scene: localized("avScript.export.scene"),
            unanchored: localized("avScript.export.unanchored"),
            bRoll: localized("avScript.export.broll"),
            editing: localized("avScript.export.editing"),
            source: localized("avScript.export.source"),
            status: localized("avScript.export.status"),
            empty: localized("avScript.export.empty"),
            notAnchored: localized("avScript.export.notAnchored"),
            csvScene: localized("avScript.export.scene"),
            csvParagraph: localized("avScript.export.paragraphHeader"),
            csvNarration: localized("avScript.export.narration"),
            csvType: localized("avScript.export.typeHeader"),
            csvDescription: localized("avScript.export.descriptionHeader"),
            csvSource: localized("avScript.export.source"),
            csvStatus: localized("avScript.export.status"),
            csvAnchor: localized("avScript.export.anchorHeader")
        )
    }

    /// Renders the AV script without touching the filesystem. Exposed so tests
    /// and future CLI commands use the exact same labels as the save panel.
    func avScriptExportText(format: AVScriptExportFormat) -> String {
        let document = avScriptDocument()
        let labels = avScriptExportLabels()
        switch format {
        case .markdown:
            return AVScriptExporter.markdown(document: document, labels: labels)
        case .csv:
            return AVScriptExporter.csv(document: document, labels: labels)
        }
    }

    /// Adds a visual (`bRoll`) or editing note anchored to the whole paragraph.
    /// Returns the new item id so a caller can reveal or focus it.
    @discardableResult
    func addAVAnnotation(
        sceneID: UUID,
        paragraphRange: NSRange,
        kind: AVScriptAnnotationKind
    ) -> UUID? {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }),
              let anchor = TextAnchorRepair.anchor(in: scene.scriptText, range: paragraphRange) else {
            return nil
        }

        let itemID = UUID()
        switch kind {
        case .bRoll:
            scene.bRollItems.append(
                BRollItem(
                    id: itemID,
                    textAnchor: anchor,
                    linkedSegmentID: nil,
                    templateType: "",
                    sourceType: .custom,
                    descriptionText: ""
                )
            )
        case .editing:
            scene.editingItems.append(
                EditingItem(
                    id: itemID,
                    textAnchor: anchor,
                    linkedSegmentID: nil,
                    templateType: "",
                    cutStyle: "",
                    transition: "",
                    subtitleStyle: ""
                )
            )
        }
        touchProject()
        scheduleRhythmReview(for: scene)
        return itemID
    }

    func deleteAVAnnotation(sceneID: UUID, itemID: UUID) {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }
        let before = scene.bRollItems.count + scene.editingItems.count
        scene.bRollItems.removeAll { $0.id == itemID }
        scene.editingItems.removeAll { $0.id == itemID }
        let after = scene.bRollItems.count + scene.editingItems.count
        guard after != before else { return }
        normalizeProductionSelection()
        touchProject()
        scheduleRhythmReview(for: scene)
    }

    func exportAVScript(format: AVScriptExportFormat) {
        guard hasOpenProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(avScriptSafeFileName(project.title))-av.\(format.fileExtension)"
        panel.message = localized("avScript.exportPanelMessage")
        if let folder = resolvedDefaultExportFolder() {
            let didStartAccessing = folder.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try avScriptExportText(format: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorCenter.present(
                AppError(
                    kind: .export,
                    context: AppErrorContext(
                        fileName: url.lastPathComponent,
                        diagnosticCode: "av-script-export-write"
                    ),
                    recoveryAction: .chooseExportFolder
                )
            )
        }
    }

    private func avScriptAnnotations(for scene: Scene) -> [AVScriptAnnotationInput] {
        var annotations = scene.bRollItems.map { item in
            AVScriptAnnotationInput(
                id: item.id,
                kind: .bRoll,
                text: item.descriptionText,
                source: displayName(item.sourceType),
                status: displayName(item.status),
                isDone: item.status == .done,
                anchor: coreAnchor(item.textAnchor)
            )
        }
        annotations += scene.editingItems.map { item in
            AVScriptAnnotationInput(
                id: item.id,
                kind: .editing,
                text: item.cutStyle,
                source: "",
                status: localized(item.status == .done ? "avScript.status.done" : "avScript.status.pending"),
                isDone: item.status == .done,
                anchor: coreAnchor(item.textAnchor)
            )
        }
        return annotations
    }

    private func coreAnchor(_ anchor: TextAnchor?) -> FrameScriptDocument.TextAnchor? {
        guard let anchor else { return nil }
        return FrameScriptDocument.TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
    }

    private func avScriptSafeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "FrameScript" : cleaned
    }
}
