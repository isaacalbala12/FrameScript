import Foundation
import FrameScriptCore
import Observation

/// One take together with the language bucket it belongs to.
struct SceneTake: Identifiable, Equatable {
    var take: Take
    var languageCode: String

    var id: UUID { take.id }
}

/// Owns the obs-websocket connection, the take lifecycle and every recording
/// mutation. The view layer only calls these methods; project writes go back
/// through the gateway so `AppState` keeps its dirty/autosave rules.
@MainActor
@Observable
final class RecordingController {
    struct Gateway {
        var scene: @MainActor (UUID) -> Scene?
        var markProjectChanged: @MainActor () -> Void
        var language: @MainActor () -> AppLanguage
    }

    private enum DefaultsKey {
        static let panelVisible = "recording.panelVisible"
        static let countdownEnabled = "recording.countdownEnabled"
    }

    private enum TakeInterruption: Equatable {
        case connectionLost
        case stopFailed
        case applicationQuit
    }

    /// Remembers the take that was closed out when the socket dropped, so a
    /// reconnect can adopt the still-running OBS output instead of duplicating
    /// the entry.
    private struct InterruptedTakeContext {
        let sceneID: UUID
        let languageCode: String
        let readText: String
        let startedAt: Date
        let takeID: UUID
    }

    // MARK: Observable state

    private(set) var phase: RecordingPhase = .idle
    private(set) var connectionState: OBSConnectionState = .disconnected
    private(set) var connectionIssue: RecordingIssue?
    private(set) var testConnectionIssue: RecordingIssue?
    private(set) var scenesIssue: RecordingIssue?
    private(set) var lastIssue: RecordingIssue?
    /// OBS is recording an output FrameScript did not start (for example a
    /// gameplay capture started by hand). Never stop it from FrameScript.
    private(set) var externalRecordingActive = false
    private(set) var scenes: [OBSScene] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastTakeID: UUID?
    private(set) var activeSceneID: UUID?
    private(set) var activeLanguageCode = ""
    private(set) var isTestingConnection = false

    /// Language chosen in the panel. The menu shortcut and manual entry use the
    /// same selection, so ⌘R never silently records the original language.
    var selectedLanguageCode = ""

    var isPanelVisible: Bool {
        didSet { defaults.set(isPanelVisible, forKey: DefaultsKey.panelVisible) }
    }

    var countdownEnabled: Bool {
        didSet { defaults.set(countdownEnabled, forKey: DefaultsKey.countdownEnabled) }
    }

    var isSettingsPresented = false
    var isManualEntryPresented = false
    /// Weak: `AppState` owns the controller and is itself the hook.
    weak var teleprompterHook: (any RecordingTeleprompterHook)?

    // MARK: Dependencies

    let preferences: OBSPreferencesStore
    private let client: any OBSRecordingClient
    /// Creates a throwaway connection for “Test connection”. The live session
    /// must never be torn down just to test a form value.
    private let clientFactory: () -> any OBSRecordingClient
    private let defaults: UserDefaults
    private var gateway: Gateway?
    private var stateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var activeStartedAt: Date?
    private var activeReadText = ""
    private var lastKnownOutputPath = ""
    private var didAutoConnect = false

    /// One token per start attempt. Every await in the start path re-checks it,
    /// so a quit or stop that lands mid-handshake cannot install `.recording`.
    private var startToken: UUID?
    private var stopRequestedWhileStarting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopping = false
    private var interruptedContext: InterruptedTakeContext?
    private var recoveredTakeID: UUID?

    /// Injectable clock so tests can assert start times without sleeping.
    var now: () -> Date

    init(
        client: any OBSRecordingClient = OBSClient(),
        clientFactory: @escaping () -> any OBSRecordingClient = { OBSClient() },
        preferences: OBSPreferencesStore = OBSPreferencesStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.clientFactory = clientFactory
        self.preferences = preferences
        self.defaults = defaults
        self.now = now
        self.isPanelVisible = defaults.bool(forKey: DefaultsKey.panelVisible)
        if let storedCountdown = defaults.object(forKey: DefaultsKey.countdownEnabled) as? Bool {
            self.countdownEnabled = storedCountdown
        } else {
            self.countdownEnabled = true
        }
        observeClient()
    }

    // MARK: Derived state

    var isBusy: Bool { phase != .idle }

    var hasActiveTake: Bool { activeSceneID != nil && phase != .idle }

    var sceneNames: [String] { scenes.map(\.name) }

    var statusLanguage: AppLanguage { gateway?.language() ?? .english }

    func issueMessage(_ issue: RecordingIssue) -> String {
        issue.message(language: statusLanguage)
    }

    /// The selected variant, but only when the current scene actually has it.
    func effectiveLanguage(for scene: Scene?) -> String {
        guard let scene else { return "" }
        let normalized = normalizedLanguage(selectedLanguageCode)
        guard !normalized.isEmpty,
              scene.languageVariants.contains(where: {
                  normalizedLanguage($0.languageCode) == normalized
              })
        else { return "" }
        return normalized
    }

    // MARK: Wiring

    /// Called once by `AppState` after initialization. Weak captures live in
    /// `AppState+Recording.swift`, so the controller never retains the app state.
    func attach(_ gateway: Gateway) {
        self.gateway = gateway
    }

    func connectAutomaticallyIfNeeded() async {
        guard preferences.autoConnect, !didAutoConnect else { return }
        didAutoConnect = true
        await connect()
    }

    // MARK: Connection

    @discardableResult
    func connect() async -> Bool {
        preferences.loadPasswordIfNeeded()
        return await connect(
            host: preferences.host,
            port: preferences.effectivePort,
            password: preferences.password
        )
    }

    @discardableResult
    func connect(host: String, port: Int, password: String) async -> Bool {
        guard phase == .idle else {
            lastIssue = .busy
            return false
        }
        connectionIssue = nil
        lastIssue = nil
        let config = OBSConnectionConfig(
            host: host,
            port: port,
            password: password.isEmpty ? nil : password,
            connectTimeout: .seconds(8),
            requestTimeout: .seconds(3),
            keepaliveInterval: .seconds(10),
            reconnect: .disabled
        )
        do {
            try await client.connect(config: config)
            connectionState = await client.currentConnectionState()
            await refreshScenes()
            await reconcileRecordStatus()
            return true
        } catch {
            connectionState = await client.currentConnectionState()
            let issue = RecordingIssue.from(error, operation: .connect)
            connectionIssue = issue
            lastIssue = issue
            return false
        }
    }

    func disconnect() async {
        guard phase == .idle else {
            lastIssue = .busy
            return
        }
        await client.disconnect()
        connectionState = .disconnected
        scenes = []
        scenesIssue = nil
    }

    /// Connects with a separate client so testing a typo never tears down the
    /// working session. The live `connectionState` deliberately is untouched.
    @discardableResult
    func testConnection(host: String, port: Int, password: String) async -> Bool {
        guard phase == .idle else {
            lastIssue = .busy
            return false
        }
        isTestingConnection = true
        testConnectionIssue = nil
        defer { isTestingConnection = false }

        let tester = clientFactory()
        let config = OBSConnectionConfig(
            host: host,
            port: port,
            password: password.isEmpty ? nil : password,
            connectTimeout: .seconds(8),
            requestTimeout: .seconds(3),
            keepaliveInterval: nil,
            reconnect: .disabled
        )
        do {
            try await tester.connect(config: config)
            await tester.disconnect()
            return true
        } catch {
            await tester.disconnect()
            testConnectionIssue = RecordingIssue.from(error, operation: .connect)
            return false
        }
    }

    func refreshScenes() async {
        guard await client.currentConnectionState().isConnected else { return }
        do {
            let list = try await client.getSceneList()
            scenes = list.scenes
            scenesIssue = nil
        } catch {
            scenes = []
            scenesIssue = RecordingIssue.from(error, operation: .connect)
        }
    }

    // MARK: Recording lifecycle

    func toggleRecording(sceneID: UUID, languageCode: String = "") async {
        switch phase {
        case .idle:
            await startTake(sceneID: sceneID, languageCode: languageCode)
        case .countdown:
            cancelCountdown()
        case .starting:
            requestStopWhileStarting()
        case .recording:
            await stopTake()
        case .stopping:
            break
        }
    }

    func startTake(sceneID: UUID, languageCode: String = "") async {
        guard phase == .idle, !isStopping else { return }
        guard !externalRecordingActive else {
            lastIssue = .externalRecordingActive
            return
        }
        guard let gateway else {
            lastIssue = .noScene
            return
        }
        guard let scene = gateway.scene(sceneID) else {
            lastIssue = .noScene
            return
        }

        let token = UUID()
        startToken = token
        // Set this synchronously: two MainActor start calls must not both pass
        // the idle guard while the first one awaits the connection check.
        phase = .starting
        stopRequestedWhileStarting = false
        lastIssue = nil
        activeSceneID = sceneID
        let requestedLanguage = normalizedLanguage(languageCode)
        activeLanguageCode = scene.languageVariants.contains(where: {
            normalizedLanguage($0.languageCode) == requestedLanguage
        }) ? requestedLanguage : ""
        activeReadText = text(in: scene, languageCode: activeLanguageCode)
        activeStartedAt = nil
        lastKnownOutputPath = ""
        elapsed = 0

        defer { signalStartupFinished() }

        let connected = await client.currentConnectionState().isConnected
        guard startToken == token else { return }
        if stopRequestedWhileStarting {
            abortStart()
            return
        }
        guard connected else {
            lastIssue = .notConnected
            abortStart()
            return
        }

        if countdownEnabled {
            startCountdown(token: token)
        } else {
            await beginRecording(token: token)
        }
    }

    private func startCountdown(token: UUID) {
        guard startToken == token, !stopRequestedWhileStarting else {
            abortStart()
            return
        }
        countdownTask?.cancel()
        let initial = 3
        phase = .countdown(initial)
        teleprompterHook?.recordingCountdownDidBegin(seconds: initial)
        teleprompterHook?.recordingCountdownDidTick(seconds: initial)
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: initial - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard !Task.isCancelled, self.startToken == token else { return }
                if self.stopRequestedWhileStarting {
                    self.abortStart()
                    return
                }
                if remaining > 0 {
                    self.phase = .countdown(remaining)
                    self.teleprompterHook?.recordingCountdownDidTick(seconds: remaining)
                }
            }
            guard !Task.isCancelled, self.startToken == token else { return }
            await self.beginRecording(token: token)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        guard case .countdown = phase else { return }
        abortStart()
    }

    private func beginRecording(token: UUID) async {
        countdownTask = nil
        guard startToken == token else { return }
        guard let sceneID = activeSceneID, let gateway else {
            abortStart(issue: .noScene)
            return
        }
        guard let scene = gateway.scene(sceneID) else {
            abortStart(issue: .sceneDeleted)
            return
        }

        do {
            if let obsScene = scene.obsSceneName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !obsScene.isEmpty {
                try await client.setCurrentProgramScene(name: obsScene)
                guard startToken == token else { return }
            }
            if stopRequestedWhileStarting {
                abortStart()
                return
            }

            let startedAt = now()
            try await client.startRecord()
            // Only the current token proves FrameScript owns this output. A
            // stale token may mean an external recording is running, so never
            // stop it here; the next GetRecordStatus will treat it as unowned.
            guard startToken == token else { return }
            if stopRequestedWhileStarting {
                stopRequestedWhileStarting = false
                await stopRecordingNow(startedAt: startedAt)
                return
            }

            activeStartedAt = startedAt
            phase = .recording(startedAt: startedAt)
            elapsed = 0
            startTicker()
            teleprompterHook?.recordingDidStart(sceneID: sceneID)
        } catch {
            guard startToken == token else { return }
            lastIssue = RecordingIssue.from(error, operation: .start)
            abortStart()
        }
    }

    func stopTake() async {
        switch phase {
        case .countdown:
            cancelCountdown()
            return
        case .starting:
            requestStopWhileStarting()
            return
        case .recording(let startedAt):
            await stopRecordingNow(startedAt: startedAt)
        case .idle, .stopping:
            return
        }
    }

    /// A stop that arrives before StartRecord returns is queued; it is honoured
    /// as soon as the start resolves (defect: silently discarded stops).
    private func requestStopWhileStarting() {
        guard case .starting = phase else { return }
        stopRequestedWhileStarting = true
    }

    private func stopRecordingNow(startedAt: Date) async {
        guard !isStopping else { return }
        isStopping = true
        phase = .stopping
        defer {
            isStopping = false
            signalStopFinished()
        }
        let elapsedAtStop = max(elapsed, now().timeIntervalSince(startedAt))
        do {
            let path = try await client.stopRecord()
            lastKnownOutputPath = path
            let fileDuration = await TakeFileProbe.duration(atPath: path)
            finalizeTake(
                filePath: path,
                duration: fileDuration ?? elapsedAtStop,
                interruption: nil
            )
        } catch {
            let issue = RecordingIssue.from(error, operation: .stop)
            lastIssue = issue
            finalizeTake(
                filePath: lastKnownOutputPath,
                duration: elapsedAtStop,
                interruption: issue == .connectionLost ? .connectionLost : .stopFailed
            )
        }
    }

    /// Stops (and finalizes) before the application asks whether to save. The
    /// take entry is therefore part of the project the save prompt writes.
    func prepareForTermination() async {
        switch phase {
        case .idle:
            return
        case .countdown:
            cancelCountdown()
            return
        case .stopping:
            break
        case .starting:
            requestStopWhileStarting()
            await waitForStartup()
            if case .countdown = phase {
                cancelCountdown()
                return
            }
            if case .recording = phase {
                await stopTake()
            }
            await waitForStopCompletion()
            return
        case .recording:
            await stopTake()
            await waitForStopCompletion()
            return
        }
        await waitForStopCompletion()
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard case .recording(let startedAt) = self.phase else { return }
                self.elapsed = max(0, self.now().timeIntervalSince(startedAt))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func finalizeTake(
        filePath: String,
        duration: TimeInterval,
        interruption: TakeInterruption?
    ) {
        guard let sceneID = activeSceneID, let gateway else {
            phase = .idle
            resetActiveTake(clearElapsed: true)
            return
        }
        let language = gateway.language()
        let startedAt = activeStartedAt ?? now()
        guard let scene = gateway.scene(sceneID) else {
            lastIssue = .sceneDeleted
            phase = .idle
            resetActiveTake(clearElapsed: true)
            return
        }

        let note = interruptionNote(for: interruption, language: language)
        let wasConnectionLost = interruption == .connectionLost
        let takeID: UUID

        if let recoveredTakeID,
           updateTake(filePath: filePath, duration: duration, note: note, wasConnectionLost: wasConnectionLost, takeID: recoveredTakeID, in: scene) {
            takeID = recoveredTakeID
        } else {
            let existing = takes(in: scene, languageCode: activeLanguageCode).map(\.take)
            let take = TakeFactory.makeTake(
                existing: existing,
                sceneText: activeReadText,
                languageCode: activeLanguageCode,
                startedAt: startedAt,
                duration: duration,
                filePath: filePath,
                note: note
            )
            append(take, to: scene, languageCode: activeLanguageCode)
            takeID = take.id
        }

        gateway.markProjectChanged()
        lastTakeID = takeID
        if wasConnectionLost {
            lastIssue = .connectionLost
            interruptedContext = InterruptedTakeContext(
                sceneID: sceneID,
                languageCode: activeLanguageCode,
                readText: activeReadText,
                startedAt: startedAt,
                takeID: takeID
            )
            recoveredTakeID = takeID
        } else {
            interruptedContext = nil
            recoveredTakeID = nil
            lastIssue = nil
        }

        phase = .idle
        elapsed = duration
        resetActiveTake(clearElapsed: false)
        teleprompterHook?.recordingDidStop(
            sceneID: sceneID,
            takeID: takeID,
            wasInterrupted: interruption != nil
        )
    }

    /// Updates a take that was previously marked interrupted when OBS kept
    /// recording through a disconnect. Returns `false` if it no longer exists.
    private func updateTake(
        filePath: String,
        duration: TimeInterval,
        note: String,
        wasConnectionLost: Bool,
        takeID: UUID,
        in scene: Scene
    ) -> Bool {
        if let index = scene.takes.firstIndex(where: { $0.id == takeID }) {
            var take = scene.takes[index]
            take.duration = max(0, duration)
            if !filePath.isEmpty { take.filePath = filePath }
            take.note = wasConnectionLost
                ? note
                : take.note.hasPrefix(Self.interruptedNoteMarker) ? "" : take.note
            scene.takes[index] = take
            return true
        }
        for variantIndex in scene.languageVariants.indices {
            if let index = scene.languageVariants[variantIndex].takes.firstIndex(where: { $0.id == takeID }) {
                var take = scene.languageVariants[variantIndex].takes[index]
                take.duration = max(0, duration)
                if !filePath.isEmpty { take.filePath = filePath }
                take.note = wasConnectionLost
                    ? note
                    : take.note.hasPrefix(Self.interruptedNoteMarker) ? "" : take.note
                scene.languageVariants[variantIndex].takes[index] = take
                return true
            }
        }
        return false
    }

    /// Interrupted takes carry a stable marker so the UI can flag them without
    /// adding a schema field (the v4 `Take` model is owned by Core).
    static let interruptedNoteMarker = "⚠︎ "

    private func interruptionNote(for interruption: TakeInterruption?, language: AppLanguage) -> String {
        guard let interruption else { return "" }
        let text: String
        switch interruption {
        case .connectionLost:
            text = L10n.tr("recording.take.interruptedNote", language: language)
        case .stopFailed:
            text = L10n.tr("recording.take.stopFailedNote", language: language)
        case .applicationQuit:
            text = L10n.tr("recording.take.quitNote", language: language)
        }
        return Self.interruptedNoteMarker + text
    }

    private func abortStart(issue: RecordingIssue? = nil) {
        if let issue { lastIssue = issue }
        startToken = nil
        stopRequestedWhileStarting = false
        phase = .idle
        resetActiveTake(clearElapsed: true)
    }

    private func resetActiveTake(clearElapsed: Bool = false) {
        tickTask?.cancel()
        tickTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        startToken = nil
        stopRequestedWhileStarting = false
        activeSceneID = nil
        activeLanguageCode = ""
        activeReadText = ""
        activeStartedAt = nil
        lastKnownOutputPath = ""
        if clearElapsed { elapsed = 0 }
    }

    // MARK: OBS observation

    private func observeClient() {
        let client = self.client
        stateTask?.cancel()
        stateTask = Task { @MainActor [weak self] in
            for await state in client.connectionStates {
                guard !Task.isCancelled, let self else { return }
                self.handleConnectionState(state)
            }
        }
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            for await event in client.events {
                guard !Task.isCancelled, let self else { return }
                await self.handleEvent(event)
            }
        }
    }

    /// Internal so tests can drive the same path the event stream uses.
    func handleConnectionState(_ state: OBSConnectionState) {
        connectionState = state
        if state.isConnected {
            connectionIssue = nil
            Task { [weak self] in
                await self?.refreshScenes()
            }
            return
        }
        scenes = []

        // A dropped socket mid-take must never lose the take silently.
        guard activeSceneID != nil else { return }
        switch phase {
        case .recording(let startedAt):
            let duration = max(elapsed, now().timeIntervalSince(startedAt))
            finalizeTake(
                filePath: lastKnownOutputPath,
                duration: duration,
                interruption: .connectionLost
            )
        case .starting:
            // Invalidate the in-flight start; if OBS ultimately started,
            // `beginRecording` sees the stale token and stops it.
            abortStart(issue: .connectionLost)
        case .countdown:
            cancelCountdown()
        case .idle, .stopping:
            break
        }
    }

    /// Internal so tests can simulate OBS events without a socket.
    func handleEvent(_ event: OBSEvent) async {
        switch event {
        case .recordStateChanged(let change):
            if let path = change.outputPath, !path.isEmpty {
                lastKnownOutputPath = path
            }
            if !change.isRecording {
                externalRecordingActive = false
            } else if phase == .idle, activeSceneID == nil {
                // OBS started recording from outside FrameScript while we were
                // connected.
                externalRecordingActive = true
            }
            // The user pressed Stop inside OBS itself.
            if !change.isRecording,
               case .recording(let startedAt) = phase,
               activeSceneID != nil {
                var duration = max(elapsed, now().timeIntervalSince(startedAt))
                let path: String
                if let outputPath = change.outputPath, !outputPath.isEmpty {
                    path = outputPath
                } else {
                    path = lastKnownOutputPath
                }
                // The stopped event can omit its path; OBS still reports the
                // duration, which is better than a zero-second take.
                if change.outputPath?.isEmpty != false,
                   let status = try? await client.getRecordStatus(),
                   status.outputDuration > 0 {
                    duration = max(duration, Double(status.outputDuration) / 1_000)
                }
                finalizeTake(
                    filePath: path,
                    duration: duration,
                    interruption: nil
                )
            }
        case .exitStarted:
            if case .recording(let startedAt) = phase, activeSceneID != nil {
                let duration = max(elapsed, now().timeIntervalSince(startedAt))
                finalizeTake(
                    filePath: lastKnownOutputPath,
                    duration: duration,
                    interruption: .connectionLost
                )
            }
        case .currentProgramSceneChanged, .other:
            break
        }
    }

    /// Called after a successful connect. OBS may still be recording from
    /// before the disconnect; adopt that output only when a matching
    /// FrameScript take exists. An output started outside FrameScript is never
    /// stopped: it is reported through `externalRecordingActive` instead.
    private func reconcileRecordStatus() async {
        guard await client.currentConnectionState().isConnected else { return }
        guard let status = try? await client.getRecordStatus() else { return }
        if !status.outputActive {
            externalRecordingActive = false
            interruptedContext = nil
            recoveredTakeID = nil
            return
        }

        if let context = interruptedContext,
           let gateway,
           gateway.scene(context.sceneID) != nil {
            let recoveredStart = now().addingTimeInterval(-Double(status.outputDuration) / 1_000)
            activeSceneID = context.sceneID
            activeLanguageCode = context.languageCode
            activeReadText = context.readText
            activeStartedAt = recoveredStart
            recoveredTakeID = context.takeID
            externalRecordingActive = false
            phase = .recording(startedAt: recoveredStart)
            elapsed = max(0, Double(status.outputDuration) / 1_000)
            startTicker()
            lastIssue = nil
            return
        }

        // Unowned output: leave OBS, the connection and the take phase alone.
        externalRecordingActive = true
        interruptedContext = nil
        recoveredTakeID = nil
    }

    // MARK: Waiter plumbing

    private func signalStartupFinished() {
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func signalStopFinished() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForStartup() async {
        guard phase == .starting else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    private func waitForStopCompletion() async {
        guard isStopping else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopWaiters.append(continuation)
        }
    }

    // MARK: Scene data

    func text(in scene: Scene, languageCode: String) -> String {
        let normalized = normalizedLanguage(languageCode)
        guard !normalized.isEmpty else { return scene.scriptText }
        return scene.languageVariants.first {
            normalizedLanguage($0.languageCode) == normalized
        }?.text ?? scene.scriptText
    }

    func takes(in scene: Scene) -> [SceneTake] {
        var result = scene.takes.map { SceneTake(take: $0, languageCode: "") }
        for variant in scene.languageVariants {
            result.append(contentsOf: variant.takes.map {
                SceneTake(take: $0, languageCode: variant.languageCode)
            })
        }
        return result.sorted {
            if $0.take.startedAt != $1.take.startedAt {
                return $0.take.startedAt > $1.take.startedAt
            }
            if $0.take.number != $1.take.number {
                return $0.take.number > $1.take.number
            }
            return $0.take.id.uuidString < $1.take.id.uuidString
        }
    }

    func takes(in scene: Scene, languageCode: String) -> [SceneTake] {
        let normalized = normalizedLanguage(languageCode)
        if normalized.isEmpty {
            return scene.takes.map { SceneTake(take: $0, languageCode: "") }
        }
        return scene.languageVariants
            .first { normalizedLanguage($0.languageCode) == normalized }?
            .takes
            .map { SceneTake(take: $0, languageCode: normalized) } ?? []
    }

    func lastTake(in scene: Scene) -> SceneTake? {
        guard let lastTakeID else { return nil }
        return takes(in: scene).first { $0.take.id == lastTakeID }
    }

    func setOBSSceneName(_ name: String?, for sceneID: UUID) {
        guard let scene = gateway?.scene(sceneID) else { return }
        let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty ?? true) ? nil : normalized
        guard scene.obsSceneName != value else { return }
        scene.obsSceneName = value
        gateway?.markProjectChanged()
    }

    // MARK: Take mutations

    func setRating(_ rating: TakeRating, takeID: UUID, sceneID: UUID) {
        updateTake(takeID: takeID, sceneID: sceneID) { $0.rating = rating }
    }

    func setNote(_ note: String, takeID: UUID, sceneID: UUID) {
        updateTake(takeID: takeID, sceneID: sceneID) { $0.note = note }
    }

    /// Removes only the take entry. The video file on disk is never touched.
    func deleteTake(takeID: UUID, sceneID: UUID) {
        guard let scene = gateway?.scene(sceneID) else { return }
        var removed = false
        if let index = scene.takes.firstIndex(where: { $0.id == takeID }) {
            scene.takes.remove(at: index)
            removed = true
        }
        for variantIndex in scene.languageVariants.indices {
            if let index = scene.languageVariants[variantIndex].takes.firstIndex(where: { $0.id == takeID }) {
                scene.languageVariants[variantIndex].takes.remove(at: index)
                removed = true
            }
        }
        guard removed else { return }
        if lastTakeID == takeID { lastTakeID = nil }
        if recoveredTakeID == takeID { recoveredTakeID = nil }
        gateway?.markProjectChanged()
    }

    private func updateTake(takeID: UUID, sceneID: UUID, _ body: (inout Take) -> Void) {
        guard let scene = gateway?.scene(sceneID) else { return }
        if let index = scene.takes.firstIndex(where: { $0.id == takeID }) {
            body(&scene.takes[index])
            gateway?.markProjectChanged()
            return
        }
        for variantIndex in scene.languageVariants.indices {
            if let index = scene.languageVariants[variantIndex].takes.firstIndex(where: { $0.id == takeID }) {
                body(&scene.languageVariants[variantIndex].takes[index])
                gateway?.markProjectChanged()
                return
            }
        }
    }

    // MARK: Manual entry

    @discardableResult
    func addManualTake(
        sceneID: UUID,
        startedAt: Date,
        duration: TimeInterval,
        fileURL: URL?,
        note: String,
        rating: TakeRating = .unrated,
        languageCode: String = ""
    ) -> Bool {
        guard let gateway, let scene = gateway.scene(sceneID) else {
            lastIssue = .noScene
            return false
        }
        let normalized = normalizedLanguage(languageCode)
        let bookmarkData = fileURL.flatMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        let take = TakeFactory.makeTake(
            existing: takes(in: scene, languageCode: normalized).map(\.take),
            sceneText: text(in: scene, languageCode: normalized),
            languageCode: normalized,
            startedAt: startedAt,
            duration: duration,
            filePath: fileURL?.path ?? "",
            bookmarkData: bookmarkData,
            rating: rating,
            note: note
        )
        append(take, to: scene, languageCode: normalized)
        gateway.markProjectChanged()
        lastTakeID = take.id
        return true
    }

    private func append(_ take: Take, to scene: Scene, languageCode: String) {
        let normalized = normalizedLanguage(languageCode)
        if normalized.isEmpty {
            scene.takes.append(take)
            return
        }
        if let index = scene.languageVariants.firstIndex(where: {
            normalizedLanguage($0.languageCode) == normalized
        }) {
            scene.languageVariants[index].takes.append(take)
        } else {
            scene.languageVariants.append(SceneLanguageVariant(
                languageCode: normalized,
                text: take.readText,
                sourceHash: take.sceneTextHash,
                takes: [take]
            ))
        }
    }

    private func normalizedLanguage(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
