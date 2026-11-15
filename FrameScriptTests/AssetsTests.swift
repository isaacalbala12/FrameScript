import AppKit
import Foundation
import FrameScriptCore
import XCTest
@testable import FrameScript

@MainActor
final class AssetsTests: XCTestCase {
    // MARK: Fixtures

    private func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptAssetsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    @discardableResult
    private func writeFile(_ name: String, in directory: URL, contents: String = "fixture") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeAppState() -> AppState {
        let suiteName = "FrameScriptAssetsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(suiteName).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        let scene = Scene(order: 0, sectionType: .hook, title: "Escena", scriptText: "Texto de prueba")
        let project = FrameProject(title: "Proyecto", scenes: [scene])
        let recording = RecordingController(
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: NoopOBSSecretStore()),
            defaults: defaults
        )
        return AppState(
            projectStore: ProjectStore(project: project),
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: defaults, key: "settings"),
            recording: recording,
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults),
            customTemplates: []
        )
    }

    // MARK: Adding references

    func testAddingAnAssetReferencesTheFileWithoutCopyingIt() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()

        let asset = try XCTUnwrap(appState.addAsset(at: file, tags: [" b-roll ", "B-ROLL"]))

        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(asset.path, file.path)
        XCTAssertEqual(asset.kind, .camera)
        XCTAssertEqual(asset.tags, ["b-roll"])
        XCTAssertFalse(asset.isCopiedIntoProject)
        XCTAssertFalse(asset.isLastKnownMissing)
        XCTAssertNotNil(asset.bookmarkData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["clip.mov"],
            "the library must never copy media next to the project"
        )
    }

    func testAddingTheSameFileTwiceMergesTagsAndKeepsOneEntry() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()

        _ = appState.addAsset(at: file, tags: ["plano"])
        let sameFile = directory
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            .appendingPathComponent("clip.mov")
        _ = appState.addAsset(at: sameFile, tags: ["plano", "nuevo"])

        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(appState.assets.first?.tags, ["plano", "nuevo"])
    }

    func testKindCanBeOverriddenAndDetectsFromTheFile() throws {
        let directory = try makeTempDirectory()
        let image = try writeFile("grafico.png", in: directory)
        let audio = try writeFile("tema.mp3", in: directory)
        let appState = makeAppState()

        let graphic = try XCTUnwrap(appState.addAsset(at: image))
        let music = try XCTUnwrap(appState.addAsset(at: audio))
        let thumbnail = try XCTUnwrap(
            appState.addAsset(at: try writeFile("otra.png", in: directory), kind: .thumbnail)
        )

        XCTAssertEqual(graphic.kind, .graphic)
        XCTAssertEqual(music.kind, .music)
        XCTAssertEqual(thumbnail.kind, .thumbnail)
    }

    func testDirectoriesAreIgnored() throws {
        let directory = try makeTempDirectory()
        let appState = makeAppState()

        let added = appState.addAssets(at: [directory])

        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(appState.assets.isEmpty)
    }

    func testRemovingAnAssetOnlyRemovesTheReference() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        let asset = try XCTUnwrap(appState.addAsset(at: file))

        appState.removeAsset(id: asset.id)

        XCTAssertTrue(appState.assets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Reachability

    func testReachabilityRefreshMarksMissingEntriesAndKeepsThemVisible() async throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        let asset = try XCTUnwrap(appState.addAsset(at: file))
        try FileManager.default.removeItem(at: file)

        await appState.refreshAssetReachability()

        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(appState.assets.first?.id, asset.id)
        XCTAssertEqual(appState.assets.first?.isLastKnownMissing, true)
    }

    func testARecoveredFileClearsTheMissingWarning() async throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        _ = appState.addAsset(at: file)
        try FileManager.default.removeItem(at: file)
        await appState.refreshAssetReachability()
        XCTAssertEqual(appState.assets.first?.isLastKnownMissing, true)

        let replacement = try writeFile("clip.mov", in: directory, contents: "restored")
        await appState.refreshAssetReachability()

        XCTAssertEqual(appState.assets.first?.path, replacement.path)
        XCTAssertEqual(appState.assets.first?.isLastKnownMissing, false)
    }

    func testLocateRelinksAStaleEntryToAChosenFile() throws {
        let directory = try makeTempDirectory()
        let original = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        let asset = try XCTUnwrap(appState.addAsset(at: original))
        try FileManager.default.removeItem(at: original)
        let relocated = try writeFile("moved.mov", in: directory, contents: "moved")

        appState.locateAsset(id: asset.id, at: relocated)

        let relinked = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(relinked.path, relocated.path)
        XCTAssertFalse(relinked.isLastKnownMissing)
        XCTAssertNotNil(relinked.bookmarkData)
    }

    // MARK: Links

    func testAssetLinksCanBeToggledForScenesVisualsAndTakes() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        let asset = try XCTUnwrap(appState.addAsset(at: file))
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let visual = BRollItem(
            templateType: "B-roll",
            sourceType: .screenRecording,
            descriptionText: "Grabación de pantalla"
        )
        scene.bRollItems = [visual]
        let take = Take(number: 1, startedAt: Date(), duration: 4, filePath: file.path)
        scene.takes = [take]

        appState.toggleAssetSceneLink(assetID: asset.id, sceneID: scene.id)
        appState.toggleAssetBRollLink(assetID: asset.id, bRollItemID: visual.id)
        appState.toggleAssetTakeLink(assetID: asset.id, takeID: take.id)

        var updated = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(updated.linkedSceneIDs, [scene.id])
        XCTAssertEqual(updated.linkedBRollItemIDs, [visual.id])
        XCTAssertEqual(updated.linkedTakeIDs, [take.id])

        appState.toggleAssetTakeLink(assetID: asset.id, takeID: take.id)
        updated = try XCTUnwrap(appState.assets.first)
        XCTAssertTrue(updated.linkedTakeIDs.isEmpty)
    }

    // MARK: OBS takes

    func testOBSAssetIsCreatedUpdatedAndSurvivesTakeDeletion() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("Plano 03.mkv", in: directory)
        let appState = makeAppState()
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let take = Take(number: 1, startedAt: Date(), duration: 12, filePath: file.path)
        scene.takes = [take]

        appState.ensureOBSAsset(sceneID: scene.id, takeID: take.id, preferredPath: file.path)

        var asset = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(asset.kind, .obs)
        XCTAssertEqual(asset.path, file.path)
        XCTAssertEqual(asset.duration, 12)
        XCTAssertEqual(asset.linkedTakeIDs, [take.id])
        XCTAssertEqual(asset.linkedSceneIDs, [scene.id])

        var updatedTake = take
        updatedTake.duration = 31
        scene.takes = [updatedTake]
        appState.ensureOBSAsset(sceneID: scene.id, takeID: updatedTake.id, preferredPath: file.path)

        asset = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(asset.duration, 31)

        scene.takes = []
        XCTAssertEqual(appState.assets.count, 1, "deleting a take must not delete its asset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOBSAssetWithoutAFilePathIsIgnored() throws {
        let appState = makeAppState()
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let take = Take(number: 1, startedAt: Date(), duration: 4, filePath: "")
        scene.takes = [take]

        appState.ensureOBSAsset(sceneID: scene.id, takeID: take.id)

        XCTAssertTrue(appState.assets.isEmpty)
    }

    func testManualTakeNotifiesTheAssetHook() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("Toma manual.mkv", in: directory)
        let appState = makeAppState()
        let scene = try XCTUnwrap(appState.project.scenes.first)

        let added = appState.recording.addManualTake(
            sceneID: scene.id,
            startedAt: Date(),
            duration: 9,
            fileURL: file,
            note: "",
            languageCode: ""
        )

        XCTAssertTrue(added)
        let asset = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(asset.kind, .obs)
        XCTAssertEqual(asset.path, file.path)
        XCTAssertEqual(asset.linkedTakeIDs.count, 1)
    }

    func testOpeningAProjectImportsExistingTakesAsOBSAssets() throws {        let directory = try makeTempDirectory()
        let file = try writeFile("Plano 01.mkv", in: directory)
        let appState = makeAppState()
        let scene = try XCTUnwrap(appState.project.scenes.first)
        scene.takes = [Take(number: 1, startedAt: Date(), duration: 21, filePath: file.path)]

        appState.syncOBSAssetsFromTakes()

        let asset = try XCTUnwrap(appState.assets.first)
        XCTAssertEqual(appState.assets.count, 1)
        XCTAssertEqual(asset.kind, .obs)
        XCTAssertEqual(asset.duration, 21)
        XCTAssertEqual(asset.linkedSceneIDs, [scene.id])

        // Running it again on every project open must stay idempotent.
        appState.syncOBSAssetsFromTakes()
        XCTAssertEqual(appState.assets.count, 1)
    }

    // MARK: Metadata

    func testMetadataLoaderReadsImageDimensionsAndFileSize() async throws {
        let directory = try makeTempDirectory()
        let url = directory.appendingPathComponent("foto.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 32).fill()
        NSGraphicsContext.restoreGraphicsState()
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: .atomic)

        let metadata = await AssetMetadataLoader.shared.load(path: url.path, bookmarkData: nil)

        XCTAssertEqual(metadata.pixelWidth, 64)
        XCTAssertEqual(metadata.pixelHeight, 32)
        XCTAssertEqual(metadata.byteSize, Int64(png.count))
        XCTAssertNotNil(metadata.modifiedAt)
    }

    // MARK: Format round trip

    func testAssetsSurviveAnFSCRRoundTrip() throws {
        let directory = try makeTempDirectory()
        let file = try writeFile("clip.mov", in: directory)
        let appState = makeAppState()
        let scene = try XCTUnwrap(appState.project.scenes.first)
        let take = Take(number: 1, startedAt: Date(), duration: 8, filePath: file.path)
        scene.takes = [take]
        let asset = try XCTUnwrap(appState.addAsset(at: file, tags: ["plano"]))
        appState.toggleAssetSceneLink(assetID: asset.id, sceneID: scene.id)
        appState.toggleAssetTakeLink(assetID: asset.id, takeID: take.id)
        let projectURL = directory.appendingPathComponent("Proyecto.fscr")

        try FrameScriptFileStore.write(project: appState.project, to: projectURL)
        let loaded = try FrameScriptFileStore.read(from: projectURL)

        let reloaded = try XCTUnwrap(loaded.assets.first)
        XCTAssertEqual(loaded.assets.count, 1)
        XCTAssertEqual(reloaded.id, asset.id)
        XCTAssertEqual(reloaded.path, file.path)
        XCTAssertEqual(reloaded.kind, .camera)
        XCTAssertEqual(reloaded.tags, ["plano"])
        XCTAssertEqual(reloaded.linkedSceneIDs, [scene.id])
        XCTAssertEqual(reloaded.linkedTakeIDs, [take.id])
        XCTAssertNotNil(reloaded.bookmarkData)
    }
}

/// In-memory secret store shared by the asset tests so no Keychain item is read
/// or written.
struct NoopOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}