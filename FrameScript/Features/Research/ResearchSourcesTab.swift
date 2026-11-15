import AppKit
import FrameScriptCore
import SwiftUI

struct ResearchSourcesTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(String(format: appState.localized("research.sources.summary"), appState.project.sources.count))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button {
                    appState.addResearchSource()
                } label: {
                    Label(appState.localized("research.sources.add"), systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.cursorPlain)
                .accessibilityIdentifier("research-add-source")
            }
            .padding(.horizontal, 20)
            .frame(height: 48)

            Divider().overlay(theme.divider)

            if appState.project.sources.isEmpty {
                ResearchEmptyState(
                    title: appState.localized("research.sources.empty.title"),
                    message: appState.localized("research.sources.empty.message"),
                    actionTitle: appState.localized("research.sources.add")
                ) {
                    appState.addResearchSource()
                }
            } else {
                let usage = appState.researchSourceUsage()
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.project.sources) { source in
                            ResearchSourceCard(
                                source: source,
                                usage: usage[source.id, default: 0]
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct ResearchSourceCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let source: ProjectSource
    let usage: Int
    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField(appState.localized("research.sources.titlePlaceholder"), text: title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))

                Spacer(minLength: 8)

                Picker("", selection: kind) {
                    ForEach(SourceKind.allCases) { kind in
                        Text(appState.localized(kind.researchLocalizationKey)).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .help(appState.localized("research.sources.type"))

                Picker("", selection: reliability) {
                    ForEach(SourceReliability.allCases) { reliability in
                        Text(appState.localized(reliability.researchLocalizationKey)).tag(reliability)
                    }
                }
                .labelsHidden()
                .frame(width: 104)
                .help(appState.localized("research.sources.reliability"))

                reliabilityDot

                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(isHovered ? theme.destructive : theme.tertiaryText)
                .help(appState.localized("research.sources.delete"))
                .accessibilityLabel(appState.localized("research.sources.delete"))
            }

            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                TextField(appState.localized("research.sources.urlPlaceholder"), text: url)
                    .textFieldStyle(QuietTextFieldStyle())
                    .font(.system(size: 12))
                Button {
                    if let link = ResearchLinks.validURL(from: source.url) {
                        NSWorkspace.shared.open(link)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(ResearchLinks.validURL(from: source.url) == nil ? theme.tertiaryText : theme.accent.color)
                .disabled(ResearchLinks.validURL(from: source.url) == nil)
                .help(appState.localized("research.sources.open"))
                .accessibilityLabel(appState.localized("research.sources.open"))

                dateControl
            }

            if !source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               ResearchLinks.validURL(from: source.url) == nil {
                Label(appState.localized("research.sources.invalidURL"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
            }

            MultilineField(
                placeholder: appState.localized("research.sources.notesPlaceholder"),
                text: note,
                minHeight: 54
            )

            HStack(spacing: 6) {
                Text(String(format: appState.localized("research.sources.usedBy"), usage))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                Spacer()
                if let host = ResearchLinks.displayHost(from: source.url) {
                    Text(host)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHovered ? theme.divider : theme.divider.opacity(0.6), lineWidth: 1)
                )
        }
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("research-source-card-\(source.id.uuidString)")
        .alert(appState.localized("research.sources.deleteConfirmTitle"), isPresented: $isConfirmingDelete) {
            Button(appState.localized("research.sources.delete"), role: .destructive) {
                appState.deleteResearchSource(id: source.id)
            }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) {}
        } message: {
            Text(appState.localized("research.sources.deleteConfirmMessage"))
        }
    }

    private var reliabilityDot: some View {
        Circle()
            .fill(reliabilityColor)
            .frame(width: 8, height: 8)
            .help(appState.localized(source.reliability.researchLocalizationKey))
    }

    private var reliabilityColor: Color {
        switch source.reliability {
        case .high: theme.success
        case .medium: theme.warning
        case .low: theme.destructive
        }
    }

    @ViewBuilder
    private var dateControl: some View {
        if let date = source.date {
            HStack(spacing: 4) {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { date },
                        set: { newValue in
                            var copy = source
                            copy.date = newValue
                            appState.updateResearchSource(copy)
                        }
                    ),
                    displayedComponents: .date
                )
                .labelsHidden()
                .datePickerStyle(.compact)
                .frame(width: 102)

                Button {
                    var copy = source
                    copy.date = nil
                    appState.updateResearchSource(copy)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.tertiaryText)
                .help(appState.localized("research.sources.clearDate"))
            }
        } else {
            Button {
                var copy = source
                copy.date = Date()
                appState.updateResearchSource(copy)
            } label: {
                Label(appState.localized("research.sources.addDate"), systemImage: "calendar")
                    .font(.system(size: 11))
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var title: Binding<String> {
        Binding(
            get: { source.title },
            set: { value in
                var copy = source
                copy.title = value
                appState.updateResearchSource(copy)
            }
        )
    }

    private var url: Binding<String> {
        Binding(
            get: { source.url },
            set: { value in
                var copy = source
                copy.url = value
                appState.updateResearchSource(copy)
            }
        )
    }

    private var note: Binding<String> {
        Binding(
            get: { source.note },
            set: { value in
                var copy = source
                copy.note = value
                appState.updateResearchSource(copy)
            }
        )
    }

    private var kind: Binding<SourceKind> {
        Binding(
            get: { source.kind },
            set: { value in
                var copy = source
                copy.kind = value
                appState.updateResearchSource(copy)
            }
        )
    }

    private var reliability: Binding<SourceReliability> {
        Binding(
            get: { source.reliability },
            set: { value in
                var copy = source
                copy.reliability = value
                appState.updateResearchSource(copy)
            }
        )
    }
}
