import SwiftUI

/// Compact variant for the scene sidebar. The row itself is a button, so this
/// uses a tap gesture instead of nesting another button.
///
/// The scene header no longer has a separate badge: `UXSceneMetaChips` owns the
/// single «N por verificar» chip there (it opens the inspector instead of the
/// research window).
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
