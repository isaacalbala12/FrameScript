import FrameScriptCore
import SwiftUI

// MARK: - Compact display

/// Read-only "1:20 · real 1:34" text used by sidebar rows. The real part turns
/// into the warning colour when it exceeds the scene target.
struct SceneDurationInlineText: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let summary: SceneDurationSummary

    var body: some View {
        HStack(spacing: 4) {
            Text(DurationEstimator.formatted(summary.estimated))

            if let real = summary.real {
                Text("·")
                    .foregroundStyle(theme.tertiaryText)
                Text("\(appState.localized("duration.real")) \(DurationEstimator.formatted(real))")
                    .foregroundStyle(summary.isOverTarget ? theme.warning : theme.secondaryText.opacity(0.9))
            }
        }
        .font(.system(size: 11))
        // Plain `secondaryText`: the old `.opacity(0.82)` dropped the contrast
        // on the sidebar to 3.18:1 for this 11 pt label.
        .foregroundStyle(theme.secondaryText)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [
            "\(appState.localized("script.estimated")) \(DurationEstimator.formatted(summary.estimated))"
        ]
        if let real = summary.real {
            parts.append("\(appState.localized("duration.real")) \(DurationEstimator.formatted(real))")
        }
        if summary.isOverTarget {
            parts.append(overrunText(summary.overrun, appState: appState))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Scene header control

/// Duration label in the scene header. Clicking it opens the targets popover.
struct SceneDurationControl: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene

    @State private var isPopoverPresented = false

    private var summary: SceneDurationSummary {
        appState.sceneDurationSummary(for: scene)
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(DurationEstimator.formatted(summary.estimated))

                Text(appState.localized("script.estimated"))
                    .foregroundStyle(theme.tertiaryText)

                if let real = summary.real {
                    Text("·")
                        .foregroundStyle(theme.tertiaryText)
                    Text("\(appState.localized("duration.real")) \(DurationEstimator.formatted(real))")
                        .foregroundStyle(summary.isOverTarget ? theme.warning : theme.primaryText)
                }

                if summary.isOverTarget {
                    Text(overrunText(summary.overrun, appState: appState))
                        .foregroundStyle(theme.warning)
                }

                if summary.target != nil {
                    Image(systemName: "target")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appState.localized("duration.sceneHelp"))
        .accessibilityIdentifier("scene-duration-control")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            SceneDurationPopover(scene: scene)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }
}

struct SceneDurationPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene

    @State private var targetText = ""

    private var summary: SceneDurationSummary {
        appState.sceneDurationSummary(for: scene)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scene.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                durationRow(
                    label: appState.localized("duration.estimated"),
                    value: DurationEstimator.formatted(summary.estimated),
                    detail: String(
                        format: appState.localized("duration.atWordsPerMinute"),
                        DurationNumber.clampedInt(
                            appState.effectiveWPM(language: appState.durationProjectLanguage),
                            range: 30...400
                        )
                    )
                )
                durationRow(
                    label: appState.localized("duration.real"),
                    value: summary.real.map(DurationEstimator.formatted) ?? appState.localized("duration.noReal"),
                    detail: realTakeDetail
                )
            }

            if let target = summary.target, let progress = summary.progress {
                Divider()
                durationRow(
                    label: appState.localized("duration.target"),
                    value: DurationEstimator.formatted(target),
                    detail: String(
                        format: appState.localized("duration.percentOfTarget"),
                        DurationNumber.percent(progress)
                    )
                )
                DurationProgressBar(
                    progress: progress,
                    isOverTarget: summary.isOverTarget
                )
                if summary.isOverTarget {
                    Label(
                        overrunText(summary.overrun, appState: appState),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.warning)
                }
            }

            Divider()
            targetEditor
        }
        .padding(14)
        .frame(width: 340)
        .onAppear(perform: syncTargetText)
    }

    private var realTakeDetail: String {
        guard let number = summary.realTakeNumber else {
            return appState.localized("duration.noRealHint")
        }
        let rating = appState.localized("duration.rating.\(summary.realTakeRating?.rawValue ?? "unrated")")
        return String(format: appState.localized("duration.takeDetail"), number, rating)
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized("duration.sceneTarget"))
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                TextField(appState.localized("duration.targetPlaceholder"), text: $targetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .onSubmit(applyTarget)

                Button(appState.localized("duration.set"), action: applyTarget)
                    .disabled(parsedTarget == nil)
                    .buttonStyle(DurationActionButtonStyle())

                Spacer(minLength: 0)

                if scene.targetDuration != nil {
                    Button(appState.localized("duration.clear"), action: clearTarget)
                        .buttonStyle(DurationActionButtonStyle())
                }
            }

            Text(appState.localized("duration.targetHelp"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var parsedTarget: TimeInterval? {
        guard let value = DurationInput.parse(targetText), value > 0 else { return nil }
        return value
    }

    private func syncTargetText() {
        targetText = scene.targetDuration.map(DurationInput.fieldValue) ?? ""
    }

    private func applyTarget() {
        guard let parsedTarget else { return }
        appState.setSceneTargetDuration(parsedTarget, sceneID: scene.id)
        syncTargetText()
    }

    private func clearTarget() {
        appState.setSceneTargetDuration(nil, sceneID: scene.id)
        syncTargetText()
    }
}

// MARK: - Project toolbar control

/// Project total in the toolbar. Shows the estimated total plus how many
/// scenes already have a real take, and opens the project-info popover.
struct ProjectDurationControl: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    @State private var isPopoverPresented = false

    var body: some View {
        // One summary per body evaluation: `projectDurationSummary()` hashes the
        // text of every scene, so reading it eight times was measurable.
        let summary = appState.projectDurationSummary()
        return Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(DurationEstimator.formatted(summary.displayTotal))

                if summary.scenesWithReal > 0 {
                    Text("·")
                        .foregroundStyle(theme.tertiaryText)
                    if summary.allScenesHaveReal {
                        Text("\(appState.localized("duration.real")) \(DurationEstimator.formatted(summary.realOrEstimated))")
                    } else {
                        Text(
                            String(
                                format: appState.localized("duration.realCount"),
                                summary.scenesWithReal,
                                summary.sceneCount
                            )
                        )
                    }
                }

                if summary.isOverTarget {
                    Text(overrunText(summary.overrun, appState: appState))
                        .foregroundStyle(theme.warning)
                }
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(summary.isOverTarget ? theme.warning : theme.secondaryText)
            .monospacedDigit()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appState.localized("duration.projectHelp"))
        .accessibilityIdentifier("project-duration-control")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            ProjectDurationPopover()
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .onAppear {
            seedDurationDemoIfNeeded()
            appState.recomputeLearnedWPMInBackground(markDirty: false)
        }
        .onChange(of: appState.project.id) { _, _ in
            seedDurationDemoIfNeeded()
            appState.recomputeLearnedWPMInBackground(markDirty: false)
        }
        .onChange(of: appState.durationRevision) { _, _ in
            DurationLearningScheduler.shared.schedule {
                appState.recomputeLearnedWPMInBackground()
            }
        }
    }

    private func seedDurationDemoIfNeeded() {
#if DEBUG
        appState.seedDurationDemoIfNeeded()
#endif
    }
}

struct ProjectDurationPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    @State private var targetText = ""
    @State private var learningReport: DurationLearningResult = .empty

    var body: some View {
        // Same reason as `ProjectDurationControl`: one whole-project summary per
        // body evaluation, not one per read.
        let summary = appState.projectDurationSummary()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(appState.localized("duration.projectInfo"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text(appState.project.title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 7) {
                durationRow(
                    label: appState.localized("duration.estimated"),
                    value: DurationEstimator.formatted(summary.estimated),
                    detail: nil
                )
                durationRow(
                    label: appState.localized("duration.realOrEstimated"),
                    value: DurationEstimator.formatted(summary.realOrEstimated),
                    detail: String(
                        format: appState.localized("duration.realCount"),
                        summary.scenesWithReal,
                        summary.sceneCount
                    )
                )
            }

            if let target = summary.target, let progress = summary.progress {
                Divider()
                durationRow(
                    label: appState.localized("duration.projectTarget"),
                    value: DurationEstimator.formatted(target),
                    detail: String(
                        format: appState.localized("duration.percentOfTarget"),
                        DurationNumber.percent(progress)
                    )
                )
                DurationProgressBar(
                    progress: progress,
                    isOverTarget: summary.isOverTarget
                )
                if summary.isOverTarget {
                    Label(
                        overrunText(summary.overrun, appState: appState),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.warning)
                }
            }

            Divider()
            targetEditor

            Divider()
            learnedSection
        }
        .padding(14)
        .frame(width: 400)
        .task {
            await refreshLearningReport()
        }
        .onAppear(perform: syncTargetText)
        .onChange(of: appState.project.learnedWordsPerMinuteByLanguage) { _, _ in
            Task { await refreshLearningReport() }
        }
    }

    private func refreshLearningReport() async {
        let signature = appState.durationLearningSignature
        let report = await appState.durationLearningReportAsync()
        guard appState.durationLearningSignature == signature else { return }
        learningReport = report
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized("duration.projectTarget"))
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                TextField(appState.localized("duration.targetPlaceholder"), text: $targetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .onSubmit(applyTarget)

                Button(appState.localized("duration.set"), action: applyTarget)
                    .disabled(parsedTarget == nil)
                    .buttonStyle(DurationActionButtonStyle())

                Spacer(minLength: 0)

                if appState.project.targetDuration != nil {
                    Button(appState.localized("duration.clear"), action: clearTarget)
                        .buttonStyle(DurationActionButtonStyle())
                }
            }

            Text(appState.localized("duration.targetHelp"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var learnedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("duration.learnedWPM"))
                .font(.system(size: 12, weight: .medium))

            Text(appState.localized("duration.learnedWPMHelp"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(SpeechLanguage.allCases, id: \.rawValue) { language in
                learnedRow(for: language)
            }
        }
    }

    private func learnedRow(for language: SpeechLanguage) -> some View {
        let statistics = learningReport.statistics(for: language.rawValue)
        let accepted = statistics?.acceptedSampleCount ?? 0
        let minimum = WPMConfiguration().minimumAcceptedSamples
        let wordsPerMinute = DurationNumber.clampedInt(
            appState.effectiveWPM(language: language.rawValue),
            range: 30...400
        )
        let hasAnythingToReset = accepted > 0
            || appState.project.learnedWordsPerMinuteByLanguage[language.rawValue] != nil

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(appState.localized("duration.language.\(language.rawValue)"))
                .font(.system(size: 12))

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: appState.localized("duration.wordsPerMinute"), wordsPerMinute))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Text(sampleDetail(accepted: accepted, minimum: minimum))
                    .font(.system(size: 10))
                    .foregroundStyle(accepted >= minimum ? theme.success : theme.secondaryText)
            }

            // Nothing learned means nothing to reset: the button only exists
            // when it would do something (V7).
            if hasAnythingToReset {
                Button(appState.localized("duration.reset")) {
                    appState.resetLearnedWPM(language: language.rawValue)
                }
                .buttonStyle(DurationActionButtonStyle())
                .help(appState.localized("duration.resetHelp"))
            }
        }
    }

    private func sampleDetail(accepted: Int, minimum: Int) -> String {
        if accepted == 0 {
            return appState.localized("duration.noSamples")
        }
        if accepted < minimum {
            return String(format: appState.localized("duration.learningSamples"), accepted, minimum)
        }
        return L10n.plural("duration.samples", count: accepted, language: appState.currentLanguage)
    }

    private var parsedTarget: TimeInterval? {
        guard let value = DurationInput.parse(targetText), value > 0 else { return nil }
        return value
    }

    private func syncTargetText() {
        targetText = appState.project.targetDuration.map(DurationInput.fieldValue) ?? ""
    }

    private func applyTarget() {
        guard let parsedTarget else { return }
        appState.setProjectTargetDuration(parsedTarget)
        syncTargetText()
    }

    private func clearTarget() {
        appState.setProjectTargetDuration(nil)
        syncTargetText()
    }
}

// MARK: - Shared rows

/// Small bordered action that reads as a button, not as disabled text.
///
/// The system `.bordered` style greys its label while the window is not key, so
/// "Fijar", "Borrar" and "Restablecer" looked like plain grey text (V7). This
/// draws the border and the accent text colour itself, in every window state.
private struct DurationActionButtonStyle: ButtonStyle {
    @Environment(\.frameTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint = isEnabled ? theme.accentText : theme.tertiaryText
        return configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint.opacity(configuration.isPressed ? 0.9 : 0.55), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct DurationProgressBar: View {
    @Environment(\.frameTheme) private var theme
    let progress: Double
    let isOverTarget: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(theme.hover)
                Capsule(style: .continuous)
                    .fill(isOverTarget ? theme.warning : theme.accent.color)
                    .frame(width: max(2, proxy.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

private func durationRow(label: String, value: String, detail: String?) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
            if let detail {
                // `.tertiary` is too faint at 10 pt on the popover surface.
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private func overrunText(_ seconds: TimeInterval, appState: AppState) -> String {
    let rounded = max(1, DurationNumber.clampedInt(seconds, range: 0...999_999_999))
    if rounded < 60 {
        return String(format: appState.localized("duration.overSeconds"), rounded)
    }
    return String(
        format: appState.localized("duration.overClock"),
        DurationEstimator.formatted(seconds)
    )
}
