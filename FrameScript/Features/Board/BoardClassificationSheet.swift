import FrameScriptCore
import SwiftUI

// MARK: - Shared fields

/// Classification form shared by the board sheet and the project-info popover.
struct BoardClassificationFields: View {
    @Environment(AppState.self) private var appState
    @Binding var status: ProductionStatus
    @Binding var topic: String
    @Binding var videoType: String
    @Binding var hasTargetDate: Bool
    @Binding var targetDate: Date
    @Binding var hasPublishDate: Bool
    @Binding var publishDate: Date
    let topicValues: [String]
    let videoTypeValues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Text(appState.localized("board.classification.status"))
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 120, alignment: .leading)
                Picker("", selection: $status) {
                    ForEach(ProductionStatus.allCases) { status in
                        Text(appState.localized("board.status.\(status.rawValue)")).tag(status)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            BoardAutocompleteField(
                title: appState.localized("board.classification.topic"),
                placeholder: appState.localized("board.classification.topicPlaceholder"),
                text: $topic,
                values: topicValues
            )

            BoardAutocompleteField(
                title: appState.localized("board.classification.videoType"),
                placeholder: appState.localized("board.classification.typePlaceholder"),
                text: $videoType,
                values: videoTypeValues
            )

            dateRow(
                title: appState.localized("board.classification.targetDate"),
                enabled: $hasTargetDate,
                date: $targetDate
            )
            dateRow(
                title: appState.localized("board.classification.publishDate"),
                enabled: $hasPublishDate,
                date: $publishDate
            )
        }
    }

    private func dateRow(title: String, enabled: Binding<Bool>, date: Binding<Date>) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: enabled) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .frame(width: 142, alignment: .leading)

            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .disabled(!enabled.wrappedValue)

            Spacer(minLength: 0)
        }
    }
}

/// Text field with a short, keyboard-free suggestion list under it. Values are
/// drawn from the editable catalog and filtered with the same diacritic-
/// insensitive matching the board filters use.
struct BoardAutocompleteField: View {
    @Environment(\.frameTheme) private var theme
    let title: String
    let placeholder: String
    @Binding var text: String
    let values: [String]
    var limit = 4

    @FocusState private var isFocused: Bool

    private var suggestions: [String] {
        // Keep the list while there is text even after focus moves to a
        // suggestion button, otherwise the button disappears before the click.
        guard isFocused || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return BoardCatalog.suggestions(in: values, for: text, limit: limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            TextField(placeholder, text: $text)
                .textFieldStyle(QuietTextFieldStyle())
                .focused($isFocused)

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { value in
                        Button {
                            text = value
                            isFocused = false
                        } label: {
                            Text(value)
                                .font(.system(size: 11.5))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(theme.hover.opacity(0.75))
                        .clickableCursor()
                    }
                }
                .background(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

// MARK: - Sheet

struct BoardClassificationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.frameTheme) private var theme
    let store: BoardStore
    let catalog: BoardCatalogStore

    @State private var currentSummary: BoardProjectSummary
    @State private var status: ProductionStatus
    @State private var topic: String
    @State private var videoType: String
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var hasPublishDate: Bool
    @State private var publishDate: Date
    @State private var message: String?
    @State private var isSaving = false

    init(summary: BoardProjectSummary, store: BoardStore, catalog: BoardCatalogStore) {
        self.store = store
        self.catalog = catalog
        _currentSummary = State(initialValue: summary)
        _status = State(initialValue: ProductionStatus(rawValue: summary.productionStatus.rawValue) ?? .idea)
        _topic = State(initialValue: summary.topic)
        _videoType = State(initialValue: summary.videoType)
        _hasTargetDate = State(initialValue: summary.targetDate != nil)
        _targetDate = State(initialValue: summary.targetDate ?? Date())
        _hasPublishDate = State(initialValue: summary.publishDate != nil)
        _publishDate = State(initialValue: summary.publishDate ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            BoardClassificationFields(
                status: $status,
                topic: $topic,
                videoType: $videoType,
                hasTargetDate: $hasTargetDate,
                targetDate: $targetDate,
                hasPublishDate: $hasPublishDate,
                publishDate: $publishDate,
                topicValues: BoardQuery.availableTopics(catalog: catalog.catalog, summaries: store.summaries),
                videoTypeValues: BoardQuery.availableVideoTypes(catalog: catalog.catalog, summaries: store.summaries)
            )

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(appState.localized("board.classification.saveHelp"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(appState.localized("project.unsaved.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .clickableCursor()

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(appState.localized("board.classification.save"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .clickableCursor()
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.localized("board.classification.title"))
                .font(.system(size: 18, weight: .semibold))
            Text(currentSummary.title.isEmpty ? appState.localized("project.untitled") : currentSummary.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(currentSummary.fileURL.path)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        rememberValues()

        let edit = BoardProjectEdit(
            topic: topic,
            videoType: videoType,
            productionStatus: FrameScriptDocument.ProductionStatus(rawValue: status.rawValue),
            targetDate: hasTargetDate ? targetDate : nil,
            publishDate: hasPublishDate ? publishDate : nil,
            clearsTargetDate: !hasTargetDate,
            clearsPublishDate: !hasPublishDate
        )
        let outcome = await store.apply(edit, to: currentSummary, appState: appState)
        switch outcome {
        case .saved:
            dismiss()
        case .conflict(let refreshed):
            if let refreshed {
                currentSummary = refreshed
                sync(from: refreshed)
            }
            message = appState.localized("board.error.conflict")
        case .failed:
            message = appState.localized("board.error.write")
        }
    }

    private func rememberValues() {
        var updated = catalog.catalog
        if !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.addTopic(topic)
        }
        if !videoType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.addVideoType(videoType)
        }
        if updated != catalog.catalog {
            catalog.catalog = updated
        }
    }

    private func sync(from summary: BoardProjectSummary) {
        status = ProductionStatus(rawValue: summary.productionStatus.rawValue) ?? .idea
        topic = summary.topic
        videoType = summary.videoType
        hasTargetDate = summary.targetDate != nil
        targetDate = summary.targetDate ?? Date()
        hasPublishDate = summary.publishDate != nil
        publishDate = summary.publishDate ?? Date()
    }
}

// MARK: - Project info section

/// Compact classification editor shown inside the existing project-info
/// popover, so the same fields can be edited from the project and the board.
struct BoardProjectInfoSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let catalog: BoardCatalogStore

    @State private var topic = ""
    @State private var videoType = ""
    @State private var status: ProductionStatus = .idea
    @State private var hasTargetDate = false
    @State private var targetDate = Date()
    @State private var hasPublishDate = false
    @State private var publishDate = Date()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                Text(appState.localized("board.projectInfo.title"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }

            BoardClassificationFields(
                status: statusBinding,
                topic: topicBinding,
                videoType: videoTypeBinding,
                hasTargetDate: targetBinding,
                targetDate: targetDateBinding,
                hasPublishDate: publishBinding,
                publishDate: publishDateBinding,
                topicValues: topicValues,
                videoTypeValues: videoTypeValues
            )

            Text(appState.localized("board.projectInfo.help"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
        .onChange(of: appState.project.id) { _, _ in load() }
    }

    /// The catalog plus the values already used by the open project.
    private var topicValues: [String] {
        merged(catalog.catalog.topics, BoardProjectTopic.display(from: appState.project.topic))
    }

    private var videoTypeValues: [String] {
        merged(catalog.catalog.videoTypes, appState.project.videoType)
    }

    private func merged(_ values: [String], _ extra: String) -> [String] {
        var result = values
        let trimmed = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           !result.contains(where: { BoardCatalog.matches($0, trimmed) }) {
            result.append(trimmed)
        }
        return result.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func load() {
        let project = appState.project
        status = project.productionStatus
        topic = BoardProjectTopic.display(from: project.topic)
        videoType = project.videoType
        hasTargetDate = project.targetDate != nil
        targetDate = project.targetDate ?? Date()
        hasPublishDate = project.publishDate != nil
        publishDate = project.publishDate ?? Date()
    }

    private var statusBinding: Binding<ProductionStatus> {
        Binding(
            get: { status },
            set: { value in
                status = value
                appState.setProjectProductionStatus(value)
            }
        )
    }

    private var topicBinding: Binding<String> {
        Binding(
            get: { topic },
            set: { value in
                topic = value
                appState.setProjectTopic(value)
            }
        )
    }

    private var videoTypeBinding: Binding<String> {
        Binding(
            get: { videoType },
            set: { value in
                videoType = value
                appState.setProjectVideoType(value)
            }
        )
    }

    private var targetBinding: Binding<Bool> {
        Binding(
            get: { hasTargetDate },
            set: { enabled in
                hasTargetDate = enabled
                appState.setProjectTargetDate(enabled ? targetDate : nil)
            }
        )
    }

    private var targetDateBinding: Binding<Date> {
        Binding(
            get: { targetDate },
            set: { value in
                targetDate = value
                guard hasTargetDate else { return }
                appState.setProjectTargetDate(value)
            }
        )
    }

    private var publishBinding: Binding<Bool> {
        Binding(
            get: { hasPublishDate },
            set: { enabled in
                hasPublishDate = enabled
                appState.setProjectPublishDate(enabled ? publishDate : nil)
            }
        )
    }

    private var publishDateBinding: Binding<Date> {
        Binding(
            get: { publishDate },
            set: { value in
                publishDate = value
                guard hasPublishDate else { return }
                appState.setProjectPublishDate(value)
            }
        )
    }

}
