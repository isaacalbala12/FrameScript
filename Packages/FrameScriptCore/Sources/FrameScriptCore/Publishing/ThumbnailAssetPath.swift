import Foundation

/// Naming rules for thumbnails copied beside the project file. Kept in Core so
/// the same collision and sanitising rules can be tested without touching disk.
public enum ThumbnailAssetPath {
    public static let fallbackProjectName = "Proyecto"
    public static let fallbackFileName = "miniatura"
    public static let fallbackExtension = "png"

    public static func sanitizedProjectName(_ value: String) -> String {
        let cleaned = sanitize(value)
        return cleaned.isEmpty ? fallbackProjectName : cleaned
    }

    public static func assetsDirectoryName(projectName: String) -> String {
        "\(sanitizedProjectName(projectName)) assets"
    }

    /// Returns a project-relative path such as `Vídeo assets/miniatura.png`.
    /// `existingPaths` contains every path already used by the project, so a
    /// second copy of the same file becomes `miniatura 2.png`.
    public static func relativePath(
        projectName: String,
        originalFileName: String,
        existingPaths: Set<String>
    ) -> String {
        let directory = assetsDirectoryName(projectName: projectName)
        var name = (originalFileName as NSString).deletingPathExtension
        if name.hasPrefix(".") { name = "" }
        let fileExtension = (originalFileName as NSString).pathExtension
        let safeName = sanitize(name).isEmpty ? fallbackFileName : sanitize(name)
        let safeExtension = sanitize(fileExtension).isEmpty
            ? fallbackExtension
            : sanitize(fileExtension).lowercased()

        var candidate = "\(directory)/\(safeName).\(safeExtension)"
        var counter = 2
        while existingPaths.contains(candidate) {
            candidate = "\(directory)/\(safeName) \(counter).\(safeExtension)"
            counter += 1
        }
        return candidate
    }

    public static func resolvedURL(relativePath: String, projectDirectory: URL) -> URL {
        projectDirectory.appendingPathComponent(relativePath)
    }

    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let withoutControls = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        return withoutControls
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
