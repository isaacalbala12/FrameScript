import AVFoundation
import Foundation
import FrameScriptCore

// MARK: - Client seam

/// The slice of `OBSClient` that recording needs.
///
/// Tests inject a fake actor instead of opening a socket, and the app keeps the
/// real `OBSClient` behind this protocol so a future obs-websocket change only
/// touches the Core adapter.
protocol OBSRecordingClient: Sendable {
    var connectionStates: AsyncStream<OBSConnectionState> { get }
    var events: AsyncStream<OBSEvent> { get }
    func currentConnectionState() async -> OBSConnectionState
    func connect(config: OBSConnectionConfig) async throws
    func disconnect() async
    func getSceneList() async throws -> OBSSceneList
    func setCurrentProgramScene(name: String) async throws
    func startRecord() async throws
    func stopRecord() async throws -> String
    func getRecordStatus() async throws -> OBSRecordStatus
}

extension OBSClient: OBSRecordingClient {
    func currentConnectionState() async -> OBSConnectionState {
        connectionState
    }
}

// MARK: - Issues

/// A user-facing recording problem. Every case has a localized title and an
/// actionable explanation in English, Spanish and Russian.
enum RecordingIssue: Error, Equatable, Sendable {
    case notConnected
    case busy
    case obsNotRunning(host: String, port: Int)
    case authenticationRequired
    case authenticationFailed
    case connectionTimeout
    case unsupportedRPCVersion
    case connectionFailed(String)
    case startFailed(String)
    case stopFailed(String)
    case connectionLost
    case obsSceneSwitchFailed(String)
    case noScene
    case sceneDeleted
    case fileUnavailable
    case generic(String)

    enum Operation {
        case connect
        case start
        case stop
    }

    static func from(_ error: Error, operation: Operation) -> RecordingIssue {
        if let issue = error as? RecordingIssue { return issue }
        guard let error = error as? OBSError else {
            let detail = error.localizedDescription
            switch operation {
            case .connect: return .connectionFailed(detail)
            case .start: return .startFailed(detail)
            case .stop: return .stopFailed(detail)
            }
        }
        switch error {
        case .notConnected, .disconnected:
            return .connectionLost
        case let .obsNotRunning(host, port):
            return .obsNotRunning(host: host, port: port)
        case .connectionTimeout:
            return .connectionTimeout
        case .authenticationRequired:
            return .authenticationRequired
        case .authenticationFailed:
            return .authenticationFailed
        case .unsupportedRPCVersion:
            return .unsupportedRPCVersion
        case let .connectionFailed(detail):
            return .connectionFailed(detail)
        case let .requestFailed(_, _, comment):
            let detail = comment ?? error.localizedDescription
            switch operation {
            case .connect: return .connectionFailed(detail)
            case .start: return .startFailed(detail)
            case .stop: return .stopFailed(detail)
            }
        case .requestTimeout:
            return operation == .stop ? .stopFailed(error.localizedDescription) : .startFailed(error.localizedDescription)
        case let .handshakeFailed(detail), let .protocolViolation(detail):
            return .connectionFailed(detail)
        case .sessionInvalidated, .clientShutdown, .transportClosed:
            return .connectionLost
        }
    }

    func message(language: AppLanguage) -> String {
        switch self {
        case .notConnected:
            L10n.tr("recording.error.notConnected", language: language)
        case .busy:
            L10n.tr("recording.error.busy", language: language)
        case let .obsNotRunning(host, port):
            String(
                format: L10n.tr("recording.error.notRunning", language: language),
                host,
                port
            )
        case .authenticationRequired:
            L10n.tr("recording.error.authenticationRequired", language: language)
        case .authenticationFailed:
            L10n.tr("recording.error.authenticationFailed", language: language)
        case .connectionTimeout:
            L10n.tr("recording.error.timeout", language: language)
        case .unsupportedRPCVersion:
            L10n.tr("recording.error.rpcVersion", language: language)
        case let .connectionFailed(detail):
            String(
                format: L10n.tr("recording.error.connectionFailed", language: language),
                detail
            )
        case let .startFailed(detail):
            String(
                format: L10n.tr("recording.error.startFailed", language: language),
                detail
            )
        case let .stopFailed(detail):
            String(
                format: L10n.tr("recording.error.stopFailed", language: language),
                detail
            )
        case .connectionLost:
            L10n.tr("recording.error.connectionLost", language: language)
        case let .obsSceneSwitchFailed(name):
            String(
                format: L10n.tr("recording.error.obsSceneSwitchFailed", language: language),
                name
            )
        case .noScene:
            L10n.tr("recording.error.noScene", language: language)
        case .sceneDeleted:
            L10n.tr("recording.error.sceneDeleted", language: language)
        case .fileUnavailable:
            L10n.tr("recording.file.missing", language: language)
        case let .generic(detail):
            String(
                format: L10n.tr("recording.error.generic", language: language),
                detail
            )
        }
    }

    /// A second line that tells the user exactly what to do, when the fix is
    /// outside FrameScript.
    func recoveryHint(language: AppLanguage) -> String? {
        switch self {
        case .obsNotRunning:
            L10n.tr("recording.error.notRunningHint", language: language)
        case .authenticationRequired, .authenticationFailed:
            L10n.tr("recording.error.passwordHint", language: language)
        case .connectionLost:
            L10n.tr("recording.error.connectionLostHint", language: language)
        default:
            nil
        }
    }
}

// MARK: - Phase

enum RecordingPhase: Equatable, Sendable {
    case idle
    case countdown(Int)
    case starting
    case recording(startedAt: Date)
    case stopping

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .idle: false
        case .countdown, .starting, .recording, .stopping: true
        }
    }

    var countdownValue: Int? {
        if case let .countdown(value) = self { return value }
        return nil
    }
}

// MARK: - Pure take rules

enum TakeNumbering {
    /// Next take number for one scene and one language: the maximum existing
    /// number plus one, ignoring numbers used by other languages.
    static func nextNumber(existing: [Take], languageCode: String) -> Int {
        let normalized = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let highest = existing
            .filter {
                $0.languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
            }
            .map(\.number)
            .max() ?? 0
        return highest + 1
    }
}

enum TakeFactory {
    /// Builds a take exactly as F10 describes it: number, start time, duration,
    /// file path, the text that was read and its stable hash.
    static func makeTake(
        existing: [Take],
        sceneText: String,
        languageCode: String,
        startedAt: Date,
        duration: TimeInterval,
        filePath: String,
        bookmarkData: Data? = nil,
        rating: TakeRating = .unrated,
        note: String = ""
    ) -> Take {
        Take(
            number: TakeNumbering.nextNumber(existing: existing, languageCode: languageCode),
            startedAt: startedAt,
            duration: max(0, duration),
            filePath: filePath,
            bookmarkData: bookmarkData,
            rating: rating,
            note: note,
            languageCode: languageCode,
            readText: sceneText,
            sceneTextHash: FrameScriptDocument.TextHash.hash(sceneText)
        )
    }
}

enum TakeFileProbe {
    /// Reads a recording's duration from the file OBS wrote. Returns `nil` when
    /// the file is missing, unreadable or has no finite positive duration so
    /// callers can fall back to the measured elapsed time.
    static func duration(atPath path: String) async -> TimeInterval? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return seconds
        } catch {
            return nil
        }
    }
}
