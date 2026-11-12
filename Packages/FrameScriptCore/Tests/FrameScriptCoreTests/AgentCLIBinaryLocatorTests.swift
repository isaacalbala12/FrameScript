import Foundation
import Testing
@testable import FrameScriptCore

private struct StubBinaryProbe: AgentCLIBinaryProbing {
    var executables: Set<String>
    var loginShellPaths: [String: String] = [:]

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    func loginShellExecutablePath(named name: String, shellPath: String) async -> String? {
        loginShellPaths[name]
    }
}

@Suite("Binary discovery")
struct AgentCLIBinaryLocatorTests {
    private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    @Test("explicit install folders win over the login shell")
    func explicitDirectoryWins() async {
        let directories = [
            URL(fileURLWithPath: "/Users/example/.t3/bin", isDirectory: true),
            URL(fileURLWithPath: "/Users/example/.local/bin", isDirectory: true)
        ]
        let probe = StubBinaryProbe(
            executables: [
                "/Users/example/.local/bin/t3",
                "/somewhere/else/t3"
            ],
            loginShellPaths: ["t3": "/somewhere/else/t3"]
        )
        let locator = AgentCLIBinaryLocator(searchDirectories: directories, probe: probe)

        let url = await locator.locate(.t3)

        #expect(url?.path == "/Users/example/.local/bin/t3")
    }

    @Test("falls back to the login shell when no candidate exists")
    func loginShellFallback() async {
        let probe = StubBinaryProbe(
            executables: ["/custom/bin/claude"],
            loginShellPaths: ["claude": "/custom/bin/claude"]
        )
        let locator = AgentCLIBinaryLocator(
            searchDirectories: [],
            usesLoginShell: true,
            probe: probe
        )

        let url = await locator.locate(.claude)

        #expect(url?.path == "/custom/bin/claude")
    }

    @Test("the login shell can be disabled")
    func loginShellDisabled() async {
        let probe = StubBinaryProbe(
            executables: ["/custom/bin/codex"],
            loginShellPaths: ["codex": "/custom/bin/codex"]
        )
        let locator = AgentCLIBinaryLocator(
            searchDirectories: [],
            usesLoginShell: false,
            probe: probe
        )

        #expect(await locator.locate(.codex) == nil)
    }

    @Test("a shell result that is not executable is ignored")
    func loginShellNonExecutable() async {
        let probe = StubBinaryProbe(
            executables: [],
            loginShellPaths: ["t3": "/custom/bin/t3"]
        )
        let locator = AgentCLIBinaryLocator(
            searchDirectories: [],
            usesLoginShell: true,
            probe: probe
        )

        #expect(await locator.locate(.t3) == nil)
    }

    @Test("unsafe executable names never reach the shell")
    func rejectsUnsafeNames() async {
        let probe = StubBinaryProbe(executables: ["/tmp/t3"])
        let locator = AgentCLIBinaryLocator(searchDirectories: [], probe: probe)

        #expect(await locator.locate(executableNamed: "t3; rm -rf /") == nil)
        #expect(await locator.locate(executableNamed: "$(whoami)") == nil)
        #expect(await locator.locate(executableNamed: "") == nil)
        #expect(SystemAgentCLIBinaryProbe.isSafeExecutableName("t3"))
        #expect(SystemAgentCLIBinaryProbe.isSafeExecutableName("claude-code.2"))
        #expect(!SystemAgentCLIBinaryProbe.isSafeExecutableName("t3 --help"))
    }

    @Test("locates all three binaries")
    func locateAll() async {
        let probe = StubBinaryProbe(
            executables: [
                "/opt/homebrew/bin/t3",
                "/opt/homebrew/bin/claude",
                "/opt/homebrew/bin/codex"
            ]
        )
        let locator = AgentCLIBinaryLocator(
            searchDirectories: [URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)],
            usesLoginShell: false,
            probe: probe
        )

        let binaries = await locator.locateAll()

        #expect(binaries.t3?.path == "/opt/homebrew/bin/t3")
        #expect(binaries.claude?.path == "/opt/homebrew/bin/claude")
        #expect(binaries.codex?.path == "/opt/homebrew/bin/codex")
        #expect(binaries.isEmpty == false)
    }

    @Test("default search order matches F12")
    func defaultDirectories() {
        let directories = AgentCLIBinaryLocator
            .defaultSearchDirectories(homeDirectory: "/Users/example")
            .map(\.path)

        #expect(directories == [
            "/Users/example/.t3/bin",
            "/Users/example/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Users/example/.npm-global/bin",
            "/Users/example/.bun/bin"
        ])
    }

    @Test("shell output picks the executable path from banners and aliases")
    func shellOutputParsing() {
        let output = """
        Welcome to zsh
        alias t3='open -a T3'
        /opt/homebrew/bin/t3
        """
        let path = AgentCLIBinaryLocator.executablePath(
            inShellOutput: output,
            isExecutable: { $0 == "/opt/homebrew/bin/t3" }
        )
        #expect(path == "/opt/homebrew/bin/t3")
    }

    @Test("shell output without a real path returns nil")
    func shellOutputWithoutPath() {
        #expect(
            AgentCLIBinaryLocator.executablePath(
                inShellOutput: "alias t3='open -a T3'\nnot-a-path",
                isExecutable: { _ in true }
            ) == nil
        )
    }
}
