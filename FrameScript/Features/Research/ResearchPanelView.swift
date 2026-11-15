import FrameScriptCore
import SwiftUI

struct ResearchPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable private var presentation = ResearchPresentation.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            tabBar
            Divider().overlay(theme.divider)
            content
        }
        .background(theme.background)
        .foregroundStyle(theme.primaryText)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.project.sources.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: appState.project.claims.map(\.id)) { _, _ in ensureSelection() }
        .onChange(of: appState.project.comparisonTables.map(\.id)) { _, _ in ensureSelection() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(theme.accent.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("research.title"))
                    .font(.system(size: 18, weight: .semibold))
                Text(appState.project.title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let message = presentation.statusMessage {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.success)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 360, alignment: .trailing)
                    .onTapGesture { presentation.statusMessage = nil }
            }

            Button {
                ResearchWindowPresenter.shared.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("research.close"))
            .accessibilityLabel(appState.localized("research.close"))
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(.sources, titleKey: "research.tab.sources", count: appState.project.sources.count)
            tabButton(.claims, titleKey: "research.tab.claims", count: appState.project.claims.count)
            tabButton(.verify, titleKey: "research.tab.verify", count: pendingCount)
            tabButton(.tables, titleKey: "research.tab.tables", count: appState.project.comparisonTables.count)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(theme.sidebarBackground.opacity(0.45))
    }

    private func tabButton(_ tab: ResearchTab, titleKey: String, count: Int) -> some View {
        let isSelected = presentation.selectedTab == tab
        return Button {
            presentation.selectedTab = tab
            presentation.statusMessage = nil
            ensureSelection()
        } label: {
            HStack(spacing: 6) {
                Text(appState.localized(titleKey))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule().fill(isSelected ? theme.accentSoft : theme.hover))
                }
            }
            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.selection : Color.clear)
            }
        }
        .buttonStyle(.cursorPlain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.selectedTab {
        case .sources:
            ResearchSourcesTab()
        case .claims:
            ResearchClaimsTab()
        case .verify:
            ResearchVerifyTab()
        case .tables:
            ResearchTablesTab()
        }
    }

    private var pendingCount: Int {
        appState.researchPendingItems().count
    }

    private func ensureSelection() {
        if presentation.selectedSourceID == nil || !appState.project.sources.contains(where: { $0.id == presentation.selectedSourceID }) {
            presentation.selectedSourceID = appState.project.sources.first?.id
        }
        if presentation.selectedClaimID == nil || !appState.project.claims.contains(where: { $0.id == presentation.selectedClaimID }) {
            presentation.selectedClaimID = appState.project.claims.first?.id
        }
        if presentation.selectedTableID == nil || !appState.project.comparisonTables.contains(where: { $0.id == presentation.selectedTableID }) {
            presentation.selectedTableID = appState.project.comparisonTables.first?.id
        }
    }
}

// MARK: - Shared styling and labels

extension ClaimStatus {
    var researchLocalizationKey: String {
        "research.status.\(rawValue)"
    }
}

extension SourceKind {
    var researchLocalizationKey: String {
        "research.sourceKind.\(rawValue)"
    }
}

extension SourceReliability {
    var researchLocalizationKey: String {
        "research.reliability.\(rawValue)"
    }
}

@MainActor
func researchStatusColor(_ status: ClaimStatus, theme: FrameTheme) -> Color {
    switch status {
    case .confirmed: theme.success
    case .probable: theme.warning
    case .rumor: theme.destructive
    case .communityOpinion: theme.accent.color
    }
}

@MainActor
func researchClaimCountText(_ count: Int, key: String, appState: AppState) -> String {
    let suffix = count == 1 ? "one" : "other"
    return String(format: appState.localized("research.count.\(key).\(suffix)"), count)
}

@MainActor
func researchCountsText(_ counts: ResearchCounts, appState: AppState) -> String {
    guard counts.total > 0 else { return appState.localized("research.counts.empty") }
    var parts: [String] = []
    for (status, count) in counts.statusParts where count > 0 {
        parts.append(researchClaimCountText(count, key: researchCountKey(status), appState: appState))
    }
    if counts.pending > 0 {
        parts.append(researchClaimCountText(counts.pending, key: "pending", appState: appState))
    }
    return parts.joined(separator: " · ")
}

private func researchCountKey(_ status: FrameScriptDocument.ClaimStatus) -> String {
    switch status {
    case .confirmed: "confirmed"
    case .probable: "probable"
    case .rumor: "rumor"
    case .communityOpinion: "opinion"
    }
}

@MainActor
func researchIssueText(_ issue: ComparisonTableIssue, appState: AppState) -> String {
    switch issue {
    case .noColumns:
        appState.localized("research.tables.warning.noColumns")
    case .noRows:
        appState.localized("research.tables.warning.noRows")
    case let .emptyHeader(column):
        String(format: appState.localized("research.tables.warning.emptyHeader"), column + 1)
    case let .duplicateHeader(column):
        String(format: appState.localized("research.tables.warning.duplicateHeader"), column + 1)
    case let .emptyCell(row, column):
        String(format: appState.localized("research.tables.warning.emptyCell"), row + 1, column + 1)
    case let .raggedRow(row, expected, actual):
        String(format: appState.localized("research.tables.warning.raggedRow"), row + 1, actual, expected)
    case let .raggedHeader(expected, actual):
        String(format: appState.localized("research.tables.warning.raggedHeader"), actual, expected)
    }
}

@MainActor
func researchPasteFormatLabel(_ format: ComparisonTablePasteFormat, appState: AppState) -> String {
    switch format {
    case .markdown: appState.localized("research.tables.pasteFormat.markdown")
    case .tsv: appState.localized("research.tables.pasteFormat.tsv")
    case .csv: appState.localized("research.tables.pasteFormat.csv")
    }
}

struct ResearchEmptyState: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
