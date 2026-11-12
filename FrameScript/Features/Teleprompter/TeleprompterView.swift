import SwiftUI

private enum TeleprompterPalette {
    static let background = Color.black
    static let guide = Color.white.opacity(0.16)
    static let status = Color.white.opacity(0.32)
}

struct TeleprompterRootView: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                TeleprompterPalette.background.ignoresSafeArea()

                TeleprompterTextCanvas(
                    model: model,
                    revision: model.layoutRevision,
                    sections: model.sections,
                    fontSize: model.settings.fontSize,
                    columnWidth: model.effectiveColumnWidth,
                    viewportSize: proxy.size,
                    readingLineFraction: model.settings.readingLineFraction,
                    mirrorVertical: model.settings.mirrorVertical
                )
                .scaleEffect(
                    x: model.settings.mirrorHorizontal ? -1 : 1,
                    y: model.settings.mirrorVertical ? -1 : 1
                )

                readingLine(viewport: proxy.size)
                statusBar

                if model.countdown == nil && (model.controlsVisible || !model.isPlaying) {
                    TeleprompterControls(model: model)
                        .transition(.opacity)
                }

                if let countdown = model.countdown {
                    countdownOverlay(countdown)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.controlsVisible)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear {
                model.updateViewport(width: proxy.size.width, height: proxy.size.height)
            }
            .onChange(of: proxy.size) { _, size in
                model.updateViewport(width: size.width, height: size.height)
            }
        }
        .background(TeleprompterPalette.background)
        .preferredColorScheme(.dark)
        .onChange(of: model.settings) { _, _ in
            model.showControlsTemporarily()
        }
        .onExitCommand { model.close() }
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
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72))
        .allowsHitTesting(false)
    }
}

// MARK: - TextKit canvas

private struct TeleprompterTextCanvas: NSViewRepresentable {
    let model: TeleprompterModel
    let revision: Int
    let sections: [TeleprompterSection]
    let fontSize: Double
    let columnWidth: Double
    let viewportSize: CGSize
    let readingLineFraction: Double
    let mirrorVertical: Bool

    func makeNSView(context: Context) -> TeleprompterTextRenderer {
        let renderer = TeleprompterTextRenderer(frame: .zero)
        model.attachRenderer(renderer)
        render(renderer)
        return renderer
    }

    func updateNSView(_ renderer: TeleprompterTextRenderer, context: Context) {
        render(renderer)
    }

    func dismantleNSView(_ renderer: TeleprompterTextRenderer, coordinator: Context) {
        model.detachRenderer(renderer)
    }

    private func render(_ renderer: TeleprompterTextRenderer) {
        _ = revision
        renderer.render(
            sections: sections,
            fontSize: fontSize,
            columnWidth: columnWidth,
            viewportSize: viewportSize,
            readingLineFraction: readingLineFraction,
            mirrorVertical: mirrorVertical,
            onMetrics: { metrics in
                Task { @MainActor in
                    model.updateTextMetrics(metrics)
                }
            }
        )
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
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0.80), location: 0.30),
                    .init(color: .black.opacity(0.97), location: 0.62),
                    .init(color: .black.opacity(0.99), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
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
