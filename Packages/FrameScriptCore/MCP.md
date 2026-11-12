# FrameScriptMCP

Protocol foundation for F23 (MCP server + `framescript` CLI) and decision D6.
UI-free; lives in `Packages/FrameScriptCore` so the app, CLI and MCP server can
share the same document code later.

## Protocol revision

This module implements the **initialization-based MCP lifecycle** exactly as
specified by the **2025-11-25** stable revision:

- newline-delimited JSON-RPC 2.0 over stdio, one message per line, no embedded
  newlines;
- `initialize` → `notifications/initialized` handshake with protocol-version
  negotiation and a `tools` capability;
- `ping` → `{}`;
- `tools/list` with `inputSchema` plus optional `outputSchema`, `title`,
  `description` and `annotations`;
- `tools/call` returning a `content` array of text items and `isError` for tool
  execution errors, while protocol problems stay JSON-RPC errors;
- `notifications/cancelled` with `requestId` (and optional `reason`).

The newest MCP revision overall is **2026-07-28**. That revision is stateless:
it replaces the handshake with per-request `_meta` fields and adds
`server/discover`. The 2026-07-28 versioning chapter still treats
initialization-based implementations as valid *legacy* servers, and modern
clients fall back to `initialize` for them. This server therefore advertises
`2025-11-25` (also accepting `2025-06-18`, `2025-03-26`, `2024-11-05`) and does
not claim 2026-07-28.

## Wiring

```swift
import FrameScriptMCP

let registry = MCPToolRegistry([
    MCPTool(
        name: "echo",
        description: "Echo text back.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["text": .object(["type": .string("string")])]),
            "required": .array([.string("text")])
        ]),
        handler: { rawArguments in
            let arguments = try MCPArguments(rawArguments)
            let text = try arguments.requiredString("text")
            return .text(text)
        }
    )
])

let server = MCPServer(registry: registry, channel: MCPStdioChannel())
await server.run()
```

`MCPMessageChannel` is the transport seam. `MCPStdioChannel` uses the process
streams; `MCPInMemoryChannel` scripts conversations in tests without processes.

## Errors

JSON-RPC protocol errors use the standard codes:

| Code | Meaning |
| --- | --- |
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request (bad envelope, batching, duplicate in-flight id, uninitialized) |
| `-32601` | Method not found |
| `-32602` | Invalid params (bad shape, unknown tool, tool-raised invalid params) |
| `-32603` | Internal error |

Tool execution failures are **not** JSON-RPC errors: they return
`{"content": [...], "isError": true}` so the model can correct itself. The
argument helpers (`MCPArguments`) throw `MCPArgumentError`, which the server
reports that way. A tool that needs a protocol error can throw
`MCPToolError.invalidParams` or `.internalError`.

All logging goes to stderr. stdout carries protocol messages only.

## CLI

```sh
swift run framescript --version
swift run framescript mcp
```

`framescript mcp` starts the stdio server with two demo tools for now:
`framescript_version` and `echo`. The FrameScript document tools arrive in a
later wave.

## Tests

```sh
swift test
```

Suites cover JSON framing, argument helpers, the full handshake, `tools/list`
schemas, `tools/call` success and both error channels, malformed JSON, unknown
methods and tools, notifications without responses, concurrent calls,
cancellation, shutdown, and an end-to-end subprocess conversation against the
built `framescript mcp` executable (skipped when the binary has not been built).
