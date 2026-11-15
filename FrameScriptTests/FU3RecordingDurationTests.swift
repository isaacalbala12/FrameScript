import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// FU3 fix-up regressions for WP3/WP4: the OBS stopped latch with the
/// countdown enabled, the toolbar teleprompter's pause defaults, the duration
/// revision hash and the escaleta export timings/tables.
@MainActor
final class FU3RecordingDurationTests: FrameScriptTestCase {
    // MARK: - WP3 #9: the stopped latch also works with the countdown on

    /// The countdown is on by default. During `startRecord()` the phase must be
    /// `.starting`; otherwise OBS's STOPPED event is ignored and the take starts
    /// anyway.
    func testStoppedEventDuringStartAbortsTheStartWithTheCountdownEnabled() async {
        let fixture = makeFixture(sceneText: "Hola", countdownEnabled: true)
        await fixture.controller.connect()
        await fixture.client.setStartDelay(300_000_000)

        await fixture.controller.startTake(sceneID: fixture.scene.id)
        // The 3 s countdown runs before StartRecord, so allow more than the
        // default timeout.
        await waitUntil(timeout: .seconds(8)) { await fixture.client.isStartInFlight }
        XCTAssertEqual(
            fixture.controller.phase, .starting,
            "StartRecord must run in .starting even when a countdown preceded it"
        )

        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: nil
        )))
        // With the countdown on, `startTake` returns as soon as the countdown is
        // scheduled, so wait for the in-flight start to settle.
        await waitUntil(timeout: .seconds(5)) { fixture.controller.phase == .idle }

        XCTAssertEqual(fixture.controller.phase, .idle)
        guard case .startFailed(let detail)? = fixture.controller.lastIssue else {
            return XCTFail("Expected a start failure, got \(String(describing: fixture.controller.lastIssue))")
        }
        XCTAssertEqual(
            detail,
            L10n.tr("recording.error.stoppedDuringStart", language: .spanish)
        )
        let startCount = await fixture.client.startCount
        XCTAssertGreaterThanOrEqual(startCount, 1)
    }

    // MARK: - WP3 #10: the toolbar teleprompter honours the configured pauses

    func testToolbarTeleprompterUsesTheConfiguredPauseDefaults() throws {
        var settings = AppSettings.defaults
        settings.editorPreferences.shortPauseSeconds = 2
        settings.editorPreferences.longPauseSeconds = 3
        settings.generalPreferences.autosaveEnabled = false

        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Escena",
            scriptText: "uno / dos // tres"
        )
        let appState = makeAppState(
            project: FrameProject(title: "Pausas", scenes: [scene], primaryLanguage: "es"),
            settings: settings
        )

        let presenter = TeleprompterPresenter.shared
        presenter.close()
        let previousHandler = presenter.presentHandler
        presenter.presentHandler = { _ in }
        addTeardownBlock {
            presenter.close()
            presenter.presentHandler = previousHandler
        }

        appState.presentTeleprompter()
        let opened = try XCTUnwrap(presenter.activeModel)
        XCTAssertEqual(
            pauseValues(in: opened), [2, 3],
            "A brand-new teleprompter must open with the configured pauses"
        )

        // Reusing the window used to keep the standard pauses for the whole
        // session, because `updateContent` snapshots the provider.
        appState.presentTeleprompter()
        let reused = try XCTUnwrap(presenter.activeModel)
        XCTAssertEqual(
            pauseValues(in: reused), [2, 3],
            "A reused teleprompter must still use the configured pauses"
        )
    }

    // MARK: - WP3 #11: durationRevision covers structural edits

    func testDurationRevisionChangesWhenTheSelectedSceneIsDeleted() {
        var settings = AppSettings.defaults
        settings.generalPreferences.confirmBeforeDeleting = false
        settings.generalPreferences.autosaveEnabled = false
        let first = Scene(order: 0, sectionType: .hook, title: "Uno", scriptText: "uno dos")
        let second = Scene(order: 1, sectionType: .explanation, title: "Dos", scriptText: "tres cuatro")
        let appState = makeAppState(
            project: FrameProject(title: "Borrado", scenes: [first, second], primaryLanguage: "es"),
            settings: settings
        )
        appState.editorState.selectedSceneID = second.id

        let before = appState.durationRevision
        appState.deleteSelectedScene()

        XCTAssertEqual(appState.project.scenes.count, 1)
        XCTAssertNotEqual(
            appState.durationRevision, before,
            "Deleting a scene must invalidate the learned-duration revision"
        )
    }

    func testDurationRevisionChangesWhenASceneIsDuplicated() {
        let scene = Scene(order: 0, sectionType: .hook, title: "Uno", scriptText: "uno dos")
        let appState = makeAppState(
            project: FrameProject(title: "Duplicado", scenes: [scene], primaryLanguage: "es")
        )
        appState.editorState.selectedSceneID = scene.id

        let before = appState.durationRevision
        appState.duplicateSelectedScene()

        XCTAssertEqual(appState.project.scenes.count, 2)
        XCTAssertNotEqual(
            appState.durationRevision, before,
            "Duplicating a scene must invalidate the learned-duration revision"
        )
    }

    func testDurationRevisionChangesWhenAVariantTextIsEdited() {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Uno",
            scriptText: "uno dos",
            languageVariants: [
                SceneLanguageVariant(languageCode: "en", text: "one two", sourceHash: "", takes: [])
            ]
        )
        let appState = makeAppState(
            project: FrameProject(title: "Variantes", scenes: [scene], primaryLanguage: "es")
        )

        let before = appState.durationRevision
        scene.languageVariants[0].text += " three"

        XCTAssertNotEqual(
            appState.durationRevision, before,
            "A variant edit must invalidate the learned-duration revision"
        )
    }

    func testDurationRevisionChangesWhenATakeIsImported() {
        let scene = Scene(order: 0, sectionType: .hook, title: "Uno", scriptText: "uno dos")
        let appState = makeAppState(
            project: FrameProject(title: "Tomas", scenes: [scene], primaryLanguage: "es")
        )

        let before = appState.durationRevision
        // Importers (project files, backups, manual take sheets) attach takes
        // to the model directly instead of going through the recording
        // controller, which is what used to bump the counter.
        scene.takes.append(
            Take(
                number: 1,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: 12,
                rating: .good,
                languageCode: "es",
                readText: "uno dos"
            )
        )

        XCTAssertNotEqual(
            appState.durationRevision, before,
            "Imported takes must invalidate the learned-duration revision"
        )
    }

    /// Guards the other side: the same project must not report a new revision
    /// on every read, or the toolbar would re-learn on every body evaluation.
    func testDurationRevisionIsStableWithoutEdits() {
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Uno",
            scriptText: "uno dos",
            languageVariants: [
                SceneLanguageVariant(languageCode: "en", text: "one two", sourceHash: "", takes: [])
            ]
        )
        let appState = makeAppState(
            project: FrameProject(title: "Estable", scenes: [scene], primaryLanguage: "es")
        )

        XCTAssertEqual(appState.durationRevision, appState.durationRevision)
    }

    // MARK: - Helpers

    private func pauseValues(in model: TeleprompterModel) -> [TimeInterval] {
        model.sections.flatMap { section in
            section.runs.compactMap { run in
                guard case .pause(let seconds) = run else { return nil }
                return seconds
            }
        }
    }

    private func makeAppState(
        project: FrameProject,
        settings: AppSettings = .defaults
    ) -> AppState {
        let suite = makeDefaults()
        var settings = settings
        settings.generalPreferences.autosaveEnabled = false
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings")
        )
    }

    private final class SceneBox {
        var scene: Scene?

        init(_ scene: Scene?) {
            self.scene = scene
        }
    }

    private struct Fixture {
        let client: FU3FakeOBSClient
        let controller: RecordingController
        let scene: Scene
    }

    private func makeFixture(sceneText: String, countdownEnabled: Bool) -> Fixture {
        let defaults = makeDefaults()
        let preferences = OBSPreferencesStore(
            defaults: defaults,
            secretStore: FU3FakeSecretStore()
        )
        let client = FU3FakeOBSClient()
        let controller = RecordingController(
            client: client,
            preferences: preferences,
            defaults: defaults
        )
        controller.countdownEnabled = countdownEnabled

        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Hook",
            scriptText: sceneText,
            obsSceneName: "Camara"
        )
        let box = SceneBox(scene)
        controller.attach(RecordingController.Gateway(
            scene: { id in
                guard let scene = box.scene, scene.id == id else { return nil }
                return scene
            },
            markProjectChanged: {},
            language: { .spanish }
        ))
        return Fixture(client: client, controller: controller, scene: scene)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        while !(await condition()) {
            guard clock.now - start < timeout else {
                XCTFail("Timed out waiting for condition")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - Test doubles

private actor FU3FakeOBSClient: OBSRecordingClient, OBSRecordingClientShutdown {
    private(set) var state: OBSConnectionState = .disconnected
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isStartInFlight = false

    nonisolated let outputPath = "/tmp/framescript-fu3-fake-take.mov"

    private var startDelayNanos: UInt64?

    nonisolated var connectionStates: AsyncStream<OBSConnectionState> {
        AsyncStream { $0.finish() }
    }

    nonisolated var events: AsyncStream<OBSEvent> {
        AsyncStream { $0.finish() }
    }

    func setStartDelay(_ nanos: UInt64?) {
        startDelayNanos = nanos
    }

    func currentConnectionState() async -> OBSConnectionState {
        state
    }

    func connect(config: OBSConnectionConfig) async throws {
        state = .connected(OBSSessionInfo(
            obsStudioVersion: "30.0.0",
            obsWebSocketVersion: "5.5.0",
            rpcVersion: 1,
            negotiatedRpcVersion: 1
        ))
    }

    func disconnect() async {
        state = .disconnected
    }

    func getSceneList() async throws -> OBSSceneList {
        OBSSceneList(
            currentProgramSceneName: "Camara",
            currentProgramSceneUuid: nil,
            currentPreviewSceneName: nil,
            currentPreviewSceneUuid: nil,
            scenes: [OBSScene(name: "Camara", index: 0, uuid: nil)]
        )
    }

    func setCurrentProgramScene(name: String) async throws {}

    func startRecord() async throws {
        isStartInFlight = true
        defer { isStartInFlight = false }
        if let startDelayNanos {
            try? await Task.sleep(nanoseconds: startDelayNanos)
        }
        startCount += 1
    }

    func stopRecord() async throws -> String {
        stopCount += 1
        return outputPath
    }

    func getRecordStatus() async throws -> OBSRecordStatus {
        OBSRecordStatus(
            outputActive: startCount > stopCount,
            outputPaused: false,
            outputTimecode: "",
            outputDuration: 0,
            outputBytes: 0
        )
    }

    func shutdown() async {
        state = .disconnected
    }
}

private final class FU3FakeSecretStore: OBSSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    func readPassword() throws -> String? {
        lock.withLock { password }
    }

    func savePassword(_ password: String) throws {
        lock.withLock { self.password = password }
    }
}
