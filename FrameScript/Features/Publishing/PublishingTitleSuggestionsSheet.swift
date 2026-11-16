import FrameScriptCore
import SwiftUI

struct PublishingTitleSuggestionsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let language: String
    var suggestionsOverride: [String]?

    @State private var selected: Set<String> = []
    @State private var pendingUse: String?

    init(language: String, suggestions: [String]? = nil) {
        self.language = language
        self.suggestionsOverride = suggestions
    }

    private var suggestions: [String] {
        suggestionsOverride ?? PublishingPresentation.shared.titleSuggestions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("publishing.titles.sheet.title"))
                    .font(.system(size: 19, weight: .semibold))
                Text(appState.localized("publishing.titles.sheet.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            if suggestions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.tertiaryText)
                    Text(appState.localized("publishing.titles.sheet.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            row(suggestion)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button(appState.localized("publishing.cancel")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Text(String(format: appState.localized("publishing.titles.sheet.selected"), selected.count))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)

                Button(appState.localized("publishing.titles.sheet.add")) {
                    appState.addPublishingTitleSuggestions(Array(selected), language: language)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent.color)
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640, height: 520)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("publishing-title-suggestions")
        .alert(
            appState.localized("publishing.titles.confirm.title"),
            isPresented: Binding(
                get: { pendingUse != nil },
                set: { if !$0 { pendingUse = nil } }
            ),
            presenting: pendingUse
        ) { title in
            Button(appState.localized("publishing.titles.confirm.confirm"), role: .destructive) {
                appState.usePublishingTitle(title, language: language)
                pendingUse = nil
                dismiss()
            }
            Button(appState.localized("publishing.cancel"), role: .cancel) {
                pendingUse = nil
            }
        } message: { title in
            Text(String(format: appState.localized("publishing.titles.confirm.message"), title))
        }
    }

    private func row(_ suggestion: String) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { selected.contains(suggestion) },
                set: { isOn in
                    if isOn {
                        selected.insert(suggestion)
                    } else {
                        selected.remove(suggestion)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .tint(theme.accent.color)

            Text(suggestion)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            PublishingCounterLabel(
                count: suggestion.count,
                limit: PublishingLimits.titleMaximum,
                recommended: PublishingLimits.titleRecommended
            )

            Button(appState.localized("publishing.titles.sheet.use")) {
                requestUse(suggestion)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accentText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func requestUse(_ title: String) {
        let current = appState.publishingPack(language: language).chosenTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current.caseInsensitiveCompare(title) == .orderedSame {
            appState.usePublishingTitle(title, language: language)
            dismiss()
        } else {
            pendingUse = title
        }
    }
}
