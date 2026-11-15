import AppKit
import FrameScriptCore
import SwiftUI

/// Settings → Tablero. Library folders, the editable game/type catalog and the
/// explicit Plane connection used by the export sheet.
struct BoardSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable var store: BoardStore
    @Bindable var catalog: BoardCatalogStore
    @Bindable var plane: PlaneSettingsStore

    @State private var newTopic = ""
    @State private var newVideoType = ""
    @State private var tokenField = ""
    @State private var tokenMessage: String?
    @State private var showTokenField = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            librarySection
            catalogSection
            planeSection
        }
        .onAppear {
            store.loadFolders()
            plane.refreshTokenStatus()
        }
    }

    // MARK: Library

    private var librarySection: some View {
        SettingsSection(title: appState.localized("board.settings.library")) {
            SettingsRow(
                appState.localized("board.settings.folders"),
                help: appState.localized("board.settings.foldersHelp")
            ) {
                Button {
                    addFolders()
                } label: {
                    Label(appState.localized("board.addFolder"), systemImage: "folder.badge.plus")
                }
                .clickableCursor()
            }

            ForEach(store.resolvedFolders(), id: \.folder.id) { resolved in
                SettingsRow(resolved.folder.displayName) {
                    HStack(spacing: 8) {
                        Text(resolved.folder.lastKnownPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(
                                FileManager.default.fileExists(atPath: resolved.folder.lastKnownPath)
                                    ? theme.tertiaryText
                                    : theme.warning
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 330, alignment: .trailing)
                        Button {
                            store.removeFolder(id: resolved.folder.id)
                            Task { await store.refresh(appState: appState) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(appState.localized("board.settings.removeFolder"))
                        .clickableCursor()
                    }
                }
            }

            SettingsRow(appState.localized("board.settings.recents")) {
                Text(appState.localized("board.settings.recentsValue"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
            }

            SettingsRow(appState.localized("board.settings.open")) {
                Button(appState.localized("board.action.open")) {
                    appState.showBoardWindow()
                }
                .clickableCursor()
            }
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = appState.localized("board.addFolder.message")
        guard panel.runModal() == .OK else { return }
        var changed = false
        for url in panel.urls {
            if (try? store.addFolder(at: url)) == true {
                changed = true
            }
        }
        if changed {
            Task { await store.refresh(appState: appState) }
        }
    }

    // MARK: Catalog

    private var catalogSection: some View {
        SettingsSection(
            title: appState.localized("board.settings.catalog"),
            resetTitle: appState.localized("board.settings.restoreSeeds"),
            resetAction: { catalog.resetToSeeds() }
        ) {
            SettingsRow(
                appState.localized("board.settings.topics"),
                help: appState.localized("board.settings.topicsHelp")
            ) {
                addValueRow(
                    text: $newTopic,
                    placeholder: appState.localized("board.settings.addTopic"),
                    action: addTopic
                )
            }

            chipsRow(catalog.catalog.topics) { topic in
                var updated = catalog.catalog
                updated.removeTopic(topic)
                catalog.catalog = updated
            }

            SettingsRow(
                appState.localized("board.settings.videoTypes"),
                help: appState.localized("board.settings.videoTypesHelp")
            ) {
                addValueRow(
                    text: $newVideoType,
                    placeholder: appState.localized("board.settings.addVideoType"),
                    action: addVideoType
                )
            }

            chipsRow(catalog.catalog.videoTypes) { type in
                var updated = catalog.catalog
                updated.removeVideoType(type)
                catalog.catalog = updated
            }
        }
    }

    private func addValueRow(
        text: Binding<String>,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: text)
                .textFieldStyle(QuietTextFieldStyle())
                .frame(width: 190)
                .onSubmit(action)
            Button(action: action) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .clickableCursor()
        }
    }

    private func chipsRow(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 5) {
                    Text(value)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Button {
                        remove(value)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .buttonStyle(.borderless)
                    .help(appState.localized("board.settings.removeValue"))
                    .clickableCursor()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(theme.cardBackground, in: Capsule())
                .overlay(Capsule().stroke(theme.divider, lineWidth: 1))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }

    private func addTopic() {
        var updated = catalog.catalog
        guard updated.addTopic(newTopic) else { return }
        catalog.catalog = updated
        newTopic = ""
    }

    private func addVideoType() {
        var updated = catalog.catalog
        guard updated.addVideoType(newVideoType) else { return }
        catalog.catalog = updated
        newVideoType = ""
    }

    // MARK: Plane

    private var planeSection: some View {
        SettingsSection(title: appState.localized("board.settings.plane")) {
            SettingsRow(
                appState.localized("board.settings.plane.baseURL"),
                help: appState.localized("board.settings.plane.baseURLHelp")
            ) {
                TextField(
                    appState.localized("board.settings.plane.baseURLPlaceholder"),
                    text: $plane.settings.baseURL
                )
                .textFieldStyle(QuietTextFieldStyle())
                .frame(width: 300)
            }

            SettingsRow(
                appState.localized("board.settings.plane.workspace"),
                help: appState.localized("board.settings.plane.workspaceHelp")
            ) {
                TextField(
                    appState.localized("board.settings.plane.workspacePlaceholder"),
                    text: $plane.settings.workspaceSlug
                )
                .textFieldStyle(QuietTextFieldStyle())
                .frame(width: 250)
            }

            SettingsRow(
                appState.localized("board.settings.plane.project"),
                help: appState.localized("board.settings.plane.projectHelp")
            ) {
                TextField(
                    appState.localized("board.settings.plane.projectPlaceholder"),
                    text: $plane.settings.projectID
                )
                .textFieldStyle(QuietTextFieldStyle())
                .frame(width: 330)
            }

            SettingsRow(
                appState.localized("board.settings.plane.token"),
                help: appState.localized("board.settings.plane.tokenHelp")
            ) {
                HStack(spacing: 8) {
                    if showTokenField {
                        SecureField(
                            appState.localized("board.settings.plane.tokenPlaceholder"),
                            text: $tokenField
                        )
                        .textFieldStyle(QuietTextFieldStyle())
                        .frame(width: 220)
                        .onSubmit(saveToken)
                        Button(appState.localized("board.settings.plane.saveToken")) {
                            saveToken()
                        }
                        .clickableCursor()
                    } else {
                        Text(
                            plane.hasStoredToken
                                ? appState.localized("board.settings.plane.tokenStored")
                                : appState.localized("board.settings.plane.tokenMissing")
                        )
                        .font(.system(size: 11.5))
                        .foregroundStyle(plane.hasStoredToken ? theme.success : theme.warning)
                    }

                    Button(plane.hasStoredToken
                        ? appState.localized("board.settings.plane.replaceToken")
                        : appState.localized("board.settings.plane.addToken")
                    ) {
                        showTokenField.toggle()
                    }
                    .clickableCursor()

                    if plane.hasStoredToken {
                        Button(appState.localized("board.settings.plane.deleteToken"), role: .destructive) {
                            deleteToken()
                        }
                        .clickableCursor()
                    }
                }
            }

            if let tokenMessage {
                Text(tokenMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            Text(appState.localized("board.settings.plane.privacy"))
                .font(.system(size: 10.5))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private func saveToken() {
        do {
            try plane.saveToken(tokenField)
            tokenField = ""
            showTokenField = false
            tokenMessage = appState.localized("board.settings.plane.tokenSaved")
        } catch {
            tokenMessage = appState.localized("board.settings.plane.tokenError")
        }
    }

    private func deleteToken() {
        do {
            try plane.deleteStoredToken()
            tokenMessage = appState.localized("board.settings.plane.tokenDeleted")
        } catch {
            tokenMessage = appState.localized("board.settings.plane.tokenError")
        }
    }
}
