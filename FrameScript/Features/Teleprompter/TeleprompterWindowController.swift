import AppKit
import FrameScriptCore
import SwiftUI

/// Hosts the teleprompter in its own AppKit window so it can be moved to any
/// display, taken full screen, and closed without disturbing the main window.
@MainActor
final class TeleprompterWindowController: NSWindowController, NSWindowDelegate {
    let model: TeleprompterModel
    weak var presenter: TeleprompterPresenter?

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var pendingDisplayID: UInt32?
    private var pendingReenterFullScreen = false

    init(
        sections: [TeleprompterSection],
        startingSectionIndex: Int,
        language: AppLanguage,
        settingsStore: TeleprompterSettingsStore,
        sceneProvider: TeleprompterSceneProvider?,
        resumeAnchor: TeleprompterReadingAnchor?,
        speechLanguage: SpeechLanguage? = .spanish,
        speechRecognizer: (any SpeechRecognizing)? = nil,
        fallbackWordsPerMinuteProvider: (@MainActor () -> Double?)? = nil
    ) {
        let model = TeleprompterModel(
            sections: sections,
            startingSectionIndex: startingSectionIndex,
            language: language,
            settingsStore: settingsStore,
            sceneProvider: sceneProvider,
            resumeAnchor: resumeAnchor,
            speechLanguage: speechLanguage,
            speechRecognizer: speechRecognizer,
            fallbackWordsPerMinuteProvider: fallbackWordsPerMinuteProvider
        )
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
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
        if let displayID = model.settings.preferredDisplayID,
           let screen = TeleprompterDisplays.screen(for: displayID) {
            window.setFrame(frame(on: screen), display: false)
        } else if let screen = NSScreen.main {
            window.setFrame(frame(on: screen), display: false)
        }
        showWindow(nil)
        bringForward()
    }

    func bringForward() {
        guard let window else { return }
        installMonitors()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.showControlsTemporarily()
    }

    // MARK: Window configuration

    private func configure(_ window: NSWindow) {
        window.title = L10n.tr("teleprompter.windowTitle", language: model.language)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isOpaque = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.minSize = NSSize(width: 720, height: 420)
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: TeleprompterRootView(model: model))

        model.onClose = { [weak self] in self?.close() }
        model.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        model.onMoveToDisplay = { [weak self] displayID in
            self?.move(to: displayID)
        }
    }

    private func frame(on screen: NSScreen) -> NSRect {
        screen.visibleFrame.insetBy(dx: 18, dy: 18)
    }

    // MARK: Full screen and displays

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func move(to displayID: UInt32) {
        guard let window, let screen = TeleprompterDisplays.screen(for: displayID) else { return }
        if window.styleMask.contains(.fullScreen) {
            pendingDisplayID = displayID
            pendingReenterFullScreen = true
            window.toggleFullScreen(nil)
        } else {
            window.setFrame(frame(on: screen), display: true)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        model.setWindowVisible(window.occlusionState.contains(.visible))
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let displayID = pendingDisplayID,
              let window,
              let screen = TeleprompterDisplays.screen(for: displayID) else { return }
        pendingDisplayID = nil
        window.setFrame(frame(on: screen), display: true)
        if pendingReenterFullScreen {
            pendingReenterFullScreen = false
            DispatchQueue.main.async { [weak self] in
                self?.window?.toggleFullScreen(nil)
            }
        }
    }

    // MARK: Monitors

    private func installMonitors() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return self.handleKey(event) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            self.model.showControlsTemporarily()
            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    // MARK: Keyboard

    /// Returns true when the event was consumed by the teleprompter.
    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        // Let focused AppKit controls keep Space and arrow-key behaviour.
        if isControlFocused(in: event), [49, 123, 124, 125, 126, 115, 116, 121].contains(event.keyCode) {
            return false
        }

        switch event.keyCode {
        case 53: // Escape
            model.close()
            return true
        case 49: // Space
            guard !event.isARepeat else { return true }
            model.togglePlayback()
            model.showControlsTemporarily()
            return true
        case 125: // Down arrow
            model.adjustWordsPerMinute(by: -5)
            model.showControlsTemporarily()
            return true
        case 126: // Up arrow
            model.adjustWordsPerMinute(by: 5)
            model.showControlsTemporarily()
            return true
        case 123, 116: // Left arrow, Page Up
            guard !event.isARepeat else { return true }
            model.previousSection()
            model.showControlsTemporarily()
            return true
        case 124, 121: // Right arrow, Page Down
            guard !event.isARepeat else { return true }
            model.nextSection()
            model.showControlsTemporarily()
            return true
        case 115: // Home
            guard !event.isARepeat else { return true }
            model.restartSection()
            model.showControlsTemporarily()
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }

        switch characters {
        case "-":
            model.adjustWordsPerMinute(by: -5)
        case "+", "=":
            model.adjustWordsPerMinute(by: 5)
        case "[":
            model.adjustFontSize(by: -4)
        case "]":
            model.adjustFontSize(by: 4)
        case ";":
            model.adjustColumnWidth(by: -40)
        case "'":
            model.adjustColumnWidth(by: 40)
        case "h", "H":
            guard !event.isARepeat else { return true }
            model.toggleMirrorHorizontal()
        case "m", "M":
            guard !event.isARepeat else { return true }
            model.toggleMirrorVertical()
        case "v", "V":
            guard !event.isARepeat else { return true }
            model.toggleVoiceFollow()
        case "c", "C":
            guard !event.isARepeat else { return true }
            model.toggleCountdown()
        default:
            return false
        }
        model.showControlsTemporarily()
        return true
    }

    private func isControlFocused(in event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        return responder is NSSlider || responder is NSTextField
    }

    // MARK: Lifecycle

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
        model.stop()
        presenter?.controllerDidClose(self)
    }
}

@MainActor
final class TeleprompterPresenter {
    static let shared = TeleprompterPresenter()

    private var controller: TeleprompterWindowController?
    private var lastAnchor: TeleprompterReadingAnchor?

    /// F11 learner hook. Set it from the app; the teleprompter only emits a
    /// session summary when voice following stops.
    var readingSessionReporter: (any TeleprompterReadingSessionReporting)?

    var activeModel: TeleprompterModel? {
        controller?.model
    }

    func show(
        source: TeleprompterSource,
        provider: TeleprompterSceneProvider?,
        startingSectionIndex: Int,
        language: AppLanguage,
        speechLanguage: SpeechLanguage? = .spanish,
        fallbackWordsPerMinuteProvider: (@MainActor () -> Double?)? = nil
    ) {
        if let existing = controller {
            existing.bringForward()
            return
        }

        let sections = source.sections
        guard !sections.isEmpty else { return }

        #if DEBUG
        let simulatedRecognizer = VoiceFollowDebugConfiguration.makeRecognizer()
        #else
        let simulatedRecognizer: (any SpeechRecognizing)? = nil
        #endif

        let controller = TeleprompterWindowController(
            sections: sections,
            startingSectionIndex: startingSectionIndex,
            language: language,
            settingsStore: TeleprompterSettingsStore(),
            sceneProvider: provider,
            resumeAnchor: lastAnchor,
            speechLanguage: speechLanguage,
            speechRecognizer: simulatedRecognizer,
            fallbackWordsPerMinuteProvider: fallbackWordsPerMinuteProvider
        )
        controller.presenter = self
        controller.model.onReadingSessionFinished = { [weak self] session in
            self?.readingSessionReporter?.teleprompterDidFinishReadingSession(session)
        }
        self.controller = controller
        controller.present()

        #if DEBUG
        if VoiceFollowDebugConfiguration.autoStart {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.activeModel?.toggleVoiceFollow()
            }
        }
        #endif
    }

    func controllerDidClose(_ controller: TeleprompterWindowController) {
        if self.controller === controller {
            lastAnchor = controller.model.readingAnchor(
                mirrorVertical: controller.model.settings.mirrorVertical,
                readingLineFraction: controller.model.settings.readingLineFraction
            )
            self.controller = nil
        }
    }

    /// Speech-follower hook: the follower maps its matched text to a content
    /// offset and hands it to the active teleprompter.
    func setVoiceTargetOffset(_ offset: Double?) {
        controller?.model.voiceTargetOffset = offset
    }

    /// Debug-only hook used by the app launch arguments to verify scrolling.
    func playForUITesting() {
        controller?.model.startPlaybackImmediately()
    }

    func closeForUITesting() {
        controller?.close()
    }
}
