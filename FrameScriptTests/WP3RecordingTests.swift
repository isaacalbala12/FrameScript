import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// Regression tests for fix package WP3 (recording, teleprompter logic and the
/// duration engine). Every test names the item it protects.
@MainActor
final class WP3RecordingTests: FrameScriptTestCase {
    // MARK: - Item 1: learned WPM survives a small number of takes

    func testOneAndTwoGoodTakesKeepTheTeleprompterLearnedWPM() throws {
        let text = Array(repeating: "palabra", count: 150).joined(separator: " ")
        let scene = makeScene(
            text: text,
            takes: [makeTake(number: 1, daysAgo: 2, duration: 60, rating: .good, readText: text)]
        )
        let project = FrameProject(title: "Learned", scenes: [scene], primaryLanguage: "es")
        project.learnedWordsPerMinuteByLanguage["es"] = 170
        let appState = makeAppState(project: project)

        appState.recomputeLearnedWPM(markDirty: false)
        XCTAssertEqual(
            project.learnedWordsPerMinuteByLanguage["es"], 170,
            "One good take is not enough evidence to replace the session-learned pace"
        )

        scene.takes.append(makeTake(number: 2, daysAgo: 1, duration: 61, rating: .good, readText: text))
        appState.recomputeLearnedWPM(markDirty: false)
        XCTAssertEqual(
            project.learnedWordsPerMinuteByLanguage["es"], 170,
            "Two good takes are still below the learner's minimum of three"
        )

        scene.takes.append(makeTake(number: 3, daysAgo: 0.5, duration: 59, rating: .good, readText: text))
        appState.recomputeLearnedWPM(markDirty: false)
        let learned = try XCTUnwrap(project.learnedWordsPerMinuteByLanguage["es"])
        XCTAssertEqual(
            learned, 150, accuracy: 0.5,
            "Three good takes must let the take rebuild win again"
        )
    }

    // MARK: - Item 4: no whole-project re-parse when the pace did not change

    func testLearnedReportDoesNotRefreshEstimatesWhenValuesAreUnchanged() {
        let scene = makeScene(text: "hola mundo")
        let project = FrameProject(title: "No refresh", scenes: [scene], primaryLanguage: "es")
        let appState = makeAppState(project: project)

        // Sentinel: only `refreshDurationEstimates()` would overwrite it.
        scene.estimatedDuration = 999
        appState.recomputeLearnedWPM(markDirty: false)

        XCTAssertEqual(
            scene.estimatedDuration, 999,
            "An unchanged learned pace must not re-parse every scene"
        )
    }

    func testSupersededLearningPassDropsItsResult() async {
        let worker = DurationLearningWorker()
        let input = DurationLearningTakeInput(
            languageCode: "es",
            rating: .good,
            duration: 60,
            readText: "uno dos tres",
            sceneTextHash: "",
            sourceText: "uno dos tres",
            sourceTextHash: "",
            startedAt: Date(),
            takeNumber: 1
        )

        let first = worker.start(inputs: [input], resetCutoffs: [:])
        let second = worker.start(inputs: [input], resetCutoffs: [:])

        XCTAssertFalse(worker.isCurrent(first.generation))
        XCTAssertTrue(worker.isCurrent(second.generation))
        _ = await first.task.value
        _ = await second.task.value
        worker.cancel()
        XCTAssertFalse(worker.isCurrent(second.generation))
    }

    // MARK: - Item 3: scene deleted mid-take keeps the file path

    func testSceneDeletedMidTakeKeepsTheIssueAndTheOrphanPath() async throws {
        let fixture = makeFixture(sceneText: "Hola mundo")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        fixture.controller.now = { start }

        await fixture.controller.connect()
        await fixture.controller.startTake(sceneID: fixture.scene.id)
        XCTAssertTrue(fixture.controller.phase.isRecording)

        fixture.box.scene = nil
        fixture.controller.now = { start.addingTimeInterval(10) }
        await fixture.controller.stopTake()

        XCTAssertEqual(fixture.controller.lastIssue, .sceneDeleted)
        XCTAssertEqual(fixture.controller.lastOrphanedTakePath, fixture.client.outputPath)
        XCTAssertTrue(
            fixture.controller.issueMessage(.sceneDeleted)
                .contains(fixture.client.outputPath),
            "The issue text must tell the user where the recording went"
        )
    }

    // MARK: - Item 7: OBS record state machine

    func testStartingEventFollowedByStartedKeepsRecording() async {
        let fixture = makeFixture(sceneText: "Hola")
        await fixture.controller.connect()
        await fixture.client.setStartDelay(200_000_000)

        let startTask = Task { @MainActor in
            await fixture.controller.startTake(sceneID: fixture.scene.id)
        }
        await waitUntil { await fixture.client.isStartInFlight }

        // OBS's normal STARTING event: outputActive == false, state == .starting.
        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .starting,
            outputPath: nil
        )))
        await startTask.value
        XCTAssertTrue(
            fixture.controller.phase.isRecording,
            "OBS's normal STARTING event reports isRecording == false and must not abort"
        )

        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: true,
            outputState: .started,
            outputPath: nil
        )))
        XCTAssertTrue(fixture.controller.phase.isRecording)

        // A STARTING event that arrives after the StartRecord response is still
        // not a user stop.
        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .starting,
            outputPath: nil
        )))
        XCTAssertTrue(fixture.controller.phase.isRecording)
    }

    func testStoppedEventDuringStartAbortsTheStart() async {
        let fixture = makeFixture(sceneText: "Hola")
        await fixture.controller.connect()
        await fixture.client.setStartDelay(300_000_000)

        let startTask = Task { @MainActor in
            await fixture.controller.startTake(sceneID: fixture.scene.id)
        }
        await waitUntil { await fixture.client.isStartInFlight }

        await fixture.controller.handleEvent(.recordStateChanged(OBSRecordStateChanged(
            outputActive: false,
            outputState: .stopped,
            outputPath: nil
        )))
        await startTask.value

        XCTAssertEqual(fixture.controller.phase, .idle)
        guard case .startFailed(let detail)? = fixture.controller.lastIssue else {
            return XCTFail("Expected a start failure, got \(String(describing: fixture.controller.lastIssue))")
        }
        XCTAssertEqual(
            detail,
            L10n.tr("recording.error.stoppedDuringStart", language: .spanish)
        )
    }

    // MARK: - Item 3: unreadable record status blocks starting

    func testUnreadableRecordStatusBlocksStartingAfterReconnect() async {
        let fixture = makeFixture(sceneText: "Hola")
        await fixture.client.failNextRecordStatusReads(2)

        let connected = await fixture.controller.connect()
        XCTAssertTrue(connected)
        XCTAssertTrue(fixture.controller.recordStatusUnknown)
        XCTAssertNotNil(fixture.controller.connectionIssue)
        let statusReads = await fixture.client.getRecordStatusCount
        XCTAssertEqual(statusReads, 2, "The status read is retried exactly once")

        await fixture.controller.startTake(sceneID: fixture.scene.id)
        XCTAssertEqual(fixture.controller.phase, .idle)
        XCTAssertEqual(fixture.controller.lastIssue, fixture.controller.connectionIssue)
        let startCount = await fixture.client.startCount
        XCTAssertEqual(startCount, 0, "An unknown status must never start a take")
    }

    // MARK: - Item 3: shutdown

    func testShutdownClosesTheOBSClient() async {
        let fixture = makeFixture(sceneText: "Hola")
        await fixture.controller.shutdown()
        let shutdownCount = await fixture.client.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
    }

    // MARK: - Item 5: configured pause defaults reach the teleprompter

    func testPauseDefaultsOfTwoAndThreeSecondsSurviveALiveRefresh() throws {
        let defaults = PauseDefaults(short: 2, long: 3)
        let sceneID = UUID()
        var scenes = [TeleprompterSceneText(id: sceneID, title: "Uno", text: "uno / dos // tres")]
        let provider: TeleprompterSceneProvider = { scenes }
        let model = TeleprompterModel(
            sections: TeleprompterContentBuilder.sections(from: scenes, pauseDefaults: defaults),
            startingSectionIndex: 0,
            language: .english,
            settingsStore: TeleprompterSettingsStore(userDefaults: makeDefaults()),
            sceneProvider: provider,
            pauseDefaults: defaults
        )
        addTeardownBlock { model.stop() }

        model.refreshFromProvider()
        XCTAssertEqual(pauseValues(in: model), [2, 3])

        scenes[0] = TeleprompterSceneText(
            id: sceneID,
            title: "Uno",
            text: "uno / dos // tres y cuatro"
        )
        model.refreshFromProvider()
        XCTAssertEqual(
            pauseValues(in: model), [2, 3],
            "The provider refresh must reuse the configured pauses, not the standard ones"
        )
    }

    // MARK: - Item 6: one language identity

    func testEsMxTakeNumberingUsesTheSameBucketAsEs() {
        let existing = [
            Take(number: 3, startedAt: Date(timeIntervalSince1970: 1_700_000_000), languageCode: "es")
        ]
        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: "es-MX"), 4)
        XCTAssertEqual(TakeNumbering.nextNumber(existing: existing, languageCode: "ES_mx"), 4)
    }

    func testEsMxEffectiveWPMUsesTheEsLearnedValue() {
        let project = FrameProject(title: "MX", scenes: [], primaryLanguage: "es-MX")
        project.learnedWordsPerMinuteByLanguage["es"] = 170
        let appState = makeAppState(project: project)

        XCTAssertEqual(appState.effectiveWPM(language: "es-MX"), 170, accuracy: 0.001)
        XCTAssertEqual(appState.durationProjectLanguage, "es")
    }

    func testSelectedEsLanguageMatchesAnEsMxVariant() {
        let fixture = makeFixture(sceneText: "Original")
        fixture.scene.languageVariants = [
            SceneLanguageVariant(languageCode: "es-MX", text: "Variante", sourceHash: "", takes: [])
        ]
        fixture.controller.selectedLanguageCode = "es"

        XCTAssertEqual(fixture.controller.effectiveLanguage(for: fixture.scene), "es")
        XCTAssertEqual(
            fixture.controller.text(in: fixture.scene, languageCode: "es"),
            "Variante"
        )
    }

    func testProjectLanguageCodeMapsToTheSpeechLocale() {
        XCTAssertEqual(SpeechLanguage(projectLanguageCode: "es-MX"), .spanish)
        XCTAssertEqual(SpeechLanguage(projectLanguageCode: "EN_us"), .english)
        XCTAssertNil(SpeechLanguage(projectLanguageCode: "ru-RU"))
        XCTAssertNil(SpeechLanguage(projectLanguageCode: ""))
    }

    // MARK: - Item 2: the presenter replaces an open window's content

    func testShowTwiceReplacesSectionsLanguageAndTitle() throws {
        let presenter = TeleprompterPresenter()
        presenter.presentHandler = { _ in }
        addTeardownBlock { presenter.close() }

        let first = [TeleprompterSceneText(id: UUID(), title: "Uno", text: "uno dos")]
        let second = [TeleprompterSceneText(id: UUID(), title: "Zwei", text: "tres cuatro")]

        presenter.show(
            source: StaticTeleprompterSource(sections: TeleprompterContentBuilder.sections(from: first)),
            provider: nil,
            startingSectionIndex: 0,
            language: .english
        )
        let model = try XCTUnwrap(presenter.activeModel)
        XCTAssertEqual(model.sections.map(\.title), ["Uno"])

        presenter.show(
            source: StaticTeleprompterSource(sections: TeleprompterContentBuilder.sections(from: second)),
            provider: nil,
            startingSectionIndex: 0,
            language: .russian
        )

        XCTAssertEqual(model.sections.map(\.title), ["Zwei"])
        XCTAssertEqual(model.language, .russian)
        XCTAssertEqual(
            presenter.activeController?.window?.title,
            L10n.tr("teleprompter.windowTitle", language: .russian)
        )
    }

    func testProjectChangeNotificationClosesThePresenter() async throws {
        let presenter = TeleprompterPresenter()
        presenter.presentHandler = { _ in }
        addTeardownBlock { presenter.close() }

        let scenes = [TeleprompterSceneText(id: UUID(), title: "Uno", text: "uno dos")]
        presenter.show(
            source: StaticTeleprompterSource(sections: TeleprompterContentBuilder.sections(from: scenes)),
            provider: nil,
            startingSectionIndex: 0,
            language: .english
        )
        XCTAssertNotNil(presenter.activeModel)

        NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: nil)
        await waitUntil { presenter.activeModel == nil }
        XCTAssertNil(presenter.activeModel)
    }

    // MARK: - Item 10: word count, pause label, plurals, settings blob

    func testSpokenWordCountIgnoresLoneDashesAndEmoji() {
        let runs: [MarkupRun] = [
            .text("hola — mundo"),
            .text(" 🚗 "),
            .text("a - b")
        ]
        XCTAssertEqual(TeleprompterTiming.wordCount(in: runs), 4)
        XCTAssertEqual(TeleprompterTiming.wordCount(in: [.text("uno, dos; tres")]), 3)
    }

    func testPauseLabelUsesTheAppLanguageDecimalSeparator() {
        let sections = [TeleprompterSection(sceneID: UUID(), title: "One", runs: [.pause(2)])]

        let english = TeleprompterAttributedStringBuilder.build(
            sections: sections,
            fontSize: 64,
            language: .english
        ).attributedString.string
        XCTAssertTrue(english.contains("2.0 s"), english)

        let spanish = TeleprompterAttributedStringBuilder.build(
            sections: sections,
            fontSize: 64,
            language: .spanish
        ).attributedString.string
        XCTAssertTrue(spanish.contains("2,0 s"), spanish)

        let russian = TeleprompterAttributedStringBuilder.build(
            sections: sections,
            fontSize: 64,
            language: .russian
        ).attributedString.string
        XCTAssertTrue(russian.contains("2,0 s"), russian)
    }

    func testDurationSamplesUseThePluralForm() {
        XCTAssertEqual(L10n.plural("duration.samples", count: 1, language: .spanish), "1 toma buena")
        XCTAssertEqual(L10n.plural("duration.samples", count: 3, language: .spanish), "3 tomas buenas")
        XCTAssertEqual(L10n.plural("duration.samples", count: 1, language: .russian), "1 хороший дубль")
        XCTAssertEqual(L10n.plural("duration.samples", count: 2, language: .russian), "2 хороших дубля")
        XCTAssertEqual(L10n.plural("duration.samples", count: 5, language: .russian), "5 хороших дублей")
        XCTAssertEqual(L10n.plural("duration.samples", count: 1, language: .english), "1 good take")
    }

    func testUnreadableTeleprompterSettingsAreKept() {
        let defaults = makeDefaults()
        let store = TeleprompterSettingsStore(userDefaults: defaults)
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: TeleprompterSettingsStore.settingsKey)

        XCTAssertEqual(store.load(), .defaults)
        XCTAssertEqual(
            defaults.data(forKey: TeleprompterSettingsStore.unreadableSettingsKey),
            garbage,
            "The unreadable blob must be preserved before the next save can overwrite it"
        )
    }

    func testPendingTeleprompterSettingsSaveIsFlushedImmediately() {
        let defaults = makeDefaults()
        let store = TeleprompterSettingsStore(userDefaults: defaults)
        let model = TeleprompterModel(
            sections: [TeleprompterSection(sceneID: UUID(), title: "One", runs: [.text("uno")])],
            startingSectionIndex: 0,
            language: .english,
            settingsStore: store
        )
        addTeardownBlock { model.stop() }

        model.settings.wordsPerMinute = 212
        model.flushPendingSettingsSave()

        XCTAssertEqual(store.load().wordsPerMinute, 212)
    }

    // MARK: - Item 9: QuickLook releases the security scope

    func testQuickLookReleasesThePreviewWhenThePanelCloses() {
        let presenter = QuickLookPresenter()
        presenter.retainPreview(URL(fileURLWithPath: "/tmp/wp3-take.mov"), accessURL: nil)
        XCTAssertEqual(presenter.activePreviewPath, "/tmp/wp3-take.mov")

        presenter.handlePanelWillClose()
        XCTAssertNil(presenter.activePreviewPath)
    }

    // MARK: - Item 11: OBS host warning

    func testOBSSettingsWarnForANonLoopbackHost() {
        XCTAssertTrue(OBSConnectionConfig(host: "localhost").isLoopbackHost)
        XCTAssertFalse(OBSConnectionConfig(host: "192.168.1.20").isLoopbackHost)
    }

    /// The OBS sheet is not part of `MainWindowSnapshotTests`, so the new
    /// non-loopback warning gets its own offscreen render (never ordered front).
    func testOBSSettingsSheetShowsTheNonLoopbackWarning() throws {
        let defaults = makeDefaults()
        let preferences = OBSPreferencesStore(
            defaults: defaults,
            secretStore: WP3FakeSecretStore()
        )
        preferences.host = "192.168.1.20"
        let controller = RecordingController(
            client: WP3FakeOBSClient(),
            preferences: preferences,
            defaults: defaults
        )
        let appState = makeAppState(project: FrameProject(title: "OBS"), recording: controller)

        for appearance in [SnapshotAppearance.light, .dark] {
            let result = SnapshotRenderer.render(
                OBSSettingsSheet(),
                name: "obs-settings-non-loopback-\(appearance.rawValue)",
                suite: "WP3RecordingTests",
                size: CGSize(width: 500, height: 640),
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("no es local") },
                "\(appearance.rawValue): the non-loopback warning is missing from \(result.textFragments)"
            )
        }
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

    private func makeTake(
        number: Int,
        daysAgo: Double,
        duration: TimeInterval,
        rating: TakeRating,
        language: String = "",
        readText: String = "",
        sceneTextHash: String = ""
    ) -> Take {
        Take(
            number: number,
            startedAt: Date(timeIntervalSinceNow: -daysAgo * 86_400),
            duration: duration,
            rating: rating,
            languageCode: language,
            readText: readText,
            sceneTextHash: sceneTextHash
        )
    }

    private func makeScene(
        text: String,
        takes: [Take] = [],
        languageVariants: [SceneLanguageVariant] = []
    ) -> Scene {
        Scene(
            order: 0,
            sectionType: .hook,
            title: "Scene",
            scriptText: text,
            takes: takes,
            languageVariants: languageVariants
        )
    }

    private func makeAppState(
        project: FrameProject,
        settings: AppSettings = .defaults,
        recording: RecordingController? = nil
    ) -> AppState {
        let suite = makeDefaults()
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            recording: recording
        )
    }

    private final class SceneBox {
        var scene: Scene?

        init(_ scene: Scene?) {
            self.scene = scene
        }
    }

    private struct Fixture {
        let client: WP3FakeOBSClient
        let controller: RecordingController
        let scene: Scene
        let box: SceneBox
    }

    private func makeFixture(sceneText: String) -> Fixture {
        let defaults = makeDefaults()
        let preferences = OBSPreferencesStore(
            defaults: defaults,
            secretStore: WP3FakeSecretStore()
        )
        let client = WP3FakeOBSClient()
        let controller = RecordingController(
            client: client,
            preferences: preferences,
            defaults: defaults
        )
        controller.countdownEnabled = false

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
        return Fixture(client: client, controller: controller, scene: scene, box: box)
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

private actor WP3FakeOBSClient: OBSRecordingClient, OBSRecordingClientShutdown {
    private(set) var state: OBSConnectionState = .disconnected
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var getRecordStatusCount = 0
    private(set) var shutdownCount = 0
    private(set) var isStartInFlight = false

    nonisolated let outputPath = "/tmp/framescript-wp3-fake-take.mov"

    private var startDelayNanos: UInt64?
    private var recordStatusFailuresRemaining = 0

    nonisolated var connectionStates: AsyncStream<OBSConnectionState> {
        AsyncStream { $0.finish() }
    }

    nonisolated var events: AsyncStream<OBSEvent> {
        AsyncStream { $0.finish() }
    }

    func setStartDelay(_ nanos: UInt64?) {
        startDelayNanos = nanos
    }

    func failNextRecordStatusReads(_ count: Int) {
        recordStatusFailuresRemaining = count
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
        getRecordStatusCount += 1
        if recordStatusFailuresRemaining > 0 {
            recordStatusFailuresRemaining -= 1
            throw OBSError.requestTimeout(requestType: "GetRecordStatus", after: .seconds(3))
        }
        return OBSRecordStatus(
            outputActive: startCount > stopCount,
            outputPaused: false,
            outputTimecode: "",
            outputDuration: 0,
            outputBytes: 0
        )
    }

    func shutdown() async {
        shutdownCount += 1
        state = .disconnected
    }
}

private final class WP3FakeSecretStore: OBSSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?

    func readPassword() throws -> String? {
        lock.withLock { password }
    }

    func savePassword(_ password: String) throws {
        lock.withLock { self.password = password }
    }
}
