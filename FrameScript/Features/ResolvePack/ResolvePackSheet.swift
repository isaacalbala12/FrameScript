import AppKit
import FrameScriptCore
import SwiftUI

// MARK: - Environment wrapper

/// The sheet presented from the menu, toolbar menu and command palette.
///
/// It owns the mutable options and the export action; the visual body is a
/// pure `ResolvePackSheetContent` so snapshot tests can render it without an
/// `AppState`, `UserDefaults` or any real app data.
struct ResolvePackSheet: View {
    let languageCode: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: ResolvePackConfiguration
    @State private var plan: ResolvePackPlan?
    @State private var exportedFolder: URL?
    @State private var errorMessage: String?

    init(languageCode: String) {
        self.languageCode = languageCode
        _configuration = State(initialValue: .defaults(languageCode: languageCode))
    }

    var body: some View {
        let revision = RhythmReviewCenter.shared.revision

        ResolvePackSheetContent(
            projectTitle: appState.project.title,
            interfaceLanguage: appState.currentLanguage,
            languageOptions: appState.resolvePackLanguageOptions,
            configuration: $configuration,
            plan: plan,
            defaultFolderPath: appState.settings.exportPreferences.defaultExportFolder.isEmpty
                ? nil
                : appState.settings.exportPreferences.defaultExportFolder,
            exportedFolder: exportedFolder,
            errorMessage: errorMessage,
            onExport: { chooseFolderAndExport(plan) },
            onClose: { dismiss() },
            onReveal: { folder in
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        )
        .onAppear {
            refreshPlan()
            RhythmReviewCenter.shared.refreshNow(
                project: appState.project,
                settings: appState.settings
            )
        }
        .onChange(of: configuration) { _, _ in
            refreshPlan()
            exportedFolder = nil
            errorMessage = nil
        }
        .onChange(of: revision) { _, _ in
            refreshPlan()
        }
    }

    private func refreshPlan() {
        plan = appState.makeResolvePackPlan(configuration: configuration)
    }

    private func chooseFolderAndExport(_ plan: ResolvePackPlan?) {
        guard let plan else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = appState.localized("resolvePack.export.prompt")
        panel.message = appState.localized("resolvePack.export.message")
        if let folder = appState.resolvePackDefaultFolder {
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        do {
            exportedFolder = try appState.exportResolvePack(plan, to: parent)
            errorMessage = nil
        } catch {
            errorMessage = appState.localized("resolvePack.export.error")
            appState.errorCenter.present(
                AppError(
                    kind: .export,
                    context: AppErrorContext(
                        fileName: plan.names.folder,
                        diagnosticCode: "resolve-pack-write"
                    )
                )
            )
        }
    }
}

// MARK: - Pure content

/// Everything the sheet draws. No environment objects, no file system, no app
/// stores: the same view renders in production and in offscreen tests.
struct ResolvePackSheetContent: View {
    let projectTitle: String
    let interfaceLanguage: AppLanguage
    let languageOptions: [ResolvePackLanguageOption]
    @Binding var configuration: ResolvePackConfiguration
    let plan: ResolvePackPlan?
    let defaultFolderPath: String?
    let exportedFolder: URL?
    let errorMessage: String?
    let onExport: () -> Void
    let onClose: () -> Void
    let onReveal: (URL) -> Void

    @Environment(\.frameTheme) private var theme

    private var names: ResolvePackNames {
        ResolvePackNaming.names(
            projectName: projectTitle,
            asciiSafe: configuration.asciiSafeNames
        )
    }

    private var selectedFileCount: Int {
        [
            configuration.includeMarkerEDL,
            configuration.includeFCPXML,
            configuration.includeShotList,
            configuration.includeEditingNotes,
            configuration.includeChapters,
            configuration.includeReadme
        ].filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: ResolvePackSheetLayout.headerHeight)
            horizontalDivider
            HStack(spacing: 0) {
                optionsColumn
                    .frame(width: ResolvePackSheetLayout.optionsColumnWidth)
                verticalDivider
                previewColumn
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            horizontalDivider
            footer
                .frame(height: ResolvePackSheetLayout.footerHeight)
        }
        .frame(
            minWidth: ResolvePackSheetLayout.minimumSheetSize.width,
            idealWidth: ResolvePackSheetLayout.idealSheetSize.width,
            minHeight: ResolvePackSheetLayout.minimumSheetSize.height,
            idealHeight: ResolvePackSheetLayout.idealSheetSize.height
        )
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("resolve-pack-sheet")
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(t("resolvePack.title"))
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                Text(t("resolvePack.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.hover))
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(t("resolvePack.close"))
            .accessibilityIdentifier("resolve-pack-close")
        }
        .padding(.horizontal, 20)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let exportedFolder {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text(
                    String(
                        format: t("resolvePack.export.success"),
                        exportedFolder.path
                    )
                )
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(exportedFolder.path)
                Button(t("resolvePack.export.reveal")) {
                    onReveal(exportedFolder)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            } else if plan == nil {
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(configuration.hasAnyFile ? theme.destructive : theme.secondaryText)
                    .lineLimit(2)
            } else {
                Text(
                    String(
                        format: t("resolvePack.fileCountFormat"),
                        selectedFileCount,
                        6
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                if configuration.includeMarkerEDL {
                    Text(t("resolvePack.note.authoritative"))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(t("resolvePack.cancel"), action: onClose)
                .buttonStyle(.cursorPlain)
                .keyboardShortcut(.cancelAction)
            Button(t("resolvePack.export"), action: onExport)
                .buttonStyle(.borderedProminent)
                .tint(theme.accent.color)
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil)
                .accessibilityIdentifier("resolve-pack-export")
        }
        .padding(.horizontal, 20)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(height: ResolvePackSheetLayout.dividerWidth)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.divider)
            .frame(width: ResolvePackSheetLayout.dividerWidth)
            .frame(maxHeight: .infinity)
    }

    // MARK: Options

    private var optionsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                timelineSection
                contentSection
                filesSection
                destinationSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) {
            columnFade
        }
    }

    private var columnFade: some View {
        LinearGradient(
            colors: [theme.windowBackground.opacity(0), theme.windowBackground],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 16)
        .allowsHitTesting(false)
    }

    private var timelineSection: some View {
        section("resolvePack.section.timeline") {
            HStack(spacing: 8) {
                Text(t("resolvePack.frameRate"))
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Picker(
                    "",
                    selection: Binding(
                        get: { configuration.rate },
                        set: { configuration.setRate($0) }
                    )
                ) {
                    ForEach(ResolvePackFrameRate.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 118)
                .accessibilityIdentifier("resolve-pack-frame-rate")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t("resolvePack.startTimecode"))
                        .font(.system(size: 12))
                    Spacer(minLength: 4)
                    TextField("01:00:00:00", text: $configuration.startTimecodeText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 118)
                        .accessibilityIdentifier("resolve-pack-start-timecode")
                }
                if configuration.parsedStartTimecode == nil {
                    Text(t("resolvePack.startTimecodeInvalid"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.destructive)
                        .accessibilityIdentifier("resolve-pack-timecode-error")
                }
                Text(t("resolvePack.startTimecodeHelp"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $configuration.asciiSafeNames) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t("resolvePack.ascii"))
                        .font(.system(size: 12))
                    Text(t("resolvePack.asciiHelp"))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("resolve-pack-ascii")
        }
    }

    private var contentSection: some View {
        section("resolvePack.section.content") {
            HStack(spacing: 8) {
                Text(t("resolvePack.duration"))
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Picker("", selection: $configuration.durationSource) {
                    ForEach(ResolvePackDurationSource.allCases) { source in
                        Text(t(source.localizationKey)).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
                .accessibilityIdentifier("resolve-pack-duration-source")
            }

            HStack(spacing: 8) {
                Text(t("resolvePack.language"))
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Picker("", selection: $configuration.languageCode) {
                    ForEach(languageOptions) { option in
                        Text(option.displayName(interfaceLanguage: interfaceLanguage))
                            .tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
                .accessibilityIdentifier("resolve-pack-language")
            }
        }
    }

    private var filesSection: some View {
        section("resolvePack.section.files") {
            fileToggle(
                key: "resolvePack.file.edl",
                fileName: names.markerEDL,
                isOn: $configuration.includeMarkerEDL
            )
            fileToggle(
                key: "resolvePack.file.fcpxml",
                fileName: names.fcpxml,
                isOn: $configuration.includeFCPXML
            )
            fileToggle(
                key: "resolvePack.file.shots",
                fileName: names.shotList,
                isOn: $configuration.includeShotList
            )
            fileToggle(
                key: "resolvePack.file.notes",
                fileName: names.editingNotes,
                isOn: $configuration.includeEditingNotes
            )
            fileToggle(
                key: "resolvePack.file.chapters",
                fileName: names.chapters,
                isOn: $configuration.includeChapters
            )
            fileToggle(
                key: "resolvePack.file.readme",
                fileName: names.readme,
                isOn: $configuration.includeReadme
            )
            Toggle(isOn: $configuration.includeChapterMarkersInFCPXML) {
                Text(t("resolvePack.file.chapterMarkers"))
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)
            .disabled(!configuration.includeFCPXML)
            .opacity(configuration.includeFCPXML ? 1 : 0.5)
        }
    }

    private var destinationSection: some View {
        section("resolvePack.section.destination") {
            Text(String(format: t("resolvePack.destination.hint"), names.folder))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            if let defaultFolderPath, !defaultFolderPath.isEmpty {
                Text(String(format: t("resolvePack.destination.default"), defaultFolderPath))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private func fileToggle(key: String, fileName: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t(key))
                    .font(.system(size: 12))
                Text(fileName)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func section<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(titleKey))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.secondaryText)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            )
        }
    }

    // MARK: Preview

    private var previewColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                metrics
                markerCard
                warningsCard
                legendCard
                limitsCard
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) {
            columnFade
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            metric(plan.map { "\($0.sceneCount)" } ?? "—", "resolvePack.metric.scenes")
            metric(plan.map { "\($0.markers.count)" } ?? "—", "resolvePack.metric.markers")
            metric(plan.map { "\($0.cueCount)" } ?? "—", "resolvePack.metric.cues")
            metric(durationText, "resolvePack.metric.duration")
        }
    }

    private var durationText: String {
        guard let plan else { return "—" }
        return DurationFormat.clock(frames: plan.durationFrames, rate: plan.settings.fps)
    }

    private func metric(_ value: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Text(t(key))
                .font(.system(size: 9.5))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.cardBackground)
        )
    }

    private var markerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t("resolvePack.preview.title"))
                    .font(.system(size: 12, weight: .semibold))
                if let plan {
                    Text(
                        String(
                            format: t("resolvePack.metric.markersFormat"),
                            plan.markers.count,
                            plan.sceneCount,
                            plan.cueCount
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Text(plan?.prefixedTimecode ?? "")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
            }

            if let plan, !plan.markerPreviews.isEmpty {
                HStack(spacing: 8) {
                    Text(t("resolvePack.column.timecode"))
                        .frame(width: 82, alignment: .leading)
                    Text(t("resolvePack.column.color"))
                        .frame(width: 68, alignment: .leading)
                    Text(t("resolvePack.column.name"))
                    Spacer()
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(theme.tertiaryText)
                .padding(.horizontal, 10)

                Divider().overlay(theme.divider)

                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(plan.markerPreviews) { marker in
                            markerRow(marker)
                            if marker.id != plan.markerPreviews.last?.id {
                                Divider().overlay(theme.divider.opacity(0.6))
                            }
                        }
                    }
                }
                .frame(height: 250)
                .accessibilityIdentifier("resolve-pack-marker-list")
            } else {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.vertical, 12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
    }

    private func markerRow(_ marker: ResolveMarkerPreview) -> some View {
        HStack(spacing: 8) {
            Text(marker.timecode)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 82, alignment: .leading)
            HStack(spacing: 5) {
                Circle()
                    .fill(marker.color.displayColor)
                    .frame(width: 7, height: 7)
                Text(colorName(marker.color))
                    .font(.system(size: 9.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 68, alignment: .leading)
            Text(marker.name)
                .font(.system(size: 11))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if marker.durationFrames > 1 {
                Text("|D:\(marker.durationFrames)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .help(marker.note.isEmpty ? marker.name : marker.note)
    }

    private var legendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("resolvePack.legend.title"))
                .font(.system(size: 12, weight: .semibold))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 108), spacing: 8)],
                alignment: .leading,
                spacing: 6
            ) {
                legendRow(ResolveMarkerLegend.scene, "resolvePack.legend.scene")
                legendRow(ResolveMarkerLegend.camera, "resolvePack.legend.cam")
                legendRow(ResolveMarkerLegend.gameplay, "resolvePack.legend.obs")
                legendRow(ResolveMarkerLegend.screen, "resolvePack.legend.screen")
                legendRow(ResolveMarkerLegend.warning, "resolvePack.legend.warning")
                legendRow(ResolveMarkerLegend.rehook, "resolvePack.legend.rehook")
                legendRow(ResolveMarkerLegend.graphic, "resolvePack.legend.graphic")
                legendRow(ResolveMarkerLegend.music, "resolvePack.legend.music")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
    }

    private func legendRow(_ color: ExportMarkerColor, _ key: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.displayColor)
                .frame(width: 7, height: 7)
            Text(t(key))
                .font(.system(size: 10))
                .lineLimit(1)
        }
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            limitRow("60", "resolvePack.note.namesLimit")
            limitRow("999", "resolvePack.note.eventsLimit")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
    }

    private func limitRow(_ badge: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(badge)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(theme.hover, in: RoundedRectangle(cornerRadius: 4))
            Text(t(key))
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("resolvePack.warnings.title"))
                .font(.system(size: 12, weight: .semibold))
            if let errorMessage {
                warningRow(errorMessage, isError: true)
            }
            if let warnings = plan?.warnings, !warnings.isEmpty {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    warningRow(warning, isError: false)
                }
            } else if errorMessage == nil {
                Text(t("resolvePack.warnings.none"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.divider, lineWidth: 1)
        )
        .accessibilityIdentifier("resolve-pack-warnings")
    }

    private func warningRow(_ text: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: isError ? "xmark.octagon" : "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(isError ? theme.destructive : theme.warning)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(isError ? theme.destructive : theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Helpers

    private var statusText: String {
        if !configuration.hasAnyFile {
            return t("resolvePack.noFiles")
        }
        if configuration.parsedStartTimecode == nil {
            return t("resolvePack.startTimecodeInvalid")
        }
        return t("resolvePack.preview.empty")
    }

    private func t(_ key: String) -> String {
        L10n.tr(key, language: interfaceLanguage)
    }

    private func colorName(_ color: ExportMarkerColor) -> String {
        switch color {
        case .blue: t("resolvePack.color.blue")
        case .green: t("resolvePack.color.green")
        case .yellow: t("resolvePack.color.yellow")
        case .pink: t("resolvePack.color.pink")
        case .red: t("resolvePack.color.red")
        case .purple: t("resolvePack.color.purple")
        case .sand: t("resolvePack.color.sand")
        case .lavender: t("resolvePack.color.lavender")
        case .cyan: t("resolvePack.color.cyan")
        default: color.spanishName
        }
    }
}

// MARK: - Presentation modifier

private struct ResolvePackSheetModifier: ViewModifier {
    @Bindable var presenter: ResolvePackPresenter
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.request) { request in
            ResolvePackSheet(languageCode: request.languageCode)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }
}

extension View {
    func resolvePackSheet(presenter: ResolvePackPresenter) -> some View {
        modifier(ResolvePackSheetModifier(presenter: presenter))
    }
}

extension ExportMarkerColor {
    /// Approximate SwiftUI colour for the preview dot. System colours adapt to
    /// light and dark automatically.
    var displayColor: Color {
        switch self {
        case .blue: .blue
        case .cyan: .cyan
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .fuchsia: .purple
        case .rose: .red
        case .lavender: .indigo
        case .sky: .cyan
        case .mint: .mint
        case .lemon: .yellow
        case .sand: .orange
        case .cocoa: .brown
        case .cream: .gray
        }
    }
}
