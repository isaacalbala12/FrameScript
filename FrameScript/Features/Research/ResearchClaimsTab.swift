import FrameScriptCore
import SwiftUI

struct ResearchClaimsTab: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Bindable private var presentation = ResearchPresentation.shared

    private var claims: [ProjectClaim] {
        appState.filteredResearchClaims()
    }

    private var targetSceneID: UUID? {
        presentation.focusedSceneID ?? appState.selectedScene?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            countsBar
            filtersBar
            Divider().overlay(theme.divider)

            ScrollView {
                LazyVStack(spacing: 10) {
                    if let sceneID = presentation.focusedSceneID {
                        sceneFilterBanner(sceneID)
                    }

                    suggestionsSection

                    ForEach(claims) { claim in
                        ResearchClaimCard(claim: claim)
                    }

                    if claims.isEmpty {
                        if appState.project.claims.isEmpty {
                            ResearchEmptyState(
                                title: appState.localized("research.claims.empty.title"),
                                message: appState.localized("research.claims.empty.message"),
                                actionTitle: appState.localized("research.claims.add")
                            ) {
                                addClaim()
                            }
                            .frame(minHeight: 220)
                        } else {
                            ResearchEmptyState(
                                title: appState.localized("research.claims.noMatches.title"),
                                message: appState.localized("research.claims.noMatches.message"),
                                actionTitle: appState.localized("research.claims.noMatches.clear")
                            ) {
                                presentation.statusFilter = Set(ClaimStatus.allCases)
                                presentation.onlyPending = false
                                presentation.focusedSceneID = nil
                                presentation.searchText = ""
                            }
                            .frame(minHeight: 220)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var countsBar: some View {
        HStack(spacing: 10) {
            Text(researchCountsText(appState.researchCounts(), appState: appState))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button {
                addClaim()
            } label: {
                Label(appState.localized("research.claims.add"), systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.framePrimary)
            .accessibilityIdentifier("research-add-claim")

            Button {
                guard let sceneID = targetSceneID else { return }
                Task { await appState.suggestResearchClaims(for: sceneID) }
            } label: {
                HStack(spacing: 5) {
                    if presentation.isCheckingClaims {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(appState.localized("research.claims.suggest"))
                }
                .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.cursorPlain)
            .disabled(
                presentation.isCheckingClaims
                    || targetSceneID == nil
                    || appState.settings.aiPreferences.provider == .disabled
            )
            .help(
                appState.settings.aiPreferences.provider == .disabled
                    ? appState.localized("research.claims.aiDisabled")
                    : appState.localized("research.claims.suggestHelp")
            )
            .accessibilityIdentifier("research-suggest-claims")
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
    }

    private var filtersBar: some View {
        HStack(spacing: 8) {
            ForEach(ClaimStatus.allCases) { status in
                statusChip(status)
            }

            Button {
                presentation.onlyPending.toggle()
            } label: {
                Text(appState.localized("research.claims.filter.onlyPending"))
                    .font(.system(size: 11, weight: presentation.onlyPending ? .semibold : .regular))
                    .foregroundStyle(presentation.onlyPending ? theme.warning : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        Capsule().fill(presentation.onlyPending ? theme.warning.opacity(0.16) : theme.hover)
                    }
            }
            .buttonStyle(.cursorPlain)

            Menu {
                Button {
                    presentation.focusedSceneID = nil
                } label: {
                    if presentation.focusedSceneID == nil {
                        Label(appState.localized("research.claims.filter.allScenes"), systemImage: "checkmark")
                    } else {
                        Text(appState.localized("research.claims.filter.allScenes"))
                    }
                }
                Divider()
                ForEach(appState.project.scenes.sortedByOrder) { scene in
                    Button {
                        presentation.focusedSceneID = scene.id
                    } label: {
                        if presentation.focusedSceneID == scene.id {
                            Label(scene.title, systemImage: "checkmark")
                        } else {
                            Text(scene.title)
                        }
                    }
                }
            } label: {
                Label(
                    presentation.focusedSceneID.map(appState.sceneTitle(for:))
                        ?? appState.localized("research.claims.filter.allScenes"),
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 190)

            Spacer(minLength: 4)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                TextField(appState.localized("research.claims.search"), text: $presentation.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(width: 190, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.editorSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 42)
    }

    private func statusChip(_ status: ClaimStatus) -> some View {
        let isOn = presentation.statusFilter.contains(status)
        let color = researchStatusColor(status, theme: theme)
        return Button {
            if isOn {
                presentation.statusFilter.remove(status)
            } else {
                presentation.statusFilter.insert(status)
            }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(appState.localized(status.researchLocalizationKey))
                    .font(.system(size: 11, weight: isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? theme.primaryText : theme.tertiaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background {
                Capsule().fill(isOn ? color.opacity(0.14) : theme.hover)
            }
        }
        .buttonStyle(.cursorPlain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func sceneFilterBanner(_ sceneID: UUID) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 11))
            Text(String(format: appState.localized("research.claims.filteredByScene"), appState.sceneTitle(for: sceneID)))
                .font(.system(size: 12))
            Spacer()
            Button(appState.localized("research.claims.filter.clear")) {
                presentation.clearSceneFilter()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.accent.color)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.accentSoft.opacity(0.5))
        }
    }

    @ViewBuilder
    private var suggestionsSection: some View {
        if presentation.isCheckingClaims {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(appState.localized("research.claims.suggesting"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.sidebarBackground.opacity(0.6))
            }
        }

        if let message = presentation.checkErrorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(theme.warning)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.warning.opacity(0.1))
                }
        }

        if !presentation.claimSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(appState.localized("research.claims.suggestions"))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button(appState.localized("research.claims.suggestionsClear")) {
                        presentation.claimSuggestions = []
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                }

                Text(appState.localized("research.claims.suggestionDisclaimer"))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(presentation.claimSuggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.claimSuggestionBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(theme.divider, lineWidth: 1)
                    )
            }
        }
    }

    private func suggestionRow(_ suggestion: ClaimSuggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(researchStatusColor(appStatus(suggestion.status), theme: theme))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(appState.localized(appStatus(suggestion.status).researchLocalizationKey))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(researchStatusColor(appStatus(suggestion.status), theme: theme))
                    if !suggestion.reason.isEmpty {
                        Text(suggestion.reason)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.tertiaryText)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Button(appState.localized("research.claims.suggestionAccept")) {
                appState.acceptResearchClaimSuggestion(suggestion)
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11, weight: .medium))

            Button(appState.localized("research.claims.suggestionDismiss")) {
                appState.dismissResearchClaimSuggestion(suggestion)
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.vertical, 5)
    }

    private func addClaim() {
        let sceneIDs = presentation.focusedSceneID.map { [$0] } ?? []
        _ = appState.addResearchClaim(text: "", status: .probable, sceneIDs: sceneIDs)
    }

    private func appStatus(_ status: FrameScriptDocument.ClaimStatus) -> ClaimStatus {
        ClaimStatus(rawValue: status.rawValue) ?? .probable
    }
}

private struct ResearchClaimCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    let claim: ProjectClaim
    @State private var anchorDraft = ""
    @State private var anchorMissing = false
    @State private var isConfirmingDelete = false

    private var anchorState: ResearchClaimAnchorState {
        appState.researchClaimAnchorState(claim)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(researchStatusColor(claim.status, theme: theme))
                    .frame(width: 8, height: 8)

                Picker("", selection: status) {
                    ForEach(ClaimStatus.allCases) { status in
                        Text(appState.localized(status.researchLocalizationKey)).tag(status)
                    }
                }
                .labelsHidden()
                .frame(width: 178)
                .help(appState.localized("research.claims.status"))

                Button {
                    appState.toggleResearchClaimVerification(id: claim.id)
                } label: {
                    Label(
                        appState.localized("research.claims.needsVerification"),
                        systemImage: claim.needsVerification ? "checkmark.square.fill" : "square"
                    )
                    .font(.system(size: 11, weight: claim.needsVerification ? .semibold : .regular))
                    .foregroundStyle(claim.needsVerification ? theme.warning : theme.secondaryText)
                }
                .buttonStyle(.cursorPlain)

                if claim.personalExperience {
                    Text(appState.localized("research.claims.personalExperience"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(theme.accentSoft))
                }

                Spacer(minLength: 8)

                Button {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.tertiaryText)
                .help(appState.localized("research.claims.delete"))
                .accessibilityLabel(appState.localized("research.claims.delete"))
            }

            MultilineField(
                placeholder: appState.localized("research.claims.textPlaceholder"),
                text: text,
                minHeight: 48
            )

            HStack(spacing: 10) {
                sceneMenu
                sourceMenu
                Spacer(minLength: 4)
                personalToggle
            }

            if !claim.sceneIDs.isEmpty {
                anchorEditor
            }

            DisclosureGroup {
                MultilineField(
                    placeholder: appState.localized("research.claims.resolutionPlaceholder"),
                    text: resolutionNote,
                    minHeight: 42
                )
                .padding(.top, 6)
            } label: {
                Text(appState.localized("research.claims.resolution"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .accessibilityIdentifier("research-claim-card-\(claim.id.uuidString)")
        .onAppear(perform: syncAnchorDraft)
        .onChange(of: claim.anchor?.selectedText) { _, _ in syncAnchorDraft() }
        .alert(appState.localized("research.claims.deleteConfirmTitle"), isPresented: $isConfirmingDelete) {
            Button(appState.localized("research.claims.delete"), role: .destructive) {
                appState.deleteResearchClaim(id: claim.id)
            }
            Button(appState.localized("project.unsaved.cancel"), role: .cancel) {}
        } message: {
            Text(appState.localized("research.claims.deleteConfirmMessage"))
        }
    }

    private var sceneMenu: some View {
        Menu {
            Button {
                appState.setResearchClaimScene(id: claim.id, sceneID: nil)
            } label: {
                if claim.sceneIDs.isEmpty {
                    Label(appState.localized("research.claims.noScene"), systemImage: "checkmark")
                } else {
                    Text(appState.localized("research.claims.noScene"))
                }
            }
            Divider()
            ForEach(appState.project.scenes.sortedByOrder) { scene in
                Button {
                    appState.toggleResearchClaimScene(id: claim.id, sceneID: scene.id)
                } label: {
                    if claim.sceneIDs.contains(scene.id) {
                        Label(scene.title, systemImage: "checkmark")
                    } else {
                        Text(scene.title)
                    }
                }
            }
        } label: {
            Label(sceneLabel, systemImage: "film")
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 230)
        .foregroundStyle(theme.secondaryText)
        .help(appState.localized("research.claims.scenes"))
    }

    private var sourceMenu: some View {
        Menu {
            if appState.project.sources.isEmpty {
                Text(appState.localized("research.claims.noSources"))
            } else {
                ForEach(appState.project.sources) { source in
                    Button {
                        appState.toggleResearchClaimSource(id: claim.id, sourceID: source.id)
                    } label: {
                        if claim.sourceIDs.contains(source.id) {
                            Label(source.title.isEmpty ? appState.localized("research.sources.untitled") : source.title, systemImage: "checkmark")
                        } else {
                            Text(source.title.isEmpty ? appState.localized("research.sources.untitled") : source.title)
                        }
                    }
                }
            }
        } label: {
            Label(sourceLabel, systemImage: "book.closed")
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 230)
        .foregroundStyle(theme.secondaryText)
        .help(appState.localized("research.claims.sources"))
    }

    private var personalToggle: some View {
        Button {
            var copy = claim
            copy.personalExperience.toggle()
            appState.updateResearchClaim(copy)
        } label: {
            Label(
                appState.localized("research.claims.personalExperience"),
                systemImage: claim.personalExperience ? "person.fill.checkmark" : "person"
            )
            .font(.system(size: 11))
            .foregroundStyle(claim.personalExperience ? theme.accent.color : theme.secondaryText)
        }
        .buttonStyle(.cursorPlain)
        .help(appState.localized("research.claims.personalExperienceHelp"))
    }

    private var anchorEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 11))
                .foregroundStyle(theme.tertiaryText)
            TextField(appState.localized("research.claims.anchorPlaceholder"), text: $anchorDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit(linkAnchor)
            Button(anchorState.isStale
                ? appState.localized("research.claims.anchorRelink")
                : appState.localized("research.claims.anchorLink")
            ) {
                linkAnchor()
            }
            .buttonStyle(FrameSecondaryButtonStyle(size: .compact))
            .disabled(anchorDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if claim.anchor != nil {
                Button {
                    appState.clearResearchClaimAnchor(id: claim.id)
                    anchorDraft = ""
                    anchorMissing = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.cursorPlain)
                .foregroundStyle(theme.tertiaryText)
                .help(appState.localized("research.claims.anchorClear"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.editorSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            anchorMissing || anchorState.isStale ? theme.warning : theme.divider,
                            lineWidth: 1
                        )
                )
        }
        .overlay(alignment: .bottomLeading) {
            if anchorMissing {
                Text(appState.localized("research.claims.anchorNotFound"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.ensuredText(theme.warning))
                    .offset(y: 13)
            } else if anchorState.isStale {
                Text(anchorState == .missingScene
                    ? appState.localized("research.claims.anchorSceneMissing")
                    : appState.localized("research.claims.anchorStale")
                )
                .font(.system(size: 10))
                .foregroundStyle(theme.ensuredText(theme.warning))
                .offset(y: 13)
                .accessibilityIdentifier("research-claim-anchor-stale-\(claim.id.uuidString)")
            }
        }
        .padding(.bottom, anchorMissing || anchorState.isStale ? 10 : 0)
    }

    private func linkAnchor() {
        anchorMissing = !appState.setResearchClaimAnchor(id: claim.id, fragment: anchorDraft)
    }

    private func syncAnchorDraft() {
        anchorDraft = claim.anchor?.selectedText ?? ""
        anchorMissing = false
    }

    private var sceneLabel: String {
        let titles = claim.sceneIDs.compactMap { id in
            appState.project.scenes.first(where: { $0.id == id })?.title
        }
        return titles.isEmpty ? appState.localized("research.claims.noScene") : titles.joined(separator: ", ")
    }

    private var sourceLabel: String {
        let titles = claim.sourceIDs.compactMap { id in
            appState.project.sources.first(where: { $0.id == id })?.title
        }
        .filter { !$0.isEmpty }
        return titles.isEmpty
            ? appState.localized("research.claims.noSources")
            : titles.joined(separator: ", ")
    }

    private var text: Binding<String> {
        Binding(
            get: { claim.text },
            set: { value in
                var copy = claim
                copy.text = value
                appState.updateResearchClaim(copy)
            }
        )
    }

    private var status: Binding<ClaimStatus> {
        Binding(
            get: { claim.status },
            set: { value in
                appState.setResearchClaimStatus(id: claim.id, status: value)
            }
        )
    }

    private var resolutionNote: Binding<String> {
        Binding(
            get: { claim.resolutionNote },
            set: { value in
                var copy = claim
                copy.resolutionNote = value
                appState.updateResearchClaim(copy)
            }
        )
    }
}

private extension FrameTheme {
    var claimSuggestionBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.035) : Color.black.opacity(0.025)
    }
}
