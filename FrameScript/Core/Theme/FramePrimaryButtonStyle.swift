import SwiftUI

/// Filled primary action button shared by the sheets that must stay
/// accent-filled while their window is not key.
///
/// `.borderedProminent` falls back to the neutral grey fill in that state, and
/// the snapshot renderer never makes its window key. Drawing the fill from
/// `accentStrong` keeps the primary action primary in every window state.
struct FramePrimaryButtonStyle: ButtonStyle {
    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = theme.accentStrong
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(FrameTheme.textColor(onFill: fill))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.82 : 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension ButtonStyle where Self == FramePrimaryButtonStyle {
    static var framePrimary: FramePrimaryButtonStyle {
        FramePrimaryButtonStyle()
    }
}
