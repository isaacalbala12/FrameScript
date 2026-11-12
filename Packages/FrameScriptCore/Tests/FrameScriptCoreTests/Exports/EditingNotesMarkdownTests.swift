import Testing
@testable import FrameScriptCore

@Suite("Editing notes Markdown")
struct EditingNotesMarkdownTests {
    private func settings(project: String = "Demo", fps: FrameRate = .fps25) -> ExportSettings {
        ExportSettings(projectName: project, fps: fps, startTimecode: Timecode.oneHour(rate: fps, dropFrame: false))
    }

    @Test("Golden notes grouped by scene with timecodes")
    func golden() {
        let scenes = [
            ExportScene(
                title: "Gancho",
                start: 0,
                duration: 30,
                isRehook: true,
                markers: [
                    ExportMarker(offset: 10, name: "B-roll OBS", note: "Gameplay", color: .yellow),
                ],
                shots: [
                    ExportShot(summary: "reacción", source: .cam, status: .pending),
                ],
                scriptExcerpt: "Hola.",
                editingNotes: ["Corte: jump cuts limpios"],
                warnings: ["Claim especulativo"],
                targetDuration: 25
            ),
        ]

        let notes = EditingNotesMarkdown.make(scenes: scenes, settings: settings())

        #expect(notes == """
        # Notas de montaje — Demo

        Timecode de inicio: 01:00:00:00 · 25 fps · NDF

        ## 00 — Gancho (0:00)
        TC: 01:00:00:00 · Duración: 0:30 · Objetivo: 0:25

        **GUION**
        > Hola.

        **PLAN DE IMAGEN**
        - [pendiente] CAM · reacción

        **MONTAJE**
        - Corte: jump cuts limpios

        **AVISOS**
        - Claim especulativo

        **RE-HOOK**
        Punto de re-enganche: cerrar con pregunta o giro.

        **MARCADORES**
        - 01:00:00:01 · 00 Re-hook Gancho (morado) — Punto de re-enganche
        - 01:00:10:00 · B-roll OBS (amarillo) — Gameplay

        """)
    }

    @Test("Omits empty sections")
    func omitsEmptySections() {
        let scenes = [ExportScene(title: "Gancho", start: 0, duration: 10)]
        let notes = EditingNotesMarkdown.make(scenes: scenes, settings: settings())

        #expect(notes == """
        # Notas de montaje — Demo

        Timecode de inicio: 01:00:00:00 · 25 fps · NDF

        ## 00 — Gancho (0:00)
        TC: 01:00:00:00 · Duración: 0:10

        """)
        #expect(!notes.contains("**GUION**"))
        #expect(!notes.contains("**PLAN DE IMAGEN**"))
        #expect(!notes.contains("**MARCADORES**"))
    }

    @Test("Handles an empty project")
    func emptyProject() {
        let notes = EditingNotesMarkdown.make(scenes: [], settings: settings())
        #expect(notes.hasSuffix("Sin escenas.\n"))
    }

    @Test("Uses drop-frame timecode for marker rows")
    func dropFrameMarkers() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 90,
                markers: [
                    ExportMarker(offset: 60, name: "Corte", note: "", color: .red),
                ]
            ),
        ]

        let settings = ExportSettings(
            projectName: "Demo",
            fps: .fps29_97,
            dropFrame: true,
            startTimecode: Timecode.oneHour(rate: .fps29_97, dropFrame: true)
        )
        let notes = EditingNotesMarkdown.make(scenes: scenes, settings: settings)

        #expect(notes.contains("Timecode de inicio: 01:00:00;00 · 29.97 fps · DF"))
        #expect(notes.contains("- 01:00:59;28 · Corte (rojo)"))
    }

    @Test("Multiple scenes are sorted and numbered")
    func multipleScenes() {
        let scenes = [
            ExportScene(title: "Dos", start: 20, duration: 20),
            ExportScene(title: "Uno", start: 0, duration: 20),
        ]
        let notes = EditingNotesMarkdown.make(scenes: scenes, settings: settings())

        let firstRange = notes.range(of: "## 00 — Uno")
        let secondRange = notes.range(of: "## 01 — Dos")
        #expect(firstRange != nil)
        #expect(secondRange != nil)
        if let firstRange, let secondRange {
            #expect(firstRange.lowerBound < secondRange.lowerBound)
        }
    }
}
