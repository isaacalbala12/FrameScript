import SwiftUI

/// Shared primary action style: a filled accent button with text that always
/// reaches WCAG AA on the accent fill. Feature branches used to invent private
/// styles, which made a primary action in one panel look like a link in another
/// (VW5).
struct FramePrimaryButtonStyle: ButtonStyle {
    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(FrameTheme.textColor(onFill: theme.accentStrong))
            .padding(.horizontal, compact ? 9 : 12)
            .frame(height: compact ? 24 : 28)
            .background {
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(theme.accentStrong)
            }
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.78 : 1))
            .clickableCursor(enabled: isEnabled)
    }
}

/// Shared secondary action style: bordered control that still reads as a
/// button, without competing with the primary action.
struct FrameSecondaryButtonStyle: ButtonStyle {
    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, compact ? 9 : 11)
            .frame(height: compact ? 24 : 28)
            .background {
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(theme.cardBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
            .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.75 : 1))
            .clickableCursor(enabled: isEnabled)
    }
}
