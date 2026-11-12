import Foundation

let exitCode = await FrameScriptCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode)
