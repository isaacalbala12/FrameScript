import CoreAudio
import Foundation
import FrameScriptCore

// MARK: - Simulated hypotheses

/// One line of a simulated recognizer transcript.
struct SimulatedHypothesis: Equatable, Sendable {
    let timestamp: TimeInterval
    let text: String
}

/// Parses the debug transcript used to exercise voice following without a
/// microphone.
///
/// Format: one hypothesis per line, timestamp first, then the full partial
/// transcript. Timestamps accept `12.5`, `00:12.5` and `1:02:03.5`; lines
/// starting with `#` and blank lines are ignored.
enum SimulatedHypothesisFile {
    static func parse(_ contents: String) -> [SimulatedHypothesis] {
        var result: [SimulatedHypothesis] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let stamp = String(trimmed[..<separator])
            let text = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let timestamp = parseTimestamp(stamp) else { continue }
            result.append(SimulatedHypothesis(timestamp: timestamp, text: text))
        }
        return result
    }

    static func parseTimestamp(_ raw: String) -> TimeInterval? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("s") || text.hasSuffix("S") {
            text.removeLast()
        }
        text = text.replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count > 1 {
            guard parts.count <= 3 else { return nil }
            var total: TimeInterval = 0
            for part in parts {
                guard let value = Double(part), value >= 0, value.isFinite else { return nil }
                total = total * 60 + value
            }
            return total
        }
        guard let value = Double(text), value >= 0, value.isFinite else { return nil }
        return value
    }
}

#if DEBUG
/// Debug recognizer that replays a transcript file in real time. It reports
/// both permissions as granted, so it never touches TCC, the microphone or the
/// network.
actor SimulatedSpeechRecognizer: SpeechRecognizing {
    let hypotheses: [SimulatedHypothesis]
    let playbackSpeed: Double

    private var task: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<SpeechRecognitionEvent, Error>.Continuation?

    init(hypotheses: [SimulatedHypothesis], playbackSpeed: Double = 1) {
        self.hypotheses = hypotheses
        self.playbackSpeed = max(0.1, playbackSpeed)
    }

    func permissions() async -> SpeechRecognitionPermissions {
        SpeechRecognitionPermissions(speech: .authorized, microphone: .authorized)
    }

    func requestPermissions() async -> SpeechRecognitionPermissions {
        await permissions()
    }

    func start(
        language: SpeechLanguage,
        inputDeviceID: AudioDeviceID?
    ) async throws -> AsyncThrowingStream<SpeechRecognitionEvent, Error> {
        await stop()
        let pair = AsyncThrowingStream<SpeechRecognitionEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation = pair.continuation

        let hypotheses = self.hypotheses
        let speed = self.playbackSpeed
        let continuation = pair.continuation
        task = Task {
            let startedAt = ProcessInfo.processInfo.systemUptime
            for hypothesis in hypotheses {
                let deadline = startedAt + hypothesis.timestamp / speed
                let delay = deadline - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                continuation.yield(
                    SpeechRecognitionEvent(
                        text: hypothesis.text,
                        isFinal: false,
                        segment: 1,
                        timestamp: ProcessInfo.processInfo.systemUptime
                    )
                )
            }
            // Keep the stream open like a live recognizer that is still
            // listening after the last partial transcript.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return pair.stream
    }

    func stop() async {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Hidden debug entry point. The app accepts:
///
///   --framescript-voice-follow-sim <file>   replay hypotheses from a file
///   --framescript-voice-follow-auto         enable voice follow on launch
///
/// The environment variable `FRAMESCRIPT_VOICE_FOLLOW_SIM` works too, which is
/// convenient when launching the binary directly.
enum VoiceFollowDebugConfiguration {
    static func simulatedHypotheses() -> [SimulatedHypothesis]? {
        let arguments = ProcessInfo.processInfo.arguments
        var path: String?
        if let index = arguments.firstIndex(of: "--framescript-voice-follow-sim"),
           index + 1 < arguments.count {
            path = arguments[index + 1]
        }
        if path == nil {
            path = ProcessInfo.processInfo.environment["FRAMESCRIPT_VOICE_FOLLOW_SIM"]
        }
        guard let path,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let hypotheses = SimulatedHypothesisFile.parse(contents)
        return hypotheses.isEmpty ? nil : hypotheses
    }

    static var autoStart: Bool {
        ProcessInfo.processInfo.arguments.contains("--framescript-voice-follow-auto")
    }

    static func makeRecognizer() -> (any SpeechRecognizing)? {
        guard let hypotheses = simulatedHypotheses() else { return nil }
        return SimulatedSpeechRecognizer(hypotheses: hypotheses)
    }
}
#endif
