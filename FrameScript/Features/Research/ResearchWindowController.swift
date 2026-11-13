import AppKit
import SwiftUI

/// Hosts the research panel in its own window so sources, claims and tables can
/// be edited beside the script without shrinking the editor.
@MainActor
final class ResearchWindowController: NSWindowController, NSWindowDelegate {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        if !window.isVisible, window.frame.origin == .zero {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func configure(_ window: NSWindow) {
        window.title = L10n.tr("research.windowTitle", language: appState.currentLanguage)
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: ResearchWindowRoot(appState: appState)
        )
    }

    func windowWillClose(_ notification: Notification) {
        ResearchWindowPresenter.shared.controllerDidClose(self)
    }
}

@MainActor
final class ResearchWindowPresenter {
    static let shared = ResearchWindowPresenter()

    private weak var appState: AppState?
    private var controller: ResearchWindowController?

    func show(appState: AppState) {
        self.appState = appState
        if let controller {
            controller.present()
            return
        }
        let controller = ResearchWindowController(appState: appState)
        self.controller = controller
        controller.present()
    }

    func close() {
        controller?.close()
        controller = nil
    }

    func controllerDidClose(_ controller: ResearchWindowController) {
        if self.controller === controller {
            self.controller = nil
        }
    }
}

/// Applies the live app theme inside the standalone window. Reading the theme
/// manager here keeps light/dark and accent changes reactive while the window
/// stays open.
struct ResearchWindowRoot: View {
    let appState: AppState

    var body: some View {
        ResearchPanelView()
            .environment(appState)
            .environment(\.frameTheme, appState.themeManager.frameTheme)
            .preferredColorScheme(appState.themeManager.preferredColorScheme)
            .background(appState.themeManager.frameTheme.background)
    }
}
