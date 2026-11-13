import AppKit
import FrameScriptCore

// MARK: - Attributed string builder

/// The text and the bookkeeping the renderer needs after layout.
struct TeleprompterAttributedDocument {
    let attributedString: NSAttributedString
    let sectionHeaderLocations: [Int]
    let sectionHeaderRanges: [NSRange]
    let sectionBodyRanges: [NSRange]
    let visibleCharacterCounts: [Int]
}

/// A single laid-out text line, in content coordinates.
struct TeleprompterFrameSample: Equatable, Sendable {
    var headerFrames: [CGRect] = []
    var bodyLineFrames: [CGRect] = []
    var sectionStarts: [Double] = []
    var sectionHeights: [Double] = []
}

/// Builds the complete teleprompter document once per text/style change.
/// Scrolling then moves this one text view instead of rebuilding SwiftUI nodes.
@MainActor
enum TeleprompterAttributedStringBuilder {
    static let contentTopInset: CGFloat = 64

    private enum Palette {
        static let text = NSColor.white
        static let emphasis = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.36, alpha: 1)
        static let strongEmphasis = NSColor(srgbRed: 1.0, green: 0.94, blue: 0.62, alpha: 1)
        static let cue = NSColor.white.withAlphaComponent(0.38)
        static let pause = NSColor.white.withAlphaComponent(0.34)
        static let header = NSColor.white.withAlphaComponent(0.42)
        static let placeholder = NSColor.white.withAlphaComponent(0.34)
    }

    static func build(
        sections: [TeleprompterSection],
        fontSize: Double,
        emptyScenePlaceholder: String = ""
    ) -> TeleprompterAttributedDocument {
        let builder = Builder(fontSize: CGFloat(fontSize), emptyScenePlaceholder: emptyScenePlaceholder)
        for (index, section) in sections.enumerated() {
            builder.appendSectionHeader(index: index, title: section.title, isFirst: index == 0)
            for run in section.runs {
                switch run {
                case .text(let value):
                    builder.appendVisibleText(value, style: .text)
                case .emphasis(let value, let level):
                    builder.appendVisibleText(value, style: level == .strong ? .strongEmphasis : .emphasis)
                case .pause(let seconds):
                    builder.appendPause(seconds: seconds)
                case .cue(let label):
                    builder.appendCue(label: label)
                }
            }
            builder.finishSection()
        }
        return builder.document
    }

    /// Scene titles often already carry their number ("01 HOOK"). The renderer
    /// adds its own `01`, so strip a leading 1–2 digit ordinal to avoid
    /// "01  01 HOOK" and the extra header width that came with it.
    nonisolated static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        var digits = 0
        while digits < scalars.count, scalars[digits].properties.numericType != nil {
            digits += 1
        }
        guard digits > 0, digits <= 2 else { return trimmed }
        var cursor = digits
        while cursor < scalars.count, CharacterSet.whitespaces.contains(scalars[cursor]) {
            cursor += 1
        }
        if cursor < scalars.count, ".:)-–—·".unicodeScalars.contains(scalars[cursor]) {
            cursor += 1
            while cursor < scalars.count, CharacterSet.whitespaces.contains(scalars[cursor]) {
                cursor += 1
            }
        }
        guard cursor < scalars.count, cursor > digits else { return trimmed }
        return String(String.UnicodeScalarView(scalars[cursor...]))
    }

    /// Encapsulates the append-only state so newline handling and character
    /// counts stay consistent without repeatedly reading the whole string.
    private final class Builder {
        private let fontSize: CGFloat
        private let emptyScenePlaceholder: String
        private let attributed = NSMutableAttributedString()
        private var sectionHeaderLocations: [Int] = []
        private var sectionHeaderRanges: [NSRange] = []
        private var sectionBodyRanges: [NSRange] = []
        private var visibleCharacterCounts: [Int] = []
        private var currentVisibleCount = 0
        private var currentBodyStart = 0
        private var currentHasBlockContent = false
        private var lastAppendedWasNewline = true
        private var pendingBlockBreak = false

        init(fontSize: CGFloat, emptyScenePlaceholder: String) {
            self.fontSize = fontSize
            self.emptyScenePlaceholder = emptyScenePlaceholder
        }

        var document: TeleprompterAttributedDocument {
            TeleprompterAttributedDocument(
                attributedString: attributed,
                sectionHeaderLocations: sectionHeaderLocations,
                sectionHeaderRanges: sectionHeaderRanges,
                sectionBodyRanges: sectionBodyRanges,
                visibleCharacterCounts: visibleCharacterCounts
            )
        }

        // MARK: Sections

        func appendSectionHeader(index: Int, title: String, isFirst: Bool) {
            currentVisibleCount = 0
            if !isFirst {
                ensureNewline()
            }
            let number = String(format: "%02d", index + 1)
            let name = TeleprompterAttributedStringBuilder.displayTitle(title).uppercased()
            let headerText = name.isEmpty ? number : "\(number)  \(name)"

            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = fontSize * 0.45
            style.paragraphSpacingBefore = isFirst ? 0 : fontSize * 0.85
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size: fontSize * 0.32, weight: .semibold),
                .foregroundColor: Palette.header,
                .kern: 1.6,
                .paragraphStyle: style
            ]

            let headerStart = attributed.length
            sectionHeaderLocations.append(headerStart)
            append(headerText, attributes: attributes)
            appendNewline(attributes: attributes)
            sectionHeaderRanges.append(
                NSRange(location: headerStart, length: attributed.length - headerStart)
            )
            currentBodyStart = attributed.length
            currentHasBlockContent = false
            pendingBlockBreak = true
        }

        func finishSection() {
            if currentVisibleCount == 0, !currentHasBlockContent, !emptyScenePlaceholder.isEmpty {
                appendPlaceholder(emptyScenePlaceholder)
            }
            sectionBodyRanges.append(
                NSRange(
                    location: currentBodyStart,
                    length: max(0, attributed.length - currentBodyStart)
                )
            )
            visibleCharacterCounts.append(currentVisibleCount)
            currentVisibleCount = 0
        }

        // MARK: Runs

        func appendVisibleText(_ rawText: String, style: TextStyle) {
            guard !rawText.isEmpty else { return }
            var text = rawText
            if pendingBlockBreak {
                text = TeleprompterBlockText.normalizedAfterBlockBreak(text)
                pendingBlockBreak = false
            }
            guard !text.isEmpty else { return }

            let attributes = attributes(for: style)
            append(text, attributes: attributes)
            currentVisibleCount += text.count
        }

        func appendCue(label: String) {
            ensureNewline()
            currentHasBlockContent = true
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = fontSize * 0.30
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.36, weight: .medium),
                .foregroundColor: Palette.cue,
                .kern: 1.1,
                .paragraphStyle: style
            ]
            let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
            append("▸ \(trimmedLabel.uppercased())", attributes: attributes)
            appendNewline(attributes: attributes)
            pendingBlockBreak = true
        }

        func appendPause(seconds: TimeInterval) {
            ensureNewline()
            currentHasBlockContent = true
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = fontSize * 0.40
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size: fontSize * 0.34, weight: .semibold),
                .foregroundColor: Palette.pause,
                .paragraphStyle: style
            ]
            // `·` is covered by both system fonts. The old `❚❚` (U+275A) was
            // absent and rendered as a tofu box on its own line.
            var label = "·  ·  ·"
            if seconds >= 1 {
                label += String(format: "  %.1f s", seconds)
            }
            append(label, attributes: attributes)
            appendNewline(attributes: attributes)
            pendingBlockBreak = true
        }

        /// A dim, italic marker for scenes with nothing to read. It occupies a
        /// line so the scene has real scrollable height, but it never counts as
        /// spoken characters (voice following and timing ignore it).
        func appendPlaceholder(_ text: String) {
            var value = text
            if pendingBlockBreak {
                stripOneLeadingLineBreak(from: &value)
                pendingBlockBreak = false
            }
            guard !value.isEmpty else { return }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = fontSize * 0.30
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: italicFont(roundedFont(size: fontSize * 0.46, weight: .regular)),
                .foregroundColor: Palette.placeholder,
                .paragraphStyle: style
            ]
            append(value, attributes: attributes)
            appendNewline(attributes: attributes)
        }

        // MARK: Helpers

        enum TextStyle {
            case text
            case emphasis
            case strongEmphasis
        }

        private func attributes(for style: TextStyle) -> [NSAttributedString.Key: Any] {
            let styleObject = NSMutableParagraphStyle()
            styleObject.lineSpacing = fontSize * 0.30
            styleObject.paragraphSpacing = 0
            styleObject.lineBreakMode = .byWordWrapping

            let font: NSFont
            let color: NSColor
            switch style {
            case .text:
                font = roundedFont(size: fontSize, weight: .medium)
                color = Palette.text
            case .emphasis:
                font = italicFont(roundedFont(size: fontSize, weight: .medium))
                color = Palette.emphasis
            case .strongEmphasis:
                font = roundedFont(size: fontSize, weight: .bold)
                color = Palette.strongEmphasis
            }
            return [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: styleObject
            ]
        }

        private func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
            attributed.append(NSAttributedString(string: text, attributes: attributes))
            if let last = text.last {
                lastAppendedWasNewline = (last == "\n")
            }
        }

        private func appendNewline(attributes: [NSAttributedString.Key: Any]) {
            append("\n", attributes: attributes)
        }

        private func ensureNewline() {
            guard !lastAppendedWasNewline else { return }
            append("\n", attributes: [
                .font: roundedFont(size: fontSize, weight: .medium),
                .foregroundColor: Palette.text
            ])
        }

        private func stripOneLeadingLineBreak(from text: inout String) {
            if text.hasPrefix("\r\n") {
                text.removeFirst(2)
            } else if text.hasPrefix("\n") || text.hasPrefix("\r") {
                text.removeFirst()
            }
        }

        private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded),
                  let rounded = NSFont(descriptor: descriptor, size: size) else {
                return base
            }
            return rounded
        }

        private func italicFont(_ font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
    }
}

// MARK: - Text renderer

/// A single non-selectable `NSTextView` inside a clipped, flipped view. Scroll
/// offsets are applied by moving the text view frame origin, so no text layout
/// or SwiftUI diffing happens during playback.
private final class NonInteractiveScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // The teleprompter owns the scroll offset; a stray trackpad gesture
        // must not desynchronise it from the model.
    }

    override func magnify(with event: NSEvent) {
        // Pinch gestures are deliberately ignored for the same reason.
    }
}

/// Belt and braces for the read-only prompter. `isEditable = false` alone still
/// leaves an AX text area that accepts programmatic edits (and some keyboard
/// paths), which is how typed letters used to reach the script and trigger the
/// single-letter mirror shortcut. This view never becomes first responder and
/// silently drops every text insertion.
private final class ReadOnlyTeleprompterTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override var isEditable: Bool {
        get { false }
        set { }
    }
    override var isSelectable: Bool {
        get { false }
        set { }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureReadOnlyStorage()
    }

    /// `NSTextView.init(frame:)` routes through this designated initializer, so
    /// a subclass that declares its own initializer must implement it; without
    /// it AppKit hits Swift's "unimplemented initializer" trap.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureReadOnlyStorage()
    }

    private func configureReadOnlyStorage() {
        // Set the superclass storage explicitly: the computed overrides above
        // only hide the flag from callers, while AppKit still consults its own
        // ivar in a few editing paths.
        super.isEditable = false
        super.isSelectable = false
        super.isRichText = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func becomeFirstResponder() -> Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func insertText(_ insertString: Any, replacementRange: NSRange) {}
    override func doCommand(by selector: Selector) {}
}

@MainActor
final class TeleprompterTextRenderer: NSView, TeleprompterTextRendering {
    private let scrollView = NonInteractiveScrollView(frame: .zero)
    private let textView = ReadOnlyTeleprompterTextView(frame: .zero)
    private var sectionHeaderLocations: [Int] = []
    private var sectionHeaderRanges: [NSRange] = []
    private var sectionBodyRanges: [NSRange] = []
    private var visibleCharacterCounts: [Int] = []
    private var sectionStarts: [Double] = []
    private var sectionHeights: [Double] = []
    private var frameSample = TeleprompterFrameSample()
    private var textBottom: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var columnWidth: CGFloat = 900
    private var scrollOffset: CGFloat = 0
    private var lastSections: [TeleprompterSection] = []
    private var lastFontSize: Double = 0
    private var lastColumnWidth: Double = 0
    private var lastEmptyScenePlaceholder = ""
    private var lastViewportSize: CGSize = .zero
    private var lastReadingLineFraction: Double = 0
    private var lastMirrorVertical = false
    private var renderGeneration = 0
    private var onMetrics: ((TeleprompterTextMetrics) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = false
        scrollView.contentView.drawsBackground = false
        scrollView.setAccessibilityElement(false)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isRichText = true
        textView.isFieldEditor = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(
            width: 0,
            height: TeleprompterAttributedStringBuilder.contentTopInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 900,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.layoutManager?.allowsNonContiguousLayout = true
        // The script is exposed once, as one read-only static text value.
        textView.setAccessibilityElement(false)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityEnabled(true)

        scrollView.documentView = textView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        setScrollOffset(scrollOffset)
    }

    /// Test hook: the glyph frames the layout assertions use. Content
    /// coordinates match the renderer's flipped space and therefore the
    /// visual top-to-bottom order.
    func currentFrameSample() -> TeleprompterFrameSample {
        frameSample
    }

    /// Test hook: the text view must never accept focus or edits.
    var textViewAccessibilityState: (acceptsFirstResponder: Bool, isEditable: Bool, isSelectable: Bool) {
        (
            textView.acceptsFirstResponder,
            textView.isEditable,
            textView.isSelectable
        )
    }

    var documentText: String { textView.string }

    func render(
        sections: [TeleprompterSection],
        fontSize: Double,
        columnWidth: Double,
        viewportSize: CGSize,
        readingLineFraction: Double,
        mirrorVertical: Bool,
        emptyScenePlaceholder: String = "",
        onMetrics: @escaping (TeleprompterTextMetrics) -> Void
    ) {
        self.onMetrics = onMetrics
        renderGeneration += 1

        let documentChanged = sections != lastSections
            || abs(fontSize - lastFontSize) > 0.001
            || abs(columnWidth - lastColumnWidth) > 0.5
            || emptyScenePlaceholder != lastEmptyScenePlaceholder
        let layoutChanged = viewportSize != lastViewportSize
            || abs(readingLineFraction - lastReadingLineFraction) > 0.0001
            || mirrorVertical != lastMirrorVertical

        if documentChanged {
            lastSections = sections
            lastFontSize = fontSize
            lastColumnWidth = columnWidth
            lastEmptyScenePlaceholder = emptyScenePlaceholder
            rebuildDocument(
                sections: sections,
                fontSize: fontSize,
                columnWidth: columnWidth,
                emptyScenePlaceholder: emptyScenePlaceholder
            )
        }
        if documentChanged || layoutChanged {
            lastViewportSize = viewportSize
            lastReadingLineFraction = readingLineFraction
            lastMirrorVertical = mirrorVertical
            updateLayout(
                viewportSize: viewportSize,
                readingLineFraction: readingLineFraction,
                mirrorVertical: mirrorVertical
            )
        }
        setScrollOffset(scrollOffset)
    }

    func setScrollOffset(_ offset: Double) {
        scrollOffset = max(0, CGFloat(offset))
        let maxY = max(0, contentHeight - bounds.height)
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: min(scrollOffset, maxY)))
    }

    // MARK: Layout

    private func rebuildDocument(
        sections: [TeleprompterSection],
        fontSize: Double,
        columnWidth: Double,
        emptyScenePlaceholder: String
    ) {
        let document = TeleprompterAttributedStringBuilder.build(
            sections: sections,
            fontSize: fontSize,
            emptyScenePlaceholder: emptyScenePlaceholder
        )
        sectionHeaderLocations = document.sectionHeaderLocations
        sectionHeaderRanges = document.sectionHeaderRanges
        sectionBodyRanges = document.sectionBodyRanges
        visibleCharacterCounts = document.visibleCharacterCounts
        self.columnWidth = CGFloat(columnWidth)
        textView.textStorage?.setAttributedString(document.attributedString)
        setAccessibilityValue(document.attributedString.string)
    }

    private func updateLayout(
        viewportSize: CGSize,
        readingLineFraction: Double,
        mirrorVertical: Bool
    ) {
        let horizontalInset = max(0, (viewportSize.width - columnWidth) / 2)
        let guideY = Double(viewportSize.height) * readingLineFraction
        // Content-coordinate position of the visual guide. Mirrored content is
        // flipped around the viewport centre, so the guide maps to 1 - fraction.
        let readingContentY = mirrorVertical
            ? Double(viewportSize.height) - guideY
            : guideY
        // The first line must start at the guide, not at a fixed 64 pt inset:
        // otherwise the reader sees the hook at the top while the counter (and
        // the elapsed time) already reports a later scene under the guide.
        let topInset = max(
            TeleprompterAttributedStringBuilder.contentTopInset,
            CGFloat(readingContentY)
        )
        textView.textContainerInset = NSSize(
            width: horizontalInset,
            height: topInset
        )
        textView.textContainer?.containerSize = NSSize(
            width: columnWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(1, viewportSize.width),
            height: max(1, viewportSize.height)
        )

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            sectionStarts = []
            sectionHeights = []
            frameSample = TeleprompterFrameSample()
            textBottom = topInset
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        textBottom = topInset + used.height

        var starts: [Double] = []
        var headerFrames: [CGRect] = []
        starts.reserveCapacity(sectionHeaderLocations.count)
        headerFrames.reserveCapacity(sectionHeaderLocations.count)
        for (index, location) in sectionHeaderLocations.enumerated() {
            guard location >= 0, location < (textView.textStorage?.length ?? 0) else {
                starts.append(Double(topInset))
                continue
            }
            let characterRange = NSRange(location: location, length: 1)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            let rect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            starts.append(Double(topInset + rect.minY))

            if sectionHeaderRanges.indices.contains(index) {
                let headerGlyphRange = layoutManager.glyphRange(
                    forCharacterRange: sectionHeaderRanges[index],
                    actualCharacterRange: nil
                )
                let headerRect = layoutManager.boundingRect(
                    forGlyphRange: headerGlyphRange,
                    in: textContainer
                )
                headerFrames.append(headerRect.offsetBy(dx: 0, dy: topInset))
            }
        }

        sectionStarts = starts
        sectionHeights = Self.heights(
            starts: starts,
            textBottom: Double(textBottom)
        )
        frameSample = TeleprompterFrameSample(
            headerFrames: headerFrames,
            bodyLineFrames: bodyLineFrames(
                layoutManager: layoutManager,
                textContainer: textContainer,
                topInset: topInset
            ),
            sectionStarts: sectionStarts,
            sectionHeights: sectionHeights
        )

        let bottomInset = max(96, Double(viewportSize.height) - readingContentY + 40)
        let newHeight = max(Double(viewportSize.height), Double(textBottom) + bottomInset)
        contentHeight = CGFloat(newHeight)

        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(1, viewportSize.width),
            height: contentHeight
        )
        scrollView.frame = bounds

        let metrics = TeleprompterTextMetrics(
            contentHeight: Double(contentHeight),
            sectionStarts: sectionStarts,
            sectionHeights: sectionHeights,
            visibleCharacterCounts: visibleCharacterCounts,
            generation: renderGeneration
        )
        onMetrics?(metrics)
    }

    private func bodyLineFrames(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        topInset: CGFloat
    ) -> [CGRect] {
        guard !sectionBodyRanges.isEmpty, layoutManager.numberOfGlyphs > 0 else { return [] }
        var frames: [CGRect] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var lineGlyphRange = NSRange(location: glyphIndex, length: 0)
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &lineGlyphRange
            )
            let characterRange = layoutManager.characterRange(
                forGlyphRange: lineGlyphRange,
                actualGlyphRange: nil
            )
            let isBody = sectionBodyRanges.contains { bodyRange in
                NSIntersectionRange(bodyRange, characterRange).length > 0
            }
            if isBody {
                frames.append(lineRect.offsetBy(dx: 0, dy: topInset))
            }
            let nextGlyph = NSMaxRange(lineGlyphRange)
            if nextGlyph <= glyphIndex { break }
            glyphIndex = nextGlyph
        }
        return frames
    }

    static func heights(starts: [Double], textBottom: Double) -> [Double] {
        starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : textBottom
            return max(0, end - starts[index])
        }
    }
}
