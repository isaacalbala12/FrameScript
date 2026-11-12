import AppKit
import OSLog
import SwiftUI

struct ScriptEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable var scene: Scene
    let editorSessionID: UUID
    @State private var notesExpanded = false
    @State private var didApplyInitialNotesVisibility = false
    @State private var didManuallyToggleNotes = false
    @State private var autocompleteState: AutocompleteEditorState = .idle
    @State private var autocompleteIssueDetails = AutocompleteIssueDetailsState()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sceneHeader

            LinkedScriptTextView(
                text: $scene.scriptText,
                sceneID: scene.id,
                editorIdentity: editorSessionID,
                sceneTitle: scene.title,
                autocompleteProvider: appState.settings.aiPreferences.provider,
                autocompleteConfigurationVersion: appState.autocompleteConfigurationVersion,
                autocompleteConfigurationEligibility: appState.autocompleteConfigurationEligibility,
                autocompleteDelay: appState.autocompleteCompletionDelay,
                autocompleteFallbackLanguage: appState.currentLanguage,
                autocompleteState: $autocompleteState,
                loadRestorationState: {
                    appState.editorState.scriptEditorState(sceneID: scene.id, editorIdentity: editorSessionID)
                },
                saveRestorationState: { state in
                    appState.editorState.setScriptEditorState(state, sceneID: scene.id, editorIdentity: editorSessionID)
                },
                markers: productionMarkers,
                fontSize: appState.settings.editorPreferences.fontSize,
                spellcheck: appState.settings.editorPreferences.spellcheck,
                smartQuotes: appState.settings.editorPreferences.smartQuotes,
                placeholder: appState.localized("script.placeholder"),
                textColor: NSColor(theme.primaryText),
                placeholderColor: NSColor(theme.secondaryText.opacity(0.58)),
                backgroundColor: NSColor(theme.editorSurface),
                bRollColor: NSColor(theme.bRollMarker),
                editingColor: NSColor(theme.editingMarker),
                addBRollLabel: appState.localized("production.addBRollForSelection"),
                addEditingLabel: appState.localized("production.addEditingForSelection"),
                onTextCommitted: { previousText, text in
                    appState.commitScriptTextChange(sceneID: scene.id, previousText: previousText, text: text)
                },
                autocomplete: { context in await appState.autocompleteScript(context: context) },
                onTeardown: { appState.flushActiveEditorBoundary(flushEditor: false) },
                markerAction: appState.selectProductionItems,
                addMarkerAction: { mode, anchor in
                    switch mode {
                    case .bRoll:
                        appState.addBRollItem(sceneID: scene.id, anchor: anchor)
                    case .editing:
                        appState.addEditingItem(sceneID: scene.id, anchor: anchor)
                    case .script:
                        break
                    }
                }
            )
            .frame(minHeight: appState.isFocusModeEnabled ? 430 : 390, maxHeight: .infinity)
            .accessibilityLabel(appState.localized("script.accessibilityLabel"))

            DisclosureGroup(isExpanded: Binding(
                get: { notesExpanded },
                set: {
                    notesExpanded = $0
                    didManuallyToggleNotes = true
                }
            )) {
                MultilineField(
                    placeholder: appState.localized("script.notesPlaceholder"),
                    text: $scene.notes,
                    minHeight: 82
                )
                .accessibilityLabel(appState.localized("script.notes"))
            } label: {
                Text(appState.localized("script.notes"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.system(size: 13))
            .tint(theme.secondaryText)
        }
        .frame(maxWidth: ScriptEditorLayout.maximumTextColumnWidth, alignment: .leading)
        .padding(WorkspaceLayout.contentInset(isFocusModeEnabled: appState.isFocusModeEnabled))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.editorSurface)
        .onAppear { applyInitialNotesVisibility() }
        .onChange(of: scene.title) { _, _ in appState.touchProject() }
        .onChange(of: scene.notes) { _, _ in appState.touchProject() }
        .onChange(of: appState.settings.editorPreferences.defaultNotesVisibility) { _, newValue in
            guard !didManuallyToggleNotes else { return }
            notesExpanded = !appState.isFocusModeEnabled && newValue == .expanded
        }
    }

    private var sceneHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(appState.localized("scene.title"), text: $scene.title)
                .textFieldStyle(.plain)
                .font(.system(size: appState.isFocusModeEnabled ? 34 : 30, weight: .semibold))
                .textCursor()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if appState.settings.editorPreferences.showSceneDuration {
                    Text(DurationEstimator.formatted(scene.estimatedDuration))
                    Text(appState.localized("script.estimated"))
                }
                if appState.settings.editorPreferences.showSceneDuration && appState.settings.editorPreferences.showWordCount { Text("·") }
                if appState.settings.editorPreferences.showWordCount { Text("\(wordCount) \(appState.localized("script.words"))") }
                if let issue = activeAutocompleteIssue {
                    if appState.settings.editorPreferences.showSceneDuration || appState.settings.editorPreferences.showWordCount { Text("·") }
                    Button {
                        autocompleteIssueDetails.open()
                    } label: {
                        Text(appState.localized("autocomplete.unavailable.control"))
                            .underline()
                            .foregroundStyle(theme.warning)
                    }
                    .buttonStyle(.plain)
                    .help(autocompleteIssueHelp(issue))
                    .accessibilityLabel(autocompleteIssueHelp(issue))
                    .accessibilityHint(appState.localized("autocomplete.unavailable.detailsHint"))
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .popover(isPresented: $autocompleteIssueDetails.isPresented, arrowEdge: .bottom) {
                        autocompleteIssueDetails(issue)
                    }
                }
                if shouldShowSectionTag {
                    Label("\(appState.localized("script.templateSection")): \(appState.displayName(scene.sectionType))", systemImage: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var wordCount: Int { scene.scriptText.split { $0.isWhitespace || $0.isNewline }.count }

    private var activeAutocompleteIssue: AutocompleteProviderIssue? {
        guard let issue = appState.autocompleteIssue,
              issue.provider == appState.settings.aiPreferences.provider else { return nil }
        return issue
    }

    private func autocompleteIssueHelp(_ issue: AutocompleteProviderIssue) -> String {
        "\(appState.localized("autocomplete.unavailable.title")): \(appState.localized(issue.reason.localizationKey))"
    }

    @ViewBuilder
    private func autocompleteIssueDetails(_ issue: AutocompleteProviderIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("autocomplete.unavailable.title"))
                .font(.system(size: 13, weight: .semibold))
            Text(autocompleteIssueMessage(issue))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if let cooldownDeadline = issue.cooldownDeadline {
                let remaining = max(1, Int(cooldownDeadline.timeIntervalSinceNow.rounded(.up)))
                Text(String(format: appState.localized("autocomplete.unavailable.cooldown"), remaining))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(width: 290, alignment: .leading)
        .padding(12)
    }

    private func autocompleteIssueMessage(_ issue: AutocompleteProviderIssue) -> String {
        if issue.reason == .rateLimited {
            return String(
                format: appState.localized("autocomplete.unavailable.rateLimited.detail"),
                appState.displayName(issue.provider)
            )
        }
        return String(
            format: appState.localized("autocomplete.unavailable.detail"),
            appState.displayName(issue.provider),
            appState.localized(issue.reason.localizationKey)
        )
    }

    private var productionMarkers: [ProductionTextMarker] {
        var markers: [ProductionTextMarker] = []
        for item in scene.bRollItems {
            if let anchor = TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) {
                markers.append(ProductionTextMarker(itemID: item.id, mode: .bRoll, anchor: anchor))
            }
        }
        for item in scene.editingItems {
            if let anchor = TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) {
                markers.append(ProductionTextMarker(itemID: item.id, mode: .editing, anchor: anchor))
            }
        }
        return markers
    }

    private var shouldShowSectionTag: Bool {
        scene.sectionType != .custom && scene.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(appState.displayName(scene.sectionType)) != .orderedSame
    }

    private func applyInitialNotesVisibility() {
        guard !didApplyInitialNotesVisibility else { return }
        didApplyInitialNotesVisibility = true
        notesExpanded = !appState.isFocusModeEnabled && appState.settings.editorPreferences.defaultNotesVisibility == .expanded
    }
}

struct ProductionTextMarker: Hashable {
    var itemID: UUID
    var mode: WorkspaceMode
    var anchor: TextAnchor
}

enum AutocompleteEditorState: Equatable {
    case idle
    case loading
    case suggestion(String)
}

struct AutocompleteIssueDetailsState: Equatable {
    var isPresented = false

    mutating func open() {
        isPresented = true
    }
}

struct AutocompleteRequestSnapshot: Equatable {
    let sceneID: UUID
    let editorIdentity: UUID
    let requestGeneration: Int
    let textRevision: Int
    let sourceText: String
    let caretLocation: Int
    let selectionLength: Int

    var range: NSRange { NSRange(location: caretLocation, length: selectionLength) }
}

enum AutocompleteEligibilityReason: String {
    case eligiblePhysicalEnd
    case eligibleTrailingWhitespace
    case blockedSelection
    case blockedMarkedText
    case blockedVisibleSuffix
}

struct AutocompleteEligibility {
    let reason: AutocompleteEligibilityReason
    let suffixCharacterCount: Int

    var isEligible: Bool {
        reason == .eligiblePhysicalEnd || reason == .eligibleTrailingWhitespace
    }
}

enum AutocompleteConfigurationEligibility: String, Equatable {
    case eligible
    case blockedPreferenceDisabled
    case blockedProviderDisabled
    case blockedMissingKeyMetadata
    case blockedCooldown

    var isEligible: Bool { self == .eligible }
}

@MainActor
func autocompleteEligibility(in textView: NSTextView) -> AutocompleteEligibility {
    let selectedRange = textView.selectedRange()
    let text = textView.string as NSString
    let length = text.length
    let caret = min(max(0, selectedRange.location), length)
    let suffixRange = NSRange(location: caret, length: length - caret)

    guard selectedRange.length == 0 else {
        return AutocompleteEligibility(reason: .blockedSelection, suffixCharacterCount: suffixRange.length)
    }
    guard !textView.hasMarkedText() else {
        return AutocompleteEligibility(reason: .blockedMarkedText, suffixCharacterCount: suffixRange.length)
    }
    guard suffixRange.length > 0 else {
        return AutocompleteEligibility(reason: .eligiblePhysicalEnd, suffixCharacterCount: 0)
    }
    let visibleSuffix = text.rangeOfCharacter(
        from: CharacterSet.whitespacesAndNewlines.inverted,
        options: [],
        range: suffixRange
    )
    guard visibleSuffix.location == NSNotFound else {
        return AutocompleteEligibility(reason: .blockedVisibleSuffix, suffixCharacterCount: suffixRange.length)
    }
    return AutocompleteEligibility(reason: .eligibleTrailingWhitespace, suffixCharacterCount: suffixRange.length)
}

@MainActor
func isAutocompleteEligible(in textView: NSTextView) -> Bool {
    autocompleteEligibility(in: textView).isEligible
}

func isAutocompleteSnapshotCurrent(
    _ snapshot: AutocompleteRequestSnapshot,
    sceneID: UUID,
    editorIdentity: UUID,
    textRevision: Int,
    sourceText: String,
    selectedRange: NSRange,
    hasMarkedText: Bool
) -> Bool {
    snapshot.sceneID == sceneID
        && snapshot.editorIdentity == editorIdentity
        && snapshot.textRevision == textRevision
        && snapshot.sourceText == sourceText
        && snapshot.caretLocation == selectedRange.location
        && snapshot.selectionLength == selectedRange.length
        && !hasMarkedText
}

struct LinkedScriptTextView: NSViewRepresentable {
    @Binding var text: String
    let sceneID: UUID
    let editorIdentity: UUID
    let sceneTitle: String
    let autocompleteProvider: AIProviderKind
    let autocompleteConfigurationVersion: Int
    let autocompleteConfigurationEligibility: AutocompleteConfigurationEligibility
    let autocompleteDelay: Duration
    let autocompleteFallbackLanguage: AppLanguage
    @Binding var autocompleteState: AutocompleteEditorState
    let loadRestorationState: () -> ScriptEditorRestorationState?
    let saveRestorationState: (ScriptEditorRestorationState) -> Void
    let markers: [ProductionTextMarker]
    let fontSize: Double
    let spellcheck: Bool
    let smartQuotes: Bool
    let placeholder: String
    let textColor: NSColor
    let placeholderColor: NSColor
    let backgroundColor: NSColor
    let bRollColor: NSColor
    let editingColor: NSColor
    let addBRollLabel: String
    let addEditingLabel: String
    let onTextCommitted: (String, String) -> Void
    let autocomplete: @MainActor (AutocompleteContext) async -> AutocompleteResult
    let onTeardown: () -> Void
    let markerAction: ([UUID], WorkspaceMode) -> Void
    let addMarkerAction: (WorkspaceMode, TextAnchor) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MarkerTextContainerView {
        let view = MarkerTextContainerView()
        context.coordinator.attach(to: view)
        view.textView.delegate = context.coordinator
        context.coordinator.applyModelTextIfNeeded()
        configureAppearance(view)
        view.markerTextRevision = context.coordinator.textRevision
        ActiveScriptEditorSession.shared.register(context.coordinator)
        DispatchQueue.main.async {
            context.coordinator.restoreEditorStateIfAvailable()
            view.textView.window?.makeFirstResponder(view.textView)
        }
        return view
    }

    func updateNSView(_ view: MarkerTextContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyModelTextIfNeeded()
        configureAppearance(view)
        view.markerTextRevision = context.coordinator.textRevision
    }

    static func dismantleNSView(_ view: MarkerTextContainerView, coordinator: Coordinator) {
        coordinator.commitMarkedTextAndFlush()
        coordinator.cancelAutocomplete()
        ActiveScriptEditorSession.shared.unregister(coordinator)
        coordinator.parent.onTeardown()
        if view.textView.delegate === coordinator { view.textView.delegate = nil }
        coordinator.detach(from: view)
    }

    private func configureAppearance(_ view: MarkerTextContainerView) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let typographyChanged = view.cachedFontSize != fontSize
        if view.textView.font != font { view.textView.font = font }
        view.textView.textColor = textColor
        view.textView.backgroundColor = backgroundColor
        view.scrollView.backgroundColor = backgroundColor
        view.textView.isContinuousSpellCheckingEnabled = spellcheck
        view.textView.isAutomaticQuoteSubstitutionEnabled = smartQuotes
        let paragraph = ScriptEditorLayout.paragraphStyle()
        view.textView.defaultParagraphStyle = paragraph
        view.textView.typingAttributes[.paragraphStyle] = paragraph
        if typographyChanged, let storage = view.textView.textStorage, storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
        }
        view.cachedFontSize = fontSize
        view.textView.placeholder = placeholder
        view.textView.placeholderColor = placeholderColor
        view.markers = markers
        view.bRollColor = bRollColor
        view.editingColor = editingColor
        view.addBRollLabel = addBRollLabel
        view.addEditingLabel = addEditingLabel
        view.markerNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
#if DEBUG
        private static let autocompleteLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Autocomplete")
#endif
        enum ChangeOrigin {
            case user
            case externalModel
            case programmaticTextView
        }

        private struct EditTransaction {
            let textRevision: Int
            let expectedSelection: NSRange
        }

        private struct EscapeDismissalContext: Equatable {
            let sourceText: String
            let textRevision: Int
            let caretLocation: Int
        }

        var parent: LinkedScriptTextView
        weak var view: MarkerTextContainerView?
        private(set) var changeOrigin: ChangeOrigin = .externalModel
        private(set) var lastUserEmittedValue: String?
        private var lastObservedModelValue: String
        private var pendingUserRevision: Int?
        private var userRevision = 0
        private var modelRevision = 0
        private(set) var textRevision = 0
        private var isApplyingProgrammaticUpdate = false
        private var pendingInitialRestorationState: ScriptEditorRestorationState?
        private var autocompleteTask: Task<Void, Never>?
        private(set) var autocompleteRequestGeneration = 0
        private var autocompleteSnapshot: AutocompleteRequestSnapshot?
        private var editTransaction: EditTransaction?
        private var lastSelectionRange: NSRange?
        private var escapeDismissalContext: EscapeDismissalContext?
        private var observedAutocompleteProvider: AIProviderKind
        private var observedAutocompleteConfigurationVersion: Int
        private var observedAutocompleteConfigurationEligibility: AutocompleteConfigurationEligibility
        init(parent: LinkedScriptTextView) {
            self.parent = parent
            self.lastObservedModelValue = parent.text
            self.observedAutocompleteProvider = parent.autocompleteProvider
            self.observedAutocompleteConfigurationVersion = parent.autocompleteConfigurationVersion
            self.observedAutocompleteConfigurationEligibility = parent.autocompleteConfigurationEligibility
        }

        func attach(to view: MarkerTextContainerView) {
            self.view = view
            view.coordinator = self
            view.textView.ghostAction = { [weak self] action in self?.handleGhostAction(action) }
            pendingInitialRestorationState = parent.loadRestorationState()
            lastSelectionRange = view.textView.selectedRange()
        }

        func detach(from view: MarkerTextContainerView) {
            if self.view === view { self.view = nil }
            if view.coordinator === self { view.coordinator = nil }
            view.textView.ghostAction = nil
        }

        @discardableResult
        func commitMarkedTextAndFlush() -> Bool {
            guard let textView = view?.textView else { return false }
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            let changed = emitCurrentText(from: textView, origin: .user)
            captureRestorationState(force: true)
            return changed
        }

        func captureRestorationState(force: Bool = false) {
            guard let view, force || pendingInitialRestorationState == nil else { return }
            view.layoutSubtreeIfNeeded()
            let visibleOrigin = clampedVisibleOrigin(view.scrollView.contentView.bounds.origin, in: view)
            view.scrollView.contentView.scroll(to: visibleOrigin)
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
            parent.saveRestorationState(ScriptEditorRestorationState(
                selectedRange: view.textView.selectedRange(),
                visibleOrigin: visibleOrigin
            ))
        }

        func restoreEditorStateIfAvailable() {
            guard let view, let state = pendingInitialRestorationState ?? parent.loadRestorationState() else { return }
            let length = (view.textView.string as NSString).length
            view.textView.setSelectedRange(TextAnchorGeometry.clamp(state.selectedRange, toLength: length))
            view.layoutSubtreeIfNeeded()
            view.scrollView.contentView.scroll(to: clampedVisibleOrigin(state.visibleOrigin, in: view))
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
            pendingInitialRestorationState = nil
        }

        func applyModelTextIfNeeded() {
            guard let view else { return }
            if observedAutocompleteProvider != parent.autocompleteProvider
                || observedAutocompleteConfigurationVersion != parent.autocompleteConfigurationVersion
                || observedAutocompleteConfigurationEligibility != parent.autocompleteConfigurationEligibility {
                observedAutocompleteProvider = parent.autocompleteProvider
                observedAutocompleteConfigurationVersion = parent.autocompleteConfigurationVersion
                observedAutocompleteConfigurationEligibility = parent.autocompleteConfigurationEligibility
                cancelAutocomplete(clearStatus: true)
            }
            let textView = view.textView
            let modelText = parent.text
            guard textView.string != modelText else {
                lastObservedModelValue = modelText
                pendingUserRevision = nil
                return
            }

            let hasMarkedText = textView.hasMarkedText()
            let isUnacknowledgedUserRevision = pendingUserRevision != nil
                && lastUserEmittedValue == textView.string
                && modelText == lastObservedModelValue
            if hasMarkedText || isUnacknowledgedUserRevision {
                if isUnacknowledgedUserRevision { parent.text = textView.string }
                return
            }

            cancelAutocomplete()

            modelRevision += 1
            textRevision += 1
            view.markerTextRevision = textRevision
            editTransaction = nil
            pendingUserRevision = nil
            lastObservedModelValue = modelText
            changeOrigin = .programmaticTextView
            isApplyingProgrammaticUpdate = true
            let selectedRange = textView.selectedRange()
            let visibleOrigin = view.scrollView.contentView.bounds.origin
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            textView.string = modelText
            undoManager?.enableUndoRegistration()
            textView.setSelectedRange(TextAnchorGeometry.clamp(selectedRange, toLength: (modelText as NSString).length))
            view.layoutSubtreeIfNeeded()
            view.scrollView.contentView.scroll(to: clampedVisibleOrigin(visibleOrigin, in: view))
            isApplyingProgrammaticUpdate = false
            changeOrigin = .externalModel
            captureRestorationState()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingProgrammaticUpdate else { return }
            _ = emitCurrentText(from: textView, origin: .user, forceCommit: true)
            escapeDismissalContext = nil
            autocompleteRequestGeneration += 1
            editTransaction = EditTransaction(
                textRevision: textRevision,
                expectedSelection: textView.selectedRange()
            )
            lastSelectionRange = textView.selectedRange()
            scheduleAutocomplete(for: textView, requestGeneration: autocompleteRequestGeneration)
            view?.markerTextRevision = textRevision
            view?.needsDisplay = true
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() { textView.unmarkText() }
            _ = emitCurrentText(from: textView, origin: .user)
            cancelAutocomplete()
            captureRestorationState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let selectedRange = textView.selectedRange()
            let previousRange = lastSelectionRange
            lastSelectionRange = selectedRange
            guard previousRange != selectedRange else {
                logAutocompleteOutcome("preservedNoOpSelection", in: textView, generation: autocompleteRequestGeneration)
                captureRestorationState()
                return
            }

            let eligibility = autocompleteEligibility(in: textView)
            guard eligibility.isEligible else {
                editTransaction = nil
                escapeDismissalContext = nil
                cancelAutocomplete()
                logAutocompleteOutcome("cancelledCaretMoved", in: textView, generation: autocompleteRequestGeneration)
                captureRestorationState()
                return
            }

            if let editTransaction,
               editTransaction.textRevision == textRevision,
               editTransaction.expectedSelection == selectedRange {
                captureRestorationState()
                return
            }

            editTransaction = nil
            if isEscapeDismissed(at: selectedRange, in: textView) {
                logAutocompleteOutcome("blockedEscapeDismissal", in: textView, generation: autocompleteRequestGeneration)
                captureRestorationState()
                return
            }
            autocompleteRequestGeneration += 1
            cancelAutocomplete()
            logAutocompleteOutcome("scheduledCaretReturned", in: textView, generation: autocompleteRequestGeneration)
            scheduleAutocomplete(for: textView, requestGeneration: autocompleteRequestGeneration)
            captureRestorationState()
        }

        @discardableResult
        private func emitCurrentText(from textView: NSTextView, origin: ChangeOrigin, forceCommit: Bool = false) -> Bool {
            let value = textView.string
            let previousValue = parent.text
            let changed = previousValue != value
            changeOrigin = origin
            lastUserEmittedValue = value
            if origin == .user {
                userRevision += 1
                textRevision += 1
                pendingUserRevision = userRevision
            }
            parent.text = value
            if changed || forceCommit { parent.onTextCommitted(previousValue, value) }
            return changed
        }

        func cancelAutocomplete(clearStatus: Bool = false) {
            autocompleteTask?.cancel()
            autocompleteTask = nil
            autocompleteSnapshot = nil
            view?.textView.ghostText = ""
            if clearStatus || parent.autocompleteState == .loading || isSuggestionVisible {
                parent.autocompleteState = .idle
            }
        }

        private var isSuggestionVisible: Bool {
            if !(view?.textView.ghostText.isEmpty ?? true) { return true }
            if case .suggestion = parent.autocompleteState { return true }
            return false
        }

        private func scheduleAutocomplete(for textView: NSTextView, requestGeneration: Int) {
            guard parent.autocompleteConfigurationEligibility.isEligible else {
                cancelAutocomplete()
                logAutocompleteOutcome(parent.autocompleteConfigurationEligibility.rawValue, in: textView, generation: requestGeneration)
                return
            }
            let eligibility = autocompleteEligibility(in: textView)
            guard eligibility.isEligible else {
                cancelAutocomplete()
                logAutocompleteOutcome(eligibility.reason.rawValue, in: textView, generation: requestGeneration)
                return
            }
            if hasValidVisibleSuggestion(in: textView) {
                logAutocompleteOutcome("blockedVisibleSuggestion", in: textView, generation: requestGeneration)
                return
            }
            if hasValidPendingRequest(in: textView) {
                logAutocompleteOutcome("blockedPendingRequest", in: textView, generation: requestGeneration)
                return
            }
            cancelAutocomplete()
            let source = textView.string
            let selectedRange = textView.selectedRange()
            let caret = selectedRange.location
            let prefix = (source as NSString).substring(to: min(caret, (source as NSString).length))
            let suffixStart = min(caret, (source as NSString).length)
            let suffix = (source as NSString).substring(from: suffixStart)
            let contextPrefix = String(prefix.suffix(600))
            guard contextPrefix.count >= 12 else { return }
            let context = AutocompleteContext(
                prefix: contextPrefix,
                suffix: String(suffix.prefix(300)),
                sceneTitle: parent.sceneTitle,
                language: PromptBuilder().responseLanguage(for: prefix, fallback: parent.autocompleteFallbackLanguage)
            )
            let snapshot = AutocompleteRequestSnapshot(
                sceneID: parent.sceneID,
                editorIdentity: parent.editorIdentity,
                requestGeneration: requestGeneration,
                textRevision: textRevision,
                sourceText: source,
                caretLocation: caret,
                selectionLength: selectedRange.length
            )
            autocompleteSnapshot = snapshot
            parent.autocompleteState = .loading
            logAutocompleteOutcome(eligibility.reason.rawValue, in: textView, generation: requestGeneration)
            autocompleteTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: self?.parent.autocompleteDelay ?? .zero) } catch { return }
                guard let self, !Task.isCancelled else { return }
                defer {
                    if snapshot.requestGeneration == self.autocompleteRequestGeneration {
                        self.autocompleteTask = nil
                    }
                }
                guard self.parent.autocompleteConfigurationEligibility.isEligible else {
                    self.logAutocompleteOutcome(self.parent.autocompleteConfigurationEligibility.rawValue, in: self.view?.textView, generation: snapshot.requestGeneration)
                    self.cancelAutocomplete()
                    return
                }
                guard self.isCurrent(snapshot, in: self.view?.textView) else {
                    self.logRejectedStaleAutocomplete(snapshot)
                    return
                }
                self.logAutocompleteOutcome("eligibleRequestStarted", in: self.view?.textView, generation: snapshot.requestGeneration)
                let result = await self.parent.autocomplete(context)
                let isCurrent = !Task.isCancelled
                    && snapshot.requestGeneration == self.autocompleteRequestGeneration
                    && self.autocompleteSnapshot == snapshot
                    && self.isCurrent(snapshot, in: self.view?.textView)
                guard isCurrent else {
                    self.logRejectedStaleAutocomplete(snapshot)
                    return
                }
                switch result {
                case .suggestion(let completion):
                    guard self.isCurrent(snapshot, in: self.view?.textView) else {
                        self.logRejectedStaleAutocomplete(snapshot)
                        return
                    }
                    self.view?.textView.ghostText = completion
                    self.parent.autocompleteState = .suggestion(completion)
                case .temporarilyUnavailable:
                    self.autocompleteSnapshot = nil
                    self.parent.autocompleteState = .idle
                case .none:
                    self.autocompleteSnapshot = nil
                    self.parent.autocompleteState = .idle
                }
            }
        }

        private func isCurrent(_ snapshot: AutocompleteRequestSnapshot, in textView: NSTextView?) -> Bool {
            guard let textView, autocompleteEligibility(in: textView).isEligible else { return false }
            return isAutocompleteSnapshotCurrent(
                snapshot,
                sceneID: parent.sceneID,
                editorIdentity: parent.editorIdentity,
                textRevision: textRevision,
                sourceText: textView.string,
                selectedRange: textView.selectedRange(),
                hasMarkedText: textView.hasMarkedText()
            )
        }

        private func logRejectedStaleAutocomplete(_ snapshot: AutocompleteRequestSnapshot) {
            logAutocompleteOutcome("rejectedStale", in: view?.textView, generation: snapshot.requestGeneration, textRevision: snapshot.textRevision)
        }

        private func hasValidPendingRequest(in textView: NSTextView) -> Bool {
            guard autocompleteTask != nil, let snapshot = autocompleteSnapshot else { return false }
            return isCurrent(snapshot, in: textView)
        }

        private func hasValidVisibleSuggestion(in textView: NSTextView) -> Bool {
            guard let placeholderTextView = textView as? PlaceholderTextView,
                  !placeholderTextView.ghostText.isEmpty,
                  let snapshot = autocompleteSnapshot else { return false }
            return isCurrent(snapshot, in: placeholderTextView)
        }

        private func isEscapeDismissed(at selectedRange: NSRange, in textView: NSTextView) -> Bool {
            escapeDismissalContext == EscapeDismissalContext(
                sourceText: textView.string,
                textRevision: textRevision,
                caretLocation: selectedRange.location
            )
        }

        private func logAutocompleteOutcome(
            _ reason: String,
            in textView: NSTextView?,
            generation: Int,
            textRevision: Int? = nil
        ) {
#if DEBUG
            let selectedRange = textView?.selectedRange() ?? .init(location: 0, length: 0)
            let textLength = ((textView?.string ?? "") as NSString).length
            let suffixCount = max(0, textLength - min(max(0, selectedRange.location), textLength))
            Self.autocompleteLogger.debug(
                "Autocomplete outcome=\(reason, privacy: .public) scene=\(self.parent.sceneID.uuidString, privacy: .public) editor=\(self.parent.editorIdentity.uuidString, privacy: .public) revision=\(textRevision ?? self.textRevision, privacy: .public) generation=\(generation, privacy: .public) caret=\(selectedRange.location, privacy: .public) suffixCount=\(suffixCount, privacy: .public)"
            )
#endif
        }

        private func clampedVisibleOrigin(_ origin: NSPoint, in view: MarkerTextContainerView) -> NSPoint {
            let documentBounds = view.scrollView.documentView?.bounds ?? .zero
            let clipSize = view.scrollView.contentView.bounds.size
            let maximumX = max(documentBounds.minX, documentBounds.maxX - clipSize.width)
            let maximumY = max(documentBounds.minY, documentBounds.maxY - clipSize.height)
            return NSPoint(
                x: min(max(origin.x, documentBounds.minX), maximumX),
                y: min(max(origin.y, documentBounds.minY), maximumY)
            )
        }

        func handleGhostAction(_ action: PlaceholderTextView.GhostAction) {
            guard let textView = view?.textView else { return }
            switch action {
            case .accept:
                let completion = textView.ghostText
                guard !completion.isEmpty, let snapshot = autocompleteSnapshot,
                      isCurrent(snapshot, in: textView) else {
                    logAutocompleteOutcome("rejectedStale", in: textView, generation: autocompleteRequestGeneration)
                    cancelAutocomplete()
                    return
                }
                textView.ghostText = ""
                autocompleteTask?.cancel()
                autocompleteTask = nil
                autocompleteSnapshot = nil
                parent.autocompleteState = .idle
                textView.insertText(completion, replacementRange: snapshot.range)
                _ = emitCurrentText(from: textView, origin: .user)
            case .dismiss:
                escapeDismissalContext = EscapeDismissalContext(
                    sourceText: textView.string,
                    textRevision: textRevision,
                    caretLocation: textView.selectedRange().location
                )
                cancelAutocomplete()
            case .replace:
                cancelAutocomplete()
            }
        }

        func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let view,
                  let range = view.selectionOrParagraphRange(at: charIndex),
                  let anchor = TextAnchorRepair.anchor(in: textView.string, range: range) else {
                return menu
            }
            menu.insertItem(NSMenuItem.separator(), at: 0)
            let editingItem = NSMenuItem(title: parent.addEditingLabel, action: #selector(addEditingForSelection(_:)), keyEquivalent: "")
            editingItem.target = self
            editingItem.representedObject = anchor
            menu.insertItem(editingItem, at: 0)
            let bRollItem = NSMenuItem(title: parent.addBRollLabel, action: #selector(addBRollForSelection(_:)), keyEquivalent: "")
            bRollItem.target = self
            bRollItem.representedObject = anchor
            menu.insertItem(bRollItem, at: 0)
            return menu
        }

        @MainActor @objc private func addBRollForSelection(_ sender: NSMenuItem) {
            guard let anchor = sender.representedObject as? TextAnchor else { return }
            parent.addMarkerAction(.bRoll, anchor)
        }

        @MainActor @objc private func addEditingForSelection(_ sender: NSMenuItem) {
            guard let anchor = sender.representedObject as? TextAnchor else { return }
            parent.addMarkerAction(.editing, anchor)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { false }
    }
}

@MainActor
protocol ActiveScriptEditor: AnyObject {
    @discardableResult func commitMarkedTextAndFlush() -> Bool
    func cancelAutocomplete(clearStatus: Bool)
    var sceneID: UUID { get }
    var editorIdentity: UUID { get }
    var owningWindow: NSWindow? { get }
    var isActualFirstResponder: Bool { get }
}

extension LinkedScriptTextView.Coordinator: ActiveScriptEditor {
    var sceneID: UUID { parent.sceneID }
    var editorIdentity: UUID { parent.editorIdentity }
    var owningWindow: NSWindow? { view?.textView.window }
    var isActualFirstResponder: Bool {
        guard let textView = view?.textView else { return false }
        return textView.window?.firstResponder === textView
    }
}

@MainActor
final class ActiveScriptEditorSession {
    static let shared = ActiveScriptEditorSession()
    private final class WeakEditor {
        weak var value: ActiveScriptEditor?
        init(_ value: ActiveScriptEditor) { self.value = value }
    }
    private var editors: [WeakEditor] = []

    private init() {}

    func register(_ editor: ActiveScriptEditor) {
        editors.removeAll { $0.value == nil || $0.value === editor }
        editors.append(WeakEditor(editor))
    }

    func unregister(_ editor: ActiveScriptEditor) {
        editors.removeAll { $0.value == nil || $0.value === editor }
    }

    @discardableResult
    func flush(keyWindow: NSWindow? = NSApp.keyWindow) -> Bool {
        editors.removeAll { $0.value == nil }
        let liveEditors = editors.compactMap(\.value)
        let editor = liveEditors.first(where: \.isActualFirstResponder) ?? {
            guard let keyWindow else { return nil }
            return liveEditors.first { $0.owningWindow === keyWindow }
        }()
        guard let editor else { return false }
        _ = editor.commitMarkedTextAndFlush()
        return true
    }

    @discardableResult
    func flushAllForAppResignation() -> Bool {
        editors.removeAll { $0.value == nil }
        let liveEditors = editors.compactMap(\.value)
        for editor in liveEditors {
            _ = editor.commitMarkedTextAndFlush()
            editor.cancelAutocomplete(clearStatus: true)
        }
        return !liveEditors.isEmpty
    }

    func cancelAllAutocomplete() {
        editors.removeAll { $0.value == nil }
        for editor in editors.compactMap(\.value) {
            editor.cancelAutocomplete(clearStatus: true)
        }
    }
}

final class PlaceholderTextView: NSTextView {
    enum GhostAction { case accept, dismiss, replace }

    struct GhostTextLayoutMetrics {
        let startsOnNextLine: Bool
        let firstWordFitsAtCaret: Bool
        let firstWordRange: NSRange?
        let firstWordLineIndex: Int?
        let visualLineRanges: [NSRange]
        let usableCaretLineWidth: CGFloat
        let firstWordPrefixWidth: CGFloat?
        let plannedLineOrigins: [CGFloat]
        let plannedBaselines: [CGFloat]
        let paragraphLineSpacing: CGFloat
        let paragraphLineHeightMultiple: CGFloat
        let lineFragmentPadding: CGFloat
    }

    private struct GhostTextLayoutPlan {
        let startsOnNextLine: Bool
        let firstWordFitsAtCaret: Bool
        let firstWordRange: NSRange?
        let visualLineRanges: [NSRange]
        let usableCaretLineWidth: CGFloat
        let firstWordPrefixWidth: CGFloat?
        let paragraphStyle: NSParagraphStyle
        let primaryStorage: NSTextStorage
        let primaryLayout: NSLayoutManager
        let primaryGlyphRange: NSRange
        let primaryOrigin: NSPoint
        let continuationStorage: NSTextStorage?
        let continuationLayout: NSLayoutManager?
        let continuationGlyphRange: NSRange?
        let continuationOrigin: NSPoint?

        func draw() {
            primaryLayout.drawGlyphs(forGlyphRange: primaryGlyphRange, at: primaryOrigin)
            if let continuationLayout, let continuationGlyphRange, let continuationOrigin {
                continuationLayout.drawGlyphs(forGlyphRange: continuationGlyphRange, at: continuationOrigin)
            }
        }

        func lineMetrics() -> (origins: [CGFloat], baselines: [CGFloat]) {
            let primary = Self.lineMetrics(
                in: primaryLayout,
                glyphRange: primaryGlyphRange,
                origin: primaryOrigin
            )
            guard let continuationLayout, let continuationGlyphRange, let continuationOrigin else {
                return primary
            }
            let continuation = Self.lineMetrics(
                in: continuationLayout,
                glyphRange: continuationGlyphRange,
                origin: continuationOrigin
            )
            return (primary.origins + continuation.origins, primary.baselines + continuation.baselines)
        }

        private static func lineMetrics(
            in layout: NSLayoutManager,
            glyphRange: NSRange,
            origin: NSPoint
        ) -> (origins: [CGFloat], baselines: [CGFloat]) {
            var origins: [CGFloat] = []
            var baselines: [CGFloat] = []
            layout.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                guard lineGlyphRange.length > 0 else { return }
                origins.append(origin.y + lineRect.minY)
                baselines.append(origin.y + layout.location(forGlyphAt: lineGlyphRange.location).y)
            }
            return (origins, baselines)
        }
    }

    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.secondaryLabelColor { didSet { needsDisplay = true } }
    var ghostText = "" { didSet { needsDisplay = true } }
    var ghostAction: ((GhostAction) -> Void)?

    var placeholderOrigin: NSPoint {
        textContainerOrigin
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        super.drawInsertionPoint(in: normalizedInsertionCaretRect(rect), color: color, turnedOn: flag)
    }

    /// Keeps the native insertion point at glyph height when paragraph spacing enlarges a TextKit line fragment.
    func normalizedInsertionCaretRect(_ systemRect: NSRect) -> NSRect {
        guard systemRect.height > 0, let font = activeCaretFont() else { return systemRect }

        let glyphHeight = max(1, font.ascender - font.descender)
        let height = min(systemRect.height, glyphHeight)
        var caretRect = systemRect
        caretRect.size.height = height
        if isEmptyParagraph(at: selectedRange().location) {
            caretRect.origin.y = systemRect.midY - height / 2
            return caretRect
        }
        if let insertionLine = insertionCaretLine(at: selectedRange().location, font: font) {
            let lineRect = insertionLine.rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            caretRect.origin.y = textContainerOrigin.y + insertionLine.baseline - font.ascender
            caretRect.origin.y = min(max(caretRect.origin.y, lineRect.minY), lineRect.maxY - height)
        } else {
            caretRect.origin.y = min(max(caretRect.origin.y, systemRect.minY), systemRect.maxY - height)
        }
        return caretRect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            (placeholder as NSString).draw(at: placeholderOrigin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: placeholderColor,
                .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default
            ])
        }
        drawGhostText()
    }

    private func drawGhostText() {
        guard let layout = ghostTextLayoutPlan() else { return }
        layout.draw()
    }

    func ghostTextLayoutMetrics() -> GhostTextLayoutMetrics? {
        guard let layout = ghostTextLayoutPlan() else { return nil }
        let firstWordLineIndex = layout.firstWordRange.flatMap { wordRange in
            layout.visualLineRanges.firstIndex {
                $0.location <= wordRange.location && wordRange.location < NSMaxRange($0)
            }
        }
        return GhostTextLayoutMetrics(
            startsOnNextLine: layout.startsOnNextLine,
            firstWordFitsAtCaret: layout.firstWordFitsAtCaret,
            firstWordRange: layout.firstWordRange,
            firstWordLineIndex: firstWordLineIndex,
            visualLineRanges: layout.visualLineRanges,
            usableCaretLineWidth: layout.usableCaretLineWidth,
            firstWordPrefixWidth: layout.firstWordPrefixWidth,
            plannedLineOrigins: layout.lineMetrics().origins,
            plannedBaselines: layout.lineMetrics().baselines,
            paragraphLineSpacing: layout.paragraphStyle.lineSpacing,
            paragraphLineHeightMultiple: layout.paragraphStyle.lineHeightMultiple,
            lineFragmentPadding: textContainer?.lineFragmentPadding ?? 0
        )
    }

    private func ghostTextLayoutPlan() -> GhostTextLayoutPlan? {
        guard !ghostText.isEmpty, isAutocompleteEligible(in: self),
              let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        let index = min(selectedRange().location, length)
        layoutManager.ensureLayout(for: textContainer)
        let insertion = insertionPoint(at: index, layoutManager: layoutManager, textContainer: textContainer)
        let attributes = ghostAttributes()
        let padding = textContainer.lineFragmentPadding
        let currentLine = insertionLineFragment(at: index, layoutManager: layoutManager)
        let insertionX = insertion.x - textContainerOrigin.x
        let rightTextInset = textContainer.size.width - padding
        let remainingWidth = max(0, min(currentLine.maxX, rightTextInset) - insertionX)
        let fullWidth = max(1, textContainer.size.width)
        let ghostString = ghostText as NSString
        let firstWordRange = firstNonWhitespaceWordRange(in: ghostString)
        let firstWordPrefixRange = firstWordRange.flatMap { firstSameLinePrefix(through: $0, in: ghostString) }
        let firstWordPrefixWidth = firstWordPrefixRange.flatMap {
            measuredFirstWordPrefixWidth(in: $0, attributes: attributes, padding: padding, containerWidth: fullWidth)
        }
        let firstWordFitsAtCaret: Bool
        if firstWordPrefixRange != nil {
            firstWordFitsAtCaret = firstWordPrefixWidth.map { $0 <= remainingWidth } ?? false
        } else {
            firstWordFitsAtCaret = true
        }
        let startsOnNextLine = firstWordRange != nil && !firstWordFitsAtCaret
        let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
        let rendering = ghostRenderingLayout(
            attributes: attributes,
            textContainer: textContainer,
            forceNextLine: startsOnNextLine
        )
        return GhostTextLayoutPlan(
            startsOnNextLine: startsOnNextLine,
            firstWordFitsAtCaret: firstWordFitsAtCaret,
            firstWordRange: firstWordRange,
            visualLineRanges: rendering.visualLineRanges,
            usableCaretLineWidth: remainingWidth,
            firstWordPrefixWidth: firstWordPrefixWidth,
            paragraphStyle: paragraphStyle,
            primaryStorage: rendering.storage,
            primaryLayout: rendering.layout,
            primaryGlyphRange: rendering.glyphRange,
            primaryOrigin: textContainerOrigin,
            continuationStorage: nil,
            continuationLayout: nil,
            continuationGlyphRange: nil,
            continuationOrigin: nil
        )
    }

    private func insertionLineFragment(at index: Int, layoutManager: NSLayoutManager) -> NSRect {
        let length = (string as NSString).length
        if index == length, !layoutManager.extraLineFragmentRect.isEmpty {
            return layoutManager.extraLineFragmentRect
        }
        guard length > 0 else { return .zero }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func firstNonWhitespaceWordRange(in text: NSString) -> NSRange? {
        let nonWhitespace = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard nonWhitespace.location != NSNotFound else { return nil }
        let trailingRange = NSRange(location: nonWhitespace.location, length: text.length - nonWhitespace.location)
        let whitespace = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: trailingRange)
        let end = whitespace.location == NSNotFound ? text.length : whitespace.location
        return NSRange(location: nonWhitespace.location, length: end - nonWhitespace.location)
    }

    /// Includes only whitespace that shares the caret line; an explicit newline is already a real line break.
    private func firstSameLinePrefix(through wordRange: NSRange, in text: NSString) -> NSRange? {
        let leadingRange = NSRange(location: 0, length: wordRange.location)
        guard text.rangeOfCharacter(from: .newlines, options: [], range: leadingRange).location == NSNotFound else {
            return nil
        }
        return NSRange(location: 0, length: NSMaxRange(wordRange))
    }

    private func measuredFirstWordPrefixWidth(
        in range: NSRange,
        attributes: [NSAttributedString.Key: Any],
        padding: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat? {
        let prefix = (ghostText as NSString).substring(with: range)
        let storage = NSTextStorage(string: prefix, attributes: attributes)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        layout.addTextContainer(container)
        let glyphRange = NSRange(location: 0, length: layout.numberOfGlyphs)
        guard glyphRange.length > 0,
              let prefixGlyphRange = firstLineGlyphRange(in: layout, glyphRange: glyphRange),
              NSMaxRange(prefixGlyphRange) == layout.numberOfGlyphs else { return nil }
        return layout.boundingRect(forGlyphRange: prefixGlyphRange, in: container).width
    }

    /// Uses a copy of the real attributed source, never mutating editor storage. Drawing only its ghost range
    /// gives the ghost the exact TextKit line fragments and baselines that inserted editor text would receive.
    private func ghostRenderingLayout(
        attributes: [NSAttributedString.Key: Any],
        textContainer: NSTextContainer,
        forceNextLine: Bool
    ) -> (storage: NSTextStorage, layout: NSLayoutManager, glyphRange: NSRange, visualLineRanges: [NSRange]) {
        let source: NSAttributedString
        if let textStorage {
            source = textStorage.attributedSubstring(from: NSRange(location: 0, length: textStorage.length))
        } else {
            source = NSAttributedString(string: string, attributes: attributes)
        }
        let storage = NSTextStorage(attributedString: source)
        if forceNextLine {
            storage.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        let ghostStart = storage.length
        storage.append(NSAttributedString(string: ghostText, attributes: attributes))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: textContainer.size)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let glyphStart = layout.glyphIndexForCharacter(at: ghostStart)
        let glyphRange = NSRange(location: glyphStart, length: layout.numberOfGlyphs - glyphStart)
        let ghostCharacters = NSRange(location: ghostStart, length: (ghostText as NSString).length)
        let visualLineRanges = lineCharacterRanges(in: layout, glyphRange: glyphRange).compactMap { lineRange -> NSRange? in
            let ghostLine = NSIntersectionRange(lineRange, ghostCharacters)
            guard ghostLine.length > 0 else { return nil }
            return NSRange(location: ghostLine.location - ghostStart, length: ghostLine.length)
        }
        return (storage, layout, glyphRange, visualLineRanges)
    }

    private func firstLineGlyphRange(in layout: NSLayoutManager, glyphRange: NSRange) -> NSRange? {
        var firstRange: NSRange?
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, stop in
            firstRange = lineGlyphRange
            stop.pointee = true
        }
        return firstRange
    }

    private func lineCharacterRanges(in layout: NSLayoutManager, glyphRange: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, lineGlyphRange, _ in
            let range = layout.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            if range.length > 0 { ranges.append(range) }
        }
        return ranges
    }

    func ghostLineFragmentWidths() -> [CGFloat] {
        guard !ghostText.isEmpty, isAutocompleteEligible(in: self), let textContainer else { return [] }
        let storage = NSTextStorage(string: ghostText, attributes: ghostAttributes())
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: textContainer.size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        layout.addTextContainer(container)
        let glyphs = NSRange(location: 0, length: layout.numberOfGlyphs)
        var widths: [CGFloat] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, _, _ in widths.append(usedRect.width) }
        return widths
    }

    private func ghostAttributes() -> [NSAttributedString.Key: Any] {
        var attributes = typingAttributes
        attributes[.font] = activeCaretFont() ?? font ?? NSFont.systemFont(ofSize: 14)
        attributes[.foregroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        attributes[.paragraphStyle] = activeCaretParagraphStyle()
        return attributes
    }

    private func activeCaretParagraphStyle() -> NSParagraphStyle {
        let length = (string as NSString).length
        let insertion = min(max(0, selectedRange().location), length)
        if let textStorage, length > 0 {
            let indices = insertion < length ? [insertion, max(0, insertion - 1)] : [length - 1]
            for index in indices {
                if let style = textStorage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle {
                    return style
                }
            }
        }
        return typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? defaultParagraphStyle ?? NSParagraphStyle.default
    }

    func insertionPoint(at index: Int, layoutManager: NSLayoutManager, textContainer: NSTextContainer) -> NSPoint {
        let length = (string as NSString).length
        if index == length, !layoutManager.extraLineFragmentRect.isEmpty {
            let rect = layoutManager.extraLineFragmentRect
            return NSPoint(x: textContainerOrigin.x + rect.origin.x, y: textContainerOrigin.y + rect.origin.y)
        }
        guard length > 0 else { return textContainerOrigin }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        let point = layoutManager.location(forGlyphAt: glyph)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        if index == length {
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            return NSPoint(x: textContainerOrigin.x + used.maxX, y: textContainerOrigin.y + line.origin.y)
        }
        return NSPoint(x: textContainerOrigin.x + point.x, y: textContainerOrigin.y + line.origin.y)
    }

    private func activeCaretFont() -> NSFont? {
        let length = (string as NSString).length
        let insertion = min(max(0, selectedRange().location), length)
        if insertion == length, (length == 0 || (string as NSString).character(at: length - 1) == 10 || (string as NSString).character(at: length - 1) == 13) {
            return typingAttributes[.font] as? NSFont ?? font
        }
        if let textStorage, length > 0 {
            let indices = insertion < length ? [insertion, max(0, insertion - 1)] : [length - 1]
            for index in indices {
                if let font = textStorage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
            }
        }
        return typingAttributes[.font] as? NSFont ?? font
    }

    private func isEmptyParagraph(at characterIndex: Int) -> Bool {
        let text = string as NSString
        let length = text.length
        let insertion = min(max(0, characterIndex), length)
        guard length > 0, insertion < length else { return false }

        let previousIsNewline = insertion == 0 || isParagraphBreak(text.character(at: insertion - 1))
        let currentIsNewline = isParagraphBreak(text.character(at: insertion))
        return previousIsNewline && currentIsNewline
    }

    private func isParagraphBreak(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private func insertionCaretLine(at characterIndex: Int, font: NSFont) -> (rect: NSRect, baseline: CGFloat)? {
        guard let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let text = string as NSString
        let length = text.length
        let insertion = min(max(0, characterIndex), length)

        if insertion == length, (length == 0 || text.character(at: length - 1) == 10 || text.character(at: length - 1) == 13) {
            let line = layoutManager.extraLineFragmentRect
            guard !line.isEmpty else { return nil }
            return (line, line.minY + font.ascender)
        }

        guard length > 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: insertion == length ? length - 1 : insertion)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return (line, line.minY + layoutManager.location(forGlyphAt: glyphIndex).y)
    }

    override func keyDown(with event: NSEvent) {
        if !ghostText.isEmpty {
            if event.keyCode == 48 { ghostAction?(.accept); return }
            if event.keyCode == 53 { ghostAction?(.dismiss); return }
            if [123, 124, 125, 126].contains(event.keyCode) {
                super.keyDown(with: event)
                return
            }
            ghostAction?(.replace)
        }
        super.keyDown(with: event)
    }
}

final class MarkerTextContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = PlaceholderTextView()
    private let markerView = TextRangeMarkerView()
    weak var coordinator: LinkedScriptTextView.Coordinator?
    var markers: [ProductionTextMarker] = [] {
        didSet {
            guard markers != oldValue else { return }
            markerView.needsDisplay = true
        }
    }
    var bRollColor = NSColor.systemBlue
    var editingColor = NSColor.systemGreen
    var addBRollLabel = ""
    var addEditingLabel = ""
    var cachedFontSize: Double?
    var markerTextRevision = 0 {
        didSet {
            guard markerTextRevision != oldValue else { return }
            markerView.needsDisplay = true
        }
    }
    private var cachedMarkerGeometry = MarkerGeometry()
    private var markerCacheSignature: MarkerCacheSignature?
    private(set) var markerGeometryRebuildCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        markerView.container = self
        addSubview(scrollView)
        addSubview(markerView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let markerWidth: CGFloat = 13
        scrollView.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - markerWidth), height: bounds.height)
        markerView.frame = NSRect(x: max(0, bounds.width - markerWidth), y: 0, width: markerWidth, height: bounds.height)
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        markerView.needsDisplay = true
    }

    @objc private func scrolled() {
        markerView.needsDisplay = true
        coordinator?.captureRestorationState()
    }

    func markerNeedsDisplay() {
        markerView.needsDisplay = true
    }

    func markerRects() -> [ViewportMarkerRect] {
        rebuildMarkerGeometryIfNeeded()
        return viewportMarkerRects(from: cachedMarkerGeometry.renderRuns)
    }

    func markerHitRects() -> [ViewportMarkerRect] {
        rebuildMarkerGeometryIfNeeded()
        return viewportMarkerRects(from: cachedMarkerGeometry.hitRegions)
    }

    func markerHitTest(at point: NSPoint) -> ViewportMarkerRect? {
        markerHitRects().first { $0.rect.contains(point) }
    }

    func documentMarkerGeometry() -> MarkerGeometry {
        rebuildMarkerGeometryIfNeeded()
        return cachedMarkerGeometry
    }

    func selectionOrParagraphRange(at charIndex: Int) -> NSRange? {
        let full = textView.string as NSString
        guard full.length > 0 else { return nil }
        let selected = textView.selectedRange()
        if selected.length > 0 {
            return TextAnchorGeometry.clamp(selected, toLength: full.length)
        }
        let safeIndex = min(max(0, charIndex), max(0, full.length - 1))
        let paragraph = full.paragraphRange(for: NSRange(location: safeIndex, length: 0))
        let trimmed = TextAnchorGeometry.trimmedRange(paragraph, in: full)
        return trimmed.length > 0 ? trimmed : nil
    }

    private func rebuildMarkerGeometryIfNeeded() {
        let text = textView.string
        let groups = TextAnchorGeometry.markerGroups(markers: markers, in: text)
        let signature = MarkerCacheSignature(
            textRevision: markerTextRevision,
            text: text,
            containerWidth: textView.textContainer?.containerSize.width ?? 0,
            fontSize: cachedFontSize ?? 0,
            groups: groups
        )
        guard markerCacheSignature != signature else { return }
        markerCacheSignature = signature
        markerGeometryRebuildCount += 1
        cachedMarkerGeometry = TextAnchorGeometry.documentMarkers(groups: groups, textView: textView)
    }

    private func viewportMarkerRects(from documentMarkers: [DocumentMarkerRect]) -> [ViewportMarkerRect] {
        let visible = scrollView.contentView.bounds
        return documentMarkers.compactMap { marker in
            var rect = marker.documentRect
            rect.origin.y -= visible.origin.y
            rect.origin.y = markerView.bounds.height - rect.maxY
            guard rect.intersects(markerView.bounds) else { return nil }
            return ViewportMarkerRect(itemIDs: marker.itemIDs, mode: marker.mode, rect: rect)
        }
    }
}

private struct MarkerCacheSignature: Equatable {
    var textRevision: Int
    var text: String
    var containerWidth: CGFloat
    var fontSize: Double
    var groups: [MarkerRangeGroup]
}

fileprivate struct MarkerRangeGroup: Equatable {
    let mode: WorkspaceMode
    var range: NSRange
    var itemIDs: [UUID]
}

struct DocumentMarkerRect: Equatable {
    var itemIDs: [UUID]
    var mode: WorkspaceMode
    var documentRect: NSRect

    var itemID: UUID? { itemIDs.first }
}

struct ViewportMarkerRect: Equatable {
    var itemIDs: [UUID]
    var mode: WorkspaceMode
    var rect: NSRect

    var itemID: UUID? { itemIDs.first }
}

struct MarkerGeometry: Equatable {
    var hitRegions: [DocumentMarkerRect] = []
    var renderRuns: [DocumentMarkerRect] = []
}

enum TextMarkerStyle {
    static let stripWidth: CGFloat = 3
    static let cornerRadius: CGFloat = 1.5
}

enum TextAnchorGeometry {
    @MainActor
    fileprivate static func documentMarkers(groups: [MarkerRangeGroup], textView: NSTextView) -> MarkerGeometry {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return MarkerGeometry() }
        layout.ensureLayout(for: container)
        let fragments = groups.enumerated().flatMap { index, group in
            markerLineFragments(
                for: group,
                groupIndex: index,
                layout: layout,
                textInset: textView.textContainerInset.height
            )
        }
        let allocated = allocateLaneLocalRegions(fragments)
        return MarkerGeometry(
            hitRegions: allocated.map(\.marker),
            renderRuns: mergedVisualRuns(from: allocated)
        )
    }

    fileprivate static func markerGroups(markers: [ProductionTextMarker], in text: String) -> [MarkerRangeGroup] {
        let validMarkers = markers.compactMap { marker -> (marker: ProductionTextMarker, range: NSRange)? in
            guard marker.mode == .bRoll || marker.mode == .editing,
                  let anchor = TextAnchorRepair.current(marker.anchor, in: text) else {
                return nil
            }
            return (marker, anchor.nsRange)
        }
        return [WorkspaceMode.bRoll, .editing].flatMap { mode in
            groupedRanges(mode: mode, markers: validMarkers)
        }
    }

    static func clamp(_ range: NSRange, toLength length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location, length: min(max(0, range.length), max(0, length - location)))
    }

    static func trimmedRange(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(text, at: start) {
            start += 1
        }
        while end > start, isWhitespace(text, at: end - 1) {
            end -= 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ text: NSString, at index: Int) -> Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [], range: NSRange(location: index, length: 1)).location != NSNotFound
    }

    private static func markerRect(for mode: WorkspaceMode, usedRect: NSRect, textInset: CGFloat) -> NSRect {
        NSRect(
            x: markerLaneX(for: mode),
            y: usedRect.minY + textInset,
            width: TextMarkerStyle.stripWidth,
            height: max(8, usedRect.height)
        )
    }

    private static func markerLaneX(for mode: WorkspaceMode) -> CGFloat {
        switch mode {
        case .bRoll: 2
        case .editing: 8
        case .script: 2
        }
    }

    private struct MarkerLineFragment {
        let groupIndex: Int
        let marker: DocumentMarkerRect
    }

    private struct AllocatedMarkerFragment {
        let groupIndex: Int
        let marker: DocumentMarkerRect
        let sharesLine: Bool
    }

    private static func markerLineFragments(
        for group: MarkerRangeGroup,
        groupIndex: Int,
        layout: NSLayoutManager,
        textInset: CGFloat
    ) -> [MarkerLineFragment] {
        var actual = NSRange()
        let glyphRange = layout.glyphRange(forCharacterRange: group.range, actualCharacterRange: &actual)
        guard glyphRange.length > 0 else { return [] }
        var regions: [MarkerLineFragment] = []
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            guard NSIntersectionRange(glyphRange, lineGlyphRange).length > 0 else { return }
            regions.append(MarkerLineFragment(
                groupIndex: groupIndex,
                marker: DocumentMarkerRect(
                    itemIDs: group.itemIDs,
                    mode: group.mode,
                    documentRect: markerRect(for: group.mode, usedRect: usedRect, textInset: textInset)
                )
            ))
        }
        return regions
    }

    private static func allocateLaneLocalRegions(_ fragments: [MarkerLineFragment]) -> [AllocatedMarkerFragment] {
        let grouped = Dictionary(grouping: fragments) { fragment in
            LaneLineKey(
                mode: fragment.marker.mode,
                minY: fragment.marker.documentRect.minY,
                maxY: fragment.marker.documentRect.maxY
            )
        }
        return grouped.values.flatMap { lineFragments in
            let ordered = lineFragments.sorted { $0.groupIndex < $1.groupIndex }
            let count = CGFloat(ordered.count)
            return ordered.enumerated().map { index, fragment in
                var rect = fragment.marker.documentRect
                let height = rect.height / count
                rect.origin.y += height * CGFloat(index)
                rect.size.height = height
                return AllocatedMarkerFragment(
                    groupIndex: fragment.groupIndex,
                    marker: DocumentMarkerRect(itemIDs: fragment.marker.itemIDs, mode: fragment.marker.mode, documentRect: rect),
                    sharesLine: ordered.count > 1
                )
            }
        }
        .sorted { lhs, rhs in
            if lhs.marker.mode != rhs.marker.mode { return lhs.marker.mode == .bRoll }
            if lhs.marker.documentRect.minY != rhs.marker.documentRect.minY { return lhs.marker.documentRect.minY < rhs.marker.documentRect.minY }
            return lhs.groupIndex < rhs.groupIndex
        }
    }

    private struct LaneLineKey: Hashable {
        let mode: WorkspaceMode
        let minY: CGFloat
        let maxY: CGFloat
    }

    private static func groupedRanges(
        mode: WorkspaceMode,
        markers: [(marker: ProductionTextMarker, range: NSRange)]
    ) -> [MarkerRangeGroup] {
        let sortedMarkers = markers.enumerated().filter { $0.element.marker.mode == mode }.sorted { lhs, rhs in
            let lhsRange = lhs.element.range
            let rhsRange = rhs.element.range
            if lhsRange.location != rhsRange.location { return lhsRange.location < rhsRange.location }
            if lhsRange.length != rhsRange.length { return lhsRange.length < rhsRange.length }
            return lhs.offset < rhs.offset
        }
        guard let first = sortedMarkers.first else { return [] }
        var group = MarkerRangeGroup(mode: mode, range: first.element.range, itemIDs: [first.element.marker.itemID])
        var groups: [MarkerRangeGroup] = []

        for entry in sortedMarkers.dropFirst() {
            let range = entry.element.range
            let groupEnd = NSMaxRange(group.range)
            if range.location <= groupEnd {
                group.range.length = max(groupEnd, NSMaxRange(range)) - group.range.location
                if !group.itemIDs.contains(entry.element.marker.itemID) {
                    group.itemIDs.append(entry.element.marker.itemID)
                }
            } else {
                groups.append(group)
                group = MarkerRangeGroup(mode: mode, range: range, itemIDs: [entry.element.marker.itemID])
            }
        }
        groups.append(group)
        return groups
    }

    private static func mergedVisualRuns(from fragments: [AllocatedMarkerFragment]) -> [DocumentMarkerRect] {
        let byGroup = Dictionary(grouping: fragments, by: \.groupIndex)
        return byGroup.values.flatMap { groupFragments in
            let ordered = groupFragments.sorted { $0.marker.documentRect.minY < $1.marker.documentRect.minY }
            var runs: [DocumentMarkerRect] = []
            var previousFragmentWasFullLane = false
            for fragment in ordered {
                guard let last = runs.indices.last,
                      previousFragmentWasFullLane,
                      !fragment.sharesLine,
                      runs[last].documentRect.minX == fragment.marker.documentRect.minX,
                      runs[last].documentRect.width == fragment.marker.documentRect.width else {
                    runs.append(fragment.marker)
                    previousFragmentWasFullLane = !fragment.sharesLine
                    continue
                }
                runs[last].documentRect.size.height = fragment.marker.documentRect.maxY - runs[last].documentRect.minY
                previousFragmentWasFullLane = true
            }
            return runs
        }
        .sorted { lhs, rhs in
            if lhs.mode != rhs.mode { return lhs.mode == .bRoll }
            if lhs.documentRect.minY != rhs.documentRect.minY { return lhs.documentRect.minY < rhs.documentRect.minY }
            return lhs.documentRect.minX < rhs.documentRect.minX
        }
    }
}

private final class TextRangeMarkerView: NSView {
    weak var container: MarkerTextContainerView?
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let container else { return }
        for marker in container.markerRects() where marker.rect.intersects(bounds) {
            (marker.mode == .bRoll ? container.bRollColor : container.editingColor).setFill()
            NSBezierPath(
                roundedRect: marker.rect,
                xRadius: TextMarkerStyle.cornerRadius,
                yRadius: TextMarkerStyle.cornerRadius
            ).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let container else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let marker = container.markerHitTest(at: point), !marker.itemIDs.isEmpty {
            container.coordinator?.parent.markerAction(marker.itemIDs, marker.mode)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
