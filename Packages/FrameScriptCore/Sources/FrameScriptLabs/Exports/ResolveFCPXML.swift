import Foundation

/// Writes an FCPXML 1.10 placeholder timeline with markers.
///
/// Version choice: Apple publishes the 1.10 DTD online, Resolve has imported
/// FCPXML 1.10 since version 18, and 1.11/1.12 add nothing this pack needs.
/// The DTD requires markers to live on a story element, so they go inside the
/// `<gap>`; a `<marker>` directly under `<sequence>` would not validate.
///
/// Offset rule (Apple's FCPXML DTD): "in a sequence with a 'tcStart' of
/// '3600s', a child element that starts 30 seconds from the start has an
/// 'offset' of '3630s'". The gap therefore starts at `tcStart`, and markers
/// are placed at `gap.offset + marker.start - gap.start`.
///
/// Best-effort caveat: some Resolve versions import the timeline but drop or
/// blue-wash FCPXML markers. The EDL is the authoritative marker path.
///
/// The format resource is 1920×1080 stereo 48 kHz, matching the documented
/// ZV-E10/1080p delivery workflow. A vertical or 4K project needs a different
/// Apple format name, which this pack does not guess.
public enum ResolveFCPXML {
    public static func make(scenes: [ExportScene], settings: ExportSettings) -> String {
        let projectName = XMLText.attribute(settings.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "FrameScript"
            : settings.projectName)
        let markers = ExportMarkerResolver.markers(scenes: scenes, settings: settings)
        let endFrame = ExportMarkerResolver.timelineEndFrame(scenes: scenes, settings: settings)
        let sequenceDuration = rationalSeconds(frames: endFrame, rate: settings.fps)
        let tcStart = rationalSeconds(frames: settings.startTimecode.frames, rate: settings.fps)
        let tcFormat = settings.effectiveDropFrame ? "DF" : "NDF"

        var lines: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE fcpxml>",
            "<fcpxml version=\"1.10\">",
            "  <resources>",
            "    <format id=\"r1\" name=\"\(videoFormatName(settings.fps))\" frameDuration=\"\(frameDuration(settings.fps))\" width=\"1920\" height=\"1080\"/>",
            "  </resources>",
            "  <library>",
            "    <event name=\"FrameScript\">",
            "      <project name=\"\(projectName)\">",
            "        <sequence format=\"r1\" duration=\"\(sequenceDuration)\" tcStart=\"\(tcStart)\" tcFormat=\"\(tcFormat)\" audioLayout=\"stereo\" audioRate=\"48k\">",
            "          <spine>",
            "            <gap name=\"Timeline\" offset=\"\(tcStart)\" duration=\"\(sequenceDuration)\" start=\"0s\">",
        ]

        for marker in markers {
            let start = rationalSeconds(frames: marker.frame, rate: settings.fps)
            let duration = rationalSeconds(frames: max(1, marker.durationFrames), rate: settings.fps)
            let value = XMLText.attribute(marker.name)
            var line = "              <marker start=\"\(start)\" duration=\"\(duration)\" value=\"\(value)\""
            let note = marker.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                line += " note=\"\(XMLText.attribute(note))\""
            }
            line += "/>"
            lines.append(line)
        }

        if settings.includeChapterMarkers {
            let chapters = YouTubeChapters.make(scenes: scenes, rate: settings.fps)
            for chapter in chapters.chapters {
                let start = rationalSeconds(frames: chapter.startFrame, rate: settings.fps)
                let duration = rationalSeconds(frames: 1, rate: settings.fps)
                lines.append(
                    "              <chapter-marker start=\"\(start)\" duration=\"\(duration)\" value=\"\(XMLText.attribute(chapter.title))\"/>"
                )
            }
        }

        lines.append(contentsOf: [
            "            </gap>",
            "          </spine>",
            "        </sequence>",
            "      </project>",
            "    </event>",
            "  </library>",
            "</fcpxml>",
            "",
        ])

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    public static func videoFormatName(_ rate: FrameRate) -> String {
        switch rate {
        case .fps23_976: "FFVideoFormat1080p2398"
        case .fps24: "FFVideoFormat1080p24"
        case .fps25: "FFVideoFormat1080p25"
        case .fps29_97: "FFVideoFormat1080p2997"
        case .fps30: "FFVideoFormat1080p30"
        case .fps50: "FFVideoFormat1080p50"
        case .fps59_94: "FFVideoFormat1080p5994"
        case .fps60: "FFVideoFormat1080p60"
        default: "FFVideoFormat1080p\(rate.nominalFPS)"
        }
    }

    /// One frame expressed as an FCPXML rational time, e.g. "1/25s".
    public static func frameDuration(_ rate: FrameRate) -> String {
        rationalSeconds(frames: 1, rate: rate)
    }

    /// Frames expressed as reduced rational seconds, e.g. "1001/100s".
    public static func rationalSeconds(frames: Int, rate: FrameRate) -> String {
        let numerator = frames * rate.denominator
        let denominator = rate.numerator
        let divisor = greatestCommonDivisor(abs(numerator), denominator)
        let reducedNumerator = numerator / divisor
        let reducedDenominator = denominator / divisor
        if reducedDenominator == 1 {
            return "\(reducedNumerator)s"
        }
        return "\(reducedNumerator)/\(reducedDenominator)s"
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x == 0 ? 1 : x
    }
}
