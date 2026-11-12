import Foundation

/// RFC 4180 shot list. One row per shot, CRLF line endings, UTF-8.
///
/// The header is kept ASCII so Numbers/Excel/Sheets never mis-detect the
/// encoding, while the values remain full Spanish UTF-8. The BOM is opt-in
/// (`csvIncludesByteOrderMark`), because a BOM is outside RFC 4180's field
/// grammar; turn it on when Excel needs help detecting UTF-8.
public enum ShotListCSV {
    public static let header = "Escena,Titulo,TC entrada,Plano,Fuente,Estado,Notas"

    public static func make(scenes: [ExportScene], settings: ExportSettings) -> String {
        var rows: [String] = [header]

        let sorted = scenes.enumerated().sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start { return lhs.offset < rhs.offset }
            return lhs.element.start < rhs.element.start
        }

        for (position, entry) in sorted.enumerated() {
            let scene = entry.element
            for shot in scene.shots {
                let offset = shot.offset ?? 0
                let frame = max(
                    0,
                    Timecode(seconds: max(0, scene.start) + offset, rate: settings.fps).frames
                )
                let timecode = Timecode(frames: settings.startTimecode.frames + frame)
                    .string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)

                let fields = [
                    String(format: "%02d", position),
                    scene.title,
                    timecode,
                    shot.summary,
                    shot.source.displayName,
                    shot.status.displayName,
                    shot.notes,
                ]
                rows.append(
                    fields
                        .map { escape($0, escapeFormulas: settings.csvEscapesFormulas) }
                        .joined(separator: ",")
                )
            }
        }

        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 bytes, optionally prefixed with a BOM.
    public static func makeData(scenes: [ExportScene], settings: ExportSettings) -> Data {
        let text = make(scenes: scenes, settings: settings)
        var data = Data()
        if settings.csvIncludesByteOrderMark {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    /// RFC 4180: quote commas, quotes, tabs and line breaks; double inner quotes.
    public static func escape(_ field: String, escapeFormulas: Bool = false) -> String {
        var value = sanitized(field)
        if escapeFormulas, let first = value.first, "=+-@".contains(first) {
            value = "'" + value
        }
        let needsQuoting = value.contains(",")
            || value.contains("\"")
            || value.contains("\n")
            || value.contains("\r")
            || value.contains("\t")
            || value.hasPrefix(" ")
            || value.hasSuffix(" ")
        guard needsQuoting else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Replaces C0/C1 controls that are not legal CSV text with spaces.
    private static func sanitized(_ field: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in field.unicodeScalars {
            switch scalar.value {
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
                output.append(" ")
            default:
                output.append(scalar)
            }
        }
        return String(output)
    }
}
