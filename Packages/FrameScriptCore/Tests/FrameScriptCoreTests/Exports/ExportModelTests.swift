import Foundation
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

    @Test("Frame rate fractions are reduced before comparison")
    func reducesFrameRateFractions() {
        let equivalent = FrameRate(numerator: 120_000, denominator: 2_002)
        #expect(equivalent == .fps59_94)
        #expect(equivalent.supportsDropFrame)
        #expect(equivalent.nominalFPS == 60)

        let ntsc = FrameRate(numerator: 48_000, denominator: 2_002)
        #expect(ntsc == .fps23_976)
        #expect(!ntsc.supportsDropFrame)
    }

    @Test("Codable rejects invalid frame rates and negative timecodes")
    func rejectsInvalidCodableValues() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                Timecode.self,
                from: Data("{\"frames\":-1}".utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                FrameRate.self,
                from: Data("{\"numerator\":1,\"denominator\":0}".utf8)
            )
        }
        let decoded = try? JSONDecoder().decode(
            Timecode.self,
            from: Data("{\"frames\":42}".utf8)
        )
        #expect(decoded?.frames == 42)
    }

    @Test("with(fps:) recomputes the default start timecode")
    func withRecomputesStartTimecode() {
        let base = ExportSettings(projectName: "X", fps: .fps25)
        #expect(base.startTimecode.frames == 90_000)

        let changed = base.with(fps: .fps29_97, dropFrame: true)
        #expect(changed.startTimecode.frames == 107_892)
        #expect(changed.startTimecode.string(rate: .fps29_97, dropFrame: true) == "01:00:00;00")

        let unchanged = base.with(fps: .fps25)
        #expect(unchanged.startTimecode.frames == 90_000)
    }

    @Test("Default CSV settings stay strict RFC 4180")
    func defaultCSVSettings() {
        let settings = ExportSettings()
        #expect(!settings.csvIncludesByteOrderMark)
        #expect(!settings.csvEscapesFormulas)
    }

    @Test("Control characters are stripped even without ASCII-safe names")
    func controlCharacters() {
        #expect(ExportTextSanitizer.markerName("A\u{0001}B\u{001B}C", asciiSafe: false) == "ABC")
        #expect(ExportTextSanitizer.title("A\u{0001}B", asciiSafe: false) == "AB")
        #expect(ExportTextSanitizer.chapterTitle("A\u{0001}B").text == "AB")
        #expect(ExportTextSanitizer.markerNote("A\u{0001}B", asciiSafe: false) == "AB")
    }

    @Test("Markdown stripping keeps snake_case, 2*3 and #1")
    func balancedMarkdown() {
        let cases: [(String, String)] = [
            ("**Gancho**", "Gancho"),
            ("*Gancho*", "Gancho"),
            ("_Gancho_", "Gancho"),
            ("`Gancho`", "Gancho"),
            ("my_file 2*3", "my_file 2*3"),
            ("snake_case and 2*3", "snake_case and 2*3"),
            ("#1 hit", "#1 hit"),
            ("## Título", "Título"),
            ("> cita", "cita"),
        ]
        for (input, expected) in cases {
            #expect(ExportTextSanitizer.stripMarkdown(input) == expected, "\(input)")
        }
        #expect(ExportTextSanitizer.markerName("my_file 2*3", asciiSafe: true) == "my_file 2*3")
        #expect(ExportTextSanitizer.chapterTitle("snake_case and 2*3").text == "snake_case and 2*3")
    }

    @Test("XML escaping drops noncharacters")
    func xmlNoncharacters() {
        #expect(XMLText.escape("A\u{FFFF}B\u{FFFE}C") == "ABC")
        #expect(XMLText.escape("A\u{1FFFE}B") == "AB")
        #expect(XMLText.escape("A\u{1FFFF}B") == "AB")
    }

    @Test("Colliding markers merge into the scene marker")
    func markerCollisions() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 30,
                markers: [
                    ExportMarker(offset: 0, name: "Cue", note: "B-roll", color: .green),
                    ExportMarker(offset: 0, name: "Cue 2", color: .pink),
                ]
            ),
        ]
        let settings = ExportSettings(projectName: "X", fps: .fps25)

        let resolution = ExportMarkerResolver.resolve(scenes: scenes, settings: settings)

        #expect(resolution.markers.count == 1)
        #expect(resolution.markers[0].kind == .scene)
        #expect(resolution.markers[0].note == "Inicio de escena · Cue: B-roll · Cue 2")
        #expect(resolution.warnings.count == 2)
        #expect(resolution.warnings.allSatisfy { $0.kind == .duplicateFrame })
    }

    @Test("Fractional scene start and offset round once, not twice")
    func fractionalOffsets() {
        let settings = ExportSettings(projectName: "X", fps: .fps25)
        let scenes = [
            ExportScene(
                title: "A",
                start: 0.02,
                duration: 10,
                markers: [ExportMarker(offset: 0.06, name: "Cue")]
            ),
        ]

        let markers = ExportMarkerResolver.allMarkers(scenes: scenes, settings: settings)
        let scene = markers.first { $0.kind == .scene }
        let cue = markers.first { $0.kind == .cue }
        #expect(scene?.frame == 1)
        #expect(cue?.frame == 2)
        #expect(Timecode(seconds: 0.02 + 0.06, rate: .fps25).frames == 2)

        let colliding = [
            ExportScene(
                title: "A",
                start: 0.02,
                duration: 10,
                markers: [ExportMarker(offset: 0.02, name: "Cue")]
            ),
        ]
        let resolution = ExportMarkerResolver.resolve(scenes: colliding, settings: settings)
        #expect(resolution.markers.count == 1)
        #expect(resolution.markers[0].note.contains("Cue"))
    }
}
