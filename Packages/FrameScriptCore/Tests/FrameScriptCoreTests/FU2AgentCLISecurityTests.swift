import Foundation
import Testing
@testable import FrameScriptCore

/// FU2 regressions for the agent-CLI flag hardening (WP2 item 6).
///
/// The flags themselves were verified against the installed CLIs:
///
///     claude 2.1.325 `claude --help`
///       --permission-mode <mode>      choices: acceptEdits, auto,
///                                     bypassPermissions, manual, dontAsk, plan
///       --permission-prompts <target> "none" (nobody: anything that would
///                                     prompt is denied automatically)
///       --strict-mcp-config           only servers from --mcp-config
///       --mcp-config <configs...>     JSON files or strings
///       --disallowedTools <tools...>  comma or space separated
///
///     codex-cli 0.167.2 `codex exec --help`
///       -s, --sandbox <SANDBOX_MODE>  read-only, workspace-write,
///                                     danger-full-access
///       --add-dir <DIR>               additional *writable* directories
///       --approve-for-me              uses the workspace-write sandbox
///       --dangerously-bypass-approvals-and-sandbox
///
/// No prompt was ever sent to either CLI: the flag names were checked with
/// `claude --help` and with subcommands that do not call the model.
@Suite("FU2 agent CLI flags")
struct FU2AgentCLISecurityTests {
    /// Every name below is accepted by the real `claude --disallowedTools`
    /// parsing (none prints "matches no known tool").
    static let requiredDeniedTools = [
        "Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch",
        "Agent", "Task", "Skill", "SlashCommand", "TodoWrite", "BashOutput",
        "KillShell", "ExitPlanMode"
    ]

    // MARK: Claude

    @Test("claude never runs in plan mode")
    func claudeDoesNotUsePlanMode() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("claude-result.json"))])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .claude, model: "sonnet"))

        let arguments = try #require(await launcher.recordedRequests().first?.arguments)
        let mode = try #require(arguments.firstIndex(of: "--permission-mode"))
        #expect(arguments[mode + 1] == "dontAsk")
        #expect(!arguments.contains("plan"), "plan mode makes the model answer with a plan")
        let prompts = try #require(arguments.firstIndex(of: "--permission-prompts"))
        #expect(arguments[prompts + 1] == "none")
    }

    @Test("claude loads no MCP servers and denies every tool FrameScript must not use")
    func claudeBlocksMCPAndDeniesTools() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("claude-result.json"))])
        let runner = ClaudeCLIRunner(executable: fakeClaudeExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .claude, model: "sonnet"))

        let arguments = try #require(await launcher.recordedRequests().first?.arguments)
        #expect(arguments.contains("--strict-mcp-config"))
        let mcpIndex = try #require(arguments.firstIndex(of: "--mcp-config"))
        let inlineConfig = try #require(arguments[safe: mcpIndex + 1])
        let config = try #require(
            try JSONSerialization.jsonObject(with: Data(inlineConfig.utf8)) as? [String: Any]
        )
        #expect((config["mcpServers"] as? [String: Any])?.isEmpty == true)

        // Every built-in tool is disabled, including ones newer than the deny list.
        let toolsIndex = try #require(arguments.firstIndex(of: "--tools"))
        #expect(arguments[safe: toolsIndex + 1] == "")

        let deniedIndex = try #require(arguments.firstIndex(of: "--disallowedTools"))
        let deniedList = try #require(arguments[safe: deniedIndex + 1])
        let names = Set(deniedList.split(separator: ",").map(String.init))
        for tool in Self.requiredDeniedTools {
            #expect(names.contains(tool), "\(tool) must be denied")
        }
        #expect(!names.contains("plan"))
    }

    // MARK: Codex

    @Test("codex stays read-only with no writable escape hatch")
    func codexStaysReadOnly() async throws {
        let launcher = FakeProcessLauncher([.json(try AgentCLIFixtures.text("codex-exec.jsonl"))])
        let runner = CodexCLIRunner(executable: fakeCodexExecutable, launcher: launcher)

        _ = try await runner.run(makeRequest(kind: .codex, model: "gpt-5.1-codex-mini"))

        let arguments = try #require(await launcher.recordedRequests().first?.arguments)
        let sandbox = try #require(arguments.firstIndex(of: "-s"))
        #expect(arguments[sandbox + 1] == "read-only")
        // From `codex exec --help`: these are the only ways to gain writes.
        #expect(!arguments.contains("--add-dir"))
        #expect(!arguments.contains("--approve-for-me"))
        #expect(!arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(!arguments.contains("workspace-write"))
        #expect(!arguments.contains("danger-full-access"))
        // The prompt still travels on stdin after the `-` terminator.
        #expect(arguments.last == "-")
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
