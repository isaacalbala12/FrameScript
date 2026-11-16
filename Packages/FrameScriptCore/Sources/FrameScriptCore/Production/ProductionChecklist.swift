import Foundation

/// Production work categories shown in the F16 checklist.
///
/// The first five mirror the automatic rules; `other` exists so manual
/// `ChecklistTask` entries keep their own bucket instead of disappearing.
public enum ProductionItemKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case record
    case acquire
    case edit
    case research
    case publish
    case other

    public var id: String { rawValue }
}

/// Why a checklist item exists. The app localizes these reasons; the core
/// never stores user-facing text so the same snapshot can feed the MCP.
public enum ProductionItemReason: Sendable, Hashable {
    case sceneNeedsTake
    case bRollNeedsFootage
    case bRollNeedsAsset
    case editingNeedsWork
    case claimNeedsVerification
    case publishingChecklist(PublishingChecklistItem)
    case manualTask

    /// Stable localization key (`production.reason.<rawValue>`).
    public var rawValue: String {
        switch self {
        case .sceneNeedsTake: "sceneNeedsTake"
        case .bRollNeedsFootage: "bRollNeedsFootage"
        case .bRollNeedsAsset: "bRollNeedsAsset"
        case .editingNeedsWork: "editingNeedsWork"
        case .claimNeedsVerification: "claimNeedsVerification"
        case .publishingChecklist: "publishingChecklist"
        case .manualTask: "manualTask"
        }
    }

    /// The publishing check this row represents, if any. The app uses its
    /// localized `titleKey` for the row title.
    public var publishingChecklistItem: PublishingChecklistItem? {
        if case .publishingChecklist(let item) = self { return item }
        return nil
    }
}

/// Where clicking an item should take the user. Local destinations are handled
/// by `AppState`; publishing and research are forwarded to the integration
/// seam because those panels live on other branches.
public enum ProductionTarget: Sendable, Hashable {
    case scene(sceneID: UUID)
    case bRoll(sceneID: UUID, itemID: UUID)
    case editing(sceneID: UUID, itemID: UUID)
    case takes(sceneID: UUID, languageCode: String)
    case publishing(languageCode: String)
    case research(claimID: UUID)
    case manualTask(taskID: UUID)
}

/// One derived or manual row in the production checklist.
///
/// Derived rows are always pending: they are recomputed from the document and
/// never persisted as a second copy. Only manual `ChecklistTask` rows carry a
/// stored done flag.
public struct ProductionItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let kind: ProductionItemKind
    public let reason: ProductionItemReason
    public let isDone: Bool
    public let sceneID: UUID?
    public let sceneOrder: Int?
    public let sceneTitle: String
    /// Non-nil only for translated scene variants and publishing packs.
    public let languageCode: String?
    /// Raw content for the row title (scene name, B-roll description, claim
    /// text, task text). Empty means the app should use a localized fallback.
    public let sourceText: String
    /// Position inside its scene or field group, for stable display ordering.
    public let sourceIndex: Int?
    public let target: ProductionTarget

    public init(
        id: String,
        kind: ProductionItemKind,
        reason: ProductionItemReason,
        isDone: Bool = false,
        sceneID: UUID? = nil,
        sceneOrder: Int? = nil,
        sceneTitle: String = "",
        languageCode: String? = nil,
        sourceText: String = "",
        sourceIndex: Int? = nil,
        target: ProductionTarget
    ) {
        self.id = id
        self.kind = kind
        self.reason = reason
        self.isDone = isDone
        self.sceneID = sceneID
        self.sceneOrder = sceneOrder
        self.sceneTitle = sceneTitle
        self.languageCode = languageCode
        self.sourceText = sourceText
        self.sourceIndex = sourceIndex
        self.target = target
    }
}

/// Counts exposed to the board view and the MCP.
///
/// `pendingByKind` always contains every `ProductionItemKind`, including zero
/// counts, so consumers get a stable shape.
public struct ProductionSummary: Codable, Sendable, Equatable {
    public var pendingByKind: [String: Int]
    public var totalPending: Int
    public var doneManualCount: Int
    public var totalCount: Int

    public init(items: [ProductionItem]) {
        var pending: [String: Int] = [:]
        for kind in ProductionItemKind.allCases {
            pending[kind.rawValue] = 0
        }
        var doneManual = 0
        for item in items {
            if item.isDone {
                if item.reason == .manualTask { doneManual += 1 }
            } else {
                pending[item.kind.rawValue, default: 0] += 1
            }
        }
        pendingByKind = pending
        totalPending = pending.values.reduce(0, +)
        doneManualCount = doneManual
        totalCount = items.count
    }

    public func pendingCount(for kind: ProductionItemKind) -> Int {
        pendingByKind[kind.rawValue] ?? 0
    }

    public static let empty = ProductionSummary(items: [])
}

/// A recomputed checklist plus its counts.
public struct ProductionSnapshot: Sendable, Equatable {
    public let items: [ProductionItem]
    public let summary: ProductionSummary

    public init(items: [ProductionItem], summary: ProductionSummary) {
        self.items = items
        self.summary = summary
    }

    public static let empty = ProductionSnapshot(items: [], summary: .empty)
}

/// Language-code normalisation shared by the take, variant and publishing
/// rules. `es-ES`, `ES` and `es_ES` all become `es`.
public enum ProductionLanguage {
    public static func normalized(_ code: String) -> String {
        let cleaned = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return cleaned
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
    }
}

/// Pure derivation for the F16 production checklist.
///
/// Rules (all recomputed from the document, never stored as duplicates):
/// - a scene with script text but no usable `good` take for a language needs
///   recording;
/// - a B-roll item that is not `.done`, or that has no linked asset, needs
///   footage or an asset;
/// - an editing note whose status is `.pending` needs editing;
/// - a claim needs research while `ResearchSummary.isPending` says so, and a
///   mirrored `.research` checklist task never produces a second row;
/// - each project with at least one publishing pack is checked against the
///   eight items of the Publishing panel checklist (once per project, tied to
///   the primary-language pack); the raw `publishing.checklist.*` tasks are
///   never shown as manual rows;
/// - manual `ChecklistTask` rows are included as-is.
///
/// A take is usable only while its `sceneTextHash` still matches the text it
/// was recorded against (empty hashes are legacy takes and count), matching the
/// duration rules: editing the script must not silently complete a recording.
public enum ProductionChecklist {
    public static func items(for project: FrameScriptDocument.Project) -> [ProductionItem] {
        // Documents are untrusted input. Duplicate IDs would otherwise crash
        // dictionary construction or produce duplicate SwiftUI identities.
        var seenSceneIDs = Set<UUID>()
        let scenes = project.scenes
            .sorted(by: sceneSort)
            .filter { seenSceneIDs.insert($0.id).inserted }

        let primaryLanguage = ProductionLanguage.normalized(project.primaryLanguage)
        let linkedBRollItemIDs = Set(project.assets.flatMap(\.linkedBRollItemIDs))
        var scenesByID: [UUID: FrameScriptDocument.Scene] = [:]
        for scene in scenes {
            scenesByID[scene.id] = scene
        }

        var items: [ProductionItem] = []
        for scene in scenes {
            items.append(contentsOf: recordingItems(for: scene, primaryLanguage: primaryLanguage))
            items.append(contentsOf: bRollItems(for: scene, linkedItemIDs: linkedBRollItemIDs))
            items.append(contentsOf: editingItems(for: scene))
        }

        var seenClaimIDs = Set<UUID>()
        var claimTexts = Set<String>()
        for (index, claim) in project.claims.enumerated() {
            // The claim row owns the fact. A stored `.research` task with the
            // same text is a mirror and must not produce a second row (E-2).
            let normalizedText = ResearchChecklist.normalized(claim.text)
            if !normalizedText.isEmpty {
                claimTexts.insert(normalizedText)
            }
            guard ResearchSummary.isPending(claim),
                  seenClaimIDs.insert(claim.id).inserted else { continue }
            let linkedScene = claim.sceneIDs.lazy.compactMap { scenesByID[$0] }.first
            items.append(
                ProductionItem(
                    id: "claim:\(claim.id.uuidString)",
                    kind: .research,
                    reason: .claimNeedsVerification,
                    sceneID: linkedScene?.id,
                    sceneOrder: linkedScene?.order,
                    sceneTitle: linkedScene?.title ?? "",
                    sourceText: claim.text,
                    sourceIndex: index,
                    target: .research(claimID: claim.id)
                )
            )
        }

        // The Publishing panel stores its eight checks as `ChecklistTask`s with
        // a stable token. The done state is per project, not per language, so
        // Production must emit the eight rows exactly once. They point at the
        // primary language's pack (or the first pack when the primary language
        // has none) so ticking a check clears one row, not one per language
        // (NEW-1, must-fix 2).
        var publishingDone = Set<PublishingChecklistItem>()
        var seenPublishingItems = Set<PublishingChecklistItem>()
        for task in project.checklistTasks {
            guard let item = PublishingChecklistItem.item(forTaskText: task.text),
                  seenPublishingItems.insert(item).inserted else { continue }
            if task.isDone { publishingDone.insert(item) }
        }

        if let languageKey = publishingLanguageKey(for: project) {
            items.append(contentsOf: publishingItems(
                languageKey: languageKey,
                doneItems: publishingDone
            ))
        }

        var seenTaskIDs = Set<UUID>()
        for (index, task) in project.checklistTasks.enumerated()
        where seenTaskIDs.insert(task.id).inserted {
            if PublishingChecklistItem.item(forTaskText: task.text) != nil {
                continue
            }
            if task.kind == .research,
               claimTexts.contains(ResearchChecklist.normalized(task.text)) {
                continue
            }
            let linkedScene = task.sceneID.flatMap { scenesByID[$0] }
            items.append(
                ProductionItem(
                    id: "manual:\(task.id.uuidString)",
                    kind: task.kind.productionKind,
                    reason: .manualTask,
                    isDone: task.isDone,
                    sceneID: linkedScene?.id,
                    sceneOrder: linkedScene?.order,
                    sceneTitle: linkedScene?.title ?? "",
                    sourceText: task.text,
                    sourceIndex: index,
                    target: .manualTask(taskID: task.id)
                )
            )
        }

        // A final global identity guard: corrupt documents can repeat a
        // B-roll or editing ID across scenes, and SwiftUI needs unique IDs.
        var seenItemIDs = Set<String>()
        return items.filter { seenItemIDs.insert($0.id).inserted }
    }

    public static func snapshot(for project: FrameScriptDocument.Project) -> ProductionSnapshot {
        let items = items(for: project)
        return ProductionSnapshot(items: items, summary: ProductionSummary(items: items))
    }

    public static func summary(for project: FrameScriptDocument.Project) -> ProductionSummary {
        ProductionSummary(items: items(for: project))
    }

    // MARK: - Recording

    private static func recordingItems(
        for scene: FrameScriptDocument.Scene,
        primaryLanguage: String
    ) -> [ProductionItem] {
        var items: [ProductionItem] = []

        if !isBlank(scene.scriptText) {
            let primaryTakes = scene.takes.filter { take in
                let code = ProductionLanguage.normalized(take.languageCode)
                return code.isEmpty || code == primaryLanguage
            }
            if !hasGoodTake(primaryTakes, sourceText: scene.scriptText) {
                items.append(recordingItem(scene: scene, languageCode: nil, targetLanguageCode: ""))
            }
        }

        // One row per translated language, even if the document happens to
        // contain duplicate variant entries for the same code.
        var seenLanguages = Set<String>()
        for variant in scene.languageVariants where !isBlank(variant.text) {
            let code = ProductionLanguage.normalized(variant.languageCode)
            guard !code.isEmpty, seenLanguages.insert(code).inserted else { continue }
            let sceneTakes = scene.takes.filter {
                ProductionLanguage.normalized($0.languageCode) == code
            }
            if !hasGoodTake(sceneTakes + variant.takes, sourceText: variant.text) {
                items.append(recordingItem(scene: scene, languageCode: code, targetLanguageCode: code))
            }
        }

        return items
    }

    private static func recordingItem(
        scene: FrameScriptDocument.Scene,
        languageCode: String?,
        targetLanguageCode: String
    ) -> ProductionItem {
        ProductionItem(
            id: "record:\(scene.id.uuidString):\(languageCode ?? "original")",
            kind: .record,
            reason: .sceneNeedsTake,
            sceneID: scene.id,
            sceneOrder: scene.order,
            sceneTitle: scene.title,
            languageCode: languageCode,
            sourceText: scene.title,
            target: .takes(sceneID: scene.id, languageCode: targetLanguageCode)
        )
    }

    private static func hasGoodTake(
        _ takes: [FrameScriptDocument.Take],
        sourceText: String
    ) -> Bool {
        let currentHash = FrameScriptDocument.TextHash.hash(sourceText)
        return takes.contains { take in
            take.rating == .good
                && (take.sceneTextHash.isEmpty || take.sceneTextHash == currentHash)
        }
    }

    // MARK: - B-roll and editing

    private static func bRollItems(
        for scene: FrameScriptDocument.Scene,
        linkedItemIDs: Set<UUID>
    ) -> [ProductionItem] {
        var seenItemIDs = Set<UUID>()
        return scene.bRollItems.enumerated().compactMap { index, item in
            guard seenItemIDs.insert(item.id).inserted else { return nil }
            let isPending = item.status != .done
            let hasAsset = linkedItemIDs.contains(item.id)
            guard isPending || !hasAsset else { return nil }
            return ProductionItem(
                id: "broll:\(item.id.uuidString)",
                kind: .acquire,
                reason: isPending ? .bRollNeedsFootage : .bRollNeedsAsset,
                sceneID: scene.id,
                sceneOrder: scene.order,
                sceneTitle: scene.title,
                sourceText: firstNonBlank(item.descriptionText, item.notes),
                sourceIndex: index,
                target: .bRoll(sceneID: scene.id, itemID: item.id)
            )
        }
    }

    private static func editingItems(for scene: FrameScriptDocument.Scene) -> [ProductionItem] {
        var seenItemIDs = Set<UUID>()
        return scene.editingItems.enumerated().compactMap { index, item in
            guard seenItemIDs.insert(item.id).inserted, item.status == .pending else { return nil }
            return ProductionItem(
                id: "edit:\(item.id.uuidString)",
                kind: .edit,
                reason: .editingNeedsWork,
                sceneID: scene.id,
                sceneOrder: scene.order,
                sceneTitle: scene.title,
                sourceText: firstNonBlank(item.cutStyle, item.notes),
                sourceIndex: index,
                target: .editing(sceneID: scene.id, itemID: item.id)
            )
        }
    }

    // MARK: - Publishing

    /// The pack the eight project-wide checks belong to: the primary language
    /// when it has a pack, otherwise the first sorted language.
    private static func publishingLanguageKey(
        for project: FrameScriptDocument.Project
    ) -> String? {
        let keys = project.publishingPacks.keys
            .filter { !isBlank($0) }
            .sorted()
        guard !keys.isEmpty else { return nil }
        let primary = ProductionLanguage.normalized(project.primaryLanguage)
        if !primary.isEmpty,
           let match = keys.first(where: { ProductionLanguage.normalized($0) == primary }) {
            return match
        }
        return keys.first
    }

    private static func publishingItems(
        languageKey: String,
        doneItems: Set<PublishingChecklistItem>
    ) -> [ProductionItem] {
        var items: [ProductionItem] = []

        func append(_ item: PublishingChecklistItem, index: Int) {
            items.append(
                ProductionItem(
                    id: "publish:checklist:\(item.rawValue)",
                    kind: .publish,
                    reason: .publishingChecklist(item),
                    languageCode: languageKey,
                    sourceIndex: index,
                    target: .publishing(languageCode: languageKey)
                )
            )
        }

        // The Publishing panel shows `done/8`; Production must count exactly
        // the same eight checks. Field-level checks would duplicate four of
        // them, so they are intentionally not emitted here.
        for (index, item) in PublishingChecklistItem.allCases.enumerated()
        where !doneItems.contains(item) {
            append(item, index: index)
        }
        return items
    }

    // MARK: - Helpers

    private static func sceneSort(
        _ lhs: FrameScriptDocument.Scene,
        _ rhs: FrameScriptDocument.Scene
    ) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func firstNonBlank(_ candidates: String...) -> String {
        for candidate in candidates where !isBlank(candidate) {
            return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}

public extension FrameScriptDocument.ChecklistTaskKind {
    /// Manual task categories reuse the checklist buckets; `other` stays
    /// separate so free-form tasks do not inflate the recording count.
    var productionKind: ProductionItemKind {
        switch self {
        case .record: .record
        case .acquire: .acquire
        case .edit: .edit
        case .research: .research
        case .other: .other
        }
    }
}
