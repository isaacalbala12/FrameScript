import Foundation

/// Writes the CMX3600-style marker EDL that DaVinci Resolve imports with
/// `Timelines ▸ Import ▸ Timeline Markers from EDL`.
///
/// Verified against the Resolve 18.6 manual ("one event for each Timeline
/// marker, with a placeholder reel number (001 by default), and source and
/// record timecodes that correspond to each marker's position"), the
/// Blackmagic forum staff description of the comment syntax, and Resolve's own
/// exported files:
///
///     001  001      V     C        01:00:00:00 01:00:00:01 01:00:00:00 01:00:00:01
///      |C:ResolveColorBlue |M:00 Gancho |D:1
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
            let duration = max(1, marker.durationFrames)

            lines.append(
                String(
                    format: "%03d  001      V     C        %@ %@ %@ %@",
                    index + 1, tcIn, tcOut, tcIn, tcOut
                )
            )
            lines.append(" |C:\(marker.color.rawValue) |M:\(name) |D:\(duration)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Just the flattened marker list, for UI previews and tests.
    public static func markers(scenes: [ExportScene], settings: ExportSettings) -> [ResolvedMarker] {
        ExportMarkerResolver.markers(scenes: scenes, settings: settings)
    }
}
