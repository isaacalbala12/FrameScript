import AppKit
import FrameScriptCore
import SwiftUI
import UniformTypeIdentifiers

struct ResearchTablesTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable private var presentation = ResearchPresentation.shared

    var body: some View {
        HStack(spacing: 0) {
            tableList
                .frame(width: 236)

            Divider().overlay(theme.divider)

            if let table = selectedTable {
                ResearchTableEditor(table: table)
                    .id(table.id)
            } else {
                ResearchEmptyState(
                    title: appState.localized("research.tables.empty.title"),
                    message: appState.localized("research.tables.empty.message"),
                    actionTitle: appState.localized("research.tables.add")
                ) {
                    addTable()
                }
            }
        }
    }

    private var selectedTable: ComparisonTable? {
        guard let id = presentation.selectedTableID else { return nil }
        return appState.project.comparisonTables.first(where: { $0.id == id })
    }

    private func addTable() {
        let column = appState.localized("research.tables.column")
        _ = appState.addComparisonTable(
            title: appState.localized("research.tables.untitled"),
            header: ["\(column) 1", "\(column) 2"]
        )
    }

    private var tableList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appState.localized("research.tab.tables"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button {
                    addTable()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.cursorPlain)
                .help(appState.localized("research.tables.add"))
                .accessibilityLabel(appState.localized("research.tables.add"))
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider().overlay(theme.divider)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(appState.project.comparisonTables) { table in
                        tableRow(table)
                    }
                }
                .padding(8)
            }
        }
        .background(theme.sidebarBackground.opacity(0.4))
    }

    private func tableRow(_ table: ComparisonTable) -> some View {
        let isSelected = presentation.selectedTableID == table.id
        return Button {
            presentation.selectedTableID = table.id
            presentation.resetPaste()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(table.title.isEmpty ? appState.localized("research.tables.untitled") : table.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(String(format: appState.localized("research.tables.sizeSummary"), table.rows.count, table.header.count))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                    if let sceneID = table.sceneID {
                        Text("· \(appState.sceneTitle(for: sceneID))")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.selection : Color.clear)
            }
        }
        .buttonStyle(.cursorPlain)
    }
}

private struct ResearchTableEditor: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable private var presentation = ResearchPresentation.shared
    let table: ComparisonTable
    @State private var isConfirmingDelete = false

    private let cellWidth: CGFloat = 132
    private let labelWidth: CGFloat = 30

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleBar
                sceneBar
                grid
                issuesSection
                pasteSection
                exportBar
            }
            .padding(16)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            TextField(appState.localized("research.tables.title"), text: title)
                .textFieldStyle(QuietTextFieldStyle())
                .font(.system(size: 14, weight: .semibold))

            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.tertiaryText)
            .help(appState.localized("research.tables.delete"))
        }
        .alert(appState.localized("research.tables.deleteConfirmTitle"), isPresented: $isConfirmingDelete) {
            Button(appState.localized("research.tables.delete"), role: .destructive) {
                appState.deleteComparisonTable(id: table.id)
            }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) {}
        } message: {
            Text(appState.localized("research.tables.deleteConfirmMessage"))
        }
    }

    private var sceneBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    update { $0.sceneID = nil }
                } label: {
                    if table.sceneID == nil {
                        Label(appState.localized("research.tables.noScene"), systemImage: "checkmark")
                    } else {
                        Text(appState.localized("research.tables.noScene"))
                    }
                }
                Divider()
                ForEach(appState.project.scenes.sortedByOrder) { scene in
                    Button {
                        update { $0.sceneID = scene.id }
                    } label: {
                        if table.sceneID == scene.id {
                            Label(scene.title, systemImage: "checkmark")
                        } else {
                            Text(scene.title)
                        }
                    }
                }
            } label: {
                Label(
                    table.sceneID.map(appState.sceneTitle(for:)) ?? appState.localized("research.tables.noScene"),
                    systemImage: "film"
                )
                .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 240)

            Button {
                if appState.addComparisonTableCue(tableID: table.id) {
                    presentation.statusMessage = appState.localized("research.tables.cueAdded")
                } else {
                    presentation.statusMessage = appState.localized("research.tables.cueAlreadyPresent")
                }
            } label: {
                Label(appState.localized("research.tables.cue"), systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.cursorPlain)
            .disabled(table.sceneID == nil)
            .help(appState.localized("research.tables.cueHelp"))

            Spacer()
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView([.horizontal]) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Color.clear.frame(width: labelWidth, height: 1)
                        ForEach(Array(table.header.indices), id: \.self) { column in
                            headerCell(column)
                        }
                        Button {
                            appState.addComparisonTableColumn(id: table.id)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 22, height: 26)
                        }
                        .buttonStyle(.cursorPlain)
                        .foregroundStyle(theme.secondaryText)
                        .help(appState.localized("research.tables.addColumn"))
                    }

                    ForEach(Array(table.rows.indices), id: \.self) { row in
                        HStack(spacing: 5) {
                            Text("\(row + 1)")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                                .frame(width: labelWidth, alignment: .trailing)
                                .padding(.trailing, 2)

                            ForEach(Array(table.header.indices), id: \.self) { column in
                                cell(row: row, column: column)
                            }

                            Button {
                                appState.removeComparisonTableRow(id: table.id, at: row)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 10))
                                    .frame(width: 22, height: 26)
                            }
                            .buttonStyle(.cursorPlain)
                            .foregroundStyle(theme.tertiaryText)
                            .help(appState.localized("research.tables.removeRow"))
                        }
                    }
                }
                .padding(.bottom, 2)
            }

            HStack(spacing: 8) {
                Button {
                    appState.addComparisonTableRow(id: table.id)
                } label: {
                    Label(appState.localized("research.tables.addRow"), systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.cursorPlain)

                Button {
                    appState.addComparisonTableColumn(id: table.id)
                } label: {
                    Label(appState.localized("research.tables.addColumn"), systemImage: "plus.rectangle.on.rectangle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.cursorPlain)

                Spacer()

                if !table.header.isEmpty {
                    Menu {
                        ForEach(Array(table.header.indices), id: \.self) { column in
                            Button(String(format: appState.localized("research.tables.removeColumnNumber"), column + 1)) {
                                appState.removeComparisonTableColumn(id: table.id, at: column)
                            }
                        }
                    } label: {
                        Label(appState.localized("research.tables.removeColumn"), systemImage: "minus.circle")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 190)
                }
            }
        }
    }

    private func headerCell(_ column: Int) -> some View {
        HStack(spacing: 2) {
            TextField(
                appState.localized("research.tables.column"),
                text: Binding(
                    get: { table.header.indices.contains(column) ? table.header[column] : "" },
                    set: { value in
                        update { copy in
                            guard copy.header.indices.contains(column) else { return }
                            copy.header[column] = value
                        }
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 28)
        }
        .frame(width: cellWidth)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.sidebarBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func cell(row: Int, column: Int) -> some View {
        TextField(
            appState.localized("research.tables.cell"),
            text: Binding(
                get: {
                    guard table.rows.indices.contains(row),
                          table.rows[row].indices.contains(column) else { return "" }
                    return table.rows[row][column]
                },
                set: { value in
                    update { copy in
                        guard copy.rows.indices.contains(row),
                              copy.rows[row].indices.contains(column) else { return }
                        copy.rows[row][column] = value
                    }
                }
            )
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .frame(width: cellWidth, height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let issues = appState.tableValidationIssues(table)
        let emptyCells = issues.filter {
            if case .emptyCell = $0 { return true }
            return false
        }.count
        let others = issues.filter {
            if case .emptyCell = $0 { return false }
            return true
        }

        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                    Text(appState.localized("research.tables.validation"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                ForEach(Array(others.prefix(6).enumerated()), id: \.offset) { _, issue in
                    Text(researchIssueText(issue, appState: appState))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                if emptyCells > 0 {
                    Text(String(format: appState.localized("research.tables.emptyCellCount"), emptyCells))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.warning.opacity(0.08))
            }
        }
    }

    private var pasteSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                MultilineField(
                    placeholder: appState.localized("research.tables.pastePlaceholder"),
                    text: $presentation.pasteText,
                    minHeight: 80
                )

                HStack(spacing: 8) {
                    Button(appState.localized("research.tables.pasteAnalyze")) {
                        appState.parseComparisonTablePaste()
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(presentation.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let format = presentation.pasteFormat {
                        Text(String(
                            format: appState.localized("research.tables.pasteDetected"),
                            researchPasteFormatLabel(format, appState: appState)
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.accent.color)

                        if let result = presentation.pasteResult {
                            Text(String(
                                format: appState.localized("research.tables.pasteSize"),
                                result.rows.count,
                                result.columnCount
                            ))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        }
                    }

                    Spacer()

                    Button(appState.localized("research.tables.pasteApply")) {
                        guard let result = presentation.pasteResult else { return }
                        appState.applyComparisonTablePaste(id: table.id, result: result)
                        presentation.resetPaste()
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(presentation.pasteResult == nil)
                }

                if let error = presentation.pasteErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                }

                if !presentation.pasteIssues.isEmpty {
                    Text(String(
                        format: appState.localized("research.tables.pasteIssues"),
                        presentation.pasteIssues.count
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                    ForEach(Array(presentation.pasteIssues.prefix(4).enumerated()), id: \.offset) { _, issue in
                        Text(researchIssueText(issue, appState: appState))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Text(appState.localized("research.tables.paste"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            Button(appState.localized("research.tables.copyMarkdown")) {
                copyToPasteboard(appState.comparisonTableDocument(table))
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11, weight: .medium))

            Button(appState.localized("research.tables.exportMarkdown")) {
                save(
                    contents: appState.comparisonTableDocument(table),
                    name: fileName(extension: "md"),
                    type: UTType(filenameExtension: "md") ?? .plainText
                )
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11, weight: .medium))

            Button(appState.localized("research.tables.exportCSV")) {
                save(
                    contents: appState.comparisonTableCSV(table),
                    name: fileName(extension: "csv"),
                    type: .commaSeparatedText
                )
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11, weight: .medium))

            Spacer()
        }
    }

    private var title: Binding<String> {
        Binding(
            get: { table.title },
            set: { value in
                update { $0.title = value }
            }
        )
    }

    private func update(_ transform: (inout ComparisonTable) -> Void) {
        var copy = table
        transform(&copy)
        appState.updateComparisonTable(copy)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        presentation.statusMessage = appState.localized("research.tables.copied")
    }

    private func save(contents: String, name: String, type: UTType) {
        guard !contents.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            presentation.statusMessage = appState.localized("research.tables.saved")
        } catch {
            presentation.statusMessage = appState.localized("research.tables.exportFailed")
        }
    }

    private func fileName(extension fileExtension: String) -> String {
        let base = table.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? appState.localized("research.tables.untitled") : base
        return "\(safe.replacingOccurrences(of: "/", with: "-")).\(fileExtension)"
    }
}
