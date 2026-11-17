import Observation
import SwiftUI

// MARK: - Tabs

/// The inspector's tabs. Wave-3 features add a case plus a definition in
/// ``UXInspectorRegistry``; the shell itself never needs to change.
enum UXInspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case ai
    case rhythm
    case scene
    case research
    case production

    var id: String { rawValue }
}

struct UXInspectorTabDefinition: Identifiable {
    let tab: UXInspectorTab
    let titleKey: String
    let systemImage: String
    let content: @MainActor () -> AnyView

    var id: UXInspectorTab { tab }
}

@MainActor
enum UXInspectorRegistry {
    /// Ordered tab definitions. Add new tabs here (and their enum case) instead
    /// of editing the panel shell.
    static let definitions: [UXInspectorTabDefinition] = [
        UXInspectorTabDefinition(
            tab: .ai,
            titleKey: "ux.inspector.tab.ai",
            systemImage: "sparkles",
            content: { AnyView(AIReviewContent()) }
        ),
        UXInspectorTabDefinition(
            tab: .rhythm,
            titleKey: "ux.inspector.tab.rhythm",
            systemImage: "waveform.path",
            content: { AnyView(UXInspectorRhythmTab()) }
        ),
        UXInspectorTabDefinition(
            tab: .scene,
            titleKey: "ux.inspector.tab.scene",
            systemImage: "film.stack",
            content: { AnyView(UXInspectorSceneTab()) }
        ),
        UXInspectorTabDefinition(
            tab: .research,
            titleKey: "ux.inspector.tab.research",
            systemImage: "checkmark.shield",
            content: { AnyView(UXInspectorResearchTab()) }
        ),
        UXInspectorTabDefinition(
            tab: .production,
            titleKey: "ux.inspector.tab.production",
            systemImage: "checklist",
            content: { AnyView(UXInspectorProductionTab()) }
        )
    ]

    static func definition(for tab: UXInspectorTab) -> UXInspectorTabDefinition? {
        definitions.first { $0.tab == tab }
    }
}

// MARK: - Per-window selection

/// Remembers which inspector tab the window is showing.
///
/// Each `AppShellView` owns one instance; it saves to `AppEnvironment.defaults`
/// (the isolated suite during tests) so reopening the app returns to the last
/// tab.
@Observable
final class UXInspectorState {
    static let storageKey = "FrameScript.ux.inspector.selectedTab"

    private let defaults: UserDefaults
    private let key: String
    private(set) var selectedTab: UXInspectorTab

    init(defaults: UserDefaults = AppEnvironment.defaults, key: String = storageKey) {
        let resolved = AppEnvironment.isolatedDefaults(defaults)
        self.defaults = resolved
        self.key = key
        let stored = resolved.string(forKey: key)
        self.selectedTab = stored.flatMap(UXInspectorTab.init(rawValue:)) ?? .ai
    }

    func select(_ tab: UXInspectorTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        defaults.set(tab.rawValue, forKey: key)
    }
}

// MARK: - Tab layout

/// Pure tab-bar layout: which tabs share a row and which one is selected.
/// Rows group the scene tools (IA, Ritmo, Escena) and the project tools
/// (Investigación, Producción).
enum UXInspectorTabLayout {
    static let rows: [[UXInspectorTab]] = [
        [.ai, .rhythm, .scene],
        [.research, .production]
    ]

    static func isSelected(_ tab: UXInspectorTab, in state: UXInspectorState) -> Bool {
        state.selectedTab == tab
    }

    /// The tabs that render as selected. Always exactly one.
    static func selectedTabs(in state: UXInspectorState) -> [UXInspectorTab] {
        rows.flatMap { $0 }.filter { isSelected($0, in: state) }
    }
}

// MARK: - Shell

/// The right inspector: one shell, three registered tabs.
struct UXInspectorPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let state: UXInspectorState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()
                .overlay(theme.divider)
            content
        }
        .background(theme.background)
        .environment(state)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appState.localized("ux.inspector.title"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(appState.localized("ux.inspector.title"))
                .font(.system(size: 14, weight: .semibold))
                .layoutProbe("inspector.leading")
            Spacer(minLength: 0)
            Button {
                appState.settings.editorPreferences.showAIReviewPanel = false
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("ux.inspector.close"))
            .accessibilityLabel(appState.localized("ux.inspector.close"))
        }
        .padding(.horizontal, FrameLayout.inspectorInset)
        .frame(height: 46)
    }

    private var tabBar: some View {
        // The column is a fixed 292 pt, where five labelled tabs never fit one
        // row. The rows are fixed (scene tools, then project tools) instead of
        // a `ViewThatFits`: the unused one-row candidate kept a second set of
        // tab buttons alive. Both rows span the same width and split it
        // evenly, so their outer edges line up.
        VStack(spacing: FrameSpacing.xxs) {
            ForEach(Array(UXInspectorTabLayout.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: FrameSpacing.xxs) {
                    ForEach(row, id: \.self) { tab in
                        if let definition = UXInspectorRegistry.definition(for: tab) {
                            tabButton(definition)
                        }
                    }
                }
                .layoutProbe("inspector.tabRow")
            }
        }
        .padding(FrameSpacing.xxs + 1)
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.container, style: .continuous)
                .fill(theme.sidebar.opacity(0.82))
        }
        .layoutProbe("inspector.leading")
        .padding(.horizontal, FrameLayout.inspectorInset)
        .padding(.bottom, FrameSpacing.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ux-inspector-tabbar")
    }

    private func tabButton(_ definition: UXInspectorTabDefinition) -> some View {
        let isSelected = UXInspectorTabLayout.isSelected(definition.tab, in: state)
        return Button {
            state.select(definition.tab)
        } label: {
            HStack(spacing: FrameSpacing.xs) {
                Image(systemName: definition.systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(appState.localized(definition.titleKey))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, FrameSpacing.xxs)
            .frame(maxWidth: .infinity)
            .frame(height: FrameControlHeight.compact)
            .foregroundStyle(isSelected ? theme.accentText : theme.secondaryText)
            .background {
                RoundedRectangle(cornerRadius: FrameRadius.control, style: .continuous)
                    .fill(isSelected ? theme.accentSoft : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: FrameRadius.control, style: .continuous))
        }
        .buttonStyle(.cursorPlain)
        // One element per tab with an explicit state, like the mode switcher:
        // VoiceOver reads exactly one "selected" tab.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(appState.localized(definition.titleKey))
        .accessibilityValue(appState.localized(isSelected ? "accessibility.selected" : "accessibility.notSelected"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("ux-inspector-tab-\(definition.tab.rawValue)")
    }

    @ViewBuilder
    private var content: some View {
        if let definition = UXInspectorRegistry.definition(for: state.selectedTab) {
            definition.content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            Color.clear
        }
    }
}

// MARK: - Rhythm tab

struct UXInspectorRhythmTab: View {
    @Environment(\.frameTheme) private var theme

    var body: some View {
        ScrollView {
            RhythmReviewSection()
                .padding(FrameLayout.inspectorInset)
        }
        .background(theme.background)
    }
}

// MARK: - Scene tab

struct UXInspectorSceneTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(UXInspectorState.self) private var inspectorState: UXInspectorState?

    var body: some View {
        ScrollView {
            if let scene = appState.activeEditorScene {
                VStack(alignment: .leading, spacing: 12) {
                    durationCard(scene)
                    takesCard(scene)
                    obsCard
                    quickActions(scene)
                }
                .padding(FrameLayout.inspectorInset)
            } else {
                Text(appState.localized("ux.scene.noScene"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(FrameLayout.inspectorInset)
            }
        }
        .background(theme.background)
    }

    private func durationCard(_ scene: Scene) -> some View {
        SceneDurationDetails(scene: scene)
            .padding(FrameLayout.cardPadding)
            .background(cardBackground)
    }

    private func takesCard(_ scene: Scene) -> some View {
        let takes = appState.recording.takes(in: scene)
        let latest = takes.first
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(appState.localized("ux.scene.section.takes"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Text(L10n.plural("ux.chip.takes", count: takes.count, language: appState.currentLanguage))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
            }

            if let latest {
                let rating = TakeRatingPresentation.label(
                    latest.take.rating,
                    language: appState.currentLanguage
                )
                Text(String(
                    format: appState.localized("ux.scene.latestTake"),
                    latest.take.number,
                    DurationEstimator.formatted(latest.take.duration),
                    rating
                ))
                .font(.system(size: 11))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(appState.localized("ux.scene.noTakes"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(FrameLayout.cardPadding)
        .background(cardBackground)
    }

    private var obsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.localized("ux.scene.section.obs"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: 6) {
                Circle()
                    .fill(obsColor)
                    .frame(width: 7, height: 7)
                Text(obsStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
            }
        }
        .padding(FrameLayout.cardPadding)
        .background(cardBackground)
    }

    private func quickActions(_ scene: Scene) -> some View {
        let model = UXActionBarModel(appState: appState)
        let actions: [UXEditorAction] = [.recordTake, .teleprompter]
        return VStack(alignment: .leading, spacing: 8) {
            Text(appState.localized("ux.scene.quickActions"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)

            HStack(spacing: 6) {
                ForEach(actions) { action in
                    UXActionButton(
                        action: action,
                        title: appState.localized(action.titleKey),
                        showsLabel: true,
                        isEnabled: model.isEnabled(action),
                        tooltip: UXActionTooltip.text(
                            title: appState.localized(action.titleKey),
                            command: action.shortcutCommand,
                            settings: appState.settings
                        ),
                        emphasis: action == .recordTake ? .filled : .standard
                    ) {
                        UXEditorActionPerformer.perform(
                            action,
                            sceneID: scene.id,
                            appState: appState,
                            inspectorState: inspectorState
                        )
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(FrameLayout.cardPadding)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.cardBackground)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            }
    }

    private var obsColor: Color {
        switch appState.recording.connectionState {
        case .connected: theme.success
        case .connecting: theme.warning
        case .failed: theme.destructive
        case .disconnected: theme.tertiaryText
        }
    }

    private var obsStatusText: String {
        switch appState.recording.connectionState {
        case .connected: appState.localized("recording.obs.connected")
        case .connecting: appState.localized("recording.obs.connecting")
        case .failed: appState.localized("recording.obs.failed")
        case .disconnected: appState.localized("recording.obs.disconnected")
        }
    }
}
