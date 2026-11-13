import AppKit
import Foundation
import FrameScriptCore
import QuickLookUI

/// Opens, reveals and previews asset files. Assets keep a security-scoped
/// bookmark, so every scope that is opened is closed immediately after use.
enum AssetFileAccess {
    struct Resolved {
        let url: URL
        let didStartAccessing: Bool
    }

    static func resolve(_ asset: ProjectAsset) -> Resolved? {
        let storedPath = AssetPath.normalized(asset.path)
        if !storedPath.isEmpty, FileManager.default.fileExists(atPath: storedPath) {
            let url = URL(fileURLWithPath: storedPath)
            let started = url.startAccessingSecurityScopedResource()
            return Resolved(url: url, didStartAccessing: started)
        }
        guard let bookmarkData = asset.bookmarkData else { return nil }
        var isStale = false
        let url = (try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )) ?? AssetBookmark.resolve(bookmarkData)
        guard let url else { return nil }
        let started = url.startAccessingSecurityScopedResource()
        return Resolved(url: url, didStartAccessing: started)
    }

    static func stopAccessing(_ file: Resolved) {
        if file.didStartAccessing {
            file.url.stopAccessingSecurityScopedResource()
        }
    }

    @MainActor
    @discardableResult
    static func quickLook(_ asset: ProjectAsset) -> Bool {
        guard let file = resolve(asset),
              FileManager.default.fileExists(atPath: file.url.path)
        else { return false }
        QuickLookPresenter.shared.present(
            file.url,
            accessURL: file.didStartAccessing ? file.url : nil
        )
        return true
    }

    @MainActor
    @discardableResult
    static func reveal(_ asset: ProjectAsset) -> Bool {
        guard let file = resolve(asset) else { return false }
        defer { stopAccessing(file) }
        guard FileManager.default.fileExists(atPath: file.url.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
        return true
    }

    @MainActor
    @discardableResult
    static func open(_ asset: ProjectAsset) -> Bool {
        guard let file = resolve(asset) else { return false }
        defer { stopAccessing(file) }
        guard FileManager.default.fileExists(atPath: file.url.path) else { return false }
        return NSWorkspace.shared.open(file.url)
    }
}
