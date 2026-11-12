import Foundation
import FrameScriptCore

enum HookGenerationError: Error, Equatable {
    case noScene
}

@MainActor
extension AppState {
    /// The first scene marked as a hook, or the project's first scene.
    var hookScene: Scene? {
        HookContextBuilder.hookScene(in: project)
    }

    var hookWordsPerMinute: Double {
        HookContextBuilder.wordsPerMinute(
            project: project,
            configured: settings.editorPreferences.wordsPerMinute
        )
    }

    // MARK: - Generation

    func generateHookSuggestions() async throws -> HookGenerationResult {
        guard hasOpenProject, let scene = hookScene else {
            throw HookGenerationError.noScene
        }
        let provider = settings.aiPreferences.provider
        guard provider != .disabled else { throw HookServiceError.providerDisabled }
        let apiKey = try providerAPIKey(for: provider)
        let service = HookService(provider: dependencies.llmProvider)
        return try await service.generateHooks(
            scene: scene,
            project: project,
            settings: settings.aiPreferences,
            interfaceLanguage: currentLanguage,
            wordsPerMinute: hookWordsPerMinute,
            apiKey: apiKey
        )
    }

    func generateRehookSuggestions() async throws -> RehookGenerationResult {
        guard hasOpenProject, let scene = selectedScene else {
            throw HookGenerationError.noScene
        }

        let wordsPerMinute = hookWordsPerMinute
        let positions = rehookPositions(for: scene, wordsPerMinute: wordsPerMinute)
        let language = PromptBuilder().responseLanguage(
            for: scene.scriptText,
            fallback: currentLanguage
        )
        let sceneSeconds = ScriptMarkup.estimateDuration(
            scene.scriptText,
            wordsPerMinute: wordsPerMinute
        )
        let sceneWords = ScriptMarkup.spokenWordCount(scene.scriptText)

        guard !positions.isEmpty else {
            return RehookGenerationResult(
                sceneID: scene.id,
                sceneTitle: scene.title,
                sceneDuration: sceneSeconds,
                sceneWordCount: sceneWords,
                wordsPerMinute: wordsPerMinute,
                language: language,
                positions: [],
                suggestions: []
            )
        }

        let provider = settings.aiPreferences.provider
        guard provider != .disabled else { throw HookServiceError.providerDisabled }
        let apiKey = try providerAPIKey(for: provider)
        let service = HookService(provider: dependencies.llmProvider)
        return try await service.generateRehooks(
            scene: scene,
            project: project,
            positions: positions,
            settings: settings.aiPreferences,
            interfaceLanguage: currentLanguage,
            wordsPerMinute: wordsPerMinute,
            apiKey: apiKey
        )
    }

    /// Long scenes get internal positions; shorter scenes only when they cover
    /// the 40–60% window of the full video.
    func rehookPositions(for scene: Scene, wordsPerMinute: Double) -> [RehookPosition] {
        let ordered = project.scenes.sortedByOrder
        var start: TimeInterval = 0
        var sceneStart: TimeInterval = 0
        var total: TimeInterval = 0
        var found = false

        for candidate in ordered {
            let duration = ScriptMarkup.estimateDuration(
                candidate.scriptText,
                wordsPerMinute: wordsPerMinute
            )
            if candidate.id == scene.id {
                sceneStart = start
                found = true
            }
            start += duration
            total += duration
        }

        guard found, total > 0 else { return [] }
        return RehookPlanner.positions(
            in: scene.scriptText,
            wordsPerMinute: wordsPerMinute,
            sceneStartSeconds: sceneStart,
            videoDurationSeconds: total
        )
    }

    // MARK: - Insertion

    @discardableResult
    func insertHookSuggestion(
        _ suggestion: HookSuggestion,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard suggestion.isWithinLimit, let scene = hookScene else { return false }
        let previousText = scene.scriptText
        let updatedText = HookInsertion.replacingHook(in: previousText, with: suggestion.text)
        guard updatedText != previousText else { return true }
        applyHookText(
            updatedText,
            sceneID: scene.id,
            previousText: previousText,
            actionKey: "hooks.insertAction",
            undoManager: undoManager
        )
        return true
    }

    @discardableResult
    func insertRehookSuggestion(
        _ suggestion: RehookSuggestion,
        sceneID: UUID,
        undoManager: UndoManager? = nil
    ) -> Bool {
        guard suggestion.isWithinLimit,
              let scene = project.scenes.first(where: { $0.id == sceneID }) else {
            return false
        }
        let previousText = scene.scriptText
        // Keep the exact planned position while it is still valid; otherwise
        // resolve the anchor against the live text.
        let range: UTF16Span
        if HookInsertion.matchesAnchor(suggestion.anchor, at: suggestion.anchorRange, in: previousText) {
            range = suggestion.anchorRange
        } else if let resolved = HookInsertion.anchorRange(for: suggestion.anchor, in: previousText) {
            range = resolved
        } else {
            return false
        }
        guard let updatedText = HookInsertion.insertingRehook(
            in: previousText,
            before: range,
            rehook: suggestion.text
        ),
        updatedText != previousText else {
            return false
        }
        applyHookText(
            updatedText,
            sceneID: sceneID,
            previousText: previousText,
            actionKey: "hooks.insertRehookAction",
            undoManager: undoManager
        )
        return true
    }

    /// Commits one text replacement and registers exactly one undo step.
    private func applyHookText(
        _ text: String,
        sceneID: UUID,
        previousText: String,
        actionKey: String,
        undoManager: UndoManager?
    ) {
        let manager = undoManager ?? projectWindow?.undoManager
        manager?.registerUndo(withTarget: self) { target in
            target.applyHookText(
                previousText,
                sceneID: sceneID,
                previousText: text,
                actionKey: actionKey,
                undoManager: manager
            )
        }
        manager?.setActionName(localized(actionKey))
        commitScriptTextChange(sceneID: sceneID, previousText: previousText, text: text)
    }
}
