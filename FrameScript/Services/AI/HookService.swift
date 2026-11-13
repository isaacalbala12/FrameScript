import Foundation
import FrameScriptCore

// MARK: - Results

struct HookGenerationResult: Equatable {
    let sceneID: UUID
    let sceneTitle: String
    let sceneDuration: TimeInterval
    let sceneWordCount: Int
    let wordsPerMinute: Double
    let language: AppLanguage
    let hooks: [HookSuggestion]
}

struct RehookGenerationResult: Equatable {
    let sceneID: UUID
    let sceneTitle: String
    let sceneDuration: TimeInterval
    let sceneWordCount: Int
    let wordsPerMinute: Double
    let language: AppLanguage
    let positions: [RehookPosition]
    let suggestions: [RehookSuggestion]
}

@MainActor
protocol HookServicing {
    func generateHooks(
        scene: Scene,
        project: FrameProject,
        settings: AIPreferences,
        interfaceLanguage: AppLanguage,
        wordsPerMinute: Double,
        apiKey: String
    ) async throws -> HookGenerationResult

    func generateRehooks(
        scene: Scene,
        project: FrameProject,
        positions: [RehookPosition],
        settings: AIPreferences,
        interfaceLanguage: AppLanguage,
        wordsPerMinute: Double,
        apiKey: String
    ) async throws -> RehookGenerationResult
}

// MARK: - Context

struct HookProjectContext: Equatable {
    let projectTitle: String
    let thesis: String
    let promise: String
    let videoType: String
    let targetDuration: String
    let sceneTitle: String
    let sceneText: String
    let sceneNotes: String
    let sceneSeconds: TimeInterval
    let sceneWordCount: Int
    let wordsPerMinute: Double
    let nextSceneTitle: String
    let nextSceneSummary: String
}

struct RehookProjectContext: Equatable {
    let projectTitle: String
    let thesis: String
    let sceneTitle: String
    let sceneText: String
    let positions: [RehookPosition]
    let sentences: [RhythmSentence]
    let sceneSeconds: TimeInterval
    let sceneWordCount: Int
    let wordsPerMinute: Double
}

enum HookContextBuilder {
    /// The scene marked as the hook, or the first scene of a project that has
    /// no explicit hook section.
    static func hookScene(in project: FrameProject) -> Scene? {
        let ordered = project.scenes.sortedByOrder
        return ordered.first(where: { $0.sectionType == .hook }) ?? ordered.first
    }

    static func wordsPerMinute(project: FrameProject, configured: Int) -> Double {
        if let learned = project.learnedWordsPerMinuteByLanguage[project.primaryLanguage],
           learned.isFinite,
           learned > 0 {
            return learned
        }
        let value = Double(configured)
        return value.isFinite && value > 0 ? value : 150
    }

    /// Script language detection falls back to the project's declared primary
    /// language before the interface language. A short or empty scene must not
    /// silently switch a Spanish project to English prompts.
    static func scriptLanguage(
        project: FrameProject,
        sceneText: String,
        interfaceLanguage: AppLanguage
    ) -> AppLanguage {
        let fallback = appLanguage(forPrimaryLanguageCode: project.primaryLanguage) ?? interfaceLanguage
        return PromptBuilder().responseLanguage(for: sceneText, fallback: fallback)
    }

    static func appLanguage(forPrimaryLanguageCode code: String) -> AppLanguage? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "spanish": return .spanish
        case "english": return .english
        case "russian": return .russian
        default: break
        }
        if normalized.hasPrefix("es") { return .spanish }
        if normalized.hasPrefix("en") { return .english }
        if normalized.hasPrefix("ru") { return .russian }
        return nil
    }

    static func hookContext(
        project: FrameProject,
        scene: Scene,
        wordsPerMinute: Double
    ) -> HookProjectContext {
        let ordered = project.scenes.sortedByOrder
        let next = ordered.firstIndex(where: { $0.id == scene.id }).flatMap { index in
            ordered.indices.contains(index + 1) ? ordered[index + 1] : nil
        }
        let pack = publishingPack(for: project)

        return HookProjectContext(
            projectTitle: projectTitle(project: project, pack: pack),
            thesis: thesis(project: project, scene: scene),
            promise: promise(project: project, scene: scene, pack: pack),
            videoType: project.videoType.trimmingCharacters(in: .whitespacesAndNewlines),
            targetDuration: project.targetDuration.map(DurationEstimator.formatted) ?? "",
            sceneTitle: scene.title,
            sceneText: truncated(scene.scriptText, limit: 2_400),
            sceneNotes: truncated(scene.notes, limit: 320),
            sceneSeconds: ScriptMarkup.estimateDuration(scene.scriptText, wordsPerMinute: wordsPerMinute),
            sceneWordCount: ScriptMarkup.spokenWordCount(scene.scriptText),
            wordsPerMinute: wordsPerMinute,
            nextSceneTitle: next?.title ?? "",
            nextSceneSummary: next.map { summary(of: $0.scriptText) } ?? ""
        )
    }

    static func rehookContext(
        project: FrameProject,
        scene: Scene,
        positions: [RehookPosition],
        wordsPerMinute: Double
    ) -> RehookProjectContext {
        RehookProjectContext(
            projectTitle: project.title,
            thesis: thesis(project: project, scene: scene),
            sceneTitle: scene.title,
            sceneText: truncated(scene.scriptText, limit: 4_000),
            positions: positions,
            sentences: RhythmSentenceSplitter.sentences(in: scene.scriptText),
            sceneSeconds: ScriptMarkup.estimateDuration(scene.scriptText, wordsPerMinute: wordsPerMinute),
            sceneWordCount: ScriptMarkup.spokenWordCount(scene.scriptText),
            wordsPerMinute: wordsPerMinute
        )
    }

    // MARK: Notes and publishing

    private static func publishingPack(for project: FrameProject) -> PublishingPack? {
        if let pack = project.publishingPacks[project.primaryLanguage] {
            return pack
        }
        return project.publishingPacks.keys.sorted().first.flatMap { project.publishingPacks[$0] }
    }

    private static func projectTitle(project: FrameProject, pack: PublishingPack?) -> String {
        let title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let chosen = pack?.chosenTitle.trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty {
            return chosen
        }
        return pack?.titleCandidates.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func thesis(project: FrameProject, scene: Scene) -> String {
        let topic = project.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if !topic.isEmpty { return truncated(topic, limit: 320) }
        return labelledNote(in: scene.notes, keys: ["tesis", "thesis"]) ?? ""
    }

    private static func promise(project: FrameProject, scene: Scene, pack: PublishingPack?) -> String {
        if let note = labelledNote(in: scene.notes, keys: ["promesa", "promise", "promete"]) {
            return note
        }
        guard let description = pack?.description.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return ""
        }
        return summary(of: description, maxCharacters: 320)
    }

    /// Finds a labelled line such as `Promesa: …` or `Tesis: …` in scene notes.
    private static func labelledNote(in notes: String, keys: [String]) -> String? {
        for line in notes.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowercased = trimmed.lowercased()
            guard keys.contains(where: { lowercased.hasPrefix($0) || lowercased.contains("\($0):") }) else {
                continue
            }
            let value: String
            if let colon = trimmed.firstIndex(of: ":") {
                value = String(trimmed[trimmed.index(after: colon)...])
            } else {
                value = trimmed
            }
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return truncated(cleaned, limit: 320) }
        }
        return nil
    }

    private static func summary(of text: String, maxCharacters: Int = 320) -> String {
        let sentences = RhythmSentenceSplitter.sentences(in: text)
        let joined = sentences.prefix(2).map(\.text).joined(separator: " ")
        let value = (joined.isEmpty ? text : joined).trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(value, limit: maxCharacters)
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - Prompt building

enum HookPromptBuilder {
    static func wordBudget(seconds: TimeInterval, wordsPerMinute: Double) -> Int {
        let rate = wordsPerMinute.isFinite && wordsPerMinute > 0 ? wordsPerMinute : 150
        return max(1, Int((seconds * rate / 60).rounded(.down)))
    }

    static func hookUserPrompt(_ context: HookProjectContext) -> String {
        let budget = wordBudget(seconds: HookLimits.maximumHookSeconds, wordsPerMinute: context.wordsPerMinute)
        var lines: [String] = [
            "Project title: \(context.projectTitle)"
        ]
        if !context.videoType.isEmpty {
            lines.append("Video type: \(context.videoType)")
        }
        if !context.targetDuration.isEmpty {
            lines.append("Target duration: \(context.targetDuration)")
        }
        if !context.thesis.isEmpty {
            lines.append("Thesis: \(context.thesis)")
        }
        if !context.promise.isEmpty {
            lines.append("Promise: \(context.promise)")
        }
        lines.append("Hook scene: \(context.sceneTitle)")
        lines.append(
            "Scene duration: \(DurationEstimator.formatted(context.sceneSeconds)) · \(context.sceneWordCount) words · \(Int(context.wordsPerMinute.rounded())) wpm"
        )
        lines.append(
            "Maximum hook length: \(Int(HookLimits.maximumHookSeconds)) s ≈ \(budget) spoken words. Aim for 80–100 % of \(budget). This replaces the opening paragraph: write it to stand alone and flow into the next sentence."
        )
        if !context.sceneNotes.isEmpty {
            lines.append("Hook scene notes: \(context.sceneNotes)")
        }
        lines.append("")
        lines.append("Hook scene text:")
        lines.append(context.sceneText)
        if !context.nextSceneTitle.isEmpty {
            lines.append("")
            lines.append("Next scene: \(context.nextSceneTitle)")
            if !context.nextSceneSummary.isEmpty {
                lines.append("Next scene summary: \(context.nextSceneSummary)")
            }
        }
        lines.append("")
        lines.append(#"Return the JSON object now: {"hooks":[{"angle":"…","text":"…","onScreenText":"…"}]}"#)
        return lines.joined(separator: "\n")
    }

    static func rehookUserPrompt(_ context: RehookProjectContext) -> String {
        let budget = wordBudget(seconds: HookLimits.maximumRehookSeconds, wordsPerMinute: context.wordsPerMinute)
        var lines: [String] = []
        if !context.projectTitle.isEmpty {
            lines.append("Project title: \(context.projectTitle)")
        }
        if !context.thesis.isEmpty {
            lines.append("Thesis: \(context.thesis)")
        }
        lines.append("Scene: \(context.sceneTitle)")
        lines.append(
            "Scene duration: \(DurationEstimator.formatted(context.sceneSeconds)) · \(context.sceneWordCount) words · \(Int(context.wordsPerMinute.rounded())) wpm"
        )
        lines.append(
            "Maximum bridge length: \(Int(HookLimits.maximumRehookSeconds)) s ≈ \(budget) spoken words. Aim for 80–100 % of \(budget). It is spoken right before its anchor."
        )
        lines.append("")

        for (index, position) in context.positions.enumerated() {
            lines.append("\(index + 1). Anchor: \(position.anchor)")
            let before = sentenceText(before: position, in: context.sentences)
            let after = sentenceText(after: position, in: context.sentences)
            if !before.isEmpty { lines.append("   Context before: \(before)") }
            if !after.isEmpty { lines.append("   Context after: \(after)") }
        }

        lines.append("")
        lines.append("Scene text:")
        lines.append(context.sceneText)
        lines.append("")
        lines.append(#"Return the JSON object now: {"bridges":[{"text":"…","anchor":"…"}]}"#)
        return lines.joined(separator: "\n")
    }

    private static func sentenceText(before position: RehookPosition, in sentences: [RhythmSentence]) -> String {
        guard position.sentenceIndex > 0, sentences.indices.contains(position.sentenceIndex - 1) else { return "" }
        return sentences[position.sentenceIndex - 1].text
    }

    private static func sentenceText(after position: RehookPosition, in sentences: [RhythmSentence]) -> String {
        guard sentences.indices.contains(position.sentenceIndex + 1) else { return "" }
        return sentences[position.sentenceIndex + 1].text
    }
}

// MARK: - Service

@MainActor
struct HookService: HookServicing {
    var provider: any LLMProviderProtocol
    var promptBuilder = PromptBuilder()

    func generateHooks(
        scene: Scene,
        project: FrameProject,
        settings: AIPreferences,
        interfaceLanguage: AppLanguage,
        wordsPerMinute: Double,
        apiKey: String
    ) async throws -> HookGenerationResult {
        guard settings.provider != .disabled else { throw HookServiceError.providerDisabled }

        let language = HookContextBuilder.scriptLanguage(
            project: project,
            sceneText: scene.scriptText,
            interfaceLanguage: interfaceLanguage
        )
        let context = HookContextBuilder.hookContext(
            project: project,
            scene: scene,
            wordsPerMinute: wordsPerMinute
        )
        let request = LLMRequest(
            task: .hook,
            provider: settings.provider,
            baseURL: settings.baseURL,
            systemPrompt: promptBuilder.systemPrompt(for: .hook, language: language),
            userPrompt: HookPromptBuilder.hookUserPrompt(context),
            model: settings.model,
            temperature: settings.temperature,
            maxTokens: max(900, settings.maxTokens)
        )

        let response = try await provider.complete(request: request, apiKey: apiKey)
        try Task.checkCancellation()
        if response.stoppedAtTokenLimit { throw HookServiceError.truncated }
        let hooks = try HookResponseParser.parseHooks(response.text, wordsPerMinute: wordsPerMinute)
        return HookGenerationResult(
            sceneID: scene.id,
            sceneTitle: scene.title,
            sceneDuration: context.sceneSeconds,
            sceneWordCount: context.sceneWordCount,
            wordsPerMinute: wordsPerMinute,
            language: language,
            hooks: hooks
        )
    }

    func generateRehooks(
        scene: Scene,
        project: FrameProject,
        positions: [RehookPosition],
        settings: AIPreferences,
        interfaceLanguage: AppLanguage,
        wordsPerMinute: Double,
        apiKey: String
    ) async throws -> RehookGenerationResult {
        let language = HookContextBuilder.scriptLanguage(
            project: project,
            sceneText: scene.scriptText,
            interfaceLanguage: interfaceLanguage
        )
        let context = HookContextBuilder.rehookContext(
            project: project,
            scene: scene,
            positions: positions,
            wordsPerMinute: wordsPerMinute
        )
        guard !positions.isEmpty else {
            return RehookGenerationResult(
                sceneID: scene.id,
                sceneTitle: scene.title,
                sceneDuration: context.sceneSeconds,
                sceneWordCount: context.sceneWordCount,
                wordsPerMinute: wordsPerMinute,
                language: language,
                positions: [],
                suggestions: []
            )
        }
        guard settings.provider != .disabled else { throw HookServiceError.providerDisabled }

        let request = LLMRequest(
            task: .rehook,
            provider: settings.provider,
            baseURL: settings.baseURL,
            systemPrompt: promptBuilder.systemPrompt(for: .rehook, language: language),
            userPrompt: HookPromptBuilder.rehookUserPrompt(context),
            model: settings.model,
            temperature: settings.temperature,
            maxTokens: max(700, settings.maxTokens)
        )

        let response = try await provider.complete(request: request, apiKey: apiKey)
        try Task.checkCancellation()
        if response.stoppedAtTokenLimit { throw HookServiceError.truncated }
        let suggestions = try HookResponseParser.parseRehooks(
            response.text,
            anchors: positions,
            wordsPerMinute: wordsPerMinute
        )
        return RehookGenerationResult(
            sceneID: scene.id,
            sceneTitle: scene.title,
            sceneDuration: context.sceneSeconds,
            sceneWordCount: context.sceneWordCount,
            wordsPerMinute: wordsPerMinute,
            language: language,
            positions: positions,
            suggestions: suggestions
        )
    }
}
