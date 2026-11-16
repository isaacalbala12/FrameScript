import Foundation

/// Turns pending claims into production checklist tasks without duplicating
/// hand-written research tasks.
public enum ResearchChecklist {
    /// Pending claims that should reach the checklist. Personal experience is
    /// excluded: there is nothing to verify, only something to tell.
    public static func pendingTexts(
        claims: [FrameScriptDocument.Claim]
    ) -> [String] {
        claims
            .filter(ResearchSummary.isPending)
            .map { normalized($0.text) }
            .filter { !$0.isEmpty }
    }

    /// Adds a `.research` task for every pending claim that does not already
    /// have one. Existing tasks keep their identity, order and done state.
    public static func mergingPendingClaims(
        _ claims: [FrameScriptDocument.Claim],
        into tasks: [FrameScriptDocument.ChecklistTask]
    ) -> [FrameScriptDocument.ChecklistTask] {
        var result = tasks
        var existing = Set(
            tasks
                .filter { $0.kind == .research }
                .map { normalized($0.text) }
        )

        for claim in claims where ResearchSummary.isPending(claim) {
            let text = normalized(claim.text)
            guard !text.isEmpty, existing.insert(text).inserted else { continue }
            result.append(
                FrameScriptDocument.ChecklistTask(
                    text: claim.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: .research,
                    isDone: false,
                    sceneID: claim.sceneIDs.first
                )
            )
        }
        return result
    }

    /// Marks the matching research task done when a claim gets confirmed.
    /// Unrelated research tasks are untouched.
    public static func markingResolved(
        claimText: String,
        in tasks: [FrameScriptDocument.ChecklistTask]
    ) -> [FrameScriptDocument.ChecklistTask] {
        let target = normalized(claimText)
        guard !target.isEmpty else { return tasks }
        return tasks.map { task in
            guard task.kind == .research, normalized(task.text) == target, !task.isDone else {
                return task
            }
            var copy = task
            copy.isDone = true
            return copy
        }
    }

    /// Removes the open research task that mirrors a deleted claim. A done task
    /// or a manually written task with the same text only by coincidence keeps
    /// its identity because the deletion promise is about open verification
    /// work (I-2).
    public static func removing(
        claimText: String,
        in tasks: [FrameScriptDocument.ChecklistTask]
    ) -> [FrameScriptDocument.ChecklistTask] {
        let target = normalized(claimText)
        guard !target.isEmpty else { return tasks }
        return tasks.filter { task in
            !(task.kind == .research && !task.isDone && normalized(task.text) == target)
        }
    }

    /// Keeps a claim's checklist task in sync when the claim text is edited.
    public static func renaming(
        claimText: String,
        to newText: String,
        sceneID: UUID?,
        in tasks: [FrameScriptDocument.ChecklistTask]
    ) -> [FrameScriptDocument.ChecklistTask] {
        let target = normalized(claimText)
        let replacement = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !replacement.isEmpty else { return tasks }
        return tasks.map { task in
            guard task.kind == .research, normalized(task.text) == target else { return task }
            var copy = task
            copy.text = replacement
            if let sceneID {
                copy.sceneID = sceneID
            }
            return copy
        }
    }

    public static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
