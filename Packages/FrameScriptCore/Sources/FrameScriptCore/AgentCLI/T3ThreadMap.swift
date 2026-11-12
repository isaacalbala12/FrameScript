import Foundation

/// Decision D2's key: one thread per (provider instance, model) pair.
public struct T3ThreadKey: Sendable, Hashable, Codable {
    public var providerInstanceID: String
    public var modelSlug: String

    public init(providerInstanceID: String, modelSlug: String) {
        self.providerInstanceID = providerInstanceID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelSlug = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init?(selection: AgentCLIModelSelection) {
        guard let provider = selection.providerInstanceID?.nilIfBlank,
              let model = selection.modelSlug?.nilIfBlank
        else {
            return nil
        }
        self.init(providerInstanceID: provider, modelSlug: model)
    }
}

/// Storage seam for the D2 map. The app can back this with the project's
/// `.fscr` settings while tests use `T3ThreadMapStore`.
public protocol T3ThreadMapping: Sendable {
    func threadID(for key: T3ThreadKey) async -> String?
    func record(threadID: String, for key: T3ThreadKey) async
}

/// In-memory D2 map, used by the router and by tests.
public actor T3ThreadMapStore: T3ThreadMapping {
    private var map: T3ThreadMap

    public init(map: T3ThreadMap = T3ThreadMap()) {
        self.map = map
    }

    public func threadID(for key: T3ThreadKey) async -> String? {
        map.threadID(providerInstanceID: key.providerInstanceID, modelSlug: key.modelSlug)
    }

    public func record(threadID: String, for key: T3ThreadKey) async {
        map.record(
            threadID: threadID,
            providerInstanceID: key.providerInstanceID,
            modelSlug: key.modelSlug
        )
    }

    public func snapshot() -> T3ThreadMap {
        map
    }

    public func replace(with map: T3ThreadMap) {
        self.map = map
    }
}

/// Decision D2: a FrameScript project reuses one T3 thread per
/// (provider instance, model) pair. Changing the model starts a new thread;
/// the entry for the old pair stays so switching back can reuse it.
public struct T3ThreadMap: Sendable, Equatable, Codable {
    public struct Entry: Sendable, Equatable, Codable {
        public var providerInstanceID: String
        public var modelSlug: String
        public var threadID: String

        public init(providerInstanceID: String, modelSlug: String, threadID: String) {
            self.providerInstanceID = providerInstanceID
            self.modelSlug = modelSlug
            self.threadID = threadID
        }
    }

    /// T3 project the threads belong to. Stored for diagnostics and to detect
    /// a project change that should invalidate the map.
    public var t3ProjectID: String?
    public private(set) var entries: [Entry]

    public init(t3ProjectID: String? = nil, entries: [Entry] = []) {
        self.t3ProjectID = t3ProjectID
        self.entries = entries
    }

    /// Exact pair match, which is what D2 asks for: no fuzzy model families.
    public func threadID(providerInstanceID: String, modelSlug: String) -> String? {
        let provider = providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.first {
            $0.providerInstanceID == provider && $0.modelSlug == model
        }?.threadID
    }

    public func threadID(for selection: AgentCLIModelSelection) -> String? {
        guard let provider = selection.providerInstanceID,
              let model = selection.modelSlug
        else {
            return nil
        }
        return threadID(providerInstanceID: provider, modelSlug: model)
    }

    /// Records or replaces the thread for a pair.
    public mutating func record(threadID: String, providerInstanceID: String, modelSlug: String) {
        let provider = providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let thread = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !model.isEmpty, !thread.isEmpty else { return }

        if let index = entries.firstIndex(where: {
            $0.providerInstanceID == provider && $0.modelSlug == model
        }) {
            entries[index].threadID = thread
        } else {
            entries.append(Entry(providerInstanceID: provider, modelSlug: model, threadID: thread))
        }
    }

    public mutating func record(threadID: String, for selection: AgentCLIModelSelection) {
        guard let provider = selection.providerInstanceID,
              let model = selection.modelSlug
        else {
            return
        }
        record(threadID: threadID, providerInstanceID: provider, modelSlug: model)
    }

    public mutating func forget(providerInstanceID: String, modelSlug: String) {
        let provider = providerInstanceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll {
            $0.providerInstanceID == provider && $0.modelSlug == model
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
