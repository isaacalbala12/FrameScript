import FrameScriptCore
import SwiftUI

/// Project-level clip list plus the editor for the selected clip.
struct ClipsPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @State private var statusFilter: ShortClipStatus?
    @State private var searchText = ""

    /// Set only by the offscreen snapshot tests.
    var layoutProbeToken: String?

    private var filteredClips: [ShortClip] {
        var clips = appState.project.clips
        if let statusFilter {
            clips = clips.filter { $0.status == statusFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            clips = clips.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        return clips
    }

    private var selectedClip: ShortClip? {
        if let id = appState.windowState.selectedClipID, let clip = appState.clip(id: id) {
            return clip
        }
        return filteredClips.first
    }

    var body: some View {
        HStack(spacing: 0) {
            clipList
                .frame(width: 248)
                .background(theme.panelBackground)
                .clipLayoutFrame("list")

            Divider()
                .overlay(theme.divider)

            if let clip = selectedClip {
                ClipEditorView(clip: clip)
                    .id(clip.id)
                    .clipLayoutFrame("editor")
            } else if !appState.project.clips.isEmpty {
                noMatchesState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .coordinateSpace(name: "clips-panel")
        .onPreferenceChange(ClipFramePreferenceKey.self) { frames in
            guard let layoutProbeToken else { return }
            ClipLayoutRegistry.shared.set(frames, token: layoutProbeToken)
        }
        .background(theme.editorSurface)
        .accessibilityIdentifier("clips-panel")
        .onAppear(perform: ensureSelection)
        .onChange(of: appState.project.clips.map(\.id)) { _, _ in
            ensureSelection()
        }
    }

    private func ensureSelection() {
        if let id = appState.windowState.selectedClipID, appState.clip(id: id) != nil {
            return
        }
        appState.windowState.selectedClipID = filteredClips.first?.id
    }

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.localized("clips.title"))
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button {
                    appState.createClipFromSelectedScene()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.hover)
                        }
                }
                .buttonStyle(.cursorPlain)
                .help(appState.localized("clips.newFromScene"))
                .accessibilityIdentifier("clips-new-button")
            }

            summaryLine

            Picker("", selection: $statusFilter) {
                Text(appState.localized("clips.list.all")).tag(Optional<ShortClipStatus>.none)
                ForEach(ShortClipStatus.allCases) { status in
                    Text(appState.localized("clips.status.\(status.rawValue)")).tag(Optional(status))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(appState.localized("clips.list.search"), text: $searchText)
                .textFieldStyle(QuietTextFieldStyle())
                .frame(height: 30)

            if filteredClips.isEmpty {
                Text(appState.project.clips.isEmpty
                    ? appState.localized("clips.list.empty")
                    : appState.localized("clips.list.noMatches"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredClips) { clip in
                            clipRow(clip)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityIdentifier("clips-list")
    }

    private var summaryLine: some View {
        let summary = appState.clipsSummary
        return HStack(spacing: 5) {
            Text(String(format: appState.localized("clips.summary.count"), summary.total))
            if summary.stale > 0 {
                Text("·")
                Text(String(format: appState.localized("clips.summary.stale"), summary.stale))
                    .foregroundStyle(theme.warning)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.secondaryText)
        .accessibilityIdentifier("clips-summary")
    }

    private func clipRow(_ clip: ShortClip) -> some View {
        let isSelected = appState.windowState.selectedClipID == clip.id
            || (appState.windowState.selectedClipID == nil && selectedClip?.id == clip.id)
        let estimate = appState.clipEstimate(for: clip)
        let isStale = appState.clipIsStale(clip)

        return Button {
            appState.windowState.selectedClipID = clip.id
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(statusColor(clip.status))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title.isEmpty ? appState.localized("clips.untitled") : clip.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(theme.primaryText)

                    HStack(spacing: 6) {
                        Text(appState.localized("clips.format.\(clip.format.rawValue)"))
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .frame(height: 16)
                            .background {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(theme.hover)
                            }
                        Text("\(DurationEstimator.formatted(estimate.seconds)) / \(DurationEstimator.formatted(estimate.targetSeconds))")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(fitColor(estimate))
                        if isStale {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(theme.warning)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.accentSoft : Color.clear)
            }
        }
        .buttonStyle(.cursorPlain)
        .contextMenu {
            Button(appState.localized("clips.duplicate")) { appState.duplicateClip(id: clip.id) }
            Divider()
            Button(appState.localized("clips.delete"), role: .destructive) { appState.deleteClip(id: clip.id) }
        }
        .accessibilityIdentifier("clip-row-\(clip.id.uuidString)")
    }

    private var noMatchesState: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("clips.list.noMatches"))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(theme.tertiaryText)
            Text(appState.localized("clips.empty.title"))
                .font(.system(size: 20, weight: .medium))
            Text(appState.localized("clips.empty.message"))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)
            HStack(spacing: 10) {
                Button(appState.localized("clips.newFromScene")) {
                    appState.createClipFromSelectedScene()
                }
                .buttonStyle(.bordered)
                Button(appState.localized("clips.command.create")) {
                    appState.createClipFromEditorSelection()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func statusColor(_ status: ShortClipStatus) -> Color {
        switch status {
        case .idea: theme.tertiaryText
        case .draft: theme.warning
        case .ready: theme.success
        case .published: theme.accent.color
        }
    }

    private func fitColor(_ estimate: ClipDurationEstimate) -> Color {
        switch estimate.fit {
        case .under: theme.warning
        case .onTarget: theme.success
        case .over: theme.destructive
        }
    }
}

/// One clip as a mini-project: source range, hook, adapted text, publishing
/// fields, coverage and export.
struct ClipEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let clip: ShortClip

    @State private var draft: ShortClip
    @State private var hashtagText: String
    @State private var isGenerating = false
    @State private var isExportPresented = false
    @State private var didCopy = false

    init(clip: ShortClip) {
        self.clip = clip
        _draft = State(initialValue: clip)
        _hashtagText = State(initialValue: ClipHashtags.text(clip.hashtags))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                staleBanner

                header
                    .clipLayoutFrame("header")

                sourceSection
                    .clipLayoutFrame("source")

                hookSection
                    .clipLayoutFrame("hook")

                adaptedSection
                    .clipLayoutFrame("adapted")

                publishingSection
                    .clipLayoutFrame("publishing")

                coverageSection
                    .clipLayoutFrame("coverage")

                exportSection
                    .clipLayoutFrame("export")
            }
            .padding(18)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .accessibilityIdentifier("clip-editor")
        .onChange(of: clip) { _, newValue in
            guard newValue != draft else { return }
            draft = newValue
            hashtagText = ClipHashtags.text(newValue.hashtags)
        }
        .onChange(of: draft) { _, newValue in
            appState.updateClip(newValue)
        }
        .onChange(of: hashtagText) { _, newValue in
            draft.hashtags = ClipHashtags.parse(newValue)
        }
        .sheet(isPresented: $isExportPresented) {
            ClipExportSheet(clip: draft)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(appState.localized("clips.titlePlaceholder"), text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold))
                .textCursor()
                .accessibilityIdentifier("clip-title-field")

            HStack(spacing: 10) {
                Picker("", selection: $draft.status) {
                    ForEach(ShortClipStatus.allCases) { status in
                        Text(appState.localized("clips.status.\(status.rawValue)")).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)

                Picker("", selection: $draft.format) {
                    ForEach(ShortClipFormat.allCases) { format in
                        Text(appState.localized("clips.format.\(format.rawValue)")).tag(format)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)

                Spacer(minLength: 0)

                Text(appState.localized("clips.target"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                ForEach(ClipLimits.targetOptions, id: \.self) { seconds in
                    Button {
                        draft.targetSeconds = seconds
                    } label: {
                        Text("\(Int(seconds)) s")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(draft.targetSeconds == seconds ? theme.accentSoft : theme.hover)
                            }
                    }
                    .buttonStyle(.cursorPlain)
                    .accessibilityIdentifier("clip-target-\(Int(seconds))")
                }
            }
        }
    }

    private var sourceSection: some View {
        clipSection(appState.localized("clips.source")) {
            VStack(alignment: .leading, spacing: 8) {
                if let anchor = draft.anchor {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "text.quote")
                            .foregroundStyle(theme.accent.color)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(appState.localized("clips.source.anchor"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                            Text(anchor.selectedText)
                                .font(.system(size: 12))
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button(appState.localized("clips.source.useWholeScene")) {
                            appState.useWholeSceneForClip(id: draft.id)
                        }
                        .buttonStyle(.cursorPlain)
                    }
                    .padding(9)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(theme.cardBackground)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.divider))
                    }
                }

                Text(appState.localized("clips.source.scenes"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                ForEach(appState.project.scenes.sortedByOrder) { scene in
                    Toggle(isOn: Binding(
                        get: { draft.sourceSceneIDs.contains(scene.id) },
                        set: { isOn in
                            if isOn {
                                if !draft.sourceSceneIDs.contains(scene.id) {
                                    draft.sourceSceneIDs.append(scene.id)
                                }
                            } else {
                                draft.sourceSceneIDs.removeAll { $0 == scene.id }
                                if draft.anchorSceneID == scene.id {
                                    draft.anchor = nil
                                    draft.anchorSceneID = nil
                                }
                            }
                        }
                    )) {
                        Text(scene.title.isEmpty ? appState.localized("clips.untitledScene") : scene.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }

                if draft.sourceSceneIDs.isEmpty {
                    Text(appState.localized("clips.source.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.warning)
                }
            }
        }
    }

    private var hookSection: some View {
        let estimate = appState.clipEstimate(for: draft)
        return clipSection(appState.localized("clips.hook")) {
            VStack(alignment: .leading, spacing: 7) {
                MultilineField(
                    placeholder: appState.localized("clips.hook.placeholder"),
                    text: $draft.hook,
                    minHeight: 58
                )
                .accessibilityIdentifier("clip-hook-field")

                HStack(spacing: 8) {
                    Text(String(format: appState.localized("clips.hook.seconds"), Int(estimate.hookSeconds.rounded())))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    switch estimate.hookFit {
                    case .empty:
                        Text(appState.localized("clips.hook.empty"))
                            .foregroundStyle(theme.secondaryText)
                    case .tooShort:
                        Text(appState.localized("clips.hook.tooShort"))
                            .foregroundStyle(theme.warning)
                    case .tooLong:
                        Text(appState.localized("clips.hook.tooLong"))
                            .foregroundStyle(theme.warning)
                    case .ok:
                        Text(appState.localized("clips.hook.ok"))
                            .foregroundStyle(theme.success)
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    private var adaptedSection: some View {
        let estimate = appState.clipEstimate(for: draft)
        let unsupportedNumbers = appState.clipFactWarning(for: draft)
        return clipSection(appState.localized("clips.adaptedText")) {
            VStack(alignment: .leading, spacing: 9) {
                MultilineField(
                    placeholder: appState.localized("clips.adaptedText.placeholder"),
                    text: $draft.adaptedText,
                    minHeight: 150
                )
                .accessibilityIdentifier("clip-adapted-field")

                estimateBar(estimate)

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isGenerating = true
                            await appState.generateClipAdaptation(id: draft.id)
                            isGenerating = false
                        }
                    } label: {
                        Label(
                            appState.localized(isGenerating ? "clips.generating" : "clips.generate"),
                            systemImage: "sparkles"
                        )
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.cursorPlain)
                    .disabled(isGenerating)

                    Button(appState.localized("clips.useSourceText")) {
                        let coreClip = FrameScriptDocument.ShortClip(clip: draft)
                        draft.adaptedText = ClipSourceExtractor.sourceText(
                            clip: coreClip,
                            scenes: appState.clipSourceScenes
                        )
                    }
                    .buttonStyle(.cursorPlain)

                    Spacer(minLength: 0)
                }

                if !unsupportedNumbers.isEmpty {
                    Label(
                        String(format: appState.localized("clips.factWarning"), unsupportedNumbers.joined(separator: ", ")),
                        systemImage: "number.circle"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func estimateBar(_ estimate: ClipDurationEstimate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("≈ \(DurationEstimator.formatted(estimate.seconds))")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("/ \(DurationEstimator.formatted(estimate.targetSeconds))")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Text(fitLabel(estimate))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fitColor(estimate))
            }
            ProgressView(value: min(1, estimate.seconds / max(1, estimate.targetSeconds)))
                .progressViewStyle(.linear)
                .tint(fitColor(estimate))
        }
        .accessibilityIdentifier("clip-estimate")
    }

    private var publishingSection: some View {
        clipSection(appState.localized("clips.publishing")) {
            VStack(alignment: .leading, spacing: 10) {
                QuietField(appState.localized("clips.onScreenText")) {
                    TextField(appState.localized("clips.onScreenText.placeholder"), text: $draft.onScreenText)
                        .textFieldStyle(QuietTextFieldStyle())
                }
                QuietField(appState.localized("clips.description")) {
                    MultilineField(
                        placeholder: appState.localized("clips.description.placeholder"),
                        text: $draft.description,
                        minHeight: 64
                    )
                }
                QuietField(appState.localized("clips.hashtags")) {
                    TextField(appState.localized("clips.hashtags.placeholder"), text: $hashtagText)
                        .textFieldStyle(QuietTextFieldStyle())
                }
            }
        }
    }

    private var coverageSection: some View {
        let takes = appState.clipCoverage(for: draft)
        let assets = appState.clipAssets(for: draft)
        return clipSection(appState.localized("clips.coverage")) {
            VStack(alignment: .leading, spacing: 8) {
                if takes.isEmpty {
                    Text(appState.localized("clips.coverage.noTakes"))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(takes) { item in
                        HStack(spacing: 7) {
                            Text(item.sceneTitle)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Text(String(format: appState.localized("clips.coverage.take"), item.take.number))
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Text(appState.localized("duration.rating.\(item.take.rating.rawValue)"))
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryText)
                            Text(DurationEstimator.formatted(item.take.duration))
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Text(item.languageCode.uppercased())
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                            Spacer(minLength: 0)
                            if let covers = item.coversAnchor {
                                Image(systemName: covers ? "checkmark.circle.fill" : "circle.dashed")
                                    .font(.system(size: 10))
                                    .foregroundStyle(covers ? theme.success : theme.tertiaryText)
                                    .help(appState.localized(covers ? "clips.coverage.covers" : "clips.coverage.partial"))
                            }
                        }
                    }
                }

                if !assets.isEmpty {
                    Divider().overlay(theme.divider)
                    ForEach(assets) { asset in
                        HStack(spacing: 6) {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.tertiaryText)
                            Text(URL(fileURLWithPath: asset.path).lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Text(asset.kind.rawValue)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                }
            }
        }
    }

    private var exportSection: some View {
        clipSection(appState.localized("clips.export.section")) {
            HStack(spacing: 10) {
                Button {
                    isExportPresented = true
                } label: {
                    Label(appState.localized("clips.export.open"), systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.cursorPlain)
                .accessibilityIdentifier("clip-export-button")

                Button {
                    if appState.copyClipExportToPasteboard(id: draft.id) {
                        didCopy = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            didCopy = false
                        }
                    }
                } label: {
                    Label(
                        appState.localized(didCopy ? "clips.export.copied" : "clips.export.copy"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.cursorPlain)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var staleBanner: some View {
        let report = appState.clipStaleness(for: draft)
        if report.isStale || report.hasUnresolvedAnchor {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label(appState.localized("clips.stale.title"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                    if report.isStale {
                        Button(appState.localized("clips.stale.markReviewed")) {
                            appState.markClipReviewed(id: draft.id)
                        }
                        .buttonStyle(.cursorPlain)
                    }
                }

                if report.hasUnresolvedAnchor {
                    HStack(spacing: 8) {
                        Text(appState.localized("clips.stale.anchorMissing"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.warning)
                        Button(appState.localized("clips.source.useWholeScene")) {
                            appState.useWholeSceneForClip(id: draft.id)
                        }
                        .buttonStyle(.cursorPlain)
                    }
                }

                ForEach(report.changes, id: \.sceneID) { change in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(change.sceneTitle.isEmpty
                            ? appState.localized("clips.stale.missingScene")
                            : change.sceneTitle)
                            .font(.system(size: 11, weight: .medium))
                        ForEach(Array(change.changeSummary().enumerated()), id: \.offset) { _, chunk in
                            Text((chunk.kind == .inserted ? "+ " : "− ") + chunk.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 11))
                                .foregroundStyle(chunk.kind == .inserted ? theme.success : theme.destructive)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(11)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.warning.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warning.opacity(0.35)))
            }
            .accessibilityIdentifier("clip-stale-banner")
        }
    }

    private func clipSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fitLabel(_ estimate: ClipDurationEstimate) -> String {
        switch estimate.fit {
        case .under:
            String(format: appState.localized("clips.estimate.under"), Int(estimate.underrun.rounded()))
        case .onTarget:
            appState.localized("clips.estimate.onTarget")
        case .over:
            String(format: appState.localized("clips.estimate.over"), Int(estimate.overrun.rounded()))
        }
    }

    private func fitColor(_ estimate: ClipDurationEstimate) -> Color {
        switch estimate.fit {
        case .under: theme.warning
        case .onTarget: theme.success
        case .over: theme.destructive
        }
    }
}

/// Text export preview with copy and Resolve marker actions.
struct ClipExportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let clip: ShortClip
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appState.localized("clips.export.title"))
                .font(.system(size: 20, weight: .semibold))

            ScrollView {
                Text(appState.clipExportDocument(for: clip).plainText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(width: 540, height: 330)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.editorSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
            }

            HStack(spacing: 10) {
                Button(appState.localized("project.unsaved.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .clickableCursor()

                Spacer()

                Button {
                    if appState.copyClipExportToPasteboard(id: clip.id) {
                        didCopy = true
                    }
                } label: {
                    Label(
                        appState.localized(didCopy ? "clips.export.copied" : "clips.export.copy"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
                .clickableCursor()

                Button(appState.localized("clips.export.saveEDL")) {
                    appState.saveClipMarkers(id: clip.id, format: .edl)
                }
                .clickableCursor()

                Button(appState.localized("clips.export.saveFCPXML")) {
                    appState.saveClipMarkers(id: clip.id, format: .fcpxml)
                }
                .clickableCursor()
            }
        }
        .padding(24)
        .frame(width: 620)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("clip-export-sheet")
    }
}
