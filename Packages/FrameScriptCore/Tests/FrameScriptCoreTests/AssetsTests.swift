import Foundation
import Testing
@testable import FrameScriptCore

// MARK: - Support

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FrameScriptAssets-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeFile(
    _ name: String,
    in directory: URL,
    contents: String = "fixture"
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url, options: .atomic)
    return url
}

private func makeAsset(
    path: String,
    kind: FrameScriptDocument.AssetKind = .web,
    tags: [String] = [],
    sceneIDs: [UUID] = [],
    visualIDs: [UUID] = [],
    takeIDs: [UUID] = [],
    missing: Bool = false,
    modifiedAt: Date? = nil
) -> FrameScriptDocument.ProjectAsset {
    FrameScriptDocument.ProjectAsset(
        path: path,
        kind: kind,
        tags: tags,
        linkedSceneIDs: sceneIDs,
        linkedBRollItemIDs: visualIDs,
        linkedTakeIDs: takeIDs,
        duration: nil,
        fileSize: nil,
        modifiedAt: modifiedAt,
        isLastKnownMissing: missing
    )
}

// MARK: - Kind detection

@Test func kindDetectionUsesTheExtensionFamily() {
    #expect(AssetKindDetector.kind(forPath: "/tmp/toma.MOV") == .camera)
    #expect(AssetKindDetector.kind(forPath: "/tmp/toma.mp4") == .camera)
    #expect(AssetKindDetector.kind(forPath: "/tmp/foto.HEIC") == .graphic)
    #expect(AssetKindDetector.kind(forPath: "/tmp/logo.svg") == .graphic)
    #expect(AssetKindDetector.kind(forPath: "/tmp/musica.mp3") == .music)
    #expect(AssetKindDetector.kind(forPath: "/tmp/fuente.wav") == .music)
    #expect(AssetKindDetector.kind(forPath: "/tmp/referencia.html") == .web)
    #expect(AssetKindDetector.kind(forPath: "/tmp/nota.pdf") == .web)
    #expect(AssetKindDetector.kind(forPath: "/tmp/sin-extension") == .web)
}

@Test func kindDetectionRecognisesScreenCapturesAndThumbnails() {
    #expect(AssetKindDetector.kind(forPath: "/tmp/Screenshot 2026-01-02 at 09.15.00.png") == .screenshot)
    #expect(AssetKindDetector.kind(forPath: "/tmp/Captura de pantalla 2026-01-02 a las 9.15.00.png") == .screenshot)
    #expect(AssetKindDetector.kind(forPath: "/tmp/miniatura-final.jpg") == .thumbnail)
    #expect(AssetKindDetector.kind(forPath: "/tmp/thumbnail_v2.png") == .thumbnail)
    // Name heuristics only refine images: a video called “captura” is still a camera clip.
    #expect(AssetKindDetector.kind(forPath: "/tmp/captura.mov") == .camera)
}

@Test func mediaCategoriesDriveMetadataWork() {
    #expect(AssetKindDetector.mediaCategory(forPath: "/tmp/a.mkv") == .video)
    #expect(AssetKindDetector.mediaCategory(forPath: "/tmp/a.png") == .image)
    #expect(AssetKindDetector.mediaCategory(forPath: "/tmp/a.flac") == .audio)
    #expect(AssetKindDetector.mediaCategory(forPath: "/tmp/a.md") == .document)
    #expect(AssetKindDetector.mediaCategory(forPath: "/tmp/a.bin") == .other)
}

// MARK: - Path normalisation and identity

@Test func pathsNormalizeWithoutNeedingTheFileToExist() {
    let normalized = AssetPath.normalized("/tmp/missing/../missing/./toma.mov")
    #expect(normalized == "/tmp/missing/toma.mov")
    #expect(AssetPath.normalized("/tmp/toma.mov/") == "/tmp/toma.mov")
    #expect(AssetPath.normalized("   ") == "")
}

@Test func tildeExpandsToTheHomeDirectory() {
    let normalized = AssetPath.normalized("~/Movies/toma.mov")
    #expect(normalized == (NSHomeDirectory() as NSString).appendingPathComponent("Movies/toma.mov"))
}

@Test func identityKeyFoldsCaseForDuplicateDetection() {
    #expect(AssetPath.identityKey("/tmp/Toma.MOV") == AssetPath.identityKey("/tmp/toma.mov"))
    #expect(AssetPath.identityKey("/tmp/../tmp/toma.mov") == AssetPath.identityKey("/tmp/toma.mov"))
    #expect(AssetPath.identityKey("") == "")
    #expect(AssetPath.isSameFile("/tmp/A.png", "/tmp/a.PNG"))
    #expect(!AssetPath.isSameFile("", ""))
}

@Test func displayHelpersUseTheLastPathComponent() {
    #expect(AssetPath.fileName("/tmp/carpeta/toma.mov") == "toma.mov")
    #expect(AssetPath.baseName("/tmp/carpeta/toma.mov") == "toma")
    #expect(AssetPath.fileExtension("/tmp/carpeta/Toma.MOV") == "mov")
    #expect(AssetPath.fileName("") == "")
}

// MARK: - Tags and de-duplication

@Test func tagNormalizationTrimsDropsEmptyAndFoldsCase() {
    #expect(AssetTags.normalized([" B-roll ", "", "b-roll", "Música", "musica"]) == ["B-roll", "Música"])
    #expect(AssetTags.contains("B-ROLL", in: ["b-roll"]))
    #expect(AssetTags.adding("  ", to: ["a"]) == ["a"])
    #expect(AssetTags.removing("B-ROLL", from: ["b-roll", "otra"]) == ["otra"])
}

@Test func deduplicationFindsTheSameFileWrittenDifferently() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try writeFile("toma.mov", in: directory)

    let assets = [makeAsset(path: url.path.uppercased())]
    #expect(AssetDeduplication.index(of: url, in: assets) == 0)
    #expect(AssetDeduplication.index(ofPath: "~/nope.mov", in: assets) == nil)
}

@Test func mergingADuplicateKeepsUserDataAndFillsGaps() {
    let sceneID = UUID()
    let takeID = UUID()
    var existing = makeAsset(
        path: "/tmp/toma.mov",
        kind: .camera,
        tags: ["plano"],
        sceneIDs: [sceneID],
        takeIDs: [takeID],
        modifiedAt: Date(timeIntervalSince1970: 10)
    )
    let incoming = FrameScriptDocument.ProjectAsset(
        path: "/tmp/Toma.MOV",
        bookmarkData: Data([1, 2, 3]),
        kind: .obs,
        tags: ["Plano", "nuevo"],
        linkedSceneIDs: [sceneID],
        linkedBRollItemIDs: [UUID()],
        linkedTakeIDs: [takeID],
        isCopiedIntoProject: true,
        duration: 12,
        fileSize: 99,
        modifiedAt: Date(timeIntervalSince1970: 5)
    )

    AssetDeduplication.merge(incoming, into: &existing)

    #expect(existing.kind == .camera)
    #expect(existing.tags == ["plano", "nuevo"])
    #expect(existing.linkedSceneIDs == [sceneID])
    #expect(existing.linkedTakeIDs == [takeID])
    #expect(existing.linkedBRollItemIDs.count == 1)
    #expect(existing.bookmarkData == Data([1, 2, 3]))
    #expect(existing.duration == 12)
    #expect(existing.fileSize == 99)
    #expect(existing.modifiedAt == Date(timeIntervalSince1970: 10))
    #expect(existing.isCopiedIntoProject)
}

// MARK: - Bookmarks

@Test func bookmarksRoundTripToTheSameFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try writeFile("toma.mov", in: directory)

    let data = try #require(AssetBookmark.make(for: url))
    let resolved = try #require(AssetBookmark.resolve(data))
    #expect(AssetPath.isSameFile(resolved.path, url.path))

    let accessed = AssetBookmark.withAccess(data) { $0.path }
    #expect(AssetPath.isSameFile(try #require(accessed), url.path))
}

// MARK: - Reachability

@Test func reachableAndMissingFilesAreReported() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try writeFile("toma.mov", in: directory)
    let present = makeAsset(path: file.path)
    let absent = makeAsset(path: directory.appendingPathComponent("borrada.mov").path)

    let results = AssetReachabilityChecker.check([present, absent])

    #expect(results.count == 2)
    #expect(results[0].reachability == .reachable)
    #expect(!results[0].isMissing)
    #expect(results[1].reachability == .missing)
    #expect(results[1].isMissing)
}

@Test func aBookmarkRescuesAFileThatMovedAwayFromItsStoredPath() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try writeFile("toma.mov", in: directory)
    let bookmark = try #require(AssetBookmark.make(for: file))
    let asset = FrameScriptDocument.ProjectAsset(
        path: "/tmp/definitely-not-here/\(UUID().uuidString).mov",
        bookmarkData: bookmark
    )

    let result = AssetReachabilityChecker.check(asset)

    #expect(result.reachability == .reachable)
    #expect(AssetPath.isSameFile(result.path, file.path))
}

@Test func applyingAReportUpdatesTheMissingFlagAndTrackedPath() {
    let missingID = UUID()
    let movedID = UUID()
    var assets = [
        makeAsset(path: "/tmp/one.mov"),
        makeAsset(path: "/tmp/two.mov")
    ]
    assets[0].id = missingID
    assets[1].id = movedID
    let results = [
        AssetReachabilityResult(assetID: missingID, path: "/tmp/one.mov", reachability: .missing),
        AssetReachabilityResult(assetID: movedID, path: "/tmp/moved/two.mov", reachability: .reachable)
    ]

    #expect(AssetReachabilityChecker.apply(results, to: &assets))
    #expect(assets[0].isLastKnownMissing)
    #expect(assets[1].path == "/tmp/moved/two.mov")
    #expect(!assets[1].isLastKnownMissing)
    // Applying the same report again is a no-op.
    #expect(!AssetReachabilityChecker.apply(results, to: &assets))
}

@Test func anEmptyPathIsMissing() {
    let asset = makeAsset(path: "")
    #expect(AssetReachabilityChecker.check(asset).reachability == .missing)
}

// MARK: - Thumbnail store

@Test func assetsFolderLivesNextToTheProjectFile() {
    let project = URL(fileURLWithPath: "/Users/example/Documents/Mi Vídeo.fscr")
    #expect(AssetStore.assetsDirectoryName(forProjectFile: project) == "Mi Vídeo assets")
    #expect(AssetStore.assetsDirectory(forProjectFile: project).path == "/Users/example/Documents/Mi Vídeo assets")
}

@Test func copyThumbnailCreatesTheFolderAndCopiesTheFile() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let source = try writeFile("cover.png", in: sourceDirectory, contents: "image-bytes")
    let project = root.appendingPathComponent("Proyecto.fscr")

    let destination = try AssetStore.copyThumbnail(from: source, projectFileURL: project)

    #expect(destination.deletingLastPathComponent().lastPathComponent == "Proyecto assets")
    #expect(destination.lastPathComponent == "cover.png")
    #expect(try String(contentsOf: destination, encoding: .utf8) == "image-bytes")
    #expect(FileManager.default.fileExists(atPath: source.path), "the source must never be moved or deleted")
}

@Test func copyThumbnailNeverOverwritesAndHonoursPreferredNames() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeFile("cover.png", in: root, contents: "v1")
    let project = root.appendingPathComponent("Proyecto.fscr")

    let first = try AssetStore.copyThumbnail(from: source, projectFileURL: project, preferredName: "miniatura")
    #expect(first.lastPathComponent == "miniatura.png")

    try Data("v2".utf8).write(to: source, options: .atomic)
    let second = try AssetStore.copyThumbnail(from: source, projectFileURL: project, preferredName: "miniatura")
    #expect(second.lastPathComponent == "miniatura 2.png")
    #expect(second != first)
    #expect(try String(contentsOf: first, encoding: .utf8) == "v1")
    #expect(try String(contentsOf: second, encoding: .utf8) == "v2")
}

@Test func copyingTwoDifferentFilesWithTheSameNameKeepsBoth() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstSource = try writeFile("portada.png", in: root, contents: "first")
    let secondDirectory = root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    let secondSource = try writeFile("portada.png", in: secondDirectory, contents: "second")
    let project = root.appendingPathComponent("Proyecto.fscr")

    let first = try AssetStore.copyThumbnail(from: firstSource, projectFileURL: project)
    let second = try AssetStore.copyThumbnail(from: secondSource, projectFileURL: project)

    #expect(first.lastPathComponent == "portada.png")
    #expect(second.lastPathComponent == "portada 2.png")
    #expect(try String(contentsOf: first, encoding: .utf8) == "first")
    #expect(try String(contentsOf: second, encoding: .utf8) == "second")
}

@Test func copyThumbnailRejectsAMissingSource() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Proyecto.fscr")
    let missing = root.appendingPathComponent("no-existe.png")

    #expect(throws: AssetStoreError.sourceMissing) {
        try AssetStore.copyThumbnail(from: missing, projectFileURL: project)
    }
}

@Test func copyThumbnailRequiresASavedProject() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeFile("cover.png", in: root)

    #expect(throws: AssetStoreError.projectFileMissing) {
        try AssetStore.copyThumbnail(from: source, projectFileURL: nil)
    }
}

@Test func thumbnailAssetRecordsTheCopiedFileNotTheOriginal() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try writeFile("cover.png", in: root, contents: "12345")
    let project = root.appendingPathComponent("Proyecto.fscr")

    let asset = try AssetStore.makeThumbnailAsset(
        from: source,
        projectFileURL: project,
        tags: [" portada ", "portada"]
    )

    #expect(asset.kind == .thumbnail)
    #expect(asset.isCopiedIntoProject)
    #expect(asset.tags == ["portada"])
    #expect(asset.fileSize == 5)
    #expect(asset.path.hasSuffix("/Proyecto assets/cover.png"))
    #expect(asset.bookmarkData != nil)
}

// MARK: - Query

@Test func filtersCombineKindTagSceneSearchAndMissingState() throws {
    let sceneA = UUID()
    let sceneB = UUID()
    let assets = [
        makeAsset(path: "/tmp/toma-camara.mov", kind: .camera, tags: ["plano"], sceneIDs: [sceneA]),
        makeAsset(path: "/tmp/musica-tema.mp3", kind: .music, tags: ["música"], sceneIDs: [sceneB]),
        makeAsset(path: "/tmp/miniatura.png", kind: .thumbnail, tags: ["portada"], sceneIDs: [sceneA], missing: true)
    ]

    #expect(AssetQuery.apply(assets, filter: AssetFilter(kind: .camera)).count == 1)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(tag: "MÚSICA")).count == 1)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(sceneID: sceneA)).count == 2)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(missingOnly: true)).map(\.path) == ["/tmp/miniatura.png"])
    #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "portada")).count == 1)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "toma")).count == 1)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(searchText: "no existe")).isEmpty)
    #expect(AssetQuery.apply(assets, filter: AssetFilter(kind: .camera, tag: "música")).isEmpty)
}

@Test func sortingIsDeterministic() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let assets = [
        makeAsset(path: "/tmp/zeta.mov", kind: .camera, modifiedAt: older),
        makeAsset(path: "/tmp/alfa.png", kind: .thumbnail, modifiedAt: newer),
        makeAsset(path: "/tmp/beta.mp3", kind: .music)
    ]

    #expect(AssetQuery.apply(assets, sort: .name).map { AssetPath.fileName($0.path) } == ["alfa.png", "beta.mp3", "zeta.mov"])
    #expect(AssetQuery.apply(assets, sort: .kind).map { AssetPath.fileName($0.path) } == ["zeta.mov", "beta.mp3", "alfa.png"])
    #expect(AssetQuery.apply(assets, sort: .recentlyModified).map { AssetPath.fileName($0.path) } == ["alfa.png", "zeta.mov", "beta.mp3"])
}

@Test func queryListsTagsAndKindsForMenus() {
    let assets = [
        makeAsset(path: "/tmp/a.mov", kind: .camera, tags: ["b-roll", "Plano"]),
        makeAsset(path: "/tmp/b.mp3", kind: .music, tags: ["plano"]),
        makeAsset(path: "/tmp/c.mov", kind: .camera)
    ]

    #expect(AssetQuery.tags(in: assets) == ["b-roll", "Plano"])
    #expect(AssetQuery.kinds(in: assets) == [.camera, .music])
    #expect(AssetQuery.linkCount(assets[0]) == 0)
}

// MARK: - OBS take sync

@Test func aFinishedTakeBecomesAnOBSAssetWithItsLinks() throws {
    let sceneID = UUID()
    let take = FrameScriptDocument.Take(
        number: 2,
        startedAt: Date(timeIntervalSince1970: 10),
        duration: 42.5,
        filePath: "/tmp/tomas/Plano 03.mkv"
    )

    let asset = try #require(OBSTakeAssetSync.makeAsset(for: take, sceneID: sceneID))

    #expect(asset.kind == .obs)
    #expect(asset.path == "/tmp/tomas/Plano 03.mkv")
    #expect(asset.duration == 42.5)
    #expect(asset.linkedSceneIDs == [sceneID])
    #expect(asset.linkedTakeIDs == [take.id])
    #expect(!asset.isCopiedIntoProject)
}

@Test func syncingTheSameTakeTwiceUpdatesOneEntry() throws {
    let sceneID = UUID()
    let takeID = UUID()
    let existingAsset = FrameScriptDocument.ProjectAsset(
        path: "/tmp/Plano 03.mkv",
        bookmarkData: Data([9]),
        kind: .obs,
        tags: ["plano"],
        linkedSceneIDs: [sceneID],
        linkedTakeIDs: [takeID],
        duration: 10
    )
    var assets = [existingAsset]
    let updatedTake = FrameScriptDocument.Take(
        id: takeID,
        number: 1,
        startedAt: Date(timeIntervalSince1970: 0),
        duration: 31,
        filePath: "/tmp/Plano 03.mkv"
    )

    let index = try #require(OBSTakeAssetSync.upsert(take: updatedTake, sceneID: sceneID, into: &assets))

    #expect(index == 0)
    #expect(assets.count == 1)
    // User tags and the existing bookmark survive.
    #expect(assets[0].tags == ["plano"])
    #expect(assets[0].bookmarkData == Data([9]))
    #expect(assets[0].duration == 31)
    #expect(assets[0].linkedTakeIDs == [takeID])
}

@Test func aDifferentTakeForTheSameFileDoesNotDuplicateTheAsset() throws {
    let sceneID = UUID()
    let firstTake = FrameScriptDocument.Take(
        number: 1,
        startedAt: Date(timeIntervalSince1970: 0),
        duration: 10,
        filePath: "/tmp/Replay.mkv"
    )
    var assets = [try #require(OBSTakeAssetSync.makeAsset(for: firstTake, sceneID: sceneID))]
    let secondSceneID = UUID()
    let secondTake = FrameScriptDocument.Take(
        number: 1,
        startedAt: Date(timeIntervalSince1970: 30),
        duration: 12,
        filePath: "/tmp/replay.mkv"
    )

    let index = try #require(OBSTakeAssetSync.upsert(take: secondTake, sceneID: secondSceneID, into: &assets))

    #expect(index == 0)
    #expect(assets.count == 1)
    #expect(assets[0].linkedTakeIDs.contains(firstTake.id))
    #expect(assets[0].linkedTakeIDs.contains(secondTake.id))
    #expect(assets[0].linkedSceneIDs.contains(sceneID))
    #expect(assets[0].linkedSceneIDs.contains(secondSceneID))
    #expect(assets[0].duration == 12)
}

@Test func takesWithoutAFileNeverCreateAssets() {
    let take = FrameScriptDocument.Take(number: 1, startedAt: Date(), duration: 5, filePath: "  ")
    var assets: [FrameScriptDocument.ProjectAsset] = []

    #expect(OBSTakeAssetSync.upsert(take: take, sceneID: UUID(), into: &assets) == nil)
    #expect(assets.isEmpty)
}

// MARK: - Links

@Test func linkTogglesAddAndRemoveIDs() {
    var asset = makeAsset(path: "/tmp/toma.mov")
    let sceneID = UUID()
    let visualID = UUID()
    let takeID = UUID()

    #expect(AssetLinks.toggle(sceneID: sceneID, in: &asset))
    #expect(AssetLinks.toggle(sceneID: sceneID, in: &asset) == false)
    #expect(asset.linkedSceneIDs.isEmpty)

    #expect(AssetLinks.toggle(bRollItemID: visualID, in: &asset))
    #expect(AssetLinks.toggle(takeID: takeID, in: &asset))
    #expect(asset.linkedBRollItemIDs == [visualID])
    #expect(asset.linkedTakeIDs == [takeID])
    #expect(AssetQuery.linkCount(asset) == 2)
}
