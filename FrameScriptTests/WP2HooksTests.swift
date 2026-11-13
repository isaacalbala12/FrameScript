import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

/// WP2 regressions for the hook pipeline: subscription providers, thesis
/// source, per-language reading speed, analysis parsing and formatting.
@MainActor
final class WP2HooksTests: FrameScriptTestCase {
    // MARK: Helpers

    /// An app state whose Keychain reader always fails, like a subscription
    /// provider with no API key stored.
    private func makeAppState(
        project: FrameProject,
        provider: AIProviderKind,
        wordsPerMinute: Int = 150
    ) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.aiPreferences.provider = provider
        settings.editorPreferences.wordsPerMinute = wordsPerMinute
        let projectStore = ProjectStore(project: project)
        projectStore.openProject(project, fileURL: nil, wordsPerMinute: wordsPerMinute, markUnsaved: false)
        let providerStub = MockLLMProvider()
        return AppState(
            projectStore: projectStore,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            dependencies: AppDependencies(
                rewriteService: RewriteService(provider: providerStub),
                analysisService: AnalysisService(provider: providerStub),
                exportService: ExportService(),
                llmProvider: providerStub,
                providerCredentials: ProviderCredentialSession(reader: { _ in
                    throw LLMProviderError.missingAPIKey
                })
            ),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }

    private func longSceneProject() -> FrameProject {
        let sentence = "Esta frase existe solo para que el planificador encuentre un ancla segura en medio de la escena."
        let text = Array(repeating: sentence, count: 40).joined(separator: " ")
        let project = FrameProject(
            title: "Reenganches",
            scenes: [
                Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: text),
                Scene(order: 1, sectionType: .explanation, title: "Desarrollo", scriptText: text),
                Scene(order: 2, sectionType: .cta, title: "Cierre", scriptText: text)
            ]
        )
        project.primaryLanguage = "es"
        return project
    }

    // MARK: Item 1: subscription providers need no Keychain key

    func testHooksSucceedWithASubscriptionProviderAndNoKeychainKey() async throws {
        let appState = makeAppState(
            project: SampleData.demoProject(language: .spanish),
            provider: .t3Code
        )

        let result = try await appState.generateHookSuggestions()

        XCTAssertFalse(result.hooks.isEmpty)
    }

    func testRehooksSucceedWithASubscriptionProviderAndNoKeychainKey() async throws {
        let project = longSceneProject()
        let appState = makeAppState(project: project, provider: .claudeCode)
        appState.editorState.selectedSceneID = project.scenes.sortedByOrder[1].id

        let result = try await appState.generateRehookSuggestions()

        XCTAssertFalse(result.positions.isEmpty, "the fixture must plan at least one anchor")
        XCTAssertFalse(result.suggestions.isEmpty)
    }

    func testAPIProvidersStillRequireAKeychainKey() async {
        let appState = makeAppState(
            project: SampleData.demoProject(language: .spanish),
            provider: .openRouter
        )

        do {
            _ = try await appState.generateHookSuggestions()
            XCTFail("An API provider without a key must fail")
        } catch let error as LLMProviderError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: Item 5: the thesis is not the escaleta metadata blob

    func testHookThesisStripsTheEscaletaMetadataBlob() throws {
        let project = SampleData.demoProject(language: .spanish)
        let blob = EscaletaProjectNotes.metadataLabel
            + Data(#"{"version":1}"#.utf8).base64EncodedString()
        // The block form is what `EscaletaProjectNotes.encoded()` writes.
        project.topic = "Promesa:\nel online vuelve.\n\nTesis:\nEl garaje sigue siendo lento.\n\n" + blob
        let scene = try XCTUnwrap(HookContextBuilder.hookScene(in: project))

        let context = HookContextBuilder.hookContext(
            project: project,
            scene: scene,
            wordsPerMinute: 150
        )

        XCTAssertEqual(context.thesis, "El garaje sigue siendo lento.")
        XCTAssertFalse(context.thesis.contains(EscaletaProjectNotes.metadataLabel))
        XCTAssertFalse(context.thesis.contains("eyJ2ZXJzaW9uIjoxfQ"))

        // The single-line form some importers produce resolves too.
        project.topic = "Tesis: La tesis en una sola línea.\n\n" + blob
        let inline = HookContextBuilder.hookContext(
            project: project,
            scene: scene,
            wordsPerMinute: 150
        )
        XCTAssertEqual(inline.thesis, "La tesis en una sola línea.")
    }

    func testHookThesisFallsBackToSceneNotesWhenTheTopicIsOnlyTheBlob() throws {
        let project = SampleData.demoProject(language: .spanish)
        let blob = EscaletaProjectNotes.metadataLabel
            + Data(#"{"version":1}"#.utf8).base64EncodedString()
        project.topic = blob
        let scene = try XCTUnwrap(HookContextBuilder.hookScene(in: project))
        scene.notes = "Tesis: La tesis que vive en la escena."

        let context = HookContextBuilder.hookContext(
            project: project,
            scene: scene,
            wordsPerMinute: 150
        )

        XCTAssertEqual(context.thesis, "La tesis que vive en la escena.")
    }

    // MARK: Item 6: per-language reading speed

    func testHookWordsPerMinuteUsesTheEnglishDefault() {
        let project = FrameProject(title: "Rate", scenes: [])
        project.primaryLanguage = "en"
        project.learnedWordsPerMinuteByLanguage = [:]

        XCTAssertEqual(
            HookContextBuilder.wordsPerMinute(project: project, settings: .defaults),
            160
        )
    }

    func testHookWordsPerMinuteUsesTheRussianDefault() {
        let project = FrameProject(title: "Ритм", scenes: [])
        project.primaryLanguage = "ru"
        project.learnedWordsPerMinuteByLanguage = [:]

        XCTAssertEqual(
            HookContextBuilder.wordsPerMinute(project: project, settings: .defaults),
            140
        )
    }

    func testHookWordsPerMinutePrefersTheLearnedRate() {
        let project = FrameProject(title: "Ritmo", scenes: [])
        project.primaryLanguage = "en"
        project.learnedWordsPerMinuteByLanguage["en"] = 168

        XCTAssertEqual(
            HookContextBuilder.wordsPerMinute(project: project, settings: .defaults),
            168
        )
    }

    func testAppStateHookWordsPerMinuteIsPerLanguage() {
        let project = FrameProject(title: "Rate", scenes: [])
        project.primaryLanguage = "en"
        let appState = makeAppState(project: project, provider: .disabled)

        XCTAssertEqual(appState.hookWordsPerMinute, 160)
    }

    // MARK: Item 7: tolerant analysis JSON

    func testAnalysisDecodesJSONThatFollowsProse() throws {
        let response = """
        Here is the JSON:
        {"title":"Hook","severity":"suggestion","message":"Make the opening concrete.","suggestion":"Name the benefit."}
        """

        let analysis = try AnalysisResponse.decode(from: response)

        XCTAssertEqual(analysis.title, "Hook")
        XCTAssertEqual(analysis.message, "Make the opening concrete.")
        XCTAssertEqual(analysis.suggestion, "Name the benefit.")
    }

    func testAnalysisStillRejectsPlainProse() {
        XCTAssertThrowsError(
            try AnalysisResponse.decode(from: "This scene needs a stronger hook.")
        )
    }

    // MARK: Item 15: localized units and plurals

    func testHookWordCountsArePluralized() {
        XCTAssertEqual(HookFormat.words(1, language: .english), "1 word")
        XCTAssertEqual(HookFormat.words(3, language: .english), "3 words")
        XCTAssertEqual(HookFormat.words(1, language: .spanish), "1 palabra")
        XCTAssertEqual(HookFormat.words(3, language: .spanish), "3 palabras")
        XCTAssertEqual(HookFormat.words(1, language: .russian), "1 слово")
        XCTAssertEqual(HookFormat.words(2, language: .russian), "2 слова")
        XCTAssertEqual(HookFormat.words(5, language: .russian), "5 слов")
    }

    func testHookSecondsUseTheAppLanguageDecimalSeparator() {
        XCTAssertTrue(HookFormat.seconds(3.5, language: .spanish).contains("3,5"))
        XCTAssertTrue(HookFormat.seconds(3.5, language: .english).contains("3.5"))
        XCTAssertTrue(HookFormat.seconds(3.5, language: .russian).contains("3,5"))
    }
}
