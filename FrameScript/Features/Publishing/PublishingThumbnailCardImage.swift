import AppKit
import FrameScriptCore
import Observation

/// Stable identity of a thumbnail card image. The paired title is deliberately
/// absent: typing it must not re-decode the image (D-4).
struct ThumbnailCardImageRequest: Equatable, Sendable {
    let path: String
    let modifiedAt: Date?

    init(asset: ProjectAsset?) {
        path = asset?.path ?? ""
        modifiedAt = asset?.modifiedAt
    }

    init(path: String, modifiedAt: Date?) {
        self.path = path
        self.modifiedAt = modifiedAt
    }
}

@MainActor
protocol ThumbnailCardImageLoading {
    func image(for asset: ProjectAsset, projectDirectory: URL?) async -> NSImage?
}

extension AssetThumbnailCache: ThumbnailCardImageLoading {}

/// Owns one card's image and only asks the loader when the resource identity
/// changes. Paired-title keystrokes re-render the card but keep the same
/// request, so the image is decoded once.
@MainActor
@Observable
final class PublishingThumbnailCardImageModel {
    private(set) var image: NSImage?
    private(set) var loadCount = 0
    private var loadedRequest: ThumbnailCardImageRequest?

    func update(
        asset: ProjectAsset?,
        projectDirectory: URL?,
        loader: any ThumbnailCardImageLoading
    ) async {
        let request = ThumbnailCardImageRequest(asset: asset)
        guard request != loadedRequest else { return }
        loadedRequest = request
        loadCount += 1
        guard let asset else {
            image = nil
            return
        }
        image = await loader.image(for: asset, projectDirectory: projectDirectory)
    }
}
