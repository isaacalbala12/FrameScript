import Foundation

/// File-name sanitisation shared by the AV script, clip text and Resolve
/// marker exports. The save panel shows the result, so it must never be empty
/// (an empty title used to produce a hidden `.edl` dotfile).
enum SafeFileName {
    static func sanitized(_ value: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Appends the extension without letting the caller pass a leading dot.
    static func fileName(_ value: String, fallback: String, extension fileExtension: String) -> String {
        let base = sanitized(value, fallback: fallback)
        let suffix = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return suffix.isEmpty ? base : "\(base).\(suffix)"
    }
}
