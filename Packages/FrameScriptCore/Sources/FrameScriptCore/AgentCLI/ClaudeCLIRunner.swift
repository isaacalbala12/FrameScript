import Foundation

/// Fallback runner for a Claude subscription: `claude -p --output-format json`.
///
/// Verified against Claude Code 2.1.325 (`claude --help`):
///
///     --print, -p              Print response and exit
///     --output-format          "text" (default), "json" (single result), or "stream-json"
///     --permission-mode        choices: acceptEdits, auto, bypassPermissions,
///                              manual, dontAsk, plan
///     --permission-prompts     "none": anything that would prompt is denied
///     --strict-mcp-config      only servers from --mcp-config
///     --mcp-config             JSON files or strings
///     --tools                  "" disables every built-in tool
///     --disallowedTools        comma or space separated tool names
///     --model <model>          Alias ('fable', 'opus', 'sonnet') or full name
///
/// The prompt goes on stdin; the JSON result carries `result`, `is_error`,
/// `session_id` and `subtype`.
///
/// The run is pinned to `dontAsk` (never prompts: anything that would ask is
/// denied) with every file/command/network/subagent tool denied and an empty,
/// strict MCP configuration, so the user's global Claude Code settings cannot
/// turn a script (which may come from an imported or shared file) into file
/// access. FrameScript only needs the model's text, never a tool call.
///
/// Plan mode is deliberately not used: it tells the model to investigate and
/// answer with a plan (or through `ExitPlanMode`) instead of producing the
/// requested JSON or text, which breaks every FrameScript AI action.
public struct ClaudeCLIRunner: AgentCLIRunner {
    /// Denied tools: no shell, no file reads or writes, no web, no subagents,
    /// no skills or slash commands, and no plan-mode escape hatch.
    static let deniedTools = [
        "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit",
        "Read", "Glob", "Grep", "WebFetch", "WebSearch",
        "Agent", "Task", "Skill", "SlashCommand",
        "TodoWrite", "BashOutput", "KillShell", "ExitPlanMode"
    ].joined(separator: ",")

    /// With `--strict-mcp-config`, only the servers named by `--mcp-config`
    /// load: an empty object means none of the user's MCP servers start.
    static let emptyMCPConfig = #"{"mcpServers":{}}"#

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

        var arguments = [
            "-p", "--output-format", "json", "--no-session-persistence",
            // `dontAsk` never prompts and denies anything that would ask;
            // `none` guarantees nothing ever waits for a permission answer.
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            // Never load the user's MCP servers: strict config plus an empty
            // inline configuration means the MCP surface is empty.
            "--strict-mcp-config", "--mcp-config", Self.emptyMCPConfig,
            // `--tools ""` disables every built-in tool, including tools added
            // to Claude Code after this list was written; the deny list stays
            // as a second layer.
            "--tools", "",
            "--disallowedTools", Self.deniedTools
        ]
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
