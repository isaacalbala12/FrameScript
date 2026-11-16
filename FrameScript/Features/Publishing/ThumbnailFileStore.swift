import Foundation

/// Errors the publishing thumbnail flow can show. The copy itself belongs to
/// `AssetStore.makeThumbnailAsset`, which owns the one collision rule and the
/// absolute-path convention shared with the asset library.
enum ThumbnailFileStoreError: Error, Equatable {
    case projectNotSaved
    case invalidImage
    case copyFailed(String)
}
