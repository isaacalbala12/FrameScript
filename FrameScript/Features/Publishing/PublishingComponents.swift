import FrameScriptCore
import SwiftUI

struct PublishingSectionHeader: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let title: String
    let field: PublishingField?
    let language: String

    init(_ title: String, field: PublishingField? = nil, language: String) {
        self.title = title
        self.field = field
        self.language = language
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 8)
            if let field {
                PublishingCopyButton(field: field, language: language)
            }
        }
    }
}

struct PublishingCopyButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let field: PublishingField
    let language: String
    @State private var copied = false

    var body: some View {
        Button {
            appState.copyPublishingValue(field, language: language)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.localized(copied ? "publishing.copied" : "publishing.copy"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(copied ? theme.success : theme.tertiaryText)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.hover)
            }
        }
        .buttonStyle(.plain)
        .help(appState.localized("publishing.copy"))
    }
}

struct PublishingCounterLabel: View {
    @Environment(\.frameTheme) private var theme
    let count: Int
    let limit: Int
    var recommended: Int?
    var unit: String = ""
    var warnOnly: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(color)
    }

    private var text: String {
        if warnOnly {
            return unit.isEmpty ? "\(count)" : "\(count) \(unit)"
        }
        return "\(count)/\(limit)" + (unit.isEmpty ? "" : " \(unit)")
    }

    private var color: Color {
        if count > limit, !warnOnly { return theme.destructive }
        if count > limit, warnOnly { return theme.warning }
        if let recommended, count > recommended { return theme.warning }
        return theme.tertiaryText
    }
}

/// Chip editor used for tags and hashtags. Enter adds; the x removes.
struct PublishingTokenEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var tokens: [String]
    let placeholder: String
    var normalize: (String) -> [String] = { value in
        value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
    }

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tokens.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        HStack(spacing: 4) {
                            Text(token)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                tokens.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.tertiaryText)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.hover)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .stroke(theme.divider, lineWidth: 1)
                                )
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(QuietTextFieldStyle())
                    .font(.system(size: 12))
                    .onSubmit(addDraft)
                Button(appState.localized("publishing.add"), action: addDraft)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? theme.tertiaryText : theme.accent.color)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addDraft() {
        let values = normalize(draft)
        guard !values.isEmpty else { return }
        for value in values where !tokens.contains(where: {
            $0.caseInsensitiveCompare(value) == .orderedSame
        }) {
            tokens.append(value)
        }
        draft = ""
    }
}

/// Minimal wrapping HStack for chips. SwiftUI's `Layout` keeps the panel from
/// clipping long tag lists at the 980 pt window width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
