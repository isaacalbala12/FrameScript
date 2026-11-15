import SwiftUI

/// Amber count shown in the script header. Clicking opens the research panel
/// filtered to the scene with unconfirmed claims.
struct ResearchSceneBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let sceneID: UUID

    var body: some View {
        if count > 0 {
            Button {
                appState.openResearchPanel(sceneID: sceneID)
            } label: {
                Label("\(count)", systemImage: "checkmark.shield")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 5)
                    .frame(height: 18)
                    .background {
                        Capsule().fill(theme.warning.opacity(0.15))
                    }
            }
            .buttonStyle(.cursorPlain)
            .help(String(format: appState.localized("research.badgeHelp"), count))
            .accessibilityLabel(String(format: appState.localized("research.badgeHelp"), count))
            .accessibilityIdentifier("research-scene-badge-\(sceneID.uuidString)")
        }
    }

    private var count: Int {
        appState.researchUnconfirmedCount(for: sceneID)
    }
}

/// Compact variant for the scene sidebar. The row itself is a button, so this
/// uses a tap gesture instead of nesting another button.
struct ResearchSidebarBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let sceneID: UUID
    let count: Int

    var body: some View {
        if count > 0 {
            Button {
                appState.openResearchPanel(sceneID: sceneID)
            } label: {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background {
                        Capsule().fill(theme.warning.opacity(0.15))
                    }
            }
            .buttonStyle(.cursorPlain)
            .help(String(format: appState.localized("research.badgeHelp"), count))
            .accessibilityLabel(String(format: appState.localized("research.badgeHelp"), count))
            .accessibilityIdentifier("research-sidebar-badge-\(sceneID.uuidString)")
        }
    }
}
