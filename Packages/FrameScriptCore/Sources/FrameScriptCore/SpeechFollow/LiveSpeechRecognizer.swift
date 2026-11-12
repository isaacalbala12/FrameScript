import AVFoundation
import CoreAudio
import Foundation
import Speech

/// Combined status of the two permissions the speech follower needs.
public struct SpeechRecognitionPermissions: Sendable, Equatable {
    public let speech: SpeechRecognitionAuthorization
    public let microphone: SpeechRecognitionAuthorization

    public init(
        speech: SpeechRecognitionAuthorization,
        microphone: SpeechRecognitionAuthorization
    ) {
        self.speech = speech
        self.microphone = microphone
    }

    public var isGranted: Bool {
        speech == .authorized && microphone == .authorized
    }
}

public enum SpeechRecognitionAuthorization: String, Sendable, Codable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// Streaming hypothesis from the live recognizer.
public struct SpeechRecognitionEvent: Sendable, Equatable {
    /// Full transcript of the current recognition segment (not a delta).
    /// Speech recognition tasks restart roughly once a minute, so `segment`
    /// changes and `text` starts again from empty.
    public let text: String
    /// True for the final result of the current segment.
    public let isFinal: Bool
    /// Increases every time the underlying SFSpeechRecognitionTask is replaced.
    public let segment: Int
    /// Monotonic host uptime when the event was produced.
    public let timestamp: TimeInterval
}

public enum SpeechRecognitionError: Error, Sendable, Equatable {
    case speechPermissionDenied
    case microphonePermissionDenied
    case localeUnsupported(String)
    case recognizerUnavailable
    case alreadyRunning
    case audioDeviceUnavailable(AudioDeviceID)
    case audioEngineFailure(String)
    case recognitionFailed(String)
}

extension SpeechRecognitionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "Speech recognition permission was denied."
        case .microphonePermissionDenied:
            "Microphone permission was denied."
        case .localeUnsupported(let identifier):
            "Speech recognition does not support the locale \(identifier)."
        case .recognizerUnavailable:
            "Speech recognition is not available right now."
        case .alreadyRunning:
            "Speech recognition is already running."
        case .audioDeviceUnavailable(let id):
            "The requested audio input device (\(id)) is not available."
        case .audioEngineFailure(let description):
            "The audio engine failed: \(description)"
        case .recognitionFailed(let description):
            "Speech recognition failed: \(description)"
        }
    }
}

/// Abstraction over the live microphone pipeline so the app can inject a fake
/// in previews, and so tests never need a microphone.
public protocol SpeechRecognizing: Sendable {
    func permissions() async -> SpeechRecognitionPermissions
    func requestPermissions() async -> SpeechRecognitionPermissions
    func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error>
    func stop() async
}

public extension SpeechRecognizing {
    func start(language: SpeechLanguage) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        try await start(language: language, inputDeviceID: nil)
    }
}

/// One input device that can be selected for speech recognition.
public struct AudioInputDevice: Sendable, Equatable, Hashable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String

    public init(id: AudioDeviceID, name: String, uid: String) {
        self.id = id
        self.name = name
        self.uid = uid
    }
}

/// CoreAudio enumeration for the input-device picker in Settings.
public enum AudioInputDevices {
    public static func available() -> [AudioInputDevice] {
        deviceIDs()
            .filter(hasInputChannels)
            .compactMap { id in
                guard let name = stringProperty(id, selector: kAudioObjectPropertyName),
                      let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else {
                    return nil
                }
                return AudioInputDevice(id: id, name: name, uid: uid)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else {
            return []
        }
        return ids
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeUnretainedValue() as String
    }
}

public struct LiveSpeechRecognizerConfiguration: Sendable, Equatable {
    /// Use on-device recognition when the installed language model supports
    /// it. F9 requires this for es-ES and en-US.
    public var prefersOnDeviceRecognition: Bool = true
    /// Proactive restart interval. Apple ends recognition tasks around one
    /// minute, so the default replaces the task at 50 s while audio keeps
    /// flowing through the same engine tap.
    public var segmentDuration: TimeInterval = 50
    /// Delay before restarting after an SFSpeechRecognitionTask ends by itself.
    public var segmentRestartDelay: TimeInterval = 0.05
    /// Give up after this many consecutive recognition errors without text.
    public var maximumConsecutiveRestartFailures: Int = 5
    public var audioBufferSize: AVAudioFrameCount = 2_048

    public init() {}
}

/// Live `SFSpeechRecognizer` microphone pipeline.
///
/// Kept behind ``SpeechRecognizing`` and out of the unit tests: CI has no
/// microphone. The audio engine stays running across recognition-task
/// restarts, so only the transcript resets, not the microphone stream.
public actor LiveSpeechRecognizer: SpeechRecognizing {
    public let configuration: LiveSpeechRecognizerConfiguration

    private var engine: AVAudioEngine?
    private var requestBox: RecognitionRequestBox?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation?
    private var restartTimerTask: Task<Void, Never>?
    private var isRunning = false
    private var tapInstalled = false
    private var generation: UInt64 = 0
    private var segment = 0
    private var consecutiveRestartFailures = 0
    private var restartScheduled = false

    public init(configuration: LiveSpeechRecognizerConfiguration = LiveSpeechRecognizerConfiguration()) {
        self.configuration = configuration
    }

    public func permissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(
            speech: Self.speechAuthorization(SFSpeechRecognizer.authorizationStatus()),
            microphone: Self.microphoneAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
        )
    }

    public func requestPermissions() async -> SpeechRecognitionPermissions {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<SpeechRecognitionAuthorization, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.speechAuthorization(status))
            }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        return await permissions()
    }

    public func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        guard !isRunning else { throw SpeechRecognitionError.alreadyRunning }

        let permissions = await requestPermissions()
        guard permissions.speech == .authorized else {
            throw SpeechRecognitionError.speechPermissionDenied
        }
        guard permissions.microphone == .authorized else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }

        let locale = Locale(identifier: language.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechRecognitionError.localeUnsupported(language.localeIdentifier)
        }
        guard recognizer.isAvailable else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation = pair.continuation
        self.recognizer = recognizer
        isRunning = true
        segment = 0
        consecutiveRestartFailures = 0
        generation &+= 1

        do {
            try startAudioEngine(inputDeviceID: inputDeviceID)
            beginRecognitionTask()
        } catch {
            tearDown(finishWith: nil)
            throw error
        }

        return pair.stream
    }

    public func stop() async {
        tearDown(finishWith: nil)
    }

    // MARK: - Audio

    private func startAudioEngine(inputDeviceID: AudioDeviceID?) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let inputDeviceID {
            try Self.selectInputDevice(inputDeviceID, on: inputNode)
        }

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechRecognitionError.audioEngineFailure("The input device reports no usable format.")
        }

        let box = RecognitionRequestBox()
        inputNode.installTap(
            onBus: 0,
            bufferSize: configuration.audioBufferSize,
            format: format
        ) { buffer, _ in
            box.append(buffer)
        }
        tapInstalled = true

        self.engine = engine
        requestBox = box

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw SpeechRecognitionError.audioEngineFailure(error.localizedDescription)
        }
    }

    private static func selectInputDevice(
        _ deviceID: AudioDeviceID,
        on inputNode: AVAudioInputNode
    ) throws {
        guard let audioUnit = inputNode.audioUnit else {
            throw SpeechRecognitionError.audioDeviceUnavailable(deviceID)
        }
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw SpeechRecognitionError.audioDeviceUnavailable(deviceID)
        }
    }

    // MARK: - Recognition task

    private func beginRecognitionTask() {
        guard isRunning, let recognizer, let requestBox else { return }

        restartTimerTask?.cancel()
        restartTimerTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if configuration.prefersOnDeviceRecognition, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        requestBox.setRequest(request)

        generation &+= 1
        let currentGeneration = generation
        segment += 1
        let currentSegment = segment

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDescription = error?.localizedDescription
            Task { [weak self] in
                await self?.handleRecognition(
                    text: text,
                    isFinal: isFinal,
                    errorDescription: errorDescription,
                    generation: currentGeneration,
                    segment: currentSegment
                )
            }
        }

        scheduleProactiveRestart()
    }

    private func scheduleProactiveRestart() {
        restartTimerTask?.cancel()
        guard configuration.segmentDuration > 0 else { return }
        let nanoseconds = UInt64(configuration.segmentDuration * 1_000_000_000)
        restartTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.restartSegmentProactively()
        }
    }

    private func restartSegmentProactively() {
        guard isRunning, !restartScheduled else { return }
        recognitionTask?.finish()
        recognitionTask = nil
        beginRecognitionTask()
    }

    private func handleRecognition(
        text: String?,
        isFinal: Bool,
        errorDescription: String?,
        generation callbackGeneration: UInt64,
        segment callbackSegment: Int
    ) {
        guard isRunning, callbackGeneration == generation else { return }

        if let text, !text.isEmpty {
            consecutiveRestartFailures = 0
            continuation?.yield(
                SpeechRecognitionEvent(
                    text: text,
                    isFinal: isFinal,
                    segment: callbackSegment,
                    timestamp: ProcessInfo.processInfo.systemUptime
                )
            )
        }

        if let errorDescription {
            consecutiveRestartFailures += 1
            if consecutiveRestartFailures > configuration.maximumConsecutiveRestartFailures {
                fail(.recognitionFailed(errorDescription))
            } else {
                scheduleRestartAfterTaskEnded()
            }
        } else if isFinal {
            scheduleRestartAfterTaskEnded()
        }
    }

    private func scheduleRestartAfterTaskEnded() {
        guard isRunning, !restartScheduled else { return }
        restartScheduled = true
        let delay = configuration.segmentRestartDelay
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.performScheduledRestart()
        }
    }

    private func performScheduledRestart() {
        restartScheduled = false
        guard isRunning else { return }
        recognitionTask = nil
        beginRecognitionTask()
    }

    private func fail(_ error: SpeechRecognitionError) {
        tearDown(finishWith: error)
    }

    private func tearDown(finishWith error: SpeechRecognitionError?) {
        isRunning = false
        generation &+= 1
        restartScheduled = false
        restartTimerTask?.cancel()
        restartTimerTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil

        requestBox?.endAudio()
        requestBox = nil

        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
        }
        engine = nil

        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
        continuation = nil
    }

    private static func speechAuthorization(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> SpeechRecognitionAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    private static func microphoneAuthorization(
        _ status: AVAuthorizationStatus
    ) -> SpeechRecognitionAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }
}

/// Thread-safe bridge between the actor that swaps recognition requests and
/// the real-time audio tap that appends buffers.
private final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func setRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func endAudio() {
        lock.lock()
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.endAudio()
    }
}
