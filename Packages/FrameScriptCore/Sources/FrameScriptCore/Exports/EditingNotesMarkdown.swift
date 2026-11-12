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

        let allMarkers = ExportMarkerResolver.markers(scenes: scenes, settings: settings)
        var markersByScene: [Int: [ResolvedMarker]] = [:]
        for marker in allMarkers where marker.kind != .scene {
            markersByScene[marker.sceneIndex, default: []].append(marker)
        }

        for (position, entry) in sorted.enumerated() {
            let index = entry.offset
            let scene = entry.element
            let number = String(format: "%02d", position)
            let title = ExportTextSanitizer.collapseWhitespace(scene.title.isEmpty ? "Escena" : scene.title)
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
                for line in excerpt.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("> \(line)")
                }
                lines.append("")
            }

            if !scene.shots.isEmpty {
                lines.append("**PLAN DE IMAGEN**")
                for shot in scene.shots {
                    var item = "- [\(shot.status.displayName)] \(shot.source.displayName) · \(shot.summary)"
                    let note = shot.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !note.isEmpty {
                        item += " — \(note)"
                    }
                    lines.append(item)
                }
                lines.append("")
            }

            if !scene.editingNotes.isEmpty {
                lines.append("**MONTAJE**")
                for note in scene.editingNotes {
                    lines.append("- \(note)")
                }
                lines.append("")
            }

            if !scene.warnings.isEmpty {
                lines.append("**AVISOS**")
                for warning in scene.warnings {
                    lines.append("- \(warning)")
                }
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
                    let note = marker.note.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
