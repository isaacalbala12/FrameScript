import Observation
import SwiftUI

// MARK: - Tabs

/// The inspector's tabs. Wave-3 features add a case plus a definition in
/// ``UXInspectorRegistry``; the shell itself never needs to change.
enum UXInspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case ai
    case rhythm
    case scene

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
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(UXInspectorRegistry.definitions) { definition in
                tabButton(definition)
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.sidebar.opacity(0.82))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tabButton(_ definition: UXInspectorTabDefinition) -> some View {
        let isSelected = state.selectedTab == definition.tab
        return Button {
            state.select(definition.tab)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: definition.systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(appState.localized(definition.titleKey))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .foregroundStyle(isSelected ? theme.accentText : theme.secondaryText)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? theme.accentSoft : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.cursorPlain)
        .accessibilityLabel(appState.localized(definition.titleKey))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
                .padding(14)
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
            if let scene = appState.selectedScene {
                VStack(alignment: .leading, spacing: 12) {
                    durationCard(scene)
                    takesCard(scene)
                    obsCard
                    quickActions(scene)
                }
                .padding(14)
            } else {
                Text(appState.localized("ux.scene.noScene"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
            }
        }
        .background(theme.background)
    }

    private func durationCard(_ scene: Scene) -> some View {
        SceneDurationDetails(scene: scene)
            .padding(12)
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
        .padding(12)
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
        .padding(12)
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
        .padding(12)
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
