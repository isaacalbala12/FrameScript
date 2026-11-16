import Foundation
@testable import FrameScriptCore
import Testing

// MARK: - Temporary folders

func makeBoardTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrameScriptBoard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Documents

func boardTake(
    number: Int = 1,
    daysAgo: Double = 1,
    duration: TimeInterval,
    rating: FrameScriptDocument.TakeRating = .good,
    languageCode: String = "",
    sceneTextHash: String = ""
) -> FrameScriptDocument.Take {
    FrameScriptDocument.Take(
        number: number,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
        duration: duration,
        rating: rating,
        languageCode: languageCode,
        sceneTextHash: sceneTextHash
    )
}

func boardScene(
    id: UUID = UUID(),
    order: Int,
    title: String,
    text: String = "",
    estimatedDuration: TimeInterval = 0,
    bRollItems: [FrameScriptDocument.BRollItem] = [],
    editingItems: [FrameScriptDocument.EditingItem] = [],
    takes: [FrameScriptDocument.Take] = [],
    variants: [FrameScriptDocument.SceneLanguageVariant] = []
) -> FrameScriptDocument.Scene {
    FrameScriptDocument.Scene(
        id: id,
        order: order,
        sectionType: .custom,
        title: title,
        scriptText: text,
        estimatedDuration: estimatedDuration,
        bRollItems: bRollItems,
        editingItems: editingItems,
        takes: takes,
        languageVariants: variants
    )
}

func boardDocument(
    id: UUID = UUID(),
    title: String = "Synthetic project",
    topic: String = "",
    videoType: String = "",
    status: FrameScriptDocument.ProductionStatus = .idea,
    targetDate: Date? = nil,
    publishDate: Date? = nil,
    primaryLanguage: String = "es",
    learnedWordsPerMinute: [String: Double] = [:],
    publishingPacks: [String: FrameScriptDocument.PublishingPack] = [:],
    checklistTasks: [FrameScriptDocument.ChecklistTask] = [],
    claims: [FrameScriptDocument.Claim] = [],
    scenes: [FrameScriptDocument.Scene] = []
) -> FrameScriptDocument {
    FrameScriptDocument(
        project: FrameScriptDocument.Project(
            id: id,
            title: title,
            scenes: scenes,
            primaryLanguage: primaryLanguage,
            topic: topic,
            videoType: videoType,
            productionStatus: status,
            targetDate: targetDate,
            publishDate: publishDate,
            learnedWordsPerMinuteByLanguage: learnedWordsPerMinute,
            publishingPacks: publishingPacks,
            checklistTasks: checklistTasks,
            claims: claims
        )
    )
}

func writeBoardDocument(_ document: FrameScriptDocument, to url: URL) throws {
    try FrameScriptDocumentCodec.write(document, to: url)
}

// MARK: - Summaries

func boardSummary(
    path: String,
    title: String,
    topic: String = "",
    videoType: String = "",
    status: FrameScriptDocument.ProductionStatus = .idea,
    targetDate: Date? = nil,
    publishDate: Date? = nil,
    updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    duration: TimeInterval = 300,
    pendingTasks: [BoardPendingTask] = []
) -> BoardProjectSummary {
    BoardProjectSummary(
        fileURL: URL(fileURLWithPath: path),
        projectID: UUID(),
        title: title,
        topic: topic,
        videoType: videoType,
        productionStatus: status,
        targetDate: targetDate,
        publishDate: publishDate,
        updatedAt: updatedAt,
        createdAt: updatedAt,
        templateID: nil,
        sceneCount: 3,
        duration: BoardDuration(
            seconds: duration,
            estimatedSeconds: duration,
            realSceneCount: 0,
            sceneCount: 3
        ),
        pendingTasks: pendingTasks,
        fingerprint: BoardFileFingerprint(
            contentHash: "hash-\(path)",
            fileSize: 100,
            modificationDate: updatedAt
        )
    )
}

func boardPendingTask(
    id: String = UUID().uuidString,
    kind: PlaneTaskKind = .manual,
    title: String = "Task",
    sceneTitle: String = "Scene"
) -> BoardPendingTask {
    BoardPendingTask(id: id, kind: kind, title: title, sceneTitle: sceneTitle)
}
