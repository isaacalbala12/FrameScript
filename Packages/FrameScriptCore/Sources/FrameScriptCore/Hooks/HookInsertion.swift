import Foundation

/// Pure text transforms used when a suggestion is inserted into a scene.
///
/// The app owns model updates and undo; these functions only return the new
/// script so every rule can be tested without SwiftUI or an editor.
public enum HookInsertion {
    /// Replaces the first spoken paragraph of a scene with `hook`.
    ///
    /// Leading cue-only lines inside that paragraph (for example
    /// `[IMAGEN: …]`) are preserved. Everything that follows the paragraph,
    /// including later cues, B-roll markers and paragraphs, is left untouched.
    /// When the scene has no spoken paragraph, the hook is appended as a new
    /// paragraph.
    public static func replacingHook(in text: String, with hook: String) -> String {
        let value = normalizedLine(hook)
        guard !value.isEmpty else { return text }

        if let range = spokenParagraphReplacementRange(in: text) {
            var result = text
            result.replaceSubrange(range, with: value)
            return result
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }
        return trimmed + "\n\n" + value
    }

    /// Inserts `[RE-HOOK]` and the bridge immediately before `anchor`.
    ///
    /// The cue line is a script marker, not spoken text. The result is
    /// paragraph-separated on both sides so the bridge reads naturally in the
    /// editor. Returns `nil` for an invalid range or empty bridge.
    public static func insertingRehook(
        in text: String,
        before anchor: UTF16Span,
        rehook: String
    ) -> String? {
        let value = normalizedLine(rehook)
        guard !value.isEmpty else { return nil }

        let nsText = text as NSString
        guard anchor.location >= 0, anchor.length > 0, anchor.end <= nsText.length else { return nil }

        let before = nsText.substring(to: anchor.location)
        let after = nsText.substring(from: anchor.location)
        let head = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = "[RE-HOOK]\n" + value

        if head.isEmpty {
            return block + "\n\n" + after
        }
        return head + "\n\n" + block + "\n\n" + after
    }

    /// Returns whether `range` still points at `anchor` in `text`, ignoring
    /// case and whitespace differences. Used before inserting a bridge so an
    /// unchanged scene keeps the exact planned position even when the same
    /// sentence appears more than once.
    public static func matchesAnchor(_ anchor: String, at range: UTF16Span, in text: String) -> Bool {
        let nsText = text as NSString
        guard range.location >= 0, range.length > 0, range.end <= nsText.length else { return false }
        let value = nsText.substring(with: NSRange(location: range.location, length: range.length))
        return normalizedAnchor(value) == normalizedAnchor(anchor)
    }

    /// Finds the current UTF-16 range of an anchor sentence in a scene.
    ///
    /// Used before insertion to survive edits made while the sheet was open.
    /// Matching ignores case and whitespace differences.
    public static func anchorRange(for anchor: String, in text: String) -> UTF16Span? {
        let target = normalizedAnchor(anchor)
        guard !target.isEmpty else { return nil }

        let sentences = RhythmSentenceSplitter.sentences(in: text)
        if let exact = sentences.first(where: { normalizedAnchor($0.text) == target }) {
            return exact.range
        }
        let contained = sentences.filter {
            let candidate = normalizedAnchor($0.text)
            return candidate.contains(target) || target.contains(candidate)
        }
        return contained.count == 1 ? contained[0].range : nil
    }

    // MARK: - Helpers

    private static func normalizedLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedAnchor(_ text: String) -> String {
        normalizedLine(text)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”«»"))
            .lowercased()
    }

    /// Returns the range from the first spoken line of the first spoken
    /// paragraph through the end of that paragraph.
    private static func spokenParagraphReplacementRange(in text: String) -> Range<String.Index>? {
        var paragraphStart: String.Index?
        var paragraphEnd: String.Index?
        var index = text.startIndex

        func firstSpokenLineRange(
            start: String.Index,
            end: String.Index
        ) -> Range<String.Index>? {
            var lineStart = start
            while lineStart < end {
                let lineEnd = text[lineStart..<end].firstIndex(of: "\n") ?? end
                let line = text[lineStart..<lineEnd]
                if ScriptMarkup.spokenWordCount(String(line)) > 0 {
                    return lineStart..<end
                }
                lineStart = lineEnd < end ? text.index(after: lineEnd) : end
            }
            return nil
        }

        func flush() -> Range<String.Index>? {
            defer {
                paragraphStart = nil
                paragraphEnd = nil
            }
            guard let start = paragraphStart, let end = paragraphEnd else { return nil }
            return firstSpokenLineRange(start: start, end: end)
        }

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<lineEnd]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let range = flush() { return range }
            } else {
                if paragraphStart == nil { paragraphStart = index }
                paragraphEnd = lineEnd
            }
            index = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        return flush()
    }
}
