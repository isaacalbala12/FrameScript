import Foundation

/// Fallback runner for a Codex subscription: `codex exec --json`.
///
/// Verified against codex-cli 0.167.2:
///
///     codex exec [OPTIONS] [PROMPT]
///       [PROMPT] ... If not provided as an argument (or if `-` is used),
///                instructions are read from stdin.
///       -m, --model <MODEL>
///       --json   Print events to stdout as JSONL
///       -o, --output-last-message <FILE>
///
/// JSONL events used here:
///
///     {"type":"thread.started","thread_id":"..."}
///     {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
///     {"type":"turn.completed", ...}
public struct CodexCLIRunner: AgentCLIRunner {
    public let kind: AgentCLIKind = .codex
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
        guard let prompt = request.prompt.nilIfBlank else {
            throw AgentCLIError.invalidConfiguration("The AI prompt is empty.")
        }

        var arguments = ["exec", "--json", "--skip-git-repo-check", "--ephemeral"]
        if let model = request.model.modelSlug?.nilIfBlank {
            arguments += ["-m", model]
        }
        arguments.append("-")

        let processRequest = AgentProcessRequest(
            executableURL: executable,
            arguments: arguments,
            standardInput: Data(prompt.utf8),
            currentDirectoryURL: request.workingDirectory,
            timeout: request.timeout > 0 ? request.timeout : 180,
            outputByteLimit: request.outputByteLimit
        )
        let output = try await launcher.launch(processRequest)
        let events = Self.parseEvents(output.standardOutputText)
        let stderr = output.standardErrorSummary

        let failure = events.errorMessage ?? stderr.nilIfBlank
        guard output.exitCode == 0 else {
            throw AgentCLIError.runFailed(
                threadID: nil,
                message: failure ?? "codex exited with code \(output.exitCode).",
                exitCode: output.exitCode
            )
        }
        guard let text = events.lastAgentMessage?.nilIfBlank else {
            throw AgentCLIError.malformedOutput(
                exitCode: output.exitCode,
                detail: failure ?? "codex printed no agent message."
            )
        }

        return .completed(
            AgentCLIReply(
                provider: .codex,
                text: text,
                sessionID: events.threadID,
                rawJSON: output.standardOutputText
            )
        )
    }

    struct Events: Sendable, Equatable {
        var threadID: String?
        var lastAgentMessage: String?
        var errorMessage: String?
    }

    /// Parses JSONL line by line. A malformed line is skipped: Codex can print
    /// a warning, and one bad event must not discard a good final message.
    static func parseEvents(_ jsonl: String) -> Events {
        var events = Events()
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else {
                continue
            }

            switch type {
            case "thread.started":
                events.threadID = object["thread_id"] as? String
            case "item.completed":
                guard let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message",
                      let text = item["text"] as? String
                else {
                    continue
                }
                events.lastAgentMessage = text
            case "error":
                events.errorMessage = (object["message"] as? String)
                    ?? (object["error"] as? [String: Any])?["message"] as? String
            case "turn.failed":
                events.errorMessage = (object["error"] as? [String: Any])?["message"] as? String
                    ?? (object["message"] as? String)
            default:
                continue
            }
        }
        return events
    }
}
