import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// OBS can write Matroska (`.mkv`), which is a dynamic UTType on most systems
/// and does not conform to `.movie`. Keep the standard movie types and add the
/// Matroska extension explicitly so those takes can be registered by hand.
enum TakeFileSelection {
    static var allowedContentTypes: [UTType] {
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        if let mkv = UTType(filenameExtension: "mkv"),
           !types.contains(where: { $0.identifier == mkv.identifier }) {
            types.append(mkv)
        }
        return types
    }
}

// MARK: - OBS settings

struct OBSSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @State private var host = ""
    @State private var portText = ""
    @State private var password = ""
    @State private var autoConnect = false
    @State private var testState: TestState = .idle
    @State private var formError: String?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("recording.obs.settings.title"))
                    .font(.system(size: 18, weight: .semibold))
                Text(appState.localized("recording.obs.settings.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            QuietField(appState.localized("recording.obs.host")) {
                TextField("localhost", text: $host)
                    .textFieldStyle(QuietTextFieldStyle())
            }

            HStack(alignment: .top, spacing: 14) {
                QuietField(appState.localized("recording.obs.port")) {
                    TextField("4455", text: $portText)
                        .textFieldStyle(QuietTextFieldStyle())
                        .frame(width: 130)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(" ")
                        .font(.system(size: 12, weight: .medium))
                    Toggle(appState.localized("recording.obs.autoConnect"), isOn: $autoConnect)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                }
            }

            QuietField(appState.localized("recording.obs.password")) {
                SecureField("", text: $password)
                    .textFieldStyle(QuietTextFieldStyle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("recording.obs.passwordHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                if appState.recording.preferences.keychainReadFailed {
                    Text(appState.localized("recording.obs.keychainFailed"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                }
                Text(appState.localized("recording.obs.settingsHelp"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let formError {
                Text(formError)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }

            testStatus

            Divider().overlay(theme.divider)

            HStack {
                Button(appState.localized("recording.obs.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(appState.localized("recording.obs.test"), action: runTest)
                    .disabled(testState == .testing)

                Button(appState.localized("recording.obs.save"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(testState == .testing)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(appState.localized("recording.obs.testing"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        case .success:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text(appState.localized("recording.obs.testSuccess"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.success)
            }
        case .failure(let message):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.destructive)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let preferences = appState.recording.preferences
        preferences.loadPasswordIfNeeded()
        host = preferences.host
        portText = String(preferences.port)
        password = preferences.password
        autoConnect = preferences.autoConnect
    }

    private func runTest() {
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else {
            formError = appState.localized("recording.obs.invalidPort")
            return
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            formError = appState.localized("recording.obs.invalidHost")
            return
        }
        formError = nil
        testState = .testing
        Task {
            let succeeded = await appState.recording.testConnection(
                host: trimmedHost,
                port: port,
                password: password
            )
            if succeeded {
                testState = .success
            } else {
                let issue = appState.recording.testConnectionIssue ?? .connectionFailed("")
                testState = .failure(issue.message(language: appState.currentLanguage))
            }
        }
    }

    private func save() {
        do {
            try appState.recording.preferences.apply(
                host: host,
                portText: portText,
                autoConnect: autoConnect,
                password: password
            )
            dismiss()
            if autoConnect && !appState.recording.connectionState.isConnected {
                Task { await appState.recording.connect() }
            }
        } catch OBSPreferencesError.invalidHost {
            formError = appState.localized("recording.obs.invalidHost")
        } catch OBSPreferencesError.invalidPort {
            formError = appState.localized("recording.obs.invalidPort")
        } catch {
            formError = appState.localized("recording.obs.saveFailed")
        }
    }
}

// MARK: - Manual take

struct ManualTakeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    let scene: Scene
    let languageCode: String

    @State private var startedAt = Date()
    @State private var minutes = ""
    @State private var seconds = ""
    @State private var pickedFile: URL?
    @State private var note = ""
    @State private var isProbing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.localized("recording.manual.title"))
                    .font(.system(size: 18, weight: .semibold))
                Text(appState.localized("recording.manual.subtitle"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(scene.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)

            QuietField(appState.localized("recording.manual.file")) {
                HStack(spacing: 8) {
                    Image(systemName: pickedFile == nil ? "film" : "film.fill")
                        .foregroundStyle(pickedFile == nil ? theme.tertiaryText : theme.accent.color)
                    Text(pickedFile?.lastPathComponent ?? appState.localized("recording.manual.noFile"))
                        .font(.system(size: 12))
                        .foregroundStyle(pickedFile == nil ? theme.tertiaryText : theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if isProbing {
                        ProgressView().controlSize(.small)
                    }
                    if pickedFile != nil {
                        Button {
                            pickedFile = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(appState.localized("recording.manual.clearFile"))
                    }
                    Button(appState.localized("recording.manual.chooseFile"), action: chooseFile)
                        .font(.system(size: 12))
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.editorSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        )
                }
            }

            HStack(alignment: .top, spacing: 16) {
                QuietField(appState.localized("recording.manual.date")) {
                    DatePicker("", selection: $startedAt)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
                QuietField(appState.localized("recording.manual.duration")) {
                    HStack(spacing: 6) {
                        TextField("0", text: $minutes)
                            .textFieldStyle(QuietTextFieldStyle())
                            .frame(width: 54)
                        Text(appState.localized("recording.manual.minutes"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        TextField("0", text: $seconds)
                            .textFieldStyle(QuietTextFieldStyle())
                            .frame(width: 54)
                        Text(appState.localized("recording.manual.seconds"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
            }

            QuietField(appState.localized("recording.take.notePlaceholder")) {
                TextField("", text: $note, axis: .vertical)
                    .textFieldStyle(QuietTextFieldStyle())
                    .lineLimit(1...3)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
            }

            HStack {
                Button(appState.localized("recording.obs.cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(appState.localized("recording.manual.addButton"), action: addTake)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TakeFileSelection.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedFile = url
        errorMessage = nil
        isProbing = true
        Task {
            let duration = await TakeFileProbe.duration(atPath: url.path)
            isProbing = false
            if let duration {
                minutes = String(Int(duration) / 60)
                seconds = String(Int(duration) % 60)
            }
        }
    }

    private func addTake() {
        let parsedMinutes = max(0, Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let parsedSeconds = max(0, Int(seconds.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        let total = TimeInterval(parsedMinutes * 60 + parsedSeconds)
        guard total > 0 || pickedFile != nil else {
            errorMessage = appState.localized("recording.manual.durationInvalid")
            return
        }
        let added = appState.addManualRecordingTake(
            sceneID: scene.id,
            startedAt: startedAt,
            duration: total,
            fileURL: pickedFile,
            note: note,
            languageCode: languageCode
        )
        if added {
            dismiss()
        } else {
            errorMessage = appState.localized("recording.error.noScene")
        }
    }
}
