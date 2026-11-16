import Foundation

public struct ResearchExportWarning: Sendable, Equatable, Identifiable {
    public let sceneID: UUID
    public let sceneTitle: String
    public let claimID: UUID
    public let claimText: String

    public var id: UUID { claimID }

    public init(
        sceneID: UUID,
        sceneTitle: String,
        claimID: UUID,
        claimText: String
    ) {
        self.sceneID = sceneID
        self.sceneTitle = sceneTitle
        self.claimID = claimID
        self.claimText = claimText
    }
}

/// The small slice of a scene that verification warnings need. The app builds
/// these on render without copying segments, takes or production items.
public struct ResearchSceneSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let order: Int
    public let title: String
    public let scriptText: String
    public let bRollText: [String]
    public let editingText: [String]

    public init(
        id: UUID,
        order: Int,
        title: String,
        scriptText: String,
        bRollText: [String] = [],
        editingText: [String] = []
    ) {
        self.id = id
        self.order = order
        self.title = title
        self.scriptText = scriptText
        self.bRollText = bRollText
        self.editingText = editingText
    }
}

/// Spanish output for the "Fuentes y verificación" appendix. The channel's
/// publishing copy is Spanish, and the appendix is pasted into a description or
/// a Markdown handoff, not into the localized app UI.
public enum ResearchExport {
    public static let appendixHeading = "Fuentes y verificación"
    public static let warningHeading = "Avisos de verificación"

    // MARK: Appendix

    public static func markdownAppendix(
        project: FrameScriptDocument.Project
    ) -> String {
        guard !project.sources.isEmpty || !project.claims.isEmpty else { return "" }

        var lines: [String] = ["## \(appendixHeading)", ""]

        if !project.sources.isEmpty {
            lines.append("### Fuentes")
            for source in project.sources {
                var detail = [sourceKindLabel(source.kind), "fiabilidad \(reliabilityLabel(source.reliability))"]
                if let date = source.date {
                    detail.append(formattedDay(date))
                }
                let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                var entry = "- **\(title.isEmpty ? "Fuente sin título" : title)** — \(detail.joined(separator: " · "))"
                let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    entry += " — \(url)"
                }
                lines.append(entry)
                let note = source.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    lines.append("  \(note.replacingOccurrences(of: "\n", with: "\n  "))")
                }
            }
            lines.append("")
        }

        if !project.claims.isEmpty {
            lines.append("### Afirmaciones")
            let scenesByID = Dictionary(project.scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sourcesByID = Dictionary(project.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for claim in project.claims {
                let status = claimStatusLabel(claim.status)
                let marker = claim.needsVerification && !claim.personalExperience ? " · pendiente de verificación" : ""
                lines.append("- **\(status)**\(marker) — \(claim.text.trimmingCharacters(in: .whitespacesAndNewlines))")

                let sourceTitles = claim.sourceIDs.compactMap { sourcesByID[$0]?.title }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let sceneTitles = claim.sceneIDs.compactMap { scenesByID[$0]?.title }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                var context: [String] = []
                if !sourceTitles.isEmpty { context.append("Fuentes: \(sourceTitles.joined(separator: ", "))") }
                if !sceneTitles.isEmpty { context.append("Escenas: \(sceneTitles.joined(separator: ", "))") }
                if claim.personalExperience { context.append("Experiencia personal") }
                if !context.isEmpty {
                    lines.append("  \(context.joined(separator: " · "))")
                }
                let note = claim.resolutionNote.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    lines.append("  Nota: \(note.replacingOccurrences(of: "\n", with: "\n  "))")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Compact block for a YouTube/publishing description. The first line is a
    /// stable marker so the app can detect an already-inserted block.
    public static func descriptionBlock(
        project: FrameScriptDocument.Project
    ) -> String {
        guard !project.sources.isEmpty || !project.claims.isEmpty else { return "" }

        var lines: [String] = [appendixHeading]

        if !project.sources.isEmpty {
            lines.append("Fuentes:")
            for source in project.sources {
                let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let url = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
                var entry = "- \(title.isEmpty ? "Fuente sin título" : title)"
                if !url.isEmpty { entry += " — \(url)" }
                lines.append(entry)
            }
        }

        if !project.claims.isEmpty {
            lines.append("Afirmaciones:")
            for claim in project.claims {
                var entry = "- [\(claimStatusLabel(claim.status))] \(claim.text.trimmingCharacters(in: .whitespacesAndNewlines))"
                if claim.needsVerification && !claim.personalExperience {
                    entry += " (pendiente)"
                }
                lines.append(entry)
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Verification warnings

    /// A scene is safe only when every non-confirmed claim is either first-hand
    /// experience or has a visible disclaimer cue in the script or visuals.
    public static func warnings(
        project: FrameScriptDocument.Project
    ) -> [ResearchExportWarning] {
        warnings(
            scenes: project.scenes.map { scene in
                ResearchSceneSnapshot(
                    id: scene.id,
                    order: scene.order,
                    title: scene.title,
                    scriptText: scene.scriptText,
                    bRollText: scene.bRollItems.flatMap { [$0.descriptionText, $0.notes] },
                    editingText: scene.editingItems.flatMap { [$0.cutStyle, $0.notes] }
                )
            },
            claims: project.claims
        )
    }

    public static func warnings(
        scenes: [ResearchSceneSnapshot],
        claims: [FrameScriptDocument.Claim]
    ) -> [ResearchExportWarning] {
        var warnings: [ResearchExportWarning] = []
        for scene in scenes.sorted(by: { $0.order < $1.order }) {
            guard !hasDisclaimerCue(in: scene) else { continue }
            for claim in claims
            where claim.sceneIDs.contains(scene.id)
                && claim.status != .confirmed
                && !claim.personalExperience {
                warnings.append(
                    ResearchExportWarning(
                        sceneID: scene.id,
                        sceneTitle: scene.title,
                        claimID: claim.id,
                        claimText: claim.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }
        return warnings
    }

    public static func warningsMarkdown(
        project: FrameScriptDocument.Project
    ) -> String {
        let warnings = warnings(project: project)
        guard !warnings.isEmpty else { return "" }
        var lines = ["## \(warningHeading)", ""]
        for warning in warnings {
            lines.append(
                "- Escena «\(warning.sceneTitle)»: «\(warning.claimText)» sigue sin confirmar y no hay rótulo ni aviso."
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func hasDisclaimerCue(
        in scene: FrameScriptDocument.Scene
    ) -> Bool {
        hasDisclaimerCue(
            in: ResearchSceneSnapshot(
                id: scene.id,
                order: scene.order,
                title: scene.title,
                scriptText: scene.scriptText,
                bRollText: scene.bRollItems.flatMap { [$0.descriptionText, $0.notes] },
                editingText: scene.editingItems.flatMap { [$0.cutStyle, $0.notes] }
            )
        )
    }

    public static func hasDisclaimerCue(
        in scene: ResearchSceneSnapshot
    ) -> Bool {
        let haystack = ([scene.scriptText] + scene.bRollText + scene.editingText)
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
        let markers = [
            "rotulo",
            "disclaimer",
            "aviso legal",
            "aviso en pantalla",
            "aviso de",
            "[aviso",
            "aviso:"
        ]
        return markers.contains { haystack.contains($0) }
    }

    // MARK: Labels

    public static func claimStatusLabel(_ status: FrameScriptDocument.ClaimStatus) -> String {
        switch status {
        case .confirmed: "Confirmada"
        case .probable: "Probable"
        case .rumor: "Rumor"
        case .communityOpinion: "Opinión comunitaria"
        }
    }

    public static func sourceKindLabel(_ kind: FrameScriptDocument.SourceKind) -> String {
        switch kind {
        case .official: "oficial"
        case .press: "prensa"
        case .community: "foro/comunidad"
        case .video: "vídeo"
        case .data: "datos"
        case .other: "otra"
        }
    }

    public static func reliabilityLabel(_ reliability: FrameScriptDocument.SourceReliability) -> String {
        switch reliability {
        case .high: "alta"
        case .medium: "media"
        case .low: "baja"
        }
    }

    private static func formattedDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Source dates are calendar dates, not instants: format in the user's
        // time zone so a date picked at local midnight does not move a day.
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
