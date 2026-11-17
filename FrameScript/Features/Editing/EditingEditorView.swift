import SwiftUI

struct EditingEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable var scene: Scene

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FrameLayout.editorBarToText) {
                    EditorModeHeader(title: scene.title, subtitle: appState.localized("editing.linkedSubtitle"))
                    if scene.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scene.editingItems.isEmpty {
                        EmptyProductionState(message: appState.localized("editing.writeScriptFirst"))
                    } else if anchorSections.isEmpty && unlinkedItems.isEmpty {
                        EmptyProductionState(
                            message: appState.localized("editing.emptyMessage"),
                            title: appState.localized("editing.emptyTitle")
                        )
                    } else {
                        ForEach(anchorSections) { section in anchorSection(section).id(section.id) }
                        if !unlinkedItems.isEmpty {
                            ProductionUnlinkedBlock(title: appState.localized("production.unlinked")) {
                                ForEach(unlinkedItems) { item in itemEditor(item) }
                            }
                        }
                    }
                }
                .frame(maxWidth: ScriptEditorLayout.maximumTextColumnWidth, alignment: .leading)
                .padding(WorkspaceLayout.contentInset(isFocusModeEnabled: appState.isFocusModeEnabled))
                .frame(maxWidth: .infinity)
            }
            .onAppear { appState.rebuildProductionSegments(markUnsaved: false); scrollToSelection(proxy) }
            .onChange(of: appState.editorState.selectedProductionItemIDs) { _, _ in scrollToSelection(proxy) }
        }
        .background(theme.editorSurface)
        .onChange(of: scene.editingItems.count) { _, _ in appState.touchProject() }
    }

    private func anchorSection(_ section: ProductionAnchorSection<EditingItem>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.excerpt).font(.system(size: 13)).foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 9)
                .overlay(alignment: .leading) { Capsule().fill(theme.editingMarker).frame(width: 3) }
            ForEach(section.items) { item in itemEditor(item) }
            HStack(spacing: 10) {
                Button { addEmptyItem(anchoredTo: section.anchor) } label: { Label(appState.localized("editing.addEmpty"), systemImage: "plus") }
                Menu(appState.localized("production.usePreset")) {
                    ForEach(EditingPreset.allCases) { preset in Button(preset.title(appState)) { addItem(from: preset, anchoredTo: section.anchor) } }
                }.menuStyle(.borderlessButton).fixedSize()
            }.font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10).overlay(alignment: .bottom) { Divider() }
    }

    private func itemEditor(_ item: EditingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(theme.editingMarker).frame(width: 7, height: 7)
                Text(appState.localized("editing.item")).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondaryText)
                Spacer(minLength: 8)
                linkMenu(item)
                EditorIconButton(systemName: "plus.square.on.square", accessibilityLabel: appState.localized("editing.duplicateItem")) { duplicateItem(item) }
                EditorIconButton(systemName: "trash", accessibilityLabel: appState.localized("editing.deleteItem"), role: .destructive) { deleteItem(item) }
            }
            QuietField(appState.localized("editing.description")) {
                MultilineField(placeholder: appState.localized("editing.descriptionPlaceholder"), text: Bindable(item).cutStyle, minHeight: 68)
            }
            QuietField(appState.localized("editing.notes")) {
                MultilineField(placeholder: appState.localized("editing.notesPlaceholder"), text: Bindable(item).notes, minHeight: 54)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 7).fill(theme.background.opacity(0.42)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(appState.isProductionItemSelected(item.id) ? theme.editingMarker : theme.divider, lineWidth: appState.isProductionItemSelected(item.id) ? 2 : 1))
        .onChange(of: item.cutStyle) { _, _ in appState.touchProject() }.onChange(of: item.notes) { _, _ in appState.touchProject() }
    }

    private func linkMenu(_ item: EditingItem) -> some View {
        Menu {
            ForEach(Array(scene.textSegments.sortedByOrder.enumerated()), id: \.element.id) { index, segment in
                Button(segmentTitle(index, segment)) {
                    appState.projectStore.link(item, to: segment, in: scene)
                    appState.normalizeProductionSelection(preferredItemID: item.id)
                    appState.touchProject()
                }
            }
            Divider(); Button(appState.localized("production.unlinked")) {
                appState.projectStore.unlink(item)
                appState.normalizeProductionSelection()
                appState.touchProject()
            }
        } label: { Label(linkLabel(item), systemImage: "link").font(.system(size: 12, weight: .medium)) }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var anchorSections: [ProductionAnchorSection<EditingItem>] {
        ProductionAnchorGrouping.sections(for: scene.editingItems, in: scene.scriptText) { $0.textAnchor }
    }

    private var unlinkedItems: [EditingItem] {
        ProductionAnchorGrouping.unlinkedItems(from: scene.editingItems, in: scene.scriptText) { $0.textAnchor }
    }
    private func addEmptyItem(anchoredTo anchor: TextAnchor) { scene.editingItems.append(EditingItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", cutStyle: "", transition: "", subtitleStyle: "")); appState.touchProject() }
    private func addItem(from preset: EditingPreset, anchoredTo anchor: TextAnchor) { scene.editingItems.append(EditingItem(textAnchor: anchor, linkedSegmentID: nil, templateType: "", cutStyle: preset.description(appState), transition: "", subtitleStyle: "", notes: preset.notes(appState))); appState.touchProject() }
    private func duplicateItem(_ item: EditingItem) {
        let copy = EditingItem(textAnchor: item.textAnchor, linkedSegmentID: item.linkedSegmentID, templateType: "", cutStyle: item.cutStyle, transition: "", subtitleStyle: "", notes: item.notes)
        if let index = scene.editingItems.firstIndex(where: { $0.id == item.id }) { scene.editingItems.insert(copy, at: index + 1) } else { scene.editingItems.append(copy) }; appState.touchProject()
    }
    private func deleteItem(_ item: EditingItem) {
        scene.editingItems.removeAll { $0.id == item.id }
        appState.normalizeProductionSelection()
        appState.touchProject()
    }
    private func linkLabel(_ item: EditingItem) -> String {
        guard let anchor = TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) else { return appState.localized("production.unlinked") }
        return String(anchor.selectedText.prefix(42))
    }
    private func segmentTitle(_ index: Int, _ segment: TextSegment) -> String { "\(String(format: "%02d", index + 1)) \(segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(42))" }
    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let itemID = appState.editorState.selectedProductionItemIDs.first,
              let section = anchorSections.first(where: { $0.items.contains(where: { $0.id == itemID }) }) else { return }
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(section.id, anchor: .center) } }
    }
}

private enum EditingPreset: String, CaseIterable, Identifiable {
    case minimal, educational, storytelling, fastSocial, documentary, custom
    var id: String { rawValue }
    @MainActor func title(_ app: AppState) -> String { app.localized("editing.template.\(rawValue)") }
    @MainActor func description(_ app: AppState) -> String { app.localized("editing.template.\(rawValue).cutStyle") }
    @MainActor func notes(_ app: AppState) -> String { app.localized("editing.template.\(rawValue).notes") }
}
