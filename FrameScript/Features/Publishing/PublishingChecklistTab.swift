import FrameScriptCore
import SwiftUI

struct PublishingChecklistTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let language: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(spacing: 6) {
                    ForEach(PublishingChecklistItem.allCases) { item in
                        row(item)
                    }
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("publishing-checklist-tab")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("publishing.checklist.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(appState.localized("publishing.checklist.subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            let progress = appState.publishingChecklistProgress
            HStack(spacing: 8) {
                ProgressView(
                    value: Double(progress.done),
                    total: Double(max(progress.total, 1))
                )
                .progressViewStyle(.linear)
                .tint(theme.accent.color)

                Text(String(format: appState.localized("publishing.checklist.progress"), progress.done, progress.total))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.top, 2)
        }
    }

    private func row(_ item: PublishingChecklistItem) -> some View {
        let isDone = appState.publishingChecklistIsDone(item)
        return Button {
            appState.setPublishingChecklist(item, done: !isDone)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isDone ? theme.success : theme.tertiaryText)

                Text(appState.localized(item.titleKey))
                    .font(.system(size: 12, weight: isDone ? .regular : .medium))
                    .foregroundStyle(isDone ? theme.secondaryText : theme.primaryText)
                    .strikethrough(isDone, color: theme.tertiaryText)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("publishing-checklist-\(item.rawValue)")
    }
}
