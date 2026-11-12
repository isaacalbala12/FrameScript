import Testing
@testable import FrameScriptCore

@Suite("Export models and text")
struct ExportModelTests {
    @Test("ASCII-safe transliterates Spanish punctuation and strips emoji")
    func asciiSafe() {
        #expect(ExportTextSanitizer.asciiSafe("Árbol ñandú") == "Arbol nandu")
        #expect(ExportTextSanitizer.asciiSafe("¿Qué? ¡Ya!") == "?Que? !Ya!")
        #expect(ExportTextSanitizer.asciiSafe("uno — dos – tres") == "uno - dos - tres")
        #expect(ExportTextSanitizer.asciiSafe("🎬 Gancho 🚗") == "Gancho")
        #expect(ExportTextSanitizer.asciiSafe("«Hola»") == "\"Hola\"")
        #expect(ExportTextSanitizer.asciiSafe("60 €") == "60 EUR")
    }

    @Test("Marker names drop pipes, collapse lines and cap at 60")
    func markerNames() {
        #expect(ExportTextSanitizer.markerName("A | B", asciiSafe: true) == "A / B")
        #expect(ExportTextSanitizer.markerName("A\nB", asciiSafe: true) == "A B")
        #expect(ExportTextSanitizer.markerName("   ", asciiSafe: true) == "Marker")
        #expect(ExportTextSanitizer.markerName(String(repeating: "x", count: 80), asciiSafe: true).count == 60)
        #expect(ExportTextSanitizer.markerName("**Gancho**", asciiSafe: false) == "Gancho")
        #expect(ExportTextSanitizer.markerName("Árbol", asciiSafe: false) == "Árbol")
    }

    @Test("Chapter titles keep Unicode but drop Markdown and emoji")
    func chapterTitles() {
        let cleaned = ExportTextSanitizer.chapterTitle("  **Qué  cambia** 🎬 ")
        #expect(cleaned.text == "Qué cambia")
        #expect(!cleaned.wasTruncated)

        let long = ExportTextSanitizer.chapterTitle(String(repeating: "a", count: 61))
        #expect(long.text.count == 60)
        #expect(long.wasTruncated)
    }

    @Test("XML escaping covers the five predefined entities and control characters")
    func xmlEscaping() {
        #expect(XMLText.escape("A & B < C > D \"E\" 'F'") == "A &amp; B &lt; C &gt; D &quot;E&quot; &apos;F&apos;")
        #expect(XMLText.escape("a\u{0001}b") == "ab")
        #expect(XMLText.attribute("dos\nlíneas") == "dos líneas")
    }

    @Test("Default start timecode is 01:00:00:00 at the chosen rate")
    func defaultStartTimecode() {
        let settings = ExportSettings(projectName: "X", fps: .fps29_97)
        #expect(settings.startTimecode.string(rate: .fps29_97, dropFrame: false) == "01:00:00:00")

        let df = ExportSettings(projectName: "X", fps: .fps29_97, dropFrame: true)
        #expect(df.startTimecode.string(rate: .fps29_97, dropFrame: true) == "01:00:00;00")
        #expect(df.effectiveDropFrame)
        #expect(df.timecodeFormatLabel == "DF")
    }

    @Test("Drop frame is reported as a warning on unsupported rates")
    func validationWarnings() {
        let settings = ExportSettings(projectName: "", fps: .fps25, dropFrame: true)
        #expect(!settings.effectiveDropFrame)
        #expect(settings.validationWarnings.count == 2)
    }

    @Test("Markers flatten in time order with a one-frame re-hook offset")
    func markerResolution() {
        let scenes = [
            ExportScene(
                title: "Dos",
                start: 20,
                duration: 20,
                isRehook: true,
                markers: [ExportMarker(offset: 2, name: "Cue", color: .red)]
            ),
            ExportScene(title: "Uno", start: 0, duration: 20),
        ]

        let settings = ExportSettings(projectName: "X", fps: .fps25)
        let markers = ExportMarkerResolver.markers(scenes: scenes, settings: settings)

        #expect(markers.map(\.frame) == [0, 500, 501, 550])
        #expect(markers.map(\.kind) == [.scene, .scene, .rehook, .cue])
        #expect(markers[0].name == "00 Uno")
        #expect(markers[1].name == "01 Dos")
        #expect(markers[2].color == .purple)
        #expect(markers[3].name == "Cue")
        #expect(markers[3].color == .red)
    }

    @Test("Timeline end covers scenes and markers")
    func timelineEnd() {
        let scenes = [
            ExportScene(title: "Uno", start: 0, duration: 5),
            ExportScene(
                title: "Dos",
                start: 5,
                duration: 5,
                markers: [ExportMarker(offset: 10, name: "Tarde", durationFrames: 3)]
            ),
        ]
        let settings = ExportSettings(projectName: "X", fps: .fps25)
        // Marker at 15 s + 3 frames = 378 frames; scene end is 250.
        #expect(ExportMarkerResolver.timelineEndFrame(scenes: scenes, settings: settings) == 378)
    }

    @Test("Suggested colours follow the delivery legend")
    func suggestedColours() {
        #expect(ExportMarkerColor.suggested(for: .cam) == .green)
        #expect(ExportMarkerColor.suggested(for: .obs) == .yellow)
        #expect(ExportMarkerColor.suggested(for: .capture) == .pink)
        #expect(ExportMarkerColor.suggested(for: .web) == .pink)
        #expect(ExportMarkerColor.suggested(for: .music) == .lavender)
        #expect(ExportMarkerColor.suggested(for: .graphic) == .lemon)
    }
}
