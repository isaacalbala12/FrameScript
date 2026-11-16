import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Helpers

private func w3TempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("W3FixCDHAssets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func w3WriteFile(
    _ name: String,
    in directory: URL,
    contents: String = "fixture"
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url, options: .atomic)
    return url
}

private func w3Asset(
    path: String,
    kind: FrameScriptDocument.AssetKind = .web,
    tags: [String] = [],
    takeIDs: [UUID] = []
) -> FrameScriptDocument.ProjectAsset {
    FrameScriptDocument.ProjectAsset(
        path: path,
        kind: kind,
        tags: tags,
        linkedTakeIDs: takeIDs
    )
}

@Suite("W3FixCDH assets")
struct W3FixCDHAssetTests {
    @Test("W3FixCDH relative asset paths resolve against the project folder, not the cwd")
    func relativePathResolvesAgainstProject() throws {
        let root = try w3TempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let assetsDirectory = root.appendingPathComponent("Proyecto assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        let file = try w3WriteFile("portada.png", in: assetsDirectory, contents: "image")
        let asset = w3Asset(path: "Proyecto assets/portada.png", kind: .thumbnail)

        let result = AssetReachabilityChecker.check(asset, projectDirectory: root)

        #expect(result.path == file.path)
        #expect(result.reachability == .reachable)
        #expect(!result.path.hasPrefix(FileManager.default.currentDirectoryPath + "/Proyecto assets"))
    }

    @Test("W3FixCDH search matches the localized badge label")
    func searchMatchesLocalizedKindLabels() {
        let assets = [
            w3Asset(path: "/tmp/pista01.mp3", kind: .music),
            w3Asset(path: "/tmp/portada.png", kind: .thumbnail),
            w3Asset(path: "/tmp/plano.mov", kind: .camera)
        ]

        #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "música")).map(\.path) == ["/tmp/pista01.mp3"])
        #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "miniatura")).map(\.path) == ["/tmp/portada.png"])
        #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "cámara")).map(\.path) == ["/tmp/plano.mov"])
    }

    @Test("W3FixCDH an OBS upsert keeps a hand-picked kind")
    func obsUpsertKeepsHandPickedKind() throws {
        let root = try w3TempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try w3WriteFile("Toma.mkv", in: root)
        let take = FrameScriptDocument.Take(
            number: 1,
            startedAt: Date(),
            duration: 12,
            filePath: file.path
        )
        var assets = [
            FrameScriptDocument.ProjectAsset(
                path: file.path,
                kind: .camera,
                linkedTakeIDs: [take.id]
            )
        ]

        OBSTakeAssetSync.upsert(take: take, sceneID: UUID(), into: &assets)

        #expect(assets.count == 1)
        #expect(assets[0].kind == .camera)
    }

    @Test("W3FixCDH a relinked path survives OBS sync when the take path is gone")
    func relinkedPathSurvivesOBSUpdate() throws {
        let root = try w3TempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original.mkv")
        let relinked = try w3WriteFile("Recuperada.mkv", in: root)
        let take = FrameScriptDocument.Take(
            number: 1,
            startedAt: Date(),
            duration: 12,
            filePath: original.path
        )
        var assets = [
            FrameScriptDocument.ProjectAsset(
                path: relinked.path,
                kind: .obs,
                linkedTakeIDs: [take.id]
            )
        ]

        OBSTakeAssetSync.upsert(take: take, sceneID: UUID(), into: &assets) { path in
            FileManager.default.fileExists(atPath: path)
        }

        #expect(assets.count == 1)
        #expect(assets[0].path == relinked.path)
    }

    @Test("W3FixCDH the production checklist hides publishing tokens")
    func productionChecklistHidesPublishingTokens() {
        let project = FrameScriptDocument.Project(
            title: "Proyecto",
            scenes: [],
            checklistTasks: [
                FrameScriptDocument.ChecklistTask(
                    text: PublishingChecklistItem.endScreen.taskToken,
                    kind: .other,
                    isDone: true
                ),
                FrameScriptDocument.ChecklistTask(
                    text: PublishingChecklistItem.tags.taskToken,
                    kind: .other,
                    isDone: false
                ),
                FrameScriptDocument.ChecklistTask(
                    text: "Comprar tarjeta SD",
                    kind: .acquire
                )
            ]
        )

        let items = ProductionChecklist.items(for: project)

        #expect(!items.contains { $0.sourceText.hasPrefix("publishing.checklist.") })
        #expect(items.contains { $0.sourceText == "Comprar tarjeta SD" })
    }

    @Test("W3FixCDH the Board and Plane export hide publishing tokens")
    func boardPendingTasksHidePublishingTokens() {
        let project = FrameScriptDocument.Project(
            title: "Proyecto",
            scenes: [],
            checklistTasks: [
                FrameScriptDocument.ChecklistTask(
                    text: PublishingChecklistItem.communityPost.taskToken,
                    kind: .other,
                    isDone: false
                ),
                FrameScriptDocument.ChecklistTask(
                    text: "Comprar tarjeta SD",
                    kind: .acquire
                )
            ]
        )

        let tasks = BoardPendingTaskDeriver().pendingTasks(for: project, labels: .english)

        #expect(!tasks.contains { $0.title.contains("publishing.checklist.") })
        #expect(tasks.contains { $0.title == "Comprar tarjeta SD" })
    }
}
