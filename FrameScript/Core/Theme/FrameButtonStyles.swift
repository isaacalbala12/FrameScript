import SwiftUI

/// Shared primary action style: a filled accent button with text that always
/// reaches WCAG AA on the accent fill.
///
/// The regular size matches the sheets that were reviewed with cdh's style
/// (13 pt, 14×6 padding, hit area via `contentShape`). The compact size is for
/// inline toolbars such as the board footer and the claim anchor editor.
/// `.framePrimary` is the shorthand used by the sheets.
struct FramePrimaryButtonStyle: ButtonStyle {
    enum Size {
        case regular
        case compact
    }

    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var size: Size = .regular

    init(size: Size = .regular) {
        self.size = size
    }

    init(compact: Bool) {
        self.size = compact ? .compact : .regular
    }

    func makeBody(configuration: Configuration) -> some View {
        let fill = theme.accentStrong
        return configuration.label
            .font(.system(size: size == .compact ? 11 : 13, weight: .semibold))
            .foregroundStyle(FrameTheme.textColor(onFill: fill))
            .padding(.horizontal, size == .compact ? 9 : 14)
            .padding(.vertical, size == .compact ? 4 : 6)
            .frame(minHeight: size == .compact ? 24 : nil)
            .background {
                RoundedRectangle(cornerRadius: size == .compact ? 6 : 7, style: .continuous)
                    .fill(fill.opacity(configuration.isPressed ? 0.82 : 1))
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: size == .compact ? 6 : 7, style: .continuous))
            .clickableCursor(enabled: isEnabled)
    }
}

/// Shared secondary action style: a bordered control that still reads as a
/// button without competing with the primary action.
struct FrameSecondaryButtonStyle: ButtonStyle {
    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var size: FramePrimaryButtonStyle.Size = .regular

    init(size: FramePrimaryButtonStyle.Size = .regular) {
        self.size = size
    }

    init(compact: Bool) {
        self.size = compact ? .compact : .regular
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size == .compact ? 11 : 13, weight: .medium))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, size == .compact ? 9 : 14)
            .padding(.vertical, size == .compact ? 4 : 6)
            .frame(minHeight: size == .compact ? 24 : nil)
            .background {
                RoundedRectangle(cornerRadius: size == .compact ? 6 : 7, style: .continuous)
                    .fill(theme.cardBackground.opacity(configuration.isPressed ? 0.75 : 1))
            }
            .overlay {
                RoundedRectangle(cornerRadius: size == .compact ? 6 : 7, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: size == .compact ? 6 : 7, style: .continuous))
            .clickableCursor(enabled: isEnabled)
    }
}

extension ButtonStyle where Self == FramePrimaryButtonStyle {
    static var framePrimary: FramePrimaryButtonStyle {
        FramePrimaryButtonStyle()
    }
}

extension ButtonStyle where Self == FrameSecondaryButtonStyle {
    static var frameSecondary: FrameSecondaryButtonStyle {
        FrameSecondaryButtonStyle()
    }
}
