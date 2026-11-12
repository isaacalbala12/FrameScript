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
`2025-11-25` and `2025-06-18` only — the two revisions whose tool surface it
actually implements (`outputSchema`, `structuredContent`, annotations, no
JSON-RPC batching). It does not claim `2025-03-26` or `2024-11-05` (batching /
missing output schemas) nor `2026-07-28` (no `server/discover` or per-request
`_meta`). Unknown requested versions negotiate down to `2025-11-25`.

## Wiring

```swift
import FrameScriptMCP

let registry = try MCPToolRegistry([
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

## Validation and safety

- Registration validates every tool schema: `inputSchema` and `outputSchema`
  must be JSON Schema objects with `"type": "object"`; malformed schemas make
  `MCPToolRegistry` throw `MCPToolDefinitionError`. `tools/list` therefore
  never emits a null or non-object schema.
- `tools/call` validates `arguments` against the tool's `inputSchema` before
  invoking the handler (type, properties, required, additionalProperties,
  items, enum, integer vs number). Failures are `-32602` with the failing path.
- Successful results are checked before writing. `structuredContent` is typed
  as `[String: JSONValue]`, must be present when `outputSchema` is declared,
  and must conform to it. Violations, and non-finite numbers anywhere in the
  result, become `isError: true` tool results rather than silence.
- `MCPJSON` refuses NaN/Infinity. If encoding ever fails anyway, the server
  writes a pre-encodable `-32603` response instead of dropping the request.
- The stdio framer is linear and enforces an 8 MiB per-message limit. On stdin
  EOF the server gives in-flight requests 2 seconds to finish and flush their
  responses before cancelling them, so pipe workflows are not truncated.

## Errors

JSON-RPC protocol errors use the standard codes:

| Code | Meaning |
| --- | --- |
| `-32700` | Parse error (invalid JSON) |
| `-32600` | Invalid request (bad envelope, batching, duplicate in-flight id, uninitialized) |
| `-32601` | Method not found |
| `-32602` | Invalid params (bad shape, unknown tool, inputSchema mismatch, tool-raised invalid params) |
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

Suites cover linear JSON framing and size limits, the JSON Schema subset
validator, tool registration rejection, argument helpers, the full handshake,
version claims, `tools/list` schemas, `tools/call` success, schema validation,
both error channels, structured-content checks, non-finite output, malformed
JSON, unknown methods and tools, notifications without responses, concurrent
calls, cancellation, bounded shutdown draining (including EOF and unterminated
final lines), and an end-to-end subprocess conversation against the built
`framescript mcp` executable (skipped when the binary has not been built).
