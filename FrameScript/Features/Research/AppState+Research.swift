import AppKit
import Foundation
import FrameScriptCore
import Observation

// MARK: - Presentation state

/// Result of "Add to description" in the research panel.
enum ResearchDescriptionAppendOutcome: Equatable {
    case added
    case createdPack
    case alreadyPresent
    case empty
}

enum ResearchTab: String, CaseIterable, Identifiable {
    case sources
    case claims
    case verify
    case tables

    var id: String { rawValue }
}

/// Observable state for the research window. A singleton mirrors the existing
/// backups presentation and keeps the feature out of `WindowState`.
@MainActor
@Observable
final class ResearchPresentation {
    static let shared = ResearchPresentation()

    var selectedTab: ResearchTab = .claims
    /// Scene the panel was opened from. Nil means the whole project.
    var focusedSceneID: UUID?
    var statusFilter: Set<ClaimStatus> = Set(ClaimStatus.allCases)
    var onlyPending = false
    var searchText = ""
    var selectedSourceID: UUID?
    var selectedClaimID: UUID?
    var selectedTableID: UUID?

    var claimSuggestions: [ClaimSuggestion] = []
    var suggestionSceneID: UUID?
    var isCheckingClaims = false
    var checkErrorMessage: String?

    var pasteText = ""
    var pasteFormat: ComparisonTablePasteFormat?
    var pasteResult: ComparisonTablePasteResult?
    var pasteIssues: [ComparisonTableIssue] = []
    var pasteErrorMessage: String?

    var statusMessage: String?

    private init() {}

    func open(sceneID: UUID? = nil) {
        if let sceneID {
            selectedTab = .claims
            focusedSceneID = sceneID
            statusFilter = Set(ClaimStatus.allCases)
            onlyPending = false
            searchText = ""
        }
        checkErrorMessage = nil
    }

    func focus(on sceneID: UUID) {
        selectedTab = .claims
        focusedSceneID = sceneID
        onlyPending = false
    }

    func clearSceneFilter() {
        focusedSceneID = nil
    }

    func resetSuggestions() {
        claimSuggestions = []
        suggestionSceneID = nil
        checkErrorMessage = nil
    }

    func resetPaste() {
        pasteText = ""
        pasteFormat = nil
        pasteResult = nil
        pasteIssues = []
        pasteErrorMessage = nil
    }
}

// MARK: - App operations

@MainActor
extension AppState {
    // MARK: Opening and summaries

    func openResearchPanel(sceneID: UUID? = nil) {
        guard hasOpenProject else { return }
        ResearchPresentation.shared.open(sceneID: sceneID)
        researchWindowPresenter(self)
    }

    var coreResearchProject: FrameScriptDocument.Project {
        FrameScriptDocument.Project(project: project)
    }

    private var coreResearchClaims: [FrameScriptDocument.Claim] {
        project.claims.map(FrameScriptDocument.Claim.init(claim:))
    }

    func researchCounts() -> ResearchCounts {
        ResearchSummary.counts(claims: coreResearchClaims)
    }

    func researchUnconfirmedCount(for sceneID: UUID) -> Int {
        ResearchSummary.unconfirmedCount(sceneID: sceneID, claims: coreResearchClaims)
    }

    func researchUnconfirmedCountsByScene() -> [UUID: Int] {
        ResearchSummary.unconfirmedCountsByScene(claims: coreResearchClaims)
    }

    func researchPendingItems() -> [ResearchPendingItem] {
        ResearchSummary.pendingItems(
            claims: coreResearchClaims,
            sourceTitlesByID: Dictionary(
                project.sources.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            ),
            sceneTitlesByID: Dictionary(
                project.scenes.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    func researchOpenTasks() -> [FrameScriptDocument.ChecklistTask] {
        project.checklistTasks
            .filter { $0.kind == .research && !$0.isDone }
            .map(FrameScriptDocument.ChecklistTask.init(task:))
    }

    func researchSourceUsage() -> [UUID: Int] {
        ResearchSummary.sourceUsage(claims: coreResearchClaims)
    }

    func researchExportWarnings() -> [ResearchExportWarning] {
        ResearchExport.warnings(
            scenes: project.scenes.map { scene in
                ResearchSceneSnapshot(
                    id: scene.id,
                    order: scene.order,
                    title: scene.title,
                    scriptText: scene.scriptText,
                    bRollText: scene.bRollItems.flatMap { [$0.descriptionText, $0.notes] },
                    editingText: scene.editingItems.flatMap { [$0.cutStyle, $0.notes] }
                )
            },
            claims: coreResearchClaims
        )
    }

    func filteredResearchClaims() -> [ProjectClaim] {
        let presentation = ResearchPresentation.shared
        return project.claims.filter { claim in
            guard presentation.statusFilter.contains(claim.status) else { return false }
            if presentation.onlyPending, !claim.needsResearch { return false }
            if let sceneID = presentation.focusedSceneID, !claim.sceneIDs.contains(sceneID) {
                return false
            }
            let query = presentation.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }
            return claim.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || claim.resolutionNote.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func sceneTitle(for id: UUID) -> String {
        project.scenes.first(where: { $0.id == id })?.title ?? localized("research.claims.noScene")
    }

    // MARK: Sources

    @discardableResult
    func addResearchSource(
        title: String = "",
        url: String = "",
        kind: SourceKind = .other,
        reliability: SourceReliability = .medium,
        date: Date? = nil,
        note: String = ""
    ) -> ProjectSource {
        let source = ProjectSource(
            title: title,
            url: url,
            kind: kind,
            reliability: reliability,
            date: date,
            note: note
        )
        project.sources.append(source)
        ResearchPresentation.shared.selectedSourceID = source.id
        touchProject()
        return source
    }

    func updateResearchSource(_ source: ProjectSource) {
        guard let index = project.sources.firstIndex(where: { $0.id == source.id }) else { return }
        project.sources[index] = source
        touchProject()
    }

    func deleteResearchSource(id: UUID) {
        let name = project.sources.first(where: { $0.id == id })?.title ?? ""
        project.sources.removeAll { $0.id == id }
        for index in project.claims.indices {
            project.claims[index].sourceIDs.removeAll { $0 == id }
        }
        if ResearchPresentation.shared.selectedSourceID == id {
            ResearchPresentation.shared.selectedSourceID = project.sources.first?.id
        }
        ResearchPresentation.shared.statusMessage = String(
            format: localized("research.sources.deletedMessage"),
            name
        )
        touchProject()
    }

    // MARK: Claims

    @discardableResult
    func addResearchClaim(
        text: String,
        status: ClaimStatus = .probable,
        sourceIDs: [UUID] = [],
        sceneIDs: [UUID] = [],
        anchorSceneID: UUID? = nil,
        anchor: TextAnchor? = nil,
        needsVerification: Bool? = nil,
        personalExperience: Bool = false,
        resolutionNote: String = ""
    ) -> ProjectClaim {
        let claim = ProjectClaim(
            text: text,
            status: status,
            sourceIDs: sourceIDs,
            sceneIDs: sceneIDs,
            anchorSceneID: anchorSceneID,
            anchor: anchor,
            needsVerification: needsVerification,
            personalExperience: personalExperience,
            resolutionNote: resolutionNote
        )
        project.claims.append(claim)
        ResearchPresentation.shared.selectedClaimID = claim.id
        if claim.needsResearch {
            _ = syncPendingClaimsToChecklist()
        } else {
            touchProject()
        }
        return claim
    }

    func updateResearchClaim(_ claim: ProjectClaim) {
        guard let index = project.claims.firstIndex(where: { $0.id == claim.id }) else { return }
        let previous = project.claims[index]
        let wasConfirmed = previous.status == .confirmed
        var updated = claim
        // Confirming clears the flag once; an explicit re-check on an already
        // confirmed claim is a user choice and must survive later updates.
        if updated.status == .confirmed, !wasConfirmed {
            updated.needsVerification = false
        }
        project.claims[index] = updated
        if previous.text != updated.text {
            project.checklistTasks = renamingChecklistTask(
                from: previous.text,
                to: updated.text,
                sceneID: updated.sceneIDs.first
            )
        }
        if updated.status == .confirmed, !wasConfirmed {
            project.checklistTasks = markingChecklistResolved(for: updated)
        } else if previous.needsResearch, !updated.needsResearch {
            project.checklistTasks = markingChecklistResolved(for: updated)
        } else if !previous.needsResearch, updated.needsResearch {
            _ = syncPendingClaimsToChecklist()
        }
        touchProject()
    }

    func deleteResearchClaim(id: UUID) {
        let deleted = project.claims.first { $0.id == id }
        project.claims.removeAll { $0.id == id }
        if let deleted {
            // The delete confirmation promises the claim also leaves the
            // checklist. Only its open research task is removed; a completed
            // task keeps the history of work that did happen (I-2).
            let coreTasks = project.checklistTasks.map(FrameScriptDocument.ChecklistTask.init(task:))
            project.checklistTasks = ResearchChecklist
                .removing(claimText: deleted.text, in: coreTasks)
                .map { $0.makeTask() }
        }
        if ResearchPresentation.shared.selectedClaimID == id {
            ResearchPresentation.shared.selectedClaimID = project.claims.first?.id
        }
        touchProject()
    }

    func setResearchClaimStatus(id: UUID, status: ClaimStatus) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        let wasConfirmed = project.claims[index].status == .confirmed
        project.claims[index].status = status
        if status == .confirmed, !wasConfirmed {
            project.claims[index].needsVerification = false
            project.checklistTasks = markingChecklistResolved(for: project.claims[index])
        } else if project.claims[index].needsResearch {
            _ = syncPendingClaimsToChecklist()
        }
        touchProject()
    }

    func toggleResearchClaimVerification(id: UUID) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        project.claims[index].needsVerification.toggle()
        touchProject()
        if project.claims[index].needsResearch {
            _ = syncPendingClaimsToChecklist()
        } else {
            project.checklistTasks = markingChecklistResolved(for: project.claims[index])
            touchProject()
        }
    }

    func confirmResearchClaim(id: UUID, resolutionNote: String? = nil) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        let note = resolutionNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        project.claims[index].status = .confirmed
        project.claims[index].needsVerification = false
        if let note, !note.isEmpty {
            project.claims[index].resolutionNote = note
        }
        project.checklistTasks = markingChecklistResolved(for: project.claims[index])
        touchProject()
    }

    func setResearchClaimScene(id: UUID, sceneID: UUID?) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        project.claims[index].sceneIDs = sceneID.map { [$0] } ?? []
        if project.claims[index].anchorSceneID != sceneID {
            project.claims[index].anchorSceneID = nil
            project.claims[index].anchor = nil
        }
        touchProject()
    }

    func toggleResearchClaimScene(id: UUID, sceneID: UUID) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        if let position = project.claims[index].sceneIDs.firstIndex(of: sceneID) {
            project.claims[index].sceneIDs.remove(at: position)
            if project.claims[index].anchorSceneID == sceneID {
                project.claims[index].anchorSceneID = nil
                project.claims[index].anchor = nil
            }
        } else {
            project.claims[index].sceneIDs.append(sceneID)
            project.claims[index].sceneIDs = unique(project.claims[index].sceneIDs)
        }
        touchProject()
    }

    func toggleResearchClaimSource(id: UUID, sourceID: UUID) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        if let position = project.claims[index].sourceIDs.firstIndex(of: sourceID) {
            project.claims[index].sourceIDs.remove(at: position)
        } else {
            project.claims[index].sourceIDs.append(sourceID)
            project.claims[index].sourceIDs = unique(project.claims[index].sourceIDs)
        }
        touchProject()
    }

    /// Resolves the claim's stored anchor against the current scene text. The
    /// card uses this instead of trusting `anchor.selectedText` (I-4).
    func researchClaimAnchorState(_ claim: ProjectClaim) -> ResearchClaimAnchorState {
        guard let anchor = claim.anchor else { return .none }
        guard let sceneID = claim.anchorSceneID,
              let scene = project.scenes.first(where: { $0.id == sceneID }) else {
            return .missingScene
        }
        let coreAnchor = FrameScriptDocument.TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
        if let current = FrameScriptDocument.TextAnchorRepair.current(coreAnchor, in: scene.scriptText) {
            return .current(text: current.selectedText)
        }
        return .stale(storedText: anchor.selectedText)
    }

    /// Creates or repairs the claim anchor from a typed fragment. Returns false
    /// when the fragment is not in the scene.
    @discardableResult
    func setResearchClaimAnchor(id: UUID, fragment: String) -> Bool {
        guard let index = project.claims.firstIndex(where: { $0.id == id }),
              let sceneID = project.claims[index].sceneIDs.first,
              let scene = project.scenes.first(where: { $0.id == sceneID }) else {
            return false
        }
        guard let anchor = ResearchAnchoring.anchor(for: fragment, in: scene.scriptText) else {
            return false
        }
        project.claims[index].anchorSceneID = sceneID
        project.claims[index].anchor = TextAnchor(
            startUTF16: anchor.startUTF16,
            lengthUTF16: anchor.lengthUTF16,
            selectedText: anchor.selectedText,
            prefixContext: anchor.prefixContext,
            suffixContext: anchor.suffixContext
        )
        touchProject()
        return true
    }

    func clearResearchClaimAnchor(id: UUID) {
        guard let index = project.claims.firstIndex(where: { $0.id == id }) else { return }
        project.claims[index].anchorSceneID = nil
        project.claims[index].anchor = nil
        touchProject()
    }

    // MARK: Checklist and description

    /// Adds pending claims to the production checklist. Returns how many tasks
    /// were actually added.
    @discardableResult
    func syncPendingClaimsToChecklist() -> Int {
        let before = project.checklistTasks.count
        let coreClaims = project.claims.map(FrameScriptDocument.Claim.init(claim:))
        let coreTasks = project.checklistTasks.map(FrameScriptDocument.ChecklistTask.init(task:))
        let merged = ResearchChecklist.mergingPendingClaims(coreClaims, into: coreTasks)
        project.checklistTasks = merged.map { $0.makeTask() }
        touchProject()
        return project.checklistTasks.count - before
    }

    func setResearchChecklistTaskDone(id: UUID, isDone: Bool) {
        guard let index = project.checklistTasks.firstIndex(where: { $0.id == id }) else { return }
        project.checklistTasks[index].isDone = isDone
        touchProject()
    }

    private func markingChecklistResolved(
        for claim: ProjectClaim
    ) -> [ChecklistTask] {
        let coreTasks = project.checklistTasks.map(FrameScriptDocument.ChecklistTask.init(task:))
        return ResearchChecklist.markingResolved(claimText: claim.text, in: coreTasks).map { $0.makeTask() }
    }

    private func renamingChecklistTask(
        from oldText: String,
        to newText: String,
        sceneID: UUID?
    ) -> [ChecklistTask] {
        let coreTasks = project.checklistTasks.map(FrameScriptDocument.ChecklistTask.init(task:))
        return ResearchChecklist
            .renaming(claimText: oldText, to: newText, sceneID: sceneID, in: coreTasks)
            .map { $0.makeTask() }
    }

    /// Appends the "Fuentes y verificación" block to the publishing description
    /// for the language the Publishing panel is showing. A missing pack is
    /// created deliberately and reported, so the user is never surprised by
    /// three new publishing rows (I-6).
    @discardableResult
    func appendResearchToPublishingDescription(language: String) -> ResearchDescriptionAppendOutcome {
        let block = ResearchExport.descriptionBlock(project: coreResearchProject)
        guard !block.isEmpty else { return .empty }
        let key = publishingStorageKey(for: language)
        guard var pack = project.publishingPacks[key] else {
            project.publishingPacks[key] = PublishingPack(description: block)
            touchProject()
            return .createdPack
        }
        guard !pack.description.localizedCaseInsensitiveContains(ResearchExport.appendixHeading) else {
            return .alreadyPresent
        }
        pack.description = pack.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? block
            : pack.description + "\n\n" + block
        project.publishingPacks[key] = pack
        touchProject()
        return .added
    }

    func researchAppendix() -> String {
        ResearchExport.markdownAppendix(project: coreResearchProject)
    }

    // MARK: Comparison tables

    @discardableResult
    func addComparisonTable(
        title: String = "",
        header: [String] = ["A", "B"],
        rows: [[String]] = [],
        sceneID: UUID? = nil
    ) -> ComparisonTable {
        let table = ComparisonTable(title: title, header: header, rows: rows, sceneID: sceneID)
        project.comparisonTables.append(table)
        ResearchPresentation.shared.selectedTableID = table.id
        touchProject()
        return table
    }

    func updateComparisonTable(_ table: ComparisonTable) {
        guard let index = project.comparisonTables.firstIndex(where: { $0.id == table.id }) else { return }
        project.comparisonTables[index] = ComparisonTableEditing.normalized(
            FrameScriptDocument.ComparisonTable(
                id: table.id,
                title: table.title,
                header: table.header,
                rows: table.rows,
                sceneID: table.sceneID
            )
        ).appTable
        touchProject()
    }

    func deleteComparisonTable(id: UUID) {
        project.comparisonTables.removeAll { $0.id == id }
        if ResearchPresentation.shared.selectedTableID == id {
            ResearchPresentation.shared.selectedTableID = project.comparisonTables.first?.id
        }
        touchProject()
    }

    func addComparisonTableRow(id: UUID) {
        guard let table = project.comparisonTables.first(where: { $0.id == id }) else { return }
        let core = coreTable(table)
        updateComparisonTable(coreTableToApp(ComparisonTableEditing.addRow(core)))
    }

    func removeComparisonTableRow(id: UUID, at index: Int) {
        guard let table = project.comparisonTables.first(where: { $0.id == id }) else { return }
        let core = coreTable(table)
        updateComparisonTable(coreTableToApp(ComparisonTableEditing.removeRow(core, at: index)))
    }

    func addComparisonTableColumn(id: UUID) {
        guard let table = project.comparisonTables.first(where: { $0.id == id }) else { return }
        let core = coreTable(table)
        updateComparisonTable(coreTableToApp(ComparisonTableEditing.addColumn(core)))
    }

    func removeComparisonTableColumn(id: UUID, at index: Int) {
        guard let table = project.comparisonTables.first(where: { $0.id == id }) else { return }
        let core = coreTable(table)
        updateComparisonTable(coreTableToApp(ComparisonTableEditing.removeColumn(core, at: index)))
    }

    func applyComparisonTablePaste(id: UUID, result: ComparisonTablePasteResult) {
        guard let table = project.comparisonTables.first(where: { $0.id == id }) else { return }
        let updated = ComparisonTableEditing.applyingPaste(result, to: coreTable(table))
        project.comparisonTables = project.comparisonTables.map {
            $0.id == id ? coreTableToApp(updated) : $0
        }
        touchProject()
    }

    func parseComparisonTablePaste() {
        let presentation = ResearchPresentation.shared
        do {
            let result = try ComparisonTablePaste.parse(presentation.pasteText)
            presentation.pasteResult = result
            presentation.pasteFormat = result.format
            presentation.pasteIssues = result.issues
            presentation.pasteErrorMessage = nil
        } catch let error as ComparisonTablePasteError {
            presentation.pasteResult = nil
            presentation.pasteFormat = nil
            presentation.pasteIssues = []
            presentation.pasteErrorMessage = error == .empty
                ? localized("research.tables.pasteEmpty")
                : localized("research.tables.pasteUnsupported")
        } catch {
            presentation.pasteResult = nil
            presentation.pasteFormat = nil
            presentation.pasteIssues = []
            presentation.pasteErrorMessage = localized("research.tables.pasteUnsupported")
        }
    }

    private func coreTable(_ table: ComparisonTable) -> FrameScriptDocument.ComparisonTable {
        FrameScriptDocument.ComparisonTable(
            id: table.id,
            title: table.title,
            header: table.header,
            rows: table.rows,
            sceneID: table.sceneID
        )
    }

    private func coreTableToApp(_ table: FrameScriptDocument.ComparisonTable) -> ComparisonTable {
        ComparisonTable(
            id: table.id,
            title: table.title,
            header: table.header,
            rows: table.rows,
            sceneID: table.sceneID
        )
    }

    func tableValidationIssues(_ table: ComparisonTable) -> [ComparisonTableIssue] {
        ComparisonTableValidation.issues(
            in: FrameScriptDocument.ComparisonTable(
                id: table.id,
                title: table.title,
                header: table.header,
                rows: table.rows,
                sceneID: table.sceneID
            )
        )
    }

    func comparisonTableMarkdown(_ table: ComparisonTable) -> String {
        ComparisonTableRender.markdown(
            FrameScriptDocument.ComparisonTable(
                id: table.id,
                title: table.title,
                header: table.header,
                rows: table.rows,
                sceneID: table.sceneID
            )
        )
    }

    func comparisonTableCSV(_ table: ComparisonTable) -> String {
        ComparisonTableRender.csv(
            FrameScriptDocument.ComparisonTable(
                id: table.id,
                title: table.title,
                header: table.header,
                rows: table.rows,
                sceneID: table.sceneID
            )
        )
    }

    func comparisonTableDocument(_ table: ComparisonTable) -> String {
        ComparisonTableRender.markdownDocument(
            title: table.title,
            table: FrameScriptDocument.ComparisonTable(
                id: table.id,
                title: table.title,
                header: table.header,
                rows: table.rows,
                sceneID: table.sceneID
            )
        )
    }

    /// Adds the `[TABLA EN PANTALLA]` visual to the linked scene. Returns false
    /// when the table has no scene or the cue already exists.
    @discardableResult
    func addComparisonTableCue(tableID: UUID) -> Bool {
        guard let table = project.comparisonTables.first(where: { $0.id == tableID }),
              let sceneID = table.sceneID,
              let scene = project.scenes.first(where: { $0.id == sceneID }) else {
            return false
        }
        let alreadyPresent = scene.bRollItems.contains { item in
            item.descriptionText.localizedCaseInsensitiveContains("[TABLA EN PANTALLA]")
                && item.notes.localizedCaseInsensitiveContains(table.title)
        }
        guard !alreadyPresent else { return false }
        scene.bRollItems.append(
            BRollItem(
                templateType: "",
                sourceType: .infographic,
                descriptionText: "[TABLA EN PANTALLA]",
                notes: table.title,
                status: .planned
            )
        )
        touchProject()
        return true
    }

    private func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: AI claim check

    /// Asks the configured provider for claim candidates. Suggestions are never
    /// confirmed: the user accepts each one explicitly.
    func suggestResearchClaims(for sceneID: UUID) async {
        guard !ResearchPresentation.shared.isCheckingClaims else { return }
        guard settings.aiPreferences.provider != .disabled else {
            errorCenter.present(AppError(kind: .aiConfiguration, recoveryAction: .openAISettings))
            return
        }
        guard let scene = project.scenes.first(where: { $0.id == sceneID }) else { return }

        let presentation = ResearchPresentation.shared
        presentation.isCheckingClaims = true
        presentation.claimSuggestions = []
        presentation.suggestionSceneID = sceneID
        presentation.checkErrorMessage = nil
        defer { presentation.isCheckingClaims = false }

        do {
            let provider = settings.aiPreferences.provider
            let apiKey = provider.isSubscriptionBacked
                ? ""
                : try dependencies.providerCredentials.apiKey(for: provider)
            let privacyMode = settings.aiPreferences.privacyMode
            let userPrompt = privacyMode
                ? scene.scriptText
                : "Escena: \(scene.title)\n\n\(scene.scriptText)"
            let response = try await dependencies.llmProvider.complete(
                request: LLMRequest(
                    task: .claimCheck,
                    provider: provider,
                    baseURL: settings.aiPreferences.baseURL,
                    systemPrompt: PromptBuilder().systemPrompt(
                        for: .claimCheck,
                        language: PromptBuilder().responseLanguage(
                            for: scene.scriptText,
                            fallback: currentLanguage
                        )
                    ),
                    userPrompt: userPrompt,
                    model: settings.aiPreferences.model,
                    temperature: settings.aiPreferences.temperature,
                    maxTokens: settings.aiPreferences.maxTokens
                ),
                apiKey: apiKey
            )
            presentation.claimSuggestions = ClaimSuggestionParser.parse(response.text)
            if presentation.claimSuggestions.isEmpty {
                presentation.statusMessage = localized("research.claims.noSuggestions")
            }
        } catch {
            presentation.checkErrorMessage = localized("research.claims.checkFailed")
            errorCenter.present(AppError.ai(error))
        }
    }

    func acceptResearchClaimSuggestion(_ suggestion: ClaimSuggestion) {
        let presentation = ResearchPresentation.shared
        guard let sceneID = presentation.suggestionSceneID else { return }
        let status = suggestion.status == .confirmed
            ? ClaimStatus.probable
            : ClaimStatus(rawValue: suggestion.status.rawValue) ?? .probable
        addResearchClaim(
            text: suggestion.text,
            status: status,
            sceneIDs: [sceneID],
            needsVerification: true,
            resolutionNote: suggestion.reason
        )
        presentation.claimSuggestions.removeAll { $0.id == suggestion.id }
    }

    func dismissResearchClaimSuggestion(_ suggestion: ClaimSuggestion) {
        ResearchPresentation.shared.claimSuggestions.removeAll { $0.id == suggestion.id }
    }
}

private extension FrameScriptDocument.ComparisonTable {
    var appTable: ComparisonTable {
        ComparisonTable(
            id: id,
            title: title,
            header: header,
            rows: rows,
            sceneID: sceneID
        )
    }
}
