import SwiftUI

struct QuietField<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let detail: String?
    @ViewBuilder var content: Content

    init(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            content
        }
    }
}

struct QuietTextFieldStyle: TextFieldStyle {
    @Environment(\.frameTheme) private var theme

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.editorSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }
    }
}

struct MultilineField: View {
    @Environment(\.frameTheme) private var theme
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 96

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 9)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(5)
                .accessibilityLabel(placeholder)
        }
        .frame(minHeight: minHeight)
        .textCursor()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.editorSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}
