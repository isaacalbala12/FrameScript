import Foundation

/// Builds the stable identifiers used to keep exported work items unique.
public enum PlaneExternalID {
    /// Value sent as Plane's `external_source`.
    public static let source = "framescript"

    /// `framescript:<FrameScript project id>:<FrameScript task id>`.
    ///
    /// The identifier does not depend on the task title, scene or due date, so
    /// editing those fields and exporting again still maps to the same Plane
    /// work item.
    ///
    /// Components are escaped because a literal `:` inside a project or task
    /// id would otherwise make the identifier ambiguous: `framescript:a:b:c`
    /// could mean project `a`, task `b:c` or project `a:b`, task `c`.
    /// `%` is escaped first, then `:` (as `%25` and `%3A`).
    public static func make(projectID: String, taskID: String) -> String {
        "\(source):\(escapeComponent(projectID)):\(escapeComponent(taskID))"
    }

    private static func escapeComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ":", with: "%3A")
    }
}

/// User-visible strings used in generated work-item descriptions.
///
/// The caller supplies these so the core package does not hardcode a
/// language. Defaults are English; the app can pass localized values from its
/// own string tables. `scene` and `project` are labels only: the exporter adds
/// the `": "` separator. Missing kind names fall back to the English defaults.
public struct PlaneExportLabels: Sendable, Equatable {
    /// Label placed before the scene title, for example `Scene`.
    public var scene: String
    /// Label placed before the project title, for example `Project`.
    public var project: String
    /// Display names for task kinds.
    public var kindNames: [PlaneTaskKind: String]

    public init(
        scene: String = "Scene",
        project: String = "Project",
        kindNames: [PlaneTaskKind: String] = PlaneExportLabels.defaultKindNames
    ) {
        self.scene = scene
        self.project = project
        self.kindNames = kindNames
    }

    public func name(for kind: PlaneTaskKind) -> String {
        kindNames[kind] ?? Self.defaultKindNames[kind] ?? kind.rawValue
    }

    public static let defaultKindNames: [PlaneTaskKind: String] = [
        .grabar: "Record",
        .conseguirBroll: "Get B-roll",
        .editar: "Edit",
        .investigar: "Research",
        .manual: "Manual"
    ]
}

/// A pure, network-free description of what a Plane export would create.
///
/// The app builds this plan, shows it as a dry run, and only then asks
/// `PlaneClient` to create the work items.
public struct PlaneExportPlan: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let task: PlanePendingTask
        public let draft: PlaneWorkItemDraft
        /// True when the task title was longer than Plane's 255-character
        /// limit and `draft.name` is the truncated form.
        public let wasNameTruncated: Bool

        public var id: String { draft.externalID }

        public init(
            task: PlanePendingTask,
            draft: PlaneWorkItemDraft,
            wasNameTruncated: Bool = false
        ) {
            self.task = task
            self.draft = draft
            self.wasNameTruncated = wasNameTruncated
        }
    }

    public struct SkippedTask: Sendable, Equatable {
        public enum Reason: Sendable, Hashable {
            /// Plane requires a non-empty name.
            case emptyTitle
            /// The task had no stable project/task identifier.
            case missingIdentifier
            /// Plane limits `external_id` to 255 characters.
            case externalIdentifierTooLong
            /// Another task in the same plan produced the same external id.
            case duplicateTask
        }

        public let task: PlanePendingTask
        public let reason: Reason

        public init(task: PlanePendingTask, reason: Reason) {
            self.task = task
            self.reason = reason
        }
    }

    public struct Summary: Sendable, Equatable {
        public let taskCount: Int
        public let workItemCount: Int
        public let skippedCount: Int
        public let skippedByReason: [SkippedTask.Reason: Int]
        public let workItemsByKind: [PlaneTaskKind: Int]
        public let truncatedNameCount: Int
        public let dueDateCount: Int
        public let earliestTargetDate: PlaneDate?
        public let latestTargetDate: PlaneDate?

        public var hasWorkItems: Bool { workItemCount > 0 }

        public init(
            taskCount: Int,
            workItemCount: Int,
            skippedCount: Int,
            skippedByReason: [SkippedTask.Reason: Int],
            workItemsByKind: [PlaneTaskKind: Int],
            truncatedNameCount: Int,
            dueDateCount: Int,
            earliestTargetDate: PlaneDate?,
            latestTargetDate: PlaneDate?
        ) {
            self.taskCount = taskCount
            self.workItemCount = workItemCount
            self.skippedCount = skippedCount
            self.skippedByReason = skippedByReason
            self.workItemsByKind = workItemsByKind
            self.truncatedNameCount = truncatedNameCount
            self.dueDateCount = dueDateCount
            self.earliestTargetDate = earliestTargetDate
            self.latestTargetDate = latestTargetDate
        }
    }

    public let entries: [Entry]
    public let skipped: [SkippedTask]

    public init(tasks: [PlanePendingTask], labels: PlaneExportLabels = PlaneExportLabels()) {
        var entries: [Entry] = []
        var skipped: [SkippedTask] = []
        var seenExternalIDs: Set<String> = []

        for task in tasks {
            let trimmedTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                skipped.append(SkippedTask(task: task, reason: .emptyTitle))
                continue
            }

            let projectID = task.projectID.trimmingCharacters(in: .whitespacesAndNewlines)
            let taskID = task.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !projectID.isEmpty, !taskID.isEmpty else {
                skipped.append(SkippedTask(task: task, reason: .missingIdentifier))
                continue
            }

            let externalID = PlaneExternalID.make(projectID: projectID, taskID: taskID)
            guard externalID.count <= 255 else {
                skipped.append(SkippedTask(task: task, reason: .externalIdentifierTooLong))
                continue
            }

            guard seenExternalIDs.insert(externalID).inserted else {
                skipped.append(SkippedTask(task: task, reason: .duplicateTask))
                continue
            }

            let name = PlaneWorkItemName.truncated(trimmedTitle)
            let draft = PlaneWorkItemDraft(
                name: name,
                descriptionHTML: Self.descriptionHTML(for: task, labels: labels),
                priority: .none,
                targetDate: task.dueDate,
                externalID: externalID,
                externalSource: PlaneExternalID.source
            )
            entries.append(
                Entry(
                    task: task,
                    draft: draft,
                    wasNameTruncated: name != trimmedTitle
                )
            )
        }

        self.entries = entries
        self.skipped = skipped
    }

    public var drafts: [PlaneWorkItemDraft] {
        entries.map(\.draft)
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public var summary: Summary {
        var byKind: [PlaneTaskKind: Int] = [:]
        var skippedByReason: [SkippedTask.Reason: Int] = [:]
        var dueDateCount = 0
        var truncatedNameCount = 0
        var earliest: PlaneDate?
        var latest: PlaneDate?

        for entry in entries {
            byKind[entry.task.kind, default: 0] += 1
            if entry.wasNameTruncated {
                truncatedNameCount += 1
            }
            guard let dueDate = entry.task.dueDate else { continue }
            dueDateCount += 1
            if let currentEarliest = earliest {
                if dueDate < currentEarliest { earliest = dueDate }
            } else {
                earliest = dueDate
            }
            if let currentLatest = latest {
                if currentLatest < dueDate { latest = dueDate }
            } else {
                latest = dueDate
            }
        }

        for skip in skipped {
            skippedByReason[skip.reason, default: 0] += 1
        }

        return Summary(
            taskCount: entries.count + skipped.count,
            workItemCount: entries.count,
            skippedCount: skipped.count,
            skippedByReason: skippedByReason,
            workItemsByKind: byKind,
            truncatedNameCount: truncatedNameCount,
            dueDateCount: dueDateCount,
            earliestTargetDate: earliest,
            latestTargetDate: latest
        )
    }

    /// Escapes the five characters that would otherwise be interpreted as
    /// HTML by Plane's rich-text renderer.
    public static func escapeHTML(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func descriptionHTML(
        for task: PlanePendingTask,
        labels: PlaneExportLabels
    ) -> String {
        let kind = escapeHTML(labels.name(for: task.kind))
        var parts = ["<p><strong>\(kind)</strong></p>"]

        var context: [String] = []
        let scene = task.sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !scene.isEmpty {
            context.append("\(escapeHTML(labels.scene)): \(escapeHTML(scene))")
        }
        let project = task.projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty {
            context.append("\(escapeHTML(labels.project)): \(escapeHTML(project))")
        }
        if !context.isEmpty {
            parts.append("<p>\(context.joined(separator: "<br>"))</p>")
        }

        return parts.joined()
    }
}
