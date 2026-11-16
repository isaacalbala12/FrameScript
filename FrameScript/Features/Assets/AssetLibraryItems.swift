import FrameScriptCore
import SwiftUI

struct AssetGridCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let asset: ProjectAsset
    let isSelected: Bool
    var width: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AssetThumbnailView(asset: asset, cornerRadius: 7)
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipped()

            Text(AssetPath.baseName(asset.path))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: max(0, width - 16), alignment: .leading)

            HStack(spacing: 5) {
                AssetKindBadge(kind: asset.kind, compact: true)
                Spacer(minLength: 2)
                if asset.isLastKnownMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.warning)
                        .help(appState.localized("assets.missing"))
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? theme.selection : theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isSelected ? theme.accent.color.opacity(0.8) : theme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AssetPath.fileName(asset.path))
    }
}

struct AssetListRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let asset: ProjectAsset
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnailView(asset: asset, cornerRadius: 5)
                .frame(width: 58, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(AssetPath.fileName(asset.path))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if asset.isLastKnownMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.warning)
                            .help(appState.localized("assets.missing"))
                    }
                }
                Text(assetPath)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let metadataText {
                Text(metadataText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: 42, alignment: .trailing)
            }

            let links = AssetQuery.linkCount(FrameScriptDocument.ProjectAsset(asset: asset))
            if links > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(links)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(theme.accent.color)
            }

            AssetKindBadge(kind: asset.kind, compact: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? theme.selection : Color.clear)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(AssetPath.fileName(asset.path))
    }

    private var assetPath: String {
        let directory = (asset.path as NSString).deletingLastPathComponent
        return (directory as NSString).abbreviatingWithTildeInPath
    }

    private var metadataText: String? {
        if let duration = AssetFormat.duration(asset.duration) {
            return duration
        }
        return AssetFormat.byteCount(asset.fileSize)
    }
}
