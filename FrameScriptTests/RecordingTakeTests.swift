import Foundation
import FrameScriptCore
import Security
import UniformTypeIdentifiers
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
        let note = fixture.scene.takes[0].note
        XCTAssertTrue(note.hasPrefix(RecordingController.interruptedNoteMarker))
        XCTAssertEqual(note.components(separatedBy: RecordingController.interruptedNoteMarker).count - 1, 1)
        XCTAssertFalse(note.contains("No se pudo detener"))
        XCTAssertEqual(fixture.scene.takes[0].duration, 3, accuracy: 0.001)
    }

    func testConcurrentStartCommandsOnlyStartOBSOnce() async {
        let fixture = makeFixture(sceneText: "Concurrente")
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.client.setStateCheckDelay(50_000_000)

        let controller = fixture.controller
        let sceneID = fixture.scene.id
        let first = Task { @MainActor in
            await controller.startTake(sceneID: sceneID)
        }
        let second = Task { @MainActor in
            await controller.startTake(sceneID: sceneID)
        }
        await first.value
        await second.value

        let startCount = await fixture.client.startCount
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(fixture.controller.phase.isRecording)
        await fixture.controller.stopTake()
    }

    func testStopRequestedWhileStartingIsHonoured() async {
        let fixture = makeFixture(sceneText: "Parar durante el arranque")
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.client.setStartDelay(120_000_000)

        let startTask = Task { await fixture.controller.startTake(sceneID: fixture.scene.id) }
        await waitForStartInFlight(fixture.client)
        XCTAssertEqual(fixture.controller.phase, .starting)

        await fixture.controller.stopTake()
        await startTask.value

        let stopCount = await fixture.client.stopCount
        let startCount = await fixture.client.startCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.scene.takes.count, 1)
    }

    func testQuitDuringStartingStopsOBSAndFinalizesTheTakeBeforeSave() async throws {
        let fixture = makeFixture(sceneText: "Salir arrancando")
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.client.setStartDelay(120_000_000)

        let startTask = Task { await fixture.controller.startTake(sceneID: fixture.scene.id) }
        await waitForStartInFlight(fixture.client)
        await fixture.controller.prepareForTermination()
        await startTask.value

        let startCount = await fixture.client.startCount
        let stopCount = await fixture.client.stopCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.scene.takes.count, 1)
        XCTAssertFalse(fixture.scene.takes[0].note.hasPrefix(RecordingController.interruptedNoteMarker))

        let project = FrameProject(title: "Quit", scenes: [fixture.scene])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTakeTests-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }
        try FrameScriptFileStore.write(project: project, to: url)
        let loaded = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(loaded.scenes.first?.takes.count, 1)
    }

    func testTerminationHelperFinalizesTheTakeBeforeSavingTheProject() async throws {
        let fixture = makeFixture(sceneText: "Cierre con guardado")
        let project = FrameProject(title: "Termination", scenes: [fixture.scene])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTakeTests-\(UUID().uuidString).fscr")
        defer { try? FileManager.default.removeItem(at: url) }
        let appState = AppState(
            recording: fixture.controller,
            closeConfirmation: { .save }
        )
        appState.projectStore.openProject(project, fileURL: url, wordsPerMinute: 120, markUnsaved: false)

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: fixture.scene.id)
        fixture.controller.now = { Date().addingTimeInterval(5) }

        let delegate = FrameScriptAppDelegate()
        let shouldTerminate = await delegate.terminationShouldProceed(appState: appState)
        XCTAssertTrue(shouldTerminate)

        let loaded = try FrameScriptFileStore.read(from: url)
        XCTAssertEqual(loaded.scenes.first?.takes.count, 1)
        XCTAssertEqual(loaded.scenes.first?.takes.first?.readText, "Cierre con guardado")
    }

    func testStaleStartTokenNeverStopsOBSOnQuit() async {
        let fixture = makeFixture(sceneText: "Token obsoleto")
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.client.setStartDelay(120_000_000)

        let startTask = Task { await fixture.controller.startTake(sceneID: fixture.scene.id) }
        await waitForStartInFlight(fixture.client)
        // Invalidate the attempt before StartRecord resolves.
        fixture.controller.handleConnectionState(.disconnected)
        await fixture.controller.prepareForTermination()
        await startTask.value

        let startCount = await fixture.client.startCount
        let stopCount = await fixture.client.stopCount
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(fixture.controller.phase, .idle)
    }

    func testReconnectAdoptsOBSRecordingInsteadOfDuplicatingTheTake() async throws {
        let fixture = makeFixture(sceneText: "Reconexión")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: fixture.scene.id)
        fixture.controller.now = { start.addingTimeInterval(10) }
        fixture.controller.handleConnectionState(.disconnected)
        XCTAssertEqual(fixture.scene.takes.count, 1)
        XCTAssertTrue(fixture.scene.takes[0].filePath.isEmpty)

        await fixture.client.setRecordStatus(outputDuration: 30)
        fixture.controller.now = { start.addingTimeInterval(40) }
        let reconnected = await fixture.controller.connect()
        XCTAssertTrue(reconnected)
        let statusCount = await fixture.client.getRecordStatusCount
        XCTAssertGreaterThan(statusCount, 0)
        XCTAssertTrue(fixture.controller.phase.isRecording)

        await fixture.controller.stopTake()
        XCTAssertEqual(fixture.scene.takes.count, 1)
        let take = try XCTUnwrap(fixture.scene.takes.first)
        XCTAssertEqual(take.filePath, "/tmp/framescript-fake-take.mov")
        XCTAssertEqual(take.duration, 30, accuracy: 0.001)
        XCTAssertFalse(take.note.hasPrefix(RecordingController.interruptedNoteMarker))
    }

    func testConnectWithUnownedExternalRecordingNeverStopsIt() async {
        let fixture = makeFixture(sceneText: "Externa")
        await fixture.client.setRecordStatus(outputActive: true, outputDuration: 20)
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)

        let stopCount = await fixture.client.stopCount
        let startCount = await fixture.client.startCount
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(startCount, 0)
        XCTAssertTrue(fixture.controller.externalRecordingActive)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertTrue(fixture.controller.connectionState.isConnected)

        await fixture.controller.startTake(sceneID: fixture.scene.id)
        let startsAfterRefusal = await fixture.client.startCount
        XCTAssertEqual(startsAfterRefusal, 0)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.controller.lastIssue, .externalRecordingActive)

        await fixture.controller.prepareForTermination()
        let stopsAfterQuit = await fixture.client.stopCount
        XCTAssertEqual(stopsAfterQuit, 0)
    }

    func testExternalStopAndInactiveStatusClearTheExternalRecordingFlag() async {
        let fixture = makeFixture(sceneText: "Externa fin")
        await fixture.client.setRecordStatus(outputActive: true, outputDuration: 20)
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        XCTAssertTrue(fixture.controller.externalRecordingActive)

        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: nil
        )))
        XCTAssertFalse(fixture.controller.externalRecordingActive)

        await fixture.client.setRecordStatus(outputActive: true, outputDuration: 5)
        await fixture.controller.connect()
        XCTAssertTrue(fixture.controller.externalRecordingActive)
        await fixture.client.setRecordStatus(outputActive: false, outputDuration: 0)
        await fixture.controller.connect()
        XCTAssertFalse(fixture.controller.externalRecordingActive)
        let stopCount = await fixture.client.stopCount
        XCTAssertEqual(stopCount, 0)
    }

    func testTestConnectionUsesASeparateClientAndLeavesTheLiveSessionAlone() async {
        let live = FakeOBSClient()
        let probe = FakeOBSClient()
        let suiteName = "RecordingTakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = OBSPreferencesStore(defaults: defaults, secretStore: FakeOBSSecretStore())
        let controller = RecordingController(
            client: live,
            clientFactory: { probe },
            preferences: preferences,
            defaults: defaults
        )
        controller.countdownEnabled = false
        let scene = Scene(
            order: 0,
            sectionType: .hook,
            title: "Hook",
            scriptText: "Prueba"
        )
        let sceneID = scene.id
        controller.attach(RecordingController.Gateway(
            scene: { id in id == sceneID ? scene : nil },
            markProjectChanged: {},
            language: { .spanish }
        ))

        let connected = await controller.connect()
        XCTAssertTrue(connected)
        let succeeded = await controller.testConnection(host: "localhost", port: 4455, password: "")
        XCTAssertTrue(succeeded)

        let liveConnects = await live.connectCount
        let probeConnects = await probe.connectCount
        let liveDisconnects = await live.disconnectCount
        XCTAssertEqual(liveConnects, 1)
        XCTAssertEqual(probeConnects, 1)
        XCTAssertEqual(liveDisconnects, 0)
        XCTAssertTrue(controller.connectionState.isConnected)
    }

    func testExternalStopWithoutPathFallsBackToLastKnownPathAndStatusDuration() async throws {
        let fixture = makeFixture(sceneText: "Parada externa")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        await fixture.controller.startTake(sceneID: fixture.scene.id)
        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: true,
            outputState: .started,
            outputPath: "/tmp/known-from-event.mov"
        )))
        await fixture.client.setRecordStatus(outputDuration: 7)

        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: nil
        )))

        let take = try XCTUnwrap(fixture.scene.takes.first)
        XCTAssertEqual(take.filePath, "/tmp/known-from-event.mov")
        XCTAssertEqual(take.duration, 7, accuracy: 0.001)
    }

    func testMenuShortcutRecordsTheSelectedLanguageVariant() async throws {
        let fixture = makeFixture(sceneText: "Texto original")
        fixture.scene.languageVariants = [SceneLanguageVariant(
            languageCode: "en",
            text: "English menu text",
            takes: [Take(number: 5, startedAt: Date(timeIntervalSince1970: 1_700_000_000), languageCode: "en")]
        )]
        let project = FrameProject(title: "Menu", scenes: [fixture.scene])
        let appState = AppState(recording: fixture.controller)
        appState.projectStore.openProject(project, fileURL: nil, wordsPerMinute: 120, markUnsaved: true)
        appState.setEditorContextAfterFlush(sceneID: fixture.scene.id, mode: .script)
        fixture.controller.selectedLanguageCode = "en"
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)

        appState.toggleRecordingTake()
        await waitForRecording(fixture.controller)
        XCTAssertTrue(fixture.controller.phase.isRecording)
        await fixture.controller.stopTake()

        let variantTake = try XCTUnwrap(fixture.scene.languageVariants.first?.takes.last)
        XCTAssertEqual(variantTake.number, 6)
        XCTAssertEqual(variantTake.languageCode, "en")
        XCTAssertEqual(variantTake.readText, "English menu text")
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

    func testOBSKeychainWriteUpdatesInsteadOfDeleting() throws {
        var added = false
        try OBSKeychainWrite.save(
            update: { errSecSuccess },
            add: { added = true; return errSecSuccess }
        )
        XCTAssertFalse(added)
    }

    func testOBSKeychainWriteAddsOnlyWhenItemIsMissing() throws {
        var added = false
        try OBSKeychainWrite.save(
            update: { errSecItemNotFound },
            add: { added = true; return errSecSuccess }
        )
        XCTAssertTrue(added)
    }

    func testOBSKeychainWriteLeavesOldItemWhenUpdateFails() {
        var added = false
        XCTAssertThrowsError(try OBSKeychainWrite.save(
            update: { errSecAuthFailed },
            add: { added = true; return errSecSuccess }
        ))
        XCTAssertFalse(added)
    }

    func testOBSKeychainReadIsLazyAndOnlyHappensOnce() {
        let suiteName = "RecordingTakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let secrets = FakeOBSSecretStore()
        secrets.password = "secreto"
        let preferences = OBSPreferencesStore(defaults: defaults, secretStore: secrets)

        XCTAssertEqual(secrets.readCount, 0)
        XCTAssertFalse(preferences.hasLoadedPassword)
        preferences.loadPasswordIfNeeded()
        preferences.loadPasswordIfNeeded()
        XCTAssertEqual(secrets.readCount, 1)
        XCTAssertEqual(preferences.password, "secreto")
    }

    func testFailedPasswordSaveKeepsThePreviousPassword() {
        let suiteName = "RecordingTakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let secrets = FakeOBSSecretStore()
        secrets.password = "old"
        let preferences = OBSPreferencesStore(defaults: defaults, secretStore: secrets)
        preferences.loadPasswordIfNeeded()
        secrets.saveError = FakeSecretError()

        XCTAssertThrowsError(try preferences.apply(
            host: "localhost",
            portText: "4455",
            autoConnect: false,
            password: "new"
        ))
        XCTAssertEqual(preferences.password, "old")
        XCTAssertEqual(secrets.password, "old")
    }

    func testManualTakeFilePickerAcceptsMatroska() throws {
        let mkv = try XCTUnwrap(UTType(filenameExtension: "mkv"))
        XCTAssertTrue(TakeFileSelection.allowedContentTypes.contains {
            $0.identifier == mkv.identifier
        })
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

    // MARK: - Integration: recorded takes feed the duration model

    /// C records takes into `scene.takes`; D must read them field for field and
    /// show the real duration and the learned pace without any adapter.
    func testRecordedTakesFeedLearnedWPMAndRealDurationSummary() async throws {
        let fixture = makeFixture(sceneText: "uno dos tres cuatro cinco seis siete ocho nueve diez")
        let scene = fixture.scene
        let project = FrameProject(title: "Duration", scenes: [scene], primaryLanguage: "es")
        let appState = AppState(
            projectStore: ProjectStore(project: project),
            recording: fixture.controller
        )
        appState.projectStore.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        appState.setEditorContextAfterFlush(sceneID: scene.id, mode: .script)
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)

        var start = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 {
            fixture.controller.now = { start }
            await fixture.controller.startTake(sceneID: scene.id)
            fixture.controller.now = { start.addingTimeInterval(5) }
            await fixture.controller.stopTake()
            start = start.addingTimeInterval(10)
        }

        XCTAssertEqual(scene.takes.count, 3)
        for take in scene.takes {
            XCTAssertEqual(take.duration, 5, accuracy: 0.001)
            XCTAssertEqual(take.readText, scene.scriptText)
            XCTAssertEqual(take.sceneTextHash, FrameScriptDocument.TextHash.hash(scene.scriptText))
            fixture.controller.setRating(.good, takeID: take.id, sceneID: scene.id)
        }

        let summary = appState.sceneDurationSummary(for: scene)
        XCTAssertEqual(try XCTUnwrap(summary.real), 5, accuracy: 0.001)
        XCTAssertEqual(summary.realTakeNumber, 3)
        XCTAssertEqual(summary.realTakeRating, .good)

        // Three good 10-word takes in 5 s teach 120 wpm, which the estimate and
        // every duration surface then use.
        appState.recomputeLearnedWPM(markDirty: false)
        let learned = try XCTUnwrap(project.learnedWordsPerMinuteByLanguage["es"])
        XCTAssertEqual(learned, 120, accuracy: 1)
        XCTAssertEqual(appState.effectiveWPM(language: "es"), learned, accuracy: 0.001)
        XCTAssertEqual(appState.currentDurationWordsPerMinute, 120)
        XCTAssertEqual(scene.estimatedDuration, 5, accuracy: 0.001)
    }

    func testVariantTakeRecordedThroughOBSFeedsRealDurationSummary() async throws {
        let fixture = makeFixture(sceneText: "Texto original")
        fixture.scene.languageVariants = [
            SceneLanguageVariant(languageCode: "en", text: "English read text")
        ]
        let scene = fixture.scene
        let project = FrameProject(title: "Variants", scenes: [scene], primaryLanguage: "es")
        let appState = AppState(
            projectStore: ProjectStore(project: project),
            recording: fixture.controller
        )
        appState.projectStore.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        appState.setEditorContextAfterFlush(sceneID: scene.id, mode: .script)
        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }
        await fixture.controller.startTake(sceneID: scene.id, languageCode: "en")
        fixture.controller.now = { start.addingTimeInterval(4) }
        await fixture.controller.stopTake()

        let take = try XCTUnwrap(scene.languageVariants.first?.takes.last)
        XCTAssertEqual(take.languageCode, "en")
        XCTAssertEqual(take.readText, "English read text")
        XCTAssertEqual(take.sceneTextHash, FrameScriptDocument.TextHash.hash("English read text"))

        XCTAssertEqual(
            try XCTUnwrap(appState.sceneDurationSummary(for: scene, language: "en").real),
            4,
            accuracy: 0.001
        )
        XCTAssertNil(appState.sceneDurationSummary(for: scene, language: "es").real)
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

    private func waitForStartInFlight(_ client: FakeOBSClient) async {
        for _ in 0..<200 {
            if await client.isStartInFlight { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("startRecord was never entered")
    }

    private func waitForRecording(_ controller: RecordingController) async {
        for _ in 0..<200 {
            if controller.phase.isRecording { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("recording never started")
    }

    private func makeFixture(sceneText: String) -> Fixture {
        let suiteName = "RecordingTakeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = OBSPreferencesStore(defaults: defaults, secretStore: FakeOBSSecretStore())
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
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var getRecordStatusCount = 0
    private(set) var programScenes: [String] = []
    private(set) var isStartInFlight = false
    private var startFailure: OBSError?
    private var stopFailure: OBSError?
    private var connectFailure: OBSError?
    private var stateCheckDelayNanos: UInt64?
    private var startDelayNanos: UInt64?
    private var reportedActive: Bool?
    private var reportedDuration: TimeInterval = 0
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
    func setStateCheckDelay(_ nanos: UInt64?) { stateCheckDelayNanos = nanos }
    func setStartDelay(_ nanos: UInt64?) { startDelayNanos = nanos }
    func setRecordStatus(outputActive: Bool? = nil, outputDuration: TimeInterval = 0) {
        reportedActive = outputActive
        reportedDuration = outputDuration
    }

    func currentConnectionState() async -> OBSConnectionState {
        if let stateCheckDelayNanos {
            try? await Task.sleep(nanoseconds: stateCheckDelayNanos)
        }
        return state
    }

    func connect(config: OBSConnectionConfig) async throws {
        connectCount += 1
        if let connectFailure { throw connectFailure }
        state = .connected(OBSSessionInfo(
            obsStudioVersion: "30.0.0",
            obsWebSocketVersion: "5.5.0",
            rpcVersion: 1,
            negotiatedRpcVersion: 1
        ))
    }

    func disconnect() async {
        disconnectCount += 1
        state = .disconnected
    }

    func getSceneList() async throws -> OBSSceneList { sceneList }

    func setCurrentProgramScene(name: String) async throws {
        programScenes.append(name)
    }

    func startRecord() async throws {
        isStartInFlight = true
        defer { isStartInFlight = false }
        if let startDelayNanos {
            try? await Task.sleep(nanoseconds: startDelayNanos)
        }
        if let startFailure { throw startFailure }
        startCount += 1
    }

    func stopRecord() async throws -> String {
        if let stopFailure { throw stopFailure }
        stopCount += 1
        return outputPath
    }

    func getRecordStatus() async throws -> OBSRecordStatus {
        getRecordStatusCount += 1
        return OBSRecordStatus(
            outputActive: reportedActive ?? (startCount > stopCount),
            outputPaused: false,
            outputTimecode: "",
            outputDuration: Int(reportedDuration * 1_000),
            outputBytes: 0
        )
    }
}

private final class FakeOBSSecretStore: OBSSecretStoring, @unchecked Sendable {
    var password: String?
    var readCount = 0
    var saveError: Error?

    func readPassword() throws -> String? {
        readCount += 1
        return password
    }

    func savePassword(_ password: String) throws {
        if let saveError { throw saveError }
        self.password = password
    }
}

private struct FakeSecretError: Error {}
