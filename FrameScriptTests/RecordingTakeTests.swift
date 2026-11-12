import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

@MainActor
final class RecordingTakeTests: XCTestCase {
    // MARK: - Take numbering

    func testTakeNumberingUsesMaxPlusOnePerSceneAndLanguage() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = [
            Take(number: 1, startedAt: date, languageCode: ""),
            Take(number: 2, startedAt: date, languageCode: ""),
            Take(number: 9, startedAt: date, languageCode: "en")
        ]

        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: ""), 3)
        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: "en"), 10)
        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: "es"), 1)
        // Language codes are compared case-insensitively and trimmed.
        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: " EN "), 10)
        XCTAssertEqual(TakeNumbering.nextNumber(existing: [], languageCode: ""), 1)
    }

    func testTakeFactoryBuildsReadTextHashAndDefaults() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let take = TakeFactory.makeTake(
            existing: [Take(number: 4, startedAt: date)],
            sceneText: "Texto leído",
            languageCode: "",
            startedAt: date,
            duration: 42,
            filePath: "/tmp/take.mov"
        )

        XCTAssertEqual(take.number, 5)
        XCTAssertEqual(take.startedAt, date)
        XCTAssertEqual(take.duration, 42)
        XCTAssertEqual(take.filePath, "/tmp/take.mov")
        XCTAssertEqual(take.rating, .unrated)
        XCTAssertEqual(take.readText, "Texto leído")
        XCTAssertEqual(take.sceneTextHash, FrameScriptDocument.TextHash.hash("Texto leído"))
    }

    // MARK: - Recording through the fake OBS protocol

    func testRecordingFlowCreatesTakeAndRatingSurvivesFSCRRoundTrip() async throws {
        let fixture = makeFixture(sceneText: "Hola mundo desde el guion")
        let scene = fixture.scene
        let sceneID = scene.id
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        scene.takes = [
            Take(number: 1, startedAt: start, languageCode: ""),
            Take(number: 2, startedAt: start, languageCode: ""),
            Take(number: 7, startedAt: start, languageCode: "en")
        ]
        fixture.controller.now = { start }

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        XCTAssertEqual(fixture.controller.sceneNames, ["Camara"])

        await fixture.controller.startTake(sceneID: sceneID)
        XCTAssertTrue(fixture.controller.phase.isRecording)
        let startCount = await fixture.client.startCount
        let programScenes = await fixture.client.programScenes
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(programScenes, ["Camara"])

        fixture.controller.now = { start.addingTimeInterval(12) }
        await fixture.controller.stopTake()

        XCTAssertEqual(scene.takes.count, 4)
        let take = try XCTUnwrap(scene.takes.last)
        XCTAssertEqual(take.number, 3)
        XCTAssertEqual(take.startedAt, start)
        XCTAssertEqual(take.duration, 12, accuracy: 0.001)
        XCTAssertEqual(take.filePath, "/tmp/framescript-fake-take.mov")
        XCTAssertEqual(take.readText, "Hola mundo desde el guion")
        XCTAssertEqual(take.sceneTextHash, FrameScriptDocument.TextHash.hash("Hola mundo desde el guion"))
        XCTAssertEqual(take.rating, .unrated)
        XCTAssertEqual(take.languageCode, "")
        XCTAssertEqual(fixture.changes.count, 1)

        fixture.controller.setRating(.good, takeID: take.id, sceneID: sceneID)
        fixture.controller.setNote("Buena entonación", takeID: take.id, sceneID: sceneID)
        XCTAssertEqual(scene.takes.last?.rating, .good)

        let project = FrameProject(title: "Takes", scenes: [scene])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTakeTests-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        let loadedTake = try XCTUnwrap(loaded.scenes.first?.takes.last)

        XCTAssertEqual(loadedTake.id, take.id)
        XCTAssertEqual(loadedTake.number, 3)
        XCTAssertEqual(loadedTake.rating, .good)
        XCTAssertEqual(loadedTake.note, "Buena entonación")
        XCTAssertEqual(loadedTake.readText, "Hola mundo desde el guion")
        XCTAssertEqual(loadedTake.sceneTextHash, take.sceneTextHash)
        XCTAssertEqual(loadedTake.duration, 12, accuracy: 0.001)
        XCTAssertEqual(loadedTake.filePath, take.filePath)
    }

    func testDisconnectDuringTakeSavesInterruptedTakeWithKnownInfo() async {
        let fixture = makeFixture(sceneText: "Texto de la toma interrumpida")
        let scene = fixture.scene
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: scene.id)
        XCTAssertTrue(fixture.controller.phase.isRecording)

        fixture.controller.now = { start.addingTimeInterval(5) }
        fixture.controller.handleConnectionState(.disconnected)

        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(scene.takes.count, 1)
        let take = scene.takes[0]
        XCTAssertEqual(take.duration, 5, accuracy: 0.001)
        XCTAssertEqual(take.readText, "Texto de la toma interrumpida")
        XCTAssertTrue(take.filePath.isEmpty)
        XCTAssertTrue(take.note.hasPrefix(RecordingController.interruptedNoteMarker))
        XCTAssertEqual(take.rating, .unrated)
        XCTAssertEqual(fixture.controller.lastIssue, .connectionLost)
    }

    func testStopFailureStillClosesOutAnInterruptedTake() async {
        let fixture = makeFixture(sceneText: "Fallo al parar")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }
        await fixture.client.setStopFailure(.notConnected)

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: fixture.scene.id)
        fixture.controller.now = { start.addingTimeInterval(3) }
        await fixture.controller.stopTake()

        XCTAssertEqual(fixture.scene.takes.count, 1)
        XCTAssertTrue(fixture.scene.takes[0].note.hasPrefix(RecordingController.interruptedNoteMarker))
        XCTAssertEqual(fixture.scene.takes[0].duration, 3, accuracy: 0.001)
    }

    func testManualTakeUsesNextNumberAndKeepsSelectedFile() {
        let fixture = makeFixture(sceneText: "Texto manual")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.scene.takes = [Take(number: 4, startedAt: date)]

        let added = fixture.controller.addManualTake(
            sceneID: fixture.scene.id,
            startedAt: date,
            duration: 90,
            fileURL: URL(fileURLWithPath: "/tmp/manual.mov"),
            note: "Rodada sin OBS"
        )

        XCTAssertTrue(added)
        let take = fixture.scene.takes.last
        XCTAssertEqual(take?.number, 5)
        XCTAssertEqual(take?.duration, 90)
        XCTAssertEqual(take?.filePath, "/tmp/manual.mov")
        XCTAssertEqual(take?.note, "Rodada sin OBS")
        XCTAssertEqual(take?.readText, "Texto manual")
        XCTAssertEqual(fixture.changes.count, 1)
    }

    func testLanguageTakeUsesVariantTextAndItsOwnNumbering() async throws {
        let fixture = makeFixture(sceneText: "Texto original")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }
        fixture.scene.languageVariants = [SceneLanguageVariant(
            languageCode: "en",
            text: "English read text",
            takes: [Take(number: 5, startedAt: start, languageCode: "en")]
        )]

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: fixture.scene.id, languageCode: "en")
        fixture.controller.now = { start.addingTimeInterval(4) }
        await fixture.controller.stopTake()

        XCTAssertEqual(fixture.scene.takes.count, 0)
        XCTAssertEqual(fixture.scene.languageVariants.first?.takes.count, 2)
        let take = try XCTUnwrap(fixture.scene.languageVariants.first?.takes.last)
        XCTAssertEqual(take.number, 6)
        XCTAssertEqual(take.languageCode, "en")
        XCTAssertEqual(take.readText, "English read text")
        XCTAssertEqual(take.duration, 4, accuracy: 0.001)
    }

    func testAutoConnectOnlyRunsWhenEnabled() async {
        let fixture = makeFixture(sceneText: "Auto")
        fixture.controller.preferences.autoConnect = false
        await fixture.controller.connectAutomaticallyIfNeeded()
        XCTAssertFalse(fixture.controller.connectionState.isConnected)

        fixture.controller.preferences.autoConnect = true
        await fixture.controller.connectAutomaticallyIfNeeded()
        XCTAssertTrue(fixture.controller.connectionState.isConnected)
        let state = await fixture.client.currentConnectionState()
        XCTAssertTrue(state.isConnected)
    }

    func testDeletingTakeRemovesEntryButNeverTheVideoFile() throws {
        let fixture = makeFixture(sceneText: "Borrar")
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTakeTests-\(UUID().uuidString).mov")
        try Data("video".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertTrue(fixture.controller.addManualTake(
            sceneID: fixture.scene.id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 10,
            fileURL: fileURL,
            note: ""
        ))
        let takeID = try XCTUnwrap(fixture.scene.takes.first?.id)

        fixture.controller.deleteTake(takeID: takeID, sceneID: fixture.scene.id)

        XCTAssertTrue(fixture.scene.takes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEveryRecordingStringExistsInEnglishSpanishAndRussian() {
        let english = L10n.recordingStrings[.english] ?? [:]
        let spanish = L10n.recordingStrings[.spanish] ?? [:]
        let russian = L10n.recordingStrings[.russian] ?? [:]

        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
    }

    // MARK: - Spanish connection messages

    func testConnectionIssuesExplainTheFixInSpanish() {
        let notRunning = RecordingIssue.obsNotRunning(host: "localhost", port: 4455)
        let notRunningMessage = notRunning.message(language: .spanish)
        XCTAssertTrue(notRunningMessage.contains("No se pudo conectar con OBS"))
        XCTAssertTrue(notRunningMessage.contains("localhost:4455"))
        let hint = notRunning.recoveryHint(language: .spanish)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("WebSocket") == true)

        let password = RecordingIssue.authenticationFailed.message(language: .spanish)
        XCTAssertTrue(password.contains("contraseña"))
        XCTAssertTrue(RecordingIssue.authenticationFailed.recoveryHint(language: .spanish)?.contains("Herramientas") == true)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let client: FakeOBSClient
        let controller: RecordingController
        let scene: Scene
        let changes: ChangeCounter
    }

    private final class ChangeCounter: @unchecked Sendable {
        var count = 0
    }

    private func makeFixture(sceneText: String) -> Fixture {
        let suiteName = "RecordingTakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = OBSPreferencesStore(defaults: defaults, loadPassword: false)
        let client = FakeOBSClient()
        let controller = RecordingController(
            client: client,
            preferences: preferences,
            defaults: defaults
        )
        // Tests exercise the direct start path; the countdown has its own state.
        controller.countdownEnabled = false
        let changes = ChangeCounter()
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Hook",
            scriptText: sceneText,
            obsSceneName: "Camara"
        )
        let sceneID = scene.id
        controller.attach(RecordingController.Gateway(
            scene: { id in id == sceneID ? scene : nil },
            markProjectChanged: { changes.count += 1 },
            language: { .spanish }
        ))
        return Fixture(client: client, controller: controller, scene: scene, changes: changes)
    }
}

/// An in-memory `OBSRecordingClient` so take logic is tested without a socket
/// or a running OBS.
private actor FakeOBSClient: OBSRecordingClient {
    private(set) var state: OBSConnectionState = .disconnected
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var programScenes: [String] = []
    private var startFailure: OBSError?
    private var stopFailure: OBSError?
    private var connectFailure: OBSError?
    var outputPath = "/tmp/framescript-fake-take.mov"
    var sceneList = OBSSceneList(
        currentProgramSceneName: "Camara",
        currentProgramSceneUuid: nil,
        currentPreviewSceneName: nil,
        currentPreviewSceneUuid: nil,
        scenes: [OBSScene(name: "Camara", index: 0, uuid: nil)]
    )

    nonisolated var connectionStates: AsyncStream<OBSConnectionState> {
        AsyncStream { $0.finish() }
    }

    nonisolated var events: AsyncStream<OBSEvent> {
        AsyncStream { $0.finish() }
    }

    func setStartFailure(_ error: OBSError?) { startFailure = error }
    func setStopFailure(_ error: OBSError?) { stopFailure = error }
    func setConnectFailure(_ error: OBSError?) { connectFailure = error }

    func currentConnectionState() async -> OBSConnectionState { state }

    func connect(config: OBSConnectionConfig) async throws {
        if let connectFailure { throw connectFailure }
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

    func getSceneList() async throws -> OBSSceneList { sceneList }

    func setCurrentProgramScene(name: String) async throws {
        programScenes.append(name)
    }

    func startRecord() async throws {
        if let startFailure { throw startFailure }
        startCount += 1
    }

    func stopRecord() async throws -> String {
        if let stopFailure { throw stopFailure }
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
}
