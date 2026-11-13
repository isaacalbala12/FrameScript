import Foundation

/// Context sent to the title model. Short on purpose: titles are a marketing
/// decision, not a script rewrite.
public struct PublishingTitleContext: Sendable, Equatable {
    public var projectTitle: String
    public var promise: String
    public var thesis: String
    public var videoType: String
    public var targetDuration: String
    public var sceneTitles: [String]
    public var openingText: String

    public init(
        projectTitle: String = "",
        promise: String = "",
        thesis: String = "",
        videoType: String = "",
        targetDuration: String = "",
        sceneTitles: [String] = [],
        openingText: String = ""
    ) {
        self.projectTitle = projectTitle
        self.promise = promise
        self.thesis = thesis
        self.videoType = videoType
        self.targetDuration = targetDuration
        self.sceneTitles = sceneTitles
        self.openingText = openingText
    }
}

public enum PublishingTitlePrompt {
    public static func systemPrompt(languageName: String) -> String {
        """
        You write YouTube titles for a Spanish-from-Spain simracing and motorsport channel. Voice: direct, concrete, dry, tuteo; never ustedes, "acá", "celular" or "computadora"; no corporate filler. If the video is in another language, write the titles in that language.

        Return exactly one JSON object:
        {"titles":["…","…"]}

        Rules:
        - Produce 6 to 8 different titles.
        - Hard limit: 100 characters. Prefer 55 to 70 characters so YouTube does not cut them.
        - One concrete idea per title. Lead with the promise, the number, the conflict or the decision the viewer faces.
        - Use only numbers, dates, prices and experiences that appear in the supplied material. Never invent them.
        - Never promise something the video does not deliver.
        - No emoji, no Markdown, no quotes around the title, no numbering, no hashtags.
        - No clickbait that the video cannot pay off. No "¡INCREÍBLE!", "no te lo pierdas", "lo que nadie te cuenta" unless the material supports it.
        - Vary the angle: pregunta, contraste, dato, promesa, decisión. Do not repeat the same formula.
        - Write in \(languageName).
        """
    }

    public static func userPrompt(_ context: PublishingTitleContext) -> String {
        var lines: [String] = []
        if !context.projectTitle.isEmpty {
            lines.append("Project title: \(context.projectTitle)")
        }
        if !context.videoType.isEmpty {
            lines.append("Video type: \(context.videoType)")
        }
        if !context.targetDuration.isEmpty {
            lines.append("Target duration: \(context.targetDuration)")
        }
        if !context.promise.isEmpty {
            lines.append("Promise: \(context.promise)")
        }
        if !context.thesis.isEmpty {
            lines.append("Thesis: \(context.thesis)")
        }
        if !context.sceneTitles.isEmpty {
            lines.append("Scenes: " + context.sceneTitles.joined(separator: " · "))
        }
        if !context.openingText.isEmpty {
            lines.append("")
            lines.append("Opening text:")
            lines.append(context.openingText)
        }
        lines.append("")
        lines.append(#"Return the JSON object now: {"titles":["…"]}"#)
        return lines.joined(separator: "\n")
    }
}

public enum PublishingTitleParser {
    public static func parse(_ response: String, maximumCharacters: Int = PublishingLimits.titleMaximum) -> [String] {
        let candidates: [String]
        if let json = jsonCandidates(from: response) {
            candidates = json
        } else {
            candidates = lineCandidates(from: response)
        }

        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let cleaned = clean(candidate, maximumCharacters: maximumCharacters)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(cleaned)
            if result.count == 8 { break }
        }
        return result
    }

    // MARK: - JSON

    private static func jsonCandidates(from response: String) -> [String]? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectRange = firstRange(from: "{", to: "}", in: trimmed)
        let arrayRange = firstRange(from: "[", to: "]", in: trimmed)

        for range in [objectRange, arrayRange].compactMap({ $0 }) {
            let slice = String(trimmed[range])
            guard let data = slice.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let object = value as? [String: Any] {
                if let titles = object["titles"] as? [Any] {
                    return strings(from: titles)
                }
                if let title = object["title"] as? String {
                    return [title]
                }
            }
            if let array = value as? [Any] {
                return strings(from: array)
            }
            if let string = value as? String {
                return [string]
            }
        }
        return nil
    }

    private static func strings(from values: [Any]) -> [String] {
        values.compactMap { value in
            if let string = value as? String { return string }
            if let object = value as? [String: Any] {
                return (object["title"] as? String) ?? (object["text"] as? String)
            }
            return nil
        }
    }

    private static func firstRange(from start: Character, to end: Character, in text: String) -> ClosedRange<String.Index>? {
        guard let startIndex = text.firstIndex(of: start),
              let endIndex = text.lastIndex(of: end),
              startIndex <= endIndex else { return nil }
        return startIndex...endIndex
    }

    // MARK: - Plain lines

    private static func lineCandidates(from response: String) -> [String] {
        response.components(separatedBy: .newlines).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("```") { return nil }
            if line.count > 200 { return nil }
            // Drop a leading bullet or a 1. / 1) prefix.
            for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                break
            }
            if let range = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) {
                line = String(line[range.upperBound...])
            }
            return line
        }
    }

    // MARK: - Cleanup

    private static func clean(_ value: String, maximumCharacters: Int) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»"))
        text = ExportTextSanitizer.collapseWhitespace(
            ExportTextSanitizer.stripEmoji(ExportTextSanitizer.stripMarkdown(text))
        )
        text = text.replacingOccurrences(of: #"^Título:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        let truncated = ExportTextSanitizer.truncated(text, limit: maximumCharacters).text
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
