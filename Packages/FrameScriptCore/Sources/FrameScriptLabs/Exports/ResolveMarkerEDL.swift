import Foundation

/// Writes the CMX3600-style marker EDL that DaVinci Resolve imports with
/// `Timelines ▸ Import ▸ Timeline Markers from EDL`.
///
/// Verified against the Resolve 21 manual (p. 4250: one event per marker,
/// reel `001`, source and record timecodes, and a note before the directives),
/// the Resolve 21 binary's marker-comment regex
/// `^(?<note>[^\|]*)?(?<color>\|C:[^\|]*)?(?<name>\|M:[^\|]*)?(?<duration>\|D:\d+)?`,
/// and Resolve's own exported files:
///
///     001  001      V     C        01:00:00:00 01:00:00:01 01:00:00:00 01:00:00:01
///      Nota del marcador |C:ResolveColorBlue |M:00 Gancho |D:1
///
/// Lines use CRLF, the convention of Resolve's own exports.
///
/// Range markers keep a one-frame event and carry the real duration in `|D:`.
/// That is how Resolve writes and reads timeline-marker EDLs (manual p. 4250);
/// consumers that derive duration from record-out instead of `|D:` will see
/// one frame. Comment lines can exceed the historical 80-column convention:
/// the target is Resolve's importer, whose regex has no length cap, and the
/// spec caps marker names at 60 characters.
public enum ResolveMarkerEDL {
    public static func make(scenes: [ExportScene], settings: ExportSettings) -> String {
        let title = ExportTextSanitizer.title(settings.projectName, asciiSafe: settings.asciiSafeNames)
        let fcm = settings.effectiveDropFrame ? "DROP FRAME" : "NON-DROP FRAME"
        let markers = ExportMarkerResolver.markers(scenes: scenes, settings: settings)

        var lines: [String] = [
            "TITLE: \(title)",
            "FCM: \(fcm)",
            "",
        ]

        for (index, marker) in markers.enumerated() {
            let recordIn = Timecode(frames: settings.startTimecode.frames + marker.frame)
            let recordOut = recordIn.advanced(by: 1)
            let tcIn = recordIn.string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
            let tcOut = recordOut.string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
            let name = ExportTextSanitizer.markerName(marker.name, asciiSafe: settings.asciiSafeNames)
            let note = ExportTextSanitizer.markerNote(marker.note, asciiSafe: settings.asciiSafeNames)
            let duration = max(1, marker.durationFrames)

            lines.append(
                String(
                    format: "%03d  001      V     C        %@ %@ %@ %@",
                    index + 1, tcIn, tcOut, tcIn, tcOut
                )
            )
            var comment = " "
            if !note.isEmpty {
                comment += note + " "
            }
            comment += "|C:\(marker.color.rawValue) |M:\(name) |D:\(duration)"
            lines.append(comment)
            lines.append("")
        }

        return lines.joined(separator: "\r\n")
    }

    /// Just the flattened marker list, for UI previews and tests.
    public static func markers(scenes: [ExportScene], settings: ExportSettings) -> [ResolvedMarker] {
        ExportMarkerResolver.markers(scenes: scenes, settings: settings)
    }

    /// Collisions and limits worth surfacing in the delivery UI.
    public static func warnings(scenes: [ExportScene], settings: ExportSettings) -> [MarkerWarning] {
        ExportMarkerResolver.resolve(scenes: scenes, settings: settings).warnings
    }
}
