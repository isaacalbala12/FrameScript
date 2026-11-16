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
    /// A name that is already taken becomes `portada 2.png`, `portada 3.png`, …
    /// An existing file is never replaced: two user images called
    /// `portada.png` must both survive, because each asset entry points at its
    /// own copy. The returned URL always points inside the project folder.
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

        let requestedName = destinationName(for: sourceURL, preferredName: preferredName)
        let destination = availableDestination(
            in: directory,
            name: requestedName,
            fileManager: fileManager
        )
        do {
            if destination.standardizedFileURL.path != sourceURL.standardizedFileURL.path {
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

    /// Same collision rule as `ThumbnailAssetPath`: `name.ext`, then
    /// `name 2.ext`, `name 3.ext`, … Never overwrites an existing file.
    private static func availableDestination(
        in directory: URL,
        name: String,
        fileManager: FileManager
    ) -> URL {
        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        func candidate(_ index: Int) -> URL {
            let fileName: String
            if index <= 1 {
                fileName = name
            } else if fileExtension.isEmpty {
                fileName = "\(base) \(index)"
            } else {
                fileName = "\(base) \(index).\(fileExtension)"
            }
            return directory.appendingPathComponent(fileName)
        }

        var index = 1
        var destination = candidate(index)
        while fileManager.fileExists(atPath: destination.path), index < 10_000 {
            index += 1
            destination = candidate(index)
        }
        return destination
    }
}
