import Testing
@testable import FrameScriptCore

@Suite("Resolve marker EDL")
struct ResolveMarkerEDLTests {
    private func settings(
        project: String = "AC EVO 0.9",
        fps: FrameRate = .fps25,
        dropFrame: Bool = false,
        ascii: Bool = true,
        start: Timecode? = nil
    ) -> ExportSettings {
        ExportSettings(
            projectName: project,
            fps: fps,
            dropFrame: dropFrame,
            startTimecode: start,
            asciiSafeNames: ascii
        )
    }

    @Test("Golden EDL with scene, cue and re-hook markers")
    func golden() {
        let scenes = [
            ExportScene(
                title: "Gancho",
                start: 0,
                duration: 45,
                markers: [
                    ExportMarker(
                        offset: 12,
                        name: "OBS Special Events",
                        note: "Gameplay",
                        color: .yellow
                    ),
                ]
            ),
            ExportScene(
                title: "El verdadero problema",
                start: 45,
                duration: 55,
                isRehook: true
            ),
        ]

        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings())

        #expect(edl == """
        TITLE: AC EVO 0.9
        FCM: NON-DROP FRAME

        001  001      V     C        01:00:00:00 01:00:00:01 01:00:00:00 01:00:00:01
         |C:ResolveColorBlue |M:00 Gancho |D:1

        002  001      V     C        01:00:12:00 01:00:12:01 01:00:12:00 01:00:12:01
         |C:ResolveColorYellow |M:OBS Special Events |D:1

        003  001      V     C        01:00:45:00 01:00:45:01 01:00:45:00 01:00:45:01
         |C:ResolveColorBlue |M:01 El verdadero problema |D:1

        004  001      V     C        01:00:45:01 01:00:45:02 01:00:45:01 01:00:45:02
         |C:ResolveColorPurple |M:01 Re-hook El verdadero problema |D:1

        """)
    }

    @Test("29.97 drop frame uses semicolons and FCM: DROP FRAME")
    func dropFrame() {
        let scenes = [
            ExportScene(title: "Uno", start: 0, duration: 30),
            ExportScene(title: "Dos", start: 60, duration: 30),
        ]

        let edl = ResolveMarkerEDL.make(
            scenes: scenes,
            settings: settings(project: "Test", fps: .fps29_97, dropFrame: true)
        )

        #expect(edl.contains("FCM: DROP FRAME"))
        #expect(edl.contains("001  001      V     C        01:00:00;00 01:00:00;01 01:00:00;00 01:00:00;01"))
        #expect(edl.contains("002  001      V     C        01:00:59;28 01:00:59;29 01:00:59;28 01:00:59;29"))
    }

    @Test("Drop frame at 25 fps falls back to non-drop")
    func dropFrameFallback() {
        let scenes = [ExportScene(title: "Uno", start: 0, duration: 30)]
        let edl = ResolveMarkerEDL.make(
            scenes: scenes,
            settings: settings(fps: .fps25, dropFrame: true)
        )
        #expect(edl.contains("FCM: NON-DROP FRAME"))
        #expect(edl.contains("01:00:00:00"))
    }

    @Test("Transliterates accents, question marks and emoji")
    func asciiNames() {
        let scenes = [
            ExportScene(
                title: "Árbol ñandú ¿qué? 🎬",
                start: 0,
                duration: 20,
                markers: [
                    ExportMarker(offset: 1, name: "Gráfico — tabla | OBS", color: .lemon),
                ]
            ),
        ]

        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings())

        #expect(edl.contains("|M:00 Arbol nandu ?que? |D:1"))
        #expect(edl.contains("|M:Grafico - tabla / OBS |D:1"))
        #expect(!edl.contains("🎬"))
        #expect(!edl.contains("á"))
    }

    @Test("Keeps Unicode when ASCII-safe names are disabled")
    func unicodeNames() {
        let scenes = [ExportScene(title: "Árbol ñandú", start: 0, duration: 20)]
        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings(ascii: false))
        #expect(edl.contains("TITLE: AC EVO 0.9"))
        #expect(edl.contains("|M:00 Árbol ñandú |D:1"))
    }

    @Test("Never emits pipes or line breaks inside a marker name")
    func sanitisesControlCharacters() {
        let scenes = [
            ExportScene(
                title: "A | B",
                start: 0,
                duration: 20,
                markers: [
                    ExportMarker(offset: 1, name: "Línea\nuno | dos", color: .red),
                ]
            ),
        ]

        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings(ascii: false))

        #expect(edl.contains("|M:00 A / B |D:1"))
        #expect(edl.contains("|M:Línea uno / dos |D:1"))
        #expect(!edl.contains("Línea\nuno"))
    }

    @Test("Caps marker names at 60 characters")
    func capsNameLength() {
        let long = String(repeating: "a", count: 100)
        let scenes = [ExportScene(title: long, start: 0, duration: 20)]
        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings())
        let markerLine = edl.split(separator: "\n").first { $0.contains("|M:") }
        let name = markerLine?
            .split(separator: "|")
            .first { $0.hasPrefix("M:") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespaces) ?? ""
        #expect(name.count == 60)
    }

    @Test("Uses |D: for range markers")
    func rangeMarker() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 30,
                markers: [
                    ExportMarker(offset: 5, name: "Rango", color: .cyan, durationFrames: 125),
                ]
            ),
        ]
        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings())
        #expect(edl.contains("|M:Rango |D:125"))
    }

    @Test("Offsets record timecode by the configured start time")
    func startTimecodeOffset() {
        let scenes = [ExportScene(title: "Uno", start: 10, duration: 20)]
        let edl = ResolveMarkerEDL.make(
            scenes: scenes,
            settings: settings(start: Timecode(string: "00:00:00:00", rate: .fps25))
        )
        #expect(edl.contains("01  001      V     C        00:00:10:00"))
    }

    @Test("Orders markers by frame and numbers events from 001")
    func orderingAndNumbering() {
        let scenes = [
            ExportScene(
                title: "B",
                start: 40,
                duration: 20,
                markers: [ExportMarker(offset: 1, name: "Posterior", color: .mint)]
            ),
            ExportScene(
                title: "A",
                start: 0,
                duration: 20,
                markers: [ExportMarker(offset: 5, name: "Intermedio", color: .green)]
            ),
        ]

        let edl = ResolveMarkerEDL.make(scenes: scenes, settings: settings())
        let names = edl
            .split(separator: "\n")
            .filter { $0.hasPrefix(" |C:") }
            .compactMap { line -> String? in
                guard let range = line.range(of: "|M:") else { return nil }
                let rest = line[range.upperBound...]
                return rest.split(separator: "|").first.map { $0.trimmingCharacters(in: .whitespaces) }
            }

        #expect(names == ["00 A", "Intermedio", "01 B", "Posterior"])
        #expect(edl.contains("001  001"))
        #expect(edl.contains("004  001"))
    }

    @Test("Empty scene list produces a valid header")
    func emptyScenes() {
        let edl = ResolveMarkerEDL.make(scenes: [], settings: settings(project: "Test"))
        #expect(edl == "TITLE: Test\nFCM: NON-DROP FRAME\n")
    }

    @Test("All 16 Resolve colours are available and none is 'Orange'")
    func colors() {
        #expect(ExportMarkerColor.allCases.count == 16)
        #expect(ExportMarkerColor(rawValue: "ResolveColorOrange") == nil)
        #expect(ExportMarkerColor.lemon.rawValue == "ResolveColorLemon")
        #expect(ExportMarkerColor.allCases.allSatisfy { $0.rawValue.hasPrefix("ResolveColor") })
    }
}
