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

/// Where an empty paragraph typed at a boundary goes. The editor inserts the
/// two newlines together with the first character, so abandoning an empty
/// draft never leaves stray blank lines in the script.
enum AVParagraphBoundary {
    /// The new paragraph starts before the current one.
    case before
    /// The new paragraph starts after the current one.
    case after
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
    /// working. The range and previous text guard against a stale row: a commit
    /// is only accepted while the model still contains exactly the text this
    /// text view was showing.
    @discardableResult
    func commitAVParagraph(
        sceneID: UUID,
        paragraphRange: NSRange,
        previousText: String,
        text: String,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return false }
        let source = scene.scriptText as NSString
        guard paragraphRange.location >= 0,
              paragraphRange.length >= 0,
              paragraphRange.location <= source.length,
              paragraphRange.length <= source.length - paragraphRange.location,
              source.substring(with: paragraphRange) == previousText else {
            return false
        }
        let updated = source.replacingCharacters(in: paragraphRange, with: text)
        guard updated != scene.scriptText else { return true }
        registerAVParagraphUndo(
            sceneID: sceneID,
            range: NSRange(location: paragraphRange.location, length: (text as NSString).length),
            previousText: text,
            nextText: previousText,
            undoManager: undoManager
        )
        commitScriptTextChange(sceneID: sceneID, previousText: scene.scriptText, text: updated)
        return true
    }

    /// Splits a paragraph at a caret offset by inserting the blank line that
    /// separates two paragraphs. Used for Return inside a multi-line paragraph;
    /// the caller then focuses the new row.
    @discardableResult
    func splitAVParagraph(
        sceneID: UUID,
        paragraphRange: NSRange,
        previousText: String,
        at caretOffset: Int,
        undoManager: UndoManager? = nil
    ) -> Bool {
        let source = previousText as NSString
        let clamped = min(max(0, caretOffset), source.length)
        let replacement = source.replacingCharacters(
            in: NSRange(location: clamped, length: 0),
            with: "\n\n"
        )
        return commitAVParagraph(
            sceneID: sceneID,
            paragraphRange: paragraphRange,
            previousText: previousText,
            text: replacement,
            undoManager: undoManager
        )
    }

    /// Commits the first character of an empty paragraph created with Return
    /// at a paragraph boundary. `previousText` is empty, so the insert can only
    /// ever write at the boundary the draft was created for.
    @discardableResult
    func insertAVParagraph(
        sceneID: UUID,
        insertionOffset: Int,
        boundary: AVParagraphBoundary,
        text: String,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard !text.isEmpty,
              let scene = project.scenes.first(where: { $0.id == sceneID }) else { return false }
        let source = scene.scriptText as NSString
        guard insertionOffset >= 0, insertionOffset <= source.length else { return false }
        // A stale draft must never write into the middle of a paragraph.
        let boundaryIsValid: Bool = switch boundary {
        case .before:
            insertionOffset == 0
                || (insertionOffset >= 2
                    && source.substring(with: NSRange(location: insertionOffset - 2, length: 2)) == "\n\n")
        case .after:
            insertionOffset == source.length
                || (insertionOffset + 2 <= source.length
                    && source.substring(with: NSRange(location: insertionOffset, length: 2)) == "\n\n")
        }
        guard boundaryIsValid else { return false }
        let replacement = boundary == .before ? text + "\n\n" : "\n\n" + text
        return commitAVParagraph(
            sceneID: sceneID,
            paragraphRange: NSRange(location: insertionOffset, length: 0),
            previousText: "",
            text: replacement,
            undoManager: undoManager
        )
    }

    private func registerAVParagraphUndo(
        sceneID: UUID,
        range: NSRange,
        previousText: String,
        nextText: String,
        undoManager: UndoManager?
    ) {
        guard let manager = undoManager ?? projectWindow?.undoManager else { return }
        manager.registerUndo(withTarget: self) { target in
            target.commitAVParagraph(
                sceneID: sceneID,
                paragraphRange: range,
                previousText: previousText,
                text: nextText,
                undoManager: manager
            )
        }
        manager.setActionName(localized("avScript.undoEdit"))
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
    func avScriptExportText(
        format: AVScriptExportFormat,
        escapeFormulas: Bool = false,
        includesBOM: Bool = false
    ) -> String {
        let document = avScriptDocument()
        let labels = avScriptExportLabels()
        switch format {
        case .markdown:
            return AVScriptExporter.markdown(document: document, labels: labels)
        case .csv:
            return AVScriptExporter.csv(
                document: document,
                labels: labels,
                escapeFormulas: escapeFormulas,
                includesBOM: includesBOM
            )
        }
    }

    /// Bytes the save panel writes. The CSV header is accented, so it carries a
    /// BOM and neutralises spreadsheet formulas; Markdown stays plain UTF-8.
    func avScriptExportData(format: AVScriptExportFormat) -> Data {
        Data(
            avScriptExportText(
                format: format,
                escapeFormulas: true,
                includesBOM: format == .csv
            ).utf8
        )
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
        panel.nameFieldStringValue = "\(SafeFileName.sanitized(project.title, fallback: "FrameScript"))-av.\(format.fileExtension)"
        panel.message = localized(
            format == .csv ? "avScript.exportPanelMessage.csv" : "avScript.exportPanelMessage"
        )
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
            try avScriptExportData(format: format).write(to: url, options: .atomic)
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
}
