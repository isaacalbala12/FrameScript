import SwiftUI

struct AIReviewPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(appState.localized("ai.review"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    appState.settings.editorPreferences.showAIReviewPanel = false
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13))
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)

            Divider()
                .overlay(theme.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if comments.isEmpty {
                        SoftCallout(
                            title: appState.localized("ai.quietTitle"),
                            message: appState.localized("ai.quietMessage")
                        )
                    } else {
                        ForEach(comments.prefix(3)) { comment in
                            AICommentView(comment: comment)
                        }
                    }

                    RhythmReviewSection()

                    if appState.aiState.isAnalyzing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(appState.localized("ai.analyzing"))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                    }

                    Button(appState.localized("ai.analyzeCurrentScene")) {
                        analyzeCurrentScene()
                    }
                    .disabled(appState.aiState.isAnalyzing)
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .padding(.top, 4)

                    if appState.aiState.didFailMostRecentAnalysis {
                        Button(appState.localized("ai.retry")) {
                            analyzeCurrentScene()
                        }
                        .buttonStyle(.cursorPlain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(16)
            }
        }
        .background(theme.background)
    }

    private var comments: [AIComment] {
        appState.selectedScene?.aiComments.filter { $0.status == .new } ?? []
    }

    private func analyzeCurrentScene() {
        Task {
            await appState.analyzeSelectedScene()
        }
    }
}

private struct AICommentView: View {
    @Environment(\.frameTheme) private var theme
    let comment: AIComment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.accent.color)
                    .frame(width: 6, height: 6)
                Text(comment.type)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            Text(comment.message)
                .font(.system(size: 13))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !comment.suggestion.isEmpty {
                Text(comment.suggestion)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.sidebar.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}

private struct SoftCallout: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.sidebar.opacity(0.65))
        }
    }
}
