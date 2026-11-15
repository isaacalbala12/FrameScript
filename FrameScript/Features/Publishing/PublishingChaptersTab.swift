import FrameScriptCore
import SwiftUI

private struct PendingChapterRegeneration: Identifiable {
    let id = UUID()
    let plan: ChapterPlan
    let diff: ChapterRegenerationDiff
}

struct PublishingChaptersTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let language: String

    @State private var pendingRegeneration: PendingChapterRegeneration?

    private var plan: ChapterPlan {
        appState.publishingChapterPlan(language: language)
    }

    private var scenes: [Scene] {
        appState.project.scenes.sortedByOrder
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                preview
                warnings
                sceneList
            }
            .padding(20)
        }
        .accessibilityIdentifier("publishing-chapters-tab")
        .sheet(item: $pendingRegeneration) { pending in
            ChapterRegenerationSheet(
                diff: pending.diff,
                onKeep: {
                    appState.applyPublishingChapterPlan(
                        pending.plan,
                        language: language,
                        keepingEditedTitles: true
                    )
                    pendingRegeneration = nil
                },
                onReplace: {
                    appState.applyPublishingChapterPlan(
                        pending.plan,
                        language: language,
                        keepingEditedTitles: false
                    )
                    pendingRegeneration = nil
                },
                onCancel: { pendingRegeneration = nil }
            )
            .environment(appState)
            .environment(\.frameTheme, theme)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized("publishing.chapters.title"))
                    .font(.system(size: 16, weight: .semibold))
                Text(appState.localized("publishing.chapters.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            validityBadge

            Button(appState.localized(plan.chapters.isEmpty
                ? "publishing.chapters.generate"
                : "publishing.chapters.regenerate")) {
                regenerate()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent.color)
            .disabled(scenes.isEmpty)
            .accessibilityIdentifier("publishing-regenerate-chapters")
        }
    }

    private var validityBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: plan.isValidForYouTube ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(appState.localized(plan.isValidForYouTube
                ? "publishing.chapters.valid"
                : "publishing.chapters.invalid"))
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(plan.isValidForYouTube ? theme.success : theme.warning)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill((plan.isValidForYouTube ? theme.success : theme.warning).opacity(0.12))
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.localized("publishing.chapters.preview"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button(appState.localized("publishing.copy")) {
                    appState.copyPublishingText(plan.text)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .disabled(plan.text.isEmpty)
            }

            if plan.text.isEmpty {
                Text(appState.localized("publishing.chapters.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(previewBackground)
            } else {
                Text(plan.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(previewBackground)
            }
        }
    }

    private var previewBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.editorSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            )
    }

    // MARK: - Warnings

    @ViewBuilder
    private var warnings: some View {
        if !plan.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized("publishing.chapters.warnings"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.warning)
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.warning)
                            .padding(.top, 3)
                        Text(warning.message)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.warning.opacity(0.10))
            }
        }
    }

    // MARK: - Scene list

    private var sceneList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("publishing.chapters.scenes"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            ForEach(scenes) { scene in
                sceneRow(scene)
            }
        }
    }

    private func sceneRow(_ scene: Scene) -> some View {
        let override = appState.publishingChapterOverride(sceneID: scene.id, language: language)
        let isExcluded = override?.isExcluded ?? false
        let durationInfo = appState.publishingSceneDurationInfo(scene: scene, language: language)
        let isMerged = !isExcluded
            && durationInfo.duration > 0
            && !plan.chapters.contains(where: { $0.sceneID == scene.id })

        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !isExcluded },
                set: { appState.setPublishingChapterIncluded($0, sceneID: scene.id, language: language) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .tint(theme.accent.color)
            .help(appState.localized("publishing.chapters.include"))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(scene.title.isEmpty ? appState.localized("publishing.chapters.untitled") : scene.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isExcluded ? theme.tertiaryText : theme.primaryText)
                        .lineLimit(1)

                    Text(DurationEstimator.formatted(durationInfo.duration))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.horizontal, 4)
                        .frame(height: 16)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.hover)
                        }

                    Text(appState.localized(durationInfo.isReal
                        ? "publishing.chapters.duration.real"
                        : "publishing.chapters.duration.estimate"))
                        .font(.system(size: 9))
                        .foregroundStyle(theme.tertiaryText)

                    if isMerged {
                        Text(appState.localized("publishing.chapters.merged"))
                            .font(.system(size: 9))
                            .foregroundStyle(theme.warning)
                    }
                }

                HStack(spacing: 6) {
                    TextField(
                        appState.localized("publishing.chapters.titlePlaceholder"),
                        text: Binding(
                            get: {
                                appState.publishingChapterOverride(sceneID: scene.id, language: language)?.title ?? ""
                            },
                            set: {
                                appState.setPublishingChapterTitle($0, sceneID: scene.id, language: language)
                            }
                        )
                    )
                    .textFieldStyle(QuietTextFieldStyle())
                    .font(.system(size: 12))
                    .disabled(isExcluded)

                    if !(override?.title ?? "").isEmpty {
                        Button {
                            appState.resetPublishingChapterTitle(sceneID: scene.id, language: language)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(appState.localized("publishing.chapters.resetTitle"))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .opacity(isExcluded ? 0.65 : 1)
    }

    // MARK: - Actions

    private func regenerate() {
        let fresh = appState.publishingChapterPlan(language: language, ignoringOverrideTitles: true)
        let diff = appState.publishingChapterDiff(language: language)
        if diff.hasChanges {
            pendingRegeneration = PendingChapterRegeneration(plan: fresh, diff: diff)
        } else {
            appState.applyPublishingChapterPlan(
                fresh,
                language: language,
                keepingEditedTitles: true
            )
        }
    }
}

struct ChapterRegenerationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let diff: ChapterRegenerationDiff
    let onKeep: () -> Void
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("publishing.chapters.diff.title"))
                    .font(.system(size: 19, weight: .semibold))
                Text(appState.localized("publishing.chapters.diff.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(diff.titleChanges) { change in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(change.oldTitle)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.primaryText)
                                Text("→ \(change.newTitle)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.accent.color)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .background(rowBackground)
                    }

                    if !diff.removedImportedTitles.isEmpty {
                        Text(appState.localized("publishing.chapters.diff.removed"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.warning)
                            .padding(.top, 6)
                        ForEach(diff.removedImportedTitles, id: \.self) { title in
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Button(appState.localized("publishing.cancel"), action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button(appState.localized("publishing.chapters.diff.keep"), action: onKeep)
                    .buttonStyle(.bordered)
                Button(appState.localized("publishing.chapters.diff.replace"), action: onReplace)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent.color)
            }
        }
        .padding(22)
        .frame(width: 580, height: 430)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("publishing-chapter-diff")
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            )
    }
}
