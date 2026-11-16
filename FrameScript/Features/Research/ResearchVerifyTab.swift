import AppKit
import FrameScriptCore
import SwiftUI
import UniformTypeIdentifiers

struct ResearchVerifyTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable private var presentation = ResearchPresentation.shared

    private var pending: [ResearchPendingItem] {
        appState.researchPendingItems()
    }

    private var tasks: [FrameScriptDocument.ChecklistTask] {
        appState.researchOpenTasks()
    }

    private var warnings: [ResearchExportWarning] {
        appState.researchExportWarnings()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary
                exportActions
                if !warnings.isEmpty {
                    warningsSection
                }
                pendingSection
                tasksSection
            }
            .padding(16)
        }
    }

    private var summary: some View {
        let counts = appState.researchCounts()
        return VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("research.verify.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(researchCountsText(counts, appState: appState))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: 12) {
                metric(
                    value: pending.count,
                    label: appState.localized("research.verify.pendingLabel"),
                    color: pending.isEmpty ? theme.success : theme.warning
                )
                metric(
                    value: warnings.count,
                    label: appState.localized("research.verify.warningLabel"),
                    color: warnings.isEmpty ? theme.success : theme.destructive
                )
                metric(
                    value: tasks.count,
                    label: appState.localized("research.verify.tasksLabel"),
                    color: tasks.isEmpty ? theme.success : theme.accent.color
                )
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func metric(value: Int, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("research.verify.exportTitle"))
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 10) {
                Button(appState.localized("research.verify.copyAppendix")) {
                    copyAppendix()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .disabled(appState.project.sources.isEmpty && appState.project.claims.isEmpty)

                Button(appState.localized("research.verify.exportAppendix")) {
                    exportAppendix()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .disabled(appState.project.sources.isEmpty && appState.project.claims.isEmpty)

                Button(appState.localized("research.verify.addToDescription")) {
                    let language = PublishingPresentation.shared.selectedLanguageCode
                        ?? appState.project.primaryLanguage
                    switch appState.appendResearchToPublishingDescription(language: language) {
                    case .added:
                        presentation.statusMessage = appState.localized("research.verify.addedToDescription")
                    case .createdPack:
                        presentation.statusMessage = appState.localized("research.verify.descriptionCreated")
                    case .alreadyPresent:
                        presentation.statusMessage = appState.localized("research.verify.descriptionExists")
                    case .empty:
                        presentation.statusMessage = appState.localized("research.verify.descriptionEmpty")
                    }
                }
                .buttonStyle(FrameSecondaryButtonStyle(compact: true))
                .disabled(appState.project.sources.isEmpty && appState.project.claims.isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.sidebarBackground.opacity(0.5))
        }
    }

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.destructive)
                Text(appState.localized("research.verify.warnings"))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(warnings.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.destructive)
            }
            Text(appState.localized("research.verify.warningsHelp"))
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(theme.destructive)
                        .frame(width: 5, height: 5)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.sceneTitle)
                            .font(.system(size: 11, weight: .medium))
                        Text(warning.claimText)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.destructive.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.destructive.opacity(0.25), lineWidth: 1)
                )
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.localized("research.verify.pendingSection"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(appState.localized("research.verify.sendToChecklist")) {
                    let added = appState.syncPendingClaimsToChecklist()
                    presentation.statusMessage = added > 0
                        ? String(format: appState.localized("research.verify.sent"), added)
                        : appState.localized("research.verify.nothingToAdd")
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 11, weight: .medium))
                .disabled(pending.isEmpty)
            }

            if pending.isEmpty {
                Text(appState.localized("research.verify.empty.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(pending) { item in
                    ResearchVerifyClaimRow(item: item)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("research.verify.checklist"))
                .font(.system(size: 12, weight: .semibold))

            if appState.project.checklistTasks.filter({ $0.kind == .research }).isEmpty {
                Text(appState.localized("research.verify.checklistEmpty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(appState.project.checklistTasks.filter { $0.kind == .research }) { task in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { task.isDone },
                            set: { appState.setResearchChecklistTaskDone(id: task.id, isDone: $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        Text(task.text)
                            .font(.system(size: 12))
                            .strikethrough(task.isDone)
                            .foregroundStyle(task.isDone ? theme.tertiaryText : theme.primaryText)
                        Spacer()
                        if let sceneID = task.sceneID {
                            Text(appState.sceneTitle(for: sceneID))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.sidebarBackground.opacity(0.5))
        }
    }

    private func copyAppendix() {
        let appendix = appState.researchAppendix()
        guard !appendix.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appendix, forType: .string)
        presentation.statusMessage = appState.localized("research.verify.copied")
    }

    private func exportAppendix() {
        let appendix = appState.researchAppendix()
        guard !appendix.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "fuentes-y-verificacion.md"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appendix.write(to: url, atomically: true, encoding: .utf8)
            presentation.statusMessage = appState.localized("research.verify.exported")
        } catch {
            presentation.statusMessage = appState.localized("research.verify.exportFailed")
        }
    }
}

private struct ResearchVerifyClaimRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let item: ResearchPendingItem
    @State private var note = ""
    @State private var isNoteOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(researchStatusColor(appStatus, theme: theme))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(appState.localized(appStatus.researchLocalizationKey))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(researchStatusColor(appStatus, theme: theme))
                        if !item.sceneTitles.isEmpty {
                            Text(item.sceneTitles.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                        }
                        if !item.sourceTitles.isEmpty {
                            Text("· \(item.sourceTitles.joined(separator: ", "))")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 8)

                Button(appState.localized("research.verify.noteButton")) {
                    isNoteOpen.toggle()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)

                Button(appState.localized("research.verify.confirm")) {
                    appState.confirmResearchClaim(id: item.claimID, resolutionNote: note)
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.success)
            }

            if isNoteOpen {
                HStack(spacing: 6) {
                    TextField(appState.localized("research.claims.resolutionPlaceholder"), text: $note)
                        .textFieldStyle(QuietTextFieldStyle())
                        .font(.system(size: 11))
                    Button(appState.localized("research.verify.saveNote")) {
                        var claim = appState.project.claims.first(where: { $0.id == item.claimID })
                        claim?.resolutionNote = note
                        if let claim {
                            appState.updateResearchClaim(claim)
                        }
                        isNoteOpen = false
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 11, weight: .medium))
                }
                .padding(.leading, 15)
            }
        }
        .padding(.vertical, 5)
    }

    private var appStatus: ClaimStatus {
        ClaimStatus(rawValue: item.status.rawValue) ?? .probable
    }
}
