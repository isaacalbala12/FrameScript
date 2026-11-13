import AppKit
import Foundation
import FrameScriptCore

// MARK: - AI adaptation

/// Structured response from the clip adaptation task.
struct GeneratedClipAdaptation: Equatable {
    var hook: String
    var adaptedText: String
    var onScreenText: String
    var description: String
    var hashtags: [String]

    init(
        hook: String,
        adaptedText: String,
        onScreenText: String,
        description: String,
        hashtags: [String]
    ) {
        self.hook = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        self.adaptedText = adaptedText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onScreenText = onScreenText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hashtags = ClipHashtags.normalize(hashtags)
    }

    init(json: String) throws {
        guard let start = json.firstIndex(of: "{"),
              let end = json.lastIndex(of: "}"),
              start <= end,
              let data = String(json[start...end]).data(using: .utf8) else {
            throw GenerationError.invalidJSON
        }
        let decoded = try JSONDecoder().decode(Payload.self, from: data)
        self.init(
            hook: decoded.hook ?? "",
            adaptedText: decoded.adaptedText ?? "",
            onScreenText: decoded.onScreenText ?? "",
            description: decoded.description ?? "",
            hashtags: decoded.hashtags ?? []
        )
    }

    private struct Payload: Decodable {
        var hook: String?
        var adaptedText: String?
        var onScreenText: String?
        var description: String?
        var hashtags: [String]?
    }
}

/// Hashtag normalisation shared by the editor, the AI response and the export.
enum ClipHashtags {
    static func normalize(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in values {
            var tag = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "")
            guard !tag.isEmpty else { continue }
            if !tag.hasPrefix("#") { tag = "#" + tag }
            guard tag.count > 1 else { continue }
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                result.append(tag)
            }
            if result.count == 10 { break }
        }
        return result
    }

    /// Parses a free-text field such as `#uno, #dos tres` into clean tags.
    static func parse(_ text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        return normalize(text.components(separatedBy: separators))
    }

    static func text(_ values: [String]) -> String {
        normalize(values).joined(separator: " ")
    }
}

/// Prompt text for the adaptation task. Kept pure so the fact rules can be
/// reviewed and tested without a provider.
enum ClipPromptBuilder {
    static func userPrompt(
        clip: FrameScriptDocument.ShortClip,
        sourceText: String
    ) -> String {
        let target = Int((ClipLimits.sanitizedTarget(clip.targetSeconds) ?? ClipLimits.defaultTargetSeconds).rounded())
        return """
        Target duration: \(target) seconds
        Format: \(clip.format.rawValue)
        Existing hook (may be empty): \(clip.hook)
        Existing on-screen text (may be empty): \(clip.onScreenText)

        Source text:
        \(sourceText)
        """
    }

    static let jsonSchema = #"Return only one JSON object with string fields hook, adaptedText, onScreenText, description and an array of strings hashtags. Do not use Markdown fences."#
}

// MARK: - App state

@MainActor
extension AppState {
    // MARK: Reading

    var clips: [ShortClip] { project.clips }

    var clipsSummary: ClipSummary {
        ClipSummaryBuilder.summary(
            clips: project.clips.map(FrameScriptDocument.ShortClip.init(clip:)),
            scenes: clipSourceScenes,
            wordsPerMinute: effectiveWPM()
        )
    }

    func clip(id: UUID) -> ShortClip? {
        project.clips.first { $0.id == id }
    }

    func clipIndex(id: UUID) -> Int? {
        project.clips.firstIndex { $0.id == id }
    }

    /// Language used by a clip's estimate and coverage. Empty means the
    /// project's primary language.
    func clipLanguageCode(_ clip: ShortClip) -> String {
        let code = DurationLanguage.normalized(clip.languageCode)
        return code.isEmpty ? durationProjectLanguage : code
    }

    func clipEstimate(for clip: ShortClip) -> ClipDurationEstimate {
        ClipEstimator.estimate(
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            targetSeconds: clip.targetSeconds,
            wordsPerMinute: effectiveWPM(language: clipLanguageCode(clip)),
            pauseDefaults: settings.editorPreferences.markupPauseDefaults
        )
    }

    func clipStaleness(for clip: ShortClip) -> ClipStalenessReport {
        ClipStaleness.report(
            clip: FrameScriptDocument.ShortClip(clip: clip),
            scenes: clipSourceScenes
        )
    }

    func clipIsStale(_ clip: ShortClip) -> Bool {
        ClipStaleness.isStale(
            clip: FrameScriptDocument.ShortClip(clip: clip),
            scenes: clipSourceScenes
        )
    }

    func clipCoverage(for clip: ShortClip) -> [ClipTakeCoverage] {
        let coreClip = FrameScriptDocument.ShortClip(clip: clip)
        let sceneIDs = Set(coreClip.sourceSceneIDs + [coreClip.anchorSceneID].compactMap { $0 })
        let scenes = project.scenes
            .filter { sceneIDs.contains($0.id) }
            .sortedByOrder
            .map(FrameScriptDocument.Scene.init(scene:))
        return ClipCoverage.takes(
            for: coreClip,
            scenes: scenes,
            primaryLanguage: durationProjectLanguage
        )
    }

    func clipAssets(for clip: ShortClip) -> [ProjectAsset] {
        let coreClip = FrameScriptDocument.ShortClip(clip: clip)
        let sceneIDs = Set(coreClip.sourceSceneIDs + [coreClip.anchorSceneID].compactMap { $0 })
        let scenes = project.scenes
            .filter { sceneIDs.contains($0.id) }
            .sortedByOrder
            .map(FrameScriptDocument.Scene.init(scene:))
        return ClipCoverage.assets(
            for: coreClip,
            scenes: scenes,
            assets: project.assets.map(FrameScriptDocument.ProjectAsset.init(asset:))
        )
        .compactMap { coreAsset in
            project.assets.first { $0.id == coreAsset.id }
        }
    }

    /// Numbers in the generated text that are not in the source. Empty means
    /// the fact guard found nothing to flag.
    func clipFactWarning(for clip: ShortClip) -> [String] {
        let coreClip = FrameScriptDocument.ShortClip(clip: clip)
        let source = ClipSourceExtractor.sourceText(clip: coreClip, scenes: clipSourceScenes)
        let generated = [clip.hook, clip.adaptedText, clip.description].joined(separator: "\n")
        return ClipFactGuard.unsupportedNumbers(in: generated, source: source)
    }

    // MARK: Creating and editing

    @discardableResult
    func createClip(
        sceneIDs: [UUID],
        anchorSceneID: UUID? = nil,
        anchor: TextAnchor? = nil,
        title: String? = nil
    ) -> ShortClip? {
        guard hasOpenProject else { return nil }
        let coreClip = ClipFactory.make(
            title: title ?? defaultClipTitle(sceneIDs: sceneIDs, anchorSceneID: anchorSceneID, anchor: anchor),
            sceneIDs: sceneIDs,
            anchorSceneID: anchorSceneID,
            anchor: anchor.map(FrameScriptDocument.TextAnchor.init(anchor:)),
            targetSeconds: ClipLimits.defaultTargetSeconds,
            format: .reel,
            languageCode: durationProjectLanguage,
            scenes: clipSourceScenes
        )
        let clip = coreClip.makeClip()
        project.clips.append(clip)
        windowState.selectedClipID = clip.id
        selectMode(.clips)
        touchProject()
        return clip
    }

    @discardableResult
    func createClipFromSelectedScene() -> ShortClip? {
        guard let scene = selectedScene else { return nil }
        return createClip(sceneIDs: [scene.id])
    }

    /// The editor context menu and the menu command both land here. A text
    /// selection wins; otherwise the selected scene becomes a whole-scene clip.
    @discardableResult
    func createClipFromEditorSelection() -> ShortClip? {
        guard let scene = selectedScene else { return nil }
        if let anchor = ActiveScriptEditorSession.shared.currentSelectionAnchor(inScene: scene.id) {
            return createClip(sceneIDs: [scene.id], anchorSceneID: scene.id, anchor: anchor)
        }
        return createClip(sceneIDs: [scene.id])
    }

    @discardableResult
    func createClipFromAnchor(sceneID: UUID, anchor: TextAnchor) -> ShortClip? {
        createClip(sceneIDs: [sceneID], anchorSceneID: sceneID, anchor: anchor)
    }

    func updateClip(_ clip: ShortClip) {
        guard let index = clipIndex(id: clip.id) else { return }
        var updated = clip
        updated.targetSeconds = ClipLimits.sanitizedTarget(
            clip.targetSeconds,
            fallback: ClipLimits.defaultTargetSeconds
        )
        updated.hashtags = ClipHashtags.normalize(clip.hashtags)

        if updated.anchor != nil {
            if let anchorSceneID = updated.anchorSceneID {
                if !updated.sourceSceneIDs.contains(anchorSceneID) {
                    updated.sourceSceneIDs.insert(anchorSceneID, at: 0)
                }
            } else if let firstSceneID = updated.sourceSceneIDs.first {
                updated.anchorSceneID = firstSceneID
            } else {
                updated.anchor = nil
                updated.anchorSceneID = nil
            }
        } else {
            updated.anchorSceneID = nil
        }

        var seen: Set<UUID> = []
        updated.sourceSceneIDs = updated.sourceSceneIDs.filter { seen.insert($0).inserted }

        let sourceSelectionChanged = updated.sourceSceneIDs != project.clips[index].sourceSceneIDs
            || updated.anchorSceneID != project.clips[index].anchorSceneID
            || updated.anchor != project.clips[index].anchor
        if sourceSelectionChanged {
            updated = reconciledSourceHashes(
                for: updated,
                previous: project.clips[index]
            )
        }

        guard updated != project.clips[index] else { return }
        project.clips[index] = updated
        touchProject()
    }

    func deleteClip(id: UUID) {
        guard let index = clipIndex(id: id) else { return }
        project.clips.remove(at: index)
        if windowState.selectedClipID == id {
            windowState.selectedClipID = index < project.clips.count ? project.clips[index].id : project.clips.last?.id
        }
        touchProject()
    }

    func duplicateClip(id: UUID) {
        guard let clip = clip(id: id) else { return }
        var copy = clip
        copy.id = UUID()
        copy.title = "\(clip.title) \(localized("clips.copySuffix"))"
        copy.status = .idea
        let insertIndex = (clipIndex(id: id) ?? project.clips.count - 1) + 1
        project.clips.insert(copy, at: min(insertIndex, project.clips.count))
        windowState.selectedClipID = copy.id
        touchProject()
    }

    func markClipReviewed(id: UUID) {
        guard let index = clipIndex(id: id) else { return }
        let reviewed = ClipStaleness.reviewed(
            FrameScriptDocument.ShortClip(clip: project.clips[index]),
            scenes: clipSourceScenes
        )
        project.clips[index] = reviewed.makeClip()
        touchProject()
    }

    func setClipStatus(id: UUID, status: ShortClipStatus) {
        guard let index = clipIndex(id: id) else { return }
        project.clips[index].status = status
        touchProject()
    }

    func setClipFormat(id: UUID, format: ShortClipFormat) {
        guard let index = clipIndex(id: id) else { return }
        project.clips[index].format = format
        touchProject()
    }

    func setClipTarget(id: UUID, seconds: TimeInterval) {
        guard let index = clipIndex(id: id) else { return }
        project.clips[index].targetSeconds = ClipLimits.sanitizedTarget(
            seconds,
            fallback: ClipLimits.defaultTargetSeconds
        )
        touchProject()
    }

    func toggleClipSourceScene(id: UUID, sceneID: UUID) {
        guard let index = clipIndex(id: id) else { return }
        var clip = project.clips[index]
        if let existing = clip.sourceSceneIDs.firstIndex(of: sceneID) {
            clip.sourceSceneIDs.remove(at: existing)
            if clip.anchorSceneID == sceneID {
                clip.anchor = nil
                clip.anchorSceneID = nil
            }
        } else {
            clip.sourceSceneIDs.append(sceneID)
        }
        updateClip(clip)
    }

    func useWholeSceneForClip(id: UUID) {
        guard let index = clipIndex(id: id) else { return }
        var clip = project.clips[index]
        clip.anchor = nil
        clip.anchorSceneID = nil
        updateClip(clip)
    }

    // MARK: AI

    func generateClipAdaptation(id: UUID) async {
        guard let clip = clip(id: id) else { return }
        guard settings.aiPreferences.provider != .disabled else {
            errorCenter.present(AppError(kind: .aiConfiguration, recoveryAction: .openAISettings))
            return
        }
        let coreClip = FrameScriptDocument.ShortClip(clip: clip)
        let source = ClipSourceExtractor.sourceText(clip: coreClip, scenes: clipSourceScenes)
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorCenter.present(AppError(kind: .invalidProjectData))
            return
        }

        do {
            let provider = settings.aiPreferences.provider
            let apiKey = provider.isSubscriptionBacked
                ? ""
                : try dependencies.providerCredentials.apiKey(for: provider)
            let response = try await dependencies.llmProvider.complete(
                request: LLMRequest(
                    task: .clipAdaptation,
                    provider: provider,
                    baseURL: settings.aiPreferences.baseURL,
                    systemPrompt: "\(PromptBuilder().systemPrompt(for: .clipAdaptation, language: .spanish)) \(ClipPromptBuilder.jsonSchema)",
                    userPrompt: ClipPromptBuilder.userPrompt(clip: coreClip, sourceText: source),
                    model: settings.aiPreferences.model,
                    temperature: settings.aiPreferences.temperature,
                    maxTokens: settings.aiPreferences.maxTokens
                ),
                apiKey: apiKey
            )
            let generated = try GeneratedClipAdaptation(json: response.text)
            guard !generated.adaptedText.isEmpty else { throw GenerationError.emptyDescription }
            guard let index = clipIndex(id: id) else { return }
            var updated = project.clips[index]
            updated.hook = generated.hook
            updated.adaptedText = generated.adaptedText
            updated.onScreenText = generated.onScreenText
            updated.description = generated.description
            updated.hashtags = generated.hashtags
            if updated.status == .idea { updated.status = .draft }
            project.clips[index] = updated
            touchProject()
        } catch {
            errorCenter.present(AppError.ai(error))
        }
    }

    // MARK: Export

    var clipExportLabels: ClipExportLabels {
        ClipExportLabels(
            title: localized("clips.export.titleLabel"),
            hook: localized("clips.export.hook"),
            adaptedText: localized("clips.export.adaptedText"),
            onScreenText: localized("clips.export.onScreenText"),
            description: localized("clips.export.description"),
            hashtags: localized("clips.export.hashtags"),
            source: localized("clips.export.source"),
            target: localized("clips.export.target"),
            seconds: localized("clips.export.seconds")
        )
    }

    func clipExportDocument(for clip: ShortClip) -> ClipExportDocument {
        ClipExport.document(
            for: FrameScriptDocument.ShortClip(clip: clip),
            scenes: clipSourceScenes,
            wordsPerMinute: effectiveWPM(language: clipLanguageCode(clip)),
            pauseDefaults: settings.editorPreferences.markupPauseDefaults,
            labels: clipExportLabels
        )
    }

    @discardableResult
    func copyClipExportToPasteboard(id: UUID) -> Bool {
        guard let clip = clip(id: id) else { return false }
        let text = clipExportDocument(for: clip).plainText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    enum ClipMarkerFormat: String {
        case edl
        case fcpxml
    }

    func saveClipMarkers(id: UUID, format: ClipMarkerFormat) {
        guard let clip = clip(id: id) else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(clip.title).\(format.rawValue)"
        panel.message = localized("clips.export.saveMessage")
        if let folder = resolvedDefaultExportFolder() {
            let didStartAccessing = folder.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    folder.stopAccessingSecurityScopedResource()
                }
            }
            panel.directoryURL = folder
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let settings = ExportSettings(
            projectName: clip.title,
            fps: .fps25,
            dropFrame: false,
            startTimecode: .zero
        )
        let coreClip = FrameScriptDocument.ShortClip(clip: clip)
        let wordsPerMinute = effectiveWPM(language: clipLanguageCode(clip))
        let pauseDefaults = self.settings.editorPreferences.markupPauseDefaults
        let content: String = switch format {
        case .edl:
            ClipExport.edl(
                for: coreClip,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults,
                settings: settings,
                labels: clipExportLabels
            )
        case .fcpxml:
            ClipExport.fcpxml(
                for: coreClip,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults,
                settings: settings,
                labels: clipExportLabels
            )
        }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorCenter.present(AppError(kind: .export))
        }
    }

    // MARK: Helpers

    /// Keeps the stale baseline for scenes the clip already used, drops hashes
    /// for removed scenes and samples newly added scenes. Without this,
    /// removing a scene would immediately mark the clip as out of date.
    private func reconciledSourceHashes(
        for updated: ShortClip,
        previous: ShortClip
    ) -> ShortClip {
        var core = FrameScriptDocument.ShortClip(clip: updated)
        let fragments = ClipSourceExtractor.fragments(clip: core, scenes: clipSourceScenes)
        let previousHashes = Dictionary(
            previous.sceneSourceHashes.map { ($0.sceneID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let anchorChanged = previous.anchor != updated.anchor
            || previous.anchorSceneID != updated.anchorSceneID

        var hashes: [FrameScriptDocument.ShortClip.SceneSourceHash] = []
        for fragment in fragments {
            let keepsBaseline = previous.sourceSceneIDs.contains(fragment.sceneID)
                && !(fragment.sceneID == updated.anchorSceneID && anchorChanged)
            if keepsBaseline, let old = previousHashes[fragment.sceneID] {
                hashes.append(
                    FrameScriptDocument.ShortClip.SceneSourceHash(
                        sceneID: old.sceneID,
                        hash: old.hash,
                        sourceText: old.sourceText
                    )
                )
            } else {
                hashes.append(
                    FrameScriptDocument.ShortClip.SceneSourceHash(
                        sceneID: fragment.sceneID,
                        hash: FrameScriptDocument.TextHash.hash(fragment.text),
                        sourceText: fragment.text
                    )
                )
            }
        }
        core.sceneSourceHashes = hashes
        core.sourceHash = ClipSourceHashing.combinedHash(hashes)
        return core.makeClip()
    }

    /// Lightweight copies of every scene. Staleness, estimates and exports only
    /// need the text, so this avoids copying takes and markers on each render.
    var clipSourceScenes: [FrameScriptDocument.Scene] {
        project.scenes.sortedByOrder.map { scene in
            FrameScriptDocument.Scene(
                id: scene.id,
                order: scene.order,
                sectionType: FrameScriptDocument.SectionType(rawValue: scene.sectionType.rawValue) ?? .custom,
                title: scene.title,
                scriptText: scene.scriptText
            )
        }
    }

    private func defaultClipTitle(
        sceneIDs: [UUID],
        anchorSceneID: UUID?,
        anchor: TextAnchor?
    ) -> String {
        let sceneTitle = sceneIDs
            .compactMap { id in project.scenes.first { $0.id == id }?.title }
            .first ?? localized("clips.untitled")
        if anchor != nil {
            return String(format: localized("clips.fromFragment"), sceneTitle)
        }
        return String(format: localized("clips.fromScene"), sceneTitle)
    }
}
