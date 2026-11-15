import AppKit
import SwiftUI

struct KeyboardShortcutsSettings: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var settings: AppSettings
    @State private var recording: ShortcutCommand?
    @State private var pendingBinding: ShortcutBinding?
    @State private var reassignPrompt: ShortcutReassignPrompt?
    @State private var lifecycle = ShortcutRecordingLifecycle()
    @State private var showResetConfirmation = false
    @State private var reservedShortcutWarning: ShortcutBinding?
    @State private var rejectionHint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(appState.localized("settings.keyboardShortcuts"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button(appState.localized("shortcuts.resetAll")) {
                    lifecycle.stopForAlert()
                    showResetConfirmation = true
                }
                    .font(.system(size: 12))
                    .buttonStyle(.borderless)
                    .disabled(!ShortcutSettingsLayout.canResetAll(
                        customizedCommands: Set(settings.shortcutOverrides.keys), recording: recording
                    ))
                    .clickableCursor(enabled: ShortcutSettingsLayout.canResetAll(
                        customizedCommands: Set(settings.shortcutOverrides.keys), recording: recording
                    ))
            }
            ForEach(ShortcutSettingsLayout.categoryCards) { card in
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.localized(card.category.localizationKey))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                    SettingsCard {
                        ForEach(card.definitions) { definition in
                            row(for: definition)
                        }
                    }
                }
            }
        }
        .alert(appState.localized("shortcuts.resetAll.title"), isPresented: $showResetConfirmation) {
            Button(appState.localized("dialog.ok"), role: .destructive) { settings.resetAllShortcuts() }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) { }
        } message: { Text(appState.localized("shortcuts.resetAll.message")) }
        .alert(appState.localized("shortcuts.reassign.title"), isPresented: isReassignPromptPresented) {
            Button(appState.localized("shortcuts.reassign")) {
                if let prompt = reassignPrompt {
                    switch prompt.action {
                    case let .assign(binding):
                        _ = settings.reassignShortcut(binding, for: prompt.destination)
                    case .reset:
                        _ = settings.reassignFactoryDefault(to: prompt.destination)
                    }
                }
                cancelRecording()
            }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) {
                // Keep both bindings unchanged and end the capture session.
                cancelRecording()
            }
        } message: {
            if let prompt = reassignPrompt {
                Text(String(
                    format: appState.localized("shortcuts.reassign.message"),
                    appState.localized(prompt.conflicting.definition.localizationKey),
                    appState.localized(prompt.destination.definition.localizationKey)
                ))
            }
        }
        .alert(appState.localized("shortcuts.reserved.title"), isPresented: isReservedShortcutWarningPresented) {
            Button(appState.localized("dialog.ok")) { resumeRecordingAfterAlert() }
        } message: {
            if let reservedShortcutWarning {
                Text(String(format: appState.localized("shortcuts.reserved.message"), reservedShortcutWarning.display))
            }
        }
        .onDisappear { lifecycle.viewDidDisappear(); clearRecordingState() }
        .background {
            SettingsWindowCloseTrackingView {
                lifecycle.settingsWindowDidClose()
                clearRecordingState()
            }
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private func row(for definition: ShortcutDefinition) -> some View {
        let state = ShortcutSettingsLayout.rowState(
            for: definition,
            customizedCommands: Set(settings.shortcutOverrides.keys),
            recording: recording
        )

        SettingsRow(appState.localized(definition.localizationKey), isHighlighted: state.isRecording) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    shortcutKeycap(for: definition.command, isRecording: state.isRecording)
                    if state.isRecording {
                        // The local monitor is already running before this field is
                        // inserted. This view exists solely to take first responder
                        // asynchronously once AppKit has attached it to a window.
                        if isWaitingForKey {
                            ShortcutRecordingField()
                                .frame(width: 1, height: 1)
                                .accessibilityLabel(appState.localized("shortcuts.recording"))
                        }

                        if pendingBinding != nil {
                            ShortcutSettingsActionButton(appState.localized("shortcuts.save")) {
                                savePending(for: definition.command)
                            }
                        }
                        ShortcutSettingsActionButton(appState.localized("project.unsaved.cancel")) {
                            cancelRecording()
                        }
                    } else if state.showsEdit {
                        ShortcutSettingsActionButton(appState.localized("shortcuts.edit")) {
                            beginRecording(definition.command)
                        }
                    }
                    if state.showsRemove {
                        ShortcutSettingsActionButton(appState.localized("shortcuts.remove")) {
                            remove(definition.command)
                        }
                    }
                    if state.showsReset {
                        ShortcutSettingsActionButton(appState.localized("shortcuts.reset")) {
                            reset(definition.command)
                        }
                    }
                }
                if state.isRecording, let rejectionHint {
                    Text(rejectionHint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func shortcutKeycap(for command: ShortcutCommand, isRecording: Bool) -> some View {
        let label = isRecording
            ? ShortcutCapturePresentation.label(
                pendingBinding: pendingBinding,
                pressShortcut: appState.localized("shortcuts.pressShortcut")
            )
            : settings.activeShortcut(for: command)?.display ?? appState.localized("shortcuts.notAssigned")
        return Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(theme.panelBackground, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
            .accessibilityLabel(label)
    }

    private func savePending(for command: ShortcutCommand) {
        guard let pendingBinding else { return }
        guard ShortcutRegistry.isAssignable(pendingBinding) else {
            self.pendingBinding = nil
            reservedShortcutWarning = pendingBinding
            lifecycle.stopForAlert()
            return
        }
        if let conflictingCommand = ShortcutRegistry.conflict(
            for: pendingBinding,
            excluding: command,
            overrides: settings.shortcutOverrides
        ) {
            reassignPrompt = .init(
                destination: command,
                conflicting: conflictingCommand,
                action: .assign(pendingBinding)
            )
            lifecycle.stopForAlert()
            return
        }
        _ = settings.setShortcut(pendingBinding, for: command)
        lifecycle.save()
        clearRecordingState()
    }

    private func beginRecording(_ command: ShortcutCommand) {
        // Start suppression synchronously, before the row changes into its visible
        // recording state. First-responder assignment may follow on the next runloop.
        lifecycle.stopForAlert()
        recording = command
        pendingBinding = nil
        reassignPrompt = nil
        reservedShortcutWarning = nil
        rejectionHint = nil
        startCapture(for: command)
    }

    private func startCapture(for command: ShortcutCommand) {
        let recordingState = $recording
        let pendingBindingState = $pendingBinding
        let reassignPromptState = $reassignPrompt
        let reservedWarningState = $reservedShortcutWarning
        let rejectionHintState = $rejectionHint
        let settingsState = $settings
        let state = appState
        let lifecycle = lifecycle
        let session = ShortcutCaptureSession(
            onRecord: { [weak lifecycle] binding in
                // ShortcutCaptureSession has already removed its event monitor,
                // so an alert cannot have its keyboard interaction intercepted.
                guard let lifecycle else { return }
                lifecycle.candidateCaptured()
                guard recordingState.wrappedValue == command else { return }
                rejectionHintState.wrappedValue = nil
                if ShortcutRecordingCoordinator.result(for: binding) == .reserved {
                    pendingBindingState.wrappedValue = nil
                    reservedWarningState.wrappedValue = binding
                    return
                }
                pendingBindingState.wrappedValue = binding
                if let conflictingCommand = ShortcutRegistry.conflict(
                    for: binding,
                    excluding: command,
                    overrides: settingsState.wrappedValue.shortcutOverrides
                ) {
                    reassignPromptState.wrappedValue = .init(
                        destination: command,
                        conflicting: conflictingCommand,
                        action: .assign(binding)
                    )
                }
            },
            onReject: { rejection, binding in
                // Not a terminal state: the monitor keeps listening so the user
                // can add the missing modifier without leaving the row.
                rejectionHintState.wrappedValue = String(
                    format: state.localized(ShortcutRejectionText.localizationKey(for: rejection)),
                    binding.display
                )
            },
            onCancel: { [weak lifecycle] in
                lifecycle?.cancel()
                recordingState.wrappedValue = nil
                pendingBindingState.wrappedValue = nil
                reassignPromptState.wrappedValue = nil
                rejectionHintState.wrappedValue = nil
            }
        )
        lifecycle.start(session)
    }

    private func remove(_ command: ShortcutCommand) {
        lifecycle.stopForAlert()
        settings.clearShortcut(command)
    }

    private func reset(_ command: ShortcutCommand) {
        lifecycle.stopForAlert()
        if let conflictingCommand = settings.resetConflict(for: command) {
            reassignPrompt = .init(destination: command, conflicting: conflictingCommand, action: .reset)
        } else {
            _ = settings.resetShortcut(command)
        }
    }

    private func cancelRecording() {
        lifecycle.cancel()
        clearRecordingState()
    }

    private func clearRecordingState() {
        recording = nil
        pendingBinding = nil
        reassignPrompt = nil
        reservedShortcutWarning = nil
    }

    private var isWaitingForKey: Bool {
        recording != nil
            && reassignPrompt == nil
            && reservedShortcutWarning == nil
            && ShortcutCapturePresentation.showsRecordingField(
                pendingBinding: pendingBinding,
                isCaptureActive: lifecycle.isCaptureActive
            )
    }

    private func resumeRecordingAfterAlert() {
        reservedShortcutWarning = nil
        guard let recording, pendingBinding == nil, reassignPrompt == nil, !lifecycle.isCaptureActive else { return }
        startCapture(for: recording)
    }

    private var isReassignPromptPresented: Binding<Bool> {
        Binding(
            get: { reassignPrompt != nil },
            set: { if !$0 { cancelRecording() } }
        )
    }

    private var isReservedShortcutWarningPresented: Binding<Bool> {
        Binding(
            get: { reservedShortcutWarning != nil },
            set: { if !$0 { resumeRecordingAfterAlert() } }
        )
    }
}

enum ShortcutCapturePresentation {
    static func label(pendingBinding: ShortcutBinding?, pressShortcut: String) -> String {
        pendingBinding?.display ?? pressShortcut
    }

    static func showsRecordingField(pendingBinding: ShortcutBinding?, isCaptureActive: Bool) -> Bool {
        pendingBinding == nil && isCaptureActive
    }
}

/// Localized explanation for a keypress the recorder refused.
enum ShortcutRejectionText {
    static func localizationKey(for rejection: ShortcutRejection) -> String {
        switch rejection {
        case .needsCommandControlOrOption: "shortcuts.rejected.modifiers"
        case .needsCommand: "shortcuts.rejected.command"
        }
    }
}

private struct ShortcutSettingsActionButton: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
            .buttonStyle(.borderless)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
            .clickableCursor()
            .accessibilityLabel(title)
    }
}

struct ShortcutSettingsCategoryCard: Identifiable {
    let category: ShortcutCategory
    let definitions: [ShortcutDefinition]

    var id: ShortcutCategory { category }
}

struct ShortcutSettingsRowState {
    let isCustomized: Bool
    let isRecording: Bool
    let isLocked: Bool

    var showsEdit: Bool { !isRecording && !isLocked }
    var showsReset: Bool { isCustomized && !isLocked }
    /// Removing a shortcut writes an explicit `.unassigned` override instead of
    /// relying on assigning the same key to another command.
    var showsRemove: Bool { showsReset }
}

enum ShortcutSettingsLayout {
    static let categoryCards = ShortcutCategory.allCases.map { category in
        ShortcutSettingsCategoryCard(
            category: category,
            definitions: ShortcutRegistry.definitions
                .filter { $0.category == category }
                .sorted { $0.order < $1.order }
        )
    }

    static func rowState(
        for definition: ShortcutDefinition,
        customizedCommands: Set<ShortcutCommand>,
        recording: ShortcutCommand?
    ) -> ShortcutSettingsRowState {
        ShortcutSettingsRowState(
            isCustomized: customizedCommands.contains(definition.command),
            isRecording: recording == definition.command,
            isLocked: recording != nil
        )
    }

    static func canResetAll(customizedCommands: Set<ShortcutCommand>, recording: ShortcutCommand?) -> Bool {
        !customizedCommands.isEmpty && recording == nil
    }
}

private struct ShortcutRecordingField: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutCaptureView {
        ShortcutCaptureView()
    }
    func updateNSView(_ nsView: ShortcutCaptureView, context: Context) {
        nsView.requestFirstResponder()
    }
}

/// Tracks only the Settings window that hosts this view. It deliberately does
/// not observe unrelated windows, sheets, panels, or alerts.
private struct SettingsWindowCloseTrackingView: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SettingsWindowTrackingView {
        let view = SettingsWindowTrackingView()
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: SettingsWindowTrackingView, context: Context) {
        context.coordinator.onClose = onClose
        context.coordinator.observe(window: nsView.window)
    }

    static func dismantleNSView(_ nsView: SettingsWindowTrackingView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        let observer = SettingsWindowCloseObserver()
        var onClose: (() -> Void)?

        init() {
            observer.onClose = { [weak self] in self?.onClose?() }
        }

        func observe(window: NSWindow?) { observer.observe(window: window) }
        func stop() { observer.stop() }
    }
}

private final class SettingsWindowTrackingView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

/// Notification ownership is scoped to one weakly held Settings window.
final class SettingsWindowCloseObserver: @unchecked Sendable {
    weak private(set) var window: NSWindow?
    var onClose: (() -> Void)?
    private var token: NSObjectProtocol?

    func observe(window: NSWindow?) {
        guard self.window !== window else { return }
        stop()
        guard let window else { return }
        self.window = window
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
        window = nil
    }

    deinit { stop() }
}

private struct ShortcutReassignPrompt: Identifiable {
    enum Action {
        case assign(ShortcutBinding)
        case reset
    }

    let destination: ShortcutCommand
    let conflicting: ShortcutCommand
    let action: Action

    var id: String { "\(destination.rawValue)-\(conflicting.rawValue)" }
}

protocol ShortcutCaptureEventMonitoring: AnyObject {
    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any
    func removeMonitor(_ monitor: Any)
}

private final class AppKitShortcutCaptureEventMonitor: ShortcutCaptureEventMonitoring, @unchecked Sendable {
    static let shared = AppKitShortcutCaptureEventMonitor()

    func addLocalKeyDownMonitor(_ handler: @escaping (NSEvent) -> NSEvent?) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler) as Any
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }
}

/// Owns the recorder lifetime independently from the SwiftUI view state. Keeping
/// this seam small makes every exit path release the local event monitor before
/// the UI can present another control or native alert.
final class ShortcutRecordingLifecycle {
    private var session: ShortcutCaptureSession?

    var isCaptureActive: Bool { session?.isActive == true }

    func start(_ session: ShortcutCaptureSession) {
        stopForAlert()
        self.session = session
        session.start()
    }

    func candidateCaptured() {
        // The session has already stopped itself before invoking onRecord.
        session = nil
    }

    func save() {
        stopForAlert()
    }

    func cancel() {
        stopForAlert()
    }

    func viewDidDisappear() {
        stopForAlert()
    }

    func settingsWindowDidClose() {
        stopForAlert()
    }

    func stopForAlert() {
        session?.stop()
        session = nil
        ShortcutCaptureSession.stopActiveSession()
    }

    deinit { stopForAlert() }
}

enum ShortcutRecordingCoordinator {
    enum CandidateResult: Equatable {
        case accepted
        case reserved
        /// Missing ⌘/⌃/⌥ (character keys) or ⌘ (Delete, arrows).
        case invalid
    }

    static func result(for binding: ShortcutBinding) -> CandidateResult {
        if ShortcutRegistry.rejection(for: binding) != nil { return .invalid }
        return ShortcutRegistry.isAssignable(binding) ? .accepted : .reserved
    }
}

/// A scoped, injectable local monitor that consumes events before SwiftUI
/// commands see them. The coordinator guarantees there is only one recorder.
///
/// The session is a plain, non-`Sendable` object: local event monitors and the
/// Settings view both run on the main thread. Only the process-wide active
/// session pointer is shared, and it lives behind a lock.
final class ShortcutCaptureSession {
    private static let activeSlot = ActiveSessionSlot()

    static var isAnySessionActive: Bool { activeSlot.current()?.isActive == true }

    private let eventMonitor: ShortcutCaptureEventMonitoring
    private let onRecord: (ShortcutBinding) -> Void
    private let onReject: (ShortcutRejection, ShortcutBinding) -> Void
    private let onCancel: () -> Void
    private var monitorToken: Any?

    private(set) var isActive = false

    init(
        eventMonitor: ShortcutCaptureEventMonitoring = AppKitShortcutCaptureEventMonitor.shared,
        onRecord: @escaping (ShortcutBinding) -> Void,
        onReject: @escaping (ShortcutRejection, ShortcutBinding) -> Void = { _, _ in },
        onCancel: @escaping () -> Void
    ) {
        self.eventMonitor = eventMonitor
        self.onRecord = onRecord
        self.onReject = onReject
        self.onCancel = onCancel
    }

    deinit { stop() }

    func start() {
        if Self.activeSlot.current() !== self { Self.activeSlot.current()?.stop() }
        guard !isActive else { return }
        Self.activeSlot.set(self)
        isActive = true
        monitorToken = eventMonitor.addLocalKeyDownMonitor { [weak self] event in
            self?.consume(event)
        }
    }

    func stop() {
        if let monitorToken {
            eventMonitor.removeMonitor(monitorToken)
            self.monitorToken = nil
        }
        isActive = false
        Self.activeSlot.clear(if: self)
    }

    static func stopActiveSession() {
        activeSlot.current()?.stop()
    }

    /// Returning `nil` consumes the event in the local application event loop.
    @discardableResult
    func consume(_ event: NSEvent) -> NSEvent? {
        guard isActive else { return event }
        if event.keyCode == 53 {
            stop()
            onCancel()
            return nil
        }
        if let candidate = ShortcutCaptureParser.candidate(from: event) {
            if let rejection = ShortcutRegistry.rejection(for: candidate) {
                // Keep listening: the user just needs another modifier.
                onReject(rejection, candidate)
                return nil
            }
            // A valid candidate is terminal: it must not continue consuming
            // events while a Save/Cancel state or conflict alert is visible.
            stop()
            onRecord(candidate)
        }
        return nil
    }
}

/// Lock-protected owner of the process-wide active capture session.
private final class ActiveSessionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: ShortcutCaptureSession?

    func current() -> ShortcutCaptureSession? {
        lock.withLock { session }
    }

    func set(_ newValue: ShortcutCaptureSession?) {
        lock.withLock { session = newValue }
    }

    func clear(if expected: ShortcutCaptureSession) {
        lock.withLock {
            if session === expected { session = nil }
        }
    }
}

enum ShortcutCaptureParser {
    /// The binding the physical key would produce, even when it is unusable.
    /// Used to explain the rejection instead of swallowing the keypress.
    static func candidate(from event: NSEvent) -> ShortcutBinding? {
        ShortcutPhysicalKeyMapper.binding(
            for: event.keyCode,
            modifiers: shortcutModifiers(from: event.modifierFlags)
        )
    }

    static func binding(from event: NSEvent) -> ShortcutBinding? {
        guard let candidate = candidate(from: event), candidate.isValid else { return nil }
        return candidate
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<ShortcutModifier> {
        var modifiers: Set<ShortcutModifier> = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }
}

private final class ShortcutCaptureView: NSView {
    override var acceptsFirstResponder: Bool { true }

    func requestFirstResponder() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(self)
        }
    }
}
