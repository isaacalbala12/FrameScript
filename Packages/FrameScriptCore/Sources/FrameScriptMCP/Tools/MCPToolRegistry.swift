import Foundation

/// An immutable, ordered collection of tools. The first registration of a name
/// wins; duplicates are ignored. Declaration order is preserved in
/// `tools/list`.
public struct MCPToolRegistry: Sendable {
    private let ordered: [MCPTool]
    private let byName: [String: MCPTool]

    public init(_ tools: [MCPTool] = []) {
        var ordered: [MCPTool] = []
        var byName: [String: MCPTool] = [:]
        for tool in tools where byName[tool.name] == nil {
            ordered.append(tool)
            byName[tool.name] = tool
        }
        self.ordered = ordered
        self.byName = byName
    }

    public var tools: [MCPTool] { ordered }

    public var definitions: [JSONValue] { ordered.map(\.definition) }

    public func tool(named name: String) -> MCPTool? {
        byName[name]
    }

    public var count: Int { ordered.count }

    public static let empty = MCPToolRegistry()
}
