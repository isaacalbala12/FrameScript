import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// WP1: a take in progress must survive a project change, and an AI run must
/// never mutate a project that replaced the one it analysed.
@MainActor
final class WP1RecordingAndAITests: FrameScriptTestCase {
    // MARK: - Recording guard

    /// Fails before the fix: closing, opening, deleting or restoring finished
    /// the take into the wrong project (or dropped it).
    func testProjectChangesAreRefusedWhileRecording() async throws {
        let urlA = try makeProjectFile(title: "Recording A")
        let urlB = try makeProjectFile(title: "Recording B")
        let scene = Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "one two three")
        let otherScene = Scene(order: 1, sectionType: .cta, title: "CTA", scriptText: "four five six")
        let project = FrameProject(title: "Recording A", scenes: [scene, otherScene])
        let defaults = makeDefaults()
        let client = SuspendedOBSClient()
        let controller = RecordingController(
            client: client,
            preferences: OBSPreferencesStore(defaults: defaults, secretStore: TestOBSSecretStore()),
            defaults: defaults
        )
        controller.countdownEnabled = false
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: urlA, wordsPerMinute: 150, markUnsaved: false)
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = false
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            recording: controller,
            closeConfirmation: { .discard }
        )
        appState.editorState.selectedSceneID = scene.id

        let startTask = Task { await controller.startTake(sceneID: scene.id) }
        for _ in 0..<200 where !controller.hasActiveTake {
            await Task.yield()
        }
        XCTAssertTrue(controller.hasActiveTake, "The fake client must hold the take in .starting")
        XCTAssertEqual(controller.activeSceneID, scene.id)

        XCTAssertFalse(appState.closeProject(), "Closing during a take must be refused")
        XCTAssertTrue(appState.hasOpenProject)
        XCTAssertEqual(appState.project.title, "Recording A")
        XCTAssertEqual(appState.errorCenter.presentedError?.kind, .recordingActive)

        appState.openProject(at: urlB)
        XCTAssertEqual(appState.project.title, "Recording A", "Opening another project must be refused")

        appState.deleteProject()
        XCTAssertTrue(appState.hasOpenProject, "Deleting the project must be refused")
        XCTAssertEqual(appState.project.title, "Recording A")

        appState.deleteSelectedScene()
        XCTAssertEqual(appState.project.scenes.count, 2, "Deleting the recorded scene must be refused")

        let backupEntry = try makeBackupEntry(for: appState)
        XCTAssertEqual(appState.restoreBackup(backupEntry), .cancelled)
        XCTAssertFalse(appState.openBackupAsCopy(backupEntry))
        XCTAssertEqual(appState.project.title, "Recording A")
        XCTAssertTrue(controller.hasActiveTake, "The take must still be running")
        XCTAssertTrue(scene.takes.isEmpty, "No take may be finalised into the old project")

        startTask.cancel()
        _ = await startTask.value
    }

    // MARK: - AI must not mutate the wrong project

    /// Fails before the fix: `analyzeFullScript` kept writing comments into the
    /// project that was open when it started (and touched the new project).
    func testSwitchingProjectDuringFullAnalysisLeavesTheNewProjectUntouched() async throws {
        let urlA = try makeProjectFile(title: "AI A")
        let urlB = try makeProjectFile(title: "AI B")
        let sceneA = Scene(order: 0, sectionType: .hook, title: "A1", scriptText: "alpha beta gamma")
        let sceneA2 = Scene(order: 1, sectionType: .cta, title: "A2", scriptText: "delta epsilon")
        let projectA = FrameProject(title: "AI A", scenes: [sceneA, sceneA2])
        let projectB = makeProject(title: "AI B", text: "untouched text")
        try FrameScriptFileStore.write(project: projectB, to: urlB)

        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = false
        settings.aiPreferences.provider = .t3Code
        let service = SuspendedAnalysisService()
        let dependencies = AppDependencies(
            rewriteService: RewriteService(provider: OpenAICompatibleLLMProvider()),
            analysisService: service,
            exportService: ExportService(),
            llmProvider: OpenAICompatibleLLMProvider(),
            providerCredentials: ProviderCredentialSession()
        )
        let store = ProjectStore(project: projectA)
        store.openProject(projectA, fileURL: urlA, wordsPerMinute: 150, markUnsaved: false)
        let appState = AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: dependencies,
            closeConfirmation: { .discard }
        )
        appState.editorState.selectedSceneID = sceneA.id

        let analysis = Task { await appState.analyzeFullScript() }
        for _ in 0..<400 where service.requestCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(service.requestCount, 1)

        appState.openProject(at: urlB)
        XCTAssertEqual(appState.project.title, "AI B")
        service.resumeAll()
        _ = await analysis.value

        XCTAssertTrue(appState.project.scenes.allSatisfy { $0.aiComments.isEmpty }, "Project B must not receive A's comments")
        XCTAssertTrue(sceneA.aiComments.isEmpty, "The abandoned project must not be mutated either")
        XCTAssertTrue(sceneA2.aiComments.isEmpty)
        XCTAssertFalse(appState.aiState.isAnalyzing)
    }

    // MARK: - Fixtures

    private func makeBackupEntry(for appState: AppState) throws -> BackupEntry {
        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let data = try FrameScriptFileStore.encode(project: appState.project)
        guard case let .created(entry, _) = BackupsCenter.store.backUpData(
            data,
            originalFileName: appState.projectStore.currentFileURL?.lastPathComponent ?? "Project.fscr",
            originalPath: appState.projectStore.currentFileURL?.path,
            projectID: projectID
        ) else {
            throw WP1TestError.backupFailed
        }
        return entry
    }

    private func makeProject(title: String, text: String) -> FrameProject {
        FrameProject(
            title: title,
            scenes: [Scene(order: 0, sectionType: .custom, title: "Scene", scriptText: text)]
        )
    }

    private func makeProjectFile(title: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP1Recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("\(title.replacingOccurrences(of: " ", with: "-")).fscr")
        try FrameScriptFileStore.write(project: makeProject(title: title, text: "text"), to: url)
        return url
    }

    private enum WP1TestError: Error {
        case backupFailed
    }
}

/// Keeps `startTake` suspended in `.starting` so the test can attempt project
/// changes while a take is active.
private actor SuspendedOBSClient: OBSRecordingClient {
    nonisolated var connectionStates: AsyncStream<OBSConnectionState> {
        AsyncStream { $0.finish() }
    }

    nonisolated var events: AsyncStream<OBSEvent> {
        AsyncStream { $0.finish() }
    }

    func currentConnectionState() async -> OBSConnectionState {
        try? await Task.sleep(for: .seconds(30))
        return .disconnected
    }

    func connect(config: OBSConnectionConfig) async throws {}
    func disconnect() async {}
    func getSceneList() async throws -> OBSSceneList {
        OBSSceneList(
            currentProgramSceneName: nil,
            currentProgramSceneUuid: nil,
            currentPreviewSceneName: nil,
            currentPreviewSceneUuid: nil,
            scenes: []
        )
    }
    func setCurrentProgramScene(name: String) async throws {}
    func startRecord() async throws {}
    func stopRecord() async throws -> String { "" }
    func getRecordStatus() async throws -> OBSRecordStatus {
        OBSRecordStatus(
            outputActive: false,
            outputPaused: false,
            outputTimecode: "00:00:00.000",
            outputDuration: 0,
            outputBytes: 0
        )
    }
}

private struct TestOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? { nil }
    func savePassword(_ password: String) throws {}
}

/// Analysis stub that suspends on its first request so the test can switch
/// projects.
@MainActor
private final class SuspendedAnalysisService: AnalysisServicing {
    private(set) var requestCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func analyze(
        scene: Scene,
        project: FrameProject,
        settings: AIPreferences,
        interfaceLanguage: AppLanguage,
        apiKey: String
    ) async throws -> [AIComment] {
        requestCount += 1
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        return [AIComment(sceneID: scene.id, type: "pacing", severity: .note, message: "note", suggestion: "")]
    }

    func resumeAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}
