import Foundation

/// Protocol revisions understood by this server.
///
/// The latest MCP revision published at the time of writing is **2026-07-28**.
/// That revision is stateless: it removed the `initialize` handshake in favour
/// of per-request `_meta` fields. The task for this module is explicitly the
/// initialization-based lifecycle (`initialize` / `notifications/initialized`,
/// `tools/list`, `tools/call`, `ping`, `notifications/cancelled`), which is the
/// **2025-11-25** revision — the last stable revision that defines that
/// lifecycle. The 2026-07-28 specification still describes servers that only
/// speak this lifecycle as valid "legacy" servers, and clients fall back to
/// them (see the versioning compatibility matrix).
///
/// This server therefore advertises 2025-11-25 as its latest version and also
/// accepts older initialization-based revisions whose tool surface is
/// identical. It deliberately does not claim 2026-07-28: it does not implement
/// `server/discover` or per-request `_meta` metadata.
public enum MCPProtocolVersion {
    /// Latest MCP revision overall (stateless, no initialize handshake).
    public static let latestPublished = "2026-07-28"

    public static let v2024_11_05 = "2024-11-05"
    public static let v2025_03_26 = "2025-03-26"
    public static let v2025_06_18 = "2025-06-18"
    public static let v2025_11_25 = "2025-11-25"

    /// Latest revision implemented by this module.
    public static let latest = v2025_11_25

    /// Newest first. Used both for capability negotiation and documentation.
    public static let supported: [String] = [
        v2025_11_25,
        v2025_06_18,
        v2025_03_26,
        v2024_11_05
    ]
}
