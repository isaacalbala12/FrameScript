import Foundation

/// Localized labels for the text export. The app passes its own table; the
/// Spanish defaults keep the core output useful in tests and tooling.
public struct ClipExportLabels: Sendable, Equatable {
    public var hook: String
    public var adaptedText: String
    public var onScreenText: String
    public var description: String
    public var hashtags: String
    public var source: String
    public var target: String
    public var seconds: String
    public var title: String

    public init(
        title: String = "Clip",
        hook: String = "Gancho",
        adaptedText: String = "Texto adaptado",
        onScreenText: String = "Texto en pantalla",
        description: String = "Descripción",
        hashtags: String = "Hashtags",
        source: String = "Fuente",
        target: String = "objetivo",
        seconds: String = "s"
    ) {
        self.title = title
        self.hook = hook
        self.adaptedText = adaptedText
        self.onScreenText = onScreenText
        self.description = description
        self.hashtags = hashtags
        self.source = source
        self.target = target
        self.seconds = seconds
    }

    public static let spanish = ClipExportLabels()
}

/// Everything a clip publishes, in one value.
public struct ClipExportDocument: Sendable, Equatable {
    public let clipID: UUID
    public let title: String
    public let hook: String
    public let adaptedText: String
    public let onScreenText: String
    public let description: String
    public let hashtags: [String]
    public let format: FrameScriptDocument.ShortClipFormat
    public let targetSeconds: TimeInterval
    public let estimate: ClipDurationEstimate
    public let sourceSceneTitles: [String]
    public let labels: ClipExportLabels

    public init(
        clipID: UUID,
        title: String,
        hook: String,
        adaptedText: String,
        onScreenText: String,
        description: String,
        hashtags: [String],
        format: FrameScriptDocument.ShortClipFormat,
        targetSeconds: TimeInterval,
        estimate: ClipDurationEstimate,
        sourceSceneTitles: [String],
        labels: ClipExportLabels
    ) {
        self.clipID = clipID
        self.title = title
        self.hook = hook
        self.adaptedText = adaptedText
        self.onScreenText = onScreenText
        self.description = description
        self.hashtags = hashtags
        self.format = format
        self.targetSeconds = targetSeconds
        self.estimate = estimate
        self.sourceSceneTitles = sourceSceneTitles
        self.labels = labels
    }

    /// Plain text ready for the clipboard or a `.txt` file.
    public var plainText: String {
        var lines: [String] = [title, ""]
        appendSection(labels.hook, value: hook, extra: secondsLabel(estimate.hookSeconds), to: &lines)
        appendSection(
            labels.adaptedText,
            value: adaptedText,
            extra: "\(secondsLabel(estimate.adaptedSeconds)) · \(labels.target) \(secondsLabel(targetSeconds))",
            to: &lines
        )
        appendSection(labels.onScreenText, value: onScreenText, extra: nil, to: &lines)
        appendSection(labels.description, value: description, extra: nil, to: &lines)
        if !hashtags.isEmpty {
            lines.append("\(labels.hashtags):")
            lines.append(hashtags.joined(separator: " "))
            lines.append("")
        }
        if !sourceSceneTitles.isEmpty {
            lines.append("\(labels.source): \(sourceSceneTitles.joined(separator: " · "))")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Markdown version for notes and documentation.
    public var markdown: String {
        var lines: [String] = ["# \(title)", ""]
        appendMarkdownSection(labels.hook, value: hook, extra: secondsLabel(estimate.hookSeconds), to: &lines)
        appendMarkdownSection(
            labels.adaptedText,
            value: adaptedText,
            extra: "\(secondsLabel(estimate.adaptedSeconds)) · \(labels.target) \(secondsLabel(targetSeconds))",
            to: &lines
        )
        appendMarkdownSection(labels.onScreenText, value: onScreenText, extra: nil, to: &lines)
        appendMarkdownSection(labels.description, value: description, extra: nil, to: &lines)
        if !hashtags.isEmpty {
            lines.append("**\(labels.hashtags)**")
            lines.append("")
            lines.append(hashtags.joined(separator: " "))
            lines.append("")
        }
        if !sourceSceneTitles.isEmpty {
            lines.append("*\(labels.source): \(sourceSceneTitles.joined(separator: " · "))*")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func secondsLabel(_ value: TimeInterval) -> String {
        let rounded = Int(max(0, value).rounded())
        return "\(rounded) \(labels.seconds)"
    }

    private func appendSection(
        _ heading: String,
        value: String,
        extra: String?,
        to lines: inout [String]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let suffix = extra.map { " (\($0))" } ?? ""
        lines.append("\(heading)\(suffix):")
        lines.append(trimmed)
        lines.append("")
    }

    private func appendMarkdownSection(
        _ heading: String,
        value: String,
        extra: String?,
        to lines: inout [String]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let suffix = extra.map { " (\($0))" } ?? ""
        lines.append("**\(heading)**\(suffix)")
        lines.append("")
        lines.append(trimmed)
        lines.append("")
    }
}

/// Builds clip text and Resolve markers on the clip's own time base.
public enum ClipExport {
    public static func document(
        for clip: FrameScriptDocument.ShortClip,
        scenes: [FrameScriptDocument.Scene],
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard,
        labels: ClipExportLabels = .spanish
    ) -> ClipExportDocument {
        let estimate = ClipEstimator.estimate(
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            targetSeconds: clip.targetSeconds,
            wordsPerMinute: wordsPerMinute,
            pauseDefaults: pauseDefaults
        )
        let sourceTitles = ClipSourceExtractor.fragments(clip: clip, scenes: scenes)
            .map(\.sceneTitle)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return ClipExportDocument(
            clipID: clip.id,
            title: clip.title,
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            onScreenText: clip.onScreenText,
            description: clip.description,
            hashtags: clip.hashtags,
            format: clip.format,
            targetSeconds: ClipLimits.sanitizedTarget(clip.targetSeconds) ?? ClipLimits.defaultTargetSeconds,
            estimate: estimate,
            sourceSceneTitles: sourceTitles,
            labels: labels
        )
    }

    /// Markers start at frame zero, not at Resolve's usual 01:00:00:00.
    public static func markers(
        for clip: FrameScriptDocument.ShortClip,
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard,
        rate: FrameRate = .fps25,
        labels: ClipExportLabels = .spanish
    ) -> [ResolvedMarker] {
        let estimate = ClipEstimator.estimate(
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            targetSeconds: clip.targetSeconds,
            wordsPerMinute: wordsPerMinute,
            pauseDefaults: pauseDefaults
        )
        var markers: [ResolvedMarker] = []
        let hookFrames = max(0, Timecode(seconds: estimate.hookSeconds, rate: rate).frames)
        let hasHook = !clip.hook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasHook {
            markers.append(
                ResolvedMarker(
                    frame: 0,
                    name: labels.hook,
                    note: clip.hook.trimmingCharacters(in: .whitespacesAndNewlines),
                    color: .purple,
                    durationFrames: max(1, hookFrames),
                    kind: .cue,
                    sceneIndex: 0
                )
            )
        }
        let onScreen = clip.onScreenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !onScreen.isEmpty {
            let start = hasHook ? max(1, hookFrames) : 0
            markers.append(
                ResolvedMarker(
                    frame: start,
                    name: labels.onScreenText,
                    note: onScreen,
                    color: .yellow,
                    durationFrames: 1,
                    kind: .cue,
                    sceneIndex: 0
                )
            )
        }
        return markers
    }

    public static func edl(
        for clip: FrameScriptDocument.ShortClip,
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard,
        settings: ExportSettings,
        labels: ClipExportLabels = .spanish
    ) -> String {
        ResolveMarkerEDL.make(
            markers: markers(
                for: clip,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults,
                rate: settings.fps,
                labels: labels
            ),
            settings: clipSettings(for: clip, base: settings)
        )
    }

    public static func fcpxml(
        for clip: FrameScriptDocument.ShortClip,
        wordsPerMinute: Double,
        pauseDefaults: PauseDefaults = .standard,
        settings: ExportSettings,
        labels: ClipExportLabels = .spanish
    ) -> String {
        let estimate = ClipEstimator.estimate(
            hook: clip.hook,
            adaptedText: clip.adaptedText,
            targetSeconds: clip.targetSeconds,
            wordsPerMinute: wordsPerMinute,
            pauseDefaults: pauseDefaults
        )
        let durationSeconds = max(estimate.seconds, estimate.targetSeconds)
        let durationFrames = max(1, Timecode(seconds: durationSeconds, rate: settings.fps).frames)
        return ResolveFCPXML.make(
            markers: markers(
                for: clip,
                wordsPerMinute: wordsPerMinute,
                pauseDefaults: pauseDefaults,
                rate: settings.fps,
                labels: labels
            ),
            durationFrames: durationFrames,
            settings: clipSettings(for: clip, base: settings)
        )
    }

    /// The clip owns its timeline: zero start timecode, no chapter markers and
    /// the clip title as the project name.
    private static func clipSettings(
        for clip: FrameScriptDocument.ShortClip,
        base: ExportSettings
    ) -> ExportSettings {
        ExportSettings(
            projectName: clip.title,
            fps: base.fps,
            dropFrame: base.dropFrame,
            startTimecode: .zero,
            asciiSafeNames: base.asciiSafeNames,
            includeChapterMarkers: false,
            csvIncludesByteOrderMark: base.csvIncludesByteOrderMark,
            csvEscapesFormulas: base.csvEscapesFormulas
        )
    }
}

/// Cheap guard against numbers invented by the adaptation model. It is a
/// warning, not a hard rejection: the editor still lets the creator decide.
public enum ClipFactGuard {
    /// Decimal numbers in `text` that do not appear in `source`, normalised to
    /// a dot decimal separator and de-duplicated in first-seen order.
    public static func unsupportedNumbers(in text: String, source: String) -> [String] {
        let sourceNumbers = Set(numbers(in: source))
        var result: [String] = []
        var seen: Set<String> = []
        for number in numbers(in: text) where !sourceNumbers.contains(number) {
            if seen.insert(number).inserted {
                result.append(number)
            }
        }
        return result
    }

    static func numbers(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)*"#) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange]).replacingOccurrences(of: ",", with: ".")
        }
    }
}
