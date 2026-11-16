import AppKit
import FrameScriptCore
import SwiftUI
import UniformTypeIdentifiers

enum AssetLayout: String {
    case grid
    case list
}

/// The project asset library. Presented as a sheet from the toolbar, the View
/// menu and the command palette so `WorkspaceMode` stays untouched.
struct AssetsSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Test-only hook: receives the frames of the sheet's key regions in the
    /// `assets-sheet` coordinate space. Snapshot tests assert they do not
    /// overlap; production passes `nil`.
    var onLayoutFrames: (([String: CGRect]) -> Void)?

    @State private var selection: UUID?
    @State private var searchText = ""
    @State private var kindFilter: AssetKind?
    @State private var tagFilter: String?
    @State private var sceneFilter: UUID?
    @State private var missingOnly = false
    @State private var sortOrder: AssetSortOrder = .name
    @State private var layout: AssetLayout
    @State private var isDropTargeted = false
    @State private var isRefreshing = false
    @State private var pendingRemoval: ProjectAsset?

    init(initialLayout: AssetLayout = .grid, onLayoutFrames: (([String: CGRect]) -> Void)? = nil) {
        _layout = State(initialValue: initialLayout)
        self.onLayoutFrames = onLayoutFrames
    }

    private var coreAssets: [FrameScriptDocument.ProjectAsset] {
        appState.assets.map(FrameScriptDocument.ProjectAsset.init(asset:))
    }

    private var filter: AssetFilter {
        AssetFilter(
            kind: kindFilter.flatMap { FrameScriptDocument.AssetKind(rawValue: $0.rawValue) },
            tag: tagFilter,
            sceneID: sceneFilter,
            searchText: searchText,
            missingOnly: missingOnly
        )
    }

    private var visibleAssets: [ProjectAsset] {
        let byID = Dictionary(uniqueKeysWithValues: appState.assets.map { ($0.id, $0) })
        return AssetQuery
            .apply(coreAssets, filter: filter, sort: sortOrder)
            .compactMap { byID[$0.id] }
    }

    private var selectedAsset: ProjectAsset? {
        guard let selection else { return nil }
        return appState.assets.first { $0.id == selection }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                    .assetLayoutProbe("header")
                Divider().overlay(theme.divider)
                filterBar
                    .assetLayoutProbe("filter")
                Divider().overlay(theme.divider)
                content
                    .assetLayoutProbe("content")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(theme.divider)

            AssetInspectorView(assetID: selection, onLocate: locate, onRemove: { pendingRemoval = $0 })
                .frame(width: 286)
                .assetLayoutProbe("inspector")
        }
        .frame(width: 940, height: 640)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .coordinateSpace(name: "assets-sheet")
        .onPreferenceChange(AssetLayoutFrameKey.self) { frames in
            onLayoutFrames?(frames)
        }
        .accessibilityIdentifier("assets-sheet")
        .alert(
            appState.localized("assets.remove.title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { asset in
            Button(appState.localized("assets.remove.confirm"), role: .destructive) {
                AssetThumbnailCache.shared.invalidate(asset)
                appState.removeAsset(id: asset.id)
                if selection == asset.id { selection = visibleAssets.first?.id }
                pendingRemoval = nil
            }
            Button(appState.localized("assets.cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: { asset in
            let usage = appState.publishingUsageCount(forAssetID: asset.id)
            if usage > 0 {
                Text(String(
                    format: appState.localized("assets.remove.message.publishing"),
                    usage
                ))
            } else {
                Text(appState.localized("assets.remove.message"))
            }
        }
        .onAppear {
            if selection == nil { selection = visibleAssets.first?.id }
            Task { await appState.refreshAssetReachability() }
        }
        .onChange(of: visibleAssets.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = ids.first
            } else if selection == nil {
                selection = ids.first
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.accent.color)
            Text(appState.localized("assets.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(String(format: appState.localized("assets.count"), appState.assets.count))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)

            Spacer(minLength: 8)

            Button(action: chooseFiles) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(appState.localized("assets.add"))
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.accentSoft)
                }
            }
            .buttonStyle(.cursorPlain)
            .accessibilityIdentifier("assets-add")
            .help(appState.localized("assets.add.help"))

            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await appState.refreshAssetReachability()
                    isRefreshing = false
                }
            } label: {
                Group {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 26, height: 26)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("assets.refresh"))

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("assets.close"))
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    // MARK: Filters

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .overlay(alignment: .leading) {
                            if searchText.isEmpty {
                                Text(appState.localized("assets.search"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.tertiaryText)
                                    .allowsHitTesting(false)
                            }
                        }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(appState.localized("assets.search.clear"))
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.editorSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        }
                }
                .accessibilityIdentifier("assets-search")

                layoutToggle

                Menu {
                    ForEach(AssetSortOrder.allCases) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            if sortOrder == order {
                                Label(sortTitle(order), systemImage: "checkmark")
                            } else {
                                Text(sortTitle(order))
                            }
                        }
                    }
                } label: {
                    Text("\(appState.localized("assets.filter.sort")): \(sortTitle(sortOrder))")
                }
                .menuStyle(.borderlessButton)
                .modifier(AssetFilterChip(isActive: sortOrder != .name, theme: theme))
            }

            HStack(spacing: 8) {
                kindMenu
                tagMenu
                sceneMenu
                missingToggle
                Spacer(minLength: 4)
                Text(String(format: appState.localized("assets.count.filtered"), visibleAssets.count, appState.assets.count))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var layoutToggle: some View {
        HStack(spacing: 2) {
            layoutButton(.grid, systemName: "square.grid.2x2", help: appState.localized("assets.view.grid"))
            layoutButton(.list, systemName: "list.bullet", help: appState.localized("assets.view.list"))
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.hover)
        }
    }

    private func layoutButton(_ mode: AssetLayout, systemName: String, help: String) -> some View {
        Button {
            layout = mode
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(layout == mode ? theme.cardBackground : Color.clear)
                }
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(layout == mode ? theme.primaryText : theme.secondaryText)
        .help(help)
    }

    private var kindMenu: some View {
        Menu {
            Button { kindFilter = nil } label: {
                if kindFilter == nil {
                    Label(appState.localized("assets.filter.allKinds"), systemImage: "checkmark")
                } else {
                    Text(appState.localized("assets.filter.allKinds"))
                }
            }
            Divider()
            ForEach(AssetKind.allCases) { kind in
                Button {
                    kindFilter = kind
                } label: {
                    if kindFilter == kind {
                        Label(appState.localized(kind.localizationKey), systemImage: "checkmark")
                    } else {
                        Text(appState.localized(kind.localizationKey))
                    }
                }
            }
        } label: {
            Text("\(appState.localized("assets.filter.kind")): \(kindFilter.map { appState.localized($0.localizationKey) } ?? appState.localized("assets.filter.allKinds"))")
        }
        .menuStyle(.borderlessButton)
        .modifier(AssetFilterChip(isActive: kindFilter != nil, theme: theme))
    }

    private var tagMenu: some View {
        Menu {
            Button { tagFilter = nil } label: {
                if tagFilter == nil {
                    Label(appState.localized("assets.filter.allTags"), systemImage: "checkmark")
                } else {
                    Text(appState.localized("assets.filter.allTags"))
                }
            }
            Divider()
            ForEach(AssetQuery.tags(in: coreAssets), id: \.self) { tag in
                Button {
                    tagFilter = tag
                } label: {
                    if tagFilter == tag {
                        Label(tag, systemImage: "checkmark")
                    } else {
                        Text(tag)
                    }
                }
            }
        } label: {
            Text("\(appState.localized("assets.filter.tag")): \(tagFilter ?? appState.localized("assets.filter.allTags"))")
        }
        .menuStyle(.borderlessButton)
        .modifier(AssetFilterChip(isActive: tagFilter != nil, theme: theme))
        .disabled(AssetQuery.tags(in: coreAssets).isEmpty)
    }

    private var sceneMenu: some View {
        Menu {
            Button { sceneFilter = nil } label: {
                if sceneFilter == nil {
                    Label(appState.localized("assets.filter.allScenes"), systemImage: "checkmark")
                } else {
                    Text(appState.localized("assets.filter.allScenes"))
                }
            }
            Divider()
            ForEach(appState.project.scenes.sortedByOrder) { scene in
                Button {
                    sceneFilter = scene.id
                } label: {
                    if sceneFilter == scene.id {
                        Label(scene.title, systemImage: "checkmark")
                    } else {
                        Text(scene.title)
                    }
                }
            }
        } label: {
            Text("\(appState.localized("assets.filter.scene")): \(selectedSceneTitle)")
        }
        .menuStyle(.borderlessButton)
        .modifier(AssetFilterChip(isActive: sceneFilter != nil, theme: theme))
    }

    private var selectedSceneTitle: String {
        guard let sceneFilter,
              let scene = appState.project.scenes.first(where: { $0.id == sceneFilter })
        else { return appState.localized("assets.filter.allScenes") }
        return scene.title
    }

    private var missingToggle: some View {
        Button {
            missingOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: missingOnly ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .medium))
                Text(appState.localized("assets.filter.missingOnly"))
                    .font(.system(size: 11))
            }
            .foregroundStyle(missingOnly ? theme.accentText : theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(missingOnly ? theme.accentSoft : theme.hover)
            }
        }
        .buttonStyle(.cursorPlain)
    }

    private func sortTitle(_ order: AssetSortOrder) -> String {
        appState.localized("assets.sort.\(order.rawValue)")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ZStack {
            Group {
                if visibleAssets.isEmpty {
                    emptyState
                } else {
                    switch layout {
                    case .grid:
                        grid
                    case .list:
                        list
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.accentSoft.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(theme.accent.color, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .overlay {
                        Label(appState.localized("assets.drop"), systemImage: "arrow.down.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.primaryText)
                    }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let added = appState.addAssets(at: urls)
            guard !added.isEmpty else { return false }
            selection = added.first?.id
            if let first = added.first {
                AssetThumbnailCache.shared.invalidate(first)
            }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 10
            let horizontalPadding: CGFloat = 28
            let columnCount = 4
            let cellWidth = max(
                120,
                floor((proxy.size.width - horizontalPadding - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount))
            )
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(cellWidth), spacing: spacing, alignment: .top),
                        count: columnCount
                    ),
                    spacing: spacing
                ) {
                    ForEach(visibleAssets) { asset in
                        AssetGridCard(asset: asset, isSelected: selection == asset.id, width: cellWidth)
                            .frame(width: cellWidth)
                            .onTapGesture { selection = asset.id }
                            .onTapGesture(count: 2) { AssetFileAccess.quickLook(asset, projectDirectory: appState.assetProjectDirectory) }
                            .contextMenu { contextMenu(for: asset) }
                    }
                }
                .padding(14)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(visibleAssets) { asset in
                    AssetListRow(asset: asset, isSelected: selection == asset.id)
                        .onTapGesture { selection = asset.id }
                        .onTapGesture(count: 2) { AssetFileAccess.quickLook(asset, projectDirectory: appState.assetProjectDirectory) }
                        .contextMenu { contextMenu(for: asset) }
                }
            }
            .padding(8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle.angled")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized(filter.isActive ? "assets.search.empty" : "assets.empty.title"))
                .font(.system(size: 15, weight: .medium))
            if !filter.isActive {
                Text(appState.localized("assets.empty.message"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button(action: chooseFiles) {
                    Text(appState.localized("assets.add"))
                }
                .padding(.top, 2)
            } else {
                Button {
                    clearFilters()
                } label: {
                    Text(appState.localized("assets.filter.clear"))
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func contextMenu(for asset: ProjectAsset) -> some View {
        Button(appState.localized("assets.preview")) {
            AssetFileAccess.quickLook(asset, projectDirectory: appState.assetProjectDirectory)
        }
        .disabled(!FileManager.default.fileExists(atPath: appState.assetReferenceURL(asset)?.path ?? ""))

        Button(appState.localized("assets.reveal")) {
            AssetFileAccess.reveal(asset, projectDirectory: appState.assetProjectDirectory)
        }
        .disabled(asset.isLastKnownMissing)

        Button(appState.localized("assets.open")) {
            AssetFileAccess.open(asset, projectDirectory: appState.assetProjectDirectory)
        }
        .disabled(asset.isLastKnownMissing)

        Divider()

        Button(appState.localized("assets.locate")) {
            locate(asset)
        }

        if let scene = appState.selectedScene {
            Button(appState.localized("assets.linkCurrentScene")) {
                appState.toggleAssetSceneLink(assetID: asset.id, sceneID: scene.id)
            }
        }

        Divider()

        Button(appState.localized("assets.remove"), role: .destructive) {
            pendingRemoval = asset
        }
    }

    // MARK: Actions

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        panel.message = appState.localized("assets.add.panelMessage")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let added = appState.addAssets(at: panel.urls)
        if let first = added.first {
            selection = first.id
            AssetThumbnailCache.shared.invalidate(first)
        }
    }

    private func locate(_ asset: ProjectAsset) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.item]
        panel.message = appState.localized("assets.locate.message")
        panel.nameFieldStringValue = AssetPath.fileName(asset.path)
        let existingDirectory = (asset.path as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: existingDirectory) {
            panel.directoryURL = URL(fileURLWithPath: existingDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.locateAsset(id: asset.id, at: url)
        AssetThumbnailCache.shared.invalidate(asset)
    }

    private func clearFilters() {
        kindFilter = nil
        tagFilter = nil
        sceneFilter = nil
        missingOnly = false
        searchText = ""
    }
}

private struct AssetFilterChip: ViewModifier {
    let isActive: Bool
    let theme: FrameTheme

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11))
            .foregroundStyle(isActive ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? theme.accentSoft : theme.hover)
            }
    }
}

private struct AssetLayoutFrameKey: PreferenceKey {    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct AssetLayoutProbe: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AssetLayoutFrameKey.self,
                    value: [name: proxy.frame(in: .named("assets-sheet"))]
                )
            }
        }
    }
}

private extension View {
    func assetLayoutProbe(_ name: String) -> some View {
        modifier(AssetLayoutProbe(name: name))
    }
}
