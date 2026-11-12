import SwiftUI

/// Settings for inline pause/emphasis markup, per-language reading speed and
/// the rhythm review (F3 / F4 / F11 / F26).
///
/// `SettingsView` shows this below the regular editor settings. Every control
/// refreshes the duration estimates and the rhythm review immediately.
struct EditorMarkupSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var newVideoType = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.localized("settings.markupRhythm"))
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.primaryText)

            SettingsCard {
                readingSpeedRows
                pauseRows
                rhythmToggleRow
            }

            if appState.settings.editorPreferences.rhythmReviewEnabled {
                rhythmThresholdsCard
            }

            SettingsCard {
                SettingsRow(appState.localized("settings.cleanMarkup"), help: appState.localized("settings.cleanMarkup.help")) {
                    Toggle("", isOn: settingBinding(\.exportPreferences.cleanMarkup))
                        .labelsHidden()
                }
            }
        }
        .onChange(of: appState.settings.editorPreferences.wordsPerMinuteByLanguage) { _, _ in
            appState.refreshDurationEstimates()
            appState.scheduleRhythmReview(delay: .zero)
        }
        .onChange(of: appState.settings.editorPreferences.shortPauseSeconds) { _, _ in
            appState.refreshDurationEstimates()
            appState.scheduleRhythmReview(delay: .zero)
        }
        .onChange(of: appState.settings.editorPreferences.longPauseSeconds) { _, _ in
            appState.refreshDurationEstimates()
            appState.scheduleRhythmReview(delay: .zero)
        }
        .onChange(of: appState.settings.editorPreferences.rhythmReviewEnabled) { _, _ in
            appState.scheduleRhythmReview(delay: .zero)
        }
    }

    private var settings: AppSettings { appState.settings }

    /// Binding into the shared settings store. Values are persisted by
    /// `SettingsStore`'s `didSet`, exactly like the built-in settings tabs.
    private func settingBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { appState.settings[keyPath: keyPath] },
            set: { appState.settings[keyPath: keyPath] = $0 }
        )
    }

    // MARK: Reading speed

    @ViewBuilder
    private var readingSpeedRows: some View {
        SettingsRow(
            appState.localized("settings.readingSpeedByLanguage"),
            help: appState.localized("settings.readingSpeed.help")
        ) {
            Button(appState.localized("settings.readingSpeed.reset")) {
                var preferences = appState.settings.editorPreferences
                for code in EditorPreferences.configurableDurationLanguages {
                    preferences.resetWordsPerMinute(for: code)
                }
                appState.settings.editorPreferences = preferences
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
            .clickableCursor()
        }

        ForEach(EditorPreferences.configurableDurationLanguages, id: \.self) { code in
            SettingsRow(languageTitle(code)) {
                HStack(spacing: 10) {
                    Stepper(
                        value: wordsPerMinuteBinding(for: code),
                        in: 60...260,
                        step: 5
                    ) {
                        Text("\(Int(appState.settings.editorPreferences.effectiveWordsPerMinute(for: code))) wpm")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .frame(minWidth: 78, alignment: .trailing)
                    }
                    .fixedSize()
                    if appState.settings.editorPreferences.hasCustomWordsPerMinute(for: code) {
                        Text(appState.localized("settings.readingSpeed.custom"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
        }
    }

    private func languageTitle(_ code: String) -> String {
        switch code {
        case "es": appState.localized("settings.readingSpeed.spanish")
        case "en": appState.localized("settings.readingSpeed.english")
        case "ru": appState.localized("settings.readingSpeed.russian")
        default: code.uppercased()
        }
    }

    private func wordsPerMinuteBinding(for code: String) -> Binding<Int> {
        Binding(
            get: { Int(appState.settings.editorPreferences.effectiveWordsPerMinute(for: code)) },
            set: { newValue in
                var preferences = appState.settings.editorPreferences
                preferences.setWordsPerMinute(newValue, for: code)
                appState.settings.editorPreferences = preferences
            }
        )
    }

    // MARK: Pauses

    @ViewBuilder
    private var pauseRows: some View {
        SettingsRow(appState.localized("settings.shortPause")) {
            Stepper(
                value: settingBinding(\.editorPreferences.shortPauseSeconds),
                in: 0.1...5,
                step: 0.1
            ) {
                Text(String(format: appState.localized("settings.pauseSeconds"), formattedSeconds(settings.editorPreferences.shortPauseSeconds)))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .fixedSize()
        }

        SettingsRow(appState.localized("settings.longPause")) {
            Stepper(
                value: settingBinding(\.editorPreferences.longPauseSeconds),
                in: 0.1...8,
                step: 0.1
            ) {
                Text(String(format: appState.localized("settings.pauseSeconds"), formattedSeconds(settings.editorPreferences.longPauseSeconds)))
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .fixedSize()
        }
    }

    private func formattedSeconds(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    // MARK: Rhythm

    private var rhythmToggleRow: some View {
        SettingsRow(appState.localized("settings.rhythmReview"), help: appState.localized("settings.rhythmReview.help")) {
            Toggle("", isOn: settingBinding(\.editorPreferences.rhythmReviewEnabled))
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var rhythmThresholdsCard: some View {
        SettingsCard {
            SettingsRow(
                appState.localized("settings.rhythmThresholds"),
                help: appState.localized("settings.rhythmThresholds.help")
            ) {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(
                            appState.localized("settings.rhythmVideoTypePlaceholder"),
                            text: $newVideoType
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                        Button(appState.localized("settings.rhythmAddVideoType")) {
                            let type = newVideoType.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !type.isEmpty else { return }
                            if appState.settings.rhythmThresholdsByVideoType[type] == nil {
                                appState.settings.rhythmThresholdsByVideoType[type] = .appDefaults
                            }
                            newVideoType = ""
                            appState.scheduleRhythmReview(delay: .zero)
                        }
                        .clickableCursor()
                    }
                    Text(appState.localized("settings.rhythmTypeDefault"))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }
            }

            ForEach(videoTypes, id: \.self) { type in
                VideoTypeThresholdRow(
                    videoType: type,
                    thresholds: thresholdsBinding(for: type),
                    canRemove: !EditorMarkupSettingsSection.defaultVideoTypes.contains(type),
                    onRemove: {
                        appState.settings.rhythmThresholdsByVideoType.removeValue(forKey: type)
                        appState.scheduleRhythmReview(delay: .zero)
                    },
                    onReset: {
                        appState.settings.rhythmThresholdsByVideoType[type] = .appDefaults
                        appState.scheduleRhythmReview(delay: .zero)
                    }
                )
            }

            if appState.hasOpenProject {
                projectOverrideRow
            }
        }
    }

    private var videoTypes: [String] {
        // The built-in types stay visible so the table is useful before any
        // project defines a type. Custom types are appended and removable.
        var types = EditorMarkupSettingsSection.defaultVideoTypes
        types.formUnion(appState.settings.rhythmThresholdsByVideoType.keys)
        let projectType = appState.project.videoType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !projectType.isEmpty {
            types.insert(projectType)
        }
        return types.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static let defaultVideoTypes: Set<String> = [
        "Análisis", "Gameplay", "Review", "Comparativa", "Noticia", "Crónica", "Tutorial", "Vantare"
    ]

    private func thresholdsBinding(for type: String) -> Binding<AppRhythmThresholds> {
        Binding(
            get: {
                appState.settings.rhythmThresholdsByVideoType[type] ?? .appDefaults
            },
            set: { value in
                appState.settings.rhythmThresholdsByVideoType[type] = value
            }
        )
    }

    @ViewBuilder
    private var projectOverrideRow: some View {
        SettingsRow(appState.localized("settings.rhythmProjectOverride")) {
            Toggle("", isOn: Binding(
                get: { appState.project.rhythmThresholdsOverride != nil },
                set: { isOn in
                    if isOn {
                        let effective = RhythmReview.effectiveThresholds(
                            project: appState.project,
                            settings: appState.settings
                        )
                        appState.project.rhythmThresholdsOverride = AppRhythmThresholds(core: effective)
                    } else {
                        appState.project.rhythmThresholdsOverride = nil
                    }
                    appState.touchProject()
                    appState.scheduleRhythmReview(delay: .zero)
                }
            ))
            .labelsHidden()
        }

        if let override = appState.project.rhythmThresholdsOverride {
            ProjectThresholdRow(
                thresholds: Binding(
                    get: { appState.project.rhythmThresholdsOverride ?? override },
                    set: { value in
                        appState.project.rhythmThresholdsOverride = value
                        appState.touchProject()
                        appState.scheduleRhythmReview(delay: .zero)
                    }
                ),
                onReset: {
                    appState.project.rhythmThresholdsOverride = nil
                    appState.touchProject()
                    appState.scheduleRhythmReview(delay: .zero)
                }
            )
        }
    }

}

/// One editable video type in the rhythm threshold table.
private struct VideoTypeThresholdRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let videoType: String
    @Binding var thresholds: AppRhythmThresholds
    let canRemove: Bool
    let onRemove: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(videoType)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Spacer()
                Button(appState.localized("settings.rhythmResetThresholds")) { onReset() }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .clickableCursor()
                if canRemove {
                    Button(role: .destructive) { onRemove() } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(appState.localized("settings.rhythmRemove"))
                    .accessibilityLabel(appState.localized("settings.rhythmRemove"))
                    .clickableCursor()
                }
            }

            HStack(spacing: 14) {
                RhythmIntThresholdField(
                    title: appState.localized("settings.rhythmSentenceWords"),
                    value: $thresholds.longSentenceWordLimit,
                    defaultValue: 25,
                    range: 5...80
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmUncoveredSeconds"),
                    value: $thresholds.uncoveredSecondsLimit,
                    defaultValue: 5,
                    range: 1...30,
                    step: 0.5,
                    suffix: " s"
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmSceneRatio"),
                    value: $thresholds.sceneLengthRatioLimit,
                    defaultValue: 1.8,
                    range: 1.1...5,
                    step: 0.1,
                    suffix: "×"
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmHookSeconds"),
                    value: $thresholds.hookSecondsLimit,
                    defaultValue: 15,
                    range: 3...90,
                    step: 1,
                    suffix: " s"
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }
}

/// Integer variant for the word-count threshold.
private struct RhythmIntThresholdField: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    @Binding var value: Int?
    let defaultValue: Int
    let range: ClosedRange<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .lineLimit(2)
            Stepper(
                value: Binding(
                    get: { value ?? defaultValue },
                    set: { value = $0 }
                ),
                in: range
            ) {
                Text("\(value ?? defaultValue)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .leading)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact numeric field for an optional threshold. `nil` means "inherit the
/// lower layer", which the stepper materializes as the effective default.
private struct RhythmThresholdField: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    @Binding var value: Double?
    let defaultValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .lineLimit(2)
            Stepper(
                value: Binding(
                    get: { value ?? defaultValue },
                    set: { value = $0 }
                ),
                in: range,
                step: step
            ) {
                Text(formatted)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .leading)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formatted: String {
        let current = value ?? defaultValue
        if step >= 1 {
            return "\(Int(current.rounded()))\(suffix)"
        }
        return String(format: "%.1f", current) + suffix
    }
}

private struct ProjectThresholdRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Binding var thresholds: AppRhythmThresholds
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(appState.localized("settings.rhythmProjectOverride"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button(appState.localized("settings.rhythmResetThresholds")) { onReset() }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .clickableCursor()
            }
            HStack(spacing: 14) {
                RhythmIntThresholdField(
                    title: appState.localized("settings.rhythmSentenceWords"),
                    value: $thresholds.longSentenceWordLimit,
                    defaultValue: 25,
                    range: 5...80
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmUncoveredSeconds"),
                    value: $thresholds.uncoveredSecondsLimit,
                    defaultValue: 5,
                    range: 1...30,
                    step: 0.5,
                    suffix: " s"
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmSceneRatio"),
                    value: $thresholds.sceneLengthRatioLimit,
                    defaultValue: 1.8,
                    range: 1.1...5,
                    step: 0.1,
                    suffix: "×"
                )
                RhythmThresholdField(
                    title: appState.localized("settings.rhythmHookSeconds"),
                    value: $thresholds.hookSecondsLimit,
                    defaultValue: 15,
                    range: 3...90,
                    step: 1,
                    suffix: " s"
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
