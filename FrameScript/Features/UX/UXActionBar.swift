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
    case productionChecklist
    case researchPanel
    case assets
    case publishingPack
    case resolvePack

    var id: String { rawValue }

    var group: UXActionGroup {
        switch self {
        case .insertShortPause, .insertLongPause, .insertBRollCue, .insertImageCue: .insert
        case .generateHook, .suggestRehooks, .analyzeScene: .ai
        case .recordTake, .teleprompter: .production
        case .productionChecklist, .researchPanel, .assets, .publishingPack, .resolvePack: .project
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
        case .productionChecklist: "ux.action.project.production"
        case .researchPanel: "ux.action.project.research"
        case .assets: "ux.action.project.assets"
        case .publishingPack: "ux.action.project.publishing"
        case .resolvePack: "ux.action.project.resolve"
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
        case .productionChecklist: "checklist"
        case .researchPanel: "books.vertical"
        case .assets: "photo.stack"
        case .publishingPack: "megaphone"
        case .resolvePack: "film.stack"
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
        case .productionChecklist: .productionChecklist
        case .researchPanel: .researchPanel
        case .assets: .assets
        case .publishingPack: .publishingPack
        case .resolvePack: .resolvePack
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
        case .generateHook, .suggestRehooks, .analyzeScene, .recordTake, .teleprompter,
             .productionChecklist, .researchPanel, .assets, .publishingPack, .resolvePack:
            nil
        }
    }
}

enum UXActionGroup: String, CaseIterable, Identifiable, Sendable {
    case insert
    case ai
    case production
    case project

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .insert: "ux.inspector.group.insert"
        case .ai: "ux.inspector.group.ai"
        case .production: "ux.inspector.group.production"
        case .project: "ux.inspector.group.project"
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
        case .project:
            // Exactly the menu matrix: a project is enough for these panels,
            // no selected scene is required.
            action.shortcutCommand.map(availability.isEnabled) ?? false
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

/// Spacing of the action bar. One place so the bar, the hidden measuring
/// copies and the tests agree on the numbers.
struct UXActionBarMetrics: Equatable {
    /// Space between the rounded container and its first/last button.
    var horizontalInset: CGFloat
    var verticalInset: CGFloat
    /// Gap between neighbouring buttons of one group.
    var buttonGap: CGFloat
    /// Space on each side of a group separator.
    var dividerInset: CGFloat
    /// Padding on each side of a button's icon + label.
    var labelPadding: CGFloat

    static let regular = UXActionBarMetrics(
        horizontalInset: FrameSpacing.m - 2,
        verticalInset: FrameSpacing.xs + 1,
        buttonGap: FrameSpacing.xxs,
        dividerInset: FrameSpacing.s,
        labelPadding: FrameSpacing.s - 2
    )

    /// The two middle layouts tighten gaps so Insertar keeps its labels at
    /// the 1180 pt window with the inspector open (about 8 pt of slack). The
    /// outer insets stay.
    static let compact = UXActionBarMetrics(
        horizontalInset: FrameSpacing.m - 2,
        verticalInset: FrameSpacing.xs + 1,
        buttonGap: 0,
        dividerInset: FrameSpacing.xxs,
        labelPadding: FrameSpacing.xs - 1
    )

    static func metrics(compact isCompact: Bool) -> UXActionBarMetrics {
        isCompact ? .compact : .regular
    }

    /// Bar height: button height plus the vertical inset on both sides.
    var barHeight: CGFloat { FrameControlHeight.compact + 2 * verticalInset }
}

enum UXActionBarLabelMode: CaseIterable, Hashable {
    /// Everything labeled.
    case all
    /// Proyecto collapses first: its buttons become icons and keep the badges.
    case allButProject
    /// IA collapses next.
    case insertAndProduction
    /// Producción collapses next; Insertar is the last group with labels.
    case insertOnly
    case none

    /// Widest first: the order the bar tries the layouts in.
    static let fittingOrder: [UXActionBarLabelMode] = [
        .all, .allButProject, .insertAndProduction, .insertOnly, .none
    ]

    /// The two middle layouts tighten the label padding and dividers.
    var usesCompactMetrics: Bool {
        self == .insertAndProduction || self == .insertOnly
    }

    func showsLabel(for group: UXActionGroup) -> Bool {
        switch self {
        case .all: true
        case .allButProject: group != .project
        case .insertAndProduction: group == .insert || group == .production
        case .insertOnly: group == .insert
        case .none: false
        }
    }
}

/// `ViewThatFits(in: .horizontal)` selection rule for the action bar: the
/// first layout whose ideal width fits the offered width, otherwise the last.
/// Before anything is measured the widest layout is shown, exactly like an
/// unconstrained `ViewThatFits`.
@MainActor
enum UXActionBarFit {
    /// Most recent measurement of any bar. Only a starting value: every bar
    /// re-measures its own content and replaces it.
    static var lastIdealWidths: [UXActionBarLabelMode: CGFloat] = [:]

    nonisolated static func labelMode(
        availableWidth: CGFloat?,
        idealWidths: [UXActionBarLabelMode: CGFloat]
    ) -> UXActionBarLabelMode {
        let order = UXActionBarLabelMode.fittingOrder
        guard let availableWidth,
              order.allSatisfy({ idealWidths[$0] != nil }) else { return order[0] }
        return order.first { (idealWidths[$0] ?? .infinity) <= availableWidth }
            ?? order[order.count - 1]
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
        case .productionChecklist, .researchPanel, .assets, .publishingPack, .resolvePack:
            guard let command = action.shortcutCommand else { return }
            UXProjectCommandDispatcher.perform(command, appState: appState)
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

    /// Ideal width of every label layout, measured by hidden copies. A new
    /// bar (mode switch, new window) starts from the last measurement so it
    /// does not need a second pass before it shows the right layout.
    @State private var idealWidths: [UXActionBarLabelMode: CGFloat] = UXActionBarFit.lastIdealWidths

    var body: some View {
        // Real measurement instead of fixed width thresholds. Insertar is the
        // group the writer clicks constantly, so it keeps its labels longest.
        // As the column shrinks: Proyecto first turns into icon buttons (the
        // badges stay), then IA, then Producción, and only then Insertar.
        //
        // Same rule as `ViewThatFits(in: .horizontal)` (first layout whose
        // ideal width fits, else the last), but the candidates are measured by
        // stable hidden copies. `ViewThatFits` rebuilt all five 14-button bars
        // on every layout pass of the editor column, which made one keystroke
        // cost ~130 ms of main-thread time.
        let badges = UXProjectBadges(appState: appState)
        let model = UXActionBarModel(appState: appState)
        // The reader picks the layout from the width of this very layout
        // pass, so a resize never shows a stale layout for a frame.
        return GeometryReader { proxy in
            let labelMode = UXActionBarFit.labelMode(
                availableWidth: proxy.size.width,
                idealWidths: idealWidths
            )
            barContent(
                labelMode: labelMode,
                compactMetrics: labelMode.usesCompactMetrics,
                badges: badges,
                model: model
            )
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .background(alignment: .topLeading) {
            measurementCopies(badges: badges, model: model)
        }
        .frame(maxWidth: .infinity)
        .frame(height: UXActionBarMetrics.regular.barHeight)
        .layoutProbe("actionbar.bar")
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.container, style: .continuous)
                .fill(theme.panelBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: FrameRadius.container, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }

    /// One fixed-size, hidden, non-interactive copy per label layout. Their
    /// inputs only change with the badges, the language or the enablement, so
    /// SwiftUI keeps their identity and cached sizes across keystrokes.
    private func measurementCopies(badges: UXProjectBadges, model: UXActionBarModel) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(UXActionBarLabelMode.fittingOrder, id: \.self) { mode in
                barContent(
                    labelMode: mode,
                    compactMetrics: mode.usesCompactMetrics,
                    badges: badges,
                    model: model
                )
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    guard idealWidths[mode] != width else { return }
                    idealWidths[mode] = width
                    UXActionBarFit.lastIdealWidths[mode] = width
                }
            }
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func barContent(
        labelMode: UXActionBarLabelMode,
        compactMetrics: Bool = false,
        badges: UXProjectBadges,
        model: UXActionBarModel
    ) -> some View {
        let metrics = UXActionBarMetrics.metrics(compact: compactMetrics)
        return HStack(spacing: 0) {
            ForEach(Array(UXActionGroup.allCases.enumerated()), id: \.element.id) { index, group in
                if group == .project {
                    // Proyecto opens other windows rather than acting on the
                    // text, so it is pinned to the trailing edge: the bar no
                    // longer ends in a large empty strip on wide columns.
                    Spacer(minLength: 0)
                }
                if index > 0 {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1, height: 16)
                        .padding(.horizontal, metrics.dividerInset)
                        .accessibilityHidden(true)
                }
                HStack(spacing: metrics.buttonGap) {
                    ForEach(group.actions) { action in
                        UXActionButton(
                            action: action,
                            title: appState.localized(action.titleKey),
                            showsLabel: labelMode.showsLabel(for: group),
                            isEnabled: model.isEnabled(action),
                            tooltip: tooltip(for: action, model: model),
                            emphasis: UXActionEmphasisPolicy.emphasis(for: action),
                            badgeCount: badges.count(for: action),
                            badgeAccessibility: badges.accessibilityText(
                                for: action,
                                language: appState.currentLanguage
                            ),
                            labelHorizontalPadding: metrics.labelPadding,
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
        .padding(.horizontal, metrics.horizontalInset)
        .padding(.vertical, metrics.verticalInset)
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
    var badgeCount: Int?
    var badgeAccessibility: String?
    var isPreviewHovered = false
    let perform: () -> Void
    private let isEnabledOverride: Bool
    private let labelHorizontalPadding: CGFloat

    @State private var isHovered = false

    init(
        action: UXEditorAction,
        title: String,
        showsLabel: Bool,
        isEnabled: Bool,
        tooltip: String,
        emphasis: UXActionEmphasis = .standard,
        badgeCount: Int? = nil,
        badgeAccessibility: String? = nil,
        labelHorizontalPadding: CGFloat = UXActionBarMetrics.regular.labelPadding,
        isPreviewHovered: Bool = false,
        perform: @escaping () -> Void
    ) {
        self.action = action
        self.title = title
        self.showsLabel = showsLabel
        self.tooltip = tooltip
        self.emphasis = emphasis
        self.badgeCount = badgeCount
        self.badgeAccessibility = badgeAccessibility
        self.labelHorizontalPadding = labelHorizontalPadding
        self.isPreviewHovered = isPreviewHovered
        self.perform = perform
        self.isEnabledOverride = isEnabled
    }

    private var effectiveHover: Bool {
        (isHovered || isPreviewHovered) && isEnabledOverride
    }

    private var accessibilityTitle: String {
        guard let badgeAccessibility else { return title }
        return "\(title), \(badgeAccessibility)"
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
                if let badgeCount {
                    Text(badgeCount > 99 ? "99+" : "\(badgeCount)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 13, minHeight: 13)
                        .background {
                            Capsule().fill(theme.warning)
                        }
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, showsLabel ? labelHorizontalPadding : 0)
            .frame(
                minWidth: showsLabel ? nil : (badgeCount == nil ? 24 : 36),
                minHeight: 26,
                maxHeight: 26
            )
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
        .accessibilityLabel(accessibilityTitle)
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

/// The chips in the scene meta line. Duration and takes open the Scene tab;
/// the research chip opens the Investigación tab. This is the single place the
/// scene's pending-claim count is shown (the former amber badge is folded into
/// the chip style here).
struct UXSceneMetaChips: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(UXInspectorState.self) private var inspectorState: UXInspectorState?

    let scene: Scene

    var body: some View {
        let takes = appState.recording.takes(in: scene)
        let pendingResearch = UXResearchPending.sceneCount(
            in: appState.project.claims,
            sceneID: scene.id
        )
        if scene.targetDuration != nil || !takes.isEmpty || pendingResearch > 0 {
            HStack(spacing: 6) {
                if pendingResearch > 0 {
                    chip(
                        systemImage: "checkmark.shield",
                        text: UXSceneResearchChip.text(
                            pending: pendingResearch,
                            language: appState.currentLanguage
                        ),
                        help: String(
                            format: appState.localized("ux.chip.research.help"),
                            pendingResearch
                        ),
                        identifier: "ux-chip-research",
                        tint: theme.warning
                    ) {
                        openResearchTab()
                    }
                }
                if let target = scene.targetDuration {
                    chip(
                        systemImage: "target",
                        text: DurationEstimator.formatted(target),
                        help: String(
                            format: appState.localized("ux.chip.target.help"),
                            DurationEstimator.formatted(target)
                        ),
                        identifier: "ux-chip-target"
                    ) {
                        openSceneTab()
                    }
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
                    ) {
                        openSceneTab()
                    }
                }
            }
        }
    }

    private func chip(
        systemImage: String,
        text: String,
        help: String,
        identifier: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        UXMetaChip(
            systemImage: systemImage,
            text: text,
            help: help,
            identifier: identifier,
            tint: tint,
            action: action
        )
    }

    private func openSceneTab() {
        appState.settings.editorPreferences.showAIReviewPanel = true
        inspectorState?.select(.scene)
    }

    private func openResearchTab() {
        appState.settings.editorPreferences.showAIReviewPanel = true
        inspectorState?.select(.research)
    }
}

/// Pure text for the scene research chip, exposed for localization tests.
enum UXSceneResearchChip {
    static func text(pending: Int, language: AppLanguage) -> String {
        L10n.plural("ux.chip.research", count: pending, language: language)
    }
}

private struct UXMetaChip: View {
    @Environment(\.frameTheme) private var theme
    let systemImage: String
    let text: String
    let help: String
    let identifier: String
    var tint: Color?
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
            .foregroundStyle(tint ?? (isHovered ? theme.accentText : theme.secondaryText))
            .background {
                Capsule()
                    .fill(background)
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

    private var background: Color {
        if let tint {
            return tint.opacity(isHovered ? 0.24 : 0.15)
        }
        return isHovered ? theme.accentSoft : theme.hover
    }
}
