import Foundation
import FrameScriptCore
import FrameScriptMCP

/// Tiny argv parser. No third-party dependency: the CLI surface is one
/// subcommand plus version/help flags.
enum FrameScriptCLI {
    static let usage = """
    Usage: framescript <command> [options]

    Commands:
      mcp          Run the FrameScript MCP server over stdio
      --version    Print the framescript version
      --help       Show this help

    The MCP server speaks newline-delimited JSON-RPC 2.0 on stdin/stdout
    (MCP protocol revision \(MCPProtocolVersion.latest)) and logs to stderr.
    """

    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            write(usage + "\n", to: .standardError)
            return 2
        }

        switch command {
        case "--version", "-v":
            guard arguments.count == 1 else {
                write("framescript: --version does not take arguments\n", to: .standardError)
                return 2
            }
            write("framescript \(FrameScriptCore.version)\n", to: .standardOutput)
            return 0

        case "--help", "-h", "help":
            write(usage + "\n", to: .standardOutput)
            return 0

        case "mcp":
            let extra = Array(arguments.dropFirst())
            if extra.contains("--help") || extra.contains("-h") {
                write(usage + "\n", to: .standardOutput)
                return 0
            }
            guard extra.isEmpty else {
                write("framescript: unexpected argument '\(extra[0])' for mcp\n", to: .standardError)
                return 2
            }
            await runMCP()
            return 0

        default:
            write("framescript: unknown command '\(command)'\n", to: .standardError)
            write(usage + "\n", to: .standardError)
            return 2
        }
    }

    private static func runMCP() async {
        let server = MCPServer(
            registry: DemoTools.registry(),
            channel: MCPStdioChannel()
        )
        await server.run()
    }

    private static func write(_ string: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(string.utf8))
    }
}
