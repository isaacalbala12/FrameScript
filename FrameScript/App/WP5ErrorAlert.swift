import AppKit
import SwiftUI

/// Decides which window presents a pending error.
///
/// Both the project window and the Settings window host `ErrorAlertModifier`.
/// The rule is: present in the window that is key when the error appears, and
/// keep presenting it there (the alert's own sheet takes key away from its
/// parent window). Without the second half the alert would dismiss itself.
enum ErrorAlertPresentation {
    static func shouldPresent(hasError: Bool, isPresenting: Bool, isKeyWindow: Bool) -> Bool {
        guard hasError else { return false }
        return isPresenting || isKeyWindow
    }

    /// Latch update when the presented error changes.
    static func presentingAfterErrorChange(
        previousPresenting: Bool,
        newErrorIsNil: Bool,
        isKeyWindow: Bool
    ) -> Bool {
        if newErrorIsNil { return false }
        return previousPresenting || isKeyWindow
    }
}

/// Presents `ErrorCenter`'s current error in the window that owns this view.
///
/// Both the project window and the Settings window host one of these. The
/// alert is presented only by the window that is key when the error appears, so
/// an API-key failure raised from Settings is not shown on the main window
/// behind it (errors E9). `isPresenting` is latched at that moment: attaching a
/// window-modal alert takes key away from the parent window, and without the
/// latch the parent would drop the alert it just presented.
struct ErrorAlertModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var isKeyWindow = false
    @State private var isPresenting = false

    func body(content: Content) -> some View {
        content
            .background {
                WindowKeyReader(isKey: $isKeyWindow)
                    .frame(width: 0, height: 0)
            }
            .onChange(of: appState.errorCenter.presentedError) { _, error in
                isPresenting = ErrorAlertPresentation.presentingAfterErrorChange(
                    previousPresenting: isPresenting,
                    newErrorIsNil: error == nil,
                    isKeyWindow: isKeyWindow
                )
            }
            .alert(item: presentedErrorBinding) { error in
                errorAlert(for: error)
            }
    }

    private var presentedErrorBinding: Binding<AppError?> {
        Binding(
            get: {
                let hasError = appState.errorCenter.presentedError != nil
                guard ErrorAlertPresentation.shouldPresent(
                    hasError: hasError,
                    isPresenting: isPresenting,
                    isKeyWindow: isKeyWindow
                ) else { return nil }
                return appState.errorCenter.presentedError
            },
            set: { newValue in
                guard newValue == nil else { return }
                isPresenting = false
                appState.errorCenter.dismissCurrent()
            }
        )
    }

    private func errorAlert(for error: AppError) -> Alert {
        let presentation = error.presentation(language: appState.currentLanguage)
        let message = [presentation.message, presentation.recoverySuggestion]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        if let action = error.recoveryAction {
            return Alert(
                title: Text(presentation.title),
                message: Text(message),
                primaryButton: .default(Text(appState.localized("recovery.\(action.localizationKey).button"))) {
                    appState.performRecovery(action)
                },
                secondaryButton: .cancel(Text(appState.localized("error.dismiss")))
            )
        }
        return Alert(
            title: Text(presentation.title),
            message: Text(message),
            dismissButton: .default(Text(appState.localized("error.dismiss")))
        )
    }
}

extension View {
    /// Attach the shared error alert to a window root.
    func errorAlert() -> some View {
        modifier(ErrorAlertModifier())
    }
}

/// Reports whether the window hosting this view is currently key.
private struct WindowKeyReader: NSViewRepresentable {
    @Binding var isKey: Bool

    func makeNSView(context: Context) -> WindowKeyTrackingView {
        let view = WindowKeyTrackingView()
        view.onKeyChange = { isKey in
            // Layout can ask again while the binding is already correct.
            guard self.isKey != isKey else { return }
            self.isKey = isKey
        }
        return view
    }

    func updateNSView(_ nsView: WindowKeyTrackingView, context: Context) {
        nsView.onKeyChange = { isKey in
            guard self.isKey != isKey else { return }
            self.isKey = isKey
        }
        nsView.reportCurrentKeyState()
    }
}

private final class WindowKeyTrackingView: NSView {
    var onKeyChange: ((Bool) -> Void)?
    private var observerTokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else {
            report(false)
            return
        }
        let center = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.report(true)
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.report(false)
            }
        ]
        reportCurrentKeyState()
    }

    func reportCurrentKeyState() {
        report(window?.isKeyWindow == true)
    }

    private func report(_ value: Bool) {
        onKeyChange?(value)
    }

    private func stopObserving() {
        let center = NotificationCenter.default
        observerTokens.forEach { center.removeObserver($0) }
        observerTokens.removeAll()
    }
}
