import FrameScriptCore
import SwiftUI

struct PublishingMetadataTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let language: String

    @State private var presentation = PublishingPresentation.shared
    @State private var showsTitleSuggestions = false
    @State private var pendingTitleReplacement: String?
    @State private var promiseDraft = ""
    @State private var thesisDraft = ""

    private var pack: PublishingPack {
        appState.publishingPack(language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                validationCard

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        promiseAndThesis
                        titleSection
                        titleCandidates
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 18) {
                        descriptionSection
                        tagsSection
                        hashtagsSection
                        pinnedSection
                        communitySection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .accessibilityIdentifier("publishing-metadata-tab")
        .onAppear {
            promiseDraft = appState.publishingPromise
            thesisDraft = appState.publishingThesis
        }
        .onChange(of: promiseDraft) { _, value in
            guard value != appState.publishingPromise else { return }
            appState.setPublishingPromise(value)
        }
        .onChange(of: thesisDraft) { _, value in
            guard value != appState.publishingThesis else { return }
            appState.setPublishingThesis(value)
        }
        .sheet(isPresented: $showsTitleSuggestions) {
            PublishingTitleSuggestionsSheet(language: language)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .alert(
            appState.localized("publishing.titles.confirm.title"),
            isPresented: Binding(
                get: { pendingTitleReplacement != nil },
                set: { if !$0 { pendingTitleReplacement = nil } }
            ),
            presenting: pendingTitleReplacement
        ) { title in
            Button(appState.localized("publishing.titles.confirm.confirm"), role: .destructive) {
                appState.usePublishingTitle(title, language: language)
                pendingTitleReplacement = nil
            }
            Button(appState.localized("publishing.cancel"), role: .cancel) {
                pendingTitleReplacement = nil
            }
        } message: { title in
            Text(String(format: appState.localized("publishing.titles.confirm.message"), title))
        }
    }

    // MARK: - Validation

    @ViewBuilder
    private var validationCard: some View {
        let issues = appState.publishingValidationIssues(language: language)
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(appState.localized("publishing.validation.title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PublishingValidator.hasErrors(issues) ? theme.destructive : theme.warning)

                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: issue.severity == .error
                            ? "exclamationmark.octagon.fill"
                            : "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(issue.severity == .error ? theme.destructive : theme.warning)
                            .padding(.top, 3)
                        Text(appState.localized("publishing.field.\(issue.field.rawValue)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(width: 95, alignment: .leading)
                        Text(String(
                            format: appState.localized("publishing.rule.\(issue.rule.rawValue)"),
                            issue.count,
                            issue.limit
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((PublishingValidator.hasErrors(issues) ? theme.destructive : theme.warning).opacity(0.09))
            }
            .accessibilityIdentifier("publishing-validation-card")
        }
    }

    // MARK: - Promise and thesis

    private var promiseAndThesis: some View {
        VStack(alignment: .leading, spacing: 12) {
            PublishingSectionHeader(
                appState.localized("publishing.field.promise"),
                field: .promise,
                language: language
            )
            TextField(
                appState.localized("publishing.promise.placeholder"),
                text: $promiseDraft
            )
            .textFieldStyle(QuietTextFieldStyle())

            PublishingSectionHeader(
                appState.localized("publishing.field.thesis"),
                field: .thesis,
                language: language
            )
            TextField(
                appState.localized("publishing.thesis.placeholder"),
                text: $thesisDraft
            )
            .textFieldStyle(QuietTextFieldStyle())
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.title"),
                field: .title,
                language: language
            )

            TextField(
                appState.localized("publishing.title.placeholder"),
                text: appState.publishingStringBinding(\.chosenTitle, language: language)
            )
            .textFieldStyle(QuietTextFieldStyle())
            .accessibilityIdentifier("publishing-chosen-title")

            HStack(spacing: 8) {
                PublishingCounterLabel(
                    count: pack.chosenTitle.count,
                    limit: PublishingLimits.titleMaximum,
                    recommended: PublishingLimits.titleRecommended,
                    unit: appState.localized("publishing.unit.characters")
                )

                Spacer()

                Text(appState.localized("publishing.titles.help"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)

                Button {
                    Task {
                        await appState.generatePublishingTitles(language: language)
                        if !PublishingPresentation.shared.titleSuggestions.isEmpty {
                            showsTitleSuggestions = true
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if presentation.isGeneratingTitles {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(appState.localized(presentation.isGeneratingTitles
                            ? "publishing.titles.generating"
                            : "publishing.titles.generate"))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.accentSoft)
                }
                .disabled(presentation.isGeneratingTitles)
                .accessibilityIdentifier("publishing-generate-titles")
            }

            if let error = presentation.titleGenerationError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Candidates

    private var titleCandidates: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.titleCandidates"),
                field: .titleCandidates,
                language: language
            )

            let candidates = pack.titleCandidates
            if candidates.isEmpty {
                Text(appState.localized("publishing.titleCandidates.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { index, candidate in
                    HStack(spacing: 6) {
                        TextField(
                            appState.localized("publishing.titleCandidates.placeholder"),
                            text: Binding(
                                get: {
                                    let current = appState.publishingPack(language: language).titleCandidates
                                    return current.indices.contains(index) ? current[index] : ""
                                },
                                set: { value in
                                    appState.updatePublishingPack(language: language) { pack in
                                        guard pack.titleCandidates.indices.contains(index) else { return }
                                        pack.titleCandidates[index] = value
                                    }
                                }
                            )
                        )
                        .textFieldStyle(QuietTextFieldStyle())

                        Button(appState.localized("publishing.titleCandidates.use")) {
                            requestUse(title: candidate)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .disabled(candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button {
                            appState.updatePublishingPack(language: language) { pack in
                                guard pack.titleCandidates.indices.contains(index) else { return }
                                pack.titleCandidates.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button(appState.localized("publishing.titleCandidates.add")) {
                appState.updatePublishingPack(language: language) { pack in
                    pack.titleCandidates.append("")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.accentText)
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.description"),
                field: .description,
                language: language
            )
            MultilineField(
                placeholder: appState.localized("publishing.description.placeholder"),
                text: appState.publishingStringBinding(\.description, language: language),
                minHeight: 104
            )
            HStack(spacing: 8) {
                PublishingCounterLabel(
                    count: pack.description.count,
                    limit: PublishingLimits.descriptionMaximum,
                    recommended: PublishingLimits.descriptionRecommended,
                    unit: appState.localized("publishing.unit.characters")
                )
                Spacer()
                let studioDescription = appState.publishingStudioDescription(language: language)
                HStack(spacing: 4) {
                    Text(appState.localized("publishing.description.studioLabel"))
                    PublishingCounterLabel(
                        count: studioDescription.count,
                        limit: PublishingLimits.descriptionMaximum,
                        recommended: PublishingLimits.descriptionRecommended,
                        unit: appState.localized("publishing.unit.characters")
                    )
                }
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                Button(appState.localized("publishing.description.copyYouTube")) {
                    appState.copyPublishingText(studioDescription)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.accentText)
                .help(appState.localized("publishing.description.copyYouTubeHelp"))
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Tags

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.tags"),
                field: .tags,
                language: language
            )
            PublishingTokenEditor(
                tokens: appState.publishingArrayBinding(\.tags, language: language),
                placeholder: appState.localized("publishing.tags.placeholder"),
                normalize: { value in value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            )
            HStack(spacing: 8) {
                Text(String(format: appState.localized("publishing.tags.count"), pack.tags.count))
                Spacer()
                PublishingCounterLabel(
                    count: PublishingText.tagCharacterCount(pack.tags),
                    limit: PublishingLimits.tagsCharactersMaximum,
                    recommended: nil,
                    unit: appState.localized("publishing.unit.characters")
                )
            }
            .font(.system(size: 10))
            .foregroundStyle(theme.tertiaryText)
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Hashtags

    private var hashtagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.hashtags"),
                field: .hashtags,
                language: language
            )
            PublishingTokenEditor(
                tokens: appState.publishingArrayBinding(\.hashtags, language: language),
                placeholder: appState.localized("publishing.hashtags.placeholder"),
                normalize: { value in PublishingText.hashtags(from: value) }
            )
            Text(String(format: appState.localized("publishing.hashtags.count"), pack.hashtags.count))
                .font(.system(size: 10))
                .foregroundStyle(pack.hashtags.count > PublishingLimits.hashtagsRecommendedCount ? theme.warning : theme.tertiaryText)
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Pinned comment

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.pinnedComment"),
                field: .pinnedComment,
                language: language
            )
            MultilineField(
                placeholder: appState.localized("publishing.pinnedComment.placeholder"),
                text: appState.publishingStringBinding(\.pinnedComment, language: language),
                minHeight: 68
            )
            PublishingCounterLabel(
                count: pack.pinnedComment.count,
                limit: PublishingLimits.pinnedCommentMaximum,
                recommended: PublishingLimits.pinnedCommentRecommended,
                unit: appState.localized("publishing.unit.characters")
            )
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Community post

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublishingSectionHeader(
                appState.localized("publishing.field.communityPost"),
                field: .communityPost,
                language: language
            )
            MultilineField(
                placeholder: appState.localized("publishing.communityPost.placeholder"),
                text: appState.publishingStringBinding(\.communityPost, language: language),
                minHeight: 78
            )
        }
        .padding(14)
        .background(cardBackground)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(theme.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            )
    }

    private func requestUse(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = pack.chosenTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty || current.caseInsensitiveCompare(trimmed) == .orderedSame {
            appState.usePublishingTitle(trimmed, language: language)
        } else {
            pendingTitleReplacement = trimmed
        }
    }
}
