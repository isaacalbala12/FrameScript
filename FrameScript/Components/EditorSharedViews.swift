import SwiftUI

struct EditorModeHeader: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }
}

struct EmptyProductionState: View {
    @Environment(\.frameTheme) private var theme
    let message: String
    /// Optional way out of the dead end ("Go to Script"). Omitted when the
    /// caller cannot switch modes.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accentText)
                    .help(actionTitle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}

struct ProductionUnlinkedBlock<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            content
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.background.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}

struct EditorIconButton: View {
    @Environment(\.frameTheme) private var theme
    let systemName: String
    let accessibilityLabel: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(role == .destructive ? theme.destructive : theme.secondaryText)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
