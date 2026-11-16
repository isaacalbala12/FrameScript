import AppKit
import FrameScriptCore
import SwiftUI

struct PublishingThumbnailsTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let language: String

    @State private var notes = PublishingThumbnailNotes()
    @State private var errorMessage: String?

    private var pack: PublishingPack {
        appState.publishingPack(language: language)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                imageSection
                conceptSection
                notesSection
            }
            .padding(20)
        }
        .accessibilityIdentifier("publishing-thumbnails-tab")
        .onAppear(perform: loadNotes)
        .onChange(of: language) { _, _ in loadNotes() }
        .onChange(of: notes) { _, newValue in
            let rendered = newValue.rendered()
            guard rendered != appState.publishingPack(language: language).thumbnailConceptNotes else {
                return
            }
            appState.setPublishingThumbnailNotes(newValue, language: language)
        }
    }

    // MARK: - Images

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.localized("publishing.thumbnails.images"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(appState.localized("publishing.thumbnails.imagesHelp"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button {
                    chooseImage()
                } label: {
                    Label(appState.localized("publishing.thumbnails.addImage"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("publishing-add-thumbnail")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if pack.thumbnailVariants.isEmpty {
                Text(appState.localized("publishing.thumbnails.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(Array(pack.thumbnailVariants.enumerated()), id: \.element.id) { index, variant in
                        variantCard(variant, index: index)
                    }
                }
            }
        }
    }

    private func variantCard(_ variant: ThumbnailVariant, index: Int) -> some View {
        let asset = appState.project.assets.first { $0.id == variant.assetID }
        return VStack(alignment: .leading, spacing: 8) {
            PublishingThumbnailCardImage(
                asset: asset,
                projectDirectory: appState.assetProjectDirectory
            )
            .frame(height: 112)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(variant.isChosen ? theme.accent.color : theme.divider, lineWidth: variant.isChosen ? 2 : 1)
            )

            HStack(spacing: 6) {
                Button {
                    appState.setPublishingThumbnailChosen(variant.id, language: language)
                } label: {
                    Image(systemName: variant.isChosen ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(variant.isChosen ? theme.accent.color : theme.tertiaryText)
                }
                .buttonStyle(.plain)

                Text(String(format: appState.localized("publishing.thumbnails.variant"), index + 1))
                    .font(.system(size: 11, weight: .semibold))

                if variant.isChosen {
                    Text(appState.localized("publishing.thumbnails.chosen"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .padding(.horizontal, 4)
                        .frame(height: 15)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.accentSoft)
                        }
                }

                Spacer()

                Button {
                    appState.removePublishingThumbnail(variantID: variant.id, language: language)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help(appState.localized("publishing.thumbnails.remove"))
            }

            TextField(
                appState.localized("publishing.thumbnails.pairedTitle"),
                text: Binding(
                    get: {
                        appState.publishingPack(language: language)
                            .thumbnailVariants
                            .first { $0.id == variant.id }?
                            .pairedTitle ?? ""
                    },
                    set: { appState.setPublishingThumbnailTitle($0, variantID: variant.id, language: language) }
                )
            )
            .textFieldStyle(QuietTextFieldStyle())
            .font(.system(size: 12))
        }
        .padding(10)
        .background(cardBackground)
    }

    // MARK: - Concepts

    private var conceptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.localized("publishing.thumbnails.concepts"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(appState.localized("publishing.thumbnails.conceptsHelp"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                PublishingCopyButton(field: .thumbnailConcept, language: language)
                Button {
                    notes.concepts.append(
                        PublishingThumbnailConcept(label: nextConceptLabel, text: "")
                    )
                } label: {
                    Label(appState.localized("publishing.thumbnails.conceptAdd"), systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
            }

            if notes.concepts.isEmpty {
                Text(appState.localized("publishing.thumbnails.conceptsEmpty"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(cardBackground)
            } else {
                ForEach(Array(notes.concepts.enumerated()), id: \.element.id) { index, _ in
                    conceptCard(index: index)
                }
            }
        }
    }

    private func conceptCard(index: Int) -> some View {
        let concept = notes.concepts[index]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(
                    appState.localized("publishing.thumbnails.conceptLabel"),
                    text: Binding(
                        get: { notes.concepts[index].label },
                        set: { notes.concepts[index].label = $0 }
                    )
                )
                .textFieldStyle(QuietTextFieldStyle())
                .frame(width: 62)
                .font(.system(size: 11))

                TextField(
                    appState.localized("publishing.thumbnails.conceptText"),
                    text: Binding(
                        get: { notes.concepts[index].text },
                        set: { notes.concepts[index].text = $0 }
                    )
                )
                .textFieldStyle(QuietTextFieldStyle())
                .font(.system(size: 12))
                .accessibilityIdentifier("publishing-concept-text-\(index)")

                PublishingCounterLabel(
                    count: concept.wordCount,
                    limit: PublishingLimits.thumbnailTextWordsRecommended,
                    recommended: nil,
                    unit: appState.localized("publishing.unit.words"),
                    warnOnly: true
                )

                Button {
                    notes.concepts.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(appState.localized("publishing.thumbnails.conceptIdea"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 70, alignment: .leading)
                TextField(
                    appState.localized("publishing.thumbnails.conceptIdeaPlaceholder"),
                    text: Binding(
                        get: { notes.concepts[index].idea },
                        set: { notes.concepts[index].idea = $0 }
                    )
                )
                .textFieldStyle(QuietTextFieldStyle())
                .font(.system(size: 11))
            }

            HStack(alignment: .top, spacing: 8) {
                Text(appState.localized("publishing.thumbnails.conceptComposition"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 70, alignment: .leading)
                MultilineField(
                    placeholder: appState.localized("publishing.thumbnails.conceptCompositionPlaceholder"),
                    text: Binding(
                        get: { notes.concepts[index].composition.joined(separator: "\n") },
                        set: { value in
                            notes.concepts[index].composition = value
                                .components(separatedBy: "\n")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                    ),
                    minHeight: 44
                )
            }

            HStack(alignment: .top, spacing: 8) {
                Text(appState.localized("publishing.thumbnails.conceptWhy"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 70, alignment: .leading)
                TextField(
                    appState.localized("publishing.thumbnails.conceptWhyPlaceholder"),
                    text: Binding(
                        get: { notes.concepts[index].whyItWorks },
                        set: { notes.concepts[index].whyItWorks = $0 }
                    )
                )
                .textFieldStyle(QuietTextFieldStyle())
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("publishing.thumbnails.notes"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
            MultilineField(
                placeholder: appState.localized("publishing.thumbnails.notesPlaceholder"),
                text: $notes.notes,
                minHeight: 64
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

    private var nextConceptLabel: String {
        let index = notes.concepts.count
        guard index < 26, let scalar = UnicodeScalar(65 + index) else {
            return "\(index + 1)"
        }
        return String(Character(scalar))
    }

    private func loadNotes() {
        notes = appState.publishingThumbnailNotes(language: language)
    }

    private func chooseImage() {
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = appState.localized("publishing.thumbnails.chooseMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try appState.addPublishingThumbnail(from: url, language: language)
        } catch let error as ThumbnailFileStoreError {
            switch error {
            case .projectNotSaved:
                errorMessage = appState.localized("publishing.thumbnails.error.projectNotSaved")
            case .invalidImage:
                errorMessage = appState.localized("publishing.thumbnails.error.invalidImage")
            case let .copyFailed(reason):
                errorMessage = String(
                    format: appState.localized("publishing.thumbnails.error.copyFailed"),
                    reason
                )
            }
        } catch {
            errorMessage = String(
                format: appState.localized("publishing.thumbnails.error.copyFailed"),
                error.localizedDescription
            )
        }
    }
}

/// Decodes the card image away from the layout pass and only when the file or
/// its modification date changes. A paired-title keystroke no longer triggers a
/// synchronous `NSImage(contentsOf:)` on the main actor (D-4).
private struct PublishingThumbnailCardImage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let asset: ProjectAsset?
    let projectDirectory: URL?

    @State private var model = PublishingThumbnailCardImageModel()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.editorSurface)
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                    if model.hasLoaded, !model.isLoading {
                        Text(appState.localized("publishing.thumbnails.missingFile"))
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(theme.tertiaryText)
            }
        }
        .task(id: ThumbnailCardImageRequest(asset: asset)) {
            await model.update(
                asset: asset,
                projectDirectory: projectDirectory,
                loader: AssetThumbnailCache.shared
            )
        }
    }
}
