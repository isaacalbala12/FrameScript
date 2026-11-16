import AppKit
import SwiftUI

// MARK: - Thumbnail

struct AssetThumbnailView: View {
    @Environment(\.frameTheme) private var theme
    let asset: ProjectAsset
    var cornerRadius: CGFloat = 6
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(theme.editorSurface)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: asset.kind.symbolName)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(theme.tertiaryText)
            }
            if asset.isLastKnownMissing {
                ZStack {
                    Color.black.opacity(0.42)
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        }
        .task(id: "\(asset.path)|\(asset.modifiedAt?.timeIntervalSince1970 ?? 0)") {
            image = await AssetThumbnailCache.shared.image(for: asset)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Kind badge

struct AssetKindBadge: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let kind: AssetKind
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(kind.tint(theme))
                .frame(width: 5, height: 5)
            Text(appState.localized(kind.localizationKey))
                .font(.system(size: compact ? 9 : 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, compact ? 5 : 6)
        .frame(height: compact ? 16 : 18)
        .background {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.hover)
        }
        .accessibilityLabel(appState.localized(kind.localizationKey))
    }
}

extension AssetKind {
    var localizationKey: String { "assets.kind.\(rawValue)" }

    var symbolName: String {
        switch self {
        case .camera: "video"
        case .obs: "record.circle"
        case .screenshot: "camera.viewfinder"
        case .web: "globe"
        case .music: "waveform"
        case .graphic: "photo"
        case .thumbnail: "photo.on.rectangle"
        }
    }

    func tint(_ theme: FrameTheme) -> Color {
        switch self {
        case .camera: theme.bRollMarker
        case .obs: theme.destructive
        case .screenshot: theme.editingMarker
        case .web: theme.secondaryText
        case .music: theme.warning
        case .graphic: theme.accent.color
        case .thumbnail: theme.success
        }
    }
}

// MARK: - Tags

/// A wrapping layout for tag chips. SwiftUI has no built-in flow layout.
struct AssetTagFlow: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        let rows = layout(subviews: subviews, maximumWidth: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = layout(subviews: subviews, maximumWidth: bounds.width)
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
        }
    }

    private struct Row {
        var items: [(index: Int, width: CGFloat)] = []
        var y: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, maximumWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                current.y = rows.last.map { $0.y + $0.height + verticalSpacing } ?? 0
                current.height = current.items.map { item in
                    subviews[item.index].sizeThatFits(.unspecified).height
                }.max() ?? 0
                rows.append(current)
                current = Row()
                x = 0
            }
            current.items.append((index, size.width))
            current.height = max(current.height, size.height)
            x += size.width + horizontalSpacing
        }
        if !current.items.isEmpty {
            current.y = rows.last.map { $0.y + $0.height + verticalSpacing } ?? 0
            rows.append(current)
        }
        return rows
    }
}

struct AssetTagChip: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.tertiaryText)
                .accessibilityLabel(title)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.hover)
        }
    }
}

// MARK: - Formatting

enum AssetFormat {
    static func byteCount(_ bytes: Int64?) -> String? {
        guard let bytes, bytes >= 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func duration(_ interval: TimeInterval?) -> String? {
        guard let interval, interval > 0 else { return nil }
        return DurationEstimator.formatted(interval)
    }

    static func date(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dimensions(width: Int?, height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }
}
