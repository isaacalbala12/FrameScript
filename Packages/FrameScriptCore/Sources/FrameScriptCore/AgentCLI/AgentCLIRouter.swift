import Foundation

/// Picks the provider for a task.
///
/// Order: an explicitly configured T3 is tried directly; otherwise T3 is used
/// when the binary exists *and* its server answers, then the configured
/// Claude/Codex provider, then the other CLI. This is the "if T3 does not
/// respond, run `claude -p` or `codex exec`" rule from F12.
public struct AgentCLIRouter: Sendable {
    public var configuredProvider: AgentCLIKind?
    public var t3: (any AgentCLIRunner)?
    public var claude: (any AgentCLIRunner)?
    public var codex: (any AgentCLIRunner)?
    public var t3Probe: (any T3AvailabilityChecking)?
    /// D2 thread reuse. When present, the router looks up a thread for the
    /// selected (provider, model) before a T3 call and records the id after it.
    public var t3ThreadMap: (any T3ThreadMapping)?
    /// Model used when a task configured for another provider falls back to T3.
    public var t3Model: AgentCLIModelSelection?
    /// Model used when a task falls back to Claude. `nil` = Claude's default.
    public var claudeModelSlug: String?
    /// Model used when a task falls back to Codex. `nil` = Codex's default.
    public var codexModelSlug: String?
    /// Fallback order when no provider was configured explicitly.
    public var fallbackOrder: [AgentCLIKind]

    public init(
        configuredProvider: AgentCLIKind? = nil,
        t3: (any AgentCLIRunner)? = nil,
        claude: (any AgentCLIRunner)? = nil,
        codex: (any AgentCLIRunner)? = nil,
        t3Probe: (any T3AvailabilityChecking)? = nil,
        t3ThreadMap: (any T3ThreadMapping)? = nil,
        t3Model: AgentCLIModelSelection? = nil,
        claudeModelSlug: String? = nil,
        codexModelSlug: String? = nil,
        fallbackOrder: [AgentCLIKind] = [.claude, .codex]
    ) {
        self.configuredProvider = configuredProvider
        self.t3 = t3
        self.claude = claude
        self.codex = codex
        self.t3Probe = t3Probe
        self.t3ThreadMap = t3ThreadMap
        self.t3Model = t3Model
        self.claudeModelSlug = claudeModelSlug
        self.codexModelSlug = codexModelSlug
        self.fallbackOrder = fallbackOrder
    }

    public func runner(for kind: AgentCLIKind) -> (any AgentCLIRunner)? {
        switch kind {
        case .t3: t3
        case .claude: claude
        case .codex: codex
        }
    }

    /// The provider that `run` would use right now, or `nil` when none is
    /// installed. Runs the T3 availability probe, so it is not free.
    public func resolvedProvider() async -> AgentCLIKind? {
        await selectRunner(for: nil)?.kind
    }

    public func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        guard let runner = await selectRunner(for: request) else {
            throw AgentCLIError.noProviderAvailable
        }

        var adapted = request
        adapted.model = model(for: runner.kind, from: request.model)
        if runner.kind != .t3 {
            // A T3 thread id is meaningless to claude/codex.
            adapted.threadID = nil
            return try await runner.run(adapted)
        }

        return try await runT3(runner, request: adapted)
    }

    private func runT3(
        _ runner: any AgentCLIRunner,
        request: AgentCLIRequest
    ) async throws -> AgentCLIResult {
        var request = request
        let key = T3ThreadKey(selection: request.model)
        if let key, let t3ThreadMap, request.threadID?.nilIfBlank == nil {
            request.threadID = await t3ThreadMap.threadID(for: key)
        }

        let result = try await runner.run(request)

        if let key, let t3ThreadMap, let threadID = result.threadID?.nilIfBlank {
            await t3ThreadMap.record(threadID: threadID, for: key)
        }
        return result
    }

    private func selectRunner(for request: AgentCLIRequest?) async -> (any AgentCLIRunner)? {
        let t3IsUsable = Self.t3IsUsable(for: request, fallbackModel: t3Model)

        // An explicit T3 choice trusts the runner even without a probe; the
        // caller already picked T3 and the call will surface a clear error if
        // the server is down. Automatic selection still needs a live probe.
        if t3IsUsable, configuredProvider == .t3, let t3 {
            if let t3Probe {
                if await t3Probe.isAvailable() {
                    return t3
                }
            } else {
                return t3
            }
        }

        if t3IsUsable,
           configuredProvider == nil,
           let t3,
           let t3Probe,
           await t3Probe.isAvailable() {
            return t3
        }

        let order: [AgentCLIKind]
        switch configuredProvider {
        case .claude:
            order = [.claude, .codex]
        case .codex:
            order = [.codex, .claude]
        case .t3, nil:
            order = fallbackOrder
        }

        for kind in order where kind != .t3 {
            if let runner = runner(for: kind) {
                return runner
            }
        }
        return nil
    }

    /// A task whose own model belongs to Claude/Codex cannot be started as a
    /// T3 thread unless a T3 fallback model is configured. Skipping T3 here
    /// avoids selecting it only to throw a configuration error.
    static func t3IsUsable(
        for request: AgentCLIRequest?,
        fallbackModel: AgentCLIModelSelection?
    ) -> Bool {
        guard let request else { return true }
        if let fallbackModel, fallbackModel.isComplete(for: .t3) {
            return true
        }
        return request.model.kind == .t3 && request.model.isComplete(for: .t3)
    }

    private func model(
        for kind: AgentCLIKind,
        from selection: AgentCLIModelSelection
    ) -> AgentCLIModelSelection {
        if selection.kind == kind, selection.isComplete(for: kind) {
            return selection
        }
        switch kind {
        case .t3:
            if let t3Model { return t3Model }
            return selection.kind == .t3 ? selection : AgentCLIModelSelection(kind: .t3)
        case .claude:
            return AgentCLIModelSelection(kind: .claude, modelSlug: claudeModelSlug)
        case .codex:
            return AgentCLIModelSelection(kind: .codex, modelSlug: codexModelSlug)
        }
    }
}

extension AgentCLIModelSelection {
    /// T3 needs provider + model; the other CLIs can use their default model.
    func isComplete(for kind: AgentCLIKind) -> Bool {
        switch kind {
        case .t3:
            return providerInstanceID?.nilIfBlank != nil && modelSlug?.nilIfBlank != nil
        case .claude, .codex:
            return true
        }
    }
}
