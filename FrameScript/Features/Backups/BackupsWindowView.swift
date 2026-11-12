import FrameScriptCore
import SwiftUI

/// Observable presentation flag for the backups sheet. A tiny standalone model
/// keeps the feature out of the shared window state.
@MainActor
@Observable
final class BackupsPresentation {
    static let shared = BackupsPresentation()
    var isPresented = false
    private init() {}
}

/// Attaches the backups sheet to the main window. Called once from
/// `FrameScriptApp.swift`.
struct BackupsSheetModifier: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        @Bindable var presentation = BackupsPresentation.shared
        content.sheet(isPresented: $presentation.isPresented) {
            BackupsWindowView()
                .environment(appState)
                .environment(\.frameTheme, appState.themeManager.frameTheme)
        }
    }
}

extension View {
    func backupsSheet(_ appState: AppState) -> some View {
        modifier(BackupsSheetModifier(appState: appState))
    }
}

struct BackupsWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [BackupEntry] = []
    @State private var loadFailed = false
    @State private var statusMessage: String?
    @State private var pendingRestore: BackupEntry?

    var body: some View {
        @Bindable var health = BackupHealth.shared
        VStack(alignment: .leading, spacing: 14) {
            header

            if let failure = health.lastFailure {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(appState.localized("backups.warning.lastFailure"))
                    Spacer()
                    Text(failure.operation.rawValue)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.warning)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.warning.opacity(0.12))
                }
            }

            Group {
                if appState.currentProjectFileURL == nil {
                    untitledState
                } else if entries.isEmpty {
                    emptyState
                } else {
                    backupList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }

            footer
        }
        .padding(24)
        .frame(width: 760, height: 520)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear(perform: reload)
        .alert(
            appState.localized("backups.restore.title"),
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { entry in
            Button(appState.localized("backups.restore.confirm"), role: .destructive) {
                restore(entry)
            }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) {
                pendingRestore = nil
            }
        } message: { _ in
            Text(appState.localized("backups.restore.message"))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized("backups.title"))
                    .font(.system(size: 21, weight: .semibold))
                Text(appState.localized("backups.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                if let url = appState.currentProjectFileURL {
                    Text(url.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            Button {
                reload()
            } label: {
                Label(appState.localized("backups.refresh"), systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(appState.localized("backups.refresh"))
            .clickableCursor()
        }
    }

    private var untitledState: some View {
        emptyMessage(
            title: appState.localized("project.untitled"),
            message: appState.localized("backups.untitled")
        )
    }

    private var emptyState: some View {
        emptyMessage(
            title: appState.localized("backups.emptyTitle"),
            message: loadFailed
                ? appState.localized("backups.error.message")
                : appState.localized("backups.emptyMessage")
        )
    }

    private func emptyMessage(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(theme.tertiaryText)
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backupList: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                Text(appState.localized("backups.column.date"))
                Text(appState.localized("backups.column.original"))
                Spacer()
                Text(appState.localized("backups.column.size"))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.tertiaryText)
            .textCase(.uppercase)
            .padding(.horizontal, 10)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(entries) { entry in
                        backupRow(entry)
                    }
                }
            }
        }
    }

    private func backupRow(_ entry: BackupEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(size: 13, weight: .medium))
                Text(entry.originalFileName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Text(entry.originalPath ?? appState.localized("backups.originalUnknown"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(sizeText(entry.byteSize))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(minWidth: 64, alignment: .trailing)

            Button(appState.localized("backups.openAsCopy")) {
                openAsCopy(entry)
            }
            .help(appState.localized("backups.openAsCopy.help"))
            .clickableCursor()

            Button(appState.localized("backups.restore")) {
                pendingRestore = entry
            }
            .help(appState.localized("backups.restore.help"))
            .clickableCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(appState.localized("backups.close")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .clickableCursor()
        }
    }

    private func reload() {
        statusMessage = nil
        guard let projectID = appState.currentBackupProjectID else {
            entries = []
            loadFailed = false
            return
        }
        let listing = BackupsCenter.store.listing(projectID: projectID)
        entries = listing.entries
        loadFailed = !listing.failures.isEmpty
    }

    private func openAsCopy(_ entry: BackupEntry) {
        if appState.openBackupAsCopy(entry) {
            dismiss()
        }
    }

    private func restore(_ entry: BackupEntry) {
        pendingRestore = nil
        if appState.restoreBackup(entry) {
            statusMessage = appState.localized("backups.restore.done")
            reload()
        } else {
            statusMessage = appState.localized("backups.restore.failed")
        }
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
