import AppKit
import Foundation
import QuickLookUI

/// Opens and reveals take files. OBS writes outside the sandbox, so a video
/// observed only by path may be readable but not previewable; manual takes keep
/// a security-scoped bookmark from the open panel.
enum TakeFileAccess {
    @MainActor
    static func resolvedURL(for take: Take) -> URL? {
        if let bookmark = take.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if !isStale {
                    _ = url.startAccessingSecurityScopedResource()
                }
                return url
            }
        }
        guard !take.filePath.isEmpty else { return nil }
        return URL(fileURLWithPath: take.filePath)
    }

    @MainActor
    @discardableResult
    static func reveal(_ take: Take) -> Bool {
        guard let url = resolvedURL(for: take) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    /// QuickLook when the file is readable, otherwise hand the URL to the
    /// system player so a sandbox-denied preview still does something useful.
    @MainActor
    @discardableResult
    static func play(_ take: Take) -> Bool {
        guard let url = resolvedURL(for: take),
              FileManager.default.fileExists(atPath: url.path)
        else { return false }
        if FileManager.default.isReadableFile(atPath: url.path) {
            QuickLookPresenter.shared.present(url)
            return true
        }
        return NSWorkspace.shared.open(url)
    }
}

/// QuickLook's data-source protocols are Objective-C and call back on the main
/// thread, but they are not annotated, so the class stays nonisolated and
/// guards its single URL with a lock.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLookPresenter()

    private let lock = NSLock()
    private var url: URL?

    @MainActor
    func present(_ url: URL) {
        lock.withLock { self.url = url }
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        lock.withLock { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> any QLPreviewItem {
        let resolved = lock.withLock { url } ?? URL(fileURLWithPath: "/")
        return resolved as NSURL
    }
}
