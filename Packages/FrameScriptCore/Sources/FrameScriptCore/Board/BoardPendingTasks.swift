import Foundation

/// Labels used to build pending task titles. The core package never hardcodes
/// a user language, so the app passes its localized names.
public struct BoardPendingLabels: Sendable, Equatable {
    public var record: String
    public var bRoll: String
    public var edit: String
    public var research: String
    public var manual: String
    /// Separator between the kind label and the scene title, for example `"Grabar · Intro"`.
    public var separator: String

    public init(
        record: String,
        bRoll: String,
        edit: String,
        research: String,
        manual: String,
        separator: String = " · "
    ) {
        self.record = record
        self.bRoll = bRoll
        self.edit = edit
        self.research = research
        self.manual = manual
        self.separator = separator
    }

    public func label(for kind: PlaneTaskKind) -> String {
        switch kind {
        case .grabar: record
        case .conseguirBroll: bRoll
        case .editar: edit
        case .investigar: research
        case .manual: manual
        }
    }

    public static let english = BoardPendingLabels(
        record: "Record",
        bRoll: "Get B-roll",
        edit: "Edit",
        research: "Research",
        manual: "Manual task"
    )
}

/// Derives the board's pending production tasks from a project document.
///
/// This is a deliberately small local derivation (the app has no shared
/// production planner yet) behind a protocol so a richer planner can replace
/// it without touching the board:
///
/// - Scenes that still need a recording before the project is marked recorded.
/// - B-roll items that are not `done`.
/// - Editing notes that are not `done`.
/// - Checklist tasks that are not done, mapped to the closest Plane kind.
///
/// Published projects report no pending work: leftover checkboxes on a
/// published video are bookkeeping, not board work.
public protocol BoardPendingTaskProviding: Sendable {
    func pendingTasks(
        for project: FrameScriptDocument.Project,
        labels: BoardPendingLabels
    ) -> [BoardPendingTask]
}

public struct BoardPendingTaskDeriver: BoardPendingTaskProviding {
    public init() {}

    public func pendingTasks(
        for project: FrameScriptDocument.Project,
        labels: BoardPendingLabels = .english
    ) -> [BoardPendingTask] {
        guard project.productionStatus != .published else { return [] }

        let primaryLanguage = BoardLanguage.normalized(project.primaryLanguage)
        let scenes = project.scenes.sorted { $0.order < $1.order }
        var tasks: [BoardPendingTask] = []
        var seen: Set<String> = []

        let recordsRecording = project.productionStatus == .idea
            || project.productionStatus == .outline
            || project.productionStatus == .script

        for scene in scenes {
            let sceneTitle = BoardText.fallbackSceneTitle(scene.title, order: scene.order)

            if recordsRecording,
               !BoardTakeSelection.hasUsableTake(
                   in: scene,
                   primaryLanguage: primaryLanguage
               ),
               !scene.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let id = "\(scene.id.uuidString):record"
                if seen.insert(id).inserted {
                    tasks.append(
                        BoardPendingTask(
                            id: id,
                            kind: .grabar,
                            title: "\(labels.record)\(labels.separator)\(sceneTitle)",
                            sceneTitle: sceneTitle
                        )
                    )
                }
            }

            for item in scene.bRollItems where item.status != .done {
                let id = "\(scene.id.uuidString):broll:\(item.id.uuidString)"
                guard seen.insert(id).inserted else { continue }
                let detail = BoardText.firstNonEmpty(item.descriptionText, item.templateType, item.notes)
                tasks.append(
                    BoardPendingTask(
                        id: id,
                        kind: .conseguirBroll,
                        title: BoardText.taskTitle(
                            label: labels.bRoll,
                            scene: sceneTitle,
                            detail: detail,
                            separator: labels.separator
                        ),
                        sceneTitle: sceneTitle
                    )
                )
            }

            for item in scene.editingItems where item.status != .done {
                let id = "\(scene.id.uuidString):edit:\(item.id.uuidString)"
                guard seen.insert(id).inserted else { continue }
                let detail = BoardText.firstNonEmpty(item.cutStyle, item.transition, item.notes)
                tasks.append(
                    BoardPendingTask(
                        id: id,
                        kind: .editar,
                        title: BoardText.taskTitle(
                            label: labels.edit,
                            scene: sceneTitle,
                            detail: detail,
                            separator: labels.separator
                        ),
                        sceneTitle: sceneTitle
                    )
                )
            }
        }

        for task in project.checklistTasks where !task.isDone {
            let id = "\(task.id.uuidString):checklist"
            guard seen.insert(id).inserted else { continue }
            let sceneTitle = scenes.first(where: { $0.id == task.sceneID })
                .map { BoardText.fallbackSceneTitle($0.title, order: $0.order) } ?? ""
            let kind = BoardPendingTaskDeriver.planeKind(for: task.kind)
            let text = task.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text.isEmpty
                ? "\(labels.label(for: kind))\(labels.separator)\(sceneTitle)"
                : text
            tasks.append(
                BoardPendingTask(
                    id: id,
                    kind: kind,
                    title: title,
                    sceneTitle: sceneTitle
                )
            )
        }

        return tasks
    }

    static func planeKind(for kind: FrameScriptDocument.ChecklistTaskKind) -> PlaneTaskKind {
        switch kind {
        case .record: .grabar
        case .acquire: .conseguirBroll
        case .edit: .editar
        case .research: .investigar
        case .other: .manual
        }
    }
}

/// Real-take selection for the board. Mirrors the duration UI: a good take
/// wins over older good takes, stale takes (recorded against different text)
/// are ignored, and a bad take is only used when nothing else exists.
enum BoardTakeSelection {
    struct Candidate {
        let rating: FrameScriptDocument.TakeRating
        let startedAt: Date
        let number: Int
        let duration: TimeInterval
    }

    static func selectedTake(
        for scene: FrameScriptDocument.Scene,
        primaryLanguage: String
    ) -> Candidate? {
        var candidates: [Candidate] = []
        let language = BoardLanguage.normalized(primaryLanguage)
        let sceneHash = FrameScriptDocument.TextHash.hash(scene.scriptText)

        for take in scene.takes {
            let takeLanguage = BoardLanguage.normalized(take.languageCode)
            guard takeLanguage.isEmpty || takeLanguage == language else { continue }
            guard isValid(take, sceneTextHash: sceneHash) else { continue }
            candidates.append(Candidate(
                rating: take.rating,
                startedAt: take.startedAt,
                number: take.number,
                duration: take.duration
            ))
        }

        for variant in scene.languageVariants {
            guard BoardLanguage.normalized(variant.languageCode) == language else { continue }
            let variantHash = FrameScriptDocument.TextHash.hash(variant.text)
            for take in variant.takes {
                let takeLanguage = BoardLanguage.normalized(take.languageCode)
                guard takeLanguage.isEmpty || takeLanguage == language else { continue }
                guard isValid(take, sceneTextHash: variantHash) else { continue }
                candidates.append(Candidate(
                    rating: take.rating,
                    startedAt: take.startedAt,
                    number: take.number,
                    duration: take.duration
                ))
            }
        }

        guard !candidates.isEmpty else { return nil }
        let good = candidates.filter { $0.rating == .good }
        let usable = good.isEmpty
            ? candidates.filter { $0.rating != .bad }
            : good
        return usable.max { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.number < rhs.number
        }
    }

    static func hasUsableTake(
        in scene: FrameScriptDocument.Scene,
        primaryLanguage: String
    ) -> Bool {
        selectedTake(for: scene, primaryLanguage: primaryLanguage) != nil
    }

    private static func isValid(
        _ take: FrameScriptDocument.Take,
        sceneTextHash: String
    ) -> Bool {
        guard take.duration.isFinite, (0.1...86_400).contains(take.duration) else { return false }
        return take.sceneTextHash.isEmpty || take.sceneTextHash == sceneTextHash
    }
}

enum BoardLanguage {
    static func normalized(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? trimmed.prefix(2))
    }

    static let defaultWordsPerMinute: [String: Double] = [
        "es": 150,
        "en": 160,
        "ru": 140
    ]

    static func wordsPerMinute(
        language: String,
        learned: [String: Double]
    ) -> Double {
        let code = normalized(language)
        if let value = learned[code] ?? learned[language], value.isFinite, (30...400).contains(value) {
            return value
        }
        if let value = learned[code.isEmpty ? "es" : code] ?? defaultWordsPerMinute[code] {
            return value
        }
        return 150
    }
}

/// Wall-clock duration of a scene: the selected real take when there is one,
/// otherwise the stored estimate (or a markup-aware estimate for old files).
enum BoardSceneDuration {
    static func seconds(
        for scene: FrameScriptDocument.Scene,
        primaryLanguage: String,
        learnedWordsPerMinute: [String: Double]
    ) -> TimeInterval {
        if let take = BoardTakeSelection.selectedTake(for: scene, primaryLanguage: primaryLanguage) {
            return take.duration
        }
        let stored = scene.estimatedDuration
        if stored.isFinite, stored > 0, stored <= 86_400 {
            return stored
        }
        let text = scene.scriptText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        return ScriptMarkup.estimateDuration(
            text,
            wordsPerMinute: BoardLanguage.wordsPerMinute(
                language: primaryLanguage,
                learned: learnedWordsPerMinute
            )
        )
    }

    static func estimatedSeconds(
        for scene: FrameScriptDocument.Scene,
        primaryLanguage: String,
        learnedWordsPerMinute: [String: Double]
    ) -> TimeInterval {
        let stored = scene.estimatedDuration
        if stored.isFinite, stored > 0, stored <= 86_400 {
            return stored
        }
        return seconds(
            for: scene,
            primaryLanguage: primaryLanguage,
            learnedWordsPerMinute: learnedWordsPerMinute
        )
    }
}

enum BoardText {
    static func fallbackSceneTitle(_ title: String, order: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "#\(order + 1)" : trimmed
    }

    static func firstNonEmpty(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    static func taskTitle(label: String, scene: String, detail: String, separator: String) -> String {
        guard !detail.isEmpty else { return "\(label)\(separator)\(scene)" }
        let shortDetail = detail.count > 80 ? String(detail.prefix(80)) : detail
        return "\(label)\(separator)\(scene): \(shortDetail)"
    }
}

/// Builds a board summary from a decoded document and its file fingerprint.
public enum BoardProjectSummaryBuilder {
    public static func makeSummary(
        document: FrameScriptDocument,
        fileURL: URL,
        fingerprint: BoardFileFingerprint,
        labels: BoardPendingLabels = .english,
        pendingProvider: any BoardPendingTaskProviding = BoardPendingTaskDeriver()
    ) -> BoardProjectSummary {
        makeSummary(
            project: document.project,
            fileURL: fileURL,
            fingerprint: fingerprint,
            labels: labels,
            pendingProvider: pendingProvider
        )
    }

    public static func makeSummary(
        project: FrameScriptDocument.Project,
        fileURL: URL,
        fingerprint: BoardFileFingerprint,
        labels: BoardPendingLabels = .english,
        pendingProvider: any BoardPendingTaskProviding = BoardPendingTaskDeriver()
    ) -> BoardProjectSummary {
        let language = BoardLanguage.normalized(project.primaryLanguage)
        let learned = project.learnedWordsPerMinuteByLanguage
        let scenes = project.scenes.sorted { $0.order < $1.order }

        var estimated: TimeInterval = 0
        var display: TimeInterval = 0
        var realScenes = 0
        for scene in scenes {
            estimated += BoardSceneDuration.estimatedSeconds(
                for: scene,
                primaryLanguage: language,
                learnedWordsPerMinute: learned
            )
            display += BoardSceneDuration.seconds(
                for: scene,
                primaryLanguage: language,
                learnedWordsPerMinute: learned
            )
            if BoardTakeSelection.selectedTake(for: scene, primaryLanguage: language) != nil {
                realScenes += 1
            }
        }

        let pending = pendingProvider.pendingTasks(for: project, labels: labels)

        return BoardProjectSummary(
            fileURL: fileURL,
            projectID: project.id,
            title: project.title.trimmingCharacters(in: .whitespacesAndNewlines),
            topic: project.topic.trimmingCharacters(in: .whitespacesAndNewlines),
            videoType: project.videoType.trimmingCharacters(in: .whitespacesAndNewlines),
            productionStatus: project.productionStatus,
            targetDate: project.targetDate,
            publishDate: project.publishDate,
            updatedAt: project.updatedAt,
            createdAt: project.createdAt,
            templateID: project.templateID,
            sceneCount: scenes.count,
            duration: BoardDuration(
                seconds: display,
                estimatedSeconds: estimated,
                realSceneCount: realScenes,
                sceneCount: scenes.count
            ),
            pendingTasks: pending,
            fingerprint: fingerprint
        )
    }
}
