import AppKit
import FrameScriptCore
import SwiftUI

/// Hosts the video board in its own window. The main window keeps the current
/// project open; the board is a library view, not a workspace mode.
@MainActor
final class BoardWindowController: NSWindowController, NSWindowDelegate {
    let store: BoardStore

    init(appState: AppState, store: BoardStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = L10n.tr("board.windowTitle", language: appState.currentLanguage)
        window.minSize = NSSize(width: 980, height: 712)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(
            rootView: BoardWindowContent(store: store)
                .environment(appState)
        )
        if !window.setFrameUsingName("FrameScriptBoardWindow") {
            window.center()
        }
        window.setFrameAutosaveName("FrameScriptBoardWindow")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // The shared store keeps the index for the next opening.
    }
}

/// Applies the current theme to the board window and refreshes it live when the
/// user changes appearance while the window is open.
private struct BoardWindowContent: View {
    @Environment(AppState.self) private var appState
    let store: BoardStore

    var body: some View {
        BoardRootView(
            store: store,
            catalog: BoardCatalogStore.shared,
            plane: PlaneSettingsStore.shared
        )
        .environment(\.frameTheme, appState.themeManager.frameTheme)
        .preferredColorScheme(appState.themeManager.preferredColorScheme)
        .onAppear(perform: updateTheme)
        .onChange(of: appState.settings.theme) { _, _ in updateTheme() }
        .onChange(of: appState.settings.accentColor) { _, _ in updateTheme() }
    }

    private func updateTheme() {
        appState.themeManager.update(
            selectedTheme: appState.settings.theme,
            accentColor: appState.settings.accentColor
        )
    }
}

@MainActor
final class BoardPresenter {
    static let shared = BoardPresenter()

    private var controller: BoardWindowController?

    var isPresented: Bool {
        controller?.window?.isVisible ?? false
    }

    func show(appState: AppState, store: BoardStore = .shared) {
        if let controller {
            controller.present()
            return
        }
        let controller = BoardWindowController(appState: appState, store: store)
        self.controller = controller
        controller.present()
    }

    func close() {
        controller?.close()
        controller = nil
    }
}
