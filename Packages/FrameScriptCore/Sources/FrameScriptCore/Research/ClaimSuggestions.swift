import Foundation

/// One claim proposed by the AI. The parser deliberately cannot produce
/// `.confirmed`: confirmation is always a human action.
public struct ClaimSuggestion: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let status: FrameScriptDocument.ClaimStatus
    public let reason: String

    public init(
        id: UUID = UUID(),
        text: String,
        status: FrameScriptDocument.ClaimStatus = .probable,
        reason: String = ""
    ) {
        self.id = id
        self.text = text
        self.status = status == .confirmed ? .probable : status
        self.reason = reason
    }
}

public enum ClaimSuggestionParser {
    public static let maximumTextLength = 280

    /// Parses the model answer into claims. It accepts a bare array, an object
    /// with a `claims` array, or a fenced JSON block. Anything else yields an
    /// empty list; a parsing failure must never crash the panel.
    public static func parse(_ response: String, limit: Int = 8) -> [ClaimSuggestion] {
        guard let json = extractedJSON(from: response),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        let rawClaims: [[String: Any]]
        if let array = root as? [[String: Any]] {
            rawClaims = array
        } else if let object = root as? [String: Any],
                  let array = object["claims"] as? [[String: Any]] {
            rawClaims = array
        } else {
            return []
        }

        let boundedLimit = max(1, min(limit, 20))
        var seen: Set<String> = []
        var suggestions: [ClaimSuggestion] = []
        for raw in rawClaims {
            guard suggestions.count < boundedLimit else { break }
            guard let textValue = raw["text"] as? String else { continue }
            let text = sanitize(textValue)
            guard text.count >= 6 else { continue }
            let key = text
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
                .lowercased()
            guard seen.insert(key).inserted else { continue }

            suggestions.append(
                ClaimSuggestion(
                    text: text,
                    status: parseStatus(raw["status"] as? String),
                    reason: sanitize(raw["reason"] as? String ?? "")
                )
            )
        }
        return suggestions
    }

    /// Spanish and English labels are accepted because providers do not always
    /// obey the requested raw values. `confirmed` is intentionally downgraded.
    public static func parseStatus(_ raw: String?) -> FrameScriptDocument.ClaimStatus {
        let value = (raw ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "confirmed", "confirmada", "confirmado", "verified", "verificado":
            return .probable
        case "rumor", "rumour", "especulativa", "especulativo", "speculative", "unverified":
            return .rumor
        case "communityopinion", "community opinion", "opinion comunitaria", "opinion",
             "opinión comunitaria", "comunidad", "community", "debate":
            return .communityOpinion
        default:
            return .probable
        }
    }

    private static func extractedJSON(from response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFences = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let objectStart = withoutFences.firstIndex(of: "{")
        let arrayStart = withoutFences.firstIndex(of: "[")
        let startsWithArray: Bool
        switch (objectStart, arrayStart) {
        case let (object?, array?): startsWithArray = array < object
        case (nil, .some): startsWithArray = true
        default: startsWithArray = false
        }

        if startsWithArray,
           let start = arrayStart,
           let end = withoutFences.lastIndex(of: "]"),
           start <= end {
            return String(withoutFences[start...end])
        }
        if let start = objectStart,
           let end = withoutFences.lastIndex(of: "}"),
           start <= end {
            return String(withoutFences[start...end])
        }
        return nil
    }

    private static func sanitize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("- ") || text.hasPrefix("* ") {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        if text.count > maximumTextLength {
            let prefix = text.prefix(maximumTextLength - 1)
            text = prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }
}
