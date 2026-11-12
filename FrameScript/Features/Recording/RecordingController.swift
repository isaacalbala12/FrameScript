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

    private enum TakeInterruption {
        case connectionLost
        case stopFailed(String)
        case applicationQuit
        case externalStop
    }

    // MARK: Observable state

    private(set) var phase: RecordingPhase = .idle
    private(set) var connectionState: OBSConnectionState = .disconnected
    private(set) var connectionIssue: RecordingIssue?
    private(set) var scenesIssue: RecordingIssue?
    private(set) var lastIssue: RecordingIssue?
    private(set) var scenes: [OBSScene] = []
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastTakeID: UUID?
    private(set) var activeSceneID: UUID?
    private(set) var activeLanguageCode = ""
    private(set) var isTestingConnection = false

    var isPanelVisible: Bool {
        didSet { defaults.set(isPanelVisible, forKey: DefaultsKey.panelVisible) }
    }

    var countdownEnabled: Bool {
        didSet { defaults.set(countdownEnabled, forKey: DefaultsKey.countdownEnabled) }
    }

    var isSettingsPresented = false
    var isManualEntryPresented = false
    var teleprompterHook: (any RecordingTeleprompterHook)?

    // MARK: Dependencies

    let preferences: OBSPreferencesStore
    private let client: any OBSRecordingClient
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

    /// Injectable clock so tests can assert start times without sleeping.
    var now: () -> Date

    init(
        client: any OBSRecordingClient = OBSClient(),
        preferences: OBSPreferencesStore = OBSPreferencesStore(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.preferences = preferences
        self.defaults = defaults
        self.now = now
        self.isPanelVisible = defaults.bool(forKey: DefaultsKey.panelVisible)
        if let storedCountdown = defaults.object(forKey: DefaultsKey.countdownEnabled) as? Bool {
            self.countdownEnabled = storedCountdown
        } else {
            self.countdownEnabled = true
        }
        self.teleprompterHook = NoOpRecordingTeleprompterHook()
        observeClient()
    }

    // MARK: Derived state

    var isBusy: Bool { phase != .idle }

    var hasActiveTake: Bool { activeSceneID != nil && phase != .idle }

    var sceneNames: [String] { scenes.map(\.name) }

    var statusLanguage: AppLanguage { gateway?.language() ?? .english }

    func localized(_ key: String) -> String {
        L10n.tr(key, language: statusLanguage)
    }

    func issueMessage(_ issue: RecordingIssue) -> String {
        issue.message(language: statusLanguage)
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
        await connect(
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

    /// Attempts a connection without persisting the form values. Used by the
    /// “Probar conexión” button so a typo never overwrites working settings.
    @discardableResult
    func testConnection(host: String, port: Int, password: String) async -> Bool {
        guard phase == .idle else {
            lastIssue = .busy
            return false
        }
        isTestingConnection = true
        defer { isTestingConnection = false }
        let succeeded = await connect(host: host, port: port, password: password)
        if !succeeded {
            lastIssue = connectionIssue
        }
        return succeeded
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
        case .recording:
            await stopTake()
        case .starting, .stopping:
            break
        }
    }

    func startTake(sceneID: UUID, languageCode: String = "") async {
        guard phase == .idle else { return }
        guard let gateway else {
            lastIssue = .noScene
            return
        }
        guard let scene = gateway.scene(sceneID) else {
            lastIssue = .noScene
            return
        }
        guard await client.currentConnectionState().isConnected else {
            lastIssue = .notConnected
            isPanelVisible = true
            return
        }

        lastIssue = nil
        activeSceneID = sceneID
        activeLanguageCode = normalizedLanguage(languageCode)
        activeReadText = text(in: scene, languageCode: activeLanguageCode)
        activeStartedAt = nil
        lastKnownOutputPath = ""
        elapsed = 0

        if countdownEnabled {
            startCountdown()
        } else {
            await beginRecording()
        }
    }

    private func startCountdown() {
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
                guard !Task.isCancelled, self.activeSceneID != nil else { return }
                if remaining > 0 {
                    self.phase = .countdown(remaining)
                    self.teleprompterHook?.recordingCountdownDidTick(seconds: remaining)
                }
            }
            guard !Task.isCancelled else { return }
            await self.beginRecording()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        guard case .countdown = phase else { return }
        phase = .idle
        lastIssue = nil
        resetActiveTake(clearElapsed: true)
    }

    private func beginRecording() async {
        countdownTask = nil
        guard let sceneID = activeSceneID, let gateway else {
            resetActiveTake()
            lastIssue = .noScene
            return
        }
        guard let scene = gateway.scene(sceneID) else {
            resetActiveTake()
            lastIssue = .sceneDeleted
            return
        }

        phase = .starting
        do {
            if let obsScene = scene.obsSceneName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !obsScene.isEmpty {
                do {
                    try await client.setCurrentProgramScene(name: obsScene)
                } catch {
                    throw RecordingIssue.obsSceneSwitchFailed(obsScene)
                }
            }
            let startedAt = now()
            try await client.startRecord()
            activeStartedAt = startedAt
            phase = .recording(startedAt: startedAt)
            elapsed = 0
            startTicker()
            teleprompterHook?.recordingDidStart(sceneID: sceneID)
        } catch {
            let issue = RecordingIssue.from(error, operation: .start)
            lastIssue = issue
            phase = .idle
            resetActiveTake(clearElapsed: true)
        }
    }

    func stopTake() async {
        guard case .recording(let startedAt) = phase, activeSceneID != nil else { return }
        phase = .stopping
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
            let interruption: TakeInterruption
            if issue == .connectionLost {
                interruption = .connectionLost
            } else {
                interruption = .stopFailed(issue.message(language: statusLanguage))
            }
            lastIssue = issue
            finalizeTake(
                filePath: lastKnownOutputPath,
                duration: elapsedAtStop,
                interruption: interruption
            )
        }
    }

    /// Best-effort stop used by the application delegate when FrameScript is
    /// quitting. The take is closed out with the elapsed time; OBS owns the file
    /// and is allowed to finish writing it.
    func stopForApplicationTermination() async {
        switch phase {
        case .countdown:
            cancelCountdown()
            return
        case .idle, .stopping:
            return
        case .starting:
            phase = .idle
            resetActiveTake(clearElapsed: true)
            return
        case .recording:
            break
        }
        guard case .recording(let startedAt) = phase, activeSceneID != nil else { return }
        phase = .stopping
        let elapsedAtStop = max(elapsed, now().timeIntervalSince(startedAt))
        do {
            let path = try await client.stopRecord()
            finalizeTake(filePath: path, duration: elapsedAtStop, interruption: .applicationQuit)
        } catch {
            finalizeTake(filePath: lastKnownOutputPath, duration: elapsedAtStop, interruption: .applicationQuit)
        }
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
            resetActiveTake(clearElapsed: true)
            phase = .idle
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
        gateway.markProjectChanged()
        lastTakeID = take.id
        if case .connectionLost = interruption {
            lastIssue = .connectionLost
        }

        phase = .idle
        elapsed = duration
        resetActiveTake(clearElapsed: false)
        teleprompterHook?.recordingDidStop(
            sceneID: sceneID,
            takeID: take.id,
            wasInterrupted: interruption != nil
        )
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
        case .stopFailed(let detail):
            text = String(
                format: L10n.tr("recording.take.stopFailedNote", language: language),
                detail
            )
        case .applicationQuit:
            text = L10n.tr("recording.take.quitNote", language: language)
        case .externalStop:
            return ""
        }
        return Self.interruptedNoteMarker + text
    }

    private func resetActiveTake(clearElapsed: Bool = false) {
        tickTask?.cancel()
        tickTask = nil
        countdownTask?.cancel()
        countdownTask = nil
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
                self.handleEvent(event)
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
            phase = .idle
            lastIssue = .connectionLost
            resetActiveTake(clearElapsed: true)
        case .countdown:
            cancelCountdown()
        case .idle, .stopping:
            break
        }
    }

    /// Internal so tests can simulate OBS events without a socket.
    func handleEvent(_ event: OBSEvent) {
        switch event {
        case .recordStateChanged(let change):
            if let path = change.outputPath, !path.isEmpty {
                lastKnownOutputPath = path
            }
            // The user pressed Stop inside OBS itself.
            if !change.isRecording,
               case .recording(let startedAt) = phase,
               activeSceneID != nil {
                let duration = max(elapsed, now().timeIntervalSince(startedAt))
                finalizeTake(
                    filePath: change.outputPath ?? lastKnownOutputPath,
                    duration: duration,
                    interruption: .externalStop
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
