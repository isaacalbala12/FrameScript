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
                                case let .row(scene, row):
                                    AVScriptRowView(
                                        scene: scene,
                                        row: row,
                                        annotationWidth: annotationWidth,
                                        contentInset: contentInset
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
            for row in entry.av.rows {
                result.append(
                    AVDisplayRow(
                        id: "\(entry.model.id)-\(row.paragraph?.index ?? -1)",
                        content: .row(scene: entry.model, row: row)
                    )
                )
            }
        }
        return result
    }
}

private struct AVDisplayRow: Identifiable {
    enum Content {
        case header(scene: Scene, number: Int, annotationCount: Int)
        case row(scene: Scene, row: AVScriptRow)
    }

    let id: String
    let content: Content
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
            let edit = {
                appState.editAVParagraphInScript(
                    sceneID: scene.id,
                    range: paragraph.range.nsRange
                )
            }
            // Narration is read-only here. The Script editor is the only place
            // where narration is edited, so there is one owner for the text
            // and one undo stack.
            AVReadOnlyParagraph(text: paragraph.text, onEdit: edit)
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
        VStack(alignment: .leading, spacing: 8) {
            if let paragraph = row.paragraph {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Button {
                        appState.editAVParagraphInScript(
                            sceneID: scene.id,
                            range: paragraph.range.nsRange
                        )
                    } label: {
                        Label(
                            appState.localized("avScript.editInScript"),
                            systemImage: "pencil"
                        )
                        .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.tertiaryText)
                    .help(appState.localized("avScript.editInScriptHelp"))
                    .accessibilityIdentifier(
                        "av-script-edit-\(scene.id.uuidString)-\(paragraph.index)"
                    )
                }
            }
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

// MARK: - Narration (read-only)

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

private struct AVReadOnlyParagraph: View {
    let text: String
    let onEdit: () -> Void

    var body: some View {
        AVReadOnlyParagraphRepresentable(text: text, onEdit: onEdit)
            .frame(minHeight: 24)
    }
}

/// Selectable, copyable narration. It deliberately has no delegate, no undo
/// and no commit path: narration is edited in the Script workspace only.
private struct AVReadOnlyParagraphRepresentable: NSViewRepresentable {
    let text: String
    let onEdit: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVReadOnlyTextView {
        let textView = AVReadOnlyTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 1)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onEdit = onEdit
        context.coordinator.styler.attach(to: textView)
        configure(textView, styler: context.coordinator.styler)
        return textView
    }

    func updateNSView(_ textView: AVReadOnlyTextView, context: Context) {
        textView.onEdit = onEdit
        configure(textView, styler: context.coordinator.styler)
    }

    static func dismantleNSView(_ textView: AVReadOnlyTextView, coordinator: Coordinator) {
        coordinator.styler.textView = nil
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: AVReadOnlyTextView,
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

    private func configure(_ textView: AVReadOnlyTextView, styler: MarkupEditorStyler) {
        let preferences = appState.settings.editorPreferences
        let theme = theme
        let fontSize = CGFloat(max(14, min(18, preferences.fontSize * 0.8)))

        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }
        textView.textColor = NSColor(theme.primaryText)
        textView.backgroundColor = NSColor(theme.editorSurface)
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let paragraphStyle = ScriptEditorLayout.paragraphStyle()
        textView.defaultParagraphStyle = paragraphStyle

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

        guard textView.string != text else {
            styler.applyAll(in: textView)
            return
        }
        textView.string = text
        applyParagraphStyle(paragraphStyle, to: textView)
        styler.applyAll(in: textView)
        textView.invalidateIntrinsicContentSize()
    }

    private func applyParagraphStyle(_ style: NSParagraphStyle, to textView: NSTextView) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(
            .paragraphStyle,
            value: style,
            range: NSRange(location: 0, length: storage.length)
        )
    }

    @MainActor
    final class Coordinator {
        let styler = MarkupEditorStyler()
    }
}

private final class AVReadOnlyTextView: PlaceholderTextView {
    var onEdit: (() -> Void)?

    /// Double-click opens the paragraph in the Script workspace, where the
    /// single narration editor lives.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onEdit?()
            return
        }
        super.mouseDown(with: event)
    }
}
