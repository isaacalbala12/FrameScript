import AppKit
import FrameScriptCore
import SwiftUI
import UniformTypeIdentifiers

struct PublishingExportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let language: String

    @State private var copied = false
    @State private var saved = false

    private var markdown: String {
        appState.publishingExportMarkdown(language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.localized("publishing.export.title"))
                        .font(.system(size: 19, weight: .semibold))
                    Text(appState.localized("publishing.export.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if saved {
                    Label(appState.localized("publishing.export.saved"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.success)
                }
            }

            ScrollView {
                Text(markdown)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.editorSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(appState.localized("publishing.export.descriptionNote"))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(appState.localized("publishing.close")) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button(appState.localized("publishing.export.copyStudioDescription")) {
                    appState.copyPublishingText(appState.publishingStudioDescription(language: language))
                }
                .buttonStyle(.bordered)

                Button {
                    appState.copyPublishingText(markdown)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Label(
                        appState.localized(copied ? "publishing.copied" : "publishing.export.copyAll"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button(appState.localized("publishing.export.save")) {
                    saveFile()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent.color)
            }
        }
        .padding(22)
        .frame(width: 760, height: 560)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("publishing-export-sheet")
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = String(
            format: appState.localized("publishing.export.fileName"),
            appState.project.title
        )
        if let folder = appState.resolvedDefaultExportFolder() {
            let didStart = folder.startAccessingSecurityScopedResource()
            defer {
                if didStart { folder.stopAccessingSecurityScopedResource() }
            }
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.savePublishingExport(language: language, to: url)
        saved = true
    }
}
