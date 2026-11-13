import Foundation
import FrameScriptCore
import Observation
import Speech

// MARK: - Failures

enum VoiceFollowFailure: Error, Equatable, Sendable {
    case unsupportedLanguage
    case onDeviceUnsupported
    case permissionsDenied
    case noMicrophone
    case recognitionUnavailable
    case recognitionLost
    case audioFailure
    case cancelled
    case unknown

    var messageKey: String {
        switch self {
        case .unsupportedLanguage: "voiceFollow.error.unsupportedLanguage"
        case .onDeviceUnsupported: "voiceFollow.error.onDeviceUnsupported"
        case .permissionsDenied: "voiceFollow.error.permissions"
        case .noMicrophone: "voiceFollow.error.noMicrophone"
        case .recognitionUnavailable: "voiceFollow.error.recognitionUnavailable"
        case .recognitionLost: "voiceFollow.error.recognitionLost"
        case .audioFailure: "voiceFollow.error.audio"
        case .cancelled: ""
        case .unknown: "voiceFollow.error.unknown"
        }
    }

    static func from(_ error: Error) -> VoiceFollowFailure {
        if let failure = error as? VoiceFollowFailure {
            return failure
        }
        guard let speechError = error as? SpeechRecognitionError else {
            return .unknown
        }
        switch speechError {
        case .speechPermissionDenied, .microphonePermissionDenied:
            return .permissionsDenied
        case .localeUnsupported:
            return .unsupportedLanguage
        case .recognizerUnavailable:
            return .recognitionUnavailable
        case .onDeviceRecognitionUnavailable:
            return .onDeviceUnsupported
        case .audioDeviceUnavailable:
            return .noMicrophone
        case .audioEngineFailure:
            return .audioFailure
        case .recognitionFailed:
            return .recognitionLost
        case .alreadyRunning, .cancelled:
            return .cancelled
        }
    }
}

// MARK: - Capabilities

enum VoiceFollowCapabilities {
    /// F9 requires on-device recognition for es-ES and en-US. If the installed
    /// language model cannot run locally we refuse instead of silently sending
    /// audio to a server.
    static func supportsOnDeviceRecognition(_ language: SpeechLanguage) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language.localeIdentifier))?
            .supportsOnDeviceRecognition == true
    }
}

// MARK: - Controller

/// Owns the live speech pipeline, the follower and the fallback state.
///
/// The follower itself runs in `VoiceFollowFollowerEngine`, an actor, because
/// its alignment DP is too expensive for the MainActor. This controller only
/// applies the resulting state, tracks the fallback mode and publishes the
/// reading location the playback model turns into a scroll offset.
@MainActor
@Observable
final class TeleprompterVoiceFollow {
    enum Phase: String, Equatable, Sendable {
        case off
        case preparing
        case listening
        case following
        case timedFallback
    }

    private(set) var phase: Phase = .off
    private(set) var phaseChangeCount = 0
    private(set) var isEnabled = false
    private(set) var currentLocation: VoiceFollowLocation?
    private(set) var confidence: Double = 0
    private(set) var availableInputDevices: [AudioInputDevice] = []
    private(set) var lastFailure: VoiceFollowFailure?
    private(set) var document: VoiceFollowDocument?

    var onFailure: ((VoiceFollowFailure) -> Void)?
    var onSessionFinished: ((TeleprompterReadingSession) -> Void)?
    /// Supplies the line currently on screen while timed fallback runs, so a
    /// hypothesis can re-anchor before alignment instead of searching from a
    /// stale pre-fallback word.
    var fallbackPositionProvider: (@MainActor () -> VoiceFollowPosition?)?
    /// Tests drive liveness with synthetic timestamps and disable the real
    /// 4 Hz clock; production leaves this on.
    var runsLivenessTask = true

    private let recognizer: any SpeechRecognizing
    private let configuration: SpeechFollowConfiguration
    private var engine: VoiceFollowFollowerEngine?
    private var tracker = VoiceFollowModeTracker()
    private var streamTask: Task<Void, Never>?
    private var livenessTask: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var documentGeneration = 0
    private var lifecycleGeneration = 0
    private var isTransitioning = false
    private var language: SpeechLanguage = .spanish
    private var sessionStartedAt: TimeInterval?
    private var lastHypothesisAt: TimeInterval?
    private var activeSpeechDuration: TimeInterval = 0
    private var speechSegmentStartedAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?
    private var startTokenIndex: Int?
    private var furthestTokenIndex: Int?

    init(
        recognizer: any SpeechRecognizing = LiveSpeechRecognizer(),
        configuration: SpeechFollowConfiguration = SpeechFollowConfiguration()
    ) {
        self.recognizer = recognizer
        self.configuration = configuration
    }

    var statusKey: String {
        switch phase {
        case .off: "voiceFollow.off"
        case .preparing: "voiceFollow.preparing"
        case .listening, .following: "voiceFollow.listening"
        case .timedFallback: "voiceFollow.timed"
        }
    }

    var isFollowing: Bool { phase == .following }

    // MARK: Permissions

    func permissions() async -> SpeechRecognitionPermissions {
        await recognizer.permissions()
    }

    func requestPermissions() async -> SpeechRecognitionPermissions {
        await recognizer.requestPermissions()
    }

    func refreshInputDevices() async {
        availableInputDevices = await Task.detached {
            AudioInputDevices.available()
        }.value
    }

    // MARK: Lifecycle

    func start(
        document: VoiceFollowDocument,
        language: SpeechLanguage,
        startPosition: VoiceFollowPosition?,
        inputDeviceUID: String?
    ) async throws {
        guard !isEnabled else { return }
        guard !isTransitioning else { throw VoiceFollowFailure.cancelled }
        isTransitioning = true
        defer { isTransitioning = false }
        let generation = nextLifecycleGeneration()
        await teardownTask?.value
        guard generation == lifecycleGeneration else {
            throw VoiceFollowFailure.cancelled
        }

        lastFailure = nil
        setPhase(.preparing)
        isEnabled = true
        self.document = document
        self.language = language
        engine = VoiceFollowFollowerEngine(document: document, configuration: configuration)
        tracker.reset()
        confidence = 0
        resetSession()
        let location = await engine?.seek(to: startPosition)
        currentLocation = location
        startTokenIndex = location?.tokenIndex ?? 0

        if recognizer is LiveSpeechRecognizer,
           !VoiceFollowCapabilities.supportsOnDeviceRecognition(language) {
            await resetAfterFailedStart(.onDeviceUnsupported)
            throw VoiceFollowFailure.onDeviceUnsupported
        }

        do {
            try await beginStreaming(language: language, inputDeviceUID: inputDeviceUID)
        } catch {
            let failure = VoiceFollowFailure.from(error)
            if failure != .cancelled {
                await resetAfterFailedStart(failure)
            }
            throw failure
        }
        guard generation == lifecycleGeneration, isEnabled else {
            await stopStreamingAndWait()
            throw VoiceFollowFailure.cancelled
        }
        updatePhase()
    }

    func restart(inputDeviceUID: String?) async throws {
        guard isEnabled, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let generation = lifecycleGeneration
        await stopStreamingAndWait()
        guard generation == lifecycleGeneration, isEnabled else {
            throw VoiceFollowFailure.cancelled
        }
        try await beginStreaming(language: language, inputDeviceUID: inputDeviceUID)
        guard generation == lifecycleGeneration, isEnabled else {
            await stopStreamingAndWait()
            throw VoiceFollowFailure.cancelled
        }
        updatePhase()
    }

    /// Replaces the document and the recognition language together. Used when
    /// the open project changes language while the teleprompter is visible.
    func restart(
        language: SpeechLanguage,
        document: VoiceFollowDocument,
        inputDeviceUID: String?
    ) async throws {
        guard isEnabled, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        let generation = lifecycleGeneration
        await stopStreamingAndWait()
        guard generation == lifecycleGeneration, isEnabled else {
            throw VoiceFollowFailure.cancelled
        }
        self.language = language
        self.document = document
        engine = VoiceFollowFollowerEngine(document: document, configuration: configuration)
        let location = await engine?.seek(to: currentLocation.map {
            VoiceFollowPosition(
                sceneID: $0.sceneID,
                characterOffset: $0.characterOffset,
                localTokenIndex: $0.localTokenIndex,
                normalizedWord: document.script.token(at: $0.tokenIndex)?.normalized
            )
        })
        currentLocation = location
        try await beginStreaming(language: language, inputDeviceUID: inputDeviceUID)
        guard generation == lifecycleGeneration, isEnabled else {
            await stopStreamingAndWait()
            throw VoiceFollowFailure.cancelled
        }
        updatePhase()
    }

    /// Invalidates any in-flight start/restart and tears the recognizer down.
    /// The returned work is stored in `teardownTask`, so the next `start`
    /// waits for the recognizer to be fully stopped before it begins.
    func stop(now: TimeInterval, emitSession: Bool) {
        lifecycleGeneration += 1
        guard isEnabled || phase != .off else { return }
        closeSpeechSegment()
        if emitSession, sessionStartedAt != nil {
            let words: Int
            if let start = startTokenIndex, let furthest = furthestTokenIndex {
                words = max(0, furthest - start + 1)
            } else {
                words = 0
            }
            let duration = activeSpeechDuration
            if words > 0, duration > 0 {
                onSessionFinished?(
                    TeleprompterReadingSession(
                        spokenWords: words,
                        duration: duration,
                        language: language
                    )
                )
            }
        }

        isEnabled = false
        setPhase(.off)
        let stream = streamTask
        let liveness = livenessTask
        streamTask = nil
        livenessTask = nil
        stream?.cancel()
        liveness?.cancel()
        let previous = teardownTask
        teardownTask = Task {
            await previous?.value
            await stream?.value
            await liveness?.value
            await recognizer.stop()
        }
        engine = nil
        document = nil
        currentLocation = nil
        confidence = 0
        tracker.reset()
        resetSession()
        _ = now
    }

    func stopAndWait(now: TimeInterval, emitSession: Bool) async {
        stop(now: now, emitSession: emitSession)
        await teardownTask?.value
    }

    func waitForStop() async {
        await teardownTask?.value
    }

    // MARK: Script updates

    /// Rebuilds the document off the MainActor and migrates the reader's word.
    /// A newer update invalidates an older one, so rapid provider refreshes do
    /// not publish stale token maps.
    func updateSections(
        _ sections: [TeleprompterSection],
        language: SpeechLanguage,
        preserving position: VoiceFollowPosition?
    ) {
        guard isEnabled else { return }
        documentGeneration += 1
        let generation = documentGeneration
        documentTask = Task { @MainActor [weak self] in
            let built = await Task.detached {
                VoiceFollowDocument(sections: sections, language: language)
            }.value
            guard let self, generation == self.documentGeneration, self.isEnabled else { return }
            await self.applyDocument(built, preserving: position)
        }
    }

    func waitForDocumentUpdate() async {
        await documentTask?.value
    }

    private func applyDocument(
        _ newDocument: VoiceFollowDocument,
        preserving position: VoiceFollowPosition?
    ) async {
        let oldDocument = document
        let oldLocation = currentLocation
        let oldStart = startTokenIndex.flatMap { oldDocument?.position(atTokenIndex: $0) }
        let oldFurthest = furthestTokenIndex.flatMap { oldDocument?.position(atTokenIndex: $0) }

        document = newDocument
        if let engine {
            currentLocation = await engine.updateDocument(
                newDocument,
                oldLocation: oldLocation,
                position: position
            )
        }
        if let oldDocument, let oldStart,
           let oldToken = oldDocument.tokenIndex(for: oldStart) {
            startTokenIndex = newDocument.migratedTokenIndex(
                from: oldDocument,
                location: oldDocument.location(forTokenIndex: oldToken),
                fallback: oldStart
            ) ?? startTokenIndex
        }
        if let oldDocument, let oldFurthest,
           let oldToken = oldDocument.tokenIndex(for: oldFurthest) {
            furthestTokenIndex = newDocument.migratedTokenIndex(
                from: oldDocument,
                location: oldDocument.location(forTokenIndex: oldToken),
                fallback: oldFurthest
            ) ?? furthestTokenIndex
        }
    }

    /// Re-anchor the follower at a reading position. Used when timed fallback
    /// starts or advances, so a long silent stretch cannot leave the follower
    /// dozens of words behind the line that is actually on screen.
    func rebase(to position: VoiceFollowPosition?) async {
        guard let engine else { return }
        currentLocation = await engine.seek(to: position)
    }

    // MARK: Events

    func ingest(text: String, at timestamp: TimeInterval, segment: Int? = nil) async {
        guard isEnabled, let engine else { return }
        sessionStartedAt = sessionStartedAt ?? timestamp
        lastHypothesisAt = timestamp
        let reanchor = (tracker.mode == .timedFallback || phase == .timedFallback)
            ? fallbackPositionProvider?()
            : nil
        let update = await engine.process(
            text: text,
            at: timestamp,
            segment: segment,
            reanchor: reanchor
        )
        guard isEnabled else { return }
        apply(update, at: timestamp, recordsSpeech: true)
    }

    func tick(now: TimeInterval) async {
        guard isEnabled, let engine else { return }
        sessionStartedAt = sessionStartedAt ?? now
        // Do not re-anchor while a fresh hypothesis is trying to recover the
        // follower: a seek starts from a pristine follower and would erase the
        // confidence the recovery needs to survive its 0.4 s hysteresis.
        let recentlyHeardSpeech = lastHypothesisAt.map { now - $0 <= 1.0 } ?? false
        let reanchor = (tracker.mode == .timedFallback || phase == .timedFallback)
            && !recentlyHeardSpeech
            ? fallbackPositionProvider?()
            : nil
        let update = await engine.tick(at: now, reanchor: reanchor)
        guard isEnabled else { return }
        apply(update, at: now, recordsSpeech: false)
    }

    private func apply(
        _ update: VoiceFollowUpdate,
        at timestamp: TimeInterval,
        recordsSpeech: Bool
    ) {
        let state = update.state
        confidence = state.confidence
        if let location = update.location {
            currentLocation = location
            if recordsSpeech, state.confidence >= tracker.followConfidence, !state.isLost {
                recordSpeech(at: timestamp)
            }
            if state.confidence >= tracker.followConfidence, !state.isLost {
                furthestTokenIndex = max(furthestTokenIndex ?? location.tokenIndex, location.tokenIndex)
            }
        }
        let mode = tracker.update(
            confidence: state.confidence,
            isLost: state.isLost,
            hasPosition: currentLocation != nil,
            at: timestamp
        )
        if mode == .timedFallback {
            closeSpeechSegment()
        }
        updatePhase()
    }

    private func updatePhase() {
        guard isEnabled else {
            setPhase(.off)
            return
        }
        switch tracker.mode {
        case .waiting: setPhase(.listening)
        case .following: setPhase(.following)
        case .timedFallback: setPhase(.timedFallback)
        }
    }

    private func setPhase(_ newPhase: Phase) {
        if phase != newPhase {
            phase = newPhase
            phaseChangeCount += 1
        }
    }

    // MARK: Active speech

    private func recordSpeech(at timestamp: TimeInterval) {
        if let start = speechSegmentStartedAt, let last = lastSpeechAt {
            if timestamp - last > max(2, configuration.lostAfterSeconds) {
                activeSpeechDuration += max(0, last - start)
                speechSegmentStartedAt = timestamp
            }
        } else {
            speechSegmentStartedAt = timestamp
        }
        lastSpeechAt = timestamp
    }

    private func closeSpeechSegment() {
        if let start = speechSegmentStartedAt, let last = lastSpeechAt {
            activeSpeechDuration += max(0, last - start)
        }
        speechSegmentStartedAt = nil
        lastSpeechAt = nil
    }

    private func resetSession() {
        sessionStartedAt = nil
        lastHypothesisAt = nil
        activeSpeechDuration = 0
        speechSegmentStartedAt = nil
        lastSpeechAt = nil
        startTokenIndex = nil
        furthestTokenIndex = nil
    }

    // MARK: Streaming

    private func beginStreaming(language: SpeechLanguage, inputDeviceUID: String?) async throws {
        let devices = await Task.detached {
            AudioInputDevices.available()
        }.value
        let deviceID = inputDeviceUID.flatMap { uid in
            devices.first { $0.uid == uid }?.id
        }
        let stream = try await recognizer.start(
            language: language,
            inputDeviceID: deviceID
        )
        guard isEnabled else {
            await recognizer.stop()
            throw VoiceFollowFailure.cancelled
        }

        streamTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self, self.isEnabled else { return }
                    await self.ingest(text: event.text, at: event.timestamp, segment: event.segment)
                }
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                await self.handleStreamEnded(error: nil)
            } catch {
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                await self.handleStreamEnded(error: error)
            }
        }

        if runsLivenessTask {
            livenessTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.isEnabled else { return }
                    await self.tick(now: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
    }

    private func stopStreamingAndWait() async {
        let stream = streamTask
        let liveness = livenessTask
        streamTask = nil
        livenessTask = nil
        stream?.cancel()
        liveness?.cancel()
        await stream?.value
        await liveness?.value
        await recognizer.stop()
    }

    private func handleStreamEnded(error: Error?) async {
        guard isEnabled else { return }
        livenessTask?.cancel()
        livenessTask = nil
        streamTask = nil
        let failure = error.map(VoiceFollowFailure.from) ?? .recognitionLost
        lastFailure = failure
        closeSpeechSegment()
        setPhase(.timedFallback)
        onFailure?(failure)
        await recognizer.stop()
    }

    private func resetAfterFailedStart(_ failure: VoiceFollowFailure) async {
        isEnabled = false
        setPhase(.off)
        engine = nil
        document = nil
        currentLocation = nil
        confidence = 0
        tracker.reset()
        resetSession()
        lastFailure = failure
        await stopStreamingAndWait()
    }

    private func nextLifecycleGeneration() -> Int {
        lifecycleGeneration += 1
        return lifecycleGeneration
    }
}
