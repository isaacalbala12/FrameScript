import AppKit
import Foundation
import OSLog

/// Receives projects opened from Finder ("Open With", double-click) before the
/// SwiftUI scene and its `AppState` exist, then drains them once the app shell
/// attaches. FrameScript is single-window/single-project: multiple files are
/// opened in order, so the last one wins after the normal unsaved prompt.
@MainActor
final class FrameScriptAppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "ProjectFiles"
    )
    private weak var appState: AppState?
    private var pendingProjectURLs: [URL] = []

    func attach(_ appState: AppState) {
        self.appState = appState
        guard !pendingProjectURLs.isEmpty else { return }
        let urls = pendingProjectURLs
        pendingProjectURLs.removeAll()
        openProjectURLs(urls, in: appState)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueue(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard appState.recording.hasActiveTake else {
            return appState.confirmApplicationTermination() ? .terminateNow : .terminateCancel
        }
        // Finalize the take before the save decision: the save prompt must see
        // the new take entry, otherwise quitting mid-take loses it.
        Task { @MainActor in
            let shouldTerminate = await self.terminationShouldProceed(appState: appState)
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    /// Testable termination order: stop/finalize first, then ask whether to
    /// save. If the user cancels, the take is already closed out but the app
    /// keeps running with the take in the project.
    func terminationShouldProceed(appState: AppState) async -> Bool {
        if appState.recording.hasActiveTake {
            await appState.recording.prepareForTermination()
        }
        return appState.confirmApplicationTermination()
    }

    static func isProjectFile(_ url: URL) -> Bool {
        ["fscr", "framescript"].contains(url.pathExtension.lowercased())
    }

    private func enqueue(_ urls: [URL]) {
        let projectURLs = urls.filter(Self.isProjectFile)
        guard !projectURLs.isEmpty else { return }
        logger.info("Received \(projectURLs.count, privacy: .public) project file open request(s) from Finder.")
        if let appState {
            openProjectURLs(projectURLs, in: appState)
        } else {
            pendingProjectURLs.append(contentsOf: projectURLs)
        }
    }

    private func openProjectURLs(_ urls: [URL], in appState: AppState) {
        for url in urls {
            appState.openProject(at: url)
        }
    }
}
