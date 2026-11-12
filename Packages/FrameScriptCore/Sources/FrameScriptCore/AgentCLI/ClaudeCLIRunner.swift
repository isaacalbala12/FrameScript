import Foundation

/// Fallback runner for a Claude subscription: `claude -p --output-format json`.
///
/// Verified against Claude Code 2.1.322:
///
///     --print, -p              Print response and exit
///     --output-format          "text" (default), "json" (single result), or "stream-json"
///     --model <model>          Alias ('fable', 'opus', 'sonnet') or full name
///
/// The prompt goes on stdin; the JSON result carries `result`, `is_error`,
/// `session_id` and `subtype`.
public struct ClaudeCLIRunner: AgentCLIRunner {
    public let kind: AgentCLIKind = .claude
    public var executable: URL
    private let launcher: any AgentProcessLaunching

    public init(
        executable: URL,
        launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
    ) {
        self.executable = executable
        self.launcher = launcher
    }

    public func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        guard request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AgentCLIError.invalidConfiguration("The AI prompt is empty.")
        }
        // Validate blankness but send the caller's prompt byte-for-byte.
        let prompt = request.prompt

        var arguments = ["-p", "--output-format", "json", "--no-session-persistence"]
        if let model = request.model.modelSlug?.nilIfBlank {
            arguments += ["--model", model]
        }

        let processRequest = AgentProcessRequest(
            executableURL: executable,
            arguments: arguments,
            standardInput: Data(prompt.utf8),
            currentDirectoryURL: request.workingDirectory,
            timeout: request.timeout > 0 ? request.timeout : 180,
            outputByteLimit: request.outputByteLimit
        )
        let output = try await launcher.launch(processRequest)
        if output.standardOutputTruncated {
            throw AgentCLIError.outputTruncated(limit: request.outputByteLimit)
        }
        let envelope = Self.decode(output.standardOutputText)
        let stderr = output.standardErrorSummary

        guard let envelope else {
            if output.exitCode != 0 {
                throw AgentCLIError.runFailed(
                    threadID: nil,
                    message: stderr.nilIfBlank ?? "claude exited with code \(output.exitCode).",
                    exitCode: output.exitCode
                )
            }
            throw AgentCLIError.malformedOutput(
                exitCode: output.exitCode,
                detail: "Expected one JSON object from claude -p."
            )
        }

        if envelope.isError == true || output.exitCode != 0 {
            throw AgentCLIError.runFailed(
                threadID: nil,
                message: envelope.result?.nilIfBlank
                    ?? stderr.nilIfBlank
                    ?? "claude stopped with \(envelope.subtype ?? "an error").",
                exitCode: output.exitCode
            )
        }

        guard envelope.type == "result" else {
            throw AgentCLIError.malformedOutput(
                exitCode: output.exitCode,
                detail: "Expected type \"result\", got \"\(envelope.type ?? "none")\"."
            )
        }
        guard let text = envelope.result else {
            throw AgentCLIError.malformedOutput(
                exitCode: output.exitCode,
                detail: "The claude result has no text."
            )
        }

        return .completed(
            AgentCLIReply(
                provider: .claude,
                text: text,
                sessionID: envelope.sessionId,
                rawJSON: output.standardOutputText
            )
        )
    }

    struct Envelope: Decodable, Equatable {
        var type: String?
        var subtype: String?
        var is_error: Bool?
        var result: String?
        var session_id: String?

        var isError: Bool? { is_error }
        var sessionId: String? { session_id }

        enum CodingKeys: String, CodingKey {
            case type
            case subtype
            case is_error
            case result
            case session_id
        }
    }

    static func decode(_ json: String) -> Envelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: data)
    }
}
