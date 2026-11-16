import Foundation

/// Builds a `TextAnchor` for a claim from a fragment the creator typed or
/// selected. The panel has no live text view, so the fragment is located in the
/// scene script with the same rules the production editors use.
public enum ResearchAnchoring {
    public static let contextLength = 32

    public static func anchor(
        for fragment: String,
        in text: String
    ) -> FrameScriptDocument.TextAnchor? {
        let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let source = text as NSString
        var range = source.range(of: trimmed)
        if range.location == NSNotFound {
            range = source.range(
                of: trimmed,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }
        guard range.location != NSNotFound, range.length > 0 else { return nil }

        return FrameScriptDocument.TextAnchor(
            startUTF16: range.location,
            lengthUTF16: range.length,
            selectedText: source.substring(with: range),
            prefixContext: prefix(of: source, before: range.location),
            suffixContext: suffix(of: source, after: NSMaxRange(range))
        )
    }

    public static func makeAnchor(
        in text: String,
        range: NSRange
    ) -> FrameScriptDocument.TextAnchor? {
        let source = text as NSString
        guard range.location != NSNotFound,
              range.length > 0,
              range.location <= source.length,
              range.length <= source.length - range.location else {
            return nil
        }
        return FrameScriptDocument.TextAnchor(
            startUTF16: range.location,
            lengthUTF16: range.length,
            selectedText: source.substring(with: range),
            prefixContext: prefix(of: source, before: range.location),
            suffixContext: suffix(of: source, after: NSMaxRange(range))
        )
    }

    private static func prefix(of text: NSString, before location: Int) -> String {
        let start = max(0, location - contextLength)
        return text.substring(with: NSRange(location: start, length: location - start))
    }

    private static func suffix(of text: NSString, after location: Int) -> String {
        let length = min(contextLength, text.length - location)
        return text.substring(with: NSRange(location: location, length: length))
    }
}
