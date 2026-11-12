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

    public init(
        text: String,
        isFinal: Bool,
        segment: Int,
        timestamp: TimeInterval
    ) {
        self.text = text
        self.isFinal = isFinal
        self.segment = segment
        self.timestamp = timestamp
    }
}

public enum SpeechRecognitionError: Error, Sendable, Equatable {
    case speechPermissionDenied
    case microphonePermissionDenied
    case localeUnsupported(String)
    case recognizerUnavailable
    case alreadyRunning
    case cancelled
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
        case .cancelled:
            "Speech recognition was cancelled."
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
        return value.takeRetainedValue() as String
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
    /// Delay before retrying after a recognition error (not after a normal
    /// end-of-task, which restarts immediately).
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
/// restarts, and the request tap is swapped to the new task before the old one
/// is finished, so no microphone buffers are lost at the boundary.
public actor LiveSpeechRecognizer: SpeechRecognizing {
    public let configuration: LiveSpeechRecognizerConfiguration

    private struct RecognitionCallback: Sendable {
        let text: String?
        let isFinal: Bool
        let errorDescription: String?
        let generation: UInt64
        let segment: Int
    }

    private var engine: AVAudioEngine?
    private var requestBox: RecognitionRequestBox?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation?
    private var rawEventContinuation: AsyncStream<RecognitionCallback>.Continuation?
    private var eventPump: Task<Void, Never>?
    private var restartTimerTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var isRunning = false
    private var isStarting = false
    private var tapInstalled = false
    private var generation: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var segment = 0
    private var lastProcessedSegment = 0
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
        // The actor yields at `await requestPermissions()`. Mark the start in
        // progress before that point so a second start cannot install a second
        // engine and leak a stream.
        guard !isRunning, !isStarting else {
            throw SpeechRecognitionError.alreadyRunning
        }
        isStarting = true
        let startLifecycle = lifecycleGeneration

        do {
            let permissions = await requestPermissions()
            guard isStarting, startLifecycle == lifecycleGeneration else {
                isStarting = false
                throw SpeechRecognitionError.cancelled
            }
            guard permissions.speech == .authorized else {
                isStarting = false
                throw SpeechRecognitionError.speechPermissionDenied
            }
            guard permissions.microphone == .authorized else {
                isStarting = false
                throw SpeechRecognitionError.microphonePermissionDenied
            }

            let locale = Locale(identifier: language.localeIdentifier)
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                isStarting = false
                throw SpeechRecognitionError.localeUnsupported(language.localeIdentifier)
            }

            let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream(
                bufferingPolicy: .bufferingNewest(32)
            )
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }

            let rawPair = AsyncStream<RecognitionCallback>.makeStream(
                bufferingPolicy: .unbounded
            )

            continuation = pair.continuation
            rawEventContinuation = rawPair.continuation
            eventPump = Task { [weak self] in
                for await callback in rawPair.stream {
                    guard !Task.isCancelled else { break }
                    await self?.handleRecognitionCallback(callback)
                }
            }

            self.recognizer = recognizer
            isRunning = true
            isStarting = false
            segment = 0
            lastProcessedSegment = 0
            consecutiveRestartFailures = 0
            restartScheduled = false
            generation &+= 1

            do {
                try startAudioEngine(inputDeviceID: inputDeviceID)
                beginRecognitionTask()
            } catch {
                tearDown(finishWith: nil)
                throw error
            }

            return pair.stream
        } catch {
            isStarting = false
            throw error
        }
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        isStarting = false
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
        guard isRunning, !isStarting, let recognizer, let requestBox else { return }

        restartTimerTask?.cancel()
        restartTimerTask = nil
        restartTask?.cancel()
        restartTask = nil
        restartScheduled = false

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if configuration.prefersOnDeviceRecognition, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        // Swap the tap to the new request before ending the old task, so audio
        // produced during the boundary is not appended to a finished request.
        let oldTask = recognitionTask
        let oldRequest = requestBox.swapRequest(request)
        generation &+= 1
        let currentGeneration = generation
        segment += 1
        let currentSegment = segment
        let rawContinuation = rawEventContinuation

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            rawContinuation?.yield(
                RecognitionCallback(
                    text: result?.bestTranscription.formattedString,
                    isFinal: result?.isFinal ?? false,
                    errorDescription: error?.localizedDescription,
                    generation: currentGeneration,
                    segment: currentSegment
                )
            )
        }

        oldRequest?.endAudio()
        oldTask?.finish()

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
        beginRecognitionTask()
    }

    private func handleRecognitionCallback(_ callback: RecognitionCallback) {
        guard isRunning else { return }

        let isCurrent = callback.generation == generation
        let isPreviousSegmentFinal = callback.isFinal
            && callback.generation &+ 1 == generation
        guard isCurrent || isPreviousSegmentFinal else { return }
        guard callback.segment >= lastProcessedSegment else { return }

        if let text = callback.text, !text.isEmpty {
            lastProcessedSegment = callback.segment
            consecutiveRestartFailures = 0
            continuation?.yield(
                SpeechRecognitionEvent(
                    text: text,
                    isFinal: callback.isFinal,
                    segment: callback.segment,
                    timestamp: ProcessInfo.processInfo.systemUptime
                )
            )
        }

        // A final result from the previous segment is delivered in order when
        // possible, but it never drives the lifecycle of the new task.
        guard isCurrent else { return }

        if let errorDescription = callback.errorDescription {
            consecutiveRestartFailures += 1
            if consecutiveRestartFailures > configuration.maximumConsecutiveRestartFailures {
                fail(.recognitionFailed(errorDescription))
            } else {
                scheduleRestartAfterTaskEnded()
            }
        } else if callback.isFinal {
            // Normal end of a recognition task (the ~1 minute limit): restart
            // immediately, with the request swap already done in begin.
            beginRecognitionTask()
        }
    }

    private func scheduleRestartAfterTaskEnded() {
        guard isRunning, !restartScheduled else { return }
        restartScheduled = true
        let delay = configuration.segmentRestartDelay
        let session = lifecycleGeneration
        let recognitionGeneration = generation
        restartTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.performScheduledRestart(
                session: session,
                recognitionGeneration: recognitionGeneration
            )
        }
    }

    private func performScheduledRestart(
        session: UInt64,
        recognitionGeneration: UInt64
    ) {
        guard isRunning,
              session == lifecycleGeneration,
              recognitionGeneration == generation else {
            return
        }
        restartScheduled = false
        restartTask = nil
        beginRecognitionTask()
    }

    private func fail(_ error: SpeechRecognitionError) {
        tearDown(finishWith: error)
    }

    private func tearDown(finishWith error: SpeechRecognitionError?) {
        isRunning = false
        isStarting = false
        lifecycleGeneration &+= 1
        generation &+= 1
        restartScheduled = false
        restartTimerTask?.cancel()
        restartTimerTask = nil
        restartTask?.cancel()
        restartTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil

        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            engine.stop()
        }
        engine = nil
        // Removing the tap first guarantees no new buffers are produced.
        requestBox?.endAudio()
        requestBox = nil

        rawEventContinuation?.finish()
        rawEventContinuation = nil
        eventPump?.cancel()
        eventPump = nil

        let publicContinuation = continuation
        continuation = nil
        if let error {
            publicContinuation?.finish(throwing: error)
        } else {
            publicContinuation?.finish()
        }
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

    func swapRequest(
        _ newRequest: SFSpeechAudioBufferRecognitionRequest?
    ) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        let old = request
        request = newRequest
        lock.unlock()
        return old
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Hold the lock through append: endAudio() must not finalize a request
        // while a buffer is still being appended.
        lock.lock()
        request?.append(buffer)
        lock.unlock()
    }

    func endAudio() {
        lock.lock()
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.endAudio()
    }
}
