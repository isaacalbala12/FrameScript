import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Resolve FCPXML")
struct ResolveFCPXMLTests {
    private func settings(
        project: String = "Test",
        fps: FrameRate = .fps25,
        dropFrame: Bool = false,
        chapters: Bool = false,
        start: Timecode? = nil
    ) -> ExportSettings {
        ExportSettings(
            projectName: project,
            fps: fps,
            dropFrame: dropFrame,
            startTimecode: start,
            includeChapterMarkers: chapters
        )
    }

    @Test("Golden FCPXML 1.10 placeholder timeline")
    func golden() {
        let scenes = [
            ExportScene(
                title: "Gancho",
                start: 0,
                duration: 10,
                markers: [
                    ExportMarker(offset: 5, name: "B-roll", note: "CAM & gameplay", color: .green),
                ]
            ),
        ]

        let xml = ResolveFCPXML.make(scenes: scenes, settings: settings())

        #expect(xml == """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" name="FFVideoFormat1080p25" frameDuration="1/25s" width="1920" height="1080"/>
          </resources>
          <library>
            <event name="FrameScript">
              <project name="Test">
                <sequence format="r1" duration="10s" tcStart="3600s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                  <spine>
                    <gap name="Timeline" offset="0s" duration="10s" start="0s">
                      <marker start="0s" duration="1/25s" value="00 Gancho" note="Inicio de escena"/>
                      <marker start="5s" duration="1/25s" value="B-roll" note="CAM &amp; gameplay"/>
                    </gap>
                  </spine>
                </sequence>
              </project>
            </event>
          </library>
        </fcpxml>

        """)
    }

    @Test("Output is well-formed XML")
    func wellFormed() throws {
        let scenes = [
            ExportScene(
                title: "Tom & Jerry <\"x\">",
                start: 0,
                duration: 10,
                markers: [
                    ExportMarker(offset: 1, name: "A & B <tag>", note: "línea & <ojo>", color: .pink),
                ]
            ),
        ]

        let xml = ResolveFCPXML.make(scenes: scenes, settings: settings())

        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse(), "XMLParser rejected the document: \(parser.parserError?.localizedDescription ?? "unknown")")
        #expect(xml.contains("Tom &amp; Jerry &lt;&quot;x&quot;&gt;"))
        #expect(xml.contains("value=\"00 Tom &amp; Jerry &lt;&quot;x&quot;&gt;\""))
        #expect(!xml.contains("<tag>"))
    }

    @Test("29.97 drop frame exports DF, rational frame duration and DF tcStart")
    func dropFrame() {
        let scenes = [ExportScene(title: "Uno", start: 0, duration: 10)]
        let xml = ResolveFCPXML.make(
            scenes: scenes,
            settings: settings(fps: .fps29_97, dropFrame: true)
        )

        #expect(xml.contains("tcFormat=\"DF\""))
        #expect(xml.contains("frameDuration=\"1001/30000s\""))
        #expect(xml.contains("duration=\"1001/100s\""))
        #expect(xml.contains("tcStart=\"8999991/2500s\""))
    }

    @Test("23.976 exports the NTSC frame duration")
    func ntsc2398() {
        let scenes = [ExportScene(title: "Uno", start: 0, duration: 10)]
        let xml = ResolveFCPXML.make(scenes: scenes, settings: settings(fps: .fps23_976))

        #expect(xml.contains("FFVideoFormat1080p2398"))
        #expect(xml.contains("frameDuration=\"1001/24000s\""))
        #expect(xml.contains("duration=\"1001/100s\""))
        #expect(xml.contains("tcFormat=\"NDF\""))
    }

    @Test("Sequence duration covers a marker placed after the last scene")
    func durationCoversMarkers() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 5,
                markers: [ExportMarker(offset: 10, name: "Tarde", color: .red)]
            ),
        ]

        let xml = ResolveFCPXML.make(scenes: scenes, settings: settings())

        // 10 s + 1 frame = 251 frames at 25 fps.
        #expect(xml.contains("duration=\"251/25s\""))
        #expect(xml.contains("<marker start=\"10s\""))
    }

    @Test("Chapter markers are opt-in and use the chapter list")
    func chapterMarkers() {
        let scenes = [
            ExportScene(title: "A", start: 0, duration: 20),
            ExportScene(title: "B", start: 20, duration: 20),
            ExportScene(title: "C", start: 40, duration: 20),
        ]

        let without = ResolveFCPXML.make(scenes: scenes, settings: settings())
        #expect(!without.contains("<chapter-marker"))

        let with = ResolveFCPXML.make(scenes: scenes, settings: settings(chapters: true))
        #expect(with.contains("<chapter-marker start=\"0s\" duration=\"1/25s\" value=\"A\"/>"))
        #expect(with.contains("<chapter-marker start=\"20s\" duration=\"1/25s\" value=\"B\"/>"))
        #expect(with.contains("<chapter-marker start=\"40s\" duration=\"1/25s\" value=\"C\"/>"))
    }

    @Test("Empty scenes still produce a one-frame placeholder timeline")
    func emptyScenes() {
        let xml = ResolveFCPXML.make(scenes: [], settings: settings())
        #expect(xml.contains("<gap name=\"Timeline\" offset=\"0s\" duration=\"1/25s\" start=\"0s\">"))
        #expect(!xml.contains("<marker"))
        let parser = XMLParser(data: Data(xml.utf8))
        #expect(parser.parse())
    }

    @Test("Rational time helpers reduce and suffix seconds")
    func rationalTimes() {
        #expect(ResolveFCPXML.frameDuration(.fps25) == "1/25s")
        #expect(ResolveFCPXML.frameDuration(.fps29_97) == "1001/30000s")
        #expect(ResolveFCPXML.rationalSeconds(frames: 0, rate: .fps25) == "0s")
        #expect(ResolveFCPXML.rationalSeconds(frames: 25, rate: .fps25) == "1s")
        #expect(ResolveFCPXML.rationalSeconds(frames: 1, rate: .fps25) == "1/25s")
        #expect(ResolveFCPXML.rationalSeconds(frames: 300, rate: .fps29_97) == "1001/100s")
    }

    @Test("Every supported rate maps to an Apple video format name")
    func formatNames() {
        #expect(ResolveFCPXML.videoFormatName(.fps23_976) == "FFVideoFormat1080p2398")
        #expect(ResolveFCPXML.videoFormatName(.fps24) == "FFVideoFormat1080p24")
        #expect(ResolveFCPXML.videoFormatName(.fps25) == "FFVideoFormat1080p25")
        #expect(ResolveFCPXML.videoFormatName(.fps29_97) == "FFVideoFormat1080p2997")
        #expect(ResolveFCPXML.videoFormatName(.fps30) == "FFVideoFormat1080p30")
        #expect(ResolveFCPXML.videoFormatName(.fps50) == "FFVideoFormat1080p50")
        #expect(ResolveFCPXML.videoFormatName(.fps59_94) == "FFVideoFormat1080p5994")
        #expect(ResolveFCPXML.videoFormatName(.fps60) == "FFVideoFormat1080p60")
    }
}
