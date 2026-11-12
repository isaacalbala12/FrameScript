import Foundation

public struct T3Project: Sendable, Equatable, Codable {
    public var id: String?
    public var title: String?
    public var path: String?
    /// The id or folder the CLI accepts as a project argument.
    public var identifier: String

    public init(id: String? = nil, title: String? = nil, path: String? = nil, identifier: String) {
        self.id = id
        self.title = title
        self.path = path
        self.identifier = identifier
    }
}

public enum T3ProjectLookupResult: Sendable, Equatable {
    case found(T3Project)
    case notFound
    case unsupported(String)
}

/// Checks, and optionally creates, the T3 project FrameScript writes to.
///
/// The installed t3 CLI (v0.1.10-nightly) has `project add`, `remove` and
/// `rename` but **no `project list`**, so a project can only be resolved by id
/// or by folder. `findProject(named:)` reports that limitation instead of
/// scanning private app state.
public struct T3ProjectResolver: Sendable {
    public struct Configuration: Sendable {
        public var executable: URL
        public var baseDirectory: URL?
        public var timeout: TimeInterval
        public var launcher: any AgentProcessLaunching

        public init(
            executable: URL,
            baseDirectory: URL? = nil,
            timeout: TimeInterval = 30,
            launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
        ) {
            self.executable = executable
            self.baseDirectory = baseDirectory
            self.timeout = timeout
            self.launcher = launcher
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Verifies that the project exists by listing its threads. Returns the
    /// project id when the thread list reveals it.
    public func resolve(_ reference: T3ProjectReference) async throws -> T3Project {
        guard let identifier = reference.identifier else {
            throw AgentCLIError.invalidConfiguration(
                "Choose a T3 project id or folder in Settings."
            )
        }

        let output = try await run(["thread", "list", "--project", identifier, "--json"])
        guard output.exitCode == 0 else {
            throw Self.error(for: output, operation: .resolve(identifier))
        }

        let threads = Self.decodeThreadList(output.standardOutputText)
        return T3Project(
            id: reference.id ?? threads?.first?.projectId,
            title: reference.name,
            path: reference.path,
            identifier: identifier
        )
    }

    /// Resolves the configured project, optionally creating it when a folder is
    /// configured and the project does not exist yet.
    public func resolveOrCreate(
        _ reference: T3ProjectReference,
        createIfMissing: Bool = false
    ) async throws -> T3Project {
        do {
            return try await resolve(reference)
        } catch AgentCLIError.projectNotFound {
            guard createIfMissing, let path = reference.path?.nilIfBlank else {
                throw AgentCLIError.projectNotFound(reference.identifier ?? reference.name ?? "")
            }
            return try await createProject(atPath: path, title: reference.name)
        }
    }

    /// Creates a project for a folder. The CLI prints
    /// `Added project <uuid> (<title>) at <path>.`; the id is parsed from it.
    public func createProject(atPath path: String, title: String? = nil) async throws -> T3Project {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AgentCLIError.invalidConfiguration("Choose a folder for the T3 project.")
        }

        var arguments = ["project", "add", trimmedPath]
        if let title = title?.nilIfBlank {
            arguments += ["--title", title]
        }
        let output = try await run(arguments)
        guard output.exitCode == 0 else {
            throw Self.error(for: output, operation: .create(trimmedPath))
        }

        let id = Self.projectID(fromAddOutput: output.standardOutputText)
        return T3Project(
            id: id,
            title: title,
            path: trimmedPath,
            identifier: id ?? trimmedPath
        )
    }

    /// Current t3 releases cannot look a project up by name.
    public func findProject(named name: String) async -> T3ProjectLookupResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }
        return .unsupported(
            "The installed t3 CLI has no `project list` command, so a project cannot be found by name. Set the T3 project id or folder in Settings."
        )
    }

    // MARK: - Helpers

    private enum Operation {
        case resolve(String)
        case create(String)
    }

    private func run(_ arguments: [String]) async throws -> AgentProcessOutput {
        var arguments = arguments
        if let baseDirectory = configuration.baseDirectory {
            arguments += ["--base-dir", baseDirectory.path]
        }
        let request = AgentProcessRequest(
            executableURL: configuration.executable,
            arguments: arguments,
            timeout: configuration.timeout,
            outputByteLimit: 262_144
        )
        return try await configuration.launcher.launch(request)
    }

    private static func error(for output: AgentProcessOutput, operation: Operation) -> AgentCLIError {
        let stderr = output.standardErrorSummary
        let message = stderr.nilIfBlank ?? "The t3 command failed with exit code \(output.exitCode)."

        if message.contains("No T3 Code project matches") {
            switch operation {
            case let .resolve(identifier): return .projectNotFound(identifier)
            case let .create(path): return .projectNotFound(path)
            }
        }
        if message.contains("already exists") {
            switch operation {
            case let .resolve(identifier): return .projectNotFound(identifier)
            case let .create(path): return .projectAlreadyExists(path)
            }
        }
        if message.contains("No running T3 Code server") || message.contains("Could not reach the T3 Code server") {
            return .serverUnavailable(message)
        }
        return .runFailed(threadID: nil, message: message, exitCode: output.exitCode)
    }

    static func decodeThreadList(_ json: String) -> [T3ThreadSummary]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([T3ThreadSummary].self, from: data)
    }

    static func projectID(fromAddOutput output: String) -> String? {
        // Prefer the documented token after "Added project".
        let tokens = output.split(whereSeparator: \.isWhitespace).map(String.init)
        if let index = tokens.firstIndex(of: "Added"),
           tokens.indices.contains(index + 2),
           tokens[index + 1] == "project",
           tokens[index + 2].contains("-") {
            return tokens[index + 2]
        }
        return tokens.first(where: isUUIDLike)
    }

    static func isUUIDLike(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let expected = [8, 4, 4, 4, 12]
        return zip(parts, expected).allSatisfy { part, count in
            part.count == count && part.allSatisfy { $0.isHexDigit }
        }
    }
}

/// Minimal thread shape from `t3 thread list --json`; unknown keys are ignored.
public struct T3ThreadSummary: Sendable, Equatable, Codable {
    public var threadId: String?
    public var projectId: String?
    public var title: String?
    public var status: String?
    public var link: String?
    public var providerInstanceId: String?
    public var model: String?

    public init(
        threadId: String? = nil,
        projectId: String? = nil,
        title: String? = nil,
        status: String? = nil,
        link: String? = nil,
        providerInstanceId: String? = nil,
        model: String? = nil
    ) {
        self.threadId = threadId
        self.projectId = projectId
        self.title = title
        self.status = status
        self.link = link
        self.providerInstanceId = providerInstanceId
        self.model = model
    }
}

public protocol T3AvailabilityChecking: Sendable {
    func isAvailable() async -> Bool
}

/// Cheap "is the T3 server there?" probe. `t3 status --json` explicitly does
/// not test connections, so this lists the project's threads instead.
public struct T3ServerProbe: T3AvailabilityChecking {
    public var executable: URL
    public var project: T3ProjectReference
    public var timeout: TimeInterval
    private let launcher: any AgentProcessLaunching

    public init(
        executable: URL,
        project: T3ProjectReference,
        timeout: TimeInterval = 8,
        launcher: any AgentProcessLaunching = SystemAgentProcessLauncher()
    ) {
        self.executable = executable
        self.project = project
        self.timeout = timeout
        self.launcher = launcher
    }

    public func isAvailable() async -> Bool {
        guard let identifier = project.identifier else { return false }
        let request = AgentProcessRequest(
            executableURL: executable,
            arguments: ["thread", "list", "--project", identifier, "--json"],
            timeout: timeout,
            outputByteLimit: 65_536
        )
        guard let output = try? await launcher.launch(request) else { return false }
        return output.exitCode == 0
    }
}
