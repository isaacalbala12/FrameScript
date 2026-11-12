import AppKit
import FrameScriptCore

/// Fonts and colors used to paint markup and rhythm warnings in the script
/// editor. Built from `FrameTheme` so both appearance modes stay legible.
struct MarkupEditorPalette: Equatable {
    var baseFont: NSFont
    var baseColor: NSColor
    var delimiterColor: NSColor
    var pauseColor: NSColor
    var pauseBackground: NSColor
    var cueColor: NSColor
    var cueBackground: NSColor
    var cueFont: NSFont
    var emphasisFont: NSFont
    var strongFont: NSFont
    var rhythmColor: NSColor
    @MainActor
    init(
        fontSize: Double,
        textColor: NSColor,
        secondaryColor: NSColor,
        accentColor: NSColor,
        rhythmColor: NSColor
    ) {
        let base = NSFont.systemFont(ofSize: fontSize)
        self.baseFont = base
        self.baseColor = textColor
        self.delimiterColor = secondaryColor.withAlphaComponent(0.55)
        self.pauseColor = accentColor.blended(withFraction: 0.15, of: secondaryColor) ?? accentColor
        self.pauseBackground = accentColor.withAlphaComponent(0.14)
        self.cueColor = secondaryColor
        self.cueBackground = secondaryColor.withAlphaComponent(0.10)
        self.cueFont = NSFont.monospacedSystemFont(ofSize: max(9, fontSize * 0.80), weight: .medium)
        self.emphasisFont = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        self.strongFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        self.rhythmColor = rhythmColor
    }
}

/// Applies `MarkupHighlightPlanner` runs to a TextKit 1 text view.
///
/// Emphasis and cue sizes are real font attributes (TextKit temporary
/// attributes do not affect layout), while colors and pause pills are temporary
/// attributes so they never enter the document, the undo stack or the typing
/// attributes. Attribute edits are wrapped in
/// `disableUndoRegistration()`/`enableUndoRegistration()`.
@MainActor
final class MarkupEditorStyler {
    struct Configuration: Equatable {
        var isEnabled: Bool
        var pauseDefaults: PauseDefaults
        var palette: MarkupEditorPalette
    }

    weak var textView: NSTextView?
    private(set) var configuration: Configuration?
    /// Duration of the most recent incremental re-highlight, for diagnostics
    /// and the performance test.
    private(set) var lastApplyDuration: TimeInterval = 0
    private(set) var lastAppliedCharacterCount = 0

    private static let temporaryColorKeys: [NSAttributedString.Key] = [
        .foregroundColor,
        .backgroundColor
    ]

    func attach(to textView: NSTextView) {
        self.textView = textView
    }

    /// Applies a new configuration, re-highlighting the whole document only when
    /// something visible changed.
    func configure(_ configuration: Configuration) {
        let previous = self.configuration
        guard previous != configuration else { return }
        self.configuration = configuration
        guard let textView else { return }
        if configuration.isEnabled {
            applyAll(in: textView)
        } else {
            clear(in: NSRange(location: 0, length: (textView.string as NSString).length), textView: textView)
        }
    }

    /// Re-highlights the whole document. Used when the model replaces the text
    /// or the theme/font size changes.
    func applyAll(in textView: NSTextView) {
        let length = (textView.string as NSString).length
        apply(charactersIn: NSRange(location: 0, length: length), textView: textView)
    }

    /// Re-highlights the paragraphs around `range` (the caret/edited range).
    func apply(around range: NSRange, in textView: NSTextView) {
        let text = textView.string as NSString
        let target = MarkupHighlightPlanner.extendedParagraphRange(around: range, in: text)
        apply(charactersIn: target, textView: textView)
    }

    private func apply(charactersIn range: NSRange, textView: NSTextView) {
        let started = DispatchTime.now()
        defer {
            lastApplyDuration = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        }
        guard let configuration, configuration.isEnabled else {
            clear(in: range, textView: textView)
            return
        }
        guard !textView.hasMarkedText() else { return }

        let fullText = textView.string
        let nsText = fullText as NSString
        let target = MarkupHighlightPlanner.clamp(range, toLength: nsText.length)
        guard target.length > 0 else { return }
        lastAppliedCharacterCount = target.length

        let palette = configuration.palette
        let storage = textView.textStorage
        let layoutManager = textView.layoutManager

        // Colors from a previous pass are temporary; font attributes are real.
        for key in Self.temporaryColorKeys {
            layoutManager?.removeTemporaryAttribute(key, forCharacterRange: target)
        }

        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        storage?.beginEditing()
        storage?.addAttribute(.font, value: palette.baseFont, range: target)

        let runs = MarkupHighlightPlanner.highlightRuns(
            text: fullText,
            pauseDefaults: configuration.pauseDefaults,
            in: target
        )
        for run in runs {
            switch run.style {
            case .emphasis:
                storage?.addAttribute(.font, value: palette.emphasisFont, range: run.range)
            case .strongEmphasis:
                storage?.addAttribute(.font, value: palette.strongFont, range: run.range)
            case .cue:
                storage?.addAttribute(.font, value: palette.cueFont, range: run.range)
                addTemporary(
                    [.foregroundColor: palette.cueColor, .backgroundColor: palette.cueBackground],
                    range: run.range,
                    layoutManager: layoutManager,
                    storage: storage
                )
            case .shortPause, .longPause, .explicitPause:
                addTemporary(
                    [.foregroundColor: palette.pauseColor, .backgroundColor: palette.pauseBackground],
                    range: run.range,
                    layoutManager: layoutManager,
                    storage: storage
                )
            case .delimiter:
                addTemporary(
                    [.foregroundColor: palette.delimiterColor],
                    range: run.range,
                    layoutManager: layoutManager,
                    storage: storage
                )
            }
        }
        storage?.endEditing()
        undoManager?.enableUndoRegistration()
    }

    private func addTemporary(
        _ attributes: [NSAttributedString.Key: Any],
        range: NSRange,
        layoutManager: NSLayoutManager?,
        storage: NSTextStorage?
    ) {
        if let layoutManager {
            layoutManager.addTemporaryAttributes(attributes, forCharacterRange: range)
        } else {
            // Fallback for a TextKit 2 view: colors become document attributes.
            storage?.addAttributes(attributes, range: range)
        }
    }

    private func clear(in range: NSRange, textView: NSTextView) {
        let nsText = textView.string as NSString
        let target = MarkupHighlightPlanner.clamp(range, toLength: nsText.length)
        guard target.length > 0 else { return }
        let layoutManager = textView.layoutManager
        for key in Self.temporaryColorKeys {
            layoutManager?.removeTemporaryAttribute(key, forCharacterRange: target)
        }
        guard let palette = configuration?.palette, let storage = textView.textStorage else { return }
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        storage.beginEditing()
        storage.addAttribute(.font, value: palette.baseFont, range: target)
        storage.endEditing()
        undoManager?.enableUndoRegistration()
    }
}

/// Text view that draws rhythm warnings as a wavy underline and exposes a
/// tooltip per warning range.
///
/// The wave is drawn in `draw(_:)` instead of using
/// `NSUnderlineStyle.patternDot`, so it stays visibly different from the
/// system's red dotted spelling underline and never touches the text storage.
final class MarkupEditorTextView: PlaceholderTextView, NSViewToolTipOwner {
    var rhythmUnderlines: [RhythmEditorUnderline] = [] {
        didSet {
            guard rhythmUnderlines != oldValue else { return }
            needsDisplay = true
            refreshRhythmToolTips()
        }
    }

    var rhythmUnderlineColor: NSColor = .systemOrange {
        didSet { needsDisplay = true }
    }

    private var tooltipMessages: [NSView.ToolTipTag: String] = [:]
    private var lastToolTipLayoutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        if abs(bounds.width - lastToolTipLayoutWidth) > 0.5 {
            lastToolTipLayoutWidth = bounds.width
            refreshRhythmToolTips()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawRhythmUnderlines(in: dirtyRect)
    }

    func refreshRhythmToolTips() {
        removeAllToolTips()
        tooltipMessages.removeAll()
        guard !rhythmUnderlines.isEmpty,
              let layoutManager,
              let textContainer,
              let storageLength = textStorage?.length,
              storageLength > 0 else { return }

        for underline in rhythmUnderlines {
            let range = MarkupHighlightPlanner.clamp(underline.range, toLength: storageLength)
            guard range.length > 0 else { continue }
            var actual = NSRange()
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: &actual)
            guard glyphRange.length > 0 else { continue }
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                let characterLineRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                let intersection = NSIntersectionRange(characterLineRange, actual)
                guard intersection.length > 0 else { return }
                let intersectionGlyphs = layoutManager.glyphRange(
                    forCharacterRange: intersection,
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(forGlyphRange: intersectionGlyphs, in: textContainer)
                rect.origin.x += self.textContainerOrigin.x
                rect.origin.y += self.textContainerOrigin.y
                if rect.height < 6 { rect.size.height = 6 }
                rect = rect.insetBy(dx: -1, dy: -3)
                let tag = self.addToolTip(rect, owner: self, userData: nil)
                self.tooltipMessages[tag] = underline.message
                _ = lineRect
            }
        }
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipMessages[tag] ?? ""
    }

    private func drawRhythmUnderlines(in dirtyRect: NSRect) {
        guard !rhythmUnderlines.isEmpty,
              let layoutManager,
              let textContainer,
              let storageLength = textStorage?.length,
              storageLength > 0 else { return }

        rhythmUnderlineColor.setStroke()
        for underline in rhythmUnderlines {
            let range = MarkupHighlightPlanner.clamp(underline.range, toLength: storageLength)
            guard range.length > 0 else { continue }
            var actual = NSRange()
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: &actual)
            guard glyphRange.length > 0 else { continue }
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
                let characterLineRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                let intersection = NSIntersectionRange(characterLineRange, actual)
                guard intersection.length > 0 else { return }
                let intersectionGlyphs = layoutManager.glyphRange(
                    forCharacterRange: intersection,
                    actualCharacterRange: nil
                )
                var rect = layoutManager.boundingRect(forGlyphRange: intersectionGlyphs, in: textContainer)
                rect.origin.x += self.textContainerOrigin.x
                rect.origin.y += self.textContainerOrigin.y
                let squiggleRect = NSRect(
                    x: rect.minX,
                    y: lineRect.maxY + self.textContainerOrigin.y - 2.5,
                    width: max(1, rect.width),
                    height: 3
                )
                guard squiggleRect.intersects(dirtyRect) else { return }
                self.drawSquiggle(in: squiggleRect)
            }
        }
    }

    private func drawSquiggle(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        let wavelength: CGFloat = 5
        var x = rect.minX
        path.move(to: NSPoint(x: x, y: rect.midY))
        var up = false
        while x < rect.maxX {
            x = min(x + wavelength / 2, rect.maxX)
            up.toggle()
            path.line(to: NSPoint(x: x, y: rect.midY + (up ? 1.1 : -1.1)))
        }
        path.stroke()
    }
}
