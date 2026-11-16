import Foundation

/// Counters for the research panel. `pending` is derived from
/// `ResearchSummary.isPending`: first-hand experience never counts, and
/// otherwise the `needsVerification` flag decides.
public struct ResearchCounts: Sendable, Equatable {
    public var confirmed = 0
    public var probable = 0
    public var rumor = 0
    public var communityOpinion = 0
    public var pending = 0

    public init(
        confirmed: Int = 0,
        probable: Int = 0,
        rumor: Int = 0,
        communityOpinion: Int = 0,
        pending: Int = 0
    ) {
        self.confirmed = max(0, confirmed)
        self.probable = max(0, probable)
        self.rumor = max(0, rumor)
        self.communityOpinion = max(0, communityOpinion)
        self.pending = max(0, pending)
    }

    public var total: Int {
        confirmed + probable + rumor + communityOpinion
    }

    public func count(for status: FrameScriptDocument.ClaimStatus) -> Int {
        switch status {
        case .confirmed: confirmed
        case .probable: probable
        case .rumor: rumor
        case .communityOpinion: communityOpinion
        }
    }

    /// Status counters in display order. Zero values stay in the list so the
    /// panel can decide whether to hide them; the counts themselves never lie.
    public var statusParts: [(status: FrameScriptDocument.ClaimStatus, count: Int)] {
        [
            (.confirmed, confirmed),
            (.probable, probable),
            (.rumor, rumor),
            (.communityOpinion, communityOpinion)
        ]
    }
}

/// One pending claim joined with the scenes and sources that make it usable.
public struct ResearchPendingItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let claimID: UUID
    public let text: String
    public let status: FrameScriptDocument.ClaimStatus
    public let sceneTitles: [String]
    public let sourceTitles: [String]
    public let hasAnchor: Bool
    public let personalExperience: Bool

    public init(
        id: UUID,
        claimID: UUID,
        text: String,
        status: FrameScriptDocument.ClaimStatus,
        sceneTitles: [String],
        sourceTitles: [String],
        hasAnchor: Bool,
        personalExperience: Bool
    ) {
        self.id = id
        self.claimID = claimID
        self.text = text
        self.status = status
        self.sceneTitles = sceneTitles
        self.sourceTitles = sourceTitles
        self.hasAnchor = hasAnchor
        self.personalExperience = personalExperience
    }
}

/// Filter shared by the claims list and the badge-driven navigation.
public struct ResearchFilter: Sendable, Equatable {
    public var statuses: Set<FrameScriptDocument.ClaimStatus>
    public var sceneID: UUID?
    public var onlyPending: Bool
    public var searchText: String

    public init(
        statuses: Set<FrameScriptDocument.ClaimStatus> = Set(FrameScriptDocument.ClaimStatus.allCases),
        sceneID: UUID? = nil,
        onlyPending: Bool = false,
        searchText: String = ""
    ) {
        self.statuses = statuses
        self.sceneID = sceneID
        self.onlyPending = onlyPending
        self.searchText = searchText
    }

    public func matches(_ claim: FrameScriptDocument.Claim) -> Bool {
        guard statuses.contains(claim.status) else { return false }
        if onlyPending, !ResearchSummary.isPending(claim) { return false }
        if let sceneID, !claim.sceneIDs.contains(sceneID) { return false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = ([claim.text, claim.resolutionNote] + claim.sceneIDs.map(\.uuidString))
            .joined(separator: " ")
        return haystack.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    public func apply(to claims: [FrameScriptDocument.Claim]) -> [FrameScriptDocument.Claim] {
        claims.filter(matches)
    }
}

public enum ResearchSummary {
    /// One rule shared by Production, the research panel, the scene badges and
    /// the board: first-hand experience never needs a fact check, and the
    /// `needsVerification` flag decides for everyone else. New non-confirmed
    /// claims start flagged; confirming clears the flag automatically; a
    /// confirmed claim can be flagged again for a second check. Unticking it
    /// means "accepted as is", so the claim leaves every pending list (E-3,
    /// NEW-5, product decision).
    public static func isPending(_ claim: FrameScriptDocument.Claim) -> Bool {
        !claim.personalExperience && claim.needsVerification
    }

    public static func counts(claims: [FrameScriptDocument.Claim]) -> ResearchCounts {
        var counts = ResearchCounts()
        for claim in claims {
            switch claim.status {
            case .confirmed: counts.confirmed += 1
            case .probable: counts.probable += 1
            case .rumor: counts.rumor += 1
            case .communityOpinion: counts.communityOpinion += 1
            }
            if isPending(claim) {
                counts.pending += 1
            }
        }
        return counts
    }

    public static func pendingClaims(
        _ claims: [FrameScriptDocument.Claim]
    ) -> [FrameScriptDocument.Claim] {
        claims.filter(isPending)
    }

    /// Claims that still need research and are linked to this scene. The badge
    /// counts these; a confirmed, unflagged claim never turns a scene amber.
    public static func unconfirmedCount(
        sceneID: UUID,
        claims: [FrameScriptDocument.Claim]
    ) -> Int {
        claims.filter { isPending($0) && $0.sceneIDs.contains(sceneID) }.count
    }

    public static func scenesWithUnconfirmedClaims(
        project: FrameScriptDocument.Project
    ) -> [UUID] {
        let ids = project.claims
            .filter(isPending)
            .flatMap(\.sceneIDs)
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// Scene IDs with at least one claim still pending research.
    public static func unconfirmedCountsByScene(
        claims: [FrameScriptDocument.Claim]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for claim in claims where isPending(claim) {
            for sceneID in Set(claim.sceneIDs) {
                result[sceneID, default: 0] += 1
            }
        }
        return result
    }

    /// Complete "verify before recording" list, resolved against project data.
    /// Claims keep their stored order so the panel does not reshuffle while the
    /// creator is working through the list.
    public static func pendingItems(
        project: FrameScriptDocument.Project
    ) -> [ResearchPendingItem] {
        pendingItems(
            claims: project.claims,
            sourceTitlesByID: Dictionary(
                project.sources.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            ),
            sceneTitlesByID: Dictionary(
                project.scenes.map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Cheap variant used by the app on every render: the caller supplies only
    /// the titles needed to resolve ids, so no scene payload is copied.
    public static func pendingItems(
        claims: [FrameScriptDocument.Claim],
        sourceTitlesByID: [UUID: String],
        sceneTitlesByID: [UUID: String]
    ) -> [ResearchPendingItem] {
        pendingClaims(claims).map { claim in
            ResearchPendingItem(
                id: claim.id,
                claimID: claim.id,
                text: claim.text,
                status: claim.status,
                sceneTitles: claim.sceneIDs.compactMap { sceneTitlesByID[$0] },
                sourceTitles: claim.sourceIDs.compactMap { sourceTitlesByID[$0] },
                hasAnchor: claim.anchor != nil,
                personalExperience: claim.personalExperience
            )
        }
    }

    /// How many claims cite each source. Used by the sources list to show why a
    /// source matters and to warn before deleting it.
    public static func sourceUsage(
        claims: [FrameScriptDocument.Claim]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for claim in claims {
            for sourceID in Set(claim.sourceIDs) {
                result[sourceID, default: 0] += 1
            }
        }
        return result
    }

    /// Research checklist tasks that are not done. Imported escaletas write
    /// these alongside claims, so the panel shows both without duplicating them.
    public static func openResearchTasks(
        project: FrameScriptDocument.Project
    ) -> [FrameScriptDocument.ChecklistTask] {
        project.checklistTasks.filter { $0.kind == .research && !$0.isDone }
    }
}
