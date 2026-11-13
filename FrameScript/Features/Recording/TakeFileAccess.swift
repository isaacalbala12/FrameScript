import AppKit
import Foundation
import QuickLookUI

/// Opens and reveals take files. Manual takes keep a security-scoped bookmark,
/// so every start is balanced with a stop: reveal stops immediately and
/// QuickLook keeps at most one scope alive while its panel is showing.
enum TakeFileAccess {
    struct ResolvedFile {
        let url: URL
        let didStartAccessing: Bool
    }

    static func resolve(_ take: Take) -> ResolvedFile? {
        if let bookmark = take.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                let started = url.startAccessingSecurityScopedResource()
                return ResolvedFile(url: url, didStartAccessing: started)
            }
        }
        guard !take.filePath.isEmpty else { return nil }
        return ResolvedFile(url: URL(fileURLWithPath: take.filePath), didStartAccessing: false)
    }

    static func stopAccessing(_ file: ResolvedFile) {
        if file.didStartAccessing {
            file.url.stopAccessingSecurityScopedResource()
        }
    }

    @MainActor
    @discardableResult
    static func reveal(_ take: Take) -> Bool {
        guard let file = resolve(take) else { return false }
        defer { stopAccessing(file) }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
        return true
    }

    /// QuickLook when the file is readable, otherwise hand the URL to the
    /// system player so a missing preview still does something useful.
    @MainActor
    @discardableResult
    static func play(_ take: Take) -> Bool {
        guard let file = resolve(take),
              FileManager.default.fileExists(atPath: file.url.path)
        else { return false }
        if FileManager.default.isReadableFile(atPath: file.url.path) {
            QuickLookPresenter.shared.present(
                file.url,
                accessURL: file.didStartAccessing ? file.url : nil
            )
            return true
        }
        let opened = NSWorkspace.shared.open(file.url)
        stopAccessing(file)
        return opened
    }
}

/// QuickLook's data-source protocols are Objective-C and call back on the main
/// thread, but they are not annotated, so the class stays nonisolated and
/// guards its single URL with a lock.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    static let shared = QuickLookPresenter()

    private let lock = NSLock()
    private var url: URL?
    private var activeAccessURL: URL?

    @MainActor
    func present(_ url: URL, accessURL: URL?) {
        lock.withLock {
            if let activeAccessURL {
                activeAccessURL.stopAccessingSecurityScopedResource()
            }
            self.url = url
            self.activeAccessURL = accessURL
        }
        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.open(url)
            lock.withLock {
                activeAccessURL?.stopAccessingSecurityScopedResource()
                self.activeAccessURL = nil
            }
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
