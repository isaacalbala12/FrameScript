import SwiftUI

// MARK: - Model

/// One button in the script editor action bar.
enum UXEditorAction: String, CaseIterable, Identifiable, Sendable {
    case insertShortPause
    case insertLongPause
    case insertBRollCue
    case insertImageCue
    case generateHook
    case suggestRehooks
    case analyzeScene
    case recordTake
    case teleprompter

    var id: String { rawValue }

    var group: UXActionGroup {
        switch self {
        case .insertShortPause, .insertLongPause, .insertBRollCue, .insertImageCue: .insert
        case .generateHook, .suggestRehooks, .analyzeScene: .ai
        case .recordTake, .teleprompter: .production
        }
    }

    var titleKey: String {
        switch self {
        case .insertShortPause: "ux.action.insert.shortPause"
        case .insertLongPause: "ux.action.insert.longPause"
        case .insertBRollCue: "ux.action.insert.bRoll"
        case .insertImageCue: "ux.action.insert.image"
        case .generateHook: "ux.action.ai.hook"
        case .suggestRehooks: "ux.action.ai.rehooks"
        case .analyzeScene: "ux.action.ai.analyze"
        case .recordTake: "ux.action.production.record"
        case .teleprompter: "ux.action.production.teleprompter"
        }
    }

    var systemImage: String {
        switch self {
        case .insertShortPause: "pause"
        case .insertLongPause: "hourglass"
        case .insertBRollCue: "film"
        case .insertImageCue: "photo"
        case .generateHook: "bolt.fill"
        case .suggestRehooks: "arrow.triangle.2.circlepath"
        case .analyzeScene: "sparkles"
        case .recordTake: "record.circle"
        case .teleprompter: "text.bubble"
        }
    }

    /// The command whose shortcut is shown in the tooltip, if the action is a
    /// registry command. Insertions have no assigned shortcut.
    var shortcutCommand: ShortcutCommand? {
        switch self {
        case .generateHook: .generateHook
        case .suggestRehooks: .suggestRehooks
        case .analyzeScene: .analyzeCurrentScene
        case .recordTake: .recordTake
        case .teleprompter: .teleprompter
        case .insertShortPause, .insertLongPause, .insertBRollCue, .insertImageCue: nil
        }
    }

    /// The markup inserted at the caret, for the insert group.
    var insertion: UXMarkupInsertion? {
        switch self {
        case .insertShortPause: .shortPause
        case .insertLongPause: .longPause
        case .insertBRollCue: .bRollCue
        case .insertImageCue: .imageCue
        case .generateHook, .suggestRehooks, .analyzeScene, .recordTake, .teleprompter: nil
        }
    }
}

enum UXActionGroup: String, CaseIterable, Identifiable, Sendable {
    case insert
    case ai
    case production

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .insert: "ux.inspector.group.insert"
        case .ai: "ux.inspector.group.ai"
        case .production: "ux.inspector.group.production"
        }
    }

    var actions: [UXEditorAction] {
        UXEditorAction.allCases.filter { $0.group == self }
    }
}

/// Pure enablement for the bar and the inspector's quick actions.
///
/// The project/scene/recording rules come straight from `CommandAvailability`
/// (the same matrix the menu, palette and welcome screen use). The only extra
/// input is whether an AI provider is configured, which mirrors the guard the
/// AI actions already perform themselves.
struct UXActionBarModel: Equatable {
    let availability: CommandAvailability
    let isAIProviderConfigured: Bool

    init(availability: CommandAvailability, isAIProviderConfigured: Bool) {
        self.availability = availability
        self.isAIProviderConfigured = isAIProviderConfigured
    }

    @MainActor
    init(appState: AppState) {
        self.init(
            availability: CommandAvailability(appState: appState),
            isAIProviderConfigured: appState.settings.aiPreferences.provider != .disabled
        )
    }

    func isEnabled(_ action: UXEditorAction) -> Bool {
        switch action.group {
        case .insert:
            availability.canInsertMarkup
        case .ai:
            availability.canAnalyzeScene && isAIProviderConfigured
        case .production:
            switch action {
            case .recordTake: availability.canToggleRecording
            case .teleprompter: availability.canOpenTeleprompter
            default: false
            }
        }
    }

    /// Localization key explaining a disable that is not obvious from the
    /// command matrix, or `nil` when the button is simply not applicable.
    func disabledReasonKey(for action: UXEditorAction) -> String? {
        guard !isEnabled(action) else { return nil }
        if action.group == .ai, availability.canAnalyzeScene, !isAIProviderConfigured {
            return "ux.action.aiUnavailable"
        }
        return nil
    }
}

enum UXActionBarLabelMode {
    case all
    case insertAndProduction
    case none

    func showsLabel(for group: UXActionGroup) -> Bool {
        switch self {
        case .all: true
        case .insertAndProduction: group != .ai
        case .none: false
        }
    }
}

enum UXActionTooltip {
    /// `Title (⌘K)`, or just the title when the command is unassigned. The
    /// binding comes from `Settings`, so user overrides are always respected.
    static func text(
        title: String,
        command: ShortcutCommand?,
        settings: AppSettings,
        disabledReason: String? = nil
    ) -> String {
        var result = title
        if let command, let binding = settings.activeShortcut(for: command) {
            result += " (\(binding.display))"
        }
        if let disabledReason {
            result += " — \(disabledReason)"
        }
        return result
    }
}

// MARK: - Execution

@MainActor
enum UXEditorActionPerformer {
    static func perform(
        _ action: UXEditorAction,
        sceneID: UUID?,
        appState: AppState,
        inspectorState: UXInspectorState?
    ) {
        switch action {
        case .insertShortPause, .insertLongPause, .insertBRollCue, .insertImageCue:
            guard let sceneID, let insertion = action.insertion else { return }
            _ = ActiveScriptEditorSession.shared.insertMarkup(insertion, inScene: sceneID)
        case .generateHook:
            HookSheetPresenter.shared.present(.hook)
        case .suggestRehooks:
            HookSheetPresenter.shared.present(.rehook)
        case .analyzeScene:
            appState.settings.editorPreferences.showAIReviewPanel = true
            inspectorState?.select(.ai)
            Task { await appState.analyzeSelectedScene() }
        case .recordTake:
            appState.toggleRecordingTake()
        case .teleprompter:
            appState.presentTeleprompter()
        }
    }
}

// MARK: - Views

/// Action bar between the scene meta line and the script text.
///
/// It sits inside `ScriptEditorView`, so it already shares the text column's
/// width and alignment. `ViewThatFits` keeps the widest label layout that
/// fits; tooltips keep the full name and the active shortcut.
struct UXEditorActionBar: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(UXInspectorState.self) private var inspectorState: UXInspectorState?

    let sceneID: UUID
    /// Snapshot/preview seam for a hover highlight. Production leaves it `nil`
    /// and uses the real pointer hover.
    var previewHoveredAction: UXEditorAction?

    var body: some View {
        // Real measurement instead of fixed width thresholds: the full label
        // set wins when it fits, then labels for the Insert and Production
        // groups (AI stays icon-only), then all icons. This keeps labels
        // visible in a 1180 pt window with the inspector open.
        ViewThatFits(in: .horizontal) {
            barContent(labelMode: .all)
            barContent(labelMode: .insertAndProduction)
            barContent(labelMode: .none)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }

    private func barContent(labelMode: UXActionBarLabelMode) -> some View {
        let model = UXActionBarModel(appState: appState)

        return HStack(spacing: 0) {
            ForEach(Array(UXActionGroup.allCases.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, 3)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) {
                    ForEach(group.actions) { action in
                        UXActionButton(
                            action: action,
                            title: appState.localized(action.titleKey),
                            showsLabel: labelMode.showsLabel(for: group),
                            isEnabled: model.isEnabled(action),
                            tooltip: tooltip(for: action, model: model),
                            emphasis: UXActionEmphasisPolicy.emphasis(for: action),
                            isPreviewHovered: previewHoveredAction == action
                        ) {
                            UXEditorActionPerformer.perform(
                                action,
                                sceneID: sceneID,
                                appState: appState,
                                inspectorState: inspectorState
                            )
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(appState.localized(group.titleKey))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func tooltip(for action: UXEditorAction, model: UXActionBarModel) -> String {
        let reason = model.disabledReasonKey(for: action).map { appState.localized($0) }
        return UXActionTooltip.text(
            title: appState.localized(action.titleKey),
            command: action.shortcutCommand,
            settings: appState.settings,
            disabledReason: reason
        )
    }
}

enum UXActionEmphasis: Equatable {
    case standard
    case filled
}

enum UXActionEmphasisPolicy {
    /// Only "Grabar toma" is the filled primary; every other action is plain.
    static func emphasis(for action: UXEditorAction) -> UXActionEmphasis {
        action == .recordTake ? .filled : .standard
    }
}

/// One bar button. Deliberately not focusable: clicking it must leave the
/// script text view as first responder so the insertion lands at the caret.
struct UXActionButton: View {
    @Environment(\.frameTheme) private var theme

    let action: UXEditorAction
    let title: String
    let showsLabel: Bool
    let tooltip: String
    let emphasis: UXActionEmphasis
    var isPreviewHovered = false
    let perform: () -> Void
    private let isEnabledOverride: Bool

    @State private var isHovered = false

    init(
        action: UXEditorAction,
        title: String,
        showsLabel: Bool,
        isEnabled: Bool,
        tooltip: String,
        emphasis: UXActionEmphasis = .standard,
        isPreviewHovered: Bool = false,
        perform: @escaping () -> Void
    ) {
        self.action = action
        self.title = title
        self.showsLabel = showsLabel
        self.tooltip = tooltip
        self.emphasis = emphasis
        self.isPreviewHovered = isPreviewHovered
        self.perform = perform
        self.isEnabledOverride = isEnabled
    }

    private var effectiveHover: Bool {
        (isHovered || isPreviewHovered) && isEnabledOverride
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 13)
                if showsLabel {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, showsLabel ? 4 : 0)
            .frame(width: showsLabel ? nil : 24, height: 26)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            }
            .opacity(isEnabledOverride ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .clickableCursor(enabled: isEnabledOverride)
        .focusable(false)
        .disabled(!isEnabledOverride)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .accessibilityLabel(title)
        .accessibilityHint(tooltip)
        .accessibilityIdentifier("ux-action-\(action.rawValue)")
    }

    private var foreground: Color {
        guard isEnabledOverride else { return theme.tertiaryText }
        switch emphasis {
        case .standard:
            return effectiveHover ? theme.primaryText : theme.secondaryText
        case .filled:
            return FrameTheme.textColor(onFill: theme.accentStrong)
        }
    }

    private var background: Color {
        guard isEnabledOverride else {
            return emphasis == .filled ? theme.hover : Color.clear
        }
        switch emphasis {
        case .standard:
            return effectiveHover ? theme.hover : Color.clear
        case .filled:
            return theme.accentStrong.opacity(effectiveHover ? 0.88 : 1)
        }
    }
}

/// The two chips in the scene meta line. Both open the inspector's Scene tab.
struct UXSceneMetaChips: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(UXInspectorState.self) private var inspectorState: UXInspectorState?

    let scene: Scene

    var body: some View {
        let takes = appState.recording.takes(in: scene)
        if scene.targetDuration != nil || !takes.isEmpty {
            HStack(spacing: 6) {
                if let target = scene.targetDuration {
                    chip(
                        systemImage: "target",
                        text: DurationEstimator.formatted(target),
                        help: String(
                            format: appState.localized("ux.chip.target.help"),
                            DurationEstimator.formatted(target)
                        ),
                        identifier: "ux-chip-target"
                    )
                }
                if !takes.isEmpty {
                    chip(
                        systemImage: "video.fill",
                        text: L10n.plural(
                            "ux.chip.takes",
                            count: takes.count,
                            language: appState.currentLanguage
                        ),
                        help: appState.localized("ux.chip.takes.help"),
                        identifier: "ux-chip-takes"
                    )
                }
            }
        }
    }

    private func chip(
        systemImage: String,
        text: String,
        help: String,
        identifier: String
    ) -> some View {
        UXMetaChip(systemImage: systemImage, text: text, help: help, identifier: identifier) {
            openSceneTab()
        }
    }

    private func openSceneTab() {
        appState.settings.editorPreferences.showAIReviewPanel = true
        inspectorState?.select(.scene)
    }
}

private struct UXMetaChip: View {
    @Environment(\.frameTheme) private var theme
    let systemImage: String
    let text: String
    let help: String
    let identifier: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 19)
            .foregroundStyle(isHovered ? theme.accentText : theme.secondaryText)
            .background {
                Capsule()
                    .fill(isHovered ? theme.accentSoft : theme.hover)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel("\(text). \(help)")
        .accessibilityIdentifier(identifier)
    }
}
