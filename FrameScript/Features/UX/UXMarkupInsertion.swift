import AppKit

/// The inline markup the editor action bar can insert at the caret.
///
/// Every case maps to syntax the parser already understands
/// (`ScriptMarkup`): `/` and `//` are pauses between whitespace, and
/// `[B-ROLL]` / `[IMAGEN: …]` are single-line bracket cues. No new syntax is
/// introduced here.
enum UXMarkupInsertion: String, CaseIterable, Identifiable, Sendable {
    case shortPause
    case longPause
    case bRollCue
    case imageCue

    var id: String { rawValue }

    /// The token written into the script.
    var token: String {
        switch self {
        case .shortPause: "/"
        case .longPause: "//"
        case .bRollCue: "[B-ROLL]"
        case .imageCue: "[IMAGEN: ]"
        }
    }

    /// Where the caret lands after insertion, measured in UTF-16 units from the
    /// start of the token. The image cue leaves the caret inside the brackets so
    /// the description can be typed straight away.
    var caretOffsetInToken: Int {
        switch self {
        case .imageCue: ("[IMAGEN: " as NSString).length
        case .shortPause, .longPause, .bRollCue: (token as NSString).length
        }
    }

    /// Computes the exact replacement without touching a text view, so the
    /// spacing rules stay unit-testable.
    ///
    /// Tokens are inline and need a word break on each side that has content:
    /// `Hola/adiós` is not a pause and `Hola[B-ROLL]` is not a cue the user can
    /// read. Existing whitespace is never doubled.
    func plan(in text: NSString, replacing range: NSRange) -> UXMarkupInsertionPlan {
        let target = TextAnchorGeometry.clamp(range, toLength: text.length)
        let needsLeadingSpace = target.location > 0
            && !Self.isWhitespace(text.character(at: target.location - 1))
        let afterLocation = NSMaxRange(target)
        let needsTrailingSpace = afterLocation < text.length
            && !Self.isWhitespace(text.character(at: afterLocation))

        let replacement = (needsLeadingSpace ? " " : "")
            + token
            + (needsTrailingSpace ? " " : "")
        let tokenStart = target.location + (needsLeadingSpace ? 1 : 0)
        let caret = tokenStart + caretOffsetInToken

        return UXMarkupInsertionPlan(
            replacementRange: target,
            replacementText: replacement,
            selectedRange: NSRange(location: caret, length: 0)
        )
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}

/// A resolved insertion. Every range is a UTF-16 `NSRange` into the script.
struct UXMarkupInsertionPlan: Equatable, Sendable {
    let replacementRange: NSRange
    let replacementText: String
    let selectedRange: NSRange
}

/// Applies an insertion through `NSTextView`'s normal typing path.
///
/// `insertText(_:replacementRange:)` is the same entry point the autocomplete
/// ghost text uses. It registers exactly one undo action, notifies the delegate
/// (`textDidChange`), and keeps the text view's first-responder status
/// untouched, so the styler, anchors and autosave all run as if the user had
/// typed the marker.
@MainActor
enum UXMarkupInsertionEngine {
    @discardableResult
    static func insert(_ insertion: UXMarkupInsertion, into textView: NSTextView) -> UXMarkupInsertionPlan? {
        guard textView.isEditable else { return nil }
        if textView.hasMarkedText() {
            textView.unmarkText()
        }
        let plan = insertion.plan(
            in: textView.string as NSString,
            replacing: textView.selectedRange()
        )
        // Start a fresh undo group so the insertion is one step even when the
        // user typed a character a moment earlier.
        textView.breakUndoCoalescing()
        textView.insertText(plan.replacementText, replacementRange: plan.replacementRange)

        let length = (textView.string as NSString).length
        let clamped = TextAnchorGeometry.clamp(plan.selectedRange, toLength: length)
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
        return UXMarkupInsertionPlan(
            replacementRange: plan.replacementRange,
            replacementText: plan.replacementText,
            selectedRange: clamped
        )
    }
}
