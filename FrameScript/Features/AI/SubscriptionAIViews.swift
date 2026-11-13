import SwiftUI

// MARK: - Progress

/// Inline progress with elapsed time and a Cancel button. Cancelling only
/// stops FrameScript from waiting; T3 may keep the run going (D2).
struct SubscriptionAIProgressView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let runtime: SubscriptionAIRuntime
    var showsCancelledNotice = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activity = runtime.activity {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activityTitle(activity))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(elapsedText(activity, now: context.date))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.secondaryText)
                        Button(appState.localized("settings.ai.subscription.cancel")) {
                            runtime.cancel()
                        }
                        .font(.system(size: 11))
                        .buttonStyle(.borderless)
                        .clickableCursor()
                        .help(appState.localized("settings.ai.subscription.cancelHelp"))
                    }
                }
            }

            if showsCancelledNotice, runtime.lastOutcome == .cancelled, runtime.activity == nil {
                HStack(spacing: 8) {
                    Text(appState.localized("settings.ai.subscription.cancelled"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    Button {
                        runtime.clearOutcome()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .clickableCursor()
                }
            }
        }
    }

    private func activityTitle(_ activity: SubscriptionAIActivity) -> String {
        let task: String
        switch activity.mode {
        case let .completion(subscriptionTask):
            task = appState.localized("aiTask.\(subscriptionTask.rawValue)")
        case .probe:
            task = appState.localized("settings.ai.subscription.activityProbe")
        }
        return String(
            format: appState.localized("settings.ai.subscription.activity"),
            task,
            appState.localized("cliKind.\(activity.kind.rawValue)")
        )
    }

    private func elapsedText(_ activity: SubscriptionAIActivity, now: Date) -> String {
        String(
            format: appState.localized("settings.ai.subscription.elapsed"),
            SubscriptionAIElapsedFormat.string(since: activity.startedAt, now: now)
        )
    }
}

// MARK: - Global overlay

/// Small floating pill for the main window so review/rewrite work is visible
/// and cancellable while the AI review panel is busy.
struct SubscriptionAIActivityOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var runtime = SubscriptionAIRuntime.shared

    var body: some View {
        if runtime.activity != nil || runtime.lastOutcome == .cancelled {
            SubscriptionAIProgressView(runtime: runtime)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                }
                .padding(14)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Exit-2 sheet

struct SubscriptionAIPendingQuestionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let prompt: SubscriptionAIPendingPrompt
    @State private var runtime = SubscriptionAIRuntime.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.localized("settings.ai.subscription.pendingTitle"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            Text(appState.localized("settings.ai.subscription.pendingMessage"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(prompt.question.question)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 220)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }

            if let openError = runtime.openError {
                Text(String(
                    format: appState.localized("settings.ai.subscription.openFailed"),
                    openError
                ))
                .font(.system(size: 11))
                .foregroundStyle(theme.destructive)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(appState.localized("settings.ai.subscription.close")) {
                    runtime.pendingPrompt = nil
                    dismiss()
                }
                .clickableCursor()

                Button(appState.localized("settings.ai.subscription.openInT3")) {
                    Task {
                        await runtime.openPendingInT3()
                        if runtime.pendingPrompt == nil {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .clickableCursor()
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.cardBackground)
    }
}
