import Foundation
import FrameScriptCore

/// Wave 2 keeps the persisted `BRollSourceType` frozen, so the importer keeps
/// the §3.4 vocabulary in its own type and maps it to the closest existing
/// source when it writes a `BRollItem`. The original cue is kept in notes so a
/// later CaptureSpec migration can recover the exact source.
enum EscaletaBRollSource: String, CaseIterable, Sendable, Identifiable {
    case unspecified
    case screenshot
    case obsGameplay
    case camera
    case graphic
    case table

    var id: String { rawValue }

    var appSourceType: BRollSourceType {
        switch self {
        case .unspecified: .custom
        case .screenshot: .screenshot
        case .obsGameplay: .screenRecording
        case .camera: .talkingHead
        case .graphic: .textOnScreen
        case .table: .infographic
        }
    }

    func label(_ language: AppLanguage) -> String {
        L10n.tr("escaleta.source.\(rawValue)", language: language)
    }
}

struct EscaletaMappingOptions: Sendable {
    var primaryLanguage: String
    var wordsPerMinute: Int

    init(primaryLanguage: String = "es", wordsPerMinute: Int = 150) {
        self.primaryLanguage = primaryLanguage
        self.wordsPerMinute = max(1, wordsPerMinute)
    }
}

struct EscaletaSceneSummary: Identifiable, Equatable, Sendable {
    let id: Int
    let order: Int
    let title: String
    let startText: String?
    let targetSeconds: Int?
    let estimatedSeconds: Int
    let bRollCount: Int
    let hasReHook: Bool
}

struct EscaletaMappingStats: Equatable, Sendable {
    var sceneCount = 0
    var cueCount = 0
    var bRollBySource: [EscaletaBRollSource: Int] = [:]
    var anchorsResolved = 0
    var anchorsUnresolved = 0
    var recordingNoteCount = 0
    var reHookCount = 0
    var seoFields: [EscaletaPublishingField] = []
    var sourceCount = 0
    var claimCount = 0
    var checklistTaskCount = 0
    var comparisonTableCount = 0
    var unparsedSectionCount = 0
    var scenes: [EscaletaSceneSummary] = []

    var bRollCount: Int { bRollBySource.values.reduce(0, +) }

    func bRollCount(for source: EscaletaBRollSource) -> Int {
        bRollBySource[source, default: 0]
    }
}

/// A project built entirely in memory. Confirming the preview only opens this
/// value; dismissing it has no side effects on the current project.
struct EscaletaProjectMapping {
    let project: FrameProject
    let warnings: [EscaletaWarning]
    let stats: EscaletaMappingStats
    let document: EscaletaDocument
}

@MainActor
enum EscaletaProjectMapper {
    static func map(
        _ result: EscaletaImportResult,
        options: EscaletaMappingOptions = EscaletaMappingOptions()
    ) -> EscaletaProjectMapping {
        let document = result.document
        var stats = EscaletaMappingStats()
        var warnings = result.warnings

        let sceneStarts = document.scenes.map(\.startSeconds)
        var scenes: [Scene] = []
        var sceneIDsByStart: [Int: UUID] = [:]

        for (index, documentScene) in document.scenes.enumerated() {
            let nextStart = nextSceneStart(after: index, in: sceneStarts)
            let scene = mapScene(
                documentScene,
                order: index,
                nextStart: nextStart,
                options: options,
                warnings: &warnings,
                stats: &stats
            )
            scenes.append(scene)
            if let start = documentScene.startSeconds, sceneIDsByStart[start] == nil {
                sceneIDsByStart[start] = scene.id
            }
        }

        let notes = EscaletaProjectNotes(
            promise: document.promise,
            thesis: document.thesis,
            versionNote: document.versionNote,
            scriptIntro: document.scriptIntro,
            pacingNotes: document.pacingNotes
        )
        let pack = makePublishingPack(
            document.publishing,
            scenes: scenes,
            sceneIDsByStart: sceneIDsByStart,
            stats: &stats
        )
        let sources = makeSources(document.sources)
        let verification = makeVerification(document.verificationItems)
        let tables = makeTables(document)
        let unparsed = makeUnparsedSections(document)
        let videoType = guessVideoType(document)

        var targetSeconds: TimeInterval = 0
        for scene in scenes {
            targetSeconds += scene.targetDuration ?? scene.estimatedDuration
        }

        let project = FrameProject(
            title: document.title,
            scenes: scenes,
            primaryLanguage: options.primaryLanguage,
            topic: notes.encoded(),
            videoType: videoType,
            productionStatus: document.scenes.isEmpty ? .outline : .script,
            targetDuration: targetSeconds > 0 ? targetSeconds : nil,
            publishingPacks: hasPublishingContent(pack) ? [options.primaryLanguage: pack] : [:],
            checklistTasks: verification.tasks,
            sources: sources,
            claims: verification.claims,
            comparisonTables: tables,
            unparsedSections: unparsed
        )
        project.updatedAt = Date()
        project.createdAt = project.updatedAt

        stats.sceneCount = scenes.count
        stats.sourceCount = sources.count
        stats.claimCount = verification.claims.count
        stats.checklistTaskCount = verification.tasks.count
        stats.comparisonTableCount = tables.count
        stats.unparsedSectionCount = unparsed.count
        stats.seoFields = seoFields(in: document.publishing)
        stats.scenes = scenes.map { scene in
            let documentScene = document.scenes[scene.order]
            return EscaletaSceneSummary(
                id: scene.order,
                order: scene.order,
                title: scene.title,
                startText: documentScene.timestampText,
                targetSeconds: scene.targetDuration.map { Int($0.rounded()) },
                estimatedSeconds: Int(scene.estimatedDuration.rounded()),
                bRollCount: scene.bRollItems.count,
                hasReHook: scene.escaletaHasReHook
            )
        }

        return EscaletaProjectMapping(
            project: project,
            warnings: warnings,
            stats: stats,
            document: document
        )
    }

    // MARK: - Scene

    private static func mapScene(
        _ scene: EscaletaScene,
        order: Int,
        nextStart: Int?,
        options: EscaletaMappingOptions,
        warnings: inout [EscaletaWarning],
        stats: inout EscaletaMappingStats
    ) -> Scene {
        let script = ScriptBuilder(scene: scene)
        stats.cueCount += scene.cues.count
        stats.recordingNoteCount += scene.cues.filter { $0.kind == .recordingNote }.count
        stats.reHookCount += scene.cues.filter { $0.kind == .rehook }.count

        var bRollItems: [BRollItem] = []
        var editingItems: [EditingItem] = []
        var noteLines: [String] = []

        for (blockIndex, block) in scene.blocks.enumerated() {
            guard case .cue(let cue) = block else { continue }

            switch cue.kind {
            case .recordingNote:
                let payload = cue.payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !payload.isEmpty {
                    noteLines.append("Nota de grabación: \(payload)")
                }
            case .unknown:
                let payload = cue.payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                noteLines.append(payload.isEmpty ? "Cue desconocido [\(cue.label)]" : "Cue desconocido [\(cue.label)]: \(payload)")
            case .rehook:
                let anchor = script.anchor(forCueAt: blockIndex)
                editingItems.append(
                    EditingItem(
                        textAnchor: anchor,
                        linkedSegmentID: nil,
                        templateType: "Escaleta",
                        cutStyle: "RE-HOOK",
                        transition: "",
                        subtitleStyle: "",
                        notes: L10n.tr("escaleta.rehook.note", language: .spanish)
                    )
                )
            default:
                guard cue.kind.isBRoll else { continue }
                let source = bRollSource(for: cue)
                stats.bRollBySource[source, default: 0] += 1
                let anchor = script.anchor(forCueAt: blockIndex)
                if anchor != nil {
                    stats.anchorsResolved += 1
                } else {
                    stats.anchorsUnresolved += 1
                    warnings.append(
                        EscaletaWarning(
                            kind: .unknownCue,
                            message: "No se pudo anclar el cue [\(cue.label)] a un párrafo de «\(scene.title)».",
                            line: cue.line
                        )
                    )
                }
                let cueLine = cue.reconstructedCueLine
                let position = script.cueIsAtEnd(blockIndex: blockIndex) ? "después" : "antes"
                var notes = "Cue original: \(cueLine)\nPosición: \(position)"
                if let suggestion = sourceSuggestionNote(for: cue, source: source) {
                    notes += "\n\(suggestion)"
                }
                bRollItems.append(
                    BRollItem(
                        textAnchor: anchor,
                        linkedSegmentID: nil,
                        templateType: "Escaleta",
                        sourceType: source.appSourceType,
                        descriptionText: cueDescription(cue),
                        notes: notes,
                        status: .planned
                    )
                )
            }
        }

        let estimated = DurationEstimator.estimate(text: script.text, wordsPerMinute: options.wordsPerMinute)
        let target: TimeInterval? = {
            guard let start = scene.startSeconds, let nextStart, nextStart > start else { return nil }
            return TimeInterval(nextStart - start)
        }()

        return Scene(
            order: order,
            sectionType: sectionType(for: scene, order: order),
            title: scene.title.isEmpty ? L10n.tr("escaleta.scene.untitled", language: .spanish) : scene.title,
            scriptText: script.text,
            notes: noteLines.joined(separator: "\n"),
            estimatedDuration: estimated,
            textSegments: [],
            bRollItems: bRollItems,
            editingItems: editingItems,
            targetDuration: target
        )
    }

    private static func nextSceneStart(after index: Int, in starts: [Int?]) -> Int? {
        guard index + 1 < starts.count else { return nil }
        for next in starts[(index + 1)...] {
            if let next { return next }
        }
        return nil
    }

    private static func cueDescription(_ cue: EscaletaCue) -> String {
        let payload = cue.payload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return payload.isEmpty ? cue.label : payload
    }

    static func bRollSource(for cue: EscaletaCue) -> EscaletaBRollSource {
        switch cue.kind {
        case .image:
            return containsAny(cue.payload, keywords: Self.screenshotKeywords) ? .screenshot : .unspecified
        case .bRoll, .capture, .test, .testOnScreen, .proposedTest, .comparison:
            return .obsGameplay
        case .record:
            return containsAny(cue.payload, keywords: Self.cameraKeywords) ? .camera : .obsGameplay
        case .lowerThird, .graphic:
            return .graphic
        case .screenTable:
            return .table
        case .recordingNote, .rehook, .unknown:
            return .unspecified
        }
    }

    private static func sourceSuggestionNote(for cue: EscaletaCue, source: EscaletaBRollSource) -> String? {
        guard cue.kind == .image else { return nil }
        if containsAny(cue.payload, keywords: Self.webKeywords) {
            return "Sugerencia de fuente: captura web (mantener como sin clasificar hasta confirmar)."
        }
        if containsAny(cue.payload, keywords: Self.obsKeywords) {
            return "Sugerencia de fuente: OBS gameplay (mantener como sin clasificar hasta confirmar)."
        }
        return nil
    }

    private static func containsAny(_ text: String?, keywords: [String]) -> Bool {
        guard let text else { return false }
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
        return keywords.contains { folded.contains($0) }
    }

    private static let cameraKeywords = [
        "camara", "camera", "volante", "wheel", "pedal", "cara", "face", "talking head", "plano a camara"
    ]
    private static let screenshotKeywords = [
        "foto", "photo", "galeria", "gallery", "modo foto", "photo mode", "captura de pantalla", "screenshot"
    ]
    private static let webKeywords = [
        "web", "comunicado", "statement", "roadmap", "foro", "forum", "steam", "pagina oficial", "official page"
    ]
    private static let obsKeywords = [
        "menu", "mfd", "hud", "telemetria", "telemetry", "setup", "replay", "gameplay", "coche", "pista", "onboard"
    ]

    private static func sectionType(for scene: EscaletaScene, order: Int) -> SectionType {
        let normalized = scene.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))
        if order == 0 || normalized.contains("hook") || normalized.contains("gancho") {
            return .hook
        }
        if normalized.contains("cta") || normalized.contains("llamada") || normalized.contains("comenta") || normalized.contains("suscrib") {
            return .cta
        }
        if normalized.contains("veredicto") || normalized.contains("conclusion") || normalized.contains("takeaway") || normalized.contains("final") {
            return .takeaway
        }
        if normalized.contains("problema") || normalized.contains("problem") || normalized.contains("falla") {
            return .problem
        }
        if normalized.contains("por que") || normalized.contains("why") {
            return .whyThisMatters
        }
        if normalized.contains("ejemplo") || normalized.contains("example") || normalized.contains("prueba") || normalized.contains("comparativa") {
            return .example
        }
        return .explanation
    }

    // MARK: - SEO

    private static func makePublishingPack(
        _ document: EscaletaPublishingPack?,
        scenes: [Scene],
        sceneIDsByStart: [Int: UUID],
        stats: inout EscaletaMappingStats
    ) -> PublishingPack {
        guard let document else { return PublishingPack() }

        let chapters = document.chapters.map { chapter in
            ChapterOverride(
                sceneID: sceneIDsByStart[chapter.seconds],
                title: chapter.title,
                startSeconds: TimeInterval(chapter.seconds)
            )
        }

        return PublishingPack(
            titleCandidates: document.titleCandidates,
            chosenTitle: document.primaryTitle ?? document.titleCandidates.first ?? "",
            description: document.description ?? "",
            tags: document.tags,
            hashtags: document.hashtags,
            pinnedComment: document.pinnedComment ?? "",
            communityPost: document.communityPost ?? "",
            chapterOverrides: chapters,
            thumbnailVariants: [],
            thumbnailConceptNotes: document.thumbnailBrief ?? ""
        )
    }

    private static func hasPublishingContent(_ pack: PublishingPack) -> Bool {
        !pack.titleCandidates.isEmpty
            || !pack.chosenTitle.isEmpty
            || !pack.description.isEmpty
            || !pack.tags.isEmpty
            || !pack.hashtags.isEmpty
            || !pack.pinnedComment.isEmpty
            || !pack.communityPost.isEmpty
            || !pack.chapterOverrides.isEmpty
            || !pack.thumbnailVariants.isEmpty
            || !pack.thumbnailConceptNotes.isEmpty
    }

    private static func seoFields(in pack: EscaletaPublishingPack?) -> [EscaletaPublishingField] {
        guard let pack else { return [] }
        var fields: [EscaletaPublishingField] = []
        if !pack.evidence.isEmpty { fields.append(.evidence) }
        if pack.primaryTitle != nil { fields.append(.primaryTitle) }
        if !pack.titleCandidates.isEmpty { fields.append(.titleCandidates) }
        if pack.thumbnailBrief != nil { fields.append(.thumbnailBrief) }
        if pack.description != nil { fields.append(.description) }
        if !pack.chapters.isEmpty { fields.append(.chapters) }
        if !pack.tags.isEmpty { fields.append(.tags) }
        if !pack.hashtags.isEmpty { fields.append(.hashtags) }
        if pack.pinnedComment != nil { fields.append(.pinnedComment) }
        if pack.communityPost != nil { fields.append(.communityPost) }
        return fields
    }

    // MARK: - Sources, verification, tables, unparsed

    private static func makeSources(_ entries: [EscaletaSourceEntry]) -> [ProjectSource] {
        entries.map { entry in
            let link = entry.links.first
            return ProjectSource(
                title: link?.title ?? entry.raw,
                url: link?.url ?? "",
                note: entry.raw
            )
        }
    }

    private static func makeVerification(
        _ items: [EscaletaVerificationItem]
    ) -> (claims: [ProjectClaim], tasks: [ChecklistTask]) {
        var claims: [ProjectClaim] = []
        var tasks: [ChecklistTask] = []
        for item in items {
            let text = verificationText(item)
            guard !text.isEmpty else { continue }
            claims.append(ProjectClaim(text: text, status: .probable))
            tasks.append(ChecklistTask(text: text, kind: .research))
        }
        return (claims, tasks)
    }

    private static func verificationText(_ item: EscaletaVerificationItem) -> String {
        let label = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return body }
        guard !body.isEmpty else { return "\(label):" }
        return "\(label): \(body)"
    }

    private static func makeTables(_ document: EscaletaDocument) -> [ComparisonTable] {
        document.comparisonTables.map { table in
            ComparisonTable(
                title: table.heading ?? document.tableSectionHeading ?? L10n.tr("escaleta.table.defaultTitle", language: .spanish),
                header: table.header,
                rows: table.rows
            )
        }
    }

    private static func makeUnparsedSections(_ document: EscaletaDocument) -> [UnparsedSection] {
        var sections = document.unparsedSections.map {
            UnparsedSection(heading: $0.heading, body: $0.body)
        }
        if let evidence = document.publishing?.evidence, !evidence.isEmpty {
            sections.append(
                UnparsedSection(
                    heading: L10n.tr("escaleta.evidence.heading", language: .spanish),
                    body: evidence.map { "- \($0)" }.joined(separator: "\n")
                )
            )
        }
        if let extraFields = document.publishing?.extraFields {
            for field in extraFields {
                sections.append(UnparsedSection(heading: field.label, body: field.value))
            }
        }
        if let tableNotes = document.tableSectionNotes, !tableNotes.isEmpty {
            sections.append(
                UnparsedSection(
                    heading: L10n.tr("escaleta.table.notesHeading", language: .spanish),
                    body: tableNotes
                )
            )
        }
        return sections
    }

    // MARK: - Video type

    static func guessVideoType(_ document: EscaletaDocument) -> String {
        let haystack = ([document.title] + document.outline.map(\.text) + document.scenes.map(\.title))
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_ES"))

        if haystack.contains("comparativa") || haystack.contains("comparison") || haystack.contains(" vs ") || haystack.contains("versus") {
            return "comparison"
        }
        if haystack.contains("review") || haystack.contains("analisis") || haystack.contains("analysis") {
            return "review"
        }
        if haystack.contains("actualizacion") || haystack.contains("update") || haystack.contains("patch") || haystack.contains("version") {
            return "update"
        }
        if haystack.contains("noticia") || haystack.contains("news") || haystack.contains("reaccion") || haystack.contains("reaction") {
            return "news"
        }
        if haystack.contains("cronica") || haystack.contains("race") || haystack.contains("carrera") || haystack.contains("challenge") {
            return "chronicle"
        }
        if haystack.contains("tutorial") || haystack.contains("como ") || haystack.contains("how to") {
            return "tutorial"
        }
        return ""
    }
}

// MARK: - Script construction

private struct ScriptBuilder {
    struct Paragraph {
        let blockIndex: Int
        let text: String
        let startUTF16: Int
        let lengthUTF16: Int
    }

    let text: String
    let paragraphs: [Paragraph]

    init(scene: EscaletaScene) {
        var parts: [(blockIndex: Int, text: String, anchorable: Bool)] = []
        for (index, block) in scene.blocks.enumerated() {
            switch block {
            case .paragraph(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append((index, trimmed, true)) }
            case .blockquote(let value):
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let quoted = trimmed.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
                    parts.append((index, quoted, true))
                }
            case .cue(let cue) where cue.kind == .rehook:
                parts.append((index, "[\(cue.label)]", false))
            case .cue, .table:
                continue
            }
        }

        var built = ""
        var mappedParagraphs: [Paragraph] = []
        for (offset, part) in parts.enumerated() {
            if offset > 0 { built += "\n\n" }
            let start = (built as NSString).length
            built += part.text
            if part.anchorable {
                mappedParagraphs.append(
                    Paragraph(
                        blockIndex: part.blockIndex,
                        text: part.text,
                        startUTF16: start,
                        lengthUTF16: (part.text as NSString).length
                    )
                )
            }
        }
        text = built
        paragraphs = mappedParagraphs
    }

    func anchor(forCueAt blockIndex: Int) -> TextAnchor? {
        guard let paragraph = targetParagraph(forCueAt: blockIndex) else { return nil }
        let full = text as NSString
        let start = paragraph.startUTF16
        let length = paragraph.lengthUTF16
        let prefixStart = max(0, start - 48)
        return TextAnchor(
            startUTF16: start,
            lengthUTF16: length,
            selectedText: full.substring(with: NSRange(location: start, length: length)),
            prefixContext: full.substring(with: NSRange(location: prefixStart, length: start - prefixStart)),
            suffixContext: full.substring(with: NSRange(location: min(full.length, start + length), length: min(48, max(0, full.length - (start + length)))))
        )
    }

    func cueIsAtEnd(blockIndex: Int) -> Bool {
        guard let paragraph = targetParagraph(forCueAt: blockIndex) else { return true }
        return paragraph.blockIndex < blockIndex && !paragraphs.contains { $0.blockIndex > blockIndex }
    }

    private func targetParagraph(forCueAt blockIndex: Int) -> Paragraph? {
        paragraphs.first { $0.blockIndex > blockIndex } ?? paragraphs.last { $0.blockIndex < blockIndex } ?? paragraphs.last
    }
}

// MARK: - Cue helpers

extension EscaletaCue {
    /// The exact full-line cue, used in notes so export can restore it without
    /// guessing from the mapped `BRollSourceType`.
    var reconstructedCueLine: String {
        if let payload, !payload.isEmpty {
            return "[\(label): \(payload)]"
        }
        return "[\(label)]"
    }
}

extension Scene {
    /// Re-hook markers are kept as a literal `[RE-HOOK]` line in the script.
    /// The app model has no boolean field, so this is the runtime flag.
    var escaletaHasReHook: Bool {
        scriptText
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "[RE-HOOK]" }
    }
}
