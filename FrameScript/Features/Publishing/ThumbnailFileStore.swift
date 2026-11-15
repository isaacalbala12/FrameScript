import AppKit
import Foundation
import FrameScriptCore

enum ThumbnailFileStoreError: Error, Equatable {
    case projectNotSaved
    case invalidImage
    case copyFailed(String)
}

/// Copies a thumbnail the creator picked into the sibling `<Project> assets/`
/// folder and returns a project-relative asset. The real asset manager (F14)
/// may replace this later; the path rules already live in Core.
struct ThumbnailFileStore {
    struct CopyResult {
        let asset: ProjectAsset
        let relativePath: String
    }

    var fileManager: FileManager = .default

    func copyThumbnail(
        from sourceURL: URL,
        projectName: String,
        projectDirectory: URL,
        existingPaths: Set<String>
    ) throws -> CopyResult {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let image = NSImage(contentsOf: sourceURL), image.size.width > 0, image.size.height > 0 else {
            throw ThumbnailFileStoreError.invalidImage
        }

        let directoryName = ThumbnailAssetPath.assetsDirectoryName(projectName: projectName)
        let assetsDirectory = projectDirectory.appendingPathComponent(directoryName, isDirectory: true)
        var existing = existingPaths
        var relativePath = ThumbnailAssetPath.relativePath(
            projectName: projectName,
            originalFileName: sourceURL.lastPathComponent,
            existingPaths: existing
        )
        var destination = projectDirectory.appendingPathComponent(relativePath)
        var attempts = 0
        while fileManager.fileExists(atPath: destination.path), attempts < 100 {
            existing.insert(relativePath)
            relativePath = ThumbnailAssetPath.relativePath(
                projectName: projectName,
                originalFileName: sourceURL.lastPathComponent,
                existingPaths: existing
            )
            destination = projectDirectory.appendingPathComponent(relativePath)
            attempts += 1
        }

        do {
            try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ThumbnailFileStoreError.copyFailed(error.localizedDescription)
        }

        let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let asset = ProjectAsset(
            path: relativePath,
            kind: .thumbnail,
            isCopiedIntoProject: true,
            fileSize: values?.fileSize.map(Int64.init),
            modifiedAt: values?.contentModificationDate
        )
        return CopyResult(asset: asset, relativePath: relativePath)
    }
}
