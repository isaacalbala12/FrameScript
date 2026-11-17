import FrameScriptCore
import SwiftUI

/// Fixed dimensions keep the panel usable at the 980×712 minimum window and
/// make the offscreen layout invariants in `ProductionPanelSnapshotTests` explicit.
enum ProductionPanelMetrics {
    static let width: CGFloat = 780
    static let height: CGFloat = 640
    static let headerHeight: CGFloat = 92
    static let filterHeight: CGFloat = 88
    static let footerHeight: CGFloat = 58
    static var listHeight: CGFloat {
        height - headerHeight - filterHeight - footerHeight - 3
    }
}

struct ProductionPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKinds: Set<ProductionItemKind> = []
    @State private var selectedSceneID: UUID?
    @State private var showsDone = true
    @State private var grouping: ProductionGrouping = .scene
    @State private var newTaskText = ""
    @State private var newTaskKind: ChecklistTaskKind = .other
    @State private var newTaskSceneID: UUID?
    @State private var editingTask: ChecklistTask?
    @State private var navigationMessage: String?
    @State private var showsExplainer: Bool

    private let explainerStore: ProductionExplainerStore

    init(
        initialGrouping: ProductionGrouping = .scene,
        explainerStore: ProductionExplainerStore = ProductionExplainerStore()
    ) {
        _grouping = State(initialValue: initialGrouping)
        self.explainerStore = explainerStore
        _showsExplainer = State(initialValue: !explainerStore.isDismissed)
    }

    private var snapshot: ProductionSnapshot {
        ProductionChecklistCenter.shared.snapshot
    }

    private var scenes: [Scene] {
        appState.project.scenes.sortedByOrder
    }

    /// Items in the current scene/done scope, before the kind filter. Chip
    /// counts stay honest when a scene filter is active.
    private var scopedItems: [ProductionItem] {
        ProductionFilter(sceneID: selectedSceneID, showsDone: showsDone)
            .apply(to: snapshot.items)
    }

    private var scopedSummary: ProductionSummary {
        ProductionSummary(items: scopedItems)
    }

    private var filter: ProductionFilter {
        ProductionFilter(
            kinds: selectedKinds,
            sceneID: selectedSceneID,
            showsDone: showsDone
        )
    }

    private var sections: [ProductionSection] {
        ProductionGrouper.sections(
            from: filter.apply(to: snapshot.items),
            grouping: grouping
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: ProductionPanelMetrics.headerHeight)
            Divider()
                .overlay(theme.divider)
            if showsExplainer {
                explainer
                Divider()
                    .overlay(theme.divider)
            }
            filterBar
                .frame(height: ProductionPanelMetrics.filterHeight)
            Divider()
                .overlay(theme.divider)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
                .overlay(theme.divider)
            footer
                .frame(height: ProductionPanelMetrics.footerHeight)
        }
        .frame(width: ProductionPanelMetrics.width, height: ProductionPanelMetrics.height)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("production-panel")
        .onAppear {
            appState.refreshProductionChecklist()
        }
        .onChange(of: scenes.map(\.id)) { _, ids in
            if let selectedSceneID, !ids.contains(selectedSceneID) {
                self.selectedSceneID = nil
            }
        }
        .sheet(item: $editingTask) { task in
            ProductionTaskEditorView(task: task)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized("production.title"))
                    .font(.system(size: 21, weight: .semibold))
                Text(appState.localized("production.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(scopedSummary.totalPending)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(scopedSummary.totalPending > 0 ? theme.primaryText : theme.success)
                Text(appState.localized("production.count.label"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            Button {
                showsExplainer.toggle()
                if !showsExplainer { explainerStore.dismiss() }
            } label: {
                Image(systemName: showsExplainer ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("production.explainer.help"))
            .accessibilityLabel(appState.localized("production.explainer.help"))
            .accessibilityIdentifier("production-explainer-toggle")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("production.panel.close"))
            .accessibilityLabel(appState.localized("production.panel.close"))
        }
        .padding(.horizontal, FrameSpacing.xl)
        .padding(.top, FrameSpacing.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Explainer

    private var explainer: some View {
        HStack(alignment: .top, spacing: FrameSpacing.m) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.accentText)
            Text(appState.localized("production.explainer.body"))
                .font(.system(size: 12))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: FrameSpacing.s)
            Button(appState.localized("production.explainer.dismiss")) {
                explainerStore.dismiss()
                showsExplainer = false
            }
            .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
            .accessibilityIdentifier("production-explainer-dismiss")
        }
        .padding(.horizontal, FrameSpacing.xl)
        .padding(.vertical, FrameSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.accentSoft)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("production-explainer")
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    kindChip(nil)
                    ForEach(ProductionItemKind.allCases) { kind in
                        kindChip(kind)
                    }
                }
                .padding(.horizontal, FrameSpacing.xl)
            }

            HStack(spacing: FrameSpacing.m) {
                Picker("", selection: $selectedSceneID) {
                    Text(appState.localized("production.filter.allScenes"))
                        .tag(UUID?.none)
                    ForEach(scenes) { scene in
                        Text(sceneMenuTitle(scene))
                            .tag(Optional(scene.id))
                    }
                }
                .labelsHidden()
                // Leading-aligned so the menu starts on the panel's 24 pt edge
                // with the title and the kind chips (was centered in 190 pt).
                .frame(width: 190, alignment: .leading)

                HStack(spacing: FrameSpacing.s) {
                    Text(appState.localized("production.group.label"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    ProductionGroupingControl(
                        grouping: $grouping,
                        sceneTitle: appState.localized("production.group.scene"),
                        kindTitle: appState.localized("production.group.kind")
                    )
                }
                .help(appState.localized("production.group.help"))

                Toggle(appState.localized("production.filter.showDone"), isOn: $showsDone)
                    .toggleStyle(FrameCheckboxToggleStyle())
                    .font(.system(size: 11))
                    .help(appState.localized("production.filter.showDone.help"))

                Spacer(minLength: 4)

                if let navigationMessage {
                    Text(navigationMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.warning)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 230, alignment: .trailing)
                        .accessibilityIdentifier("production-navigation-message")
                }
            }
            .padding(.horizontal, FrameSpacing.xl)
        }
        .padding(.vertical, FrameSpacing.m)
    }

    private func kindChip(_ kind: ProductionItemKind?) -> some View {
        let isSelected = kind.map { selectedKinds.contains($0) } ?? selectedKinds.isEmpty
        let count = kind.map { scopedSummary.pendingCount(for: $0) } ?? scopedSummary.totalPending
        let label = kind.map { kindLabel($0) } ?? appState.localized("production.filter.allKinds")

        return Button {
            if let kind {
                if selectedKinds.contains(kind) {
                    selectedKinds.remove(kind)
                } else {
                    selectedKinds.insert(kind)
                }
            } else {
                selectedKinds.removeAll()
            }
            navigationMessage = nil
        } label: {
            HStack(spacing: 5) {
                if let kind {
                    Image(systemName: kindIcon(kind))
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? theme.primaryText.opacity(0.72) : theme.tertiaryText)
            }
            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background {
                Capsule().fill(isSelected ? theme.accentSoft : theme.hover)
            }
            .overlay {
                Capsule().stroke(
                    isSelected ? theme.accent.color.opacity(0.55) : Color.clear,
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.cursorPlain)
        .help(appState.localized(ProductionExplanation.tooltipKey(for: kind)))
        .accessibilityIdentifier("production-chip-\(kind?.rawValue ?? "all")")
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, FrameSpacing.xl)
                .padding(.vertical, FrameSpacing.l)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(theme.success)
            Text(appState.localized("production.empty.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(appState.localized("production.empty.message"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func sectionView(_ section: ProductionSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if let kind = section.kind {
                    Image(systemName: kindIcon(kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(kindColor(kind))
                    Text(kindLabel(kind))
                        .font(.system(size: 12, weight: .semibold))
                } else if section.sceneID != nil {
                    Text(sectionTitle(section))
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text(appState.localized("production.section.project"))
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer()

                Text("\(section.items.filter { !$0.isDone }.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
            }

            ForEach(section.items) { item in
                ProductionRow(
                    item: item,
                    title: title(for: item),
                    reason: reasonLabel(for: item),
                    explanation: ProductionExplanation.explanation(
                        for: item,
                        language: appState.currentLanguage,
                        recordShortcut: appState.settings.activeShortcut(for: .recordTake)?.display
                    ),
                    actionTitle: ProductionExplanation.actionKey(for: item)
                        .map { appState.localized($0) },
                    detail: detail(for: item),
                    isManual: item.reason == .manualTask,
                    kindIcon: kindIcon(item.kind),
                    kindColor: kindColor(item.kind),
                    onNavigate: { navigate(to: item) },
                    onToggleDone: { toggleDone(item) },
                    onEdit: { edit(item) },
                    onDelete: { delete(item) }
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            TextField(appState.localized("production.task.placeholder"), text: $newTaskText)
                .textFieldStyle(QuietTextFieldStyle())
                .onSubmit(addTask)
                .accessibilityIdentifier("production-task-field")

            Picker("", selection: $newTaskKind) {
                ForEach(ChecklistTaskKind.allCases) { kind in
                    Text(taskKindLabel(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 126)

            Picker("", selection: $newTaskSceneID) {
                Text(appState.localized("production.task.project"))
                    .tag(UUID?.none)
                ForEach(scenes) { scene in
                    Text(sceneMenuTitle(scene))
                        .tag(Optional(scene.id))
                }
            }
            .labelsHidden()
            .frame(width: 160)

            Button(appState.localized("production.task.add"), action: addTask)
                .buttonStyle(.framePrimary)
                .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("production-task-add")
        }
        .padding(.horizontal, FrameSpacing.xl)
    }

    // MARK: - Actions

    private func addTask() {
        guard appState.addProductionTask(
            text: newTaskText,
            kind: newTaskKind,
            sceneID: newTaskSceneID
        ) else { return }
        newTaskText = ""
    }

    private func toggleDone(_ item: ProductionItem) {
        guard case let .manualTask(taskID) = item.target else { return }
        appState.toggleProductionTask(id: taskID)
    }

    private func edit(_ item: ProductionItem) {
        guard case let .manualTask(taskID) = item.target,
              let task = appState.project.checklistTasks.first(where: { $0.id == taskID })
        else { return }
        editingTask = task
    }

    private func delete(_ item: ProductionItem) {
        guard case let .manualTask(taskID) = item.target else { return }
        appState.deleteProductionTask(id: taskID)
    }

    private func navigate(to item: ProductionItem) {
        if appState.navigateToProductionTarget(item.target) {
            navigationMessage = nil
            dismiss()
            return
        }

        switch item.target {
        case .publishing:
            navigationMessage = appState.localized("production.nav.unavailable.publishing")
        case .research:
            navigationMessage = appState.localized("production.nav.unavailable.research")
        default:
            navigationMessage = appState.localized("production.nav.unavailable.generic")
        }
    }

    // MARK: - Presentation helpers

    private func title(for item: ProductionItem) -> String {
        ProductionExplanation.title(for: item, language: appState.currentLanguage)
    }

    private func reasonLabel(for item: ProductionItem) -> String {
        appState.localized("production.reason.\(item.reason.rawValue)")
    }

    private func detail(for item: ProductionItem) -> String? {
        var parts: [String] = []
        if grouping == .kind, item.reason != .sceneNeedsTake, let scene = sceneLabel(for: item) {
            parts.append(scene)
        }
        if let language = languageLabel(for: item) {
            parts.append(language)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sceneLabel(for item: ProductionItem) -> String? {
        guard item.sceneID != nil else { return nil }
        if !item.sceneTitle.isEmpty { return item.sceneTitle }
        if let order = item.sceneOrder {
            return String(format: appState.localized("production.item.scene"), max(0, order) + 1)
        }
        return appState.localized("production.item.sceneFallback")
    }

    private func languageLabel(for item: ProductionItem) -> String? {
        guard let code = item.languageCode else { return nil }
        switch ProductionLanguage.normalized(code) {
        case "": return appState.localized("production.language.original")
        case "es": return appState.localized("production.language.es")
        case "en": return appState.localized("production.language.en")
        case "ru": return appState.localized("production.language.ru")
        default: return ProductionLanguage.normalized(code).uppercased()
        }
    }

    private func sectionTitle(_ section: ProductionSection) -> String {
        if !section.sceneTitle.isEmpty { return section.sceneTitle }
        if let order = section.sceneOrder {
            return String(format: appState.localized("production.item.scene"), max(0, order) + 1)
        }
        return appState.localized("production.item.sceneFallback")
    }

    private func sceneMenuTitle(_ scene: Scene) -> String {
        let number = max(0, scene.order) + 1
        let title = scene.title.isEmpty
            ? String(format: appState.localized("production.item.scene"), number)
            : scene.title
        return "\(String(format: "%02d", number)) · \(title)"
    }

    private func kindLabel(_ kind: ProductionItemKind) -> String {
        appState.localized("production.kind.\(kind.rawValue)")
    }

    private func taskKindLabel(_ kind: ChecklistTaskKind) -> String {
        kindLabel(kind.productionKind)
    }

    private func kindIcon(_ kind: ProductionItemKind) -> String {
        switch kind {
        case .record: "record.circle"
        case .acquire: "film.stack"
        case .edit: "scissors"
        case .research: "magnifyingglass"
        case .publish: "paperplane"
        case .other: "checklist"
        }
    }

    private func kindColor(_ kind: ProductionItemKind) -> Color {
        switch kind {
        case .record: theme.destructive
        case .acquire: theme.bRollMarker
        case .edit: theme.editingMarker
        case .research: theme.accent.color
        case .publish: theme.success
        case .other: theme.secondaryText
        }
    }
}

// MARK: - Row

private struct ProductionRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let item: ProductionItem
    let title: String
    let reason: String
    let explanation: String
    let actionTitle: String?
    let detail: String?
    let isManual: Bool
    let kindIcon: String
    let kindColor: Color

    /// 4.5:1 at 10 pt on every surface; the icon keeps the original kind tint.
    private var reasonColor: Color {
        theme.ensuredText(kindColor)
    }
    let onNavigate: () -> Void
    let onToggleDone: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(kindColor.opacity(0.14))
                    .frame(width: 24, height: 24)
                Image(systemName: kindIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kindColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: item.isDone ? .regular : .medium))
                    .strikethrough(item.isDone, color: theme.tertiaryText)
                    .foregroundStyle(item.isDone ? theme.secondaryText : theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    originTag
                    Text(reason)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(reasonColor)
                    if let detail, !detail.isEmpty {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiaryText)
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            if isManual {
                Button(action: onToggleDone) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.isDone ? theme.success : theme.tertiaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.cursorPlain)
                .help(
                    item.isDone
                        ? appState.localized("production.task.markPending")
                        : appState.localized("production.task.markDone")
                )
                .accessibilityLabel(
                    item.isDone
                        ? appState.localized("production.task.markPending")
                        : appState.localized("production.task.markDone")
                )

                Menu {
                    Button(onEditLabel, action: onEdit)
                    Button(
                        item.isDone
                            ? appState.localized("production.task.markPending")
                            : appState.localized("production.task.markDone"),
                        action: onToggleDone
                    )
                    Divider()
                    Button(appState.localized("production.task.delete"), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .foregroundStyle(theme.secondaryText)
                .accessibilityLabel(appState.localized("production.task.more"))
            } else if let actionTitle {
                Button(actionTitle, action: onNavigate)
                    .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
                    .accessibilityIdentifier("production-action-\(item.id)")
            }
        }
        .padding(.horizontal, FrameLayout.cardPadding)
        .padding(.vertical, FrameSpacing.s + 1)
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.card, style: .continuous)
                .fill(theme.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: FrameRadius.card, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isManual {
                onEdit()
            } else {
                onNavigate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(reason)")
        .accessibilityHint(appState.localized("production.item.openHelp"))
        .accessibilityAction {
            if isManual {
                onEdit()
            } else {
                onNavigate()
            }
        }
        .accessibilityIdentifier("production-item-\(item.id)")
    }

    /// «automática» for rows the app derives, «manual» for the writer's own.
    private var originTag: some View {
        Text(appState.localized(isManual ? "production.tag.manual" : "production.tag.auto"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isManual ? theme.secondaryText : theme.accentText)
            .padding(.horizontal, 6)
            .frame(height: 15)
            .background {
                Capsule().fill(isManual ? theme.hover : theme.accentSoft)
            }
            .accessibilityIdentifier("production-tag-\(item.id)")
    }

    private var onEditLabel: String {
        appState.localized("production.task.edit")
    }
}

// MARK: - Controls

/// Two-option control in the theme's accent instead of the system-blue
/// segmented picker.
struct ProductionGroupingControl: View {
    @Environment(\.frameTheme) private var theme
    @Binding var grouping: ProductionGrouping
    let sceneTitle: String
    let kindTitle: String

    var body: some View {
        HStack(spacing: FrameSpacing.xxs) {
            segment(.scene, title: sceneTitle)
            segment(.kind, title: kindTitle)
        }
        .padding(FrameSpacing.xxs)
        .background {
            RoundedRectangle(cornerRadius: FrameRadius.control + 2, style: .continuous)
                .fill(theme.hover)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("production-grouping")
    }

    private func segment(_ value: ProductionGrouping, title: String) -> some View {
        let isSelected = grouping == value
        return Button {
            grouping = value
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? FrameTheme.textColor(onFill: theme.accentStrong) : theme.secondaryText)
                .padding(.horizontal, FrameSpacing.m)
                .frame(height: 22)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: FrameRadius.control, style: .continuous)
                            .fill(theme.accentStrong)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.cursorPlain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("production-group-\(value.rawValue)")
    }
}

/// Checkbox drawn in the theme accent (the system one is always system blue).
struct FrameCheckboxToggleStyle: ToggleStyle {
    @Environment(\.frameTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: FrameSpacing.s - 2) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(configuration.isOn ? theme.accentStrong : theme.tertiaryText)
                configuration.label
                    .foregroundStyle(theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.cursorPlain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "1" : "0")
    }
}

// MARK: - Sidebar and toolbar affordances

struct ProductionSidebarEntry: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    private var pendingCount: Int {
        ProductionChecklistCenter.shared.snapshot.summary.totalPending
    }

    var body: some View {
        Button {
            ProductionPresentation.shared.present()
        } label: {
            HStack(spacing: FrameLayout.sidebarSlotSpacing) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: FrameLayout.sidebarLeadingSlot, alignment: .leading)
                    .layoutProbe("sidebar.leading")
                Text(appState.localized("production.title"))
                    .font(.system(size: 13, weight: .medium))
                    .layoutProbe("sidebar.title")
                Spacer(minLength: 6)
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.warning)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background {
                            Capsule().fill(theme.warning.opacity(0.15))
                        }
                }
            }
            .padding(.horizontal, FrameLayout.sidebarRowInset)
            .frame(height: FrameControlHeight.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(theme.secondaryText)
        .help(appState.localized("production.sidebar.help"))
        .accessibilityLabel(
            pendingCount > 0
                ? String(format: appState.localized("production.badge.accessibility"), pendingCount)
                : appState.localized("production.sidebar.help")
        )
        .accessibilityIdentifier("production-sidebar-entry")
    }
}

struct ProductionToolbarButton: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    /// The 980–1250 pt toolbar tier packs the count tighter.
    var compact = false

    private var pendingCount: Int {
        ProductionChecklistCenter.shared.snapshot.summary.totalPending
    }

    private var badge: some View {
        Text("\(pendingCount)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(theme.background)
            .padding(.horizontal, compact ? 3 : 4)
            .frame(minWidth: compact ? 14 : 15, minHeight: compact ? 14 : 15)
            .background {
                Capsule().fill(theme.warning)
            }
            .fixedSize()
    }

    var body: some View {
        Button {
            ProductionPresentation.shared.present()
        } label: {
            // The count sits beside the glyph in both toolbar tiers; a corner
            // badge covered the checklist icon and poked above the button.
            HStack(spacing: compact ? 2 : 3) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .medium))
                if pendingCount > 0 {
                    badge
                }
            }
            .padding(.horizontal, pendingCount > 0 ? (compact ? 3 : 5) : 0)
            .frame(minWidth: FrameControlHeight.regular, minHeight: FrameControlHeight.regular)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(theme.secondaryText)
        .help(
            UXActionTooltip.text(
                title: appState.localized("production.toolbar.help"),
                command: .productionChecklist,
                settings: appState.settings
            )
        )
        .accessibilityLabel(
            pendingCount > 0
                ? String(format: appState.localized("production.badge.accessibility"), pendingCount)
                : appState.localized("production.toolbar.help")
        )
        .accessibilityIdentifier("production-toolbar-button")
    }
}

// MARK: - Task editor

struct ProductionTaskEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let task: ChecklistTask

    @State private var text: String
    @State private var kind: ChecklistTaskKind
    @State private var sceneID: UUID?

    init(task: ChecklistTask) {
        self.task = task
        _text = State(initialValue: task.text)
        _kind = State(initialValue: task.kind)
        _sceneID = State(initialValue: task.sceneID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appState.localized("production.task.edit"))
                .font(.system(size: 18, weight: .semibold))

            QuietField(appState.localized("production.task.note")) {
                MultilineField(
                    placeholder: appState.localized("production.task.notePlaceholder"),
                    text: $text,
                    minHeight: 80
                )
                .frame(height: 110)
            }

            QuietField(appState.localized("production.task.kind")) {
                Picker("", selection: $kind) {
                    ForEach(ChecklistTaskKind.allCases) { option in
                        Text(taskKindLabel(option)).tag(option)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            QuietField(appState.localized("production.task.scene")) {
                Picker("", selection: $sceneID) {
                    Text(appState.localized("production.task.project"))
                        .tag(UUID?.none)
                    ForEach(appState.project.scenes.sortedByOrder) { scene in
                        Text(sceneMenuTitle(scene))
                            .tag(Optional(scene.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(appState.localized("production.task.delete"), role: .destructive) {
                    appState.deleteProductionTask(id: task.id)
                    dismiss()
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.destructive)

                Spacer()

                Button(appState.localized("production.task.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.cursorPlain)

                Button(appState.localized("production.task.save")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("production-task-editor")
    }

    private func save() {
        guard appState.updateProductionTask(
            id: task.id,
            text: text,
            kind: kind,
            sceneID: sceneID
        ) else { return }
        dismiss()
    }

    private func taskKindLabel(_ kind: ChecklistTaskKind) -> String {
        appState.localized("production.kind.\(kind.productionKind.rawValue)")
    }

    private func sceneMenuTitle(_ scene: Scene) -> String {
        let number = max(0, scene.order) + 1
        let title = scene.title.isEmpty
            ? String(format: appState.localized("production.item.scene"), number)
            : scene.title
        return "\(String(format: "%02d", number)) · \(title)"
    }
}
