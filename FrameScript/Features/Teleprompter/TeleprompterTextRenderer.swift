import AppKit
import FrameScriptCore

// MARK: - Attributed string builder

/// The text and the bookkeeping the renderer needs after layout.
struct TeleprompterAttributedDocument {
    let attributedString: NSAttributedString
    let sectionHeaderLocations: [Int]
    let visibleCharacterCounts: [Int]
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
        static let pause = NSColor.white.withAlphaComponent(0.30)
        static let header = NSColor.white.withAlphaComponent(0.42)
    }

    static func build(sections: [TeleprompterSection], fontSize: Double) -> TeleprompterAttributedDocument {
        let builder = Builder(fontSize: CGFloat(fontSize))
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

    /// Encapsulates the append-only state so newline handling and character
    /// counts stay consistent without repeatedly reading the whole string.
    private final class Builder {
        private let fontSize: CGFloat
        private let attributed = NSMutableAttributedString()
        private var sectionHeaderLocations: [Int] = []
        private var visibleCharacterCounts: [Int] = []
        private var currentVisibleCount = 0
        private var lastAppendedWasNewline = true
        private var pendingBlockBreak = false

        init(fontSize: CGFloat) {
            self.fontSize = fontSize
        }

        var document: TeleprompterAttributedDocument {
            TeleprompterAttributedDocument(
                attributedString: attributed,
                sectionHeaderLocations: sectionHeaderLocations,
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
            let name = title.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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

            sectionHeaderLocations.append(attributed.length)
            append(headerText, attributes: attributes)
            appendNewline(attributes: attributes)
            pendingBlockBreak = true
        }

        func finishSection() {
            visibleCharacterCounts.append(currentVisibleCount)
            currentVisibleCount = 0
        }

        // MARK: Runs

        func appendVisibleText(_ rawText: String, style: TextStyle) {
            guard !rawText.isEmpty else { return }
            var text = rawText
            if pendingBlockBreak {
                stripOneLeadingLineBreak(from: &text)
                pendingBlockBreak = false
            }
            guard !text.isEmpty else { return }

            let attributes = attributes(for: style)
            append(text, attributes: attributes)
            currentVisibleCount += text.count
        }

        func appendCue(label: String) {
            ensureNewline()
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
            append("▸ \(label.uppercased())", attributes: attributes)
            appendNewline(attributes: attributes)
            pendingBlockBreak = true
        }

        func appendPause(seconds: TimeInterval) {
            ensureNewline()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 0
            style.paragraphSpacing = fontSize * 0.40
            style.lineBreakMode = .byWordWrapping
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size: fontSize * 0.28, weight: .semibold),
                .foregroundColor: Palette.pause,
                .paragraphStyle: style
            ]
            var label = "❚❚"
            if seconds >= 1 {
                label += String(format: "  %.1fs", seconds)
            }
            append(label, attributes: attributes)
            appendNewline(attributes: attributes)
            pendingBlockBreak = true
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

@MainActor
final class TeleprompterTextRenderer: NSView, TeleprompterTextRendering {
    private let scrollView = NonInteractiveScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private var sectionHeaderLocations: [Int] = []
    private var visibleCharacterCounts: [Int] = []
    private var sectionStarts: [Double] = []
    private var sectionHeights: [Double] = []
    private var textBottom: CGFloat = 0
    private var contentHeight: CGFloat = 0
    private var columnWidth: CGFloat = 900
    private var scrollOffset: CGFloat = 0
    private var lastSections: [TeleprompterSection] = []
    private var lastFontSize: Double = 0
    private var lastColumnWidth: Double = 0
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

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isRichText = true
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

    func render(
        sections: [TeleprompterSection],
        fontSize: Double,
        columnWidth: Double,
        viewportSize: CGSize,
        readingLineFraction: Double,
        mirrorVertical: Bool,
        onMetrics: @escaping (TeleprompterTextMetrics) -> Void
    ) {
        self.onMetrics = onMetrics
        renderGeneration += 1

        let documentChanged = sections != lastSections
            || abs(fontSize - lastFontSize) > 0.001
            || abs(columnWidth - lastColumnWidth) > 0.5
        let layoutChanged = viewportSize != lastViewportSize
            || abs(readingLineFraction - lastReadingLineFraction) > 0.0001
            || mirrorVertical != lastMirrorVertical

        if documentChanged {
            lastSections = sections
            lastFontSize = fontSize
            lastColumnWidth = columnWidth
            rebuildDocument(
                sections: sections,
                fontSize: fontSize,
                columnWidth: columnWidth
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
        columnWidth: Double
    ) {
        let document = TeleprompterAttributedStringBuilder.build(sections: sections, fontSize: fontSize)
        sectionHeaderLocations = document.sectionHeaderLocations
        visibleCharacterCounts = document.visibleCharacterCounts
        self.columnWidth = CGFloat(columnWidth)
        textView.textStorage?.setAttributedString(document.attributedString)
    }

    private func updateLayout(
        viewportSize: CGSize,
        readingLineFraction: Double,
        mirrorVertical: Bool
    ) {
        let horizontalInset = max(0, (viewportSize.width - columnWidth) / 2)
        textView.textContainerInset = NSSize(
            width: horizontalInset,
            height: TeleprompterAttributedStringBuilder.contentTopInset
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
            textBottom = TeleprompterAttributedStringBuilder.contentTopInset
            return
        }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        textBottom = TeleprompterAttributedStringBuilder.contentTopInset + used.height

        var starts: [Double] = []
        starts.reserveCapacity(sectionHeaderLocations.count)
        for location in sectionHeaderLocations {
            guard location >= 0, location < (textView.textStorage?.length ?? 0) else {
                starts.append(Double(TeleprompterAttributedStringBuilder.contentTopInset))
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
            starts.append(
                Double(TeleprompterAttributedStringBuilder.contentTopInset + rect.minY)
            )
        }

        sectionStarts = starts
        sectionHeights = Self.heights(
            starts: starts,
            textBottom: Double(textBottom)
        )

        let guideY = Double(viewportSize.height) * readingLineFraction
        let readingContentY = mirrorVertical
            ? Double(viewportSize.height) - guideY
            : guideY
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

    static func heights(starts: [Double], textBottom: Double) -> [Double] {
        starts.indices.map { index in
            let end = index + 1 < starts.count ? starts[index + 1] : textBottom
            return max(0, end - starts[index])
        }
    }
}
