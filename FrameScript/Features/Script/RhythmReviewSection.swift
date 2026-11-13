import FrameScriptCore
import SwiftUI

/// "Ritmo" section of the review panel (F26).
///
/// Lists warnings for the selected scene plus project-level outliers. Every
/// row selects its range in the script editor.
struct RhythmReviewSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.warning)
                Text(appState.localized("rhythm.sectionTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                if center.isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 12, height: 12)
                }
                if totalCount > 0 {
                    Text("\(totalCount)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background {
                            Capsule().fill(theme.warning.opacity(0.14))
                        }
                }
            }

            if !appState.settings.editorPreferences.rhythmReviewEnabled {
                Text(appState.localized("rhythm.disabled"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if sceneWarnings.isEmpty && projectWarnings.isEmpty {
                Text(appState.localized(center.isPending ? "rhythm.analyzing" : "rhythm.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sceneWarnings) { warning in
                    warningRow(warning, prefix: nil)
                }
                if !projectWarnings.isEmpty {
                    Text(appState.localized("rhythm.projectSection").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.top, 2)
                    ForEach(projectWarnings) { warning in
                        warningRow(warning, prefix: sceneTitle(for: warning))
                    }
                }
                Text(appState.localized("rhythm.clickHint"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.sidebar.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private var center: RhythmReviewCenter { RhythmReviewCenter.shared }

    private var sceneWarnings: [RhythmWarning] {
        guard let sceneID = appState.selectedScene?.id else { return [] }
        return center.warnings(for: sceneID)
    }

    private var projectWarnings: [RhythmWarning] {
        center.projectWarnings
    }

    private var totalCount: Int {
        sceneWarnings.count + projectWarnings.count
    }

    private func sceneTitle(for warning: RhythmWarning) -> String? {
        guard let raw = warning.sceneID, let id = UUID(uuidString: raw) else { return nil }
        return appState.project.scenes.first(where: { $0.id == id })?.title
    }

    private func warningRow(_ warning: RhythmWarning, prefix: String?) -> some View {
        Button {
            appState.selectRhythmWarning(warning)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(color(for: warning.kind))
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    if let prefix, !prefix.isEmpty {
                        Text(prefix)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                    Text(appState.rhythmWarningText(warning))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private func color(for kind: RhythmWarning.Kind) -> Color {
        switch kind {
        case .longSentence: theme.warning
        case .noVisualChange: theme.accent.color
        case .longHook: theme.destructive
        case .sceneLengthOutlier: theme.secondaryText
        }
    }
}

/// Small warning counter shown in the scene sidebar.
struct RhythmSidebarBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let sceneID: UUID

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.warning)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background {
                    Capsule().fill(theme.warning.opacity(0.15))
                }
                .help(String(format: appState.localized("rhythm.badgeAccessibility"), count))
                .accessibilityLabel(String(format: appState.localized("rhythm.badgeAccessibility"), count))
        }
    }

    private var count: Int {
        guard appState.settings.editorPreferences.rhythmReviewEnabled else { return 0 }
        return RhythmReviewCenter.shared.warningCount(for: sceneID)
    }
}
