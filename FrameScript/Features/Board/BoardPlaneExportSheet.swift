import FrameScriptCore
import SwiftUI

/// Explicit, preview-first export of one project's pending tasks to Plane.
/// Nothing is sent until the user presses the export button, and the preview is
/// always shown first.
struct BoardPlaneExportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(\.frameTheme) private var theme

    let summary: BoardProjectSummary
    let store: BoardStore
    let plane: PlaneSettingsStore
    let exporter: BoardPlaneExporter
    let ledgerStore: BoardPlaneLedgerStore

    @State private var plan = PlaneExportPlan(tasks: [])
    @State private var report: PlaneExportReport?
    @State private var errorMessage: String?
    @State private var isExporting = false

    init(
        summary: BoardProjectSummary,
        store: BoardStore,
        plane: PlaneSettingsStore,
        exporter: BoardPlaneExporter = BoardPlaneExporter(),
        ledgerStore: BoardPlaneLedgerStore = BoardPlaneLedgerStore()
    ) {
        self.summary = summary
        self.store = store
        self.plane = plane
        self.exporter = exporter
        self.ledgerStore = ledgerStore
    }

    private var isConfigured: Bool {
        plane.settings.isConfigured && plane.hasStoredToken
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let report {
                resultView(report)
            } else if !isConfigured {
                configurationNotice
            } else if plan.entries.isEmpty {
                emptyView
            } else {
                preview
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(22)
        .frame(width: 620)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear {
            plane.refreshTokenStatus()
            reloadPlan()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.localized("board.plane.title"))
                .font(.system(size: 18, weight: .semibold))
            Text(summary.title.isEmpty ? appState.localized("project.untitled") : summary.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(appState.localized("board.plane.previewNote"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configurationNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(appState.localized("board.plane.notConfigured"), systemImage: "gearshape")
                .font(.system(size: 12, weight: .medium))
            Text(appState.localized("board.plane.notConfiguredHelp"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button(appState.localized("board.plane.openSettings")) {
                dismiss()
                Task { @MainActor in
                    appState.openSettings(tab: .board)
                    openSettings()
                }
            }
            .clickableCursor()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.warning.opacity(0.10))
        }
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26))
                .foregroundStyle(theme.success)
            Text(appState.localized("board.plane.noTasks"))
                .font(.system(size: 13, weight: .medium))
            Text(appState.localized("board.plane.noTasksHelp"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(String(
                    format: appState.localized("board.plane.summary"),
                    plan.summary.workItemCount,
                    plan.summary.taskCount
                ))
                .font(.system(size: 12, weight: .semibold))
                if plan.summary.skippedCount > 0 {
                    Text(String(
                        format: appState.localized("board.plane.skipped"),
                        plan.summary.skippedCount
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                }
                Spacer(minLength: 0)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: BoardPendingKindStyle.icon(entry.task.kind))
                                .font(.system(size: 9.5))
                                .foregroundStyle(theme.secondaryText)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.task.title)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                if !entry.task.sceneTitle.isEmpty,
                                   !entry.task.title.localizedCaseInsensitiveContains(entry.task.sceneTitle) {
                                    Text(entry.task.sceneTitle)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(theme.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            if entry.wasNameTruncated {
                                Text(appState.localized("board.plane.truncated"))
                                    .font(.system(size: 9))
                                    .foregroundStyle(theme.warning)
                            }
                            if let due = entry.task.dueDate {
                                Text(due.iso8601)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 250)

            if plan.summary.truncatedNameCount > 0 {
                Text(appState.localized("board.plane.truncatedHelp"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private func resultView(_ report: PlaneExportReport) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(appState.localized("board.plane.done"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.success)

            Text(String(
                format: appState.localized("board.plane.resultCounts"),
                count(in: report, matching: { if case .created = $0 { true } else { false } }),
                count(in: report, matching: { if case .verified = $0 { true } else { false } }),
                count(in: report, matching: { if case .recreated = $0 { true } else { false } }),
                count(in: report, matching: { if case .failed = $0 { true } else { false } })
            ))
            .font(.system(size: 11.5))
            .foregroundStyle(theme.secondaryText)

            if report.warnings.contains(where: { $0.kind == .possibleDuplicateByName }) {
                Label(
                    appState.localized("board.plane.duplicateWarning"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10.5))
                .foregroundStyle(theme.warning)
            }

            if report.outcomes.contains(where: {
                if case .deleted = $0 { true } else { false }
            }) {
                Text(appState.localized("board.plane.deletedWarning"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.warning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.success.opacity(0.08))
        }
    }

    private var footer: some View {
        HStack {
            if !isConfigured, report == nil {
                Text(appState.localized("board.plane.settingsHint"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
            Spacer()
            Button(report == nil ? appState.localized("project.unsaved.cancel") : appState.localized("board.plane.close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .clickableCursor()

            if report == nil {
                Button {
                    Task { await export() }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(appState.localized("board.plane.export"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isConfigured || plan.entries.isEmpty || isExporting)
                .clickableCursor()
            }
        }
    }

    private func reloadPlan() {
        guard let live = store.summary(id: summary.id) else {
            plan = store.planePlan(for: summary, appState: appState)
            return
        }
        plan = store.planePlan(for: live, appState: appState)
    }

    private func export() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }
        errorMessage = nil

        do {
            let token = try plane.tokenForExport()
            let configuration = try plane.settings.configuration(apiKey: token)
            let ledger = ledgerStore.ledger(for: summary.projectID)
            let result = try await exporter.export(
                plan: plan,
                configuration: configuration,
                ledger: ledger
            )
            ledgerStore.save(result.ledger, for: summary.projectID)
            report = result
        } catch let error as PlaneError {
            errorMessage = "\(appState.localized("board.plane.error")) \(error.localizedDescription)"
        } catch {
            errorMessage = appState.localized("board.plane.error")
        }
    }

    private func count(
        in report: PlaneExportReport,
        matching predicate: (PlaneExportOutcome) -> Bool
    ) -> Int {
        report.outcomes.filter(predicate).count
    }
}

