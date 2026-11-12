import Foundation

/// Text hygiene for the delivery pack.
///
/// EDL is a 1970s format; marker names must not contain pipes, line breaks or
/// control characters, and Resolve has historically mangled non-ASCII names.
/// The full text always survives in the FCPXML notes and the Markdown.
public enum ExportTextSanitizer {
    /// Collapses tabs, newlines and repeated spaces into single spaces.
    public static func collapseWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    /// Removes the light Markdown used in scene titles: `**bold**`, `*italic*`,
    /// `_italic_`, inline code and leading heading marks.
    public static func stripMarkdown(_ value: String) -> String {
        var text = value
        for token in ["**", "__", "`", "*", "_"] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        while text.hasPrefix("#") {
            text.removeFirst()
        }
        if text.hasPrefix(">") {
            text.removeFirst()
        }
        return text
    }

    /// Removes emoji and their invisible joiners / variation selectors.
    public static func stripEmoji(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar.properties.isEmojiPresentation { continue }
            switch scalar.value {
            case 0x200D, 0xFE0F, 0xFE0E: continue
            case 0x1F1E6...0x1F1FF: continue // regional indicators
            case 0x1F3FB...0x1F3FF: continue // skin tone modifiers
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// Transliterates to plain ASCII: á→a, ñ→n, ¿→?, ¡→!, —→-, emoji removed.
    public static func asciiSafe(_ value: String) -> String {
        let withoutEmoji = stripEmoji(stripMarkdown(value))
        let latin = withoutEmoji.applyingTransform(.toLatin, reverse: false) ?? withoutEmoji
        let folded = latin.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )

        var replaced = folded
        let manual: [Character: String] = [
            "¿": "?", "¡": "!", "—": "-", "–": "-", "…": "...",
            "“": "\"", "”": "\"", "„": "\"", "‘": "'", "’": "'", "‚": "'",
            "«": "\"", "»": "\"", "€": "EUR", "£": "GBP", "·": "-",
        ]
        replaced = String(replaced.map { manual[$0] ?? String($0) }.joined())

        var output = String.UnicodeScalarView()
        for scalar in replaced.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                output.append(" ")
            case 0x20...0x7E:
                output.append(scalar)
            default:
                continue
            }
        }
        return collapseWhitespace(String(output))
    }

    /// A safe EDL marker name: one line, no pipes, trimmed, at most 60 chars.
    public static func markerName(
        _ value: String,
        asciiSafe useASCII: Bool,
        limit: Int = 60
    ) -> String {
        let base = useASCII ? asciiSafe(value) : collapseWhitespace(stripEmoji(stripMarkdown(value)))
        let withoutPipes = base.replacingOccurrences(of: "|", with: "/")
        let trimmed = withoutPipes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Marker" }
        return truncated(trimmed, limit: limit).text
    }

    /// A safe EDL title line.
    public static func title(_ value: String, asciiSafe useASCII: Bool) -> String {
        let base = useASCII ? asciiSafe(value) : collapseWhitespace(stripEmoji(value))
        let withoutControl = base.replacingOccurrences(of: "|", with: "/")
        let trimmed = withoutControl.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "FrameScript" : truncated(trimmed, limit: 80).text
    }

    /// YouTube chapter title: no Markdown, no emoji, at most 60 characters.
    public static func chapterTitle(_ value: String, limit: Int = 60) -> (text: String, wasTruncated: Bool) {
        let cleaned = collapseWhitespace(stripEmoji(stripMarkdown(value)))
        return truncated(cleaned, limit: limit)
    }

    /// Truncates on grapheme boundaries without adding an ellipsis.
    public static func truncated(_ value: String, limit: Int) -> (text: String, wasTruncated: Bool) {
        guard value.count > limit else { return (value, false) }
        let cut = value.prefix(limit).trimmingCharacters(in: .whitespaces)
        return (cut, true)
    }
}

/// XML 1.0 escaping shared by the FCPXML writer.
public enum XMLText {
    public static func escape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default:
                // XML 1.0 forbids most C0 controls; drop them.
                if scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D || scalar.value >= 0x20 {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    /// Attribute values cannot contain raw newlines; normalise them first.
    public static func attribute(_ value: String) -> String {
        let singleLine = ExportTextSanitizer.collapseWhitespace(value)
        return escape(singleLine)
    }
}
