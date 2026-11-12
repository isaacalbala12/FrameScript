import Foundation

/// Tolerant decoding for the structured JSON returned by hook and re-hook
/// prompts.
///
/// Providers can answer with plain JSON, fenced JSON, JSON wrapped in a
/// one-key object, a root array, or JSON surrounded by prose. The parser tries
/// every reasonable extraction, then validates each entry and computes spoken
/// seconds with `ScriptMarkup.estimateDuration`. Invalid entries are skipped;
/// a response with no usable entry throws.
public enum HookResponseParser {
    // MARK: - Hooks

    public static func parseHooks(
        _ response: String,
        wordsPerMinute: Double,
        maximumSeconds: TimeInterval = HookLimits.maximumHookSeconds,
        defaults: PauseDefaults = .standard
    ) throws -> [HookSuggestion] {
        guard let entries = HookJSONPayload.entries(
            from: response,
            keys: ["hooks", "alternatives", "variants", "options", "suggestions", "results", "items"]
        ) else {
            throw HookParsingError.invalidJSON
        }

        let rate = validWordsPerMinute(wordsPerMinute)
        var seen = Set<String>()
        var suggestions: [HookSuggestion] = []

        for entry in entries {
            guard suggestions.count < HookLimits.maximumHookAlternatives else { break }
            guard let object = HookJSONPayload.object(from: entry) else { continue }
            guard let rawText = HookJSONPayload.firstString(
                in: object,
                keys: ["text", "hook", "spokenText", "spoken_text", "line", "script"]
            ), let text = sanitizedSpokenText(rawText) else {
                continue
            }
            guard seen.insert(normalized(text)).inserted else { continue }

            let angle = sanitizedLabel(
                HookJSONPayload.firstString(in: object, keys: ["angle", "label", "type", "kind"]) ?? "",
                limit: 48
            )
            let onScreenText = sanitizedLabel(
                HookJSONPayload.firstString(
                    in: object,
                    keys: ["onScreenText", "on_screen_text", "screenText", "screen_text", "overlay", "textOnScreen"]
                ) ?? "",
                limit: 80
            )

            suggestions.append(HookSuggestion(
                angle: angle,
                text: text,
                onScreenText: onScreenText,
                wordCount: ScriptMarkup.spokenWordCount(text),
                estimatedSeconds: ScriptMarkup.estimateDuration(
                    text,
                    wordsPerMinute: rate,
                    defaults: defaults
                ),
                maximumSeconds: maximumSeconds
            ))
        }

        guard !suggestions.isEmpty else { throw HookParsingError.noSuggestions }
        return suggestions
    }

    // MARK: - Re-hooks

    public static func parseRehooks(
        _ response: String,
        anchors: [RehookPosition],
        wordsPerMinute: Double,
        maximumSeconds: TimeInterval = HookLimits.maximumRehookSeconds,
        defaults: PauseDefaults = .standard
    ) throws -> [RehookSuggestion] {
        guard !anchors.isEmpty else { throw HookParsingError.noValidAnchors }
        guard let entries = HookJSONPayload.entries(
            from: response,
            keys: ["bridges", "rehooks", "reHooks", "suggestions", "hooks", "results", "items"]
        ) else {
            throw HookParsingError.invalidJSON
        }

        let rate = validWordsPerMinute(wordsPerMinute)
        var usedCounts: [Int: Int] = [:]
        var seen = Set<String>()
        var suggestions: [RehookSuggestion] = []

        for entry in entries {
            guard let object = HookJSONPayload.object(from: entry) else { continue }
            guard let rawText = HookJSONPayload.firstString(
                in: object,
                keys: ["text", "bridge", "rehook", "reHook", "line", "script"]
            ), let text = sanitizedSpokenText(rawText) else {
                continue
            }

            let rawAnchor = HookJSONPayload.firstString(
                in: object,
                keys: ["anchor", "anchorSentence", "anchor_sentence", "insertBefore", "insert_before", "sentence"]
            ) ?? ""
            guard let position = matchedAnchor(
                rawAnchor,
                anchors: anchors,
                usedCounts: usedCounts
            ) else {
                continue
            }
            let count = usedCounts[position.sentenceIndex, default: 0]
            guard count < HookLimits.maximumRehooksPerPosition else { continue }
            guard seen.insert("\(position.anchorRange.location):\(normalized(text))").inserted else { continue }

            usedCounts[position.sentenceIndex] = count + 1
            suggestions.append(RehookSuggestion(
                text: text,
                anchor: position.anchor,
                anchorRange: position.anchorRange,
                wordCount: ScriptMarkup.spokenWordCount(text),
                estimatedSeconds: ScriptMarkup.estimateDuration(
                    text,
                    wordsPerMinute: rate,
                    defaults: defaults
                ),
                maximumSeconds: maximumSeconds
            ))
        }

        guard !suggestions.isEmpty else { throw HookParsingError.noSuggestions }
        return suggestions
    }

    // MARK: - Anchor matching

    private static func matchedAnchor(
        _ raw: String,
        anchors: [RehookPosition],
        usedCounts: [Int: Int]
    ) -> RehookPosition? {
        let normalizedRaw = normalizedAnchor(raw)
        let available = anchors.filter {
            usedCounts[$0.sentenceIndex, default: 0] < HookLimits.maximumRehooksPerPosition
        }

        if normalizedRaw.isEmpty {
            // Without an anchor, only an unambiguous position is safe.
            return available.count == 1 ? available[0] : nil
        }

        if let exact = available.first(where: { normalizedAnchor($0.anchor) == normalizedRaw }) {
            return exact
        }

        // Some models trim or expand the sentence. Accept a containment match
        // when it points at exactly one available position.
        let contained = available.filter {
            let candidate = normalizedAnchor($0.anchor)
            return candidate.contains(normalizedRaw) || normalizedRaw.contains(candidate)
        }
        return contained.count == 1 ? contained[0] : nil
    }

    // MARK: - Sanitizing

    private static func validWordsPerMinute(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 150
    }

    private static func sanitizedSpokenText(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Strip one matching pair of wrapping quotes, if present.
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")]
        for (opening, closing) in quotePairs where value.count > 2 {
            if value.first == opening, value.last == closing {
                value = String(value.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Drop a leading list bullet the model may have added.
        for bullet in ["- ", "* ", "• "] where value.hasPrefix(bullet) {
            value = String(value.dropFirst(bullet.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        // Drop a leading "Hook:" / "Gancho:" style label.
        let labels = ["hook:", "gancho:", "text:", "texto:", "spoken hook:", "opening:", "bridge:", "puente:"]
        let lowercased = value.lowercased()
        for label in labels where lowercased.hasPrefix(label) {
            value = String(value.dropFirst(label.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !value.isEmpty, value.count <= 1_200 else { return nil }
        guard !value.contains("```"), !value.contains("**"), !value.contains("##") else { return nil }
        guard !value.lowercased().contains("[re-hook]") else { return nil }
        guard ScriptMarkup.spokenWordCount(value) > 0 else { return nil }
        return value
    }

    private static func sanitizedLabel(_ raw: String, limit: Int) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")]
        for (opening, closing) in quotePairs where value.count > 2 {
            if value.first == opening, value.last == closing {
                value = String(value.dropFirst().dropLast())
                break
            }
        }
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard !value.contains("```"), !value.contains("**"), !value.contains("##") else { return "" }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedAnchor(_ text: String) -> String {
        normalized(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tolerant JSON extraction

enum HookJSONPayload {
    static func entries(from response: String, keys: [String]) -> [Any]? {
        for candidate in candidates(from: response) {
            guard let data = candidate.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data),
                  let entries = unwrap(value, keys: keys) else {
                continue
            }
            return entries
        }
        return nil
    }

    static func object(from entry: Any) -> [String: Any]? {
        if let object = entry as? [String: Any] { return object }
        if let text = entry as? String { return ["text": text] }
        return nil
    }

    static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func candidates(from response: String) -> [String] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        var values: [String] = []
        append(trimmed, to: &values)

        if let fenced = fenceContent(from: trimmed) {
            append(fenced, to: &values)
        }

        let sources = values
        for source in sources {
            for (opening, closing) in [("{", "}"), ("[", "]")] {
                if let start = source.firstIndex(of: Character(opening)),
                   let end = source.lastIndex(of: Character(closing)),
                   start < end {
                    append(String(source[start...end]), to: &values)
                }
            }
        }

        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func append(_ value: String, to values: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        values.append(trimmed)
    }

    private static func fenceContent(from text: String) -> String? {
        guard let opening = text.range(of: "```") else { return nil }
        var body = text[opening.upperBound...]
        if let lineEnd = body.firstIndex(of: "\n") {
            body = body[body.index(after: lineEnd)...]
        } else if let firstSpace = body.firstIndex(of: " ") {
            // A single-line fence such as ```json {...}```.
            body = body[body.index(after: firstSpace)...]
        }
        guard let closing = body.range(of: "```", options: .backwards) else { return nil }
        return String(body[..<closing.lowerBound])
    }

    private static func unwrap(_ value: Any, keys: [String]) -> [Any]? {
        if let array = value as? [Any] {
            return array
        }
        guard let object = value as? [String: Any] else { return nil }

        for key in keys {
            if let array = object[key] as? [Any] { return array }
            if let single = object[key] as? [String: Any] { return [single] }
        }

        // A bare suggestion object.
        if object["text"] != nil || object["hook"] != nil || object["bridge"] != nil {
            return [object]
        }

        // One-key wrapper.
        if object.count == 1, let nested = object.values.first {
            return unwrap(nested, keys: keys)
        }
        return nil
    }
}
