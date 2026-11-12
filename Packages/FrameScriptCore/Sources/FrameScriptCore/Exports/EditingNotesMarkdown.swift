import Foundation

/// Markdown editing notes grouped by scene, with absolute timecodes.
public enum EditingNotesMarkdown {
    public static func make(scenes: [ExportScene], settings: ExportSettings) -> String {
        let project = ExportTextSanitizer.collapseWhitespace(settings.projectName)
        let displayProject = project.isEmpty ? "FrameScript" : project
        let sorted = scenes.enumerated().sorted { lhs, rhs in
            if lhs.element.start == rhs.element.start { return lhs.offset < rhs.offset }
            return lhs.element.start < rhs.element.start
        }

        var lines: [String] = [
            "# Notas de montaje — \(displayProject)",
            "",
            "Timecode de inicio: \(settings.startTimecode.string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)) · \(settings.fps) fps · \(settings.timecodeFormatLabel)",
            "",
        ]

        guard !sorted.isEmpty else {
            lines.append("Sin escenas.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        // Notes are a human-readable safety net: keep every raw cue, even ones
        // that the EDL/FCPXML deduplicates into a scene marker's note.
        let allMarkers = ExportMarkerResolver.allMarkers(scenes: scenes, settings: settings)
        var markersByScene: [Int: [ResolvedMarker]] = [:]
        for marker in allMarkers where marker.kind != .scene {
            markersByScene[marker.sceneIndex, default: []].append(marker)
        }

        for (position, entry) in sorted.enumerated() {
            let index = entry.offset
            let scene = entry.element
            let number = String(format: "%02d", position)
            let cleanedTitle = ExportTextSanitizer.collapseWhitespace(scene.title)
            let title = cleanedTitle.isEmpty ? "Escena" : cleanedTitle
            let start = DurationFormat.clock(seconds: max(0, scene.start), rate: settings.fps)
            let startFrame = Timecode(seconds: max(0, scene.start), rate: settings.fps).frames
            let absoluteStart = Timecode(frames: settings.startTimecode.frames + startFrame)
                .string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
            let duration = DurationFormat.clock(seconds: max(0, scene.duration), rate: settings.fps)

            lines.append("## \(number) — \(title) (\(start))")
            var meta = "TC: \(absoluteStart) · Duración: \(duration)"
            if let target = scene.targetDuration {
                meta += " · Objetivo: \(DurationFormat.clock(seconds: max(0, target), rate: settings.fps))"
            }
            lines.append(meta)
            lines.append("")

            if let excerpt = scene.scriptExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !excerpt.isEmpty {
                lines.append("**GUION**")
                for line in normalizedLines(excerpt) {
                    lines.append("> \(line)")
                }
                lines.append("")
            }

            if !scene.shots.isEmpty {
                lines.append("**PLAN DE IMAGEN**")
                for shot in scene.shots {
                    var item = "- [\(shot.status.displayName)] \(shot.source.displayName) · \(shot.summary)"
                    let note = ExportTextSanitizer.collapseWhitespace(shot.notes)
                    if !note.isEmpty {
                        item += " — \(note)"
                    }
                    lines.append(item)
                }
                lines.append("")
            }

            if !scene.editingNotes.isEmpty {
                lines.append("**MONTAJE**")
                appendBullets(scene.editingNotes, to: &lines)
                lines.append("")
            }

            if !scene.warnings.isEmpty {
                lines.append("**AVISOS**")
                appendBullets(scene.warnings, to: &lines)
                lines.append("")
            }

            if scene.isRehook {
                lines.append("**RE-HOOK**")
                lines.append("Punto de re-enganche: cerrar con pregunta o giro.")
                lines.append("")
            }

            if let markers = markersByScene[index], !markers.isEmpty {
                lines.append("**MARCADORES**")
                for marker in markers {
                    let frame = Timecode(frames: settings.startTimecode.frames + marker.frame)
                    let timecode = frame.string(rate: settings.fps, dropFrame: settings.effectiveDropFrame)
                    var item = "- \(timecode) · \(marker.name) (\(marker.color.spanishName))"
                    let note = ExportTextSanitizer.collapseWhitespace(marker.note)
                    if !note.isEmpty {
                        item += " — \(note)"
                    }
                    lines.append(item)
                }
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Splits on CRLF, LF and CR so a Windows-imported script does not leave
    /// stray carriage returns in the blockquote.
    private static func normalizedLines(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Emits one bullet per non-empty line. A multi-line note keeps its
    /// content instead of breaking the list or being flattened silently.
    private static func appendBullets(_ values: [String], to lines: inout [String]) {
        for value in values {
            for line in normalizedLines(value) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                lines.append("- \(trimmed)")
            }
        }
    }
}
