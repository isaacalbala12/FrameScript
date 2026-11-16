import AVFoundation
import AppKit
import Foundation
import FrameScriptCore
import ImageIO
import QuickLookThumbnailing

/// The metadata the library can read from a referenced file without opening it.
struct AssetFileMetadata: Sendable, Equatable {
    var duration: TimeInterval?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteSize: Int64?
    var modifiedAt: Date?

    var isEmpty: Bool {
        duration == nil && pixelWidth == nil && pixelHeight == nil && byteSize == nil && modifiedAt == nil
    }
}

/// Reads file metadata away from the main actor. Video and audio durations come
/// from AVFoundation; image dimensions come from ImageIO. A missing file simply
/// yields empty metadata instead of failing the whole refresh.
actor AssetMetadataLoader {
    static let shared = AssetMetadataLoader()

    func load(path: String, bookmarkData: Data?) async -> AssetFileMetadata {
        await Self.read(path: path, bookmarkData: bookmarkData)
    }

    private nonisolated static func read(path: String, bookmarkData: Data?) async -> AssetFileMetadata {
        var url = URL(fileURLWithPath: AssetPath.normalized(path))
        if path.isEmpty || !FileManager.default.fileExists(atPath: url.path) {
            guard let bookmarkData, let resolved = AssetBookmark.resolve(bookmarkData) else {
                return AssetFileMetadata()
            }
            url = resolved
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AssetFileMetadata()
        }

        var metadata = AssetFileMetadata()
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            metadata.byteSize = values.fileSize.map(Int64.init)
            metadata.modifiedAt = values.contentModificationDate
        }

        let category = AssetKindDetector.mediaCategory(for: url)
        if category == .image {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                metadata.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
                metadata.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
            }
        } else if category == .video || category == .audio {
            metadata.duration = await duration(of: url)
        }
        return metadata
    }

    private nonisolated static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}

/// Small on-demand thumbnail cache backed by Quick Look.
@MainActor
final class AssetThumbnailCache {
    static let shared = AssetThumbnailCache()

    private var images: [String: NSImage] = [:]
    private var failed: Set<String> = []
    private var order: [String] = []
    private let maximumEntries = 150

    func image(for asset: ProjectAsset, projectDirectory: URL? = nil) async -> NSImage? {
        let key = cacheKey(for: asset)
        if let image = images[key] { return image }
        guard !failed.contains(key),
              let resolved = AssetFileAccess.resolve(asset, projectDirectory: projectDirectory)
        else { return nil }
        defer { AssetFileAccess.stopAccessing(resolved) }
        guard FileManager.default.fileExists(atPath: resolved.url.path) else { return nil }

        let request = QLThumbnailGenerator.Request(
            fileAt: resolved.url,
            size: CGSize(width: 320, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            failed.insert(key)
            return nil
        }
        let image = representation.nsImage
        images[key] = image
        order.append(key)
        if order.count > maximumEntries {
            let evicted = order.removeFirst()
            images[evicted] = nil
            failed.remove(evicted)
        }
        return image
    }

    func invalidate(_ asset: ProjectAsset) {
        let key = cacheKey(for: asset)
        images[key] = nil
        failed.remove(key)
        order.removeAll { $0 == key }
    }

#if DEBUG
    /// Snapshot tests draw deterministic synthetic thumbnails instead of
    /// waiting for Quick Look and depending on the host's file types.
    func seedForTesting(_ image: NSImage, for asset: ProjectAsset) {
        let key = cacheKey(for: asset)
        images[key] = image
        failed.remove(key)
        if !order.contains(key) { order.append(key) }
    }
#endif

    private func cacheKey(for asset: ProjectAsset) -> String {
        "\(asset.path)|\(asset.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }
}
