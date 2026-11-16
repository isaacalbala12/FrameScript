import FrameScriptCore
import SwiftUI

// MARK: - Models

/// What the Investigación tab needs for the current scene.
///
/// Pure data so the shell can be snapshot-tested without a window and so the
/// pending count always comes from `ResearchSummary` rather than a second rule.
struct UXInspectorResearchModel: Equatable {
    let sceneID: UUID
    let claims: [ProjectClaim]
    let pendingCount: Int

    init(sceneID: UUID, claims: [ProjectClaim], pendingCount: Int) {
        self.sceneID = sceneID
        self.claims = claims
        self.pendingCount = pendingCount
    }

    @MainActor
    init?(appState: AppState) {
        guard let scene = appState.selectedScene else { return nil }
        self.init(
            sceneID: scene.id,
            claims: appState.project.claims.filter { $0.sceneIDs.contains(scene.id) },
            pendingCount: UXResearchPending.sceneCount(
                in: appState.project.claims,
                sceneID: scene.id
            )
        )
    }
}

/// What the Producción tab needs for the current scene.
///
/// The rows come from the same `ProductionChecklist` snapshot the full panel
/// renders, filtered to its toggleable manual rows for this scene. That keeps
/// the inspector from re-introducing the E-2 research copy (the snapshot hides
/// a stored `.research` task that mirrors a claim) and from showing publishing
/// rows twice.
struct UXInspectorProductionModel: Equatable {
    let sceneID: UUID
    let tasks: [ChecklistTask]

    var openCount: Int {
        tasks.filter { !$0.isDone }.count
    }

    init(sceneID: UUID, tasks: [ChecklistTask]) {
        self.sceneID = sceneID
        self.tasks = tasks
    }

    @MainActor
    init?(appState: AppState) {
        guard let scene = appState.selectedScene else { return nil }
        self.init(
            sceneID: scene.id,
            tasks: Self.visibleSceneTasks(
                appState: appState,
                sceneID: scene.id,
                snapshot: ProductionChecklistCenter.shared.snapshot
            )
        )
    }

    /// Manual rows the production panel can toggle, in panel order.
    @MainActor
    static func visibleSceneTasks(
        appState: AppState,
        sceneID: UUID,
        snapshot: ProductionSnapshot
    ) -> [ChecklistTask] {
        let tasksByID = Dictionary(
            appState.project.checklistTasks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return snapshot.items.compactMap { item in
            guard item.reason == .manualTask,
                  item.sceneID == sceneID,
                  case let .manualTask(taskID) = item.target,
                  let task = tasksByID[taskID]
            else { return nil }
            return task
        }
    }
}

// MARK: - Bindings

/// The inspector writes through the same `AppState` APIs as the full panels.
///
/// Bindings read the live model instead of the last rendered copy, so a
/// checkbox can never toggle twice or drift from the panel.
@MainActor
enum UXInspectorProjectBindings {
    static func claimVerification(
        claimID: UUID,
        appState: AppState
    ) -> Binding<Bool> {
        Binding(
            get: {
                appState.project.claims.first(where: { $0.id == claimID })?.needsVerification ?? false
            },
            set: { isOn in
                guard let claim = appState.project.claims.first(where: { $0.id == claimID }),
                      claim.needsVerification != isOn
                else { return }
                appState.toggleResearchClaimVerification(id: claimID)
            }
        )
    }

    static func taskDone(taskID: UUID, appState: AppState) -> Binding<Bool> {
        Binding(
            get: {
                appState.project.checklistTasks.first(where: { $0.id == taskID })?.isDone ?? false
            },
            set: { isDone in
                guard let task = appState.project.checklistTasks.first(where: { $0.id == taskID }),
                      task.isDone != isDone
                else { return }
                appState.toggleProductionTask(id: taskID)
            }
        )
    }
}

// MARK: - Investigación tab

struct UXInspectorResearchTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        ScrollView {
            if let model = UXInspectorResearchModel(appState: appState) {
                VStack(alignment: .leading, spacing: 12) {
                    summaryCard(model)
                    if model.claims.isEmpty {
                        emptyCard
                    } else {
                        ForEach(model.claims) { claim in
                            UXResearchClaimRow(claimID: claim.id)
                        }
                    }
                    openButton(sceneID: model.sceneID)
                }
                .padding(14)
            } else {
                Text(appState.localized("ux.inspector.research.noScene"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .background(theme.background)
    }

    private func summaryCard(_ model: UXInspectorResearchModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.pendingCount > 0 ? theme.warning : theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("ux.inspector.research.heading"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text(pendingText(model.pendingCount))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.pendingCount > 0 ? theme.warning : theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ux-inspector-research-summary")
    }

    private func pendingText(_ count: Int) -> String {
        count == 0
            ? appState.localized("ux.inspector.research.none")
            : UXSceneResearchChip.text(pending: count, language: appState.currentLanguage)
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("ux.inspector.research.empty.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(appState.localized("ux.inspector.research.empty.message"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(cardBackground)
        .accessibilityIdentifier("ux-inspector-research-empty")
    }

    private func openButton(sceneID: UUID) -> some View {
        Button {
            appState.openResearchPanel(sceneID: sceneID)
        } label: {
            Label(
                appState.localized("ux.inspector.research.open"),
                systemImage: "arrow.up.forward.square"
            )
        }
        .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
        .accessibilityIdentifier("ux-inspector-open-research")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
    }
}

private struct UXResearchClaimRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let claimID: UUID

    private var claim: ProjectClaim? {
        appState.project.claims.first { $0.id == claimID }
    }

    var body: some View {
        if let claim {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(researchStatusColor(claim.status, theme: theme))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                    Text(displayText(claim))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Toggle(
                    isOn: UXInspectorProjectBindings.claimVerification(
                        claimID: claimID,
                        appState: appState
                    )
                ) {
                    Text(appState.localized("ux.inspector.research.verify"))
                        .font(.system(size: 10, weight: claim.needsVerification ? .semibold : .regular))
                        .foregroundStyle(claim.needsVerification ? theme.warning : theme.secondaryText)
                }
                .toggleStyle(.checkbox)
                .help(appState.localized("ux.inspector.research.verifyHelp"))
                .accessibilityIdentifier("ux-inspector-claim-toggle-\(claimID.uuidString)")
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(displayText(claim)). \(statusLabel(claim.status))")
            .accessibilityIdentifier("ux-inspector-claim-\(claimID.uuidString)")
        }
    }

    private func displayText(_ claim: ProjectClaim) -> String {
        let trimmed = claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? appState.localized("ux.inspector.research.untitled")
            : trimmed
    }

    private func statusLabel(_ status: ClaimStatus) -> String {
        appState.localized(status.researchLocalizationKey)
    }
}

// MARK: - Producción tab

struct UXInspectorProductionTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        ScrollView {
            if let model = UXInspectorProductionModel(appState: appState) {
                VStack(alignment: .leading, spacing: 12) {
                    summaryCard(model)
                    if model.tasks.isEmpty {
                        emptyCard
                    } else {
                        ForEach(model.tasks) { task in
                            UXProductionTaskRow(taskID: task.id)
                        }
                    }
                    openButton
                }
                .padding(14)
            } else {
                Text(appState.localized("ux.inspector.production.noScene"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .background(theme.background)
        .onAppear {
            // Same cache the production panel reads; refresh on open so a
            // just-created claim copy cannot survive in the snapshot.
            appState.refreshProductionChecklist()
        }
    }

    private func summaryCard(_ model: UXInspectorProductionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.openCount > 0 ? theme.warning : theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("ux.inspector.production.heading"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text(
                    model.openCount == 0
                        ? appState.localized("ux.inspector.production.none")
                        : L10n.plural(
                            "ux.inspector.production.open",
                            count: model.openCount,
                            language: appState.currentLanguage
                        )
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(model.openCount > 0 ? theme.warning : theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(cardBackground)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ux-inspector-production-summary")
    }

    private var emptyCard: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("ux.inspector.production.empty.title"))
                .font(.system(size: 12, weight: .semibold))
            Text(appState.localized("ux.inspector.production.empty.message"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(cardBackground)
        .accessibilityIdentifier("ux-inspector-production-empty")
    }

    private var openButton: some View {
        Button {
            UXProjectCommandDispatcher.perform(.productionChecklist, appState: appState)
        } label: {
            Label(
                appState.localized("ux.inspector.production.openPanel"),
                systemImage: "arrow.up.forward.square"
            )
        }
        .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
        .accessibilityIdentifier("ux-inspector-open-production")
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
    }
}

private struct UXProductionTaskRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let taskID: UUID

    private var task: ChecklistTask? {
        appState.project.checklistTasks.first { $0.id == taskID }
    }

    var body: some View {
        if let task {
            Toggle(
                isOn: UXInspectorProjectBindings.taskDone(taskID: taskID, appState: appState)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 11, weight: task.isDone ? .regular : .medium))
                        .strikethrough(task.isDone, color: theme.tertiaryText)
                        .foregroundStyle(task.isDone ? theme.secondaryText : theme.primaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(
                        appState.localized("production.kind.\(task.kind.productionKind.rawValue)")
                    )
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                }
            }
            .toggleStyle(.checkbox)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    }
            }
            .accessibilityIdentifier("ux-inspector-task-\(taskID.uuidString)")
        }
    }
}
