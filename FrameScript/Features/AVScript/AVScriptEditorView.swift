import AppKit
import FrameScriptCore
import SwiftUI

/// Two-column AV script: narration on the left, visuals and editing notes on
/// the right, aligned paragraph by paragraph.
struct AVScriptEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    @State private var showsAllScenes: Bool
    /// An empty paragraph created with Return at a paragraph boundary. It only
    /// exists in the editor until the first character is typed, so abandoning
    /// it leaves no stray blank lines in the script.
    @State private var draftParagraph: AVDraftParagraph?
    /// The row that must become first responder after a split.
    @State private var focusRequest: AVFocusRequest?

    init(scene: Scene, initiallyShowsAllScenes: Bool = false) {
        self.scene = scene
        _showsAllScenes = State(initialValue: initiallyShowsAllScenes)
    }

    private var contentInset: CGFloat {
        WorkspaceLayout.contentInset(isFocusModeEnabled: appState.isFocusModeEnabled)
    }

    var body: some View {
        GeometryReader { geometry in
            let annotationWidth = AVScriptLayoutMetrics.annotationColumnWidth(containerWidth: geometry.size.width)
            let entries = visibleSceneEntries()
            let rows = displayRows(for: entries)
            let hasContent = entries.contains { !$0.av.rows.isEmpty }

            VStack(spacing: 0) {
                header
                Divider()
                    .overlay(theme.divider)

                if hasContent {
                    columnHeader(annotationWidth: annotationWidth)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { display in
                                switch display.content {
                                case let .header(scene, number, annotationCount):
                                    AVScriptSceneHeaderRow(
                                        scene: scene,
                                        number: number,
                                        annotationCount: annotationCount,
                                        contentInset: contentInset
                                    )
                                case let .row(scene, row, draft, focusToken, focusOffset):
                                    AVScriptRowView(
                                        scene: scene,
                                        row: row,
                                        annotationWidth: annotationWidth,
                                        contentInset: contentInset,
                                        draft: draft,
                                        focusToken: focusToken,
                                        focusOffset: focusOffset,
                                        onSplit: handleSplit,
                                        onDraftCommitted: dismissDraft,
                                        onBeginEditing: dismissDraftIfStillEmpty
                                    )
                                }
                            }
                        }
                    }
                } else {
                    emptyState
                }
            }
        }
        .background(theme.editorSurface)
        .onAppear {
            appState.rebuildProductionSegments(markUnsaved: false)
            appState.scheduleSceneMetricsUpdate(sceneID: scene.id, delay: .zero)
            appState.scheduleRhythmReview(for: scene, delay: .zero)
        }
        .onChange(of: scene.scriptText) { _, _ in
            appState.scheduleRhythmReview(for: scene)
        }
        .onChange(of: scene.bRollItems.count) { _, _ in
            appState.scheduleRhythmReview(for: scene)
        }
        .onChange(of: scene.editingItems.count) { _, _ in
            appState.scheduleRhythmReview(for: scene)
        }
        .onChange(of: scene.id) { _, _ in
            dismissDraft()
        }
        .accessibilityIdentifier("av-script-editor")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            EditorModeHeader(
                title: scene.title,
                subtitle: appState.localized("avScript.subtitle")
            )
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 9) {
                Picker("", selection: $showsAllScenes) {
                    Text(appState.localized("avScript.scope.current")).tag(false)
                    Text(appState.localized("avScript.scope.all")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .accessibilityLabel(appState.localized("avScript.scope.label"))

                Menu {
                    Button(appState.localized("avScript.exportMarkdown")) {
                        appState.exportAVScript(format: .markdown)
                    }
                    Button(appState.localized("avScript.exportCSV")) {
                        appState.exportAVScript(format: .csv)
                    }
                } label: {
                    Label(appState.localized("avScript.export"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, contentInset)
        .padding(.top, max(18, contentInset * 0.55))
        .padding(.bottom, 14)
    }

    private func columnHeader(annotationWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(appState.localized("avScript.narration"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(appState.localized("avScript.annotations"))
                .padding(.leading, AVScriptLayoutMetrics.columnGap + AVScriptLayoutMetrics.dividerWidth)
                .frame(width: annotationWidth, alignment: .leading)
        }
        .font(.system(size: 10, weight: .semibold))
        .textCase(.uppercase)
        .tracking(0.7)
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, contentInset)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmptyProductionState(
                message: appState.localized("avScript.emptyMessage"),
                title: appState.localized("avScript.emptyTitle"),
                actionTitle: appState.localized("avScript.goToScript")
            ) {
                appState.selectMode(.script)
            }
            Spacer(minLength: 0)
        }
        .padding(contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func visibleSceneEntries() -> [(model: Scene, av: AVScriptScene)] {
        let ordered = appState.project.scenes.sortedByOrder
        let shown = showsAllScenes ? ordered : ordered.filter { $0.id == scene.id }
        return shown.map { ($0, appState.avScriptScene($0)) }
    }

    private func displayRows(for entries: [(model: Scene, av: AVScriptScene)]) -> [AVDisplayRow] {
        let ordered = appState.project.scenes.sortedByOrder
        var result: [AVDisplayRow] = []
        for entry in entries {
            let number = (ordered.firstIndex(where: { $0.id == entry.model.id }) ?? 0) + 1
            if showsAllScenes {
                result.append(
                    AVDisplayRow(
                        id: "header-\(entry.model.id)",
                        content: .header(
                            scene: entry.model,
                            number: number,
                            annotationCount: entry.av.annotationCount
                        )
                    )
                )
            }
            let draft = draftParagraph?.sceneID == entry.model.id ? draftParagraph : nil
            for row in rows(for: entry.model, av: entry.av, draft: draft) {
                let rowID = "\(entry.model.id)-\(row.displayIndex ?? -1)"
                let focus = focusRequest?.rowID == rowID ? focusRequest : nil
                result.append(
                    AVDisplayRow(
                        id: rowID,
                        content: .row(
                            scene: entry.model,
                            row: row.row,
                            draft: row.draft,
                            focusToken: focus?.id,
                            focusOffset: focus?.offset ?? 0
                        )
                    )
                )
            }
        }
        return result
    }

    private struct DisplayedRow {
        let row: AVScriptRow
        let draft: AVDraftParagraph?
        let displayIndex: Int?
    }

    /// Inserts the empty draft at its paragraph position and shifts the ids of
    /// the paragraphs after it, so the text view that held focus keeps the same
    /// identity when the first character turns the draft into a real paragraph.
    private func rows(
        for scene: Scene,
        av: AVScriptScene,
        draft: AVDraftParagraph?
    ) -> [DisplayedRow] {
        guard let draft else {
            return av.rows.map { DisplayedRow(row: $0, draft: nil, displayIndex: $0.paragraph?.index) }
        }
        let draftRow = AVScriptRow(
            sceneID: scene.id,
            paragraph: AVScriptParagraph(
                sceneID: scene.id,
                index: draft.paragraphIndex,
                text: "",
                range: AVScriptTextRange(
                    startUTF16: draft.insertionOffset,
                    lengthUTF16: 0
                )
            ),
            annotations: []
        )
        let insertionIndex = av.rows.firstIndex { row in
            guard let index = row.paragraph?.index else { return true }
            return index >= draft.paragraphIndex
        } ?? av.rows.endIndex

        var rows = av.rows
        rows.insert(draftRow, at: insertionIndex)
        return rows.enumerated().map { offset, row in
            if offset == insertionIndex {
                return DisplayedRow(row: draftRow, draft: draft, displayIndex: draft.paragraphIndex)
            }
            guard let index = row.paragraph?.index else {
                return DisplayedRow(row: row, draft: nil, displayIndex: nil)
            }
            let displayIndex = index >= draft.paragraphIndex ? index + 1 : index
            return DisplayedRow(row: row, draft: nil, displayIndex: displayIndex)
        }
    }

    private func handleSplit(_ request: AVParagraphSplitRequest) {
        let range = request.paragraphRange
        let length = (request.previousText as NSString).length
        let caret = min(max(0, request.caretOffset), length)

        if caret == 0 {
            let draft = AVDraftParagraph(
                sceneID: request.sceneID,
                paragraphIndex: request.paragraphIndex,
                insertionOffset: range.location,
                boundary: .before
            )
            draftParagraph = draft
            focusRequest = AVFocusRequest(
                id: UUID(),
                rowID: "\(request.sceneID)-\(draft.paragraphIndex)",
                offset: 0
            )
            return
        }
        if caret == length {
            let draft = AVDraftParagraph(
                sceneID: request.sceneID,
                paragraphIndex: request.paragraphIndex + 1,
                insertionOffset: range.location + range.length,
                boundary: .after
            )
            draftParagraph = draft
            focusRequest = AVFocusRequest(
                id: UUID(),
                rowID: "\(request.sceneID)-\(draft.paragraphIndex)",
                offset: 0
            )
            return
        }
        guard appState.splitAVParagraph(
            sceneID: request.sceneID,
            paragraphRange: range,
            previousText: request.previousText,
            at: caret,
            undoManager: request.undoManager
        ) else { return }
        focusRequest = AVFocusRequest(
            id: UUID(),
            rowID: "\(request.sceneID)-\(request.paragraphIndex + 1)",
            offset: 0
        )
    }

    private func dismissDraft() {
        draftParagraph = nil
        focusRequest = nil
    }

    private func dismissDraftIfStillEmpty() {
        guard draftParagraph != nil else { return }
        draftParagraph = nil
        focusRequest = nil
    }
}

private struct AVDisplayRow: Identifiable {
    enum Content {
        case header(scene: Scene, number: Int, annotationCount: Int)
        case row(
            scene: Scene,
            row: AVScriptRow,
            draft: AVDraftParagraph?,
            focusToken: UUID?,
            focusOffset: Int
        )
    }

    let id: String
    let content: Content
}

private struct AVDraftParagraph: Equatable {
    let sceneID: UUID
    let paragraphIndex: Int
    let insertionOffset: Int
    let boundary: AVParagraphBoundary
}

private struct AVFocusRequest: Equatable {
    let id: UUID
    let rowID: String
    let offset: Int
}

private struct AVParagraphSplitRequest {
    let sceneID: UUID
    let paragraphIndex: Int
    let paragraphRange: NSRange
    let previousText: String
    let caretOffset: Int
    let undoManager: UndoManager?
}

private struct AVScriptSceneHeaderRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let number: Int
    let annotationCount: Int
    let contentInset: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%02d", number))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
            Text(displayTitle)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
            Spacer(minLength: 8)
            if annotationCount > 0 {
                Text("\(annotationCount)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.hover)
                    }
            }
        }
        .padding(.horizontal, contentInset)
        .padding(.top, 24)
        .padding(.bottom, 6)
    }

    private var displayTitle: String {
        let trimmed = scene.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appState.localized("templates.defaultScene") : trimmed
    }
}

private struct AVScriptRowView: View {
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let row: AVScriptRow
    let annotationWidth: CGFloat
    let contentInset: CGFloat
    let draft: AVDraftParagraph?
    let focusToken: UUID?
    let focusOffset: Int
    let onSplit: (AVParagraphSplitRequest) -> Void
    let onDraftCommitted: () -> Void
    let onBeginEditing: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn
                .padding(.trailing, AVScriptLayoutMetrics.narrationTrailingInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(theme.divider)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            rightColumn
                .padding(.leading, 16)
                .frame(width: annotationWidth, alignment: .leading)
        }
        .padding(.horizontal, contentInset)
        .padding(.vertical, 12)
        .background(row.isUnanchored ? theme.warning.opacity(0.045) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.horizontal, contentInset)
        }
    }

    @ViewBuilder
    private var leftColumn: some View {
        if let paragraph = row.paragraph {
            AVParagraphEditor(
                text: paragraph.text,
                placeholder: appState.localized("avScript.paragraphPlaceholder"),
                paragraphRange: paragraph.range.nsRange,
                isDraft: draft != nil,
                focusToken: focusToken,
                focusOffset: focusOffset,
                onSplit: { caretOffset, textLength, range, previousText, undoManager in
                    onSplit(
                        AVParagraphSplitRequest(
                            sceneID: scene.id,
                            paragraphIndex: paragraph.index,
                            paragraphRange: range,
                            previousText: previousText,
                            caretOffset: min(max(0, caretOffset), textLength),
                            undoManager: undoManager
                        )
                    )
                },
                onCommit: { text, range, previousText, undoManager in
                    if let draft {
                        let accepted = appState.insertAVParagraph(
                            sceneID: scene.id,
                            insertionOffset: draft.insertionOffset,
                            boundary: draft.boundary,
                            text: text,
                            undoManager: undoManager
                        )
                        if accepted {
                            onDraftCommitted()
                        }
                        return accepted
                    }
                    return appState.commitAVParagraph(
                        sceneID: scene.id,
                        paragraphRange: range,
                        previousText: previousText,
                        text: text,
                        undoManager: undoManager
                    )
                },
                onBeginEditing: draft == nil ? onBeginEditing : {}
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(appState.localized("avScript.unanchored"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.warning)
                Text(appState.localized("avScript.unanchoredHint"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var rightColumn: some View {
        if draft != nil {
            Color.clear.frame(height: 1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if row.annotations.isEmpty, let paragraph = row.paragraph {
                    Text(appState.localized("avScript.noAnnotations"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.top, 4)
                    addMenu(for: paragraph)
                } else {
                    ForEach(row.annotations) { annotation in
                        AVScriptAnnotationView(
                            scene: scene,
                            annotation: annotation,
                            isUnanchored: row.isUnanchored
                        )
                    }
                    if let paragraph = row.paragraph {
                        addMenu(for: paragraph)
                    }
                }
            }
        }
    }

    @Environment(AppState.self) private var appState

    private func addMenu(for paragraph: AVScriptParagraph) -> some View {
        Menu {
            Button {
                appState.addAVAnnotation(
                    sceneID: scene.id,
                    paragraphRange: paragraph.range.nsRange,
                    kind: .bRoll
                )
            } label: {
                Label(appState.localized("avScript.addBRoll"), systemImage: "photo")
            }
            Button {
                appState.addAVAnnotation(
                    sceneID: scene.id,
                    paragraphRange: paragraph.range.nsRange,
                    kind: .editing
                )
            } label: {
                Label(appState.localized("avScript.addEditing"), systemImage: "scissors")
            }
        } label: {
            Label(appState.localized("avScript.addToParagraph"), systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(appState.localized("avScript.addToParagraph"))
        .accessibilityIdentifier("av-script-add-\(scene.id.uuidString)-\(row.id.paragraphIndex ?? -1)")
    }
}

private struct AVScriptAnnotationView: View {
    let scene: Scene
    let annotation: AVScriptAnnotation
    let isUnanchored: Bool

    var body: some View {
        if annotation.kind == .bRoll,
           let item = scene.bRollItems.first(where: { $0.id == annotation.id }) {
            AVBRollCard(scene: scene, annotation: annotation, item: item, isUnanchored: isUnanchored)
        } else if annotation.kind == .editing,
                  let item = scene.editingItems.first(where: { $0.id == annotation.id }) {
            AVEditingCard(scene: scene, annotation: annotation, item: item, isUnanchored: isUnanchored)
        }
    }
}

private struct AVBRollCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let annotation: AVScriptAnnotation
    @Bindable var item: BRollItem
    let isUnanchored: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.bRollMarker)
                    .frame(width: 6, height: 6)
                Text(appState.localized("avScript.export.broll"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                statusMenu
                deleteButton
            }

            if isUnanchored, !annotation.anchorExcerpt.isEmpty {
                Text("«\(annotation.anchorExcerpt)»")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 6) {
                Text(appState.localized("avScript.source"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                Picker("", selection: Bindable(item).sourceType) {
                    ForEach(BRollSourceType.allCases) { source in
                        Text(appState.displayName(source)).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(appState.localized("avScript.source"))
            }

            MultilineField(
                placeholder: appState.localized("avScript.descriptionPlaceholder"),
                text: Bindable(item).descriptionText,
                minHeight: 46
            )
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .onChange(of: item.descriptionText) { _, _ in appState.touchProject() }
        .onChange(of: item.sourceType) { _, _ in appState.touchProject() }
        .accessibilityIdentifier("av-script-broll-\(item.id.uuidString)")
    }

    private var statusMenu: some View {
        Menu {
            ForEach(BRollStatus.allCases) { status in
                Button {
                    item.status = status
                    appState.touchProject()
                } label: {
                    if item.status == status {
                        Label(appState.displayName(status), systemImage: "checkmark")
                    } else {
                        Text(appState.displayName(status))
                    }
                }
            }
        } label: {
            Text(appState.displayName(item.status))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background {
                    Capsule()
                        .fill(item.status == .done ? theme.success.opacity(0.16) : theme.hover)
                }
                .foregroundStyle(item.status == .done ? theme.success : theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(appState.localized("avScript.status"))
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            appState.deleteAVAnnotation(sceneID: scene.id, itemID: item.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(theme.tertiaryText)
        .help(appState.localized("avScript.deleteBRoll"))
        .accessibilityLabel(appState.localized("avScript.deleteBRoll"))
    }
}

private struct AVEditingCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let scene: Scene
    let annotation: AVScriptAnnotation
    @Bindable var item: EditingItem
    let isUnanchored: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.editingMarker)
                    .frame(width: 6, height: 6)
                Text(appState.localized("avScript.export.editing"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                Toggle(isOn: doneBinding) {
                    Text(appState.localized("avScript.done"))
                        .font(.system(size: 10, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .tint(theme.accent.color)
                .foregroundStyle(theme.secondaryText)
                deleteButton
            }

            if isUnanchored, !annotation.anchorExcerpt.isEmpty {
                Text("«\(annotation.anchorExcerpt)»")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
            }

            MultilineField(
                placeholder: appState.localized("avScript.editingPlaceholder"),
                text: Bindable(item).cutStyle,
                minHeight: 46
            )
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .onChange(of: item.cutStyle) { _, _ in appState.touchProject() }
        .accessibilityIdentifier("av-script-editing-\(item.id.uuidString)")
    }

    private var doneBinding: Binding<Bool> {
        Binding(
            get: { item.status == .done },
            set: { isDone in
                item.status = isDone ? .done : .pending
                appState.touchProject()
            }
        )
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            appState.deleteAVAnnotation(sceneID: scene.id, itemID: item.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.cursorPlain)
        .foregroundStyle(theme.tertiaryText)
        .help(appState.localized("avScript.deleteEditing"))
        .accessibilityLabel(appState.localized("avScript.deleteEditing"))
    }
}

// MARK: - Paragraph editor

enum AVScriptLayoutMetrics {
    static let dividerWidth: CGFloat = 1
    static let columnGap: CGFloat = 16
    static let narrationTrailingInset: CGFloat = 12
    static let minimumNarrationWidth: CGFloat = 220

    static func annotationColumnWidth(containerWidth: CGFloat) -> CGFloat {
        min(360, max(228, containerWidth * 0.36))
    }

    static func narrationColumnWidth(containerWidth: CGFloat, contentInset: CGFloat) -> CGFloat {
        let content = max(0, containerWidth - contentInset * 2)
        return content
            - annotationColumnWidth(containerWidth: containerWidth)
            - columnGap
            - dividerWidth
            - narrationTrailingInset
    }
}

private struct AVParagraphEditor: View {
    let text: String
    let placeholder: String
    let paragraphRange: NSRange
    let isDraft: Bool
    let focusToken: UUID?
    let focusOffset: Int
    let onSplit: (Int, Int, NSRange, String, UndoManager?) -> Void
    let onCommit: (String, NSRange, String, UndoManager?) -> Bool
    let onBeginEditing: () -> Void

    var body: some View {
        AVParagraphTextRepresentable(
            text: text,
            placeholder: placeholder,
            paragraphRange: paragraphRange,
            isDraft: isDraft,
            focusToken: focusToken,
            focusOffset: focusOffset,
            onSplit: onSplit,
            onCommit: onCommit,
            onBeginEditing: onBeginEditing
        )
        .frame(minHeight: 24)
    }
}

private struct AVParagraphTextRepresentable: NSViewRepresentable {
    let text: String
    let placeholder: String
    let paragraphRange: NSRange
    let isDraft: Bool
    let focusToken: UUID?
    let focusOffset: Int
    let onSplit: (Int, Int, NSRange, String, UndoManager?) -> Void
    /// `(newText, rangeShownByThisView, modelTextShownByThisView, undoManager)`.
    let onCommit: (String, NSRange, String, UndoManager?) -> Bool
    let onBeginEditing: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AVParagraphTextView {
        let textView = AVParagraphTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.attach(to: textView)
        context.coordinator.configure(textView)
        return textView
    }

    func updateNSView(_ textView: AVParagraphTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure(textView)
    }

    static func dismantleNSView(_ textView: AVParagraphTextView, coordinator: Coordinator) {
        if textView.delegate === coordinator {
            textView.delegate = nil
        }
        coordinator.detach()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: AVParagraphTextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? textView.bounds.width
        guard width > 0, let container = textView.textContainer else { return nil }
        container.containerSize = NSSize(
            width: max(1, width - textView.textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: container)
        let usedHeight = textView.layoutManager?.usedRect(for: container).height ?? 0
        let height = max(24, ceil(usedHeight + textView.textContainerInset.height * 2))
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AVParagraphTextRepresentable
        let styler = MarkupEditorStyler()
        private var isApplyingModelText = false
        /// The paragraph text this view last displayed or committed. Commits
        /// are refused when the model range no longer contains it, so an edit
        /// can never leak into a different paragraph after a row shift.
        private var boundText = ""
        private var boundRange: NSRange
        private var lastHandledFocusToken: UUID?

        init(parent: AVParagraphTextRepresentable) {
            self.parent = parent
            self.boundRange = parent.paragraphRange
        }

        func attach(to textView: AVParagraphTextView) {
            styler.attach(to: textView)
            textView.pasteHandler = { [weak self, weak textView] pasteboard in
                guard let self, let textView else { return false }
                return self.handleMultilinePaste(in: textView, pasteboard: pasteboard)
            }
        }

        func detach() {
            styler.textView = nil
        }

        func configure(_ textView: AVParagraphTextView) {
            let preferences = parent.appState.settings.editorPreferences
            let theme = parent.theme
            let fontSize = CGFloat(max(14, min(18, preferences.fontSize * 0.8)))

            if textView.font?.pointSize != fontSize {
                textView.font = NSFont.systemFont(ofSize: fontSize)
            }
            textView.textColor = NSColor(theme.primaryText)
            textView.insertionPointColor = NSColor(theme.accent.color)
            textView.backgroundColor = NSColor(theme.editorSurface)
            textView.isContinuousSpellCheckingEnabled = preferences.spellcheck
            textView.isAutomaticQuoteSubstitutionEnabled = preferences.smartQuotes
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.placeholder = parent.placeholder
            textView.placeholderColor = NSColor(theme.secondaryText.opacity(0.58))

            let paragraphStyle = ScriptEditorLayout.paragraphStyle()
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes[.paragraphStyle] = paragraphStyle
            applyParagraphStyle(paragraphStyle, to: textView)

            styler.configure(
                MarkupEditorStyler.Configuration(
                    isEnabled: true,
                    pauseDefaults: preferences.markupPauseDefaults,
                    palette: MarkupEditorPalette(
                        fontSize: Double(fontSize),
                        textColor: NSColor(theme.primaryText),
                        secondaryColor: NSColor(theme.secondaryText),
                        accentColor: NSColor(theme.accent.color),
                        rhythmColor: NSColor(theme.warning),
                        backgroundColor: NSColor(theme.editorSurface)
                    )
                )
            )

            let modelText = parent.text
            let shownText = Self.normalizedTrailingNewlines(textView.string)
            if shownText == modelText {
                // The text view is ahead of the model only by the user's own
                // pending trailing newline; keep it and adopt the current range.
                boundText = modelText
                boundRange = parent.paragraphRange
                requestFocusIfNeeded(textView)
                return
            }

            let modelChanged = modelText != Self.normalizedTrailingNewlines(boundText)
                || parent.paragraphRange != boundRange
            guard modelChanged else {
                requestFocusIfNeeded(textView)
                return
            }

            // The row was reused for another paragraph or the model changed
            // outside this editor. Resync even while focused and drop undo
            // actions recorded against the old paragraph (A-2).
            isApplyingModelText = true
            let selection = textView.selectedRange()
            textView.string = modelText
            applyParagraphStyle(paragraphStyle, to: textView)
            isApplyingModelText = false
            let clamped = TextAnchorGeometry.clamp(
                selection,
                toLength: (modelText as NSString).length
            )
            textView.setSelectedRange(clamped)
            styler.applyAll(in: textView)
            textView.invalidateIntrinsicContentSize()
            clearUndoHistory(in: textView)
            boundText = modelText
            boundRange = parent.paragraphRange
            requestFocusIfNeeded(textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard !parent.isDraft else { return }
            parent.onBeginEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText,
                  let textView = notification.object as? AVParagraphTextView else {
                return
            }
            styler.apply(around: textView.selectedRange(), in: textView)
            commit(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !isApplyingModelText,
                  let textView = notification.object as? AVParagraphTextView else {
                return
            }
            commit(textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            guard let textView = textView as? AVParagraphTextView else { return false }
            let text = textView.string
            guard !text.isEmpty else { return true }
            let selection = textView.selectedRange()
            // Replacing a selection with Return is a normal replacement; only
            // a collapsed caret becomes a paragraph split.
            guard selection.length == 0 else { return false }

            let nsText = text as NSString
            let location = min(max(0, selection.location), nsText.length)
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let line = nsText.substring(
                with: NSRange(location: lineStart, length: max(0, contentsEnd - lineStart))
            )
            // The AV model has no blank paragraphs, so Return on an empty line
            // must never insert another one.
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return true }

            let column = location - lineStart
            let isBoundary = location == 0
                || location == nsText.length
                || column == 0
                || location == contentsEnd
            guard isBoundary else { return false }

            parent.onSplit(
                location,
                nsText.length,
                boundRange,
                boundText,
                textView.undoManager
            )
            return true
        }

        private func commit(_ textView: AVParagraphTextView) {
            let accepted = parent.onCommit(
                textView.string,
                boundRange,
                boundText,
                textView.undoManager
            )
            if accepted {
                boundText = Self.normalizedTrailingNewlines(textView.string)
                boundRange = NSRange(
                    location: boundRange.location,
                    length: (textView.string as NSString).length
                )
            } else {
                configure(textView)
            }
        }

        private func requestFocusIfNeeded(_ textView: AVParagraphTextView) {
            guard let token = parent.focusToken, token != lastHandledFocusToken else { return }
            lastHandledFocusToken = token
            let offset = parent.focusOffset
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                if let window = textView.window, window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
                let length = (textView.string as NSString).length
                textView.setSelectedRange(
                    NSRange(location: min(max(0, offset), length), length: 0)
                )
                self.parent.onBeginEditing()
            }
        }

        /// One model commit, then the row resyncs from the model. A paste that
        /// contains a blank line must never live inside a single paragraph row.
        private func handleMultilinePaste(
            in textView: AVParagraphTextView,
            pasteboard: NSPasteboard
        ) -> Bool {
            guard let plain = pasteboard.string(forType: .string),
                  plain.range(of: "\\n\\s*\\n", options: .regularExpression) != nil else {
                return false
            }
            let selection = textView.selectedRange()
            let updated = (textView.string as NSString).replacingCharacters(
                in: selection,
                with: plain
            )
            _ = parent.onCommit(updated, boundRange, boundText, textView.undoManager)
            configure(textView)
            return true
        }

        private func clearUndoHistory(in textView: NSTextView) {
            guard let undoManager = textView.undoManager else { return }
            undoManager.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage {
                undoManager.removeAllActions(withTarget: storage)
            }
            // NSTextView's typing undo is registered through a private target,
            // so clearing the manager is the only reliable way to guarantee a
            // Cmd-Z can never write the previous paragraph into this row.
            undoManager.removeAllActions()
        }

        private static func normalizedTrailingNewlines(_ text: String) -> String {
            var end = text.endIndex
            while end > text.startIndex {
                let previous = text.index(before: end)
                let character = text[previous]
                guard character == "\n" || character == "\r" else { break }
                end = previous
            }
            return String(text[..<end])
        }

        private func applyParagraphStyle(_ style: NSParagraphStyle, to textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }
            if let existing = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
               existing.isEqual(style) {
                return
            }
            let undoManager = textView.undoManager
            undoManager?.disableUndoRegistration()
            storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: storage.length))
            undoManager?.enableUndoRegistration()
        }
    }
}

private final class AVParagraphTextView: PlaceholderTextView {
    var pasteHandler: ((NSPasteboard) -> Bool)?

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    /// The paragraph editor allows rich text so the markup styler can apply
    /// fonts, but pasted content must stay plain. Multi-paragraph pastes are
    /// routed through the model so blank lines never enter one row.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if pasteHandler?(pasteboard) == true { return }
        guard let plain = pasteboard.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(plain, replacementRange: selectedRange())
    }
}
