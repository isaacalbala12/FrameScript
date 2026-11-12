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
    case unknown

    var messageKey: String {
        switch self {
        case .unsupportedLanguage: "voiceFollow.error.unsupportedLanguage"
        case .onDeviceUnsupported: "voiceFollow.error.onDeviceUnsupported"
        case .permissionsDenied: "voiceFollow.error.permissions"
        case .noMicrophone: "voiceFollow.error.noMicrophone"
        case .recognitionUnavailable: "voiceFollow.error.recognitionUnavailable"
        case .recognitionLost: "voiceFollow.error.recognitionLost"
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
        case .audioDeviceUnavailable, .audioEngineFailure:
            return .noMicrophone
        case .recognitionFailed:
            return .recognitionLost
        case .alreadyRunning, .cancelled:
            return .unknown
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
/// It is deliberately independent from the scroll geometry: it publishes the
/// current `VoiceFollowLocation`, and the playback model turns that into a
/// content offset and feeds its smoother. This keeps the recognizer and the
/// follower testable without a window.
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
    private(set) var isEnabled = false
    private(set) var currentLocation: VoiceFollowLocation?
    private(set) var confidence: Double = 0
    private(set) var availableInputDevices: [AudioInputDevice] = []
    private(set) var lastFailure: VoiceFollowFailure?
    private(set) var document: VoiceFollowDocument?

    var onFailure: ((VoiceFollowFailure) -> Void)?
    var onSessionFinished: ((TeleprompterReadingSession) -> Void)?

    private let recognizer: any SpeechRecognizing
    private let configuration: SpeechFollowConfiguration
    private var follower: SpeechFollower?
    private var tracker = VoiceFollowModeTracker()
    private var streamTask: Task<Void, Never>?
    private var language: SpeechLanguage = .spanish
    private var inputDeviceUID: String?
    private var sessionStartedAt: TimeInterval?
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

    func refreshInputDevices() {
        availableInputDevices = AudioInputDevices.available()
    }

    // MARK: Lifecycle

    func start(
        document: VoiceFollowDocument,
        language: SpeechLanguage,
        startPosition: VoiceFollowPosition?,
        inputDeviceUID: String?
    ) async throws {
        guard !isEnabled else { return }
        lastFailure = nil
        phase = .preparing
        isEnabled = true
        self.document = document
        self.language = language
        self.inputDeviceUID = inputDeviceUID
        tracker.reset()
        confidence = 0
        sessionStartedAt = nil
        startTokenIndex = nil
        furthestTokenIndex = nil

        if recognizer is LiveSpeechRecognizer,
           !VoiceFollowCapabilities.supportsOnDeviceRecognition(language) {
            isEnabled = false
            phase = .off
            self.document = nil
            currentLocation = nil
            lastFailure = .onDeviceUnsupported
            throw VoiceFollowFailure.onDeviceUnsupported
        }

        let token = startPosition.flatMap { document.tokenIndex(for: $0) } ?? 0
        rebase(to: startPosition)
        startTokenIndex = token

        do {
            try await beginStreaming(language: language, inputDeviceUID: inputDeviceUID)
        } catch {
            isEnabled = false
            phase = .off
            follower = nil
            self.document = nil
            currentLocation = nil
            lastFailure = VoiceFollowFailure.from(error)
            throw lastFailure ?? .unknown
        }
        updatePhase()
    }

    func restart(inputDeviceUID: String?) async throws {
        guard isEnabled else { return }
        let previous = phase
        self.inputDeviceUID = inputDeviceUID
        await stopStreaming()
        try await beginStreaming(language: language, inputDeviceUID: inputDeviceUID)
        phase = previous == .off ? .listening : previous
    }

    func stop(now: TimeInterval, emitSession: Bool) {
        guard isEnabled || phase != .off else { return }
        if emitSession,
           let started = sessionStartedAt,
           let start = startTokenIndex,
           let furthest = furthestTokenIndex {
            let words = max(0, furthest - start + 1)
            let duration = max(0, now - started)
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
        phase = .off
        streamTask?.cancel()
        streamTask = nil
        Task { await recognizer.stop() }
        follower = nil
        document = nil
        currentLocation = nil
        confidence = 0
        tracker.reset()
        sessionStartedAt = nil
        startTokenIndex = nil
        furthestTokenIndex = nil
    }

    // MARK: Script updates

    func updateDocument(_ newDocument: VoiceFollowDocument, preserving position: VoiceFollowPosition?) {
        let oldDocument = document
        let oldLocation = currentLocation
        let oldStartPosition = startTokenIndex.flatMap { oldDocument?.position(atTokenIndex: $0) }
        let oldFurthestPosition = furthestTokenIndex.flatMap { oldDocument?.position(atTokenIndex: $0) }

        document = newDocument
        let target = position ?? oldLocation.map {
            VoiceFollowPosition(sceneID: $0.sceneID, characterOffset: $0.characterOffset)
        }
        rebase(to: target)

        if let oldStartPosition {
            startTokenIndex = newDocument.tokenIndex(for: oldStartPosition) ?? startTokenIndex
        }
        if let oldFurthestPosition {
            furthestTokenIndex = newDocument.tokenIndex(for: oldFurthestPosition) ?? furthestTokenIndex
        }
    }

    /// Re-anchor the follower at a reading position. Used when enabling voice
    /// in the middle of a script and when timed fallback starts (so a long
    /// silent stretch does not leave the follower hundreds of words behind).
    func rebase(to position: VoiceFollowPosition?) {
        guard let document else { return }
        let token: Int
        if let position, let resolved = document.tokenIndex(for: position) {
            token = resolved
        } else {
            token = min(max(0, startTokenIndex ?? 0), max(0, document.script.tokens.count - 1))
        }
        var follower = SpeechFollower(script: document.script, configuration: configuration)
        follower.seek(toToken: token)
        self.follower = follower
        if let location = document.location(forTokenIndex: token) {
            currentLocation = location
        }
    }

    // MARK: Events

    func ingest(text: String, at timestamp: TimeInterval, segment: Int? = nil) {
        guard isEnabled, var follower else { return }
        sessionStartedAt = sessionStartedAt ?? timestamp
        let state = follower.process(text: text, at: timestamp, segment: segment)
        self.follower = follower
        apply(state, at: timestamp)
    }

    func tick(now: TimeInterval) {
        guard isEnabled, var follower else { return }
        sessionStartedAt = sessionStartedAt ?? now
        let state = follower.tick(at: now)
        self.follower = follower
        apply(state, at: now)
    }

    private func apply(_ state: SpeechFollowState, at timestamp: TimeInterval) {
        confidence = state.confidence
        if let token = state.tokenIndex {
            if let location = document?.location(forTokenIndex: token) {
                currentLocation = location
                if state.confidence >= tracker.followConfidence, !state.isLost {
                    furthestTokenIndex = max(furthestTokenIndex ?? token, token)
                }
            }
        }
        _ = tracker.update(
            confidence: state.confidence,
            isLost: state.isLost,
            hasPosition: currentLocation != nil,
            at: timestamp
        )
        updatePhase()
    }

    private func updatePhase() {
        guard isEnabled else {
            phase = .off
            return
        }
        switch tracker.mode {
        case .waiting: phase = .listening
        case .following: phase = .following
        case .timedFallback: phase = .timedFallback
        }
    }

    // MARK: Streaming

    private func beginStreaming(language: SpeechLanguage, inputDeviceUID: String?) async throws {
        let deviceID = inputDeviceUID.flatMap { uid in
            AudioInputDevices.available().first { $0.uid == uid }?.id
        }
        let stream = try await recognizer.start(
            language: language,
            inputDeviceID: deviceID
        )
        streamTask = Task { @MainActor [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self, self.isEnabled else { return }
                    self.ingest(text: event.text, at: event.timestamp, segment: event.segment)
                }
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.handleStreamEnded()
            } catch {
                guard !Task.isCancelled, let self, self.isEnabled else { return }
                self.handleStreamEnded()
            }
        }
    }

    private func stopStreaming() async {
        streamTask?.cancel()
        streamTask = nil
        await recognizer.stop()
    }

    private func handleStreamEnded() {
        guard isEnabled else { return }
        streamTask = nil
        lastFailure = .recognitionLost
        phase = .timedFallback
        onFailure?(.recognitionLost)
        Task { await recognizer.stop() }
    }
}
