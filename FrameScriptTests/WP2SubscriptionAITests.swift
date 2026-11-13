import Foundation
import FrameScriptCore
import Security
@testable import FrameScript
import XCTest

/// One-shot gate so a test can inspect the runtime while a fake CLI is running.
actor WP2Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class WP2Flag {
    var value = false
}

@MainActor
private func wp2WaitUntil(
    _ predicate: @MainActor () -> Bool,
    iterations: Int = 400
) async -> Bool {
    for _ in 0..<iterations {
        if predicate() { return true }
        await Task.yield()
    }
    return false
}

/// WP2 regressions for the subscription runtime, its settings store and the
/// provider/thread hygiene fixes.
@MainActor
final class WP2SubscriptionAITests: FrameScriptTestCase {
    private func llmRequest(task: AITask) -> LLMRequest {
        LLMRequest(
            task: task,
            provider: .t3Code,
            baseURL: "",
            systemPrompt: "System instructions",
            userPrompt: "Scene text",
            model: "ignored",
            temperature: 0,
            maxTokens: 0
        )
    }

    private func runtime(
        store: SubscriptionAISettingsStore,
        router: AgentCLIRouter
    ) -> SubscriptionAIRuntime {
        SubscriptionAIRuntime(
            store: store,
            routerFactory: StaticSubscriptionRouterProvider(router: router),
            inspector: SubscriptionAIT3ThreadInspector(launcher: SubscriptionFakeLauncher([]))
        )
    }

    // MARK: Item 2: a neutral working directory

    func testSubscriptionAIContextRunsOutsideTheProjectFolder() throws {
        let defaults = makeDefaults()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP2Project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = directory.appendingPathComponent("wp2.fscr")

        let project = SampleData.demoProject(language: .spanish)
        let projectStore = ProjectStore(project: project)
        projectStore.openProject(project, fileURL: projectURL, wordsPerMinute: 150, markUnsaved: false)
        let appState = AppState(
            projectStore: projectStore,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )

        let workingDirectory = try XCTUnwrap(appState.subscriptionAIContext.workingDirectory)

        XCTAssertNotEqual(workingDirectory, directory)
        XCTAssertEqual(workingDirectory.lastPathComponent, "\(SubscriptionAIScratchDirectory.name)-\(ProcessInfo.processInfo.processIdentifier)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingDirectory.path))
    }

    // MARK: Item 3: a fallback provider is visible

    func testAFallbackProviderIsVisibleInTheActivity() async throws {
        let defaults = makeDefaults()
        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        store.settings.defaultSelection = SubscriptionAISelection(kind: .claude, modelSlug: "sonnet")
        let gate = WP2Gate()
        let router = AgentCLIRouter(
            configuredProvider: .claude,
            codex: SubscriptionRecordingRunner(kind: .codex, recorder: SubscriptionRunnerRecorder()) { _ in
                await gate.wait()
                return .completed(AgentCLIReply(provider: .codex, text: "OK"))
            }
        )
        let subject = runtime(store: store, router: router)

        let run = Task { try await subject.complete(request: llmRequest(task: .analyze)) }
        let shown = await wp2WaitUntil { subject.activity?.kind == .codex }

        XCTAssertTrue(shown, "the activity must report the CLI that is really running")
        XCTAssertEqual(subject.activity?.configuredKind, .claude)
        XCTAssertEqual(subject.activity?.usedFallback, true)

        await gate.open()
        _ = try await run.value
    }

    func testTheConfiguredProviderIsReportedWithoutAFallback() async throws {
        let defaults = makeDefaults()
        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        store.settings.defaultSelection = SubscriptionAISelection(kind: .claude, modelSlug: "sonnet")
        let gate = WP2Gate()
        let started = WP2Flag()
        let router = AgentCLIRouter(
            configuredProvider: .claude,
            claude: SubscriptionRecordingRunner(kind: .claude, recorder: SubscriptionRunnerRecorder()) { _ in
                await MainActor.run { started.value = true }
                await gate.wait()
                return .completed(AgentCLIReply(provider: .claude, text: "OK"))
            }
        )
        let subject = runtime(store: store, router: router)

        let run = Task { try await subject.complete(request: llmRequest(task: .analyze)) }
        let running = await wp2WaitUntil { started.value }

        XCTAssertTrue(running)
        XCTAssertEqual(subject.activity?.kind, .claude)
        XCTAssertEqual(subject.activity?.configuredKind, .claude)
        XCTAssertEqual(subject.activity?.usedFallback, false)

        await gate.open()
        _ = try await run.value
    }

    // MARK: Item 8: an unreadable settings blob is preserved

    func testAnUnreadableSettingsBlobIsPreserved() throws {
        let defaults = makeDefaults()
        let corrupt = Data("this is not json".utf8)
        defaults.set(corrupt, forKey: SubscriptionAISettingsStore.storageKey)

        let store = SubscriptionAISettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertTrue(store.didRecoverFromUnreadableSettings)
        let backupKey = try XCTUnwrap(store.unreadableBackupKey)
        XCTAssertEqual(defaults.data(forKey: backupKey), corrupt)
        XCTAssertEqual(defaults.data(forKey: SubscriptionAISettingsStore.storageKey), corrupt)

        // An explicit change replaces the live blob, never the preserved copy.
        store.settings.defaultTimeout = 240
        XCTAssertEqual(defaults.data(forKey: backupKey), corrupt)
        XCTAssertNotEqual(defaults.data(forKey: SubscriptionAISettingsStore.storageKey), corrupt)

        store.acknowledgeUnreadableSettings()
        XCTAssertFalse(store.didRecoverFromUnreadableSettings)
    }

    func testReadableSettingsDoNotRaiseTheRecoveryNotice() {
        let defaults = makeDefaults()
        let first = SubscriptionAISettingsStore(userDefaults: defaults)
        first.settings.defaultTimeout = 240

        let reloaded = SubscriptionAISettingsStore(userDefaults: defaults)

        XCTAssertEqual(reloaded.settings.defaultTimeout, 240)
        XCTAssertFalse(reloaded.didRecoverFromUnreadableSettings)
        XCTAssertNil(reloaded.unreadableBackupKey)
    }

    // MARK: Item 9: the runtime does not survive a project change

    func testAProjectChangeClearsTheRuntimeAndCancelsTheRun() async throws {
        let defaults = makeDefaults()
        let store = SubscriptionAISettingsStore(userDefaults: defaults)
        let router = AgentCLIRouter(
            configuredProvider: .claude,
            claude: SubscriptionRecordingRunner(kind: .claude, recorder: SubscriptionRunnerRecorder()) { _ in
                try await Task.sleep(for: .seconds(30))
                return .completed(AgentCLIReply(provider: .claude, text: "late"))
            }
        )
        let subject = runtime(store: store, router: router)

        let run = Task { try await subject.complete(request: llmRequest(task: .analyze)) }
        let started = await wp2WaitUntil { subject.isRunning }
        XCTAssertTrue(started)

        subject.pendingPrompt = SubscriptionAIPendingPrompt(
            question: AgentCLIPendingQuestion(threadID: "thread-1", question: "Keep the cold open?")
        )

        NotificationCenter.default.post(name: .frameScriptProjectWillChange, object: nil)

        let cleared = await wp2WaitUntil { subject.pendingPrompt == nil }
        XCTAssertTrue(cleared, "a pending question belongs to the old project")

        do {
            _ = try await run.value
            XCTFail("The run must be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let stopped = await wp2WaitUntil { !subject.isRunning }
        XCTAssertTrue(stopped)
        XCTAssertNil(subject.lastOutcome, "a project change must not leave a cancelled notice")
        XCTAssertNil(subject.openError)
    }

    // MARK: Item 10: rehook has its own task mapping

    func testRehookHasItsOwnTaskMapping() {
        XCTAssertEqual(SubscriptionAITask(AITask.rehook), .rehook)
        XCTAssertEqual(SubscriptionAITask.rehook.threadTitle, "Rehooks")
        XCTAssertNotEqual(SubscriptionAITask(AITask.rehook), .review)

        var settings = SubscriptionAISettings()
        settings.setUseForAllTasks(false)
        settings.setSelection(
            SubscriptionAISelection(kind: .codex, modelSlug: "gpt-5.3-codex"),
            for: .rehook
        )
        XCTAssertEqual(settings.selection(for: SubscriptionAITask(AITask.rehook)).kind, .codex)
    }

    // MARK: Item 12: diagnostics and unknown kinds

    func testLongCLIStderrIsTruncatedInTheAlert() throws {
        let long = String(repeating: "x", count: 600)

        let mapping = try XCTUnwrap(
            SubscriptionAIErrorDescription.mapping(
                for: AgentCLIError.runFailed(threadID: nil, message: long, exitCode: 1)
            )
        )

        XCTAssertEqual(mapping.key, "aiError.runFailed")
        let argument = try XCTUnwrap(mapping.arguments.first)
        XCTAssertEqual(argument.count, SubscriptionAIErrorDescription.maximumDiagnosticLength + 1)
        XCTAssertTrue(argument.hasSuffix("…"))
        XCTAssertEqual(SubscriptionAIErrorDescription.truncatedDiagnostic("short"), "short")
    }

    func testAnUnknownStoredProviderKindIsInvalidNotT3() throws {
        let json = #"{"kind":"quantum","providerInstanceID":"","modelSlug":""}"#
        let selection = try JSONDecoder().decode(SubscriptionAISelection.self, from: Data(json.utf8))

        XCTAssertTrue(selection.hasUnknownKind)
        XCTAssertEqual(selection.validationIssue, .unknownProviderKind)
    }

    func testAKnownStoredProviderKindIsValid() throws {
        let json = #"{"kind":"claude","providerInstanceID":"","modelSlug":"sonnet"}"#
        let selection = try JSONDecoder().decode(SubscriptionAISelection.self, from: Data(json.utf8))

        XCTAssertFalse(selection.hasUnknownKind)
        XCTAssertNil(selection.validationIssue)
    }

    // MARK: Item 13: Keychain writes never delete a working key

    func testKeychainWriteUpdatesAnExistingItem() throws {
        var calls: [String] = []

        try KeychainStore.write(
            update: { calls.append("update"); return errSecSuccess },
            add: { calls.append("add"); return errSecSuccess }
        )

        XCTAssertEqual(calls, ["update"])
    }

    func testKeychainWriteAddsOnlyWhenTheItemIsMissing() throws {
        var calls: [String] = []

        try KeychainStore.write(
            update: { calls.append("update"); return errSecItemNotFound },
            add: { calls.append("add"); return errSecSuccess }
        )

        XCTAssertEqual(calls, ["update", "add"])
    }

    func testKeychainWriteNeverAddsAfterAFailedUpdate() {
        var added = false

        XCTAssertThrowsError(
            try KeychainStore.write(
                update: { errSecAuthFailed },
                add: { added = true; return errSecSuccess }
            )
        )

        XCTAssertFalse(added, "a failed update must not touch the stored key")
    }

    // MARK: Item 14: ASCII provider raw values with a legacy decoder

    func testLegacySpanishProviderRawValuesStillDecode() throws {
        XCTAssertEqual(AIProviderKind(storedRawValue: "T3 Code (suscripción)"), .t3Code)
        XCTAssertEqual(AIProviderKind(storedRawValue: "Claude Code (suscripción)"), .claudeCode)
        XCTAssertEqual(AIProviderKind(storedRawValue: "Codex (suscripción)"), .codex)
        XCTAssertEqual(AIProviderKind(storedRawValue: "t3Code"), .t3Code)
        XCTAssertNil(AIProviderKind(storedRawValue: "quantum"))

        let json = #"{"provider":"T3 Code (suscripción)"}"#
        let preferences = try JSONDecoder().decode(AIPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(preferences.provider, .t3Code)
    }

    func testProviderDefaultsKeysMigrateFromTheSpanishRawValues() {
        let defaults = makeDefaults()
        defaults.set(
            ["model": "legacy-model", "baseURL": "https://legacy.example"],
            forKey: "FrameScript.ai.provider.T3 Code (suscripción)"
        )
        defaults.set(true, forKey: "FrameScript.ai.hasStoredKey.OpenRouter")

        let store = AIProviderConfigurationStore(userDefaults: defaults)

        XCTAssertEqual(store.load(for: .t3Code).model, "legacy-model")
        XCTAssertEqual(store.load(for: .t3Code).baseURL, "https://legacy.example")
        XCTAssertTrue(store.hasStoredKey(for: .openRouter))
        XCTAssertNil(defaults.object(forKey: "FrameScript.ai.provider.T3 Code (suscripción)"))
        XCTAssertNil(defaults.object(forKey: "FrameScript.ai.hasStoredKey.OpenRouter"))
        XCTAssertNotNil(defaults.object(forKey: "FrameScript.ai.provider.t3Code"))
        XCTAssertNotNil(defaults.object(forKey: "FrameScript.ai.hasStoredKey.openRouter"))
    }

    func testTheKeychainAccountStaysOnTheLegacyName() {
        // Renaming the account would orphan every saved API key.
        XCTAssertEqual(AIProviderKind.openAICompatible.keychainAccount, "OpenAI-compatible")
        XCTAssertEqual(AIProviderKind.openRouter.keychainAccount, "OpenRouter")
        XCTAssertEqual(AIProviderKind.groq.keychainAccount, "Groq")
        XCTAssertEqual(AIProviderKind.googleAIStudio.keychainAccount, "FrameScript.GoogleAIStudio")
    }

    func testEveryProviderKindStillHasALocalizedName() {
        for language in [AppLanguage.english, .russian, .spanish] {
            for provider in AIProviderKind.allCases {
                let key = "aiProvider.\(provider.rawValue)"
                let name = L10n.tr(key, language: language)
                XCTAssertNotEqual(name, key, "\(provider) has no \(language) display name")
                XCTAssertFalse(name.isEmpty)
            }
        }
    }

    // MARK: Localization

    func testEveryWP2StringResolvesInAllThreeLanguages() throws {
        let tables = L10n.wp2Strings
        for (language, table) in tables {
            XCTAssertFalse(table.isEmpty, "no strings for \(language)")
            for key in table.keys {
                let value = L10n.tr(key, language: language)
                XCTAssertNotEqual(value, key, "\(key) has no \(language) value")
                XCTAssertFalse(value.isEmpty)
            }
        }

        let english = try XCTUnwrap(tables[.english])
        let russian = try XCTUnwrap(tables[.russian])
        let spanish = try XCTUnwrap(tables[.spanish])
        // SpanishLocalizationTests enforces en/es parity globally; Russian uses
        // the CLDR `few`/`many` forms instead of `other`.
        XCTAssertEqual(Set(english.keys), Set(spanish.keys))
        XCTAssertEqual(
            Set(english.keys).subtracting(["hooks.words.other"]),
            Set(russian.keys).subtracting(["hooks.words.few", "hooks.words.many"])
        )
        for (count, language) in [
            (1, AppLanguage.english), (5, AppLanguage.english),
            (1, AppLanguage.spanish), (5, AppLanguage.spanish),
            (1, AppLanguage.russian), (2, AppLanguage.russian),
            (5, AppLanguage.russian), (21, AppLanguage.russian)
        ] {
            let value = L10n.plural("hooks.words", count: count, language: language)
            XCTAssertFalse(value.hasPrefix("hooks.words"), "\(language) plural \(count) fell back to the key")
        }
    }

    func testTheKeysUsedByWP2ViewsExist() {
        let keys = [
            "ai.review.closeHelp",
            "ai.analyzeCurrentSceneHelp",
            "settings.ai.subscription.dismissHelp",
            "settings.ai.subscription.activityFallback",
            "settings.ai.subscription.activityFallbackHelp",
            "settings.ai.subscription.secondsFormat",
            "settings.ai.subscription.recoveredTitle",
            "settings.ai.subscription.recoveredMessage",
            "error.dismiss",
            "aiTask.rehook",
            "aiError.issue.unknownProviderKind"
        ]

        for key in keys {
            for language in [AppLanguage.english, .russian, .spanish] {
                XCTAssertNotEqual(L10n.tr(key, language: language), key, "missing \(key) in \(language)")
            }
        }
    }
}
