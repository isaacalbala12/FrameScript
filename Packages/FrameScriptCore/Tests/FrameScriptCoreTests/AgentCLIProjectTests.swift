import Foundation
import Testing
@testable import FrameScriptCore

@Suite("T3 project resolution")
struct T3ProjectResolverTests {
    private func makeResolver(
        launcher: FakeProcessLauncher,
        baseDirectory: URL? = nil
    ) -> T3ProjectResolver {
        T3ProjectResolver(
            configuration: T3ProjectResolver.Configuration(
                executable: fakeT3Executable,
                baseDirectory: baseDirectory,
                launcher: launcher
            )
        )
    }

    @Test("resolve by id parses the real thread list fixture")
    func resolveByID() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-list.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let resolver = makeResolver(launcher: launcher)

        let project = try await resolver.resolve(T3ProjectReference(id: fakeProjectID))

        #expect(project.id == fakeProjectID)
        #expect(project.identifier == fakeProjectID)

        let requests = await launcher.recordedRequests()
        let arguments = try #require(requests.first?.arguments)
        #expect(arguments == ["thread", "list", "--project", fakeProjectID, "--json"])
    }

    @Test("resolve by folder learns the project id from any thread")
    func resolveByPath() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-list.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let resolver = makeResolver(launcher: launcher)

        let project = try await resolver.resolve(
            T3ProjectReference(path: "/tmp/framescript-ia", name: "FrameScript IA")
        )

        #expect(project.id == fakeProjectID)
        #expect(project.identifier == "/tmp/framescript-ia")
        #expect(project.title == "FrameScript IA")
    }

    @Test("missing project is reported with its identifier")
    func missingProject() async {
        let stderr = "No T3 Code project matches 'nope'. Pass a project id or a path inside a project."
        let launcher = FakeProcessLauncher([.json("", exit: 1, stderr: stderr)])
        let resolver = makeResolver(launcher: launcher)

        let error = await captureAgentCLIError {
            try await resolver.resolve(T3ProjectReference(id: "nope"))
        }

        #expect(error == .projectNotFound("nope"))
    }

    @Test("a stopped server is reported separately")
    func stoppedServer() async {
        let stderr = "No running T3 Code server uses /tmp/t3. Start T3 Code, then retry."
        let launcher = FakeProcessLauncher([.json("", exit: 1, stderr: stderr)])
        let resolver = makeResolver(launcher: launcher)

        let error = await captureAgentCLIError {
            try await resolver.resolve(T3ProjectReference(id: fakeProjectID))
        }

        #expect(error == .serverUnavailable(stderr))
    }

    @Test("an empty reference never launches a process")
    func emptyReference() async {
        let launcher = FakeProcessLauncher([])
        let resolver = makeResolver(launcher: launcher)

        let error = await captureAgentCLIError {
            try await resolver.resolve(T3ProjectReference(name: "FrameScript IA"))
        }

        #expect(error?.errorDescription?.contains("Choose a T3 project id or folder") == true)
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("creating a project parses the CLI's added project line")
    func createProject() async throws {
        let stdout = "Added project 77777777-7777-4777-8777-777777777777 (FrameScript IA) at /tmp/framescript-ia.\n"
        let launcher = FakeProcessLauncher([.json(stdout)])
        let resolver = makeResolver(launcher: launcher)

        let project = try await resolver.createProject(
            atPath: "/tmp/framescript-ia",
            title: "FrameScript IA"
        )

        #expect(project.id == "77777777-7777-4777-8777-777777777777")
        #expect(project.identifier == "77777777-7777-4777-8777-777777777777")
        #expect(project.path == "/tmp/framescript-ia")

        let requests = await launcher.recordedRequests()
        let arguments = try #require(requests.first?.arguments)
        #expect(arguments == [
            "project", "add", "/tmp/framescript-ia", "--title", "FrameScript IA"
        ])
    }

    @Test("an existing project is a distinct error")
    func alreadyExists() async {
        let stderr = "An active project already exists for '/tmp/framescript-ia'."
        let launcher = FakeProcessLauncher([.json("", exit: 1, stderr: stderr)])
        let resolver = makeResolver(launcher: launcher)

        let error = await captureAgentCLIError {
            try await resolver.createProject(atPath: "/tmp/framescript-ia")
        }

        #expect(error == .projectAlreadyExists("/tmp/framescript-ia"))
    }

    @Test("ensure creates the project only when asked")
    func resolveOrCreate() async throws {
        let missing = "No T3 Code project matches '/tmp/framescript-ia'. Pass a project id or a path inside a project."
        let added = "Added project 99999999-9999-4999-8999-999999999999 (FrameScript IA) at /tmp/framescript-ia.\n"
        let launcher = FakeProcessLauncher([
            .json("", exit: 1, stderr: missing),
            .json(added)
        ])
        let resolver = makeResolver(launcher: launcher)

        let project = try await resolver.resolveOrCreate(
            T3ProjectReference(path: "/tmp/framescript-ia", name: "FrameScript IA"),
            createIfMissing: true
        )

        #expect(project.id == "99999999-9999-4999-8999-999999999999")
        let requests = await launcher.recordedRequests()
        #expect(requests.count == 2)
        #expect(Array(requests[1].arguments.prefix(3)) == ["project", "add", "/tmp/framescript-ia"])
    }

    @Test("ensure does not create anything unless asked")
    func resolveOrCreateDisabled() async {
        let missing = "No T3 Code project matches '/tmp/framescript-ia'. Pass a project id or a path inside a project."
        let launcher = FakeProcessLauncher([.json("", exit: 1, stderr: missing)])
        let resolver = makeResolver(launcher: launcher)

        let error = await captureAgentCLIError {
            try await resolver.resolveOrCreate(
                T3ProjectReference(path: "/tmp/framescript-ia"),
                createIfMissing: false
            )
        }

        #expect(error == .projectNotFound("/tmp/framescript-ia"))
        let requests = await launcher.recordedRequests()
        #expect(requests.count == 1)
    }

    @Test("the project id parser tolerates unknown prefixes")
    func projectIDParser() {
        #expect(
            T3ProjectResolver.projectID(
                fromAddOutput: "Created 88888888-8888-4888-8888-888888888888 at /tmp/x"
            ) == "88888888-8888-4888-8888-888888888888"
        )
        #expect(T3ProjectResolver.projectID(fromAddOutput: "nothing here") == nil)
        #expect(T3ProjectResolver.isUUIDLike("11111111-1111-4111-8111-111111111111"))
        #expect(!T3ProjectResolver.isUUIDLike("1111-1111"))
    }

    @Test("t3 cannot look projects up by name; we report that instead of guessing")
    func nameLookupUnsupported() async {
        let launcher = FakeProcessLauncher([])
        let resolver = makeResolver(launcher: launcher)

        let result = await resolver.findProject(named: "FrameScript IA")

        guard case let .unsupported(detail) = result else {
            Issue.record("Expected .unsupported, got \(result)")
            return
        }
        #expect(detail.contains("project list"))
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }

    @Test("base directory is forwarded to every project command")
    func baseDirectory() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-list.json")
        let launcher = FakeProcessLauncher([.json(fixture)])
        let resolver = makeResolver(
            launcher: launcher,
            baseDirectory: URL(fileURLWithPath: "/tmp/t3-home")
        )

        _ = try await resolver.resolve(T3ProjectReference(id: fakeProjectID))

        let requests = await launcher.recordedRequests()
        let arguments = try #require(requests.first?.arguments)
        #expect(arguments.suffix(2) == ["--base-dir", "/tmp/t3-home"])
    }
}

@Suite("T3 server probe")
struct T3ServerProbeTests {
    @Test("available when thread list succeeds")
    func available() async {
        let launcher = FakeProcessLauncher([.json("[]")])
        let probe = T3ServerProbe(
            executable: fakeT3Executable,
            project: T3ProjectReference(id: fakeProjectID),
            launcher: launcher
        )

        #expect(await probe.isAvailable())
        let arguments = await launcher.recordedRequests().first?.arguments
        #expect(arguments == ["thread", "list", "--project", fakeProjectID, "--json"])
    }

    @Test("unavailable when the server fails")
    func unavailable() async {
        let launcher = FakeProcessLauncher([
            .json("", exit: 1, stderr: "No running T3 Code server")
        ])
        let probe = T3ServerProbe(
            executable: fakeT3Executable,
            project: T3ProjectReference(id: fakeProjectID),
            launcher: launcher
        )

        #expect(await probe.isAvailable() == false)
    }

    @Test("unavailable when no project is configured")
    func noProject() async {
        let launcher = FakeProcessLauncher([])
        let probe = T3ServerProbe(
            executable: fakeT3Executable,
            project: T3ProjectReference(name: "FrameScript IA"),
            launcher: launcher
        )

        #expect(await probe.isAvailable() == false)
        let requests = await launcher.recordedRequests()
        #expect(requests.isEmpty)
    }
}

@Suite("T3 thread map (D2)")
struct T3ThreadMapTests {
    @Test("reuses the thread for the same provider and model")
    func reuse() {
        var map = T3ThreadMap(t3ProjectID: fakeProjectID)
        map.record(
            threadID: fakeThreadID,
            providerInstanceID: fakeProvider,
            modelSlug: fakeModelSlug
        )

        #expect(map.threadID(providerInstanceID: fakeProvider, modelSlug: fakeModelSlug) == fakeThreadID)
        #expect(map.threadID(for: AgentCLIModelSelection(
            kind: .t3,
            providerInstanceID: fakeProvider,
            modelSlug: fakeModelSlug
        )) == fakeThreadID)
    }

    @Test("a different model gets a new thread and keeps the old one")
    func differentModel() {
        var map = T3ThreadMap()
        map.record(threadID: "thread-a", providerInstanceID: "opencode", modelSlug: "model-a")
        map.record(threadID: "thread-b", providerInstanceID: "opencode", modelSlug: "model-b")

        #expect(map.threadID(providerInstanceID: "opencode", modelSlug: "model-a") == "thread-a")
        #expect(map.threadID(providerInstanceID: "opencode", modelSlug: "model-b") == "thread-b")
        #expect(map.threadID(providerInstanceID: "opencode", modelSlug: "model-c") == nil)
        #expect(map.entries.count == 2)
    }

    @Test("a different provider does not reuse the thread")
    func differentProvider() {
        var map = T3ThreadMap()
        map.record(threadID: "thread-a", providerInstanceID: "opencode", modelSlug: "same-model")

        #expect(map.threadID(providerInstanceID: "claude", modelSlug: "same-model") == nil)
    }

    @Test("recording the same pair replaces the thread id")
    func replaces() {
        var map = T3ThreadMap()
        map.record(threadID: "old", providerInstanceID: "p", modelSlug: "m")
        map.record(threadID: "new", providerInstanceID: "p", modelSlug: "m")

        #expect(map.entries.count == 1)
        #expect(map.threadID(providerInstanceID: "p", modelSlug: "m") == "new")
    }

    @Test("keys are trimmed and blank values are ignored")
    func normalization() {
        var map = T3ThreadMap()
        map.record(threadID: "  thread-a  ", providerInstanceID: " p ", modelSlug: " m ")
        map.record(threadID: "   ", providerInstanceID: "p", modelSlug: "m")
        map.record(threadID: "x", providerInstanceID: "", modelSlug: "m")

        #expect(map.entries.count == 1)
        #expect(map.threadID(providerInstanceID: "p", modelSlug: "m") == "thread-a")
    }

    @Test("incomplete selections never resolve")
    func incompleteSelection() {
        var map = T3ThreadMap()
        map.record(threadID: "t", providerInstanceID: "p", modelSlug: "m")

        #expect(map.threadID(for: AgentCLIModelSelection(kind: .t3, providerInstanceID: "p")) == nil)
        #expect(map.threadID(for: AgentCLIModelSelection(kind: .t3, modelSlug: "m")) == nil)
    }

    @Test("forget removes exactly one pair")
    func forget() {
        var map = T3ThreadMap()
        map.record(threadID: "a", providerInstanceID: "p", modelSlug: "m1")
        map.record(threadID: "b", providerInstanceID: "p", modelSlug: "m2")

        map.forget(providerInstanceID: "p", modelSlug: "m1")

        #expect(map.threadID(providerInstanceID: "p", modelSlug: "m1") == nil)
        #expect(map.threadID(providerInstanceID: "p", modelSlug: "m2") == "b")
    }

    @Test("round-trips through the project file codec")
    func codable() throws {        var map = T3ThreadMap(t3ProjectID: fakeProjectID)
        map.record(threadID: fakeThreadID, providerInstanceID: fakeProvider, modelSlug: fakeModelSlug)
        map.record(threadID: "thread-2", providerInstanceID: "codex", modelSlug: "model-2")

        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(T3ThreadMap.self, from: data)

        #expect(decoded == map)
        #expect(decoded.t3ProjectID == fakeProjectID)
        #expect(decoded.entries.count == 2)
    }

    @Test("the map drives start the first time and send afterwards")
    func startThenReuse() async throws {
        let fixture = try AgentCLIFixtures.text("t3-thread-start.json")
        let launcher = FakeProcessLauncher([.json(fixture), .json(fixture)])
        let runner = makeT3Runner(launcher: launcher)
        var map = T3ThreadMap(t3ProjectID: fakeProjectID)
        let selection = AgentCLIModelSelection(
            kind: .t3,
            providerInstanceID: fakeProvider,
            modelSlug: fakeModelSlug
        )

        var request = makeRequest()
        request.threadID = map.threadID(for: selection)
        let first = try await runner.run(request)
        let threadID = try #require(first.reply?.threadID)
        map.record(threadID: threadID, for: selection)

        request.threadID = map.threadID(for: selection)
        _ = try await runner.run(request)

        let recorded = await launcher.recordedRequests()
        #expect(Array(recorded[0].arguments.prefix(2)) == ["thread", "start"])
        #expect(Array(recorded[1].arguments.prefix(3)) == ["thread", "send", fakeThreadID])
    }
}
