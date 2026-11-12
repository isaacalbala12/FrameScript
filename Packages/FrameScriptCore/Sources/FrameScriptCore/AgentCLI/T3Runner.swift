import Foundation

/// A T3 Code project, identified either by its id or by a folder inside it.
public struct T3ProjectReference: Sendable, Equatable, Hashable, Codable {
    public var id: String?
    public var path: String?
    /// Display name. Kept for Settings and for project creation; the CLI
    /// cannot resolve a project by name.
    public var name: String?

    public init(id: String? = nil, path: String? = nil, name: String? = nil) {
        self.id = id
        self.path = path
        self.name = name
    }

    /// The value accepted by `t3 thread start` / `t3 thread list --project`.
    public var identifier: String? {
        id?.nilIfBlank ?? path?.nilIfBlank
    }
}

public struct T3Configuration: Sendable, Equatable {
    public var executable: URL
    public var project: T3ProjectReference
    /// Passed as `--base-dir`; lets the app share the desktop app's data folder.
    public var baseDirectory: URL?
    public var defaultTimeout: TimeInterval

    public init(
        executable: URL,
        project: T3ProjectReference,
        baseDirectory: URL? = nil,
        defaultTimeout: TimeInterval = 180
    ) {
        self.executable = executable
        self.project = project
        self.baseDirectory = baseDirectory
        self.defaultTimeout = defaultTimeout
    }
}

/// Runs prompts through `t3 thread start` / `t3 thread send`.
///
/// The CLI contract this implements, verified against t3
/// v0.1.10-nightly.20261112.4580:
///
///     t3 thread start <project|path> - --provider <id> --model <slug> \
///         --title <title> --wait --json
///     t3 thread send <thread> - --wait --json
///
/// Both print `{threadId, runId, status, reply, error}` on stdout when
/// `--wait --json` is used. Exit 0 = completed, 1 = run failed, 2 = the agent
/// is waiting for a human answer.
///
/// Cancelling only stops waiting locally (the process is terminated); the T3
/// run may keep going, which is why D2 shows a warning and discards the result.
public struct T3Runner: AgentCLIRunner {
    public let kind: AgentCLIKind = .t3
    public var configuration: T3Configuration
    private let launcher: any AgentProcessLaunching

    public init(
        configuration: T3Configuration,
        launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
    ) {
        self.configuration = configuration
        self.launcher = launcher
    }

    public func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        guard let prompt = request.prompt.nilIfBlank else {
            throw AgentCLIError.invalidConfiguration("The AI prompt is empty.")
        }

        let threadID = request.threadID?.nilIfBlank
        let arguments: [String]
        if let threadID {
            arguments = sendArguments(threadID: threadID)
        } else {
            arguments = try startArguments(for: request.model, title: request.title)
        }

        let processRequest = AgentProcessRequest(
            executableURL: configuration.executable,
            arguments: arguments,
            standardInput: Data(prompt.utf8),
            currentDirectoryURL: request.workingDirectory,
            timeout: effectiveTimeout(request.timeout),
            outputByteLimit: request.outputByteLimit
        )
        let output = try await launcher.launch(processRequest)
        let envelope = Self.decodeRunEnvelope(output.standardOutputText)
        let stderr = output.standardErrorSummary

        switch output.exitCode {
        case 0:
            guard let envelope else {
                throw AgentCLIError.malformedOutput(
                    exitCode: 0,
                    detail: "Expected a JSON object with threadId/status/reply."
                )
            }
            if envelope.status == "waiting" {
                return await pendingResult(
                    threadID: envelope.threadId,
                    runID: envelope.runId,
                    rawJSON: output.standardOutputText,
                    fallbackQuestion: stderr
                )
            }
            guard envelope.status == "completed" else {
                throw AgentCLIError.runFailed(
                    threadID: envelope.threadId,
                    message: Self.failureMessage(
                        status: envelope.status,
                        error: envelope.error,
                        stderr: stderr
                    ),
                    exitCode: 0
                )
            }
            guard let reply = envelope.reply else {
                throw AgentCLIError.malformedOutput(
                    exitCode: 0,
                    detail: "The run completed without a reply."
                )
            }
            return .completed(
                AgentCLIReply(
                    provider: .t3,
                    text: reply,
                    threadID: envelope.threadId,
                    runID: envelope.runId,
                    rawJSON: output.standardOutputText
                )
            )

        case 2:
            guard let envelope else {
                throw AgentCLIError.malformedOutput(
                    exitCode: 2,
                    detail: "Exit code 2 means the agent needs an answer, but the thread id was missing."
                )
            }
            return await pendingResult(
                threadID: envelope.threadId,
                runID: envelope.runId,
                rawJSON: output.standardOutputText,
                fallbackQuestion: stderr
            )

        default:
            if envelope == nil {
                if stderr.contains("No T3 Code project matches"),
                   let identifier = configuration.project.identifier {
                    throw AgentCLIError.projectNotFound(identifier)
                }
                if stderr.contains("No running T3 Code server") || stderr.contains("Could not reach the T3 Code server") {
                    throw AgentCLIError.serverUnavailable(stderr)
                }
            }
            throw AgentCLIError.runFailed(
                threadID: envelope?.threadId,
                message: Self.failureMessage(
                    status: envelope?.status,
                    error: envelope?.error,
                    stderr: stderr
                ),
                exitCode: output.exitCode
            )
        }
    }

    // MARK: - Arguments

    private func startArguments(for model: AgentCLIModelSelection, title: String?) throws -> [String] {
        guard let identifier = configuration.project.identifier else {
            throw AgentCLIError.invalidConfiguration(
                "No T3 project is configured. Choose the T3 project id or folder in Settings."
            )
        }
        guard let provider = model.providerInstanceID?.nilIfBlank,
              let slug = model.modelSlug?.nilIfBlank
        else {
            throw AgentCLIError.invalidConfiguration(
                "T3 needs both a provider instance id and a model slug."
            )
        }

        var arguments = ["thread", "start", identifier, "-"]
        arguments += ["--provider", provider, "--model", slug]
        if let title = title?.nilIfBlank {
            arguments += ["--title", title]
        }
        arguments += baseDirectoryArguments
        arguments += ["--wait", "--json"]
        return arguments
    }

    private func sendArguments(threadID: String) -> [String] {
        ["thread", "send", threadID, "-"] + baseDirectoryArguments + ["--wait", "--json"]
    }

    private func showArguments(threadID: String) -> [String] {
        ["thread", "show", threadID, "--messages", "1"] + baseDirectoryArguments + ["--json"]
    }

    private var baseDirectoryArguments: [String] {
        configuration.baseDirectory.map { ["--base-dir", $0.path] } ?? []
    }

    /// Titles are only passed when the caller supplied one; otherwise the CLI
    /// derives the title from the first prompt line.
    private func effectiveTimeout(_ requestTimeout: TimeInterval) -> TimeInterval {
        requestTimeout > 0 ? requestTimeout : configuration.defaultTimeout
    }

    // MARK: - Pending question

    private func pendingResult(
        threadID: String,
        runID: String?,
        rawJSON: String,
        fallbackQuestion: String
    ) async -> AgentCLIResult {
        let details = await threadDetails(threadID: threadID)
        let question = details?.question
            ?? fallbackQuestion.nilIfBlank
            ?? "Thread \(threadID) is waiting for an answer. Open it in T3 Code to respond."
        return .awaitingAnswer(
            AgentCLIPendingQuestion(
                provider: .t3,
                threadID: threadID,
                question: question,
                openInT3URL: details?.link,
                runID: runID,
                rawJSON: rawJSON
            )
        )
    }

    private func threadDetails(threadID: String) async -> (question: String?, link: URL?)? {
        let timeout = min(20, max(1, effectiveTimeout(0)))
        let request = AgentProcessRequest(
            executableURL: configuration.executable,
            arguments: showArguments(threadID: threadID),
            timeout: timeout,
            outputByteLimit: 262_144
        )
        guard let output = try? await launcher.launch(request),
              output.exitCode == 0,
              let show = Self.decodeShowEnvelope(output.standardOutputText)
        else {
            return nil
        }

        let question = show.messages?
            .last(where: { ($0.role ?? "assistant") == "assistant" && ($0.text?.nilIfBlank != nil) })?
            .text?.nilIfBlank
            ?? show.messages?.last(where: { $0.text?.nilIfBlank != nil })?.text?.nilIfBlank

        let link: URL? = show.thread?.link.flatMap { raw -> URL? in
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else {
                return nil
            }
            return url
        }
        return (question, link)
    }

    // MARK: - Decoding

    struct RunEnvelope: Decodable, Equatable {
        var threadId: String
        var runId: String?
        var status: String?
        var reply: String?
        var error: String?
    }

    struct ShowEnvelope: Decodable, Equatable {
        struct Thread: Decodable, Equatable {
            var threadId: String?
            var projectId: String?
            var title: String?
            var link: String?
            var status: String?
        }

        struct Message: Decodable, Equatable {
            var role: String?
            var runId: String?
            var text: String?
        }

        var thread: Thread?
        var messages: [Message]?
    }

    static func decodeRunEnvelope(_ json: String) -> RunEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RunEnvelope.self, from: data)
    }

    static func decodeShowEnvelope(_ json: String) -> ShowEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ShowEnvelope.self, from: data)
    }

    static func failureMessage(status: String?, error: String?, stderr: String) -> String {
        if let error = error?.nilIfBlank { return error }
        if let stderr = stderr.nilIfBlank { return stderr }
        if let status = status?.nilIfBlank { return "The T3 run stopped with status \(status)." }
        return "The T3 command failed."
    }
}
