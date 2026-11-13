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
            .filter { $0.needsVerification && !$0.personalExperience }
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

        for claim in claims where claim.needsVerification && !claim.personalExperience {
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

    public static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
