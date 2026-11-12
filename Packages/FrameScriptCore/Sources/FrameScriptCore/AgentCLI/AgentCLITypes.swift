import Foundation

/// The local, subscription-backed command line tools FrameScript can hand AI work to.
public enum AgentCLIKind: String, Sendable, Codable, CaseIterable, Hashable {
    /// T3 Code (`t3 thread start` / `t3 thread send`).
    case t3
    /// Claude Code (`claude -p`).
    case claude
    /// Codex CLI (`codex exec`).
    case codex

    /// The executable name used both for discovery and for diagnostics.
    public var executableName: String { rawValue }
}

/// Which provider instance/model a task should use.
///
/// For T3 both `providerInstanceID` and `modelSlug` are required: the CLI
/// rejects `--provider` without `--model` and vice versa.
public struct AgentCLIModelSelection: Sendable, Equatable, Hashable, Codable {
    public var kind: AgentCLIKind
    /// T3 provider instance id, for example `opencode`.
    public var providerInstanceID: String?
    /// Provider-specific model slug, for example `opencode-go/deepseek-v4.1-flash`.
    public var modelSlug: String?

    public init(kind: AgentCLIKind, providerInstanceID: String? = nil, modelSlug: String? = nil) {
        self.kind = kind
        self.providerInstanceID = providerInstanceID
        self.modelSlug = modelSlug
    }
}

/// One AI request. The prompt is always delivered on stdin, never as a command
/// line argument, so long scripts do not hit `ARG_MAX` and never appear in `ps`.
public struct AgentCLIRequest: Sendable, Equatable {
    public var prompt: String
    public var model: AgentCLIModelSelection
    public var title: String?
    /// Existing T3 thread to continue. Ignored by the Claude and Codex runners.
    public var threadID: String?
    public var workingDirectory: URL?
    /// Wall-clock budget for the CLI invocation. Defaults to three minutes.
    public var timeout: TimeInterval
    /// Per-stream capture cap. Output beyond it is drained and discarded.
    public var outputByteLimit: Int

    public init(
        prompt: String,
        model: AgentCLIModelSelection,
        title: String? = nil,
        threadID: String? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 180,
        outputByteLimit: Int = 8 * 1024 * 1024
    ) {
        self.prompt = prompt
        self.model = model
        self.title = title
        self.threadID = threadID
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
    }
}

/// A completed run.
public struct AgentCLIReply: Sendable, Equatable {
    public var provider: AgentCLIKind
    public var text: String
    /// T3 thread id, when the run went through T3.
    public var threadID: String?
    /// T3 run id, when reported by the CLI.
    public var runID: String?
    /// Claude session id or Codex thread id, when reported by the CLI.
    public var sessionID: String?
    /// The raw stdout JSON, kept for diagnostics and for future structured parsing.
    public var rawJSON: String?
    /// True when the stream cap was hit but the final bytes still contained a
    /// usable result (Codex JSONL). Whole-JSON formats throw instead.
    public var outputTruncated: Bool

    public init(
        provider: AgentCLIKind,
        text: String,
        threadID: String? = nil,
        runID: String? = nil,
        sessionID: String? = nil,
        rawJSON: String? = nil,
        outputTruncated: Bool = false
    ) {
        self.provider = provider
        self.text = text
        self.threadID = threadID
        self.runID = runID
        self.sessionID = sessionID
        self.rawJSON = rawJSON
        self.outputTruncated = outputTruncated
    }
}

/// The agent stopped to ask a question. The app shows the question and offers
/// "open in T3"; the T3 thread keeps running until the user answers it there.
public struct AgentCLIPendingQuestion: Sendable, Equatable {
    public var provider: AgentCLIKind
    public var threadID: String
    public var question: String
    /// Deep link from `t3 thread show --json`, e.g. `https://app.t3.codes/threads/...`.
    public var openInT3URL: URL?
    public var runID: String?
    public var rawJSON: String?

    public init(
        provider: AgentCLIKind = .t3,
        threadID: String,
        question: String,
        openInT3URL: URL? = nil,
        runID: String? = nil,
        rawJSON: String? = nil
    ) {
        self.provider = provider
        self.threadID = threadID
        self.question = question
        self.openInT3URL = openInT3URL
        self.runID = runID
        self.rawJSON = rawJSON
    }
}

/// The only two successful shapes: a reply, or a question that needs a human.
public enum AgentCLIResult: Sendable, Equatable {
    case completed(AgentCLIReply)
    case awaitingAnswer(AgentCLIPendingQuestion)

    public var reply: AgentCLIReply? {
        guard case let .completed(reply) = self else { return nil }
        return reply
    }

    public var pendingQuestion: AgentCLIPendingQuestion? {
        guard case let .awaitingAnswer(pending) = self else { return nil }
        return pending
    }

    public var provider: AgentCLIKind {
        switch self {
        case let .completed(reply): reply.provider
        case let .awaitingAnswer(pending): pending.provider
        }
    }

    /// The T3 thread id, for either a reply or a pending question.
    public var threadID: String? {
        switch self {
        case let .completed(reply): reply.threadID
        case let .awaitingAnswer(pending): pending.threadID
        }
    }
}

/// Anything that can answer an `AgentCLIRequest`.
public protocol AgentCLIRunner: Sendable {
    var kind: AgentCLIKind { get }
    func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult
}

extension AgentCLIRunner {
    /// Convenience for call sites that only have a prompt and a model.
    public func run(
        prompt: String,
        model: AgentCLIModelSelection,
        title: String? = nil,
        threadID: String? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 180
    ) async throws -> AgentCLIResult {
        try await run(
            AgentCLIRequest(
                prompt: prompt,
                model: model,
                title: title,
                threadID: threadID,
                workingDirectory: workingDirectory,
                timeout: timeout
            )
        )
    }
}

public enum AgentCLIError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case binaryNotFound(AgentCLIKind)
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)
    case cancelled
    /// Exit code 1 for T3, or a failed non-interactive Claude/Codex turn.
    case runFailed(threadID: String?, message: String, exitCode: Int32)
    case malformedOutput(exitCode: Int32, detail: String)
    /// The stdout cap was reached before a complete result could be parsed.
    case outputTruncated(limit: Int)
    case projectNotFound(String)
    case projectAlreadyExists(String)
    case projectNameLookupUnsupported(String)
    case serverUnavailable(String)
    case noProviderAvailable

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            return detail
        case let .binaryNotFound(kind):
            return "Could not find the \(kind.executableName) command. Install it or choose its location in Settings."
        case let .launchFailed(detail):
            return "Could not launch the AI command: \(detail)"
        case let .timedOut(seconds):
            return "The AI command took longer than \(Int(seconds.rounded())) s and was stopped."
        case .cancelled:
            return "The AI request was cancelled."
        case let .runFailed(threadID, message, _):
            if let threadID, !threadID.isEmpty {
                return "The AI run failed in thread \(threadID): \(message)"
            }
            return "The AI run failed: \(message)"
        case let .malformedOutput(_, detail):
            return "The AI command returned output FrameScript could not read: \(detail)"
        case let .outputTruncated(limit):
            return "The AI command produced more than \(limit) bytes of output and the result was cut off. Increase the output limit or ask for a shorter answer."
        case let .projectNotFound(identifier):
            return "No T3 Code project matches '\(identifier)'. Choose a T3 project id or folder in Settings."
        case let .projectAlreadyExists(path):
            return "A T3 Code project already exists for '\(path)'."
        case let .projectNameLookupUnsupported(detail):
            return detail
        case let .serverUnavailable(detail):
            return "T3 Code is not reachable: \(detail)"
        case .noProviderAvailable:
            return "No AI command is available. Install t3, claude or codex, or configure their paths in Settings."
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
