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

    /// Removes the light Markdown used in scene titles, but only balanced
    /// emphasis. Underscores in `snake_case` and multiplication signs in
    /// `2*3` survive.
    public static func stripMarkdown(_ value: String) -> String {
        var text = value
        text = stripPaired(text, marker: "*", double: true, requiresBoundaries: true)
        text = stripPaired(text, marker: "_", double: true, requiresBoundaries: true)
        text = stripPaired(text, marker: "*", double: false, requiresBoundaries: true)
        text = stripPaired(text, marker: "_", double: false, requiresBoundaries: true)
        text = stripPaired(text, marker: "`", double: false, requiresBoundaries: false)
        return stripLeadingBlockMarkers(text)
    }

    private static func stripPaired(
        _ value: String,
        marker: Character,
        double: Bool,
        requiresBoundaries: Bool
    ) -> String {
        var characters = Array(value)
        var index = 0
        while index < characters.count {
            guard characters[index] == marker else {
                index += 1
                continue
            }
            let markerLength = double ? 2 : 1
            if double {
                guard index + 1 < characters.count, characters[index + 1] == marker else {
                    index += 1
                    continue
                }
            }

            let previousOK = !requiresBoundaries
                || index == 0
                || characters[index - 1].isWhitespace
                || characters[index - 1].isPunctuation
            let contentStart = index + markerLength
            guard previousOK, contentStart < characters.count, !characters[contentStart].isWhitespace else {
                index += 1
                continue
            }

            var closing = contentStart + 1
            var found = false
            while closing + markerLength <= characters.count {
                if characters[closing] == marker,
                   !double || (closing + 1 < characters.count && characters[closing + 1] == marker) {
                    let after = closing + markerLength
                    let afterOK = !requiresBoundaries
                        || after >= characters.count
                        || characters[after].isWhitespace
                        || characters[after].isPunctuation
                    if afterOK {
                        found = true
                        break
                    }
                }
                closing += 1
            }

            if found {
                characters.removeSubrange(closing..<(closing + markerLength))
                characters.removeSubrange(index..<contentStart)
                continue
            }
            index += 1
        }
        return String(characters)
    }

    private static func stripLeadingBlockMarkers(_ value: String) -> String {
        var text = value
        if text.hasPrefix("#") {
            let hashes = text.prefix { $0 == "#" }
            let rest = text.dropFirst(hashes.count)
            if rest.first?.isWhitespace == true {
                text = String(rest.drop(while: { $0.isWhitespace }))
            }
        } else if text.hasPrefix(">"), text.dropFirst().first?.isWhitespace == true {
            text = String(text.dropFirst().drop(while: { $0.isWhitespace }))
        }
        return text
    }

    /// Removes C0/C1 control characters and Unicode line separators that can
    /// corrupt an EDL line, while keeping tab/CR/LF for whitespace collapsing.
    public static func stripControlCharacters(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                continue
            default:
                output.append(scalar)
            }
        }
        return String(output)
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
        var base = useASCII ? asciiSafe(value) : stripEmoji(stripMarkdown(value))
        base = stripControlCharacters(collapseWhitespace(base))
        let withoutPipes = base.replacingOccurrences(of: "|", with: "/")
        let trimmed = withoutPipes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Marker" }
        return truncated(trimmed, limit: limit).text
    }

    /// A safe EDL marker note: one line, no pipes, never empty with a fallback.
    /// The full note still lives in the FCPXML and the Markdown.
    public static func markerNote(
        _ value: String,
        asciiSafe useASCII: Bool,
        limit: Int = 160
    ) -> String {
        var base = useASCII ? asciiSafe(value) : stripEmoji(stripMarkdown(value))
        base = stripControlCharacters(collapseWhitespace(base))
        let withoutPipes = base.replacingOccurrences(of: "|", with: "/")
        let trimmed = withoutPipes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return truncated(trimmed, limit: limit).text
    }

    /// A safe EDL title line.
    public static func title(_ value: String, asciiSafe useASCII: Bool) -> String {
        var base = useASCII ? asciiSafe(value) : stripEmoji(value)
        base = stripControlCharacters(collapseWhitespace(base))
        let withoutPipes = base.replacingOccurrences(of: "|", with: "/")
        let trimmed = withoutPipes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "FrameScript" : truncated(trimmed, limit: 80).text
    }

    /// YouTube chapter title: no Markdown, no emoji, at most 60 characters.
    public static func chapterTitle(_ value: String, limit: Int = 60) -> (text: String, wasTruncated: Bool) {
        let cleaned = stripControlCharacters(collapseWhitespace(stripEmoji(stripMarkdown(value))))
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
                // XML 1.0 forbids most C0 controls and the FFFE/FFFF
                // noncharacters; drop them so xmllint and Resolve accept
                // the document.
                let value = scalar.value
                if (value & 0xFFFF) == 0xFFFE || (value & 0xFFFF) == 0xFFFF {
                    continue
                }
                if value == 0x09 || value == 0x0A || value == 0x0D || value >= 0x20 {
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
