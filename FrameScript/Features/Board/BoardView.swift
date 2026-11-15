import AppKit
import FrameScriptCore
import SwiftUI

/// Main board window content: header, filters, kanban or list, and footer.
/// The view is intentionally self-contained so snapshot tests can render it
/// offscreen with an isolated store.
struct BoardRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable var store: BoardStore
    let catalog: BoardCatalogStore
    let plane: PlaneSettingsStore

    @State private var classificationTarget: BoardProjectSummary?
    @State private var planeTarget: BoardProjectSummary?
    @State private var statusMessage: String?
    @State private var statusTask: Task<Void, Never>?
    @State private var didRequestInitialScan = false

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            if !store.warnings.isEmpty {
                warningBar
            }
            Divider()
                .overlay(theme.divider)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
                .overlay(theme.divider)
            footer
        }
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .overlay(alignment: .bottom) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.bottom, 46)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: statusMessage)
        .sheet(item: $classificationTarget) { summary in
            BoardClassificationSheet(
                summary: summary,
                store: store,
                catalog: catalog
            )
            .environment(appState)
            .environment(\.frameTheme, theme)
        }
        .sheet(item: $planeTarget) { summary in
            BoardPlaneExportSheet(
                summary: summary,
                store: store,
                plane: plane
            )
            .environment(appState)
            .environment(\.frameTheme, theme)
        }
        .task {
            store.loadFolders()
            guard !didRequestInitialScan else { return }
            didRequestInitialScan = true
            await store.refresh(appState: appState)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized("board.windowTitle"))
                    .font(.system(size: 22, weight: .semibold))
                Text(appState.localized("board.subtitle"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            searchField

            Button(action: chooseFolders) {
                Label(appState.localized("board.addFolder"), systemImage: "folder.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .help(appState.localized("board.addFolder.help"))
            .clickableCursor()

            Button {
                Task { await store.refresh(appState: appState) }
            } label: {
                if store.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help(appState.localized("board.refresh"))
            .disabled(store.isScanning)
            .clickableCursor()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
            TextField(appState.localized("board.search"), text: $store.filter.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !store.filter.searchText.isEmpty {
                Button {
                    store.filter.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryText)
                }
                .buttonStyle(.borderless)
                .clickableCursor()
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 210, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $store.layout) {
                Label(appState.localized("board.view.kanban"), systemImage: "rectangle.split.3x1")
                    .tag(BoardLayout.kanban)
                Label(appState.localized("board.view.list"), systemImage: "list.bullet")
                    .tag(BoardLayout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            if store.layout == .list {
                Picker("", selection: $store.grouping) {
                    ForEach(BoardGrouping.allCases, id: \.rawValue) { grouping in
                        Text(groupingTitle(grouping)).tag(grouping)
                    }
                }
                .labelsHidden()
                .frame(width: 132)
            }

            statusMenu
            topicMenu
            videoTypeMenu

            Toggle(isOn: $store.filter.unfinishedOnly) {
                Text(appState.localized("board.filter.pending"))
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)

            if store.filter.isActive {
                Button(appState.localized("board.filter.clear")) {
                    store.clearFilters()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .clickableCursor()
            }

            Spacer(minLength: 0)

            Text(countText)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var statusMenu: some View {
        Menu {
            ForEach(FrameScriptDocument.ProductionStatus.allCases, id: \.rawValue) { status in
                Button {
                    store.toggle(status: status)
                } label: {
                    if store.filter.statuses.contains(status) {
                        Label(statusTitle(status), systemImage: "checkmark")
                    } else {
                        Text(statusTitle(status))
                    }
                }
            }
            if !store.filter.statuses.isEmpty {
                Divider()
                Button(appState.localized("board.filter.clearStatus")) {
                    store.filter.statuses.removeAll()
                }
            }
        } label: {
            filterLabel(
                appState.localized("board.filter.status"),
                count: store.filter.statuses.count
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var topicMenu: some View {
        Menu {
            let topics = BoardQuery.availableTopics(catalog: catalog.catalog, summaries: store.summaries)
            if topics.isEmpty {
                Text(appState.localized("board.filter.emptyCatalog"))
            } else {
                ForEach(topics, id: \.self) { topic in
                    Button {
                        store.toggle(topic: topic)
                    } label: {
                        if store.filter.topics.contains(where: { BoardCatalog.matches($0, topic) }) {
                            Label(topic, systemImage: "checkmark")
                        } else {
                            Text(topic)
                        }
                    }
                }
            }
            if !store.filter.topics.isEmpty {
                Divider()
                Button(appState.localized("board.filter.clearTopic")) {
                    store.filter.topics.removeAll()
                }
            }
        } label: {
            filterLabel(
                appState.localized("board.filter.topic"),
                count: store.filter.topics.count
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var videoTypeMenu: some View {
        Menu {
            let types = BoardQuery.availableVideoTypes(catalog: catalog.catalog, summaries: store.summaries)
            if types.isEmpty {
                Text(appState.localized("board.filter.emptyCatalog"))
            } else {
                ForEach(types, id: \.self) { type in
                    Button {
                        store.toggle(videoType: type)
                    } label: {
                        if store.filter.videoTypes.contains(where: { BoardCatalog.matches($0, type) }) {
                            Label(type, systemImage: "checkmark")
                        } else {
                            Text(type)
                        }
                    }
                }
            }
            if !store.filter.videoTypes.isEmpty {
                Divider()
                Button(appState.localized("board.filter.clearType")) {
                    store.filter.videoTypes.removeAll()
                }
            }
        } label: {
            filterLabel(
                appState.localized("board.filter.type"),
                count: store.filter.videoTypes.count
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func filterLabel(_ title: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11.5))
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.accentSoft, in: Capsule())
            }
        }
        .foregroundStyle(count > 0 ? theme.primaryText : theme.secondaryText)
    }

    private var countText: String {
        let filtered = store.groups.reduce(0) { $0 + $1.summaries.count }
        if filtered == store.summaries.count {
            return String(format: appState.localized("board.count.all"), filtered)
        }
        return String(
            format: appState.localized("board.count.filtered"),
            filtered,
            store.summaries.count
        )
    }

    // MARK: Warnings

    private var warningBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            Text(String(format: appState.localized("board.warnings.count"), store.warnings.count))
                .font(.system(size: 11.5, weight: .medium))
            Button(appState.localized("board.warnings.show")) {
                store.showsWarnings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium))
            .clickableCursor()
            .popover(isPresented: $store.showsWarnings, arrowEdge: .bottom) {
                warningPopover
            }
            Spacer()
        }
        .foregroundStyle(theme.warning)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(theme.warning.opacity(0.10))
    }

    private var warningPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.localized("board.warnings.title"))
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.warnings) { warning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warningTitle(warning.kind))
                                .font(.system(size: 12, weight: .medium))
                            Text(warning.url.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            Button(appState.localized("board.warnings.close")) {
                store.showsWarnings = false
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(14)
        .frame(width: 380)
        .environment(\.frameTheme, theme)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.isScanning && store.summaries.isEmpty {
            loadingState
        } else if store.summaries.isEmpty {
            emptyLibraryState
        } else if store.groups.isEmpty {
            emptyFilterState
        } else if store.layout == .kanban {
            kanban
        } else {
            BoardListView(
                store: store,
                catalog: catalog,
                onOpen: open,
                onEdit: { classificationTarget = $0 },
                onExport: { planeTarget = $0 },
                onStatusChange: changeStatus,
                statusTitle: statusTitle,
                onReveal: reveal
            )
        }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(appState.localized("board.scanning"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.split.3x1")
                .font(.system(size: 34))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("board.empty.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(appState.localized("board.empty.message"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            Button {
                chooseFolders()
            } label: {
                Label(appState.localized("board.addFolder"), systemImage: "folder.badge.plus")
            }
            .clickableCursor()
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var emptyFilterState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("board.noMatches.title"))
                .font(.system(size: 15, weight: .semibold))
            Text(appState.localized("board.noMatches.message"))
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Button(appState.localized("board.filter.clear")) {
                store.clearFilters()
            }
            .clickableCursor()
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var kanban: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(FrameScriptDocument.ProductionStatus.allCases, id: \.rawValue) { status in
                    BoardKanbanColumn(
                        status: status,
                        title: statusTitle(status),
                        summaries: summaries(for: status),
                        selectedID: store.selectedProjectID,
                        onSelect: { store.selectedProjectID = $0.id },
                        onOpen: open,
                        onEdit: { classificationTarget = $0 },
                        onExport: { planeTarget = $0 },
                        onReveal: reveal,
                        onDrop: { summary in changeStatus(summary, to: status) },
                        onMove: changeStatus,
                        resolve: { id in store.summary(id: id) }
                    )
                }
            }
            .padding(16)
        }
        .scrollIndicators(.visible)
    }

    private func summaries(for status: FrameScriptDocument.ProductionStatus) -> [BoardProjectSummary] {
        store.sort.sorted(
            store.summaries.filter { $0.productionStatus == status && store.filter.matches($0) }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Text(footerSummary)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()

            Spacer()

            if let date = store.lastScanDate {
                Text(String(
                    format: appState.localized("board.lastScan"),
                    date.formatted(date: .omitted, time: .shortened)
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.tertiaryText)
            }

            if let failure = store.scanFailure ?? store.folderFailure {
                Text(appState.localized(failure))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.warning)
            }

            if let summary = store.selectedSummary {
                Button(appState.localized("board.action.editClassification")) {
                    classificationTarget = summary
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .clickableCursor()

                Button(appState.localized("board.action.exportPlane")) {
                    planeTarget = summary
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .clickableCursor()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 40)
    }

    private var footerSummary: String {
        let counts = store.groups.flatMap(\.summaries)
        let pending = counts.reduce(0) { $0 + $1.pending.total }
        return String(
            format: appState.localized("board.footer.summary"),
            counts.count,
            pending
        )
    }

    // MARK: Actions

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.message = appState.localized("board.addFolder.message")
        guard panel.runModal() == .OK else { return }
        var added = false
        for url in panel.urls {
            do {
                if try store.addFolder(at: url) {
                    added = true
                }
            } catch {
                showStatus(appState.localized("board.error.folder"))
            }
        }
        guard added else {
            if store.folderFailure == nil {
                showStatus(appState.localized("board.error.folderDuplicate"))
            }
            return
        }
        Task { await store.refresh(appState: appState) }
    }

    private func open(_ summary: BoardProjectSummary) {
        if !appState.openBoardProject(summary) {
            showStatus(appState.localized("board.error.open"))
        }
    }

    private func reveal(_ summary: BoardProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([summary.fileURL])
    }

    private func changeStatus(
        _ summary: BoardProjectSummary,
        to status: FrameScriptDocument.ProductionStatus
    ) {
        guard summary.productionStatus != status else { return }
        Task {
            let outcome = await store.apply(
                BoardProjectEdit(productionStatus: status),
                to: summary,
                appState: appState
            )
            handle(outcome)
        }
    }

    private func handle(_ outcome: BoardWriteOutcome) {
        switch outcome {
        case .saved:
            showStatus(appState.localized("board.statusSaved"))
        case .conflict:
            showStatus(appState.localized("board.error.conflict"))
        case .failed:
            showStatus(appState.localized("board.error.write"))
        }
    }

    private func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        statusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    // MARK: Localized labels

    private func statusTitle(_ status: FrameScriptDocument.ProductionStatus) -> String {
        appState.localized("board.status.\(status.rawValue)")
    }

    private func groupingTitle(_ grouping: BoardGrouping) -> String {
        appState.localized("board.group.\(grouping.rawValue)")
    }

    private func warningTitle(_ kind: BoardScanWarning.Kind) -> String {
        appState.localized("board.warning.\(kind.rawValue)")
    }
}

// MARK: - Kanban

private struct BoardKanbanColumn: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let status: FrameScriptDocument.ProductionStatus
    let title: String
    let summaries: [BoardProjectSummary]
    let selectedID: String?
    let onSelect: (BoardProjectSummary) -> Void
    let onOpen: (BoardProjectSummary) -> Void
    let onEdit: (BoardProjectSummary) -> Void
    let onExport: (BoardProjectSummary) -> Void
    let onReveal: (BoardProjectSummary) -> Void
    let onDrop: (BoardProjectSummary) -> Void
    let onMove: (BoardProjectSummary, FrameScriptDocument.ProductionStatus) -> Void
    let resolve: (String) -> BoardProjectSummary?

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(BoardStatusStyle.color(status, theme: theme))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(summaries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 2)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        BoardProjectCard(
                            summary: summary,
                            isSelected: selectedID == summary.id,
                            onSelect: { onSelect(summary) },
                            onOpen: { onOpen(summary) },
                            onEdit: { onEdit(summary) },
                            onExport: { onExport(summary) },
                            onReveal: { onReveal(summary) },
                            onMove: { target in onMove(summary, target) },
                            statusTitle: { appState.localized("board.status.\($0.rawValue)") }
                        )
                        .draggable(summary.id)
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.hidden)

            if summaries.isEmpty {
                Text(appState.localized("board.column.empty"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.tertiaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.divider, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
            }
        }
        .padding(10)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isTargeted ? theme.accentSoft.opacity(0.55) : theme.sidebarBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isTargeted ? theme.focus : theme.divider, lineWidth: 1)
                )
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first,
                  let summary = resolve(id) else {
                return false
            }
            onDrop(summary)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct BoardProjectCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let summary: BoardProjectSummary
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onReveal: () -> Void
    let onMove: (FrameScriptDocument.ProductionStatus) -> Void
    let statusTitle: (FrameScriptDocument.ProductionStatus) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(summary.title.isEmpty ? appState.localized("project.untitled") : summary.title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !summary.topic.isEmpty || !summary.videoType.isEmpty {
                HStack(spacing: 4) {
                    if !summary.topic.isEmpty {
                        BoardChip(text: summary.topic, tint: theme.bRollMarker)
                    }
                    if !summary.videoType.isEmpty {
                        BoardChip(text: summary.videoType, tint: theme.editingMarker)
                    }
                }
            }

            HStack(spacing: 8) {
                Label(BoardFormatting.duration(summary.duration), systemImage: "clock")
                    .help(appState.localized("board.duration.\(summary.duration.kind.rawValue)"))
                if !summary.pending.isEmpty {
                    Label("\(summary.pending.total)", systemImage: "checklist")
                        .help(appState.localized("board.card.pendingHelp"))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .monospacedDigit()

            if !summary.pending.isEmpty {
                BoardPendingKindRow(counts: summary.pending)
            }

            if summary.targetDate != nil || summary.publishDate != nil {
                HStack(spacing: 9) {
                    if let date = summary.targetDate {
                        Label {
                            Text(BoardFormatting.shortDate(date))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        .foregroundStyle(BoardFormatting.isOverdue(summary) ? theme.warning : theme.secondaryText)
                        .help(appState.localized("board.classification.targetDate"))
                    }
                    if let date = summary.publishDate {
                        Label {
                            Text(BoardFormatting.shortDate(date))
                                .monospacedDigit()
                        } icon: {
                            Image(systemName: "paperplane")
                        }
                        .foregroundStyle(theme.secondaryText)
                        .help(appState.localized("board.classification.publishDate"))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9.5))
            }
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? theme.focus : theme.divider, lineWidth: isSelected ? 1.5 : 1)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
        .contextMenu {
            BoardProjectMenu(
                summary: summary,
                onOpen: onOpen,
                onEdit: onEdit,
                onExport: onExport,
                onReveal: onReveal,
                onMove: onMove,
                statusTitle: statusTitle
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary.title), \(statusTitle(summary.productionStatus))")
    }
}

// MARK: - Shared row bits

struct BoardPendingKindRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let counts: BoardPendingCounts

    var body: some View {
        HStack(spacing: 7) {
            ForEach(counts.activeKinds, id: \.rawValue) { kind in
                HStack(spacing: 2) {
                    Image(systemName: BoardPendingKindStyle.icon(kind))
                        .font(.system(size: 9))
                    Text("\(counts.count(for: kind))")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.secondaryText)
                .help(appState.localized("board.kind.\(kind.rawValue)"))
            }
            Spacer(minLength: 0)
        }
    }
}

struct BoardChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

struct BoardProjectMenu: View {
    @Environment(AppState.self) private var appState
    let summary: BoardProjectSummary
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onReveal: () -> Void
    let onMove: (FrameScriptDocument.ProductionStatus) -> Void
    let statusTitle: (FrameScriptDocument.ProductionStatus) -> String

    var body: some View {
        Button(appState.localized("board.action.open"), action: onOpen)
        Button(appState.localized("board.action.editClassification"), action: onEdit)
        Button(appState.localized("board.action.exportPlane"), action: onExport)
        if let next = BoardProductionStatus.next(after: summary.productionStatus) {
            Button(String(
                format: appState.localized("board.action.advance"),
                statusTitle(next)
            )) {
                onMove(next)
            }
        }
        Divider()
        Menu(appState.localized("board.action.moveTo")) {
            ForEach(FrameScriptDocument.ProductionStatus.allCases, id: \.rawValue) { status in
                Button {
                    onMove(status)
                } label: {
                    if summary.productionStatus == status {
                        Label(statusTitle(status), systemImage: "checkmark")
                    } else {
                        Text(statusTitle(status))
                    }
                }
                .disabled(summary.productionStatus == status)
            }
        }
        Divider()
        Button(appState.localized("board.action.reveal"), action: onReveal)
    }
}

enum BoardStatusStyle {
    static func color(_ status: FrameScriptDocument.ProductionStatus, theme: FrameTheme) -> Color {
        switch status {
        case .idea: theme.tertiaryText
        case .outline: theme.bRollMarker
        case .script: theme.accent.color
        case .recorded: theme.warning
        case .edited: theme.editingMarker
        case .published: theme.success
        }
    }
}

enum BoardPendingKindStyle {
    static func icon(_ kind: PlaneTaskKind) -> String {
        switch kind {
        case .grabar: "video.fill"
        case .conseguirBroll: "photo.on.rectangle"
        case .editar: "scissors"
        case .investigar: "magnifyingglass"
        case .manual: "checklist"
        }
    }
}

enum BoardFormatting {
    static func duration(_ duration: BoardDuration) -> String {
        DurationEstimator.formatted(duration.seconds)
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func isOverdue(_ summary: BoardProjectSummary, now: Date = Date()) -> Bool {
        guard summary.productionStatus != .published,
              let target = summary.targetDate else {
            return false
        }
        return target < now
    }
}

// MARK: - List

private struct BoardListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable var store: BoardStore
    let catalog: BoardCatalogStore
    let onOpen: (BoardProjectSummary) -> Void
    let onEdit: (BoardProjectSummary) -> Void
    let onExport: (BoardProjectSummary) -> Void
    let onStatusChange: (BoardProjectSummary, FrameScriptDocument.ProductionStatus) -> Void
    let statusTitle: (FrameScriptDocument.ProductionStatus) -> String
    let onReveal: (BoardProjectSummary) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(theme.divider)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if group.kind != .all {
                                groupHeader(group)
                            }
                            ForEach(group.summaries) { summary in
                                row(summary)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            sortHeader(appState.localized("board.column.title"), key: .title, width: nil)
            sortHeader(appState.localized("board.column.status"), key: .status, width: 90)
            columnHeader(appState.localized("board.column.topic"), width: 112)
            columnHeader(appState.localized("board.column.type"), width: 112)
            sortHeader(appState.localized("board.column.duration"), key: .duration, width: 66)
            sortHeader(appState.localized("board.column.pending"), key: .pending, width: 88)
            sortHeader(appState.localized("board.column.target"), key: .targetDate, width: 82)
            sortHeader(appState.localized("board.column.publish"), key: .publishDate, width: 82)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.tertiaryText)
        .textCase(.uppercase)
        .padding(.horizontal, 26)
        .frame(height: 30)
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .frame(width: width, alignment: .leading)
            .lineLimit(1)
    }

    private func sortHeader(_ title: String, key: BoardSortKey, width: CGFloat?) -> some View {
        Button {
            if store.sort.key == key {
                store.sort.ascending.toggle()
            } else {
                store.sort = BoardSort(key: key, ascending: key == .title)
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if store.sort.key == key {
                    Image(systemName: store.sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }

    private func groupHeader(_ group: BoardGroup) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(groupColor(group.kind))
                .frame(width: 6, height: 6)
            Text(groupTitle(group))
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(group.summaries.count)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func groupTitle(_ group: BoardGroup) -> String {
        switch group.kind {
        case .all:
            appState.localized("board.group.none")
        case .status(let status):
            statusTitle(status)
        case .topic(let topic):
            topic.isEmpty ? appState.localized("board.unclassified") : topic
        case .videoType(let type):
            type.isEmpty ? appState.localized("board.unclassified") : type
        }
    }

    private func groupColor(_ kind: BoardGroup.Kind) -> Color {
        switch kind {
        case .status(let status): BoardStatusStyle.color(status, theme: theme)
        case .topic: theme.bRollMarker
        case .videoType: theme.editingMarker
        case .all: theme.accent.color
        }
    }

    private func row(_ summary: BoardProjectSummary) -> some View {
        let selected = store.selectedProjectID == summary.id
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(summary.title.isEmpty ? appState.localized("project.untitled") : summary.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if summary.pending.total > 0 {
                    Text("\(summary.pending.total)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 5)
                        .background(theme.hover, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(BoardStatusStyle.color(summary.productionStatus, theme: theme))
                    .frame(width: 6, height: 6)
                Text(statusTitle(summary.productionStatus))
                    .lineLimit(1)
            }
            .frame(width: 90, alignment: .leading)

            Text(summary.topic.isEmpty ? appState.localized("board.unclassified") : summary.topic)
                .foregroundStyle(summary.topic.isEmpty ? theme.tertiaryText : theme.primaryText)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)

            Text(summary.videoType.isEmpty ? appState.localized("board.unclassified") : summary.videoType)
                .foregroundStyle(summary.videoType.isEmpty ? theme.tertiaryText : theme.primaryText)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)

            Text(BoardFormatting.duration(summary.duration))
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
                .frame(width: 66, alignment: .leading)

            HStack(spacing: 5) {
                ForEach(summary.pending.activeKinds, id: \.rawValue) { kind in
                    HStack(spacing: 1) {
                        Image(systemName: BoardPendingKindStyle.icon(kind))
                            .font(.system(size: 8.5))
                        Text("\(summary.pending.count(for: kind))")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(theme.secondaryText)
                    .help(appState.localized("board.kind.\(kind.rawValue)"))
                }
                if summary.pending.isEmpty {
                    Text("—")
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .frame(width: 88, alignment: .leading)

            Text(summary.targetDate.map(BoardFormatting.shortDate) ?? "—")
                .foregroundStyle(
                    BoardFormatting.isOverdue(summary) ? theme.warning : theme.secondaryText
                )
                .frame(width: 82, alignment: .leading)

            Text(summary.publishDate.map(BoardFormatting.shortDate) ?? "—")
                .foregroundStyle(theme.secondaryText)
                .frame(width: 82, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? theme.selection : theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(selected ? theme.focus : theme.divider, lineWidth: selected ? 1.4 : 1)
                )
        }
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(summary) }
        .onTapGesture { store.selectedProjectID = summary.id }
        .contextMenu {
            BoardProjectMenu(
                summary: summary,
                onOpen: { onOpen(summary) },
                onEdit: { onEdit(summary) },
                onExport: { onExport(summary) },
                onReveal: { onReveal(summary) },
                onMove: { onStatusChange(summary, $0) },
                statusTitle: statusTitle
            )
        }
    }
}
