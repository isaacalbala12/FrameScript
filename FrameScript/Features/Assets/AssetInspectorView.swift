import AppKit
import FrameScriptCore
import SwiftUI

/// Right-hand inspector for the selected asset: metadata, origin tag, free
/// tags and the scene / visual / take links stored on `ProjectAsset`.
struct AssetInspectorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let assetID: UUID?
    let onLocate: (ProjectAsset) -> Void
    let onRemove: (ProjectAsset) -> Void

    @State private var newTag = ""
    @State private var pixelSize: String?

    private var asset: ProjectAsset? {
        guard let assetID else { return nil }
        return appState.assets.first { $0.id == assetID }
    }

    var body: some View {
        Group {
            if let asset {
                inspector(asset)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panelBackground)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("assets.inspector.empty"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inspector(_ asset: ProjectAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                AssetThumbnailView(asset: asset, cornerRadius: 8)
                    .frame(height: 148)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 5) {
                    Text(AssetPath.fileName(asset.path))
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        AssetKindBadge(kind: asset.kind)
                        if asset.isCopiedIntoProject {
                            Text(appState.localized("assets.copied"))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        Spacer(minLength: 0)
                    }
                }

                if asset.isLastKnownMissing {
                    missingCard(asset)
                }

                actions(asset)

                Divider().overlay(theme.divider)

                sectionTitle(appState.localized("assets.details"))
                kindPicker(asset)
                metadataRows(asset)

                Divider().overlay(theme.divider)

                sectionTitle(appState.localized("assets.tags"))
                tagsSection(asset)

                Divider().overlay(theme.divider)

                sectionTitle(appState.localized("assets.links"))
                linksSection(asset)
            }
            .padding(14)
        }
        .task(id: "\(asset.path)|\(asset.modifiedAt?.timeIntervalSince1970 ?? 0)") {
            pixelSize = nil
            guard AssetKindDetector.mediaCategory(forPath: asset.path) == .image else { return }
            let metadata = await AssetMetadataLoader.shared.load(path: asset.path, bookmarkData: asset.bookmarkData)
            pixelSize = AssetFormat.dimensions(width: metadata.pixelWidth, height: metadata.pixelHeight)
        }
    }

    private func missingCard(_ asset: ProjectAsset) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text(appState.localized("assets.missing"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.warning)
            Text(appState.localized("assets.missing.detail"))
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onLocate(asset)
            } label: {
                Text(appState.localized("assets.locate"))
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.warning.opacity(theme.colorScheme == .dark ? 0.15 : 0.1))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.warning.opacity(0.4), lineWidth: 1)
                }
        }
    }

    private func actions(_ asset: ProjectAsset) -> some View {
        HStack(spacing: 6) {
            iconAction("play.rectangle", help: appState.localized("assets.preview"), disabled: asset.isLastKnownMissing) {
                AssetFileAccess.quickLook(asset, projectDirectory: appState.assetProjectDirectory)
            }
            iconAction("folder", help: appState.localized("assets.reveal"), disabled: asset.isLastKnownMissing) {
                AssetFileAccess.reveal(asset, projectDirectory: appState.assetProjectDirectory)
            }
            iconAction("arrow.triangle.2.circlepath", help: appState.localized("assets.locate"), disabled: false) {
                onLocate(asset)
            }
            Spacer(minLength: 0)
            iconAction("trash", help: appState.localized("assets.remove"), disabled: false, tint: theme.destructive) {
                onRemove(asset)
            }
        }
    }

    private func iconAction(
        _ systemName: String,
        help: String,
        disabled: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 26)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.hover)
                }
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(tint ?? theme.secondaryText)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
            .textCase(.uppercase)
    }

    private func kindPicker(_ asset: ProjectAsset) -> some View {
        Menu {
            ForEach(AssetKind.allCases) { kind in
                Button {
                    appState.setAssetKind(kind, assetID: asset.id)
                } label: {
                    if asset.kind == kind {
                        Label(appState.localized(kind.localizationKey), systemImage: "checkmark")
                    } else {
                        Text(appState.localized(kind.localizationKey))
                    }
                }
            }
        } label: {
            Text("\(appState.localized("assets.details.kind")): \(appState.localized(asset.kind.localizationKey))")
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11))
        .foregroundStyle(theme.primaryText)
        .padding(.horizontal, 8)
        .frame(width: 258, height: 30, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.editorSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                }
        }
        .accessibilityIdentifier("assets-kind-picker")
    }

    @ViewBuilder
    private func metadataRows(_ asset: ProjectAsset) -> some View {
        VStack(spacing: 5) {
            detailRow(appState.localized("assets.details.location"), asset.path, truncate: true)
            if let size = AssetFormat.byteCount(asset.fileSize) {
                detailRow(appState.localized("assets.details.size"), size)
            }
            if let duration = AssetFormat.duration(asset.duration) {
                detailRow(appState.localized("assets.details.duration"), duration)
            }
            if let pixelSize {
                detailRow(appState.localized("assets.details.dimensions"), pixelSize)
            }
            if let modified = AssetFormat.date(asset.modifiedAt) {
                detailRow(appState.localized("assets.details.modified"), modified)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, truncate: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .frame(width: 70, alignment: .leading)
            Group {
                if truncate {
                    Text(value)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(value)
                        .lineLimit(2)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.primaryText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tagsSection(_ asset: ProjectAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if asset.tags.isEmpty {
                Text(appState.localized("assets.tags.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            } else {
                AssetTagFlow(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(asset.tags, id: \.self) { tag in
                        AssetTagChip(title: tag) {
                            appState.removeAssetTag(tag, assetID: asset.id)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .onSubmit { commitTag(asset) }
                    .overlay(alignment: .leading) {
                        if newTag.isEmpty {
                            Text(appState.localized("assets.tags.placeholder"))
                                .font(.system(size: 11))
                                .foregroundStyle(theme.tertiaryText)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.editorSurface)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(theme.divider, lineWidth: 1)
                            }
                    }
                Button {
                    commitTag(asset)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.hover)
                        }
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.secondaryText)
                .disabled(newTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(appState.localized("assets.tags.add"))
            }
        }
    }

    private func commitTag(_ asset: ProjectAsset) {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        appState.addAssetTag(tag, assetID: asset.id)
        newTag = ""
    }

    private func linksSection(_ asset: ProjectAsset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sceneLinks(asset)
            visualLinks(asset)
            takeLinks(asset)
        }
    }

    private func sceneLinks(_ asset: ProjectAsset) -> some View {
        let scenes = appState.project.scenes.sortedByOrder
        let linkedScenes = scenes.filter { asset.linkedSceneIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            linkMenuRow(
                title: appState.localized("assets.links.scenes"),
                count: linkedScenes.count
            ) {
                ForEach(scenes) { scene in
                    Button {
                        appState.toggleAssetSceneLink(assetID: asset.id, sceneID: scene.id)
                    } label: {
                        if asset.linkedSceneIDs.contains(scene.id) {
                            Label(scene.title, systemImage: "checkmark")
                        } else {
                            Text(scene.title)
                        }
                    }
                }
            }
            if !linkedScenes.isEmpty {
                AssetTagFlow(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(linkedScenes) { scene in
                        AssetTagChip(title: scene.title) {
                            appState.toggleAssetSceneLink(assetID: asset.id, sceneID: scene.id)
                        }
                    }
                }
            }
        }
    }

    private func visualLinks(_ asset: ProjectAsset) -> some View {
        let scenes = appState.project.scenes.sortedByOrder.filter { !$0.bRollItems.isEmpty }
        let linked = visualLinkItems(asset)
        return VStack(alignment: .leading, spacing: 6) {
            linkMenuRow(
                title: appState.localized("assets.links.broll"),
                count: linked.count
            ) {
                ForEach(scenes) { scene in
                    Menu(scene.title) {
                        ForEach(scene.bRollItems) { item in
                            Button {
                                appState.toggleAssetBRollLink(assetID: asset.id, bRollItemID: item.id)
                            } label: {
                                if asset.linkedBRollItemIDs.contains(item.id) {
                                    Label(visualTitle(item), systemImage: "checkmark")
                                } else {
                                    Text(visualTitle(item))
                                }
                            }
                        }
                    }
                }
            }
            if !linked.isEmpty {
                AssetTagFlow(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(linked) { entry in
                        AssetTagChip(title: entry.title) {
                            appState.toggleAssetBRollLink(assetID: asset.id, bRollItemID: entry.id)
                        }
                    }
                }
            }
        }
    }

    private func takeLinks(_ asset: ProjectAsset) -> some View {
        let linked = takeLinkItems(asset)
        return VStack(alignment: .leading, spacing: 6) {
            linkMenuRow(
                title: appState.localized("assets.links.takes"),
                count: linked.count
            ) {
                ForEach(appState.project.scenes.sortedByOrder) { scene in
                    Menu(scene.title) {
                        ForEach(scene.takes) { take in
                            takeButton(take: take, asset: asset)
                        }
                        ForEach(scene.languageVariants, id: \.languageCode) { variant in
                            ForEach(variant.takes) { take in
                                takeButton(take: take, asset: asset)
                            }
                        }
                    }
                }
            }
            if !linked.isEmpty {
                AssetTagFlow(horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(linked) { entry in
                        AssetTagChip(title: entry.title) {
                            appState.toggleAssetTakeLink(assetID: asset.id, takeID: entry.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func takeButton(take: Take, asset: ProjectAsset) -> some View {
        Button {
            appState.toggleAssetTakeLink(assetID: asset.id, takeID: take.id)
        } label: {
            if asset.linkedTakeIDs.contains(take.id) {
                Label(takeTitle(take), systemImage: "checkmark")
            } else {
                Text(takeTitle(take))
            }
        }
    }

    private func linkMenuRow<Content: View>(
        title: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Text("\(title) · \(count)")
        }
        .menuStyle(.borderlessButton)
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 8)
        .frame(width: 258, height: 28, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.editorSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                }
        }
    }

    // MARK: Link lookup

    private struct LinkEntry: Identifiable {
        let id: UUID
        let title: String
    }

    private func visualTitle(_ item: BRollItem) -> String {
        let text = item.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? item.sourceType.rawValue : text
    }

    private func takeTitle(_ take: Take) -> String {
        var title = String(format: appState.localized("assets.takeLabel"), take.number)
        let language = take.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            title += " · \(language.uppercased())"
        }
        return title
    }

    private func visualLinkItems(_ asset: ProjectAsset) -> [LinkEntry] {
        var entries: [LinkEntry] = []
        for scene in appState.project.scenes.sortedByOrder {
            for item in scene.bRollItems where asset.linkedBRollItemIDs.contains(item.id) {
                entries.append(LinkEntry(id: item.id, title: visualTitle(item)))
            }
        }
        return entries
    }

    private func takeLinkItems(_ asset: ProjectAsset) -> [LinkEntry] {
        var entries: [LinkEntry] = []
        for scene in appState.project.scenes.sortedByOrder {
            for take in scene.takes where asset.linkedTakeIDs.contains(take.id) {
                entries.append(LinkEntry(id: take.id, title: takeTitle(take)))
            }
            for variant in scene.languageVariants {
                for take in variant.takes where asset.linkedTakeIDs.contains(take.id) {
                    entries.append(LinkEntry(id: take.id, title: takeTitle(take)))
                }
            }
        }
        return entries
    }
}
