import SwiftUI
import FrameScriptCore

struct EscaletaImportPreviewSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(EscaletaImportCoordinator.self) private var coordinator
    @Environment(\.frameTheme) private var theme
    let request: EscaletaImportRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    modeExplanation
                    if let stats = request.mapping?.stats {
                        summary(stats)
                        scenes(stats)
                        bRoll(stats)
                        seo(stats)
                    }
                    if request.document.kind == .thumbnailConcepts {
                        thumbnailConcepts
                    }
                    if request.document.kind == .researchDossier || request.mode == .appendResearchDossier {
                        dossierSections
                    }
                    warnings
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider().overlay(theme.divider)
            footer
        }
        .frame(width: 720, height: 620)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(theme.accent.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized("escaleta.import.title"))
                    .font(.system(size: 18, weight: .semibold))
                Text(request.fileName)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(kindLabel)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(theme.accentSoft.opacity(0.55), in: Capsule())
        }
        .padding(20)
    }

    private var modeExplanation: some View {
        Text(explanation)
            .font(.system(size: 13))
            .foregroundStyle(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summary(_ stats: EscaletaMappingStats) -> some View {
        HStack(spacing: 10) {
            metric("escaleta.import.metric.scenes", "\(stats.sceneCount)")
            metric("escaleta.import.metric.cues", "\(stats.cueCount)")
            metric("escaleta.import.metric.broll", "\(stats.bRollCount)")
            metric("escaleta.import.metric.anchors", "\(stats.anchorsResolved)/\(stats.anchorsResolved + stats.anchorsUnresolved)")
            metric("escaleta.import.metric.sources", "\(stats.sourceCount)")
            metric("escaleta.import.metric.tables", "\(stats.comparisonTableCount)")
        }
    }

    private func metric(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
            Text(appState.localized(key))
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func scenes(_ stats: EscaletaMappingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.scenes")
            VStack(spacing: 0) {
                ForEach(stats.scenes) { scene in
                    HStack(spacing: 10) {
                        Text(scene.startText ?? "—")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.tertiaryText)
                            .frame(width: 52, alignment: .leading)
                        Text(scene.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        if scene.hasReHook {
                            Text("RE-HOOK")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.accent.color)
                        }
                        Spacer(minLength: 6)
                        if scene.bRollCount > 0 {
                            Text("\(scene.bRollCount) B-roll")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.secondaryText)
                        }
                        if let target = scene.targetSeconds {
                            Text(DurationEstimator.formatted(TimeInterval(target)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                        } else if scene.estimatedSeconds > 0 {
                            Text("~\(DurationEstimator.formatted(TimeInterval(scene.estimatedSeconds)))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    if scene.id != stats.scenes.last?.id {
                        Divider().overlay(theme.divider)
                    }
                }
            }
            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func bRoll(_ stats: EscaletaMappingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.broll")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(EscaletaBRollSource.allCases) { source in
                    let count = stats.bRollCount(for: source)
                    if count > 0 {
                        HStack(spacing: 6) {
                            Text(source.label(appState.currentLanguage))
                                .font(.system(size: 11))
                            Spacer(minLength: 4)
                            Text("\(count)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
    }

    private func seo(_ stats: EscaletaMappingStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.seo")
            if stats.seoFields.isEmpty {
                Text(appState.localized("escaleta.import.seo.none"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                    ForEach(stats.seoFields, id: \.rawValue) { field in
                        Text(appState.localized("escaleta.seo.\(field.rawValue)"))
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
            }
        }
    }

    private var thumbnailConcepts: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.thumbnailConcepts")
            if let groups = request.document.thumbnailConcepts?.groups {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack(spacing: 8) {
                        Text(group.title.isEmpty ? appState.localized("escaleta.import.group") : group.title)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(group.concepts.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
    }

    private var dossierSections: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.dossierSections")
            ForEach(Array(request.dossierSections.prefix(12).enumerated()), id: \.offset) { _, section in
                Text(section.heading)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if request.dossierSections.count > 12 {
                Text(String(format: appState.localized("escaleta.import.moreSections"), request.dossierSections.count - 12))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var warnings: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("escaleta.import.warnings")
            if request.warnings.isEmpty {
                Text(appState.localized("escaleta.import.noWarnings"))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            } else {
                ForEach(Array(request.warnings.enumerated()), id: \.offset) { _, warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            if let line = warning.line {
                                Text(String(format: appState.localized("escaleta.import.lineFormat"), line))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.tertiaryText)
                            }
                            Text(warning.message)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(appState.localized("escaleta.import.cancel")) {
                coordinator.dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .clickableCursor()

            Spacer()

            Button(confirmLabel) {
                if appState.confirmEscaletaImport(request) {
                    coordinator.dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!request.isConfirmEnabled)
            .clickableCursor()
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(appState.localized(key))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.secondaryText)
    }

    private var kindLabel: String {
        switch request.document.kind {
        case .escaleta: appState.localized("escaleta.kind.escaleta")
        case .thumbnailConcepts: appState.localized("escaleta.kind.thumbnailConcepts")
        case .researchDossier: appState.localized("escaleta.kind.researchDossier")
        case .other: appState.localized("escaleta.kind.other")
        }
    }

    private var confirmLabel: String {
        switch request.mode {
        case .newProject: appState.localized("escaleta.import.createProject")
        case .appendThumbnailConcepts, .appendResearchDossier: appState.localized("escaleta.import.addToProject")
        case .requiresOpenProject, .unsupported: appState.localized("escaleta.import.createProject")
        }
    }

    private var explanation: String {
        switch request.mode {
        case .newProject:
            String(format: appState.localized("escaleta.import.explanation.newProject"), request.document.scenes.count)
        case .appendThumbnailConcepts:
            String(
                format: appState.localized("escaleta.import.explanation.thumbnails"),
                request.thumbnailConceptCount,
                appState.project.title
            )
        case .appendResearchDossier:
            String(
                format: appState.localized("escaleta.import.explanation.dossier"),
                request.dossierSections.count,
                appState.project.title
            )
        case .requiresOpenProject:
            appState.localized("escaleta.import.explanation.requiresOpenProject")
        case .unsupported:
            appState.localized("escaleta.import.explanation.unsupported")
        }
    }
}

struct EscaletaImportSheetModifier: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(EscaletaImportCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        @Bindable var coordinator = coordinator
        content.sheet(item: $coordinator.request) { request in
            EscaletaImportPreviewSheet(request: request)
                .environment(appState)
                .environment(coordinator)
                .environment(\.frameTheme, appState.themeManager.frameTheme)
        }
    }
}

extension View {
    func escaletaImportSheet() -> some View {
        modifier(EscaletaImportSheetModifier())
    }
}
