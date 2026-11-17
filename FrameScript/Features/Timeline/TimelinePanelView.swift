import FrameScriptCore
import SwiftUI

/// Presentational timeline used by the workspace and by the offscreen snapshot
/// tests. It never reads `AppState`, so it can render without touching app data.
struct TimelinePanelView: View {
    let layout: TimelineLayout
    let language: AppLanguage
    let theme: FrameTheme
    var metrics: TimelineTrackMetrics = .standard
    let pointsPerSecond: Double
    let zoomFraction: Binding<Double>
    let selectedBlockID: String?
    let selectedSceneID: UUID?
    let isPending: Bool
    let onSelectBlock: (TimelineBlock) -> Void
    let onMoveScene: (UUID, Int) -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onZoomChange: (Double) -> Void
    /// "Ajustar": make the whole video fill the canvas.
    var onFit: () -> Void = {}
    /// True while the current zoom is the fitted one (the button then rests).
    var isFitted = false
    /// Empty-state button that goes back to the script.
    var onGoToScript: () -> Void = {}

    private var showsEmptyState: Bool {
        TimelineEmptyState.shouldShow(for: layout)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.divider)
            if showsEmptyState {
                emptyState
            } else {
                timelineBody
            }
            Divider().overlay(theme.divider)
            footer
        }
        .background(theme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-workspace")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: FrameSpacing.l) {
            VStack(alignment: .leading, spacing: FrameSpacing.xs) {
                Text(text("timeline.title"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Text(text("timeline.explainer"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("timeline-explainer")
            }

            Spacer(minLength: FrameSpacing.m)

            if !showsEmptyState {
                zoomControls
            }
        }
        .padding(.horizontal, FrameSpacing.l + 2)
        .padding(.vertical, FrameSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panelBackground)
    }

    private var zoomControls: some View {
        HStack(spacing: FrameSpacing.s) {
            Button(action: onZoomOut) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.cursorPlain)
            .help(text("timeline.zoomOut"))
            .accessibilityLabel(text("timeline.zoomOut"))
            .accessibilityIdentifier("timeline-zoom-out")

            Slider(value: zoomFraction, in: 0...1)
                .controlSize(.small)
                .tint(theme.accent.color)
                .frame(width: 110)
                .help(text("timeline.zoomHelp"))
                .accessibilityLabel(text("timeline.zoom"))
                .accessibilityIdentifier("timeline-zoom-slider")

            Button(action: onZoomIn) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.cursorPlain)
            .help(text("timeline.zoomIn"))
            .accessibilityLabel(text("timeline.zoomIn"))
            .accessibilityIdentifier("timeline-zoom-in")

            Text(zoomScaleText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .help(zoomPercentHelp)
                .accessibilityIdentifier("timeline-zoom-percent")

            Button(text("timeline.fit"), action: onFit)
                .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
                .disabled(isFitted)
                .help(text("timeline.fit.help"))
                .accessibilityIdentifier("timeline-fit")
        }
        .foregroundStyle(theme.secondaryText)
    }

    private var zoomScaleText: String {
        TimelineZoomText.scale(pointsPerSecond: pointsPerSecond, language: language)
    }

    private var zoomPercentHelp: String {
        let percent = Int((pointsPerSecond / TimelineZoom.defaultPointsPerSecond * 100).rounded())
        return "\(text("timeline.zoom")): \(percent)%"
    }

    private var subtitle: String {
        TimelineSubtitle.text(
            sceneCount: layout.scenes.count,
            totalDuration: layout.totalDuration,
            language: language
        )
    }

    // MARK: Body

    private var timelineBody: some View {
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                trackLabels
                Divider().overlay(theme.divider)
                ScrollView(.horizontal, showsIndicators: true) {
                    let contentWidth = TimelineViewport(pointsPerSecond: pointsPerSecond)
                        .contentWidth(totalDuration: layout.totalDuration)
                    TimelineCanvasView(
                        layout: layout,
                        metrics: metrics,
                        pointsPerSecond: pointsPerSecond,
                        theme: theme,
                        language: language,
                        selectedBlockID: selectedBlockID,
                        selectedSceneID: selectedSceneID,
                        onSelectBlock: onSelectBlock,
                        onMoveScene: onMoveScene,
                        onZoomChange: onZoomChange
                    )
                    .frame(
                        width: max(contentWidth, max(320, proxy.size.width - 113)),
                        height: metrics.totalHeight
                    )
                    .overlay(alignment: .topTrailing) {
                        if isPending {
                            ProgressView()
                                .controlSize(.small)
                                .padding(6)
                        }
                    }
                }
                .background(theme.windowBackground)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var trackLabels: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            Color.clear
                .frame(height: metrics.rulerHeight - metrics.rowSpacing)
            ForEach(TimelineTrack.allCases, id: \.self) { track in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(trackAccent(track))
                        .frame(width: 3, height: 14)
                    Text(text("timeline.track.\(track.rawValue)"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: metrics.height(for: track))
                .contentShape(Rectangle())
                .help(text("timeline.track.\(track.rawValue).help"))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(track == .scenes ? theme.softAccent.opacity(0.35) : Color.clear)
                )
            }
        }
        .frame(width: 112)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timeline-track-labels")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: FrameSpacing.l) {
            legendChip(color: theme.accent.color.opacity(0.8), title: text("timeline.legend.real"))
                .help(text("timeline.legend.real.help"))
            legendChip(color: theme.accent.color.opacity(0.2), title: text("timeline.legend.estimated"))
                .help(text("timeline.legend.estimated.help"))
            legendChip(color: theme.warning, title: text("timeline.legend.pause"))
                .help(text("timeline.legend.pause.help"))
            if warningCount > 0 {
                legendChip(
                    color: theme.warning,
                    title: L10n.plural(
                        "timeline.warningsCount",
                        count: warningCount,
                        language: language
                    )
                )
            }

            Spacer(minLength: FrameSpacing.s)

            if !showsEmptyState {
                Label(text("timeline.dragHint"), systemImage: "arrow.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                Text(TimelineZoomText.recordedSummary(layout: layout, language: language))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .accessibilityIdentifier("timeline-recorded-summary")
            }
        }
        .padding(.horizontal, FrameSpacing.l + 2)
        .frame(height: 34)
        .background(theme.panelBackground)
    }

    private func legendChip(color: Color, title: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
    }

    private var warningCount: Int {
        layout.blocks(on: .warnings).count
    }

    private var emptyState: some View {
        VStack(spacing: FrameSpacing.m) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(text("timeline.empty.friendly"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button(text("timeline.empty.goToScript"), action: onGoToScript)
                .buttonStyle(.framePrimary)
                .accessibilityIdentifier("timeline-go-to-script")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FrameSpacing.xl)
        .accessibilityIdentifier("timeline-empty-state")
    }

    // MARK: Palette

    private func trackAccent(_ track: TimelineTrack) -> Color {
        switch track {
        case .scenes: theme.accent.color
        case .narration: theme.primaryText.opacity(0.42)
        case .pauses: theme.warning
        case .bRoll: theme.bRollMarker
        case .editing: theme.editingMarker
        case .takes: theme.success
        case .warnings: theme.destructive
        }
    }

    private func text(_ key: String) -> String {
        L10n.tr(key, language: language)
    }
}

// MARK: - Canvas

private struct TimelineCanvasView: View {
    let layout: TimelineLayout
    let metrics: TimelineTrackMetrics
    let pointsPerSecond: Double
    let theme: FrameTheme
    let language: AppLanguage
    let selectedBlockID: String?
    let selectedSceneID: UUID?
    let onSelectBlock: (TimelineBlock) -> Void
    let onMoveScene: (UUID, Int) -> Void
    let onZoomChange: (Double) -> Void

    @State private var draggingSceneID: UUID?
    @State private var dragTargetIndex: Int?
    @State private var pinchStart: Double?

    private var viewport: TimelineViewport {
        TimelineViewport(pointsPerSecond: pointsPerSecond)
    }

    var body: some View {
        Canvas { context, size in
            draw(context: &context, size: size)
        }
        .contentShape(Rectangle())
        .background(alignment: .topLeading) { sceneTooltips }
        .gesture(dragGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("timeline.canvas.accessibilityLabel", language: language))
        .accessibilityHint(L10n.tr("timeline.canvas.accessibilityHint", language: language))
        .accessibilityIdentifier("timeline-canvas")
    }

    /// Hover tooltips with the full scene title, since a narrow block only
    /// shows its number.
    private var sceneTooltips: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.blocks(on: .scenes)) { block in
                let x = viewport.x(for: block.start)
                let width = max(6, viewport.width(for: block.duration))
                Color.clear
                    .frame(width: width, height: metrics.height(for: .scenes))
                    .offset(x: x, y: metrics.yOffset(for: .scenes))
                    .help(TimelineBlockLabel.sceneTooltip(for: block, layout: layout))
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingSceneID == nil {
                    guard metrics.track(atY: value.startLocation.y) == .scenes,
                          let block = TimelineHitTester.block(
                            at: value.startLocation,
                            layout: layout,
                            metrics: metrics,
                            viewport: viewport
                          ) else { return }
                    draggingSceneID = block.sceneID
                }
                guard let sceneID = draggingSceneID else { return }
                dragTargetIndex = TimelineHitTester.sceneInsertionIndex(
                    atX: value.location.x,
                    layout: layout,
                    viewport: viewport,
                    excluding: sceneID
                )
            }
            .onEnded { value in
                if let sceneID = draggingSceneID,
                   let index = dragTargetIndex,
                   abs(value.translation.width) >= 3 {
                    onMoveScene(sceneID, index)
                } else if let block = TimelineHitTester.block(
                    at: value.location,
                    layout: layout,
                    metrics: metrics,
                    viewport: viewport
                ) {
                    onSelectBlock(block)
                }
                draggingSceneID = nil
                dragTargetIndex = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? pointsPerSecond
                pinchStart = start
                let magnification = value.magnification.isFinite ? value.magnification : 1
                onZoomChange(TimelineZoom.clamp(start * magnification))
            }
            .onEnded { _ in
                pinchStart = nil
            }
    }

    // MARK: Drawing

    private func draw(context: inout GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(theme.windowBackground)
        )
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: metrics.rulerHeight)),
            with: .color(theme.panelBackground)
        )

        for track in TimelineTrack.allCases {
            let rect = CGRect(
                x: 0,
                y: metrics.yOffset(for: track),
                width: size.width,
                height: metrics.height(for: track)
            )
            context.fill(Path(rect), with: .color(trackBackground(track)))
        }

        drawRuler(context: &context, size: size)

        for block in layout.blocks {
            draw(block: block, context: &context, size: size)
        }

        if let index = dragTargetIndex, let draggingSceneID {
            drawDropIndicator(
                context: &context,
                destination: index,
                draggingSceneID: draggingSceneID
            )
        }
    }

    private func drawRuler(context: inout GraphicsContext, size: CGSize) {
        let ticks = TimelineRuler.ticks(
            totalDuration: layout.totalDuration,
            pointsPerSecond: pointsPerSecond
        )
        let labelColor = theme.tertiaryText

        for tick in ticks {
            let x = viewport.x(for: tick.time)
            guard x <= size.width else { break }
            var path = Path()
            path.move(to: CGPoint(x: x, y: metrics.rulerHeight - 6))
            path.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(path, with: .color(theme.divider.opacity(0.55)), lineWidth: 1)
            context.draw(
                Text(tick.label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(labelColor),
                at: CGPoint(x: x + 4, y: metrics.rulerHeight / 2),
                anchor: .leading
            )
        }
    }

    private func draw(block: TimelineBlock, context: inout GraphicsContext, size: CGSize) {
        let top = metrics.yOffset(for: block.track)
        let height = metrics.height(for: block.track)
        let padding: CGFloat = 4
        var y = top + padding
        var blockHeight = max(6, height - padding * 2)
        if block.track == .takes {
            let rect = metrics.takeLaneRect(
                lane: block.lane,
                lanesUsed: layout.maximumLane(on: .takes) + 1
            )
            y = top + rect.offset
            blockHeight = rect.height
        }

        let x = viewport.x(for: block.start)
        var width = viewport.width(for: block.duration)
        if block.track == .editing {
            width = 3
        } else if block.track == .warnings {
            width = max(2, width)
        } else if block.duration <= 0 {
            width = 3
        } else {
            width = max(3, width)
        }
        if block.track == .scenes {
            width = max(6, width)
        }
        guard x < size.width else { return }
        if x + width > size.width {
            width = max(3, size.width - x)
        }

        let rect = CGRect(x: x, y: y, width: width, height: blockHeight)
        let corner = block.track == .takes ? CGFloat(3) : CGFloat(4)
        let shape = Path(roundedRect: rect, cornerRadius: corner)
        let isSelected = block.id == selectedBlockID
            || (block.track == .scenes && block.sceneID == selectedSceneID)

        if block.track == .warnings {
            drawWarningStripes(rect: rect, context: &context)
        } else {
            context.fill(shape, with: .color(blockFill(block)))
            context.stroke(
                shape,
                with: .color(blockStroke(block)),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: block.isAnchored ? [] : [3, 2]
                )
            )
        }

        if isSelected || (block.track == .takes && block.isSelected) {
            context.stroke(shape, with: .color(theme.focus), lineWidth: 2)
        }

        var label = label(for: block)
        var labelWidthNeeded = minimumLabelWidth(for: block.track)
        if block.track == .scenes {
            // Full "01 · Title" only when it fits whole; otherwise just the
            // number (the title stays in the tooltip). Never a cut-off word.
            let reserved: CGFloat = width > 120 ? 48 : 12
            if !TimelineBlockLabel.fits(label, inWidth: width - reserved) {
                label = TimelineBlockLabel.sceneNumber(for: block, layout: layout)
                labelWidthNeeded = 22
            } else {
                labelWidthNeeded = 0
            }
        }
        if !label.isEmpty, width >= labelWidthNeeded {
            let textColor = theme.primaryText
            context.drawLayer { layer in
                if block.track == .scenes {
                    layer.clip(to: Path(CGRect(
                        x: rect.minX,
                        y: rect.minY,
                        width: max(0, rect.width - 42),
                        height: rect.height
                    )))
                } else {
                    layer.clip(to: shape)
                }
                layer.draw(
                    Text(label)
                        .font(.system(size: block.track == .scenes ? 11 : 10, weight: .medium))
                        .foregroundColor(textColor),
                    at: CGPoint(x: rect.minX + 6, y: rect.midY),
                    anchor: .leading
                )
            }
        }

        if block.track == .scenes, width > 120 {
            let durationText = DurationFormat.clock(seconds: Int(block.duration.rounded()))
            context.draw(
                Text(durationText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(theme.secondaryText),
                at: CGPoint(x: rect.maxX - 6, y: rect.midY),
                anchor: .trailing
            )
        }
    }

    private func drawWarningStripes(rect: CGRect, context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.fill(Path(rect), with: .color(theme.warning.opacity(0.24)))
            var stripeX = rect.minX - rect.height
            while stripeX < rect.maxX {
                var path = Path()
                path.move(to: CGPoint(x: stripeX, y: rect.maxY))
                path.addLine(to: CGPoint(x: stripeX + rect.height, y: rect.minY))
                layer.stroke(path, with: .color(theme.warning.opacity(0.65)), lineWidth: 1)
                stripeX += 6
            }
            layer.stroke(
                Path(rect),
                with: .color(theme.warning.opacity(0.55)),
                lineWidth: 1
            )
        }
    }

    private func drawDropIndicator(
        context: inout GraphicsContext,
        destination: Int,
        draggingSceneID: UUID
    ) {
        let others = layout.scenes.filter { $0.id != draggingSceneID }
        let insertionTime: TimeInterval
        if destination <= 0 {
            insertionTime = others.first?.start ?? 0
        } else if destination >= others.count {
            insertionTime = others.last?.end ?? layout.totalDuration
        } else {
            insertionTime = others[destination].start
        }
        let indicatorX = viewport.x(for: insertionTime)
        var path = Path()
        path.move(to: CGPoint(x: indicatorX, y: metrics.rulerHeight))
        path.addLine(to: CGPoint(x: indicatorX, y: metrics.totalHeight))
        context.stroke(path, with: .color(theme.focus), lineWidth: 2)
    }

    // MARK: Palette

    private func trackBackground(_ track: TimelineTrack) -> Color {
        switch track {
        case .scenes: theme.softAccent.opacity(0.22)
        case .narration: theme.cardBackground.opacity(0.42)
        case .pauses, .warnings: theme.warning.opacity(0.05)
        case .bRoll: theme.bRollMarker.opacity(0.05)
        case .editing: theme.editingMarker.opacity(0.05)
        case .takes: theme.hover
        }
    }

    private func minimumLabelWidth(for track: TimelineTrack) -> CGFloat {
        switch track {
        case .scenes: 64
        case .narration: 48
        case .pauses: 28
        case .bRoll: 64
        case .editing: 40
        case .takes: 30
        case .warnings: 64
        }
    }

    private func blockFill(_ block: TimelineBlock) -> Color {
        switch block.track {
        case .scenes:
            let hasReal = layout.scene(id: block.sceneID)?.hasRealTake == true
            if hasReal {
                return theme.accent.color.opacity(theme.colorScheme == .dark ? 0.30 : 0.45)
            }
            return theme.accent.color.opacity(theme.colorScheme == .dark ? 0.12 : 0.18)
        case .narration: return theme.cardBackground
        case .pauses: return theme.warning.opacity(0.5)
        case .bRoll: return theme.bRollMarker.opacity(0.55)
        case .editing: return theme.editingMarker.opacity(0.6)
        case .takes:
            switch block.takeRating ?? .unrated {
            case .good: return theme.success.opacity(block.isSelected ? 0.62 : 0.42)
            case .bad: return theme.destructive.opacity(0.42)
            case .safe: return theme.warning.opacity(0.42)
            case .unrated: return theme.secondaryText.opacity(0.25)
            }
        case .warnings: return theme.warning.opacity(0.2)
        }
    }

    private func blockStroke(_ block: TimelineBlock) -> Color {
        if block.track == .scenes, block.isSelected {
            return theme.accent.color
        }
        return theme.divider
    }

    private func label(for block: TimelineBlock) -> String {
        TimelineBlockLabel.label(for: block, layout: layout, language: language)
    }

    private func text(_ key: String) -> String {
        L10n.tr(key, language: language)
    }
}

/// Header subtitle built from the same plural keys as the footer.
enum TimelineSubtitle {
    static func text(
        sceneCount: Int,
        totalDuration: TimeInterval,
        language: AppLanguage
    ) -> String {
        let total = DurationFormat.clock(seconds: Int(totalDuration.rounded()))
        let scenes = L10n.plural(
            "timeline.sceneCount",
            count: sceneCount,
            language: language
        )
        return "\(scenes) · \(total)"
    }
}

/// Canvas labels shared by the view and the regression tests. Every label comes
/// from the localized tables; no enum raw value ever reaches the canvas.
enum TimelineBlockLabel {
    static func label(
        for block: TimelineBlock,
        layout: TimelineLayout,
        language: AppLanguage
    ) -> String {
        switch block.track {
        case .scenes:
            let hasReal = layout.scene(id: block.sceneID)?.hasRealTake == true
            let number = sceneNumber(for: block, layout: layout)
            let title = block.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = title.isEmpty ? number : "\(number) · \(title)"
            return hasReal ? "\(base) · \(text("timeline.real", language: language))" : base
        case .narration:
            return block.label
        case .pauses:
            guard let seconds = block.pauseSeconds else { return "" }
            return String(
                format: text("timeline.pauseShort", language: language),
                formattedPause(seconds)
            )
        case .bRoll, .editing:
            guard !block.isAnchored else { return block.label }
            return "\(block.label) · \(text("timeline.unanchored", language: language))"
        case .takes:
            return block.isSelected ? "\(block.label) · \(text("timeline.real", language: language))" : block.label
        case .warnings:
            guard let kind = block.warningKind else { return block.label }
            return text("timeline.warning.\(kind.rawValue)", language: language)
        }
    }

    /// Rough text width at the canvas font, to decide between the full label
    /// and the bare number without drawing a cut-off word.
    static func fits(_ label: String, inWidth width: CGFloat) -> Bool {
        CGFloat(label.count) * 6.3 + 4 <= width
    }

    /// Full "01 · Title" for the hover tooltip.
    static func sceneTooltip(for block: TimelineBlock, layout: TimelineLayout) -> String {
        let number = sceneNumber(for: block, layout: layout)
        let title = block.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? number : "\(number) · \(title)"
    }

    /// Two-digit scene number (`01`), matching the sidebar.
    static func sceneNumber(for block: TimelineBlock, layout: TimelineLayout) -> String {
        let order = layout.scene(id: block.sceneID)?.order ?? 0
        return String(format: "%02d", max(0, order) + 1)
    }

    private static func formattedPause(_ seconds: TimeInterval) -> String {
        if abs(seconds - seconds.rounded()) < 0.001 {
            return "\(Int(seconds.rounded()))"
        }
        return String(format: "%.1f", seconds)
    }

    private static func text(_ key: String, language: AppLanguage) -> String {
        L10n.tr(key, language: language)
    }
}

/// Zoom and footer text for the timeline header and footer.
enum TimelineZoomText {
    /// «10 s por división» / «2 min por división».
    static func scale(pointsPerSecond: Double, language: AppLanguage) -> String {
        let seconds = Int(TimelineZoom.secondsPerDivision(pointsPerSecond: pointsPerSecond).rounded())
        let unit: String
        if seconds >= 60, seconds % 60 == 0 {
            unit = String(format: L10n.tr("timeline.scale.minutes", language: language), seconds / 60)
        } else {
            unit = String(format: L10n.tr("timeline.scale.seconds", language: language), seconds)
        }
        return String(format: L10n.tr("timeline.scale.perDivision", language: language), unit)
    }

    /// «Tomas reales: 3 de 9 escenas», the footer figure that replaced the
    /// bare block count.
    static func recordedSummary(layout: TimelineLayout, language: AppLanguage) -> String {
        let recorded = layout.scenes.filter(\.hasRealTake).count
        return String(
            format: L10n.tr("timeline.recordedSummary", language: language),
            recorded,
            layout.scenes.count
        )
    }
}
