import SwiftUI

struct RecordingPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var pendingDeletion: PendingTakeDeletion?

    private var recording: RecordingController { appState.recording }

    var body: some View {
        @Bindable var recording = appState.recording
        VStack(spacing: 0) {
            header(recording)
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusCard(recording)
                    if let scene = appState.selectedScene {
                        sceneCard(scene, recording: recording)
                        if let latest = recording.lastTake(in: scene), recording.phase == .idle {
                            latestTakeCard(latest, scene: scene, recording: recording)
                        }
                        takesSection(scene, recording: recording)
                    } else {
                        Text(appState.localized("recording.error.noScene"))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(14)
            }
            Divider().overlay(theme.divider)
            footer(recording)
        }
        .frame(width: 330)
        .background(theme.panelBackground)
        .sheet(isPresented: $recording.isManualEntryPresented) {
            if let scene = appState.selectedScene {
                ManualTakeSheet(scene: scene, languageCode: recording.effectiveLanguage(for: scene))
                    .environment(appState)
                    .environment(\.frameTheme, theme)
            }
        }
        .alert(
            appState.localized("recording.take.delete.title"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { pending in
            Button(appState.localized("recording.take.delete.confirm"), role: .destructive) {
                appState.recording.deleteTake(takeID: pending.take.id, sceneID: pending.sceneID)
                pendingDeletion = nil
            }
            Button(appState.localized("recording.obs.cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text(appState.localized("recording.take.delete.message"))
        }
    }

    // MARK: Header

    private func header(_ recording: RecordingController) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.destructive)
            Text(appState.localized("recording.panel.title"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                recording.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("recording.obs.settings"))

            Button {
                recording.isPanelVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("recording.panel.close"))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    // MARK: Connection

    private func statusCard(_ recording: RecordingController) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(recording))
                    .frame(width: 8, height: 8)
                Text(statusText(recording))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if recording.connectionState.isConnected {
                    compactButton(appState.localized("recording.obs.disconnect")) {
                        Task { await recording.disconnect() }
                    }
                    .disabled(recording.isBusy)
                } else {
                    compactButton(appState.localized("recording.obs.connect")) {
                        Task { await recording.connect() }
                    }
                    .disabled(recording.isBusy || recording.isTestingConnection)
                }
            }

            if recording.connectionState.isConnected,
               let session = recording.connectionState.sessionInfo {
                Text(String(
                    format: appState.localized("recording.obs.version"),
                    session.obsStudioVersion ?? "?",
                    session.obsWebSocketVersion ?? "?"
                ))
                .font(.system(size: 10))
                .foregroundStyle(theme.tertiaryText)
            }

            if recording.externalRecordingActive {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 10))
                    Text(appState.localized("recording.externalRecordingActive"))
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(theme.warning)
            }

            if let issue = recording.lastIssue ?? recording.connectionIssue,
               issue != .externalRecordingActive {
                Text(recording.issueMessage(issue))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = issue.recoveryHint(language: appState.currentLanguage) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let scenesIssue = recording.scenesIssue {
                Text(recording.issueMessage(scenesIssue))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func statusColor(_ recording: RecordingController) -> Color {
        if recording.phase.isActive { return theme.destructive }
        switch recording.connectionState {
        case .connected: return theme.success
        case .connecting: return theme.warning
        case .failed: return theme.destructive
        case .disconnected: return theme.tertiaryText
        }
    }

    private func statusText(_ recording: RecordingController) -> String {
        switch recording.phase {
        case .countdown(let value):
            return "\(value)…"
        case .starting:
            return appState.localized("recording.starting")
        case .stopping:
            return appState.localized("recording.stopping")
        case .recording:
            return String(
                format: appState.localized("recording.status.recording"),
                DurationEstimator.formatted(recording.elapsed)
            )
        case .idle:
            break
        }
        switch recording.connectionState {
        case .connected:
            return appState.localized("recording.obs.connected")
        case .connecting:
            return appState.localized("recording.obs.connecting")
        case .failed:
            return appState.localized("recording.obs.failed")
        case .disconnected:
            return appState.localized("recording.obs.disconnected")
        }
    }

    private func compactButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.hover)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.secondaryText)
    }

    // MARK: Scene

    private func sceneCard(_ scene: Scene, recording: RecordingController) -> some View {
        let previewText = recording.text(
            in: scene,
            languageCode: recording.effectiveLanguage(for: scene)
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(appState.localized("recording.scene.current"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                if let index = appState.selectedSceneIndex {
                    Text(String(
                        format: appState.localized("recording.scene.index"),
                        index + 1,
                        appState.project.scenes.count
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                }
            }

            Text(scene.title)
                .font(.system(size: 14, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(appState.localized("recording.scene.obsScene"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Picker("", selection: obsSceneBinding(for: scene)) {
                    Text(appState.localized("recording.scene.none")).tag("")
                    ForEach(obsSceneOptions(for: scene), id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .disabled(recording.isBusy)
            }

            if !scene.languageVariants.isEmpty {
                HStack(spacing: 8) {
                    Text(appState.localized("recording.scene.language"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { recording.effectiveLanguage(for: scene) },
                        set: { recording.selectedLanguageCode = $0 }
                    )) {
                        Text(appState.localized("recording.scene.originalLanguage")).tag("")
                        ForEach(scene.languageVariants, id: \.languageCode) { variant in
                            Text(languageName(variant.languageCode)).tag(variant.languageCode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .disabled(recording.isBusy)
                }
            }

            Text(appState.localized("recording.scene.textPreview"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(previewText.isEmpty
                 ? appState.localized("recording.scene.emptyText")
                 : previewText)
                .font(.system(size: 11))
                .foregroundStyle(previewText.isEmpty ? theme.tertiaryText : theme.primaryText)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func obsSceneBinding(for scene: Scene) -> Binding<String> {
        Binding(
            get: { scene.obsSceneName ?? "" },
            set: { value in
                appState.setOBSSceneName(value.isEmpty ? nil : value, for: scene.id)
            }
        )
    }

    private func obsSceneOptions(for scene: Scene) -> [String] {
        var names = recording.sceneNames
        if let current = scene.obsSceneName,
           !current.isEmpty,
           !names.contains(current) {
            names.append(current)
        }
        return names
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    // MARK: Latest take

    private func latestTakeCard(_ entry: SceneTake, scene: Scene, recording: RecordingController) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(appState.localized("recording.take.justNow"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(String(format: appState.localized("recording.take.number"), entry.take.number))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(DurationEstimator.formatted(entry.take.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            HStack(spacing: 6) {
                ForEach([TakeRating.good, .bad, .safe], id: \.self) { rating in
                    ratingButton(rating, take: entry.take, scene: scene, recording: recording)
                }
            }

            TakeNoteField(take: entry.take, sceneID: scene.id)
                .id(entry.take.id)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.accentSoft.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
    }

    private func ratingButton(
        _ rating: TakeRating,
        take: Take,
        scene: Scene,
        recording: RecordingController
    ) -> some View {
        let isSelected = take.rating == rating
        let color = TakeRatingPresentation.color(rating, theme: theme)
        return Button {
            recording.setRating(rating, takeID: take.id, sceneID: scene.id)
        } label: {
            Text(TakeRatingPresentation.label(rating, language: appState.currentLanguage))
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background {
                    Capsule()
                        .fill(isSelected ? color.opacity(0.22) : theme.hover)
                }
                .overlay {
                    Capsule()
                        .stroke(isSelected ? color : Color.clear, lineWidth: 1)
                }
                .foregroundStyle(isSelected ? color : theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    // MARK: Takes list

    private func takesSection(_ scene: Scene, recording: RecordingController) -> some View {
        let entries = recording.takes(in: scene)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(appState.localized("recording.takes.title"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text(String(format: appState.localized("recording.takes.count"), entries.count))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                Spacer()
                Button {
                    recording.isManualEntryPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help(appState.localized("recording.manual.add"))
            }

            if entries.isEmpty {
                Text(appState.localized("recording.takes.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(entries) { entry in
                        RecordingTakeRow(entry: entry, sceneID: scene.id) { pending in
                            pendingDeletion = pending
                        }
                    }
                }
            }
        }
    }

    // MARK: Footer

    private func footer(_ recording: RecordingController) -> some View {
        VStack(spacing: 8) {
            if let scene = appState.selectedScene {
                recordButton(scene, recording: recording)

                HStack {
                    Toggle(
                        appState.localized("recording.countdown"),
                        isOn: Binding(
                            get: { recording.countdownEnabled },
                            set: { recording.countdownEnabled = $0 }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(recording.isBusy)
                    Spacer()
                    if case .idle = recording.phase,
                       !recording.connectionState.isConnected {
                        Text(appState.localized("recording.needsConnection"))
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }

                HStack(spacing: 8) {
                    Button(appState.localized("recording.manual.add")) {
                        recording.isManualEntryPresented = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                    Spacer()

                    Button(appState.localized("recording.nextScene")) {
                        appState.selectNextScene()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appState.hasNextScene ? theme.accent.color : theme.tertiaryText)
                    .disabled(!appState.hasNextScene)
                }
            } else if recording.phase.isActive {
                // The scene can disappear mid-take; keep a stop affordance.
                stopOnlyButton(recording)
            } else {
                Text(appState.localized("recording.error.noScene"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(12)
    }

    private func stopOnlyButton(_ recording: RecordingController) -> some View {
        Button {
            Task { await recording.stopTake() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                Text(appState.localized("recording.stop"))
                    .font(.system(size: 13, weight: .semibold))
                if recording.phase.isRecording {
                    Text(DurationEstimator.formatted(recording.elapsed))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.destructive)
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(recording.phase == .stopping)
    }

    private func recordButton(_ scene: Scene, recording: RecordingController) -> some View {
        Button {
            let language = recording.effectiveLanguage(for: scene)
            switch recording.phase {
            case .countdown:
                recording.cancelCountdown()
            case .idle, .recording:
                Task { await recording.toggleRecording(sceneID: scene.id, languageCode: language) }
            case .starting:
                Task { await recording.stopTake() }
            case .stopping:
                break
            }
        } label: {
            HStack(spacing: 8) {
                switch recording.phase {
                case .countdown(let value):
                    Text("\(value)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(appState.localized("recording.cancelCountdown"))
                        .font(.system(size: 12, weight: .medium))
                case .starting, .stopping:
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.localized(recording.phase == .starting
                                            ? "recording.starting"
                                            : "recording.stopping"))
                        .font(.system(size: 13, weight: .semibold))
                case .recording:
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text(appState.localized("recording.stop"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(DurationEstimator.formatted(recording.elapsed))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                case .idle:
                    Image(systemName: "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(appState.localized("recording.start"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(appState.shortcutDisplay(for: .recordTake))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .opacity(0.8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .padding(.horizontal, 12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(buttonFill(recording))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(
            recording.phase == .starting
                || recording.phase == .stopping
                || recording.externalRecordingActive
        )
    }

    private func buttonFill(_ recording: RecordingController) -> Color {
        switch recording.phase {
        case .recording, .stopping:
            return theme.destructive
        case .countdown:
            return theme.warning
        case .idle, .starting:
            return recording.connectionState.isConnected
                ? theme.accent.color
                : theme.accent.color.opacity(0.45)
        }
    }
}

private struct PendingTakeDeletion: Identifiable {
    let take: Take
    let sceneID: UUID

    var id: UUID { take.id }
}

// MARK: - Rating presentation

enum TakeRatingPresentation {
    static func label(_ rating: TakeRating, language: AppLanguage) -> String {
        switch rating {
        case .good: L10n.tr("recording.take.good", language: language)
        case .bad: L10n.tr("recording.take.bad", language: language)
        case .safe: L10n.tr("recording.take.safe", language: language)
        case .unrated: L10n.tr("recording.take.unrated", language: language)
        }
    }

    static func color(_ rating: TakeRating, theme: FrameTheme) -> Color {
        switch rating {
        case .good: theme.success
        case .bad: theme.destructive
        case .safe: theme.warning
        case .unrated: theme.tertiaryText
        }
    }
}

// MARK: - Take row

private struct RecordingTakeRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var isHovered = false

    let entry: SceneTake
    let sceneID: UUID
    let onDelete: (PendingTakeDeletion) -> Void

    private var take: Take { entry.take }

    private var hasFile: Bool {
        !take.filePath.isEmpty || take.bookmarkData != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(take.number)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if !entry.languageCode.isEmpty {
                    Text(entry.languageCode.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 4)
                        .frame(height: 14)
                        .background {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(theme.hover)
                        }
                        .foregroundStyle(theme.secondaryText)
                }

                Menu {
                    ForEach(TakeRating.allCases, id: \.self) { rating in
                        Button(TakeRatingPresentation.label(rating, language: appState.currentLanguage)) {
                            appState.recording.setRating(rating, takeID: take.id, sceneID: sceneID)
                        }
                    }
                } label: {
                    Text(TakeRatingPresentation.label(take.rating, language: appState.currentLanguage))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TakeRatingPresentation.color(take.rating, theme: theme))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer(minLength: 4)

                Text(DurationEstimator.formatted(take.duration))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }

            if !take.note.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    if take.note.hasPrefix(RecordingController.interruptedNoteMarker) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.warning)
                    }
                    Text(take.note.replacingOccurrences(of: RecordingController.interruptedNoteMarker, with: ""))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Text(take.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(theme.tertiaryText)

                Spacer()

                rowButton("play.fill", help: appState.localized("recording.take.play"), enabled: hasFile) {
                    TakeFileAccess.play(take)
                }
                rowButton("folder", help: appState.localized("recording.take.reveal"), enabled: hasFile) {
                    TakeFileAccess.reveal(take)
                }
                rowButton("trash", help: appState.localized("recording.take.delete"), color: theme.destructive) {
                    onDelete(PendingTakeDeletion(take: take, sceneID: sceneID))
                }
            }
            .opacity(isHovered ? 1 : 0.72)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            ForEach(TakeRating.allCases, id: \.self) { rating in
                Button(TakeRatingPresentation.label(rating, language: appState.currentLanguage)) {
                    appState.recording.setRating(rating, takeID: take.id, sceneID: sceneID)
                }
            }
            Divider()
            Button(appState.localized("recording.take.play")) { TakeFileAccess.play(take) }
            Button(appState.localized("recording.take.reveal")) { TakeFileAccess.reveal(take) }
            Divider()
            Button(appState.localized("recording.take.delete"), role: .destructive) {
                onDelete(PendingTakeDeletion(take: take, sceneID: sceneID))
            }
        }
    }

    private func rowButton(
        _ symbol: String,
        help: String,
        color: Color? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color ?? theme.secondaryText)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - Note editor

private struct TakeNoteField: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let take: Take
    let sceneID: UUID
    @State private var text = ""

    var body: some View {
        TextField(
            appState.localized("recording.take.notePlaceholder"),
            text: $text,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .lineLimit(1...3)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(theme.editorSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .onAppear { text = take.note }
        .onChange(of: take.note) { _, newValue in
            if newValue != text { text = newValue }
        }
        .onChange(of: text) { _, newValue in
            guard newValue != take.note else { return }
            appState.recording.setNote(newValue, takeID: take.id, sceneID: sceneID)
        }
    }
}
