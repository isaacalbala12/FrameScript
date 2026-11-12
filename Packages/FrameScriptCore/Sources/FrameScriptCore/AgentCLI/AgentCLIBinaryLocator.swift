import Foundation

/// Filesystem and login-shell lookups used by `AgentCLIBinaryLocator`.
///
/// A Finder-launched app does not inherit the Terminal `PATH`, so discovery is
/// explicit: known install directories first, then an optional
/// `/bin/zsh -lc 'command -v <name>'` probe.
public protocol AgentCLIBinaryProbing: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
    func loginShellExecutablePath(named name: String, shellPath: String) async -> String?
}

public struct SystemAgentCLIBinaryProbe: AgentCLIBinaryProbing {
    public init() {}

    public func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return false
        }
        return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    public func loginShellExecutablePath(named name: String, shellPath: String) async -> String? {
        guard Self.isSafeExecutableName(name) else { return nil }
        let request = AgentProcessRequest(
            executableURL: URL(fileURLWithPath: shellPath),
            arguments: ["-lc", "command -v \(name)"],
            standardInput: Data(),
            timeout: 8,
            outputByteLimit: 64 * 1024
        )
        guard let output = try? await SystemAgentProcessLauncher().launch(request),
              output.exitCode == 0
        else {
            return nil
        }
        return AgentCLIBinaryLocator.executablePath(
            inShellOutput: output.standardOutputText,
            isExecutable: isExecutableFile
        )
    }

    /// Rejects names that could change the meaning of the shell command.
    static func isSafeExecutableName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// The three binaries FrameScript cares about.
public struct AgentCLIBinaries: Sendable, Equatable {
    public var t3: URL?
    public var claude: URL?
    public var codex: URL?

    public init(t3: URL? = nil, claude: URL? = nil, codex: URL? = nil) {
        self.t3 = t3
        self.claude = claude
        self.codex = codex
    }

    public func url(for kind: AgentCLIKind) -> URL? {
        switch kind {
        case .t3: t3
        case .claude: claude
        case .codex: codex
        }
    }

    public var isEmpty: Bool {
        t3 == nil && claude == nil && codex == nil
    }
}

public struct AgentCLIBinaryLocator: Sendable {
    /// Directories checked before falling back to the login shell.
    public var searchDirectories: [URL]
    public var loginShellPath: String
    public var usesLoginShell: Bool
    private let probe: any AgentCLIBinaryProbing

    public init(
        searchDirectories: [URL]? = nil,
        loginShellPath: String = "/bin/zsh",
        usesLoginShell: Bool = true,
        probe: any AgentCLIBinaryProbing = SystemAgentCLIBinaryProbe()
    ) {
        self.searchDirectories = searchDirectories ?? Self.defaultSearchDirectories()
        self.loginShellPath = loginShellPath
        self.usesLoginShell = usesLoginShell
        self.probe = probe
    }

    /// Home-relative directories first, then the usual Homebrew/npm/Bun
    /// locations. The values are computed at runtime, never stored.
    public static func defaultSearchDirectories(homeDirectory: String = NSHomeDirectory()) -> [URL] {
        [
            "\(homeDirectory)/.t3/bin",
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public func locate(_ kind: AgentCLIKind) async -> URL? {
        await locate(executableNamed: kind.executableName)
    }

    public func locate(executableNamed name: String) async -> URL? {
        guard SystemAgentCLIBinaryProbe.isSafeExecutableName(name) else { return nil }

        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(name, isDirectory: false)
            if probe.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        guard usesLoginShell,
              let path = await probe.loginShellExecutablePath(named: name, shellPath: loginShellPath),
              probe.isExecutableFile(atPath: path)
        else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    public func locateAll() async -> AgentCLIBinaries {
        async let t3 = locate(.t3)
        async let claude = locate(.claude)
        async let codex = locate(.codex)
        return await AgentCLIBinaries(t3: t3, claude: claude, codex: codex)
    }

    /// Picks the first executable path from `command -v` output. Login shells
    /// may print banners or aliases, so only real executable files count.
    public static func executablePath(
        inShellOutput output: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines.reversed() {
            // `command -v` prints the path alone for real commands. Skip
            // aliases/functions, which the login shell would not give us.
            guard line.hasPrefix("/") || line.hasPrefix("~") else { continue }
            let expanded = (line as NSString).expandingTildeInPath
            if isExecutable(expanded) {
                return expanded
            }
        }
        return nil
    }
}
