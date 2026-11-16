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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.divider)
            if layout.isEmpty {
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(text("timeline.title"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
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

                Text("\(Int((pointsPerSecond / TimelineZoom.defaultPointsPerSecond * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityIdentifier("timeline-zoom-percent")
            }
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
        .background(theme.panelBackground)
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
        HStack(spacing: 14) {
            Label(text("timeline.dragHint"), systemImage: "arrow.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
                .labelStyle(.titleAndIcon)

            legendChip(color: theme.accent.color.opacity(0.8), title: text("timeline.real"))
            legendChip(color: theme.accent.color.opacity(0.2), title: text("timeline.estimated"))
            legendChip(color: theme.warning, title: text("timeline.legend.pause"))
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

            Spacer(minLength: 8)

            Text(L10n.plural(
                "timeline.blockCount",
                count: layout.blocks.count,
                language: language
            ))
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityIdentifier("timeline-block-count")
        }
        .padding(.horizontal, 18)
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
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(text("timeline.empty.title"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(theme.primaryText)
            Text(text("timeline.empty.message"))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .gesture(dragGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("timeline.canvas.accessibilityLabel", language: language))
        .accessibilityHint(L10n.tr("timeline.canvas.accessibilityHint", language: language))
        .accessibilityIdentifier("timeline-canvas")
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
        let padding: CGFloat = block.track == .takes ? 2 : 4
        let laneHeight = block.track == .takes
            ? height / CGFloat(TimelineLayoutBuilder.maximumTakeLanes)
            : height
        let y = top + padding + (block.track == .takes ? CGFloat(block.lane) * laneHeight : 0)
        let blockHeight = max(6, laneHeight - padding * 2)

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

        let label = label(for: block)
        if !label.isEmpty, width >= minimumLabelWidth(for: block.track) {
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
            return hasReal ? "\(block.label) · \(text("timeline.real", language: language))" : block.label
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
