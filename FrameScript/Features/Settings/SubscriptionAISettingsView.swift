import AppKit
import FrameScriptCore
import SwiftUI

/// F12 settings: one selection per task, the shared T3 project, the timeout,
/// a connection probe and the D2 thread controls.
struct SubscriptionAISettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var store = SubscriptionAISettingsStore.shared
    @State private var runtime = SubscriptionAIRuntime.shared
    @State private var status = ""
    @State private var isTesting = false
    @State private var isCreatingProject = false
    @State private var showsCreateConfirmation = false

    var body: some View {
        @Bindable var store = store

        SettingsSection(title: appState.localized("settings.ai.subscription"), resetAction: {
            store.reset()
            status = ""
        }) {
            SettingsRow(appState.localized("settings.ai.subscription.privacyTitle"), help: appState.localized("settings.ai.subscription.subtitle")) {
                Text(appState.localized("settings.ai.subscription.privacy"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430, alignment: .trailing)
            }

            SettingsRow(appState.localized("settings.ai.subscription.useForAll")) {
                Toggle("", isOn: Binding(
                    get: { store.settings.useForAllTasks },
                    set: { store.settings.setUseForAllTasks($0) }
                ))
                .labelsHidden()
            }

            SettingsRow(appState.localized("settings.ai.subscription.defaultSelection")) {
                VStack(alignment: .trailing, spacing: 8) {
                    selectionEditor($store.settings.defaultSelection)
                    SubscriptionAIThreadControls(selection: store.settings.defaultSelection)
                    if !appState.hasOpenProject {
                        Text(appState.localized("settings.ai.subscription.noProject"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !store.settings.useForAllTasks {
                ForEach(SubscriptionAITask.allCases) { task in
                    SettingsRow(appState.localized("aiTask.\(task.rawValue)")) {
                        VStack(alignment: .trailing, spacing: 8) {
                            Toggle(appState.localized("settings.ai.subscription.custom"), isOn: customBinding(for: task))
                                .toggleStyle(.switch)
                                .controlSize(.mini)

                            if store.settings.hasOverride(for: task) {
                                selectionEditor(taskSelectionBinding(for: task))
                                SubscriptionAIThreadControls(selection: store.settings.taskSelections[task.rawValue] ?? store.settings.defaultSelection)
                            } else {
                                Text(selectionSummary(store.settings.defaultSelection))
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                        }
                    }
                }
            }

            SettingsRow(appState.localized("settings.ai.subscription.t3Project")) {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(appState.localized("settings.ai.subscription.t3ProjectID"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("", text: optionalText($store.settings.t3Project.id), prompt: Text(verbatim: "a1b2c3d4-…"))
                            .textFieldStyle(QuietTextFieldStyle())
                            .frame(width: 230)
                    }

                    HStack(spacing: 8) {
                        Text(appState.localized("settings.ai.subscription.t3ProjectPath"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("", text: optionalText($store.settings.t3Project.path), prompt: Text(verbatim: "~/Documents/FrameScript IA"))
                            .textFieldStyle(QuietTextFieldStyle())
                            .frame(width: 230)
                        Button(appState.localized("settings.ai.subscription.chooseFolder")) {
                            chooseProjectFolder()
                        }
                        .clickableCursor()
                    }

                    Button(appState.localized("settings.ai.subscription.createProject")) {
                        requestCreateProject()
                    }
                    .disabled(isCreatingProject)
                    .clickableCursor(enabled: !isCreatingProject)
                }
            }

            SettingsRow(appState.localized("settings.ai.subscription.timeout"), help: appState.localized("settings.ai.subscription.timeoutHelp")) {
                Stepper(
                    "\(Int(store.settings.defaultTimeout)) s",
                    value: $store.settings.defaultTimeout,
                    in: 30...900,
                    step: 15
                )
                .frame(width: 140)
            }

            SettingsRow("") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button(appState.localized("settings.ai.subscription.probe")) {
                            Task { await testConnection() }
                        }
                        .disabled(isTesting || runtime.isRunning)
                        .clickableCursor(enabled: !isTesting && !runtime.isRunning)

                        if !status.isEmpty {
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    SubscriptionAIProgressView(runtime: runtime)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert(appState.localized("settings.ai.subscription.createProjectTitle"), isPresented: $showsCreateConfirmation) {
            Button(appState.localized("error.dismiss"), role: .cancel) {}
            Button(appState.localized("settings.ai.subscription.createProjectConfirm")) {
                Task { await createProject() }
            }
        } message: {
            Text(String(
                format: appState.localized("settings.ai.subscription.createProjectMessage"),
                store.settings.t3Project.path ?? ""
            ))
        }
    }

    // MARK: Selection editor

    private func selectionEditor(_ selection: Binding<SubscriptionAISelection>) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text(appState.localized("settings.ai.subscription.kind"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Picker("", selection: selection.kind) {
                    ForEach(AgentCLIKind.allCases, id: \.self) { kind in
                        Text(appState.localized("cliKind.\(kind.rawValue)")).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            if selection.wrappedValue.kind == .t3 {
                HStack(spacing: 8) {
                    Text(appState.localized("settings.ai.subscription.providerInstance"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    TextField("", text: selection.providerInstanceID)
                        .textFieldStyle(QuietTextFieldStyle())
                        .frame(width: 170)
                    suggestionMenu(
                        values: SubscriptionAIModelCatalog.providerInstances(for: .t3),
                        current: selection.wrappedValue.trimmedProviderInstanceID
                    ) { value in
                        selection.wrappedValue.providerInstanceID = value
                    }
                }
            }

            HStack(spacing: 8) {
                Text(appState.localized("settings.ai.subscription.model"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                TextField("", text: selection.modelSlug)
                    .textFieldStyle(QuietTextFieldStyle())
                    .frame(width: 230)
                suggestionMenu(
                    values: SubscriptionAIModelCatalog.models(
                        for: selection.wrappedValue.kind,
                        providerInstanceID: selection.wrappedValue.trimmedProviderInstanceID
                    ),
                    current: selection.wrappedValue.trimmedModelSlug
                ) { value in
                    selection.wrappedValue.modelSlug = value
                }
            }
        }
    }

    private func suggestionMenu(
        values: [String],
        current: String,
        apply: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(values, id: \.self) { value in
                Button {
                    apply(value)
                } label: {
                    if value == current {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help(appState.localized("settings.ai.subscription.suggestions"))
    }

    private func customBinding(for task: SubscriptionAITask) -> Binding<Bool> {
        Binding(
            get: { store.settings.hasOverride(for: task) },
            set: { isCustom in
                if isCustom {
                    store.settings.setSelection(store.settings.defaultSelection, for: task)
                } else {
                    store.settings.useDefault(for: task)
                }
            }
        )
    }

    private func taskSelectionBinding(for task: SubscriptionAITask) -> Binding<SubscriptionAISelection> {
        Binding(
            get: { store.settings.taskSelections[task.rawValue] ?? store.settings.defaultSelection },
            set: { store.settings.setSelection($0, for: task) }
        )
    }

    private func selectionSummary(_ selection: SubscriptionAISelection) -> String {
        let kind = appState.localized("cliKind.\(selection.kind.rawValue)")
        switch selection.kind {
        case .t3:
            return "\(kind) · \(selection.trimmedProviderInstanceID) · \(selection.trimmedModelSlug)"
        case .claude, .codex:
            return "\(kind) · \(selection.trimmedModelSlug)"
        }
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    // MARK: T3 project

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = appState.localized("settings.ai.subscription.chooseFolder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.t3Project.path = url.path
        if (store.settings.t3Project.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.settings.t3Project.name = "FrameScript IA"
        }
    }

    private func requestCreateProject() {
        if store.settings.t3Project.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            chooseProjectFolder()
        }
        guard store.settings.t3Project.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            status = appState.localized("settings.ai.subscription.projectHint")
            return
        }
        showsCreateConfirmation = true
    }

    private func createProject() async {
        guard let path = store.settings.t3Project.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            status = appState.localized("settings.ai.subscription.projectHint")
            return
        }
        isCreatingProject = true
        defer { isCreatingProject = false }
        do {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
            let resolver = try await SubscriptionAIToolchain.shared.t3ProjectResolver()
            let title = store.settings.t3Project.name ?? "FrameScript IA"
            let project = try await resolver.createProject(atPath: path, title: title)
            store.settings.t3Project = T3ProjectReference(
                id: project.id,
                path: project.path ?? path,
                name: project.title ?? title
            )
            status = appState.localized("settings.ai.subscription.projectCreated")
        } catch {
            status = ""
            appState.errorCenter.present(AppError.ai(error))
        }
    }

    // MARK: Probe

    private func testConnection() async {
        guard let problem = store.settings.defaultSelection.validationMessage else {
            isTesting = true
            defer { isTesting = false }
            status = appState.localized("settings.ai.subscription.testing")
            let result = await runtime.probe()
            switch result {
            case let .reply(text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK") {
                    status = appState.localized("settings.ai.subscription.probeSuccess")
                } else {
                    status = String(
                        format: appState.localized("settings.ai.subscription.probeReply"),
                        String(text.prefix(200))
                    )
                }
            case .pending:
                status = appState.localized("settings.ai.subscription.probePending")
            case let .failure(message):
                status = String(
                    format: appState.localized("settings.ai.subscription.probeFailure"),
                    message
                )
            }
            return
        }
        status = String(
            format: appState.localized("settings.ai.subscription.probeFailure"),
            problem
        )
    }
}

// MARK: - Thread controls

/// D2: one reused thread per provider+model, persisted in the project's
/// `aiThreadMap`. "New thread" only forgets this pair.
struct SubscriptionAIThreadControls: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let selection: SubscriptionAISelection
    @State private var message = ""
    @State private var runtime = SubscriptionAIRuntime.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let threadID = appState.subscriptionAIThreadID(for: selection) {
                HStack(spacing: 8) {
                    Text(shortThreadID(threadID))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(appState.localized("settings.ai.subscription.openThread")) {
                        Task {
                            switch await runtime.openThreadInT3(selection: selection) {
                            case .opened, .noThread:
                                message = ""
                            case let .failed(detail):
                                message = String(
                                    format: appState.localized("settings.ai.subscription.openFailed"),
                                    detail
                                )
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .clickableCursor()

                    Button(appState.localized("settings.ai.subscription.newThread")) {
                        appState.subscriptionAIResetThread(for: selection)
                        message = appState.localized("settings.ai.subscription.threadReset")
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.borderless)
                    .clickableCursor()
                }
            } else {
                Text(appState.localized("settings.ai.subscription.threadNone"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortThreadID(_ threadID: String) -> String {
        guard threadID.count > 22 else { return threadID }
        return String(threadID.prefix(10)) + "…" + String(threadID.suffix(6))
    }
}
