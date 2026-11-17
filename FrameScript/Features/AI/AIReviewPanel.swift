import SwiftUI

struct AIReviewPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        // Legacy standalone wrapper kept for previews and snapshot coverage.
        // The app shell now hosts `AIReviewContent` inside the inspector.
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .overlay(theme.divider)

            AIReviewContent()
        }
        .background(theme.background)
    }

    private var header: some View {
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
            .help(appState.localized("ux.inspector.close"))
            .accessibilityLabel(appState.localized("ux.inspector.close"))
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }
}

/// The legacy AI review content, reused as the inspector's AI tab.
struct AIReviewContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FrameSpacing.m) {
                if comments.isEmpty {
                    // The empty state is one card: the explanation and the
                    // action share the same padding and leading edge.
                    SoftCallout(
                        title: appState.localized("ai.quietTitle"),
                        message: appState.localized("ai.quietMessage")
                    ) {
                        analyzeButton
                    }
                } else {
                    ForEach(comments.prefix(3)) { comment in
                        AICommentView(comment: comment)
                    }
                }

                if appState.aiState.isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(appState.localized("ai.analyzing"))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                }

                if !comments.isEmpty {
                    analyzeButton
                }

                if appState.aiState.didFailMostRecentAnalysis {
                    Button(appState.localized("ai.retry")) {
                        analyzeCurrentScene()
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(FrameLayout.inspectorInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var analyzeButton: some View {
        Button(appState.localized("ai.analyzeCurrentScene")) {
            analyzeCurrentScene()
        }
        .disabled(appState.aiState.isAnalyzing)
        // A bordered button reads as a control, not as a heading, and
        // shows the disabled state while a review is running.
        .buttonStyle(.frameSecondary)
        .help(appState.localized("ai.analyzeCurrentSceneHelp"))
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct SoftCallout<Action: View>: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: FrameSpacing.s) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            action
                .padding(.top, FrameSpacing.xs)
        }
        .padding(FrameLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutProbe("inspector.leading")
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.card, style: .continuous)
                .fill(theme.sidebar.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: FrameRadius.card, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }
}
