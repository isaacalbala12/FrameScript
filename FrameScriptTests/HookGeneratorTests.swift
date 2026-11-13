import AppKit
import Foundation
@testable import FrameScript
import FrameScriptCore
import XCTest

@MainActor
final class HookGeneratorTests: XCTestCase {
    // MARK: - Prompts

    func testHookSystemPromptContainsVoiceConstraintsAndLanguage() {
        let prompt = PromptBuilder().systemPrompt(for: .hook, language: .spanish)

        XCTAssertTrue(prompt.contains("Respond only in Spanish."))
        XCTAssertTrue(prompt.contains("simracing"))
        XCTAssertTrue(prompt.contains("first 15 seconds"))
        XCTAssertTrue(prompt.contains("Never exceed the word budget"))
        XCTAssertTrue(prompt.contains("First sentence 12 words or fewer"))
        XCTAssertTrue(prompt.contains("canonical labels, never translated"))
        XCTAssertTrue(prompt.contains("en el vídeo de hoy"))
        XCTAssertTrue(prompt.contains("no olvides suscribirte"))
        XCTAssertTrue(prompt.contains("en conclusión"))
        XCTAssertTrue(prompt.contains("Never invent facts"))
        XCTAssertTrue(prompt.contains("onScreenText"))
        XCTAssertTrue(prompt.contains("pregunta"))
        XCTAssertTrue(prompt.contains("contraste"))
        XCTAssertTrue(prompt.contains("promesa"))
    }

    func testRehookSystemPromptContainsAnchorAndBudgetConstraints() {
        let prompt = PromptBuilder().systemPrompt(for: .rehook, language: .russian)

        XCTAssertTrue(prompt.contains("Respond only in Russian."))
        XCTAssertTrue(prompt.contains("IMMEDIATELY BEFORE the anchor"))
        XCTAssertTrue(prompt.contains("Never exceed the word budget"))
        XCTAssertTrue(prompt.contains("No structure announcements"))
        XCTAssertTrue(prompt.contains("copy one supplied anchor sentence exactly"))
        XCTAssertTrue(prompt.contains("además"))
        XCTAssertTrue(prompt.contains("not summarise"))
        XCTAssertTrue(prompt.contains("bridges"))
    }

    func testHookUserPromptCarriesProjectThesisPromiseSceneAndNextScene() throws {
        let project = SampleData.demoProject(language: .spanish)
        project.topic = "La 3.0 arregla el online, pero llega cuatro meses tarde."
        project.videoType = "Análisis de actualización"
        project.targetDuration = 660
        project.publishingPacks["es"] = PublishingPack(
            description: "La promesa es comprobar si la actualización devuelve las ganas de jugar online. Separamos lo confirmado de lo que sigue siendo una promesa."
        )
        let scene = try XCTUnwrap(HookContextBuilder.hookScene(in: project))
        let wordsPerMinute = HookContextBuilder.wordsPerMinute(project: project, configured: 150)
        let context = HookContextBuilder.hookContext(
            project: project,
            scene: scene,
            wordsPerMinute: wordsPerMinute
        )

        let prompt = HookPromptBuilder.hookUserPrompt(context)

        XCTAssertTrue(prompt.contains("Project title: \(project.title)"))
        XCTAssertTrue(prompt.contains("Video type: Análisis de actualización"))
        XCTAssertTrue(prompt.contains("Target duration: 11:00"))
        XCTAssertTrue(prompt.contains("Thesis: La 3.0 arregla el online"))
        XCTAssertTrue(prompt.contains("Promise: La promesa es comprobar"))
        XCTAssertTrue(prompt.contains("Hook scene: \(scene.title)"))
        XCTAssertTrue(prompt.contains(scene.scriptText))
        XCTAssertTrue(prompt.contains("Next scene: \(project.scenes.sortedByOrder[1].title)"))
        XCTAssertTrue(prompt.contains("15 s ≈ 37 spoken words"))
        XCTAssertTrue(prompt.contains("Aim for 80–100 % of 37"))
        XCTAssertTrue(prompt.contains("This replaces the opening paragraph"))
        XCTAssertTrue(prompt.contains("\"hooks\""))
    }

    func testRehookUserPromptCarriesAnchorsContextAndBudget() throws {
        let project = makeLongProject()
        let scene = try XCTUnwrap(project.scenes.first)
        let wordsPerMinute = 150.0
        let positions = RehookPlanner.positions(in: scene.scriptText, wordsPerMinute: wordsPerMinute)
        XCTAssertFalse(positions.isEmpty)
        let context = HookContextBuilder.rehookContext(
            project: project,
            scene: scene,
            positions: positions,
            wordsPerMinute: wordsPerMinute
        )

        let prompt = HookPromptBuilder.rehookUserPrompt(context)

        XCTAssertTrue(prompt.contains("Project title: \(project.title)"))
        XCTAssertTrue(prompt.contains("Scene: \(scene.title)"))
        XCTAssertTrue(prompt.contains("Maximum bridge length: 6 s ≈ 15 spoken words"))
        XCTAssertTrue(prompt.contains("Aim for 80–100 % of 15"))
        XCTAssertTrue(prompt.contains("spoken right before its anchor"))
        for position in positions {
            XCTAssertTrue(prompt.contains("Anchor: \(position.anchor)"))
        }
        XCTAssertTrue(prompt.contains("Context before:"))
        XCTAssertTrue(prompt.contains("Context after:"))
        XCTAssertTrue(prompt.contains("\"bridges\""))
    }

    func testWordBudgetUsesTheEffectiveRate() {
        XCTAssertEqual(HookPromptBuilder.wordBudget(seconds: 15, wordsPerMinute: 150), 37)
        XCTAssertEqual(HookPromptBuilder.wordBudget(seconds: 6, wordsPerMinute: 150), 15)
        XCTAssertEqual(HookPromptBuilder.wordBudget(seconds: 15, wordsPerMinute: 0), 37)
        XCTAssertEqual(HookPromptBuilder.wordBudget(seconds: 15, wordsPerMinute: 180), 45)
    }

    func testPromptBudgetAtSlowRateStaysWithinSpokenLimits() {
        let hookBudget = HookPromptBuilder.wordBudget(seconds: 15, wordsPerMinute: 110)
        XCTAssertEqual(hookBudget, 27)
        let hookText = Array(repeating: "palabra", count: hookBudget).joined(separator: " ")
        XCTAssertLessThanOrEqual(ScriptMarkup.estimateDuration(hookText, wordsPerMinute: 110), 15)

        let rehookBudget = HookPromptBuilder.wordBudget(seconds: 6, wordsPerMinute: 110)
        XCTAssertEqual(rehookBudget, 11)
        let rehookText = Array(repeating: "palabra", count: rehookBudget).joined(separator: " ")
        XCTAssertLessThanOrEqual(ScriptMarkup.estimateDuration(rehookText, wordsPerMinute: 110), 6)
    }

    func testHookScenePrefersTheMarkedHookThenTheFirstScene() {
        let fallback = FrameProject(title: "Sin hook", scenes: [
            Scene(order: 0, sectionType: .problem, title: "Introducción", scriptText: "Texto.")
        ])
        XCTAssertEqual(HookContextBuilder.hookScene(in: fallback)?.title, "Introducción")

        let marked = FrameProject(title: "Con hook", scenes: [
            Scene(order: 0, sectionType: .problem, title: "Introducción", scriptText: "Texto."),
            Scene(order: 1, sectionType: .hook, title: "Gancho marcado", scriptText: "Gancho.")
        ])
        XCTAssertEqual(HookContextBuilder.hookScene(in: marked)?.title, "Gancho marcado")
    }

    func testEffectiveWordsPerMinutePrefersLearnedRate() {
        let project = FrameProject(title: "Ritmo", scenes: [])
        project.primaryLanguage = "es"
        project.learnedWordsPerMinuteByLanguage["es"] = 168

        XCTAssertEqual(HookContextBuilder.wordsPerMinute(project: project, configured: 150), 168)
        project.learnedWordsPerMinuteByLanguage["es"] = 0
        XCTAssertEqual(HookContextBuilder.wordsPerMinute(project: project, configured: 0), 150)
    }

    func testProjectPrimaryLanguageIsTheFallbackBeforeTheInterface() {
        XCTAssertEqual(HookContextBuilder.appLanguage(forPrimaryLanguageCode: "es-ES"), .spanish)
        XCTAssertEqual(HookContextBuilder.appLanguage(forPrimaryLanguageCode: "english"), .english)
        XCTAssertEqual(HookContextBuilder.appLanguage(forPrimaryLanguageCode: "ru-RU"), .russian)
        XCTAssertNil(HookContextBuilder.appLanguage(forPrimaryLanguageCode: "fr"))

        let project = FrameProject(title: "Idioma", primaryLanguage: "es")
        XCTAssertEqual(
            HookContextBuilder.scriptLanguage(project: project, sceneText: "", interfaceLanguage: .english),
            .spanish
        )
        XCTAssertEqual(
            HookContextBuilder.scriptLanguage(project: project, sceneText: "Hola", interfaceLanguage: .russian),
            .spanish
        )

        project.primaryLanguage = "fr"
        XCTAssertEqual(
            HookContextBuilder.scriptLanguage(project: project, sceneText: "", interfaceLanguage: .russian),
            .russian
        )
    }

    // MARK: - Service

    func testHookGenerationUsesScriptLanguageAndParsesFencedJSON() async throws {
        let provider = HookTestProvider(LLMResponse(text: """
        ```json
        {"hooks":[
          {"angle":"pregunta","text":"La 3.0 promete arreglar el online. ¿Te devuelve las ganas de volver?","onScreenText":"¿Volverías?"},
          {"angle":"dato","text":"Cuatro meses tarde, tres cambios y una pregunta que nadie responde.","onScreenText":""}
        ]}
        ```
        """))
        let project = makeShortProject()
        project.topic = "La actualización llega tarde."
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        open(project, in: appState)

        let result = try await appState.generateHookSuggestions()

        XCTAssertEqual(result.hooks.count, 2)
        XCTAssertEqual(result.hooks.first?.angle, "pregunta")
        XCTAssertEqual(result.hooks.first?.onScreenText, "¿Volverías?")
        XCTAssertEqual(
            result.language,
            PromptBuilder().responseLanguage(for: project.scenes[0].scriptText, fallback: appState.currentLanguage)
        )
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.task, .hook)
        XCTAssertTrue(request.userPrompt.contains("Thesis: La actualización llega tarde."))
        XCTAssertTrue(request.userPrompt.contains(project.scenes[0].scriptText))
        XCTAssertGreaterThanOrEqual(request.maxTokens, 900)
        let promptLanguage = PromptBuilder().responseLanguage(
            for: project.scenes[0].scriptText,
            fallback: appState.currentLanguage
        )
        XCTAssertTrue(request.systemPrompt.contains("Respond only in \(promptLanguage == .spanish ? "Spanish" : "English")."))
    }

    func testHookGenerationUsesSpanishWhenTheScriptIsSpanish() async throws {
        let provider = HookTestProvider(LLMResponse(text: #"{"hooks":[{"angle":"pregunta","text":"¿Merece la pena volver al online con esta actualización?"}]}"#))
        let project = SampleData.demoProject(language: .spanish)
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        open(project, in: appState)

        let result = try await appState.generateHookSuggestions()

        XCTAssertEqual(result.language, .spanish)
        XCTAssertTrue(provider.requests.first?.systemPrompt.contains("Respond only in Spanish.") == true)
        XCTAssertTrue(provider.requests.first?.userPrompt.contains("Gancho") == true)
    }

    func testHookGenerationFallsBackToProjectPrimaryLanguageWhenTheSceneIsEmpty() async throws {
        let provider = HookTestProvider(LLMResponse(text: #"{"hooks":[{"angle":"dato","text":"Un gancho de reserva con un dato concreto."}]}"#))
        let project = makeShortProject()
        project.primaryLanguage = "es"
        project.scenes[0].scriptText = ""
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        appState.settings.generalPreferences.language = .english
        open(project, in: appState)

        let result = try await appState.generateHookSuggestions()

        XCTAssertEqual(result.language, .spanish)
        XCTAssertTrue(provider.requests.first?.systemPrompt.contains("Respond only in Spanish.") == true)
    }

    func testHookGenerationSurfacesTruncationInsteadOfParsingPartialJSON() async throws {
        let provider = HookTestProvider(LLMResponse(text: #"{"hooks":[{"angle":"dato","text":"Un gancho a medias"#, finishReason: "length"))
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        open(makeShortProject(), in: appState)

        do {
            _ = try await appState.generateHookSuggestions()
            XCTFail("Expected truncated response")
        } catch let error as HookServiceError {
            XCTAssertEqual(error, .truncated)
            XCTAssertEqual(HookLocalization.errorKey(for: error), "hooks.error.truncated")
        }
    }

    func testDisabledProviderIsReportedAsALocalizedConfigurationError() async throws {
        let provider = HookTestProvider(LLMResponse(text: "{}"))
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .disabled
        open(makeShortProject(), in: appState)

        do {
            _ = try await appState.generateHookSuggestions()
            XCTFail("Expected disabled provider")
        } catch let error as HookServiceError {
            XCTAssertEqual(error, .providerDisabled)
            XCTAssertEqual(HookLocalization.errorKey(for: error), "hooks.error.disabled")
            XCTAssertEqual(provider.calls, 0)
        }
    }

    func testShortSceneOutsideTheVideoMidpointSkipsTheNetworkCall() async throws {
        let provider = HookTestProvider(LLMResponse(text: "{}"))
        let short = Scene(
            order: 0,
            sectionType: .hook,
            title: "Gancho",
            scriptText: "Uno empieza aquí. Dos sigue el ritmo. Tres cierra la idea."
        )
        let long = Scene(
            order: 1,
            sectionType: .explanation,
            title: "Explicación",
            scriptText: (1...30)
                .map { "Frase número \($0) con diez palabras para probar el plan." }
                .joined(separator: " ")
        )
        let project = FrameProject(title: "Proyecto corto", scenes: short.scenesWithSelf(long))
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        open(project, in: appState)
        appState.editorState.selectedSceneID = short.id

        let result = try await appState.generateRehookSuggestions()

        XCTAssertTrue(result.positions.isEmpty)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertEqual(provider.calls, 0)
    }

    func testRehookGenerationUsesPlannedAnchorsAndParsesBridges() async throws {
        let project = makeLongProject()
        let scene = try XCTUnwrap(project.scenes.first)
        let positions = RehookPlanner.positions(in: scene.scriptText, wordsPerMinute: 150)
        XCTAssertEqual(positions.count, 2)
        let entries = positions.enumerated().map { index, position in
            #"{"text":"Puente número \#(index + 1) para seguir viendo el análisis.","anchor":"\#(position.anchor)"}"#
        }.joined(separator: ",")
        let provider = HookTestProvider(LLMResponse(text: #"{"bridges":[\#(entries)]}"#))
        let appState = makeAppState(provider: provider)
        appState.settings.aiPreferences.provider = .openAICompatible
        open(project, in: appState)
        appState.editorState.selectedSceneID = scene.id

        let result = try await appState.generateRehookSuggestions()

        XCTAssertEqual(result.positions.count, 2)
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertEqual(Set(result.suggestions.map(\.anchor)), Set(positions.map(\.anchor)))
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.task, .rehook)
        XCTAssertTrue(request.userPrompt.contains("Maximum bridge length: 6 s"))
        for position in positions {
            XCTAssertTrue(request.userPrompt.contains(position.anchor))
        }
    }

    // MARK: - Insertion

    func testInsertHookReplacesTheFirstParagraphAndUndoesInOneStep() throws {
        let project = makeShortProject()
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let scene = try XCTUnwrap(project.scenes.first)
        let previous = scene.scriptText
        let suggestion = HookSuggestion(
            angle: "contraste",
            text: "Nuevo gancho.",
            onScreenText: "Pantalla",
            wordCount: 2,
            estimatedSeconds: 0.8
        )
        let undoManager = UndoManager()

        undoManager.beginUndoGrouping()
        XCTAssertTrue(appState.insertHookSuggestion(suggestion, sceneID: scene.id, undoManager: undoManager))
        undoManager.endUndoGrouping()

        XCTAssertEqual(scene.scriptText, "Nuevo gancho.\n[TEXTO: Pantalla]\n\nResto del guion.")
        undoManager.undo()
        XCTAssertEqual(scene.scriptText, previous)
        undoManager.redo()
        XCTAssertEqual(scene.scriptText, "Nuevo gancho.\n[TEXTO: Pantalla]\n\nResto del guion.")
    }

    func testHookInsertUsesTheGeneratedSceneID() throws {
        let first = Scene(
            order: 0,
            sectionType: .hook,
            title: "Primer gancho",
            scriptText: "Gancho A.\n\nResto A."
        )
        let second = Scene(
            order: 1,
            sectionType: .hook,
            title: "Segundo gancho",
            scriptText: "Gancho B.\n\nResto B."
        )
        let project = FrameProject(title: "Dos ganchos", scenes: [first, second])
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let suggestion = HookSuggestion(
            angle: "dato",
            text: "Nuevo gancho.",
            wordCount: 2,
            estimatedSeconds: 0.8
        )

        // The sheet generated for the first scene; make it stop being the
        // default hook scene before insertion.
        first.sectionType = .problem
        XCTAssertTrue(appState.insertHookSuggestion(suggestion, sceneID: first.id))

        XCTAssertEqual(first.scriptText, "Nuevo gancho.\n\nResto A.")
        XCTAssertEqual(second.scriptText, "Gancho B.\n\nResto B.")
    }

    func testOverLimitHookIsRejectedByTheInsertionGuard() throws {
        let project = makeShortProject()
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let scene = try XCTUnwrap(project.scenes.first)
        let previous = scene.scriptText
        let suggestion = HookSuggestion(
            angle: "dato",
            text: "Un gancho que claramente se pasa del tiempo permitido.",
            wordCount: 12,
            estimatedSeconds: 16
        )

        XCTAssertFalse(appState.insertHookSuggestion(suggestion, sceneID: scene.id))

        XCTAssertEqual(scene.scriptText, previous)
    }

    func testInsertRehookAddsCueAndBridgeBeforeTheAnchor() throws {
        let project = makeShortProject()
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let scene = try XCTUnwrap(project.scenes.first)
        scene.scriptText = "Uno. Dos. Tres."
        let previous = scene.scriptText
        let range = try XCTUnwrap(HookInsertion.anchorRange(for: "Dos.", in: previous))
        let suggestion = RehookSuggestion(
            text: "Puente.",
            anchor: "Dos.",
            anchorRange: range,
            wordCount: 1,
            estimatedSeconds: 0.4
        )
        let undoManager = UndoManager()

        undoManager.beginUndoGrouping()
        XCTAssertTrue(appState.insertRehookSuggestion(suggestion, sceneID: scene.id, undoManager: undoManager))
        undoManager.endUndoGrouping()

        XCTAssertEqual(scene.scriptText, "Uno.\n\n[RE-HOOK]\nPuente.\n\nDos. Tres.")
        undoManager.undo()
        XCTAssertEqual(scene.scriptText, previous)
    }

    func testRehookFailsWhenTheAnchorDisappeared() throws {
        let project = makeShortProject()
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let scene = try XCTUnwrap(project.scenes.first)
        scene.scriptText = "La frase ha cambiado por completo."
        let suggestion = RehookSuggestion(
            text: "Puente.",
            anchor: "Dos.",
            anchorRange: UTF16Span(location: 0, length: 4),
            wordCount: 1,
            estimatedSeconds: 0.4
        )

        XCTAssertFalse(appState.insertRehookSuggestion(suggestion, sceneID: scene.id))
        XCTAssertEqual(scene.scriptText, "La frase ha cambiado por completo.")
    }

    func testDuplicateAnchorKeepsThePlannedOccurrence() throws {
        let project = makeShortProject()
        let appState = makeAppState(provider: HookTestProvider(LLMResponse(text: "{}")))
        open(project, in: appState)
        let scene = try XCTUnwrap(project.scenes.first)
        scene.scriptText = "Dos. Uno. Dos. Tres."
        let previous = scene.scriptText
        let secondRange = (previous as NSString).range(of: "Dos.", options: .backwards)
        let suggestion = RehookSuggestion(
            text: "Puente.",
            anchor: "Dos.",
            anchorRange: UTF16Span(location: secondRange.location, length: secondRange.length),
            wordCount: 1,
            estimatedSeconds: 0.4
        )

        XCTAssertTrue(appState.insertRehookSuggestion(suggestion, sceneID: scene.id))

        XCTAssertEqual(scene.scriptText, "Dos. Uno.\n\n[RE-HOOK]\nPuente.\n\nDos. Tres.")
    }

    // MARK: - Localization

    func testFeatureTableIsMergedIntoAllThreeLanguages() {
        XCTAssertEqual(L10n.tr("menu.generateHook", language: .english), "Generate Hook…")
        XCTAssertEqual(L10n.tr("hooks.insert", language: .spanish), "Insertar")
        XCTAssertEqual(L10n.tr("hooks.error.missingKey", language: .russian), "Добавьте API-ключ провайдера в настройках.")
        XCTAssertEqual(L10n.tr("hooks.angle.question", language: .spanish), "Pregunta")
    }

    func testAngleLabelsFallBackToTheProviderLabel() {
        XCTAssertEqual(HookLocalization.angle("dato", language: .spanish), "Dato")
        XCTAssertEqual(HookLocalization.angle("CONTRASTE", language: .english), "Contrast")
        XCTAssertEqual(HookLocalization.angle("цифра", language: .russian), "Данные")
        XCTAssertEqual(HookLocalization.angle("", language: .russian), "Угол")
        XCTAssertEqual(HookLocalization.angle("curiosidad", language: .english), "Curiosidad")
    }

    func testMockRehookEchoesTheFirstPromptAnchor() throws {
        let prompt = "1. Anchor: Uno. Dos.\n2. Anchor: Tres."
        let response = MockLLMProvider.rehookResponse(for: prompt)
        let anchors = [
            RehookPosition(anchor: "Uno. Dos.", anchorRange: UTF16Span(location: 0, length: 9), sentenceIndex: 1, reason: .longScene),
            RehookPosition(anchor: "Tres.", anchorRange: UTF16Span(location: 10, length: 5), sentenceIndex: 2, reason: .longScene)
        ]

        let suggestions = try HookResponseParser.parseRehooks(
            response.text,
            anchors: anchors,
            wordsPerMinute: 150
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.anchor, "Uno. Dos.")
    }

    func testProviderErrorsMapToLocalizedHookKeys() {
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.missingAPIKey), "hooks.error.missingKey")
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.httpStatus(401, nil)), "hooks.error.auth")
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.httpStatus(402, nil)), "hooks.error.credit")
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.httpStatus(429, nil)), "hooks.error.rateLimit")
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.httpStatus(503, nil)), "hooks.error.server")
        XCTAssertEqual(HookLocalization.errorKey(for: LLMProviderError.network("1")), "hooks.error.network")
        XCTAssertEqual(HookLocalization.errorKey(for: HookParsingError.invalidJSON), "hooks.error.malformed")
        XCTAssertEqual(HookLocalization.errorKey(for: HookParsingError.noSuggestions), "hooks.error.empty")
        XCTAssertEqual(HookLocalization.errorKey(for: HookParsingError.noValidAnchors), "hooks.error.anchorMissing")
        XCTAssertEqual(HookLocalization.errorKey(for: HookServiceError.truncated), "hooks.error.truncated")
        XCTAssertEqual(HookLocalization.errorKey(for: HookGenerationError.noScene), "hooks.error.noScene")
    }

    func testPalettePresentationWaitsForThePaletteToDismiss() {
        let presenter = HookSheetPresenter()

        presenter.presentAfterPaletteDismissal(.rehook)
        XCTAssertNil(presenter.request)

        presenter.presentPendingRequest()
        XCTAssertEqual(presenter.request?.mode, .rehook)

        presenter.presentPendingRequest()
        XCTAssertEqual(presenter.request?.mode, .rehook)
    }

    // MARK: - Fixtures

    private func makeShortProject() -> FrameProject {
        FrameProject(title: "Proyecto de prueba", scenes: [
            Scene(
                order: 0,
                sectionType: .hook,
                title: "Gancho",
                scriptText: "Gancho viejo.\n\nResto del guion."
            ),
            Scene(
                order: 1,
                sectionType: .problem,
                title: "Problema",
                scriptText: "Este es el contexto del problema."
            )
        ])
    }

    private func makeLongProject() -> FrameProject {
        let text = (1...30)
            .map { "Frase número \($0) con diez palabras para probar el plan." }
            .joined(separator: " ")
        return FrameProject(title: "Proyecto largo", scenes: [
            Scene(order: 0, sectionType: .hook, title: "Gancho", scriptText: text)
        ])
    }

    private func open(_ project: FrameProject, in appState: AppState) {
        appState.projectStore.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: true)
        appState.editorState.selectedSceneID = project.scenes.sortedByOrder.first?.id
        appState.settings.editorPreferences.wordsPerMinute = 150
    }

    private func makeAppState(provider: any LLMProviderProtocol) -> AppState {
        AppState(dependencies: AppDependencies(
            rewriteService: RewriteService(provider: provider),
            analysisService: AnalysisService(provider: provider),
            exportService: ExportService(),
            llmProvider: provider,
            providerCredentials: ProviderCredentialSession(reader: { _ in "secret" })
        ))
    }
}

@MainActor
private final class HookTestProvider: LLMProviderProtocol {
    private(set) var requests: [LLMRequest] = []
    private(set) var calls = 0
    private let response: LLMResponse

    init(_ response: LLMResponse) {
        self.response = response
    }

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        calls += 1
        requests.append(request)
        return response
    }
}

private extension Scene {
    /// Small helper so a test can keep two scenes while creating them inline.
    func scenesWithSelf(_ other: Scene) -> [Scene] {
        [self, other]
    }
}
