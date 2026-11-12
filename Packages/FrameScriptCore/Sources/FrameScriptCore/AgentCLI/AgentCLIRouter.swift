import Foundation

/// Picks the provider for a task.
///
/// Order: T3 when the binary exists *and* its server answers; otherwise the
/// configured Claude/Codex provider, then the other CLI. This is the "if T3
/// does not respond, run `claude -p` or `codex exec`" rule from F12.
public struct AgentCLIRouter: Sendable {
    public var configuredProvider: AgentCLIKind?
    public var t3: (any AgentCLIRunner)?
    public var claude: (any AgentCLIRunner)?
    public var codex: (any AgentCLIRunner)?
    public var t3Probe: (any T3AvailabilityChecking)?
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
        await selectRunner()?.kind
    }

    public func run(_ request: AgentCLIRequest) async throws -> AgentCLIResult {
        guard let runner = await selectRunner() else {
            throw AgentCLIError.noProviderAvailable
        }

        var adapted = request
        adapted.model = model(for: runner.kind, from: request.model)
        if runner.kind != .t3 {
            // A T3 thread id is meaningless to claude/codex.
            adapted.threadID = nil
        }
        return try await runner.run(adapted)
    }

    private func selectRunner() async -> (any AgentCLIRunner)? {
        if configuredProvider == nil || configuredProvider == .t3 {
            if let t3, let probe = t3Probe, await probe.isAvailable() {
                return t3
            }
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
