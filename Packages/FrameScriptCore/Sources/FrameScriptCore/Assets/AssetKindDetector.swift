import Foundation

/// Coarse media family of an asset, derived from its extension. The app uses
/// this to decide whether it needs a video duration or pixel dimensions.
public enum AssetMediaCategory: String, Codable, Sendable, Hashable {
    case video
    case image
    case audio
    case document
    case other
}

/// Detects a sensible `AssetKind` for a file the user drops or picks.
///
/// Extensions are the primary signal because the library can describe a file
/// that is temporarily missing. File-name conventions refine the result for
/// screen captures and thumbnails, which share extensions with ordinary images.
public enum AssetKindDetector {
    public static func kind(for url: URL) -> FrameScriptDocument.AssetKind {
        kind(forPath: url.path)
    }

    public static func kind(forPath path: String) -> FrameScriptDocument.AssetKind {
        let fileName = AssetPath.fileName(path).lowercased()
        let fileExtension = AssetPath.fileExtension(path)
        switch mediaCategory(forFileExtension: fileExtension) {
        case .video:
            return .camera
        case .audio:
            return .music
        case .image:
            if isScreenshot(fileName) { return .screenshot }
            if isThumbnail(fileName) { return .thumbnail }
            return .graphic
        case .document:
            return .web
        case .other:
            return .web
        }
    }

    public static func mediaCategory(for url: URL) -> AssetMediaCategory {
        mediaCategory(forFileExtension: url.pathExtension.lowercased())
    }

    public static func mediaCategory(forPath path: String) -> AssetMediaCategory {
        mediaCategory(forFileExtension: AssetPath.fileExtension(path))
    }

    public static func mediaCategory(forFileExtension fileExtension: String) -> AssetMediaCategory {
        let fileExtension = fileExtension.lowercased()
        if videoExtensions.contains(fileExtension) { return .video }
        if imageExtensions.contains(fileExtension) { return .image }
        if audioExtensions.contains(fileExtension) { return .audio }
        if documentExtensions.contains(fileExtension) { return .document }
        return .other
    }

    /// Screen-capture file names produced by macOS in English and Spanish.
    private static func isScreenshot(_ fileName: String) -> Bool {
        let prefixes = [
            "screenshot",
            "screen shot",
            "captura de pantalla",
            "captura"
        ]
        return prefixes.contains { fileName.hasPrefix($0) }
    }

    private static func isThumbnail(_ fileName: String) -> Bool {
        let markers = ["thumbnail", "miniatura", "thumb"]
        let base = (fileName as NSString).deletingPathExtension
        return markers.contains { base.contains($0) }
    }

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "mxf",
        "mpg", "mpeg", "wmv", "flv", "3gp", "braw", "r3d", "insv"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp",
        "webp", "avif", "svg", "psd", "ai", "sketch", "fig", "afdesign",
        "xcf", "raw", "dng", "cr2", "nef", "arw", "jxl"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "wav", "aiff", "aif", "m4a", "aac", "flac", "ogg", "opus",
        "caf", "wma", "aifc"
    ]

    private static let documentExtensions: Set<String> = [
        "html", "htm", "webloc", "url", "pdf", "txt", "md", "rtf", "doc",
        "docx", "pages", "csv", "xlsx", "numbers", "pptx", "keynote",
        "json", "xml", "yml", "yaml"
    ]
}
