import Foundation

/// Standard JSON-RPC 2.0 error codes, as required by MCP.
public enum JSONRPCErrorCode: Int, Sendable, CaseIterable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603

    public var defaultMessage: String {
        switch self {
        case .parseError: return "Parse error"
        case .invalidRequest: return "Invalid Request"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid params"
        case .internalError: return "Internal error"
        }
    }
}
