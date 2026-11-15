import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class WP9SaveSafetyTests: FrameScriptTestCase {
    private func dir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("WP9Verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    private func bigProject(_ n: Int = 60) -> FrameProject {
        let words = "cuando la ciudad despierta cada mañana los vecinos caminan hacia el mercado con sus bolsas de tela. "
        let scenes = (0..<n).map { i in
            Scene(order: i, sectionType: .custom, title: "S\(i)", scriptText: String(repeating: words, count: 40))
        }
        return FrameProject(title: "Verify", scenes: scenes, primaryLanguage: "es")
    }

    private var closePrompts = 0
    private var externalPrompts = 0

    private func makeAppState() -> AppState {
        let suite = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = true
        settings.generalPreferences.autosaveIntervalSeconds = 3_600
        return AppState(
            projectStore: ProjectStore(project: SampleData.defaultProject),
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: { [unowned self] in self.closePrompts += 1; return .discard },
            externalChangeConfirmation: { [unowned self] in self.externalPrompts += 1; return .keepMine }
        )
    }

    private func open(_ project: FrameProject) throws -> (AppState, URL) {
        let url = try dir().appendingPathComponent("P.fscr")
        try FrameScriptFileStore.write(project: project, to: url)
        let app = makeAppState()
        app.openProject(at: url)
        return (app, url)
    }

    /// Cmd+S while a background autosave is in flight: the late completion
    /// must not replace the baseline with the older bytes.
    func testReproManualSaveDuringAutosaveKeepsBaselineInSyncWithDisk() async throws {
        let (app, url) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " uno.")
        app.performAutosave()
        XCTAssertTrue(app.projectStore.hasPendingBackgroundWrite)
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " dos.")
        XCTAssertTrue(app.saveProject())
        let diskAfterSave = ProjectFileSnapshotReader.hash(of: try Data(contentsOf: url))
        print("VERIFY after save: baseline==disk", app.trackedProjectFileSnapshot?.contentHash == diskAfterSave, "dirty", app.projectStore.hasUnsavedFileChanges)
        for _ in 0..<50 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        let disk = ProjectFileSnapshotReader.hash(of: try Data(contentsOf: url))
        print("VERIFY after completion: baseline==disk", app.trackedProjectFileSnapshot?.contentHash == disk, "dirty", app.projectStore.hasUnsavedFileChanges, "lastSaved==disk", app.projectStore.lastSavedFileData.map { ProjectFileSnapshotReader.hash(of: $0) } == disk)
        XCTAssertEqual(app.trackedProjectFileSnapshot?.contentHash, disk, "baseline must match disk after Cmd+S")
        XCTAssertFalse(app.projectStore.hasUnsavedFileChanges, "Cmd+S saved everything")
        // Next edit + autosave must not raise a false external-change prompt.
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " tres.")
        app.flushActiveEditorBoundary(saveImmediately: false)
        app.performAutosave()
        for _ in 0..<50 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(externalPrompts, 0, "own write reported as external change")
    }

    /// Closing a dirty project with autosave enabled did not prompt in base
    /// (synchronous autosave cleared the flag first).
    func testReproCloseWithAutosaveDoesNotPrompt() throws {
        let (app, _) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " cierre.")
        app.flushActiveEditorBoundary(saveImmediately: false)
        XCTAssertTrue(app.closeProject())
        XCTAssertEqual(closePrompts, 0, "autosave-enabled close prompted Save/Don't Save")
    }

    /// A re-segmentation (markUnsaved) during the write does not bump the
    /// content revision, so completion clears the dirty flag.
    func testReproResegmentDuringWriteStaysDirty() async throws {
        let (app, _) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " seg.")
        app.performAutosave()
        XCTAssertTrue(app.projectStore.hasPendingBackgroundWrite)
        app.projectStore.synchronizeTextSegments(splitMode: .paragraph, wordsPerMinute: 150, markUnsaved: true)
        XCTAssertTrue(app.projectStore.hasUnsavedFileChanges)
        _ = try await waitUntil("write", timeout: .seconds(15)) { !app.projectStore.hasPendingBackgroundWrite }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(app.projectStore.hasUnsavedFileChanges, "segment change after snapshot marked saved")
    }

    /// Base recomputed estimates on open/save; a stale but plausible stored
    /// estimate now survives open and save.
    func testReproStaleStoredEstimateIsRefreshed() throws {
        let p = bigProject(4)
        for s in p.scenes { s.estimatedDuration = 999 }
        let (app, url) = try open(p)
        XCTAssertNotEqual(app.project.scenes.sortedByOrder.last?.estimatedDuration, 999, "open kept stale estimate")
        let first = try XCTUnwrap(app.project.scenes.sortedByOrder.first)
        app.commitScriptTextChange(sceneID: first.id, text: first.scriptText + " x.")
        XCTAssertTrue(app.saveProject())
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertNotEqual(saved.scenes.sortedByOrder.last?.estimatedDuration, 999, "save kept stale estimate")
    }
}

// MARK: - Lifecycle drains beyond the verifier repros

extension WP9SaveSafetyTests {
    /// Quitting with "Don't Save" while an autosave is still running must wait
    /// for that write before terminating.
    func testQuitWithDiscardSettlesThePendingWrite() async throws {
        let (app, url) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        let firstText = scene.scriptText + " uno."
        app.commitScriptTextChange(sceneID: scene.id, text: firstText)
        app.performAutosave()
        XCTAssertTrue(app.projectStore.hasPendingBackgroundWrite)
        app.commitScriptTextChange(sceneID: scene.id, text: firstText + " dos.")

        XCTAssertTrue(app.confirmApplicationTermination())
        XCTAssertEqual(closePrompts, 1, "the newer edit still needs a Save/Don't Save decision")
        XCTAssertFalse(app.projectStore.hasPendingBackgroundWrite, "quit returned with a write in flight")
        let saved = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(saved.scenes.first(where: { $0.id == scene.id })?.scriptText, firstText)
        XCTAssertTrue(app.projectStore.hasUnsavedFileChanges, "the discarded edit stays only in memory")
    }

    /// Opening another project while dirty with autosave enabled must settle
    /// the write instead of prompting on every open.
    func testOpeningAnotherProjectWithAutosaveDoesNotPrompt() throws {
        let (app, _) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        app.commitScriptTextChange(sceneID: scene.id, text: scene.scriptText + " otro.")
        app.flushActiveEditorBoundary(saveImmediately: false)

        let secondURL = try dir().appendingPathComponent("Second.fscr")
        try FrameScriptFileStore.write(
            project: FrameProject(
                title: "Second",
                scenes: [Scene(order: 0, sectionType: .hook, title: "S", scriptText: "Dos.")],
                primaryLanguage: "es"
            ),
            to: secondURL
        )
        app.openProject(at: secondURL)

        XCTAssertEqual(closePrompts, 0, "autosave-enabled open prompted Save/Don't Save")
        XCTAssertEqual(app.project.title, "Second")
    }

    /// Close and reopen the same file while its autosave is still running: the
    /// reopened document must be the bytes that were written, not the old file.
    func testReopeningTheSameFileDuringAWriteDoesNotDiverge() throws {
        let (app, url) = try open(bigProject())
        let scene = try XCTUnwrap(app.project.scenes.first)
        let newText = scene.scriptText + " reabrir."
        app.commitScriptTextChange(sceneID: scene.id, text: newText)
        app.performAutosave()
        XCTAssertTrue(app.projectStore.hasPendingBackgroundWrite)

        XCTAssertTrue(app.closeProject())
        XCTAssertEqual(closePrompts, 0, "the pending write already contains every edit")
        XCTAssertFalse(app.projectStore.hasPendingBackgroundWrite)

        app.openProject(at: url)
        XCTAssertEqual(app.project.scenes.first(where: { $0.id == scene.id })?.scriptText, newText)
        XCTAssertFalse(app.projectStore.hasUnsavedFileChanges)
    }
}
