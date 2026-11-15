import Foundation

public enum AssetStoreError: Error, Equatable, Sendable, LocalizedError {
    /// The project has never been saved, so there is no place next to the
    /// `.fscr` file to copy a generated thumbnail into.
    case projectFileMissing
    case sourceMissing
    case cannotCreateDirectory
    case cannotCopy

    public var errorDescription: String? {
        switch self {
        case .projectFileMissing:
            "Save the project before adding a generated thumbnail."
        case .sourceMissing:
            "The thumbnail file does not exist."
        case .cannotCreateDirectory:
            "The project assets folder could not be created."
        case .cannotCopy:
            "The thumbnail could not be copied into the project assets folder."
        }
    }
}

/// Owns the one folder FrameScript writes next to a project: `<Project> assets/`.
///
/// Asset references never copy the media itself. Thumbnails are the deliberate
/// exception: they are small, curated and must travel with the `.fscr` file, so
/// the publishing flow calls ``copyThumbnail(from:projectFileURL:preferredName:)``.
public enum AssetStore {
    public static func assetsDirectoryName(forProjectFile projectFileURL: URL) -> String {
        "\(projectFileURL.deletingPathExtension().lastPathComponent) assets"
    }

    public static func assetsDirectory(forProjectFile projectFileURL: URL) -> URL {
        projectFileURL
            .deletingLastPathComponent()
            .appendingPathComponent(assetsDirectoryName(forProjectFile: projectFileURL), isDirectory: true)
    }

    /// Copies `sourceURL` into the project assets folder and returns the copy.
    ///
    /// An existing file with the same name is replaced so republishing a new
    /// thumbnail does not leave stale copies behind. The returned URL always
    /// points inside the project folder.
    @discardableResult
    public static func copyThumbnail(
        from sourceURL: URL,
        projectFileURL: URL,
        preferredName: String? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AssetStoreError.sourceMissing
        }

        let directory = assetsDirectory(forProjectFile: projectFileURL)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AssetStoreError.cannotCreateDirectory
        }

        let destination = directory.appendingPathComponent(
            destinationName(for: sourceURL, preferredName: preferredName)
        )
        do {
            if destination.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: sourceURL, to: destination)
            }
        } catch {
            throw AssetStoreError.cannotCopy
        }
        return destination
    }

    @discardableResult
    public static func copyThumbnail(
        from sourceURL: URL,
        projectFileURL: URL?,
        preferredName: String? = nil
    ) throws -> URL {
        guard let projectFileURL else { throw AssetStoreError.projectFileMissing }
        return try copyThumbnail(
            from: sourceURL,
            projectFileURL: projectFileURL,
            preferredName: preferredName
        )
    }

    /// Copies a thumbnail and returns the library entry for the copy.
    public static func makeThumbnailAsset(
        from sourceURL: URL,
        projectFileURL: URL?,
        preferredName: String? = nil,
        tags: [String] = []
    ) throws -> FrameScriptDocument.ProjectAsset {
        guard let projectFileURL else { throw AssetStoreError.projectFileMissing }
        return try makeThumbnailAsset(
            from: sourceURL,
            projectFileURL: projectFileURL,
            preferredName: preferredName,
            tags: tags
        )
    }

    /// Copies a thumbnail and returns the library entry for the copy.
    public static func makeThumbnailAsset(
        from sourceURL: URL,
        projectFileURL: URL,
        preferredName: String? = nil,
        tags: [String] = []
    ) throws -> FrameScriptDocument.ProjectAsset {
        let destination = try copyThumbnail(
            from: sourceURL,
            projectFileURL: projectFileURL,
            preferredName: preferredName
        )
        let attributes = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FrameScriptDocument.ProjectAsset(
            path: destination.path,
            bookmarkData: AssetBookmark.make(for: destination),
            kind: .thumbnail,
            tags: AssetTags.normalized(tags),
            isCopiedIntoProject: true,
            fileSize: attributes?.fileSize.map(Int64.init),
            modifiedAt: attributes?.contentModificationDate
        )
    }

    private static func destinationName(for sourceURL: URL, preferredName: String?) -> String {
        let sourceName = sourceURL.lastPathComponent
        let requested = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var name = requested.isEmpty ? sourceName : requested
        name = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = (name as NSString).lastPathComponent
        if (name as NSString).pathExtension.isEmpty {
            let sourceExtension = (sourceName as NSString).pathExtension
            if !sourceExtension.isEmpty {
                name += ".\(sourceExtension)"
            }
        }
        return name.isEmpty ? "thumbnail" : name
    }
}
