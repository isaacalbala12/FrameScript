import Foundation

/// RFC 4180 shot list. One row per shot, CRLF line endings, UTF-8.
///
/// The header is kept ASCII so Numbers/Excel/Sheets never mis-detect the
/// encoding, while the values remain full Spanish UTF-8.
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
                rows.append(fields.map(escape).joined(separator: ","))
            }
        }

        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// UTF-8 bytes, optionally prefixed with a BOM (default, per settings).
    public static func makeData(scenes: [ExportScene], settings: ExportSettings) -> Data {
        let text = make(scenes: scenes, settings: settings)
        var data = Data()
        if settings.csvIncludesByteOrderMark {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(contentsOf: text.utf8)
        return data
    }

    /// RFC 4180: quote commas, quotes and line breaks; double inner quotes.
    public static func escape(_ field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
            || field.hasPrefix(" ")
            || field.hasSuffix(" ")
        guard needsQuoting else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
