import AppKit
import Foundation
import FrameScriptCore
import Observation
import UniformTypeIdentifiers

enum EscaletaImportMode: Equatable {
    case newProject
    case appendThumbnailConcepts
    case appendResearchDossier
    case requiresOpenProject
    case unsupported
}

struct EscaletaImportRequest: Identifiable {
    let id = UUID()
    let url: URL
    let markdown: String
    let result: EscaletaImportResult
    let mapping: EscaletaProjectMapping?
    let mode: EscaletaImportMode

    var document: EscaletaDocument { result.document }
    var warnings: [EscaletaWarning] {
        (mapping?.warnings ?? result.warnings)
    }

    var fileName: String { url.lastPathComponent }

    var isConfirmEnabled: Bool {
        switch mode {
        case .newProject:
            mapping != nil && !document.scenes.isEmpty
        case .appendThumbnailConcepts:
            document.thumbnailConcepts?.groups.isEmpty == false
        case .appendResearchDossier:
            !dossierSections.isEmpty
        case .requiresOpenProject, .unsupported:
            false
        }
    }

    var dossierSections: [EscaletaUnparsedSection] {
        let sections = document.unparsedSections
        if !sections.isEmpty { return sections }
        guard !document.title.isEmpty else { return [] }
        var body: [String] = []
        if let preTitle = document.preTitleText { body.append(preTitle) }
        if let versionNote = document.versionNote { body.append(versionNote) }
        return [
            EscaletaUnparsedSection(
                level: 1,
                heading: document.title,
                body: body.joined(separator: "\n\n")
            )
        ]
    }

    var thumbnailConceptCount: Int {
        document.thumbnailConcepts?.groups.reduce(0) { $0 + $1.concepts.count } ?? 0
    }
}

@MainActor
@Observable
final class EscaletaImportCoordinator {
    var request: EscaletaImportRequest?

    func chooseFile(appState: AppState) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.message = appState.localized("escaleta.import.openPanelMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        present(url: url, appState: appState)
    }

    func present(url: URL, appState: AppState) {
        guard let request = appState.prepareEscaletaImport(url: url) else { return }
        self.request = request
    }

    func dismiss() {
        request = nil
    }
}

@MainActor
extension AppState {
    func prepareEscaletaImport(url: URL) -> EscaletaImportRequest? {
        do {
            let markdown = try securityScope.withAccess(to: url) {
                try String(contentsOf: url, encoding: .utf8)
            }
            let result = EscaletaParser.parse(markdown)
            let mode = importMode(for: result.document)
            let mapping: EscaletaProjectMapping? = if result.document.kind == .escaleta, !result.document.scenes.isEmpty {
                EscaletaProjectMapper.map(
                    result,
                    options: EscaletaMappingOptions(wordsPerMinute: settings.editorPreferences.wordsPerMinute)
                )
            } else {
                nil
            }
            return EscaletaImportRequest(
                url: url,
                markdown: markdown,
                result: result,
                mapping: mapping,
                mode: mode
            )
        } catch {
            errorCenter.present(
                AppError(
                    kind: .invalidProjectData,
                    context: AppErrorContext(
                        fileName: url.lastPathComponent,
                        diagnosticCode: "markdown-import-read"
                    )
                )
            )
            return nil
        }
    }

    @discardableResult
    func confirmEscaletaImport(_ request: EscaletaImportRequest) -> Bool {
        switch request.mode {
        case .newProject:
            guard let mapping = request.mapping else { return false }
            return openImportedEscaletaProject(mapping.project)
        case .appendThumbnailConcepts:
            return appendThumbnailConcepts(from: request.document)
        case .appendResearchDossier:
            return appendResearchDossier(from: request)
        case .requiresOpenProject, .unsupported:
            return false
        }
    }

    func exportEscaletaMarkdown() {
        guard hasOpenProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.nameFieldStringValue = "\(safeFileName(project.title)) — escaleta.md"
        panel.message = localized("escaleta.export.panelMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let markdown = EscaletaProjectExporter.markdown(from: project)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorCenter.present(
                AppError(
                    kind: .export,
                    context: AppErrorContext(
                        fileName: url.lastPathComponent,
                        diagnosticCode: "markdown-export-write"
                    ),
                    recoveryAction: .chooseExportFolder
                )
            )
        }
    }

    // MARK: - Modes

    private func importMode(for document: EscaletaDocument) -> EscaletaImportMode {
        switch document.kind {
        case .escaleta:
            return document.scenes.isEmpty ? .unsupported : .newProject
        case .thumbnailConcepts:
            return hasOpenProject ? .appendThumbnailConcepts : .requiresOpenProject
        case .researchDossier:
            return hasOpenProject ? .appendResearchDossier : .requiresOpenProject
        case .other:
            guard hasOpenProject else { return .unsupported }
            return document.unparsedSections.isEmpty ? .unsupported : .appendResearchDossier
        }
    }

    // MARK: - New project

    private func openImportedEscaletaProject(_ imported: FrameProject) -> Bool {
        guard closeProject() else { return false }
        projectStore.openProject(
            imported,
            fileURL: nil,
            wordsPerMinute: settings.editorPreferences.wordsPerMinute,
            markUnsaved: true
        )
        resetProjectFileTracking()
        projectStore.synchronizeTextSegments(
            splitMode: settings.generalPreferences.defaultSplitMode,
            wordsPerMinute: settings.editorPreferences.wordsPerMinute
        )
        setEditorContextAfterFlush(sceneID: .some(imported.scenes.sortedByOrder.first?.id), mode: .script)
        editorState.isFocusModeEnabled = false
        return true
    }

    // MARK: - Append to current project

    private func appendThumbnailConcepts(from document: EscaletaDocument) -> Bool {
        guard hasOpenProject, let thumbnail = document.thumbnailConcepts else { return false }
        let language = project.primaryLanguage
        var pack = project.publishingPacks[language] ?? PublishingPack()
        let rendered = thumbnailConceptNotes(from: thumbnail)
        guard !rendered.isEmpty else { return false }
        if pack.thumbnailConceptNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pack.thumbnailConceptNotes = rendered
        } else {
            pack.thumbnailConceptNotes += "\n\n" + rendered
        }
        project.publishingPacks[language] = pack
        touchProject()
        return true
    }

    private func appendResearchDossier(from request: EscaletaImportRequest) -> Bool {
        guard hasOpenProject else { return false }
        let sections = request.dossierSections
        guard !sections.isEmpty else { return false }
        let existing = Set(project.unparsedSections.map { "\($0.heading)\u{1F}\($0.body)" })
        for section in sections {
            let key = "\(section.heading)\u{1F}\(section.body)"
            guard !existing.contains(key) else { continue }
            project.unparsedSections.append(
                UnparsedSection(heading: section.heading, body: section.body)
            )
        }
        touchProject()
        return true
    }

    private func thumbnailConceptNotes(from document: ThumbnailConceptsDocument) -> String {
        var lines: [String] = []
        for group in document.groups {
            if !group.title.isEmpty {
                lines.append("## \(group.title)")
            }
            if let reference = group.referenceTitle {
                lines.append("Referencia: \(reference)")
            }
            for concept in group.concepts {
                let suffix = concept.recommended ? " — Recomendado" : ""
                lines.append("### Concepto \(concept.label) — \(concept.text)\(suffix)")
                if let idea = concept.idea { lines.append("Idea: \(idea)") }
                if !concept.composition.isEmpty {
                    lines.append("Composición:")
                    lines.append(contentsOf: concept.composition.map { "- \($0)" })
                }
                if let why = concept.whyItWorks { lines.append("Por qué funciona: \(why)") }
            }
            if !group.abTestItems.isEmpty {
                lines.append("Prueba A/B:")
                lines.append(contentsOf: group.abTestItems.map { "- \($0)" })
            }
        }
        if !document.sharedRules.isEmpty {
            lines.append("## Jerarquía visual común")
            lines.append(contentsOf: document.sharedRules.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private func safeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "escaleta" : cleaned
    }
}
