import AppKit
import FrameScriptCore
import SwiftUI

/// Read-only description of one scene for the continuous editor.
///
/// `headerText` is built by the SwiftUI layer because it owns localization and
/// duration formatting. The AppKit coordinator only lays it out and protects it.
struct FullScriptSceneSnapshot: Equatable, Sendable {
    let id: UUID
    let order: Int
    let headerText: String
    let numberText: String
    let durationText: String
    var scriptText: String
    let isCollapsed: Bool

    var descriptor: FullScriptSceneDescriptor {
        FullScriptSceneDescriptor(
            id: id,
            headerText: headerText,
            bodyText: scriptText,
            isCollapsed: isCollapsed
        )
    }
}

/// A caret or selection inside one scene body, expressed in scene-local UTF-16
/// units. Used by undo and by the external-change rebuild so the caret keeps
/// its place even when earlier scenes change length.
struct FullScriptSceneSelection: Equatable, Sendable {
    let sceneID: UUID
    let range: NSRange
}

struct FullScriptEditorAppearance: Equatable {
    var fontSize: Double
    var textColor: NSColor
    var secondaryTextColor: NSColor
    var accentColor: NSColor
    var backgroundColor: NSColor
    /// Hairline drawn above every scene header except the first.
    var dividerColor: NSColor = .separatorColor
}

extension NSAttributedString.Key {
    /// Marks header characters so a future reader (and tests) can tell a
    /// protected separator run from editable scene text. The delegate still
    /// enforces protection through `FullScriptLayout`, never through styling.
    static let fullScriptHeaderSceneID = NSAttributedString.Key("FrameScriptFullScriptHeaderSceneID")
}

// MARK: - Representable

/// One `NSTextView` whose storage is every scene concatenated in order.
struct FullScriptTextView: NSViewRepresentable {
    var scenes: [FullScriptSceneSnapshot]
    var appearance: FullScriptEditorAppearance
    var spellcheck: Bool
    var smartQuotes: Bool
    var pauseDefaults: PauseDefaults
    var placeholder: String
    var accessibilityLabel: String
    var accessibilityHint: String
    var loadRestorationState: () -> ScriptEditorRestorationState?
    var saveRestorationState: (ScriptEditorRestorationState) -> Void
    /// Reads the current committed text of a scene. Captured weakly by the
    /// undo hub so undo actions survive this view being torn down.
    var currentSceneText: @MainActor @Sendable (UUID) -> String?
    var onSceneTextCommitted: @MainActor @Sendable (UUID, String, String) -> Void
    var onCaretSceneChanged: (UUID?) -> Void
    var onToggleCollapse: (UUID) -> Void
    var onTeardown: () -> Void
    /// Menu title for one undo step ("Typing", localized by the view).
    var undoActionName: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FullScriptTextContainerView {
        let view = FullScriptTextContainerView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: FullScriptTextContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyModelTextIfNeeded()
        context.coordinator.applyAppearanceIfNeeded()
    }

    static func dismantleNSView(_ view: FullScriptTextContainerView, coordinator: Coordinator) {
        coordinator.commitMarkedTextAndFlush()
        coordinator.captureRestorationState()
        coordinator.detach(from: view)
        coordinator.parent.onTeardown()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, ActiveScriptEditor {
        private struct PendingEdit {
            let target: FullScriptEditTarget
            /// Document length of the last layout we trust. Everything after
            /// the edited body (separator, headers, later scenes) is immutable
            /// during an authorized edit, so the new body length is derived
            /// from the total length minus that fixed suffix.
            let documentLength: Int
        }

        var parent: FullScriptTextView
        weak var view: FullScriptTextContainerView?
        private(set) var layout: FullScriptLayout
        private(set) var sceneSnapshots: [FullScriptSceneSnapshot]
        private(set) var lastAppliedCharacterCount = 0
        let editorIdentity = UUID()
        private let fallbackSceneID = UUID()
        private var pendingEdit: PendingEdit?
        private var isApplyingProgrammaticUpdate = false
        private var pendingModelRefresh = false
        /// External scene list that arrived while an IME composition was open.
        /// It is merged after the composition commits so the just-typed text is
        /// never replaced by the pre-composition parent snapshot.
        private var deferredExternalScenes: [FullScriptSceneSnapshot]?
        private var pendingInitialRestoration: ScriptEditorRestorationState?
        private var cachedAppearance: FullScriptEditorAppearance?
        private var lastCaretSceneID: UUID?

        init(parent: FullScriptTextView) {
            self.parent = parent
            self.sceneSnapshots = parent.scenes
            self.layout = Self.makeLayout(scenes: parent.scenes)
            self.pendingInitialRestoration = parent.loadRestorationState()
        }

        // MARK: Lifecycle

        func attach(to view: FullScriptTextContainerView) {
            self.view = view
            view.coordinator = self
            view.textView.delegate = self
            view.textView.headerSceneProvider = { [weak self] location in
                self?.headerSceneID(atUTF16Location: location)
            }
            view.textView.headerRangesProvider = { [weak self] in
                self?.layout.segments.map(\.headerRange) ?? []
            }
            view.textView.headerClickAction = { [weak self] sceneID in
                self?.parent.onToggleCollapse(sceneID)
            }
            view.textView.allowsUndo = false
            let restoration = pendingInitialRestoration
            cachedAppearance = parent.appearance
            configureTextView(view)
            rebuildDocument(
                preserving: initialSelection(from: restoration),
                scroll: restoration?.visibleOrigin,
                restyleBodies: true
            )
            pendingInitialRestoration = nil
            ActiveScriptEditorSession.shared.register(self)
            FullScriptUndoHub.shared.activate(self)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: view.scrollView.contentView
            )
            view.scrollView.contentView.postsBoundsChangedNotifications = true
            lastCaretSceneID = nil
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                view.layoutSubtreeIfNeeded()
                view.textView.window?.makeFirstResponder(view.textView)
                self.reportCaretSceneIfNeeded(deferred: true)
            }
        }

        func detach(from view: FullScriptTextContainerView) {
            NotificationCenter.default.removeObserver(self)
            FullScriptUndoHub.shared.deactivate(self)
            ActiveScriptEditorSession.shared.unregister(self)
            if view.coordinator === self { view.coordinator = nil }
            view.textView.headerSceneProvider = nil
            view.textView.headerRangesProvider = nil
            view.textView.headerClickAction = nil
            if view.textView.delegate === self { view.textView.delegate = nil }
            if self.view === view { self.view = nil }
        }

        // MARK: Model reconciliation

        func applyModelTextIfNeeded() {
            guard let view else { return }
            let incoming = parent.scenes
            if incoming == sceneSnapshots {
                // Defensive: nothing in this editor writes storage directly,
                // but if another responder ever replaces it, repair from the
                // model instead of trusting the view.
                if !isApplyingProgrammaticUpdate,
                   !view.textView.hasMarkedText(),
                   view.textView.string != layout.text {
                    rebuildDocument(
                        preserving: currentSceneSelection(),
                        scroll: currentScrollOrigin(),
                        restyleBodies: true
                    )
                }
                return
            }
            guard !view.textView.hasMarkedText() else {
                pendingModelRefresh = true
                deferredExternalScenes = incoming
                return
            }
            deferredExternalScenes = nil
            // A settled edit refreshes the scene's duration, so its header
            // text changes after nearly every pause in typing. Rebuilding and
            // restyling the whole document for that cost ~100 ms on a long
            // script; replacing only the changed header runs keeps every body
            // character, attribute and the caret untouched.
            if applyHeaderOnlyChange(incoming) { return }
            let selection = currentSceneSelection()
            let scroll = currentScrollOrigin()
            // Text written by someone else (AI insert, reload, single-scene
            // editor) ends the current typing group. Header-only refreshes
            // (duration, title) must not, or typing would never coalesce.
            if incoming.count != sceneSnapshots.count
                || zip(incoming, sceneSnapshots).contains(where: { $0.scriptText != $1.scriptText || $0.id != $1.id }) {
                FullScriptUndoHub.shared.breakCoalescing()
            }
            sceneSnapshots = incoming
            layout = Self.makeLayout(scenes: incoming)
            pendingEdit = nil
            pendingModelRefresh = false
            rebuildDocument(preserving: selection, scroll: scroll, restyleBodies: true)
        }

        /// Replaces only the header runs when nothing but header text changed
        /// (same scenes, order, bodies and collapse state). Returns false when a
        /// full rebuild is required.
        private func applyHeaderOnlyChange(_ incoming: [FullScriptSceneSnapshot]) -> Bool {
            guard let view,
                  let storage = view.textView.textStorage,
                  incoming.count == sceneSnapshots.count,
                  storage.length == layout.utf16Length else { return false }
            var changedSceneIDs: Set<UUID> = []
            for (new, old) in zip(incoming, sceneSnapshots) {
                guard new.id == old.id,
                      new.order == old.order,
                      new.isCollapsed == old.isCollapsed,
                      new.scriptText == old.scriptText else { return false }
                if new.headerText != old.headerText
                    || new.numberText != old.numberText
                    || new.durationText != old.durationText {
                    changedSceneIDs.insert(new.id)
                }
            }
            guard !changedSceneIDs.isEmpty else { return false }

            let selection = currentSceneSelection()
            let scroll = currentScrollOrigin()
            let previousLayout = layout
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }

            sceneSnapshots = incoming
            let textView = view.textView
            storage.beginEditing()
            // Back to front, so the ranges of earlier headers stay valid.
            for scene in incoming.reversed() where changedSceneIDs.contains(scene.id) {
                guard let segment = previousLayout.segment(for: scene.id) else { continue }
                // `headerRange` includes the header's trailing newline.
                let textRange = NSRange(
                    location: segment.headerRange.location,
                    length: max(0, segment.headerRange.length - 1)
                )
                storage.replaceCharacters(in: textRange, with: headerAttributedString(for: scene))
            }
            storage.endEditing()
            layout = Self.makeLayout(scenes: incoming)
            pendingEdit = nil
            pendingModelRefresh = false

            textView.typingAttributes = bodyAttributes()
            textView.setSelectedRange(documentRange(for: selection) ?? defaultSelection())
            restoreScroll(scroll)
            textView.needsDisplay = true
            reportCaretSceneIfNeeded()
            captureRestorationState()
            return true
        }

        func applyAppearanceIfNeeded() {
            guard let view else { return }
            guard cachedAppearance != parent.appearance else { return }
            guard !view.textView.hasMarkedText() else { return }
            let selection = currentSceneSelection()
            let scroll = currentScrollOrigin()
            cachedAppearance = parent.appearance
            configureTextView(view)
            rebuildDocument(preserving: selection, scroll: scroll, restyleBodies: true)
        }


        /// Applies an external change that arrived during an IME composition.
        /// The scene the user just committed keeps its local text; every other
        /// scene takes the external snapshot. Without this merge, the stale
        /// parent array captured before the composition would silently undo
        /// the last composed character.
        private func applyDeferredExternalChanges(keepingLocalTextFor sceneID: UUID?) {
            guard let incoming = deferredExternalScenes else {
                pendingModelRefresh = false
                return
            }
            pendingModelRefresh = false
            deferredExternalScenes = nil
            var merged = incoming
            if let sceneID,
               let local = sceneSnapshots.first(where: { $0.id == sceneID }),
               let index = merged.firstIndex(where: { $0.id == sceneID }) {
                merged[index].scriptText = local.scriptText
            }
            let selection = currentSceneSelection()
            let scroll = currentScrollOrigin()
            sceneSnapshots = merged
            layout = Self.makeLayout(scenes: merged)
            pendingEdit = nil
            rebuildDocument(preserving: selection, scroll: scroll, restyleBodies: true)
        }

        private func configureTextView(_ view: FullScriptTextContainerView) {
            let appearance = parent.appearance
            let font = NSFont.systemFont(ofSize: appearance.fontSize)
            let paragraph = ScriptEditorLayout.paragraphStyle()
            view.textView.font = font
            view.textView.textColor = appearance.textColor
            view.textView.backgroundColor = appearance.backgroundColor
            view.scrollView.backgroundColor = appearance.backgroundColor
            view.textView.isContinuousSpellCheckingEnabled = parent.spellcheck
            view.textView.isAutomaticQuoteSubstitutionEnabled = parent.smartQuotes
            view.textView.defaultParagraphStyle = paragraph
            view.textView.typingAttributes = bodyAttributes()
            view.textView.placeholder = parent.placeholder
            view.textView.headerSeparatorColor = appearance.dividerColor
            view.textView.placeholderColor = appearance.secondaryTextColor.withAlphaComponent(0.58)
            view.textView.setAccessibilityLabel(parent.accessibilityLabel)
            view.textView.setAccessibilityHelp(parent.accessibilityHint)
            view.markupStyler.configure(MarkupEditorStyler.Configuration(
                isEnabled: true,
                pauseDefaults: parent.pauseDefaults,
                palette: MarkupEditorPalette(
                    fontSize: appearance.fontSize,
                    textColor: appearance.textColor,
                    secondaryColor: appearance.secondaryTextColor,
                    accentColor: appearance.accentColor,
                    rhythmColor: appearance.accentColor,
                    backgroundColor: appearance.backgroundColor
                )
            ))
            // `configure` re-highlights the whole document when the palette
            // changes and would overwrite the header fonts; put them back.
            if view.textView.textStorage?.length ?? 0 > 0 {
                applyHeaderAttributes(in: view.textView)
            }
            view.alphaValue = 1
        }

        // MARK: NSTextViewDelegate

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingProgrammaticUpdate else { return false }
            let target = (textView.hasMarkedText()
                ? resolveMarkedTextEdit(in: affectedCharRange, textView: textView)
                : nil)
                ?? layout.resolveEdit(in: affectedCharRange)
            guard let target else {
                pendingEdit = nil
                if applyClampedEdit(in: affectedCharRange, replacementString: replacementString, textView: textView) {
                    return false
                }
                rejectEdit()
                return false
            }
            pendingEdit = PendingEdit(
                target: target,
                documentLength: layout.utf16Length
            )
            return true
        }

        /// A triple-click on the last paragraph of a scene selects it together
        /// with the protected separator newline. Instead of rejecting the edit,
        /// clamp the range to the scene body and apply it ourselves (AppKit is
        /// told "no" because it cannot change the range). Returns true when the
        /// edit was handled.
        private func applyClampedEdit(
            in range: NSRange,
            replacementString: String?,
            textView: NSTextView
        ) -> Bool {
            guard let replacementString,
                  !textView.hasMarkedText(),
                  range.location >= 0, range.length > 0,
                  let segment = layout.segments.first(where: { segment in
                      !segment.isCollapsed
                          && range.location >= segment.bodyRange.location
                          && range.location <= NSMaxRange(segment.bodyRange)
                          && NSMaxRange(range) == NSMaxRange(segment.separatorRange)
                  }) else { return false }
            let body = segment.bodyRange
            let clamped = NSRange(
                location: range.location,
                length: NSMaxRange(body) - range.location
            )
            guard let target = layout.resolveEdit(in: clamped) else { return false }
            if clamped.length == 0, replacementString.isEmpty { return true }
            guard let storage = textView.textStorage else { return false }
            let pending = PendingEdit(target: target, documentLength: layout.utf16Length)
            isApplyingProgrammaticUpdate = true
            storage.replaceCharacters(
                in: clamped,
                with: NSAttributedString(string: replacementString, attributes: bodyAttributes())
            )
            textView.setSelectedRange(NSRange(
                location: clamped.location + (replacementString as NSString).length,
                length: 0
            ))
            isApplyingProgrammaticUpdate = false
            applyAuthorizedChange(pending, in: textView)
            return true
        }

        /// While an IME composition is open, NSTextStorage temporarily contains
        /// marked text that the layout does not know about. A replace/delete of
        /// that marked run can therefore extend past the old body end. The
        /// fixed suffix after the body still identifies where the live body
        /// ends, so the edit stays confined to the same scene.
        private func resolveMarkedTextEdit(
            in range: NSRange,
            textView: NSTextView
        ) -> FullScriptEditTarget? {
            let currentDocumentLength = (textView.string as NSString).length
            guard range.location >= 0, range.length >= 0 else { return nil }
            let markedRange = textView.markedRange()
            let markedSceneID = markedRange.location == NSNotFound
                ? nil
                : layout.sceneID(atUTF16Location: markedRange.location)
            for segment in layout.segments where !segment.isCollapsed {
                if let markedSceneID, segment.sceneID != markedSceneID { continue }
                let body = segment.bodyRange
                let fixedSuffixLength = layout.utf16Length - NSMaxRange(body)
                let currentBodyEnd = body.location + currentDocumentLength - fixedSuffixLength
                guard currentBodyEnd >= body.location else { continue }
                if range.length == 0 {
                    guard range.location >= body.location,
                          range.location <= currentBodyEnd else { continue }
                } else {
                    guard range.location >= body.location,
                          range.length <= currentBodyEnd - range.location else { continue }
                }
                let localLocation = min(max(0, range.location - body.location), body.length)
                let localLength = min(range.length, max(0, body.length - localLocation))
                return FullScriptEditTarget(
                    sceneID: segment.sceneID,
                    localRange: NSRange(location: localLocation, length: localLength),
                    bodyRange: body
                )
            }
            return nil
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate,
                  let textView = notification.object as? NSTextView,
                  textView === view?.textView else { return }
            guard let pending = pendingEdit else {
                if textView.hasMarkedText() {
                    return
                }
                // No authorized edit produced this change. The only safe
                // recovery is the model's text; never let stray storage stay.
                if textView.string != layout.text {
                    rebuildDocument(
                        preserving: currentSceneSelection(),
                        scroll: currentScrollOrigin(),
                        restyleBodies: true
                    )
                    rejectEdit()
                }
                return
            }
            pendingEdit = nil
            applyAuthorizedChange(pending, in: textView)
            if pendingModelRefresh {
                applyDeferredExternalChanges(keepingLocalTextFor: pending.target.sceneID)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingProgrammaticUpdate,
                  let textView = notification.object as? NSTextView,
                  textView === view?.textView else { return }
            if !textView.hasMarkedText() {
                view?.textView.typingAttributes = bodyAttributes()
            }
            reportCaretSceneIfNeeded()
            captureRestorationState()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  textView === view?.textView else { return }
            if textView.hasMarkedText() { textView.unmarkText() }
            // `unmarkText()` can itself emit an end-editing notification while
            // its replacement shouldChange calls are still in flight. Merging
            // there would use the pre-composition parent and erase the final
            // composition text; the textDidChange path owns that merge.
            if pendingModelRefresh, pendingEdit == nil, !textView.hasMarkedText() {
                applyDeferredExternalChanges(keepingLocalTextFor: nil)
            }
            captureRestorationState()
        }

        // MARK: Authorized edit

        private func applyAuthorizedChange(_ pending: PendingEdit, in textView: NSTextView) {
            let text = textView.string
            let nsText = text as NSString
            let newDocumentLength = nsText.length
            let oldBodyEnd = NSMaxRange(pending.target.bodyRange)
            let fixedSuffixLength = pending.documentLength - oldBodyEnd
            let bodyStart = pending.target.bodyRange.location
            let newBodyLength = newDocumentLength - bodyStart - fixedSuffixLength

            let bodyEnd = bodyStart + newBodyLength
            guard newBodyLength >= 0,
                  bodyStart >= 1,
                  bodyEnd >= bodyStart,
                  bodyEnd + 1 <= newDocumentLength,
                  nsText.character(at: bodyStart - 1) == 10,
                  nsText.character(at: bodyEnd) == 10 else {
                // AppKit changed more than the authorized body. The model is
                // still authoritative; restore it and reject the keystroke.
                rebuildDocument(
                    preserving: pending.target.bodyRange.location == bodyStart
                        ? FullScriptSceneSelection(
                            sceneID: pending.target.sceneID,
                            range: NSRange(location: 0, length: 0)
                        )
                        : currentSceneSelection(),
                    scroll: currentScrollOrigin(),
                    restyleBodies: true
                )
                rejectEdit()
                return
            }

            let newBody = nsText.substring(with: NSRange(location: bodyStart, length: newBodyLength))
            guard let index = sceneSnapshots.firstIndex(where: { $0.id == pending.target.sceneID }) else {
                rebuildDocument(preserving: nil, scroll: currentScrollOrigin(), restyleBodies: true)
                return
            }
            // Stale write-back guard: the model owns the text. If the view's
            // pre-edit body differs from the model, another writer (single
            // scene editor, AI insert, reload) changed it since the last
            // rebuild. Rebuild from the model and reject this keystroke.
            if let modelText = parent.currentSceneText(pending.target.sceneID),
               modelText != sceneSnapshots[index].scriptText {
                resyncFromModel()
                rejectEdit()
                return
            }
            let previousBody = sceneSnapshots[index].scriptText
            guard newBody != previousBody else { return }

            let selectionBeforeUndo = FullScriptSceneSelection(
                sceneID: pending.target.sceneID,
                range: pending.target.localRange
            )
            sceneSnapshots[index].scriptText = newBody
            parent.onSceneTextCommitted(pending.target.sceneID, previousBody, newBody)
            layout = Self.makeLayout(scenes: sceneSnapshots)

            restyleBody(sceneID: pending.target.sceneID, in: textView)
            reportCaretSceneIfNeeded()
            captureRestorationState()

            let selectionAfterEdit = currentSceneSelection()
            FullScriptUndoHub.shared.register(
                sceneID: pending.target.sceneID,
                previousText: previousBody,
                newText: newBody,
                selectionBeforeEdit: selectionBeforeUndo,
                selectionAfterEdit: selectionAfterEdit,
                currentText: parent.currentSceneText,
                commit: parent.onSceneTextCommitted,
                actionName: parent.undoActionName.isEmpty ? nil : parent.undoActionName,
                in: textView.window?.undoManager ?? textView.undoManager
            )
        }

        /// Replaces every scene body the view holds with the model's text and
        /// rebuilds the document. Used when a write-back would have used a
        /// stale snapshot.
        private func resyncFromModel() {
            for index in sceneSnapshots.indices {
                if let text = parent.currentSceneText(sceneSnapshots[index].id) {
                    sceneSnapshots[index].scriptText = text
                }
            }
            layout = Self.makeLayout(scenes: sceneSnapshots)
            pendingEdit = nil
            FullScriptUndoHub.shared.breakCoalescing()
            rebuildDocument(
                preserving: currentSceneSelection(),
                scroll: currentScrollOrigin(),
                restyleBodies: true
            )
        }

        /// Applies one undo/redo swap from the undo hub. Returns the committed
        /// text so the hub can register the inverse step.
        @discardableResult
        func applyUndoText(
            sceneID: UUID,
            text: String,
            selection: FullScriptSceneSelection?
        ) -> Bool {
            guard let view,
                  let index = sceneSnapshots.firstIndex(where: { $0.id == sceneID }) else {
                return false
            }
            if view.textView.hasMarkedText() { view.textView.unmarkText() }
            pendingEdit = nil
            let previous = sceneSnapshots[index].scriptText
            if previous != text {
                sceneSnapshots[index].scriptText = text
                parent.onSceneTextCommitted(sceneID, previous, text)
                layout = Self.makeLayout(scenes: sceneSnapshots)
            }
            rebuildDocument(
                preserving: selection,
                scroll: currentScrollOrigin(),
                restyleBodies: true
            )
            return true
        }

        func canHandleUndoManager(_ manager: UndoManager) -> Bool {
            guard let view else { return false }
            let ownManager = view.textView.window?.undoManager ?? view.textView.undoManager
            return ownManager === manager
        }

        func currentSceneSelection() -> FullScriptSceneSelection? {
            guard let view else { return nil }
            let range = view.textView.selectedRange()
            guard let sceneID = layout.sceneID(atUTF16Location: range.location),
                  let segment = layout.segment(for: sceneID) else { return nil }
            let offset = min(
                max(0, range.location - segment.bodyRange.location),
                segment.bodyRange.length
            )
            let length = min(max(0, range.length), max(0, segment.bodyRange.length - offset))
            return FullScriptSceneSelection(
                sceneID: sceneID,
                range: NSRange(location: offset, length: length)
            )
        }

        // MARK: Document construction

        private static func makeLayout(scenes: [FullScriptSceneSnapshot]) -> FullScriptLayout {
            FullScriptLayout(scenes: scenes.map(\.descriptor))
        }

        private func rebuildDocument(
            preserving selection: FullScriptSceneSelection?,
            scroll: NSPoint?,
            restyleBodies: Bool
        ) {
            guard let view else { return }
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }

            let textView = view.textView
            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributedString(attributedDocument())
            storage?.endEditing()
            textView.font = NSFont.systemFont(ofSize: parent.appearance.fontSize)
            textView.textColor = parent.appearance.textColor
            textView.defaultParagraphStyle = ScriptEditorLayout.paragraphStyle()
            textView.typingAttributes = bodyAttributes()

            let target = documentRange(for: selection) ?? defaultSelection()
            textView.setSelectedRange(target)
            view.layoutSubtreeIfNeeded()
            restoreScroll(scroll)
            if restyleBodies {
                var applied = 0
                for segment in layout.segments where !segment.isCollapsed && segment.bodyRange.length > 0 {
                    view.markupStyler.apply(
                        charactersIn: segment.bodyRange,
                        textView: textView
                    )
                    applied = max(applied, view.markupStyler.lastAppliedCharacterCount)
                }
                lastAppliedCharacterCount = applied
            }
            applyHeaderAttributes(in: textView)
            textView.needsDisplay = true
            reportCaretSceneIfNeeded()
            captureRestorationState()
        }

        private func attributedDocument() -> NSAttributedString {
            let result = NSMutableAttributedString()
            let headerNewline = headerNewlineAttributes()
            let body = bodyAttributes()
            let separatorAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: parent.appearance.fontSize),
                .foregroundColor: parent.appearance.secondaryTextColor,
                .paragraphStyle: ScriptEditorLayout.paragraphStyle()
            ]
            for scene in sceneSnapshots {
                result.append(headerAttributedString(for: scene))
                result.append(NSAttributedString(string: "\n", attributes: headerNewline))
                if !scene.isCollapsed {
                    result.append(NSAttributedString(string: scene.scriptText, attributes: body))
                }
                result.append(NSAttributedString(string: "\n", attributes: separatorAttributes))
            }
            return result
        }

        /// Header look follows the single-scene editor's scene header: a
        /// semibold primary title with a quiet secondary meta line. Only the
        /// scene label takes the accent color. Every run uses the system font
        /// (no monospaced face) so number, title and duration read as one line.
        private func headerAttributedString(for scene: FullScriptSceneSnapshot) -> NSAttributedString {
            let appearance = parent.appearance
            let text = scene.headerText
            let isFirst = scene.id == sceneSnapshots.first?.id
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacingBefore = isFirst ? 4 : Self.headerSpacingBefore
            paragraph.paragraphSpacing = 8
            let titleFont = NSFont.systemFont(
                ofSize: max(17, appearance.fontSize * 0.9),
                weight: .semibold
            )
            let metaFont = NSFont.systemFont(
                ofSize: max(11, appearance.fontSize * 0.6),
                weight: .medium
            )
            let sceneID = scene.id.uuidString
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: metaFont,
                .foregroundColor: appearance.secondaryTextColor,
                .paragraphStyle: paragraph,
                .fullScriptHeaderSceneID: sceneID
            ])
            let nsText = text as NSString
            guard nsText.length > 0 else { return attributed }

            // Chevron.
            attributed.addAttribute(.foregroundColor, value: appearance.accentColor,
                                    range: NSRange(location: 0, length: 1))

            let numberRange = nsText.range(of: scene.numberText)
            let durationRange = nsText.range(of: scene.durationText, options: .backwards)
            if numberRange.location != NSNotFound {
                // "ESCENA 01": the label starts at the first letter after the chevron.
                var labelStart = 1
                while labelStart < numberRange.location,
                      CharacterSet.whitespaces.contains(UnicodeScalar(nsText.character(at: labelStart)) ?? " ") {
                    labelStart += 1
                }
                attributed.addAttributes([
                    .foregroundColor: appearance.accentColor,
                    .font: NSFont.systemFont(ofSize: metaFont.pointSize, weight: .semibold)
                ], range: NSRange(location: labelStart, length: NSMaxRange(numberRange) - labelStart))

                // Title: between the dot after the number and the dot before the duration.
                var titleStart = NSMaxRange(numberRange)
                let tail = NSRange(location: titleStart, length: nsText.length - titleStart)
                let dot = nsText.range(of: "·", range: tail)
                if dot.location != NSNotFound {
                    titleStart = NSMaxRange(dot)
                    while titleStart < nsText.length,
                          CharacterSet.whitespaces.contains(UnicodeScalar(nsText.character(at: titleStart)) ?? "x") {
                        titleStart += 1
                    }
                    var titleEnd = durationRange.location != NSNotFound && durationRange.location > titleStart
                        ? durationRange.location
                        : nsText.length
                    while titleEnd > titleStart {
                        let scalar = UnicodeScalar(nsText.character(at: titleEnd - 1)) ?? "x"
                        if CharacterSet.whitespaces.contains(scalar) || scalar == "·" { titleEnd -= 1 } else { break }
                    }
                    if titleEnd > titleStart {
                        attributed.addAttributes([
                            .font: titleFont,
                            .foregroundColor: appearance.textColor
                        ], range: NSRange(location: titleStart, length: titleEnd - titleStart))
                    }
                }
            }
            if durationRange.location != NSNotFound {
                attributed.addAttributes([
                    .font: NSFont.monospacedDigitSystemFont(ofSize: metaFont.pointSize, weight: .medium),
                    .foregroundColor: appearance.secondaryTextColor
                ], range: durationRange)
            }
            return attributed
        }

        /// Space above every scene header except the first.
        static let headerSpacingBefore: CGFloat = 30

        private func headerNewlineAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: parent.appearance.fontSize),
                .foregroundColor: parent.appearance.secondaryTextColor,
                .paragraphStyle: ScriptEditorLayout.paragraphStyle()
            ]
        }

        private func bodyAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: parent.appearance.fontSize),
                .foregroundColor: parent.appearance.textColor,
                .paragraphStyle: ScriptEditorLayout.paragraphStyle()
            ]
        }

        /// Header fonts are real attributes; restore them after the markup
        /// styler runs so a body-only pass can never repaint a protected header.
        private func applyHeaderAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            storage.beginEditing()
            for scene in sceneSnapshots {
                guard let segment = layout.segment(for: scene.id) else { continue }
                let header = headerAttributedString(for: scene)
                guard header.length > 0 else { continue }
                let visibleLength = min(header.length, segment.headerRange.length)
                guard visibleLength > 0 else { continue }
                header.enumerateAttributes(
                    in: NSRange(location: 0, length: visibleLength),
                    options: []
                ) { attributes, range, _ in
                    let target = NSRange(
                        location: segment.headerRange.location + range.location,
                        length: range.length
                    )
                    guard NSMaxRange(target) <= storage.length else { return }
                    storage.setAttributes(attributes, range: target)
                }
                let newlineLocation = segment.headerRange.location + visibleLength
                if newlineLocation < storage.length {
                    storage.setAttributes(
                        headerNewlineAttributes(),
                        range: NSRange(location: newlineLocation, length: 1)
                    )
                }
            }
            storage.endEditing()
        }

        private func restyleBody(sceneID: UUID, in textView: NSTextView) {
            guard let segment = layout.segment(for: sceneID),
                  segment.bodyRange.length > 0 else { return }
            view?.markupStyler.apply(charactersIn: segment.bodyRange, textView: textView)
            lastAppliedCharacterCount = view?.markupStyler.lastAppliedCharacterCount ?? 0
        }

        // MARK: Selection, caret and scroll

        private func initialSelection(from restoration: ScriptEditorRestorationState?) -> FullScriptSceneSelection? {
            guard let restored = restoration else { return nil }
            return selection(fromDocumentRange: restored.selectedRange)
        }

        private func defaultSelection() -> NSRange {
            guard let first = layout.segments.first else { return NSRange(location: 0, length: 0) }
            return NSRange(location: first.bodyRange.location, length: 0)
        }

        private func documentRange(for selection: FullScriptSceneSelection?) -> NSRange? {
            guard let selection,
                  let segment = layout.segment(for: selection.sceneID) else { return nil }
            let bodyLength = segment.bodyRange.length
            let location = segment.bodyRange.location + min(max(0, selection.range.location), bodyLength)
            let length = min(max(0, selection.range.length), max(0, bodyLength - (location - segment.bodyRange.location)))
            return NSRange(location: location, length: length)
        }

        private func selection(fromDocumentRange range: NSRange) -> FullScriptSceneSelection? {
            let clamped = clampedDocumentRange(range)
            guard let sceneID = layout.sceneID(atUTF16Location: clamped.location),
                  let segment = layout.segment(for: sceneID) else { return nil }
            let offset = min(
                max(0, clamped.location - segment.bodyRange.location),
                segment.bodyRange.length
            )
            let length = min(max(0, clamped.length), max(0, segment.bodyRange.length - offset))
            return FullScriptSceneSelection(
                sceneID: sceneID,
                range: NSRange(location: offset, length: length)
            )
        }

        private func clampedDocumentRange(_ range: NSRange) -> NSRange {
            TextAnchorGeometry.clamp(range, toLength: layout.utf16Length)
        }

        private func currentScrollOrigin() -> NSPoint? {
            view?.scrollView.contentView.bounds.origin
        }

        private func restoreScroll(_ origin: NSPoint?) {
            guard let view, let origin else { return }
            view.layoutSubtreeIfNeeded()
            let documentBounds = view.scrollView.documentView?.bounds ?? .zero
            let clipSize = view.scrollView.contentView.bounds.size
            let maximumX = max(documentBounds.minX, documentBounds.maxX - clipSize.width)
            let maximumY = max(documentBounds.minY, documentBounds.maxY - clipSize.height)
            let clamped = NSPoint(
                x: min(max(origin.x, documentBounds.minX), maximumX),
                y: min(max(origin.y, documentBounds.minY), maximumY)
            )
            view.scrollView.contentView.scroll(to: clamped)
            view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        }

        @objc private func scrollBoundsChanged() {
            captureRestorationState()
        }

        func captureRestorationState() {
            guard let view else { return }
            view.layoutSubtreeIfNeeded()
            let visibleOrigin = view.scrollView.contentView.bounds.origin
            let state = ScriptEditorRestorationState(
                selectedRange: view.textView.selectedRange(),
                visibleOrigin: visibleOrigin
            )
            parent.saveRestorationState(state)
        }

        private func currentCaretSceneID() -> UUID? {
            guard let view else { return nil }
            return layout.sceneID(atUTF16Location: view.textView.selectedRange().location)
        }

        private func reportCaretSceneIfNeeded(deferred: Bool = false) {
            guard let view, !view.textView.hasMarkedText() else { return }
            let sceneID = currentCaretSceneID()
            guard sceneID != lastCaretSceneID else { return }
            guard !deferred, !isApplyingProgrammaticUpdate else {
                DispatchQueue.main.async { [weak self] in
                    self?.reportCaretSceneIfNeeded()
                }
                return
            }
            lastCaretSceneID = sceneID
            parent.onCaretSceneChanged(sceneID)
        }

        // MARK: Header click

        private func headerSceneID(atUTF16Location location: Int) -> UUID? {
            for segment in layout.segments {
                let header = segment.headerRange
                if location >= header.location, location < NSMaxRange(header) {
                    return segment.sceneID
                }
            }
            return nil
        }

        // MARK: Rejection

        private func rejectEdit() {
#if !DEBUG
            NSSound.beep()
#else
            if !AppEnvironment.isRunningTests {
                NSSound.beep()
            }
#endif
        }

        // MARK: ActiveScriptEditor

        var sceneID: UUID {
            currentCaretSceneID() ?? sceneSnapshots.first?.id ?? fallbackSceneID
        }

        var owningWindow: NSWindow? {
            view?.textView.window
        }

        var isActualFirstResponder: Bool {
            guard let textView = view?.textView else { return false }
            return textView.window?.firstResponder === textView
        }

        @discardableResult
        func commitMarkedTextAndFlush() -> Bool {
            guard let textView = view?.textView else { return false }
            let before = textView.string
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            if let pending = pendingEdit {
                pendingEdit = nil
                applyAuthorizedChange(pending, in: textView)
            }
            return textView.string != before
        }

        func cancelAutocomplete(clearStatus: Bool) {}

        func selectRange(_ range: NSRange) {
            guard let view,
                  let sceneID = currentCaretSceneID(),
                  let segment = layout.segment(for: sceneID) else { return }
            let local = TextAnchorGeometry.clamp(range, toLength: segment.bodyRange.length)
            let absolute = NSRange(
                location: segment.bodyRange.location + local.location,
                length: local.length
            )
            view.textView.setSelectedRange(absolute)
            view.textView.scrollRangeToVisible(absolute)
            view.textView.window?.makeFirstResponder(view.textView)
            reportCaretSceneIfNeeded()
            captureRestorationState()
        }

        func currentSelectionAnchor() -> TextAnchor? {
            guard let view,
                  let scene = sceneSnapshots.first(where: { $0.id == currentCaretSceneID() }),
                  let segment = layout.segment(for: scene.id) else { return nil }
            let selected = view.textView.selectedRange()
            guard selected.length > 0,
                  selected.location >= segment.bodyRange.location,
                  NSMaxRange(selected) <= NSMaxRange(segment.bodyRange) else { return nil }
            let local = NSRange(
                location: selected.location - segment.bodyRange.location,
                length: selected.length
            )
            return TextAnchorRepair.anchor(in: scene.scriptText, range: local)
        }

        @discardableResult
        func insertMarkup(_ insertion: UXMarkupInsertion) -> Bool {
            guard let view,
                  currentSceneSelection() != nil,
                  layout.resolveEdit(in: view.textView.selectedRange()) != nil else {
                rejectEdit()
                return false
            }
            return UXMarkupInsertionEngine.insert(insertion, into: view.textView) != nil
        }
    }
}

// MARK: - Container

final class FullScriptTextContainerView: NSView {
    let scrollView = NSScrollView()
    let textView = FullScriptEditableTextView()
    let markupStyler = MarkupEditorStyler()
    weak var coordinator: FullScriptTextView.Coordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        markupStyler.attach(to: textView)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 0)
        textView.maxSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}

/// Text view that turns a click on a protected scene header into a
/// collapse/expand action. Header ranges come from the coordinator's map; the
/// view never edits or reinterprets the document itself.
final class FullScriptEditableTextView: PlaceholderTextView {
    var headerSceneProvider: ((Int) -> UUID?)?
    var headerClickAction: ((UUID) -> Void)?
    /// Header ranges in document order; the first one never gets a hairline.
    var headerRangesProvider: (() -> [NSRange])?
    var headerSeparatorColor: NSColor?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawHeaderHairlines(in: dirtyRect)
    }

    /// Subtle hairline above each scene header (not the first), centred in the
    /// extra space the header's paragraph spacing creates.
    private func drawHeaderHairlines(in dirtyRect: NSRect) {
        guard let color = headerSeparatorColor,
              let ranges = headerRangesProvider?(),
              ranges.count > 1,
              let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        // Only headers whose line can reach the dirty rect. Asking TextKit for
        // the line rect of every header forced layout of the whole document on
        // each redraw (one per keystroke) in a long script.
        let reach = FullScriptTextView.Coordinator.headerSpacingBefore
        let containerRect = dirtyRect
            .insetBy(dx: 0, dy: -reach)
            .offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let visibleCharacters = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        color.setFill()
        for range in ranges.dropFirst() where range.location < length
            && range.location >= visibleCharacters.location
            && range.location <= NSMaxRange(visibleCharacters) {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = used.minY + textContainerOrigin.y - FullScriptTextView.Coordinator.headerSpacingBefore * 0.5
            let rect = NSRect(
                x: textContainerOrigin.x,
                y: y.rounded() - 0.5,
                width: textContainer.size.width,
                height: 1
            )
            if rect.intersects(dirtyRect) { rect.fill() }
        }
    }

    /// `allowsUndo` is false because native text undo would replay raw storage
    /// ranges instead of scene text. These actions keep the standard Edit menu
    /// and Cmd-Z pointed at the window's undo manager, where the full-script
    /// steps live.
    @objc func undo(_ sender: Any?) {
        window?.undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        window?.undoManager?.redo()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            return window?.undoManager?.canUndo ?? false
        }
        if item.action == #selector(redo(_:)) {
            return window?.undoManager?.canRedo ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let sceneID = headerSceneID(at: event) {
            if hasMarkedText() { unmarkText() }
            window?.makeFirstResponder(self)
            headerClickAction?(sceneID)
            return
        }
        super.mouseDown(with: event)
    }

    private func headerSceneID(at event: NSEvent) -> UUID? {
        guard let headerSceneProvider, let layoutManager, let textContainer,
              (string as NSString).length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return headerSceneProvider(characterIndex)
    }
}
