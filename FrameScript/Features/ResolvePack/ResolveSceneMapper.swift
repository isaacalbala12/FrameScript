import Foundation
import FrameScriptCore

/// Result of mapping the app document onto the UI-free export model.
struct ResolveSceneMappingResult: Sendable {
    let scenes: [ExportScene]
    let warnings: [String]
}

/// Turns `FrameProject` scenes into `ExportScene` values for the Resolve pack.
///
/// Every scene's start is the sum of the durations before it, so the pack can
/// honour a real take (which is usually shorter or longer than the estimate)
/// without leaving a gap or shifting later markers. Anchored cues are placed
/// with the same learned pace as the estimate and scaled into the chosen
/// duration.
struct ResolveSceneMapper: Sendable {
    var languageCode: String
    var durationSource: ResolvePackDurationSource
    var wordsPerMinute: Double
    var pauseDefaults: PauseDefaults = .standard
    /// Frame rate used to separate cues that share an anchor. Resolve stores
    /// one marker per frame, so two cues at the same word must be nudged to
    /// neighbouring frames or one of them loses its colour.
    var frameRate: FrameRate = .fps25
    /// Rhythm warnings already computed by `RhythmReviewCenter`, keyed by scene.
    var rhythmWarningsByScene: [UUID: [RhythmWarning]] = [:]

    func map(project: FrameProject) -> ResolveSceneMappingResult {
        let sorted = project.scenes.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order == rhs.element.order { return lhs.offset < rhs.offset }
                return lhs.element.order < rhs.element.order
            }
            .map(\.element)

        let targetLanguage = DurationLanguage.normalized(languageCode)
        let primaryLanguage = DurationLanguage.normalized(project.primaryLanguage)
        var output: [ExportScene] = []
        var warnings: [String] = []
        var start: TimeInterval = 0

        for scene in sorted {
            let variant = scene.languageVariants.first { variant in
                DurationLanguage.normalized(variant.languageCode) == targetLanguage
                    && !variant.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let text = variant?.text ?? scene.scriptText
            if variant == nil,
               !targetLanguage.isEmpty,
               targetLanguage != primaryLanguage,
               !scene.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append(
                    "«\(scene.title)» no tiene texto en «\(targetLanguage)»; se usa el original."
                )
            }

            let estimate = Self.estimate(
                text,
                wordsPerMinute: wordsPerMinute,
                defaults: pauseDefaults
            )
            let records = DurationTakeRecords.make(
                scene: scene,
                primaryLanguage: project.primaryLanguage
            )
            let selected = DurationTakeSelector.selectedTake(
                from: records,
                language: languageCode
            )
            let realDuration = selected.map(\.take.duration)
            let resolvedDuration: TimeInterval
            switch durationSource {
            case .realTakes:
                resolvedDuration = realDuration ?? estimate
            case .estimates:
                resolvedDuration = estimate
            }
            let duration = Self.sanitizedDuration(resolvedDuration)
            if duration <= 0,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append(
                    "«\(scene.title)» no tiene una duración estimable; sus marcadores pueden coincidir con la escena siguiente."
                )
            }

            let originalEstimate = Self.estimate(
                scene.scriptText,
                wordsPerMinute: wordsPerMinute,
                defaults: pauseDefaults
            )
            let scale = originalEstimate > 0.001 ? duration / originalEstimate : 1

            func cueSeconds(for anchor: TextAnchor?) -> TimeInterval {
                guard let current = TextAnchorRepair.current(anchor, in: scene.scriptText) else {
                    return 0
                }
                let seconds = TimelineAnchoring.seconds(
                    text: scene.scriptText,
                    utf16Offset: current.startUTF16,
                    wordsPerMinute: wordsPerMinute,
                    defaults: pauseDefaults
                )
                return Self.scaled(seconds, by: scale, into: duration)
            }

            var markers: [ExportMarker] = []
            var sceneWarnings: [String] = []
            var editingNotes: [String] = []
            var rehookOffsets: [TimeInterval] = []

            if !scene.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editingNotes.append(scene.notes)
            }

            // MARK: B-roll

            var shots: [ExportShot] = []
            for item in scene.bRollItems {
                let source = Self.sourceTag(for: item.sourceType)
                let label = Self.sourceLabel(for: item.sourceType)
                let summary = ExportTextSanitizer.collapseWhitespace(item.descriptionText)
                let name = summary.isEmpty ? label : "\(label) · \(summary)"
                let offset = cueSeconds(for: item.textAnchor)

                var noteParts = [item.notes, item.framing, item.motion, item.mood]
                    .map(ExportTextSanitizer.collapseWhitespace)
                    .filter { !$0.isEmpty }
                if item.duration > 0 {
                    noteParts.append(DurationFormat.clock(seconds: Int(item.duration.rounded())))
                }

                markers.append(
                    ExportMarker(
                        offset: offset,
                        name: name,
                        note: noteParts.joined(separator: " · "),
                        color: ResolveMarkerLegend.color(for: source)
                    )
                )
                shots.append(
                    ExportShot(
                        summary: item.descriptionText,
                        source: source,
                        status: Self.shotStatus(for: item.status),
                        notes: noteParts.joined(separator: " · "),
                        offset: offset
                    )
                )

                if item.textAnchor == nil || TextAnchorRepair.current(item.textAnchor, in: scene.scriptText) == nil {
                    warnings.append(
                        "«\(scene.title)»: el B-roll «\(summary.isEmpty ? label : summary)» no tiene ancla; se coloca al inicio de la escena."
                    )
                }
            }

            // MARK: Editing cues

            for item in scene.editingItems {
                let offset = cueSeconds(for: item.textAnchor)
                if Self.isReHook(item) {
                    rehookOffsets.append(offset)
                }

                let notes = [item.notes, item.emphasis, item.transition, item.zoom, item.sfx, item.cutStyle]
                    .map(ExportTextSanitizer.collapseWhitespace)
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")

                let subtitle = item.subtitleStyle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !subtitle.isEmpty {
                    markers.append(
                        ExportMarker(
                            offset: offset,
                            name: "RÓTULO · \(subtitle)",
                            note: notes,
                            color: ResolveMarkerLegend.graphic
                        )
                    )
                }

                let graphics = item.graphics.trimmingCharacters(in: .whitespacesAndNewlines)
                if !graphics.isEmpty {
                    let isTable = graphics.folding(
                        options: [.diacriticInsensitive, .caseInsensitive],
                        locale: Locale(identifier: "es_ES")
                    ).contains("tabla")
                    markers.append(
                        ExportMarker(
                            offset: offset,
                            name: "\(isTable ? "TABLA" : "GRÁFICO") · \(graphics)",
                            note: notes,
                            color: ResolveMarkerLegend.graphic
                        )
                    )
                }

                let music = item.musicCue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !music.isEmpty {
                    markers.append(
                        ExportMarker(
                            offset: offset,
                            name: "MÚSICA · \(music)",
                            note: notes,
                            color: ResolveMarkerLegend.music
                        )
                    )
                }

                let parts = [item.cutStyle, item.transition, item.emphasis, item.zoom, item.sfx, item.musicCue, item.graphics, item.subtitleStyle, item.notes]
                    .map(ExportTextSanitizer.collapseWhitespace)
                    .filter { !$0.isEmpty }
                if !parts.isEmpty {
                    editingNotes.append(parts.joined(separator: " · "))
                }
            }

            // MARK: Script cues

            for token in ScriptMarkup.parse(scene.scriptText, defaults: pauseDefaults) {
                guard case .cue(let label, let payload) = token.kind else { continue }
                let offset = Self.scaled(
                    TimelineAnchoring.seconds(
                        text: scene.scriptText,
                        utf16Offset: token.range.location,
                        wordsPerMinute: wordsPerMinute,
                        defaults: pauseDefaults
                    ),
                    by: scale,
                    into: duration
                )
                let normalized = label.folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "es_ES")
                ).uppercased()
                let payloadText = ExportTextSanitizer.collapseWhitespace(payload)
                let name = Self.composed(Self.cueName(for: normalized), payloadText)

                switch normalized {
                case "RE-HOOK", "REHOOK":
                    rehookOffsets.append(offset)
                case "ROTULO", "TEXTO", "TEXTO EN PANTALLA":
                    markers.append(ExportMarker(offset: offset, name: Self.composed("RÓTULO", payloadText), color: ResolveMarkerLegend.graphic))
                case "TABLA", "TABLA COMPARATIVA", "COMPARATIVA":
                    markers.append(ExportMarker(offset: offset, name: Self.composed("TABLA", payloadText), color: ResolveMarkerLegend.graphic))
                case "MUSICA":
                    markers.append(ExportMarker(offset: offset, name: Self.composed("MÚSICA", payloadText), color: ResolveMarkerLegend.music))
                case "IMAGEN", "B-ROLL", "BROLL":
                    markers.append(ExportMarker(offset: offset, name: Self.composed("IMAGEN", payloadText), color: ResolveMarkerLegend.screen))
                default:
                    markers.append(ExportMarker(offset: offset, name: name, note: payloadText, color: .cyan))
                }
            }

            // MARK: Re-hooks

            let uniqueRehooks = Array(
                Set(rehookOffsets.map { ($0 * 1_000).rounded() / 1_000 })
            ).sorted()
            for offset in uniqueRehooks where offset >= 0.5 {
                markers.append(
                    ExportMarker(
                        offset: offset,
                        name: "RE-HOOK",
                        note: "Punto de re-enganche",
                        color: ResolveMarkerLegend.rehook
                    )
                )
            }

            // MARK: Rigor / rhythm

            let rigorOffset = duration > 2 ? 1.0 : max(0, duration / 2)
            let claims = project.claims.filter {
                $0.sceneIDs.contains(scene.id) && $0.status != .confirmed
            }
            for claim in claims {
                let status = Self.claimStatusLabel(claim.status)
                markers.append(
                    ExportMarker(
                        offset: rigorOffset,
                        name: "RIGOR · claim \(status)",
                        note: claim.text,
                        color: ResolveMarkerLegend.warning
                    )
                )
                sceneWarnings.append("Claim \(status): \(claim.text)")
            }

            for warning in rhythmWarningsByScene[scene.id] ?? [] {
                let message = RhythmWarningFormatter.text(for: warning, language: .spanish)
                switch warning.kind {
                case .longSentence, .noVisualChange:
                    let offset = Self.scaled(
                        TimelineAnchoring.seconds(
                            text: scene.scriptText,
                            utf16Offset: warning.range.location,
                            wordsPerMinute: wordsPerMinute,
                            defaults: pauseDefaults
                        ),
                        by: scale,
                        into: duration
                    )
                    markers.append(
                        ExportMarker(
                            offset: offset,
                            name: "RITMO · \(Self.rhythmLabel(warning.kind))",
                            note: message,
                            color: ResolveMarkerLegend.warning
                        )
                    )
                case .longHook, .sceneLengthOutlier:
                    sceneWarnings.append(message)
                }
            }

            let exportedScene = ExportScene(
                id: scene.id,
                title: scene.title,
                start: start,
                duration: duration,
                isRehook: !uniqueRehooks.isEmpty,
                markers: Self.spreadCollisions(
                    markers,
                    duration: duration,
                    frameDuration: 1 / frameRate.framesPerSecond,
                    reservedFrames: uniqueRehooks.isEmpty ? [0] : [0, 1]
                ),
                shots: shots,
                scriptExcerpt: text.isEmpty ? nil : text,
                editingNotes: Self.deduplicated(editingNotes),
                warnings: Self.deduplicated(sceneWarnings),
                targetDuration: scene.targetDuration,
                chapterTitle: scene.title,
                includesInChapters: true
            )
            output.append(exportedScene)
            start += duration
        }

        return ResolveSceneMappingResult(
            scenes: output,
            warnings: Self.deduplicated(warnings)
        )
    }

    // MARK: - Mapping helpers

    static func sourceTag(for source: BRollSourceType) -> ExportSourceTag {
        switch source {
        case .talkingHead, .stockFootage, .productShot, .custom: .cam
        case .screenRecording: .obs
        case .screenshot, .memeInsert: .web
        case .animation, .infographic, .textOnScreen: .graphic
        }
    }

    static func sourceLabel(for source: BRollSourceType) -> String {
        switch sourceTag(for: source) {
        case .cam: "CAM"
        case .obs: "OBS"
        case .capture: "CAPTURA"
        case .web: "WEB"
        case .music: "MÚSICA"
        case .graphic: "GRÁFICO"
        }
    }

    static func shotStatus(for status: BRollStatus) -> ExportShotStatus {
        switch status {
        case .idea, .planned: .pending
        case .sourced: .recorded
        case .done: .approved
        }
    }

    static func isReHook(_ item: EditingItem) -> Bool {
        item.cutStyle == "RE-HOOK" || item.notes.contains("Cue original: [RE-HOOK]")
    }

    private static func cueName(for normalizedLabel: String) -> String {
        switch normalizedLabel {
        case "RE-HOOK", "REHOOK": "RE-HOOK"
        case "ROTULO", "TEXTO", "TEXTO EN PANTALLA": "RÓTULO"
        case "TABLA", "TABLA COMPARATIVA", "COMPARATIVA": "TABLA"
        case "MUSICA": "MÚSICA"
        case "IMAGEN", "B-ROLL", "BROLL": "IMAGEN"
        default: normalizedLabel
        }
    }

    private static func composed(_ label: String, _ payload: String) -> String {
        payload.isEmpty ? label : "\(label) · \(payload)"
    }

    private static func claimStatusLabel(_ status: ClaimStatus) -> String {
        switch status {
        case .confirmed: "confirmado"
        case .probable: "probable"
        case .rumor: "rumor"
        }
    }

    private static func rhythmLabel(_ kind: RhythmWarning.Kind) -> String {
        switch kind {
        case .longSentence: "frase larga"
        case .noVisualChange: "sin cambio visual"
        case .longHook: "hook largo"
        case .sceneLengthOutlier: "escena larga"
        }
    }

    private static func estimate(
        _ text: String,
        wordsPerMinute: Double,
        defaults: PauseDefaults
    ) -> TimeInterval {
        let value = ScriptMarkup.estimateDuration(
            text,
            wordsPerMinute: wordsPerMinute,
            defaults: defaults
        )
        return value.isFinite ? max(0, value) : 0
    }

    private static func sanitizedDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(0, min(value, DurationLimits.maximumDuration))
    }

    private static func scaled(
        _ seconds: TimeInterval,
        by scale: TimeInterval,
        into duration: TimeInterval
    ) -> TimeInterval {
        let value = seconds * scale
        guard value.isFinite else { return 0 }
        return min(max(0, value), max(0, duration))
    }

    /// Moves cues that land on the same frame to the next free frame.
    ///
    /// Resolve keeps one marker per frame, and the pack should not silently
    /// lose the colour of a cue that shares a word with another one (for
    /// example a rótulo, a table and a music cue on the same anchor). Frames 0
    /// and 1 are reserved for the scene marker and the re-hook marker.
    static func spreadCollisions(
        _ markers: [ExportMarker],
        duration: TimeInterval,
        frameDuration: TimeInterval,
        reservedFrames: Set<Int>
    ) -> [ExportMarker] {
        guard frameDuration > 0, duration > 0, !markers.isEmpty else { return markers }
        let maxFrame = max(0, Int((duration / frameDuration).rounded()) - 1)
        guard maxFrame > 0 else { return markers }

        var used = reservedFrames.filter { $0 <= maxFrame }
        var adjusted: [ExportMarker] = []
        adjusted.reserveCapacity(markers.count)

        for marker in markers.sorted(by: { $0.offset < $1.offset }) {
            var frame = Int((max(0, marker.offset) / frameDuration).rounded())
            frame = min(max(0, frame), maxFrame)
            while used.contains(frame), frame < maxFrame {
                frame += 1
            }
            if used.contains(frame) {
                frame = maxFrame
                while used.contains(frame), frame > 0 {
                    frame -= 1
                }
            }
            used.insert(frame)
            var result = marker
            result.offset = Double(frame) * frameDuration
            adjusted.append(result)
        }
        return adjusted
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
