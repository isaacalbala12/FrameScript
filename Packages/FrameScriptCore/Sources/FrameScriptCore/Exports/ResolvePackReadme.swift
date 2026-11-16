import Foundation

/// Step-by-step import instructions shipped next to the pack.
///
/// The delivery files are written in Spanish, like the editing notes and the
/// EDL notes the pack already produced, so the README stays consistent with
/// them regardless of the interface language.
public enum ResolvePackReadme {
    public static func make(plan: ResolvePackPlan) -> String {
        let project = displayProject(plan.projectName)
        let startTimecode = plan.settings.startTimecode.string(
            rate: plan.settings.fps,
            dropFrame: plan.settings.effectiveDropFrame
        )
        let duration = DurationFormat.clock(frames: plan.durationFrames, rate: plan.settings.fps)
        let options = plan.options
        let names = plan.names

        var lines: [String] = [
            "# Pack para DaVinci Resolve — \(project)",
            "",
            "Generado por FrameScript para importar en **DaVinci Resolve 21 FREE**.",
            "",
            "- Timeline: **\(plan.settings.fps) fps · \(plan.settings.timecodeFormatLabel)**.",
            "- Timecode de inicio: **\(startTimecode)**.",
            "- **\(plan.sceneCount) escenas · \(plan.markers.count) marcadores** (\(plan.sceneCount) escenas + \(plan.cueCount) cues).",
            "- Duración estimada: **\(duration)**.",
        ]

        if options.asciiSafeNames {
            lines.append("- Nombres del EDL transliterados a ASCII; el FCPXML y las notas conservan el texto original.")
        } else {
            lines.append("- Nombres con acentos y Unicode originales.")
        }
        lines.append("")

        lines.append("## Archivos")
        lines.append("")
        if options.includeMarkerEDL {
            lines.append("- `\(names.markerEDL)` — marcadores de escena y cues: B-roll por fuente, re-hook, rótulo, tabla y avisos de rigor/ritmo.")
        }
        if options.includeFCPXML {
            lines.append("- `\(names.fcpxml)` — timeline de referencia con los mismos marcadores\(options.includeChapterMarkersInFCPXML ? " y chapter markers" : "").")
        }
        if options.includeShotList {
            lines.append("- `\(names.shotList)` — plan de planos, una fila por plano, con timecode de entrada.")
        }
        if options.includeEditingNotes {
            lines.append("- `\(names.editingNotes)` — notas de montaje por escena: guion, plan de imagen, montaje, avisos y marcadores.")
        }
        if plan.includesChaptersFile {
            lines.append("- `\(names.chapters)` — capítulos listos para pegar en la descripción de YouTube.")
        } else if options.includeChapters {
            lines.append("- `\(names.chapters)` no se incluye: YouTube necesita al menos 3 capítulos de 10 s y esta lista no los cumple.")
        }
        lines.append("- `\(names.readme)` — este archivo.")
        lines.append("")

        if options.includeMarkerEDL {
            lines.append("## Importar los marcadores (EDL)")
            lines.append("")
            lines.append("1. Abre tu proyecto en DaVinci Resolve 21 (versión FREE).")
            lines.append("2. Crea o abre una timeline con el mismo frame rate del pack: **\(plan.settings.fps) fps**.")
            lines.append("3. Comprueba que la timeline empieza en **\(startTimecode)**. Si no, cambia su timecode de inicio en los ajustes del proyecto antes de importar.")
            lines.append("4. En la **Media Pool**, haz clic derecho sobre la timeline.")
            lines.append("5. Elige **Timelines > Import > Timeline Markers from EDL**.")
            lines.append("6. Selecciona `\(names.markerEDL)` y acepta.")
            lines.append("7. Si los marcadores aparecen desplazados, ajusta **Starting Timecode** en el diálogo de importación al timecode de inicio de la timeline (**\(startTimecode)**) y vuelve a importar. El EDL usa el timecode de registro del pack.")
            lines.append("8. Abre el panel de marcadores de Resolve para revisar la lista por color y nombre.")
            lines.append("")
        }

        if options.includeFCPXML {
            lines.append("## Importar la timeline FCPXML")
            lines.append("")
            lines.append("1. En Resolve, elige **File > Import > Timeline…**.")
            lines.append("2. Selecciona `\(names.fcpxml)`.")
            lines.append("3. Resolve crea una timeline de referencia con los marcadores\(options.includeChapterMarkersInFCPXML ? " y los chapter markers" : ""). No sustituye tu montaje: úsala para localizar posiciones y copiar marcadores.")
            lines.append("4. Si tu versión de Resolve ignora los marcadores del FCPXML, importa el EDL: es la ruta fiable.")
            lines.append("")
        }

        if options.includeShotList {
            lines.append("## Abrir el plan de planos (CSV)")
            lines.append("")
            lines.append("1. Abre `\(names.shotList)` en **Numbers** (arrástralo o usa **Archivo > Abrir**).")
            lines.append("2. La primera fila es la cabecera: `Escena, Titulo, TC entrada, Plano, Fuente, Estado, Notas`.")
            lines.append("3. Filtra por **Fuente** (CAM, OBS, captura, web, gráfico, música) o por **Estado** para preparar la grabación.")
            lines.append("4. `TC entrada` es el timecode absoluto con el inicio del pack; coincide con los marcadores del EDL.")
            lines.append("")
        }

        if options.includeEditingNotes {
            lines.append("## Notas de montaje")
            lines.append("")
            lines.append("Abre `\(names.editingNotes)` en cualquier editor Markdown. Cada escena lleva su timecode absoluto, duración, guion, plan de imagen, notas de montaje, avisos y la lista de marcadores con su color.")
            lines.append("")
        }

        if plan.includesChaptersFile {
            lines.append("## Capítulos de YouTube")
            lines.append("")
            lines.append("Pega el contenido de `\(names.chapters)` en la descripción de tu vídeo. YouTube necesita al menos tres capítulos, el primero en 0:00 y 10 segundos como mínimo por capítulo.")
            if !plan.chapters.warnings.isEmpty {
                lines.append("")
                lines.append("> Hay avisos de capítulos: revisa la lista de avisos del pack antes de publicar.")
            }
            lines.append("")
        } else if options.includeChapters {
            lines.append("## Capítulos de YouTube")
            lines.append("")
            lines.append("No se ha escrito `\(names.chapters)`: YouTube necesita al menos tres capítulos de 10 segundos y esta lista no los cumple. Añade escenas o marcas al guion y vuelve a exportar.")
            lines.append("")
        }

        lines.append("## Leyenda de colores")
        lines.append("")
        lines.append("| Color en Resolve | Uso |")
        lines.append("| --- | --- |")
        lines.append("| Azul (`Blue`) | Inicio de escena |")
        lines.append("| Verde (`Green`) | CAM / plano a cámara |")
        lines.append("| Amarillo (`Yellow`) | OBS / gameplay |")
        lines.append("| Rosa (`Pink`) | Captura / web / screenshot |")
        lines.append("| Rojo (`Red`) | Rigor (claim sin confirmar) o ritmo |")
        lines.append("| Morado (`Purple`) | Re-hook |")
        lines.append("| Naranja/arena (`Sand`) | Gráfico / tabla / rótulo |")
        lines.append("| Lavanda (`Lavender`) | Música |")
        lines.append("")
        lines.append("> Resolve no tiene un color llamado «Orange». Gráficos y tablas usan `Sand`, el naranja de Resolve.")
        lines.append("")

        lines.append("## Límites del formato")
        lines.append("")
        lines.append("- Los nombres de marcador se recortan a **60 caracteres** en el EDL. El texto completo sigue en el FCPXML, en las notas del EDL y en `\(names.editingNotes)`.")
        lines.append("- CMX3600 admite **999 eventos**; por encima, Resolve puede ignorar los últimos.")
        lines.append("- Resolve guarda un marcador por fotograma: si dos coinciden, se fusionan en la nota del primero.")
        lines.append("- El FCPXML es una timeline de referencia sin medios; no crea proxies ni enlaza tus archivos.")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func displayProject(_ value: String) -> String {
        let cleaned = ExportTextSanitizer.collapseWhitespace(value)
        return cleaned.isEmpty ? "FrameScript" : cleaned
    }
}
