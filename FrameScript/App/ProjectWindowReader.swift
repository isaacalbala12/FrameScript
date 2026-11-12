import AppKit
import SwiftUI

/// Resolves the window that hosts the main project UI so AppState can listen
/// only to that window's close notification. Settings, teleprompter and backup
/// windows must never trigger the project save/conflict flow.
struct ProjectWindowReader: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: WindowObservingView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }
}

@MainActor
final class WindowObservingView: NSView {
    var onWindowChange: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
