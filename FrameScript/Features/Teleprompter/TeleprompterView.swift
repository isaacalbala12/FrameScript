import SwiftUI

private enum TeleprompterPalette {
    static let background = Color.black
    static let text = Color.white
    static let emphasis = Color(red: 1.0, green: 0.84, blue: 0.36)
    static let strongEmphasis = Color(red: 1.0, green: 0.94, blue: 0.62)
    static let cue = Color.white.opacity(0.34)
    static let pause = Color.white.opacity(0.30)
    static let guide = Color.white.opacity(0.16)
    static let chrome = Color.white.opacity(0.9)
    static let status = Color.white.opacity(0.32)
}

private struct TeleprompterContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TeleprompterSectionHeightsKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TeleprompterRootView: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                TeleprompterPalette.background.ignoresSafeArea()
                scrollingContent(viewport: proxy.size)
                readingLine(viewport: proxy.size)
                statusBar
                if let countdown = model.countdown {
                    countdownOverlay(countdown)
                }
                if model.controlsVisible || !model.isPlaying || model.countdown != nil {
                    TeleprompterControls(model: model)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.controlsVisible)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { model.updateViewport(height: proxy.size.height) }
            .onChange(of: proxy.size.height) { _, height in
                model.updateViewport(height: height)
            }
        }
        .background(TeleprompterPalette.background)
        .preferredColorScheme(.dark)
        .onChange(of: model.settings) { _, _ in
            model.showControlsTemporarily()
        }
        .onExitCommand { model.close() }
    }

    // MARK: Content

    private func scrollingContent(viewport: CGSize) -> some View {
        let columnWidth = min(model.settings.columnWidth, max(260, viewport.width - 96))
        let bottomInset = max(160, viewport.height * (1 - model.settings.readingLineFraction) + 48)

        return ZStack(alignment: .top) {
            VStack(alignment: .center, spacing: 0) {
                ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                    TeleprompterSectionView(
                        section: section,
                        index: index,
                        fontSize: model.settings.fontSize,
                        showsHeader: true,
                        noTextLabel: model.localized("teleprompter.noText")
                    )
                    .frame(width: columnWidth, alignment: .leading)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TeleprompterSectionHeightsKey.self,
                                value: [index: proxy.size.height]
                            )
                        }
                    }
                }
            }
            .padding(.top, TeleprompterModel.contentTopInset)
            .padding(.bottom, bottomInset)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TeleprompterContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .onPreferenceChange(TeleprompterContentHeightKey.self) { height in
                model.updateContentHeight(height)
            }
            .onPreferenceChange(TeleprompterSectionHeightsKey.self) { heights in
                model.updateSectionHeights(heights.mapValues { Double($0) })
            }
            .offset(y: -model.offset)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .top)
        .clipped()
        .scaleEffect(
            x: model.settings.mirrorHorizontal ? -1 : 1,
            y: model.settings.mirrorVertical ? -1 : 1
        )
    }

    // MARK: Guides and status

    private func readingLine(viewport: CGSize) -> some View {
        let y = viewport.height * model.settings.readingLineFraction
        return VStack(spacing: 0) {
            Spacer().frame(height: max(0, y - 0.5))
            HStack(spacing: 0) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 7))
                LinearGradient(
                    colors: [.white.opacity(0.02), TeleprompterPalette.guide, .white.opacity(0.02)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.system(size: 7))
            }
            .foregroundStyle(.white.opacity(0.16))
            .padding(.horizontal, 10)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var statusBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(sceneLabel)
                .lineLimit(1)
            Spacer(minLength: 24)
            Text(timeLabel)
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(TeleprompterPalette.status)
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .allowsHitTesting(false)
    }

    private var sceneLabel: String {
        guard !model.sections.isEmpty else { return "" }
        let position = "\(model.currentSectionIndex + 1)/\(model.sections.count)"
        return "\(position) · \(model.currentSectionTitle)"
    }

    private var timeLabel: String {
        let elapsed = DurationEstimator.formatted(model.elapsedEstimate)
        let remaining = DurationEstimator.formatted(model.remainingEstimate)
        return "≈ \(elapsed) · −\(remaining)"
    }

    private func countdownOverlay(_ countdown: Int) -> some View {
        VStack(spacing: 18) {
            Text("\(countdown)")
                .font(.system(size: 180, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(model.localized("teleprompter.ready"))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55))
        .allowsHitTesting(false)
    }
}

// MARK: - Section rendering

private struct TeleprompterSectionView: View {
    let section: TeleprompterSection
    let index: Int
    let fontSize: Double
    let showsHeader: Bool
    let noTextLabel: String

    private var blocks: [TeleprompterBlock] {
        TeleprompterBlock.make(from: section.runs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
            }
            if blocks.isEmpty {
                Text(noTextLabel)
                    .font(.system(size: fontSize * 0.45, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(.bottom, fontSize * 0.5)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .inline(let runs):
                        inlineText(runs)
                    case .pause(let seconds):
                        pauseGlyph(seconds)
                    case .cue(let label):
                        cueLabel(label)
                    }
                }
            }
        }
        .padding(.bottom, fontSize * 1.05)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: fontSize * 0.24) {
            Text(String(format: "%02d", index + 1))
                .monospacedDigit()
            Text(section.title.uppercased())
                .lineLimit(1)
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
        .font(.system(size: fontSize * 0.32, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.38))
        .tracking(1.6)
        .padding(.bottom, fontSize * 0.5)
    }

    private func inlineText(_ runs: [TeleprompterRun]) -> some View {
        runs.reduce(Text("")) { result, run in
            switch run {
            case .text(let value):
                return result + Text(value)
            case .emphasis(let value, let strong):
                return result + Text(value)
                    .bold(strong)
                    .italic(!strong)
                    .foregroundStyle(strong ? TeleprompterPalette.strongEmphasis : TeleprompterPalette.emphasis)
            case .pause, .cue:
                return result
            }
        }
        .font(.system(size: fontSize, weight: .medium, design: .rounded))
        .foregroundStyle(TeleprompterPalette.text)
        .lineSpacing(fontSize * 0.30)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, fontSize * 0.18)
    }

    private func pauseGlyph(_ seconds: TimeInterval) -> some View {
        VStack(spacing: fontSize * 0.10) {
            Image(systemName: "pause.fill")
                .font(.system(size: fontSize * 0.24, weight: .bold))
            if seconds >= 1 {
                Text(String(format: "%.1fs", seconds))
                    .font(.system(size: fontSize * 0.18, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(TeleprompterPalette.pause)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, fontSize * 0.55)
        .accessibilityHidden(true)
    }

    private func cueLabel(_ label: String) -> some View {
        HStack(spacing: fontSize * 0.18) {
            Rectangle()
                .fill(.white.opacity(0.20))
                .frame(width: fontSize * 0.6, height: 1)
            Text(label.uppercased())
                .font(.system(size: fontSize * 0.36, weight: .medium, design: .monospaced))
                .foregroundStyle(TeleprompterPalette.cue)
                .tracking(1.1)
                .lineLimit(2)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
        .padding(.vertical, fontSize * 0.35)
    }
}

private enum TeleprompterBlock {
    case inline([TeleprompterRun])
    case pause(TimeInterval)
    case cue(String)

    static func make(from runs: [TeleprompterRun]) -> [TeleprompterBlock] {
        var blocks: [TeleprompterBlock] = []
        var inline: [TeleprompterRun] = []

        func flushInline() {
            guard !inline.isEmpty else { return }
            blocks.append(.inline(inline))
            inline.removeAll(keepingCapacity: true)
        }

        for run in runs {
            switch run {
            case .text, .emphasis:
                inline.append(run)
            case .pause(let seconds):
                flushInline()
                blocks.append(.pause(seconds))
            case .cue(let label):
                flushInline()
                blocks.append(.cue(label))
            }
        }
        flushInline()
        return blocks
    }
}

// MARK: - Controls overlay

private struct TeleprompterControls: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        VStack(spacing: 14) {
            transportRow
            sliderRow
            Text(model.localized("teleprompter.hint"))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.30))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.72), location: 0.30),
                    .init(color: .black.opacity(0.96), location: 0.62),
                    .init(color: .black.opacity(0.99), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            controlButton(
                "backward.end.fill",
                help: model.localized("teleprompter.previousScene"),
                action: model.previousSection
            )
            controlButton(
                model.isPlaying ? "pause.fill" : "play.fill",
                help: model.localized(model.isPlaying ? "teleprompter.pause" : "teleprompter.play"),
                isActive: true,
                size: 46,
                action: model.togglePlayback
            )
            controlButton(
                "forward.end.fill",
                help: model.localized("teleprompter.nextScene"),
                action: model.nextSection
            )
            controlButton(
                "arrow.counterclockwise",
                help: model.localized("teleprompter.restartScene"),
                action: model.restartSection
            )

            Divider()
                .overlay(Color.white.opacity(0.16))
                .frame(height: 24)
                .padding(.horizontal, 2)

            controlButton(
                "timer",
                help: model.localized("teleprompter.countdown"),
                isActive: model.settings.countdownEnabled,
                action: model.toggleCountdown
            )
            controlButton(
                "arrow.left.and.right",
                help: model.localized("teleprompter.mirrorHorizontal"),
                isActive: model.settings.mirrorHorizontal,
                action: model.toggleMirrorHorizontal
            )
            controlButton(
                "arrow.up.and.down",
                help: model.localized("teleprompter.mirrorVertical"),
                isActive: model.settings.mirrorVertical,
                action: model.toggleMirrorVertical
            )

            Spacer(minLength: 16)

            displayMenu
            controlButton(
                "arrow.up.left.and.arrow.down.right",
                help: model.localized("teleprompter.fullScreen"),
                action: model.toggleFullScreen
            )
            controlButton(
                "xmark",
                help: model.localized("teleprompter.close"),
                action: model.close
            )
        }
    }

    private var sliderRow: some View {
        HStack(alignment: .top, spacing: 18) {
            TeleprompterSliderRow(
                title: model.localized("teleprompter.speed"),
                valueText: String(
                    format: model.localized("teleprompter.wpmValue"),
                    Int(model.settings.wordsPerMinute.rounded())
                ),
                value: $model.settings.wordsPerMinute,
                range: TeleprompterSettings.Limits.wordsPerMinute
            )
            TeleprompterSliderRow(
                title: model.localized("teleprompter.fontSize"),
                valueText: String(
                    format: model.localized("teleprompter.pointsValue"),
                    Int(model.settings.fontSize.rounded())
                ),
                value: $model.settings.fontSize,
                range: TeleprompterSettings.Limits.fontSize
            )
            TeleprompterSliderRow(
                title: model.localized("teleprompter.columnWidth"),
                valueText: String(
                    format: model.localized("teleprompter.pointsValue"),
                    Int(model.settings.columnWidth.rounded())
                ),
                value: $model.settings.columnWidth,
                range: TeleprompterSettings.Limits.columnWidth
            )
            TeleprompterSliderRow(
                title: model.localized("teleprompter.readingLine"),
                valueText: "\(Int((model.settings.readingLineFraction * 100).rounded()))%",
                value: $model.settings.readingLineFraction,
                range: TeleprompterSettings.Limits.readingLineFraction
            )
        }
    }

    private var displayMenu: some View {
        Menu {
            ForEach(model.availableDisplays) { display in
                Button {
                    model.selectDisplay(display.id)
                } label: {
                    if display.id == model.selectedDisplayID {
                        Label(display.name, systemImage: "checkmark")
                    } else {
                        Text(display.name)
                    }
                }
            }
            Divider()
            Button(model.localized("teleprompter.fullScreen")) {
                model.toggleFullScreen()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.selectedDisplayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                Capsule().fill(.white.opacity(0.10))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.localized("teleprompter.display"))
    }

    private func controlButton(
        _ systemImage: String,
        help: String,
        isActive: Bool = false,
        size: CGFloat = 34,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size > 40 ? 18 : 13, weight: .semibold))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(isActive ? Color.white.opacity(0.9) : Color.white.opacity(0.10))
                }
                .foregroundStyle(isActive ? Color.black : Color.white.opacity(0.88))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct TeleprompterSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer(minLength: 4)
                Text(valueText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
    }
}
