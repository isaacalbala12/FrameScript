import Foundation
import Security
@testable import FrameScript
import XCTest

@MainActor
final class ErrorHandlingTests: FrameScriptTestCase {
    func testErrorCenterPresentsQueuesPromotesAndDeduplicates() {
        let center = ErrorCenter()
        let first = AppError(kind: .projectRead)
        let duplicate = AppError(kind: .projectRead)
        let second = AppError(kind: .projectWrite)

        center.present(first)
        XCTAssertEqual(center.presentedError?.kind, .projectRead)
        center.present(duplicate)
        center.present(second)
        XCTAssertEqual(center.presentedError?.kind, .projectRead)

        center.dismissCurrent()
        XCTAssertEqual(center.presentedError?.kind, .projectWrite)
        center.dismissCurrent()
        XCTAssertNil(center.presentedError)
    }

    func testCancellationIsIgnored() {
        let center = ErrorCenter()
        center.present(AppError.ai(CancellationError()))
        XCTAssertNil(center.presentedError)
    }

    func testAutosaveErrorRemainsSuppressedAfterDismissal() {
        let center = ErrorCenter()
        let failure = AppError(kind: .autosave, context: AppErrorContext(diagnosticCode: "disk-full"), recoveryAction: .saveAs)

        center.presentAutosave(failure)
        center.dismissCurrent()
        center.presentAutosave(failure)

        XCTAssertNil(center.presentedError)
    }

    func testSuccessfulSaveResetsAutosaveSuppression() {
        let center = ErrorCenter()
        let failure = AppError(kind: .autosave, context: AppErrorContext(diagnosticCode: "disk-full"), recoveryAction: .saveAs)
        center.presentAutosave(failure)
        center.dismissCurrent()

        center.clearAutosaveFailureSuppression()
        center.presentAutosave(failure)

        XCTAssertEqual(center.presentedError?.kind, .autosave)
    }

    func testNewNoticeReplacesOldNotice() {
        let center = ErrorCenter()
        center.showNotice(AppNotice(kind: .recentRemoved))
        center.showNotice(AppNotice(kind: .apiKeySaved))
        XCTAssertEqual(center.notice?.kind, .apiKeySaved)
    }

    func testEnglishAndRussianPresentationsAreNonEmpty() {
        for kind in [AppErrorKind.projectRead, .settingsWrite, .aiAuthentication, .export] {
            let error = AppError(kind: kind, recoveryAction: .openAISettings)
            for language in [AppLanguage.english, .russian] {
                let presentation = error.presentation(language: language)
                XCTAssertFalse(presentation.title.isEmpty)
                XCTAssertFalse(presentation.message.isEmpty)
                XCTAssertFalse(presentation.recoverySuggestion?.isEmpty ?? true)
            }
        }
    }

    func testCorruptedSettingsDataIsPreserved() {
        let defaults = makeDefaults()
        let original = Data("{broken".utf8)
        defaults.set(original, forKey: "settings")

        let store = SettingsStore(userDefaults: defaults, key: "settings")

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(store.errorEvent?.kind, .settingsRead)
        XCTAssertEqual(defaults.data(forKey: "settings"), original)
    }

    func testSettingsEncodingFailureIsReported() {
        enum EncodingFailure: Error { case failed }
        let store = SettingsStore(settings: .defaults, userDefaults: makeDefaults(), encoder: { _ in throw EncodingFailure.failed })
        store.settings.generalPreferences.autosaveEnabled.toggle()
        XCTAssertEqual(store.errorEvent?.kind, .settingsWrite)
    }

    func testKeychainStatusMappingUsesOperationKind() {
        let failure = KeychainError.unhandledStatus(errSecAuthFailed)
        XCTAssertEqual(AppError.keychain(failure, operation: .read)?.kind, .keychainRead)
        XCTAssertEqual(AppError.keychain(failure, operation: .write)?.kind, .keychainWrite)
        XCTAssertEqual(AppError.keychain(failure, operation: .delete)?.kind, .keychainDelete)
    }

    func testUnsupportedProjectVersionMapsCorrectly() {
        let mapped = AppError.project(FrameScriptFileError.unsupportedVersion(99), fileURL: nil, operation: .read)
        XCTAssertEqual(mapped?.kind, .unsupportedProjectVersion)
    }

    func testMissingFileAndCorruptedJSONMapDifferently() throws {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let corrupted: Error
        do {
            _ = try JSONDecoder().decode(FrameScriptFile.self, from: Data("{".utf8))
            return XCTFail("Expected decoding to fail")
        } catch {
            corrupted = error
        }
        XCTAssertEqual(AppError.project(missing, fileURL: nil, operation: .read)?.kind, .projectMissing)
        XCTAssertEqual(AppError.project(corrupted, fileURL: nil, operation: .read)?.kind, .corruptedProject)
    }

    func testMissingWriteDestinationOffersSaveAsWhileReadRemainsMissing() {
        let missing = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)

        let write = AppError.project(missing, fileURL: nil, operation: .write)
        XCTAssertEqual(write?.kind, .projectWrite)
        XCTAssertEqual(write?.recoveryAction, .saveAs)

        let readMissing = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let read = AppError.project(readMissing, fileURL: nil, operation: .read)
        XCTAssertEqual(read?.kind, .projectMissing)
        XCTAssertNil(read?.recoveryAction)
    }

    func testAIErrorMappingsAreDistinct() {
        XCTAssertEqual(AppError.ai(LLMProviderError.httpStatus(401, nil))?.kind, .aiAuthentication)
        XCTAssertEqual(AppError.ai(LLMProviderError.httpStatus(429, nil))?.kind, .aiRateLimit)
        XCTAssertEqual(AppError.ai(LLMProviderError.network("-1009"))?.kind, .aiNetwork)
        XCTAssertEqual(AppError.ai(LLMProviderError.httpStatus(404, nil))?.kind, .aiModelUnavailable)
        XCTAssertEqual(AppError.ai(LLMProviderError.malformedResponse(nil))?.kind, .aiMalformedResponse)
        XCTAssertEqual(AppError.ai(GenerationError.invalidJSON)?.kind, .aiMalformedResponse)
    }

    func testOfflineAITransportStillMapsToNetworkError() {
        XCTAssertEqual(AppError.ai(URLError(.notConnectedToInternet))?.kind, .aiNetwork)
    }

    func testMalformedResponseAlertsNeverExposeParserDiagnostics() throws {
        let error = try XCTUnwrap(AppError.ai(LLMProviderError.malformedResponse("The provider did not return a structured analysis response.")))

        for language in [AppLanguage.english, .russian] {
            let message = error.presentation(language: language).message
            XCTAssertFalse(message.contains("structured analysis response"))
            XCTAssertFalse(message.contains("analysis.invalid"))
        }
    }

    func testFailedKeychainSavePreventsAIConnectionRequest() async {
        enum ExpectedFailure: Error { case keychain }
        var didRequestConnection = false
        let request = LLMRequest(
            task: .autocomplete,
            provider: .googleAIStudio,
            baseURL: OpenAICompatibleLLMProvider.defaultBaseURL(for: .googleAIStudio),
            systemPrompt: "",
            userPrompt: "",
            model: AIProviderConfigurationStore.defaultModel(for: .googleAIStudio),
            temperature: 0,
            maxTokens: 128
        )

        do {
            try await AIConnectionTester.saveKeyAndTest(
                pendingAPIKey: "secret",
                saveKey: { _ in throw ExpectedFailure.keychain },
                acquireKey: { "stored-key" },
                request: request,
                test: { _, _ in
                    didRequestConnection = true
                }
            )
            XCTFail("Expected Keychain save failure")
        } catch ExpectedFailure.keychain {
            XCTAssertFalse(didRequestConnection)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGoogleAIStudioEndpointAndKeychainAccount() throws {
        let baseURL = OpenAICompatibleLLMProvider.defaultBaseURL(for: .googleAIStudio)
        let endpoint = try OpenAICompatibleLLMProvider.endpointURL(baseURL: baseURL)

        XCTAssertEqual(endpoint.absoluteString, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        XCTAssertEqual(AIProviderConfigurationStore.defaultModel(for: .googleAIStudio), "gemini-3.5-flash")
        XCTAssertEqual(AIProviderKind.googleAIStudio.keychainAccount, "FrameScript.GoogleAIStudio")
        XCTAssertNotEqual(AIProviderKind.googleAIStudio.keychainAccount, AIProviderKind.openRouter.keychainAccount)
    }

    func testProviderSpecificSettingsRemainSeparate() {
        let defaults = makeDefaults()
        let store = AIProviderConfigurationStore(userDefaults: defaults)
        let google = AIProviderConfiguration(model: "gemini-custom", baseURL: "https://google.example/v1")
        let groq = AIProviderConfiguration(model: "groq-custom", baseURL: "https://groq.example/v1")

        store.save(google, for: .googleAIStudio)
        store.save(groq, for: .groq)

        XCTAssertEqual(store.load(for: .googleAIStudio), google)
        XCTAssertEqual(store.load(for: .groq), groq)
    }

    func testStoredKeyMetadataCanBeClearedWithoutReadingKeychain() {
        let defaults = makeDefaults()
        let store = AIProviderConfigurationStore(userDefaults: defaults)

        store.setHasStoredKey(true, for: .groq)
        XCTAssertTrue(store.hasStoredKey(for: .groq))
        store.setHasStoredKey(false, for: .groq)
        XCTAssertFalse(store.hasStoredKey(for: .groq))
    }

    func testUnchangedRecentValidationDoesNotEncodeAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErrorHandlingTests-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Project.fscr")
        try "test".write(to: file, atomically: true, encoding: .utf8)
        let defaults = makeDefaults()
        var encodeCount = 0
        let store = RecentProjectStore(
            userDefaults: defaults,
            storageKey: "recents",
            legacyPathsKey: "legacy",
            bookmarkCreator: { Data($0.path.utf8) },
            bookmarkResolver: { data, _ in URL(fileURLWithPath: String(decoding: data, as: UTF8.self)) },
            entriesEncoder: {
                encodeCount += 1
                return try JSONEncoder().encode($0)
            },
            securityScope: SecurityScopedResourceAccess(start: { _ in false }, stop: { _ in })
        )
        try store.add(url: file)
        XCTAssertEqual(encodeCount, 1)

        store.validateEntriesNow()

        XCTAssertEqual(encodeCount, 1)
    }

    func testModeSwitcherAccessibilityKeysExistInBothLanguages() {
        for key in ["accessibility.selected", "accessibility.notSelected"] {
            for language in [AppLanguage.english, .russian] {
                let value = L10n.tr(key, language: language)
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key)
            }
        }
    }
}
