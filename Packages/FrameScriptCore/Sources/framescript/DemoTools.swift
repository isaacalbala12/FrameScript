import Foundation
import FrameScriptCore
import FrameScriptMCP

/// Demo tools registered until the FrameScript document tools arrive in a
/// later wave. They exercise text content, structured content, JSON Schemas,
/// annotations and argument validation.
enum DemoTools {
    static func registry() -> MCPToolRegistry {
        MCPToolRegistry([versionTool(), echoTool()])
    }

    static func versionTool() -> MCPTool {
        MCPTool(
            name: "framescript_version",
            title: "FrameScript version",
            description: "Return the version of the framescript CLI and its MCP server.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false)
            ]),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "version": .object([
                        "type": .string("string"),
                        "description": .string("FrameScript version string.")
                    ])
                ]),
                "required": .array([.string("version")]),
                "additionalProperties": .bool(false)
            ]),
            annotations: MCPToolAnnotations(
                title: "FrameScript version",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            handler: { _ in
                let payload = JSONValue.object(["version": .string(FrameScriptCore.version)])
                return MCPToolResult(
                    content: [.text("framescript \(FrameScriptCore.version)")],
                    structuredContent: payload
                )
            }
        )
    }

    static func echoTool() -> MCPTool {
        MCPTool(
            name: "echo",
            title: "Echo",
            description: "Echo text back to the caller. Optionally uppercase it.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to echo back.")
                    ]),
                    "uppercase": .object([
                        "type": .string("boolean"),
                        "description": .string("Uppercase the echoed text.")
                    ])
                ]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false)
            ]),
            outputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The echoed text.")
                    ])
                ]),
                "required": .array([.string("text")]),
                "additionalProperties": .bool(false)
            ]),
            annotations: MCPToolAnnotations(
                title: "Echo",
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            ),
            handler: { arguments in
                let args = try MCPArguments(arguments)
                let text = try args.requiredString("text")
                let uppercase = try args.optionalBool("uppercase") ?? false
                let output = uppercase ? text.uppercased() : text
                return MCPToolResult(
                    content: [.text(output)],
                    structuredContent: .object(["text": .string(output)])
                )
            }
        )
    }
}
