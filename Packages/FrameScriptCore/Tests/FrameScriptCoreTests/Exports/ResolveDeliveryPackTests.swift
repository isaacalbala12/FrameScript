import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Resolve delivery pack")
struct ResolveDeliveryPackTests {
    // MARK: - Fixtures

    private func scenes() -> [ExportScene] {
        [
            ExportScene(
                title: "Gancho",
                start: 0,
                duration: 20,
                markers: [
                    ExportMarker(offset: 3, name: "OBS · gameplay", note: "Curva 4", color: .yellow),
                    ExportMarker(offset: 5, name: "CAM · plano a cámara", color: .green),
                    ExportMarker(offset: 7, name: "RÓTULO · precio", color: .sand),
                    ExportMarker(offset: 9, name: "TABLA · comparativa", color: .sand),
                    ExportMarker(offset: 11, name: "RIGOR · claim", note: "Sin fuente", color: .red),
                ]
            ),
            ExportScene(
                title: "El problema",
                start: 20,
                duration: 30,
                isRehook: true
            ),
            ExportScene(
                title: "Cierre",
                start: 50,
                duration: 10,
                markers: [
                    ExportMarker(offset: 2, name: "CAJÓN · heredado", color: .cyan),
                ]
            ),
        ]
    }

    private func options(
        fps: FrameRate = .fps25,
        dropFrame: Bool = false,
        ascii: Bool = true
    ) -> ResolvePackOptions {
        ResolvePackOptions(
            fps: fps,
            dropFrame: dropFrame,
            asciiSafeNames: ascii
        )
    }

    private func plan(
        project: String = "AC EVO 0.9",
        scenes: [ExportScene]? = nil,
        options: ResolvePackOptions? = nil
    ) -> ResolvePackPlan {
        ResolveDeliveryPack.plan(
            scenes: scenes ?? self.scenes(),
            projectName: project,
            options: options ?? self.options()
        )
    }

    private func edlEvents(_ edl: String) -> [String] {
        edl.components(separatedBy: "\r\n").filter { line in
            let prefix = line.prefix(3)
            return prefix.count == 3 && prefix.allSatisfy(\.isNumber)
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResolveDeliveryPackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Marker coverage

    @Test("One EDL event per scene and per cue")
    func markerCountEqualsScenesPlusCues() {
        let plan = plan()
        // Five cues in scene 1, a re-hook in scene 2 and a cue in scene 3.
        #expect(plan.sceneCount == 3)
        #expect(plan.cueCount == 7)
        #expect(plan.allMarkers.count == 10)
        #expect(plan.markers.count == 10)

        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        #expect(edlEvents(edl).count == plan.allMarkers.count)
        #expect(edlEvents(edl).count == plan.sceneCount + plan.cueCount)
    }

    @Test("Colliding cues survive in the pre-merge list and merge once in Resolve")
    func collisionKeepsEveryCueBeforeMerge() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 30,
                markers: [
                    ExportMarker(offset: 0, name: "Cue A", color: .green),
                    ExportMarker(offset: 0, name: "Cue B", color: .pink),
                ]
            ),
        ]
        let plan = plan(scenes: scenes)
        #expect(plan.allMarkers.count == 3)
        #expect(plan.sceneCount + plan.cueCount == 3)
        #expect(plan.markers.count == 1)
        #expect(plan.warnings.contains { $0.contains("coincide") })
    }

    @Test("The preview uses the same absolute timecodes as the EDL")
    func previewTimecodes() {
        let plan = plan()
        let first = plan.markerPreviews.first
        #expect(first?.timecode == "01:00:00:00")
        #expect(first?.name == "00 Gancho")
        #expect(first?.color == .blue)

        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        for event in edlEvents(edl) {
            let fields = event.split(whereSeparator: { $0 == " " })
            guard fields.count >= 8 else { continue }
            #expect(plan.markerPreviews.contains { $0.timecode == String(fields[6]) })
        }
    }

    // MARK: - Timecode

    @Test("29.97 drop frame writes semicolons and DROP FRAME")
    func dropFrame29_97() {
        let settings = options(fps: .fps29_97, dropFrame: true)
        let plan = plan(options: settings)
        #expect(plan.settings.effectiveDropFrame)
        #expect(plan.markerPreviews.first?.timecode == "01:00:00;00")

        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        #expect(edl.contains("FCM: DROP FRAME"))
        #expect(edl.contains("01:00:00;00 01:00:00;01"))
        #expect(!edl.contains("01:00:00:00"))
        let semicolonTimecodes = edl.components(separatedBy: "\r\n").filter {
            $0.range(of: #"\d\d:\d\d:\d\d;\d\d"#, options: .regularExpression) != nil
        }
        #expect(semicolonTimecodes.count >= plan.allMarkers.count)
    }

    @Test("59.94 drop frame starts at 01:00:00;00")
    func dropFrame59_94() {
        let plan = plan(options: options(fps: .fps59_94, dropFrame: true))
        #expect(plan.settings.fps == .fps59_94)
        #expect(plan.markerPreviews.first?.timecode == "01:00:00;00")
        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        #expect(edl.contains("01:00:00;00 01:00:00;01"))
    }

    @Test("Changing the rate recomputes the default start so markers never land an hour off")
    func noHourOffset() throws {
        let base = options()
        let converted = base.with(fps: .fps29_97, dropFrame: true)
        #expect(converted.startTimecode.frames == 107_892)
        #expect(
            converted.startTimecode.string(rate: .fps29_97, dropFrame: true) == "01:00:00;00"
        )

        let plan = plan(options: converted)
        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        #expect(edlEvents(edl).first?.contains("01:00:00;00") == true)
        #expect(!edl.contains("02:00:"))

        let xml = ResolveFCPXML.make(scenes: plan.scenes, settings: plan.settings)
        let document = try XMLDocument(data: Data(xml.utf8))
        let sequence = try document.nodes(forXPath: "//sequence").first as? XMLElement
        let gap = try document.nodes(forXPath: "//gap").first as? XMLElement
        let firstMarker = try document.nodes(forXPath: "//marker").first as? XMLElement
        #expect(sequence?.attribute(forName: "tcStart")?.stringValue == gap?.attribute(forName: "offset")?.stringValue)
        #expect(firstMarker?.attribute(forName: "start")?.stringValue == "0s")
    }

    // MARK: - Names

    @Test("ASCII-safe names transliterate the EDL but the preview keeps the original")
    func asciiNames() {
        let scenes = [
            ExportScene(title: "Árbol ñandú ¿qué? 🎬", start: 0, duration: 20),
        ]
        let plan = plan(project: "Árbol ñandú", scenes: scenes, options: options(ascii: true))
        #expect(plan.names.folder == "Arbol nandu_resolve")
        #expect(plan.names.markerEDL == "Arbol nandu_markers.edl")
        #expect(plan.markerPreviews.first?.name == "00 Árbol ñandú ¿qué?")
        #expect(plan.markerPreviews.first?.edlName == "00 Arbol nandu ?que?")
        #expect(plan.markerPreviews.first?.edlDiffers == true)
        let edl = ResolveMarkerEDL.make(scenes: plan.scenes, settings: plan.settings)
        #expect(edl.hasPrefix("TITLE: Arbol nandu\r\n"))
        #expect(!edl.contains("ñ"))
    }

    @Test("Unicode names survive when ASCII-safe is off")
    func unicodeNames() {
        let plan = plan(
            project: "Árbol ñandú",
            scenes: [ExportScene(title: "Árbol ñandú", start: 0, duration: 20)],
            options: options(ascii: false)
        )
        #expect(plan.names.folder == "Árbol ñandú_resolve")
        #expect(plan.names.markerEDL == "Árbol ñandú_markers.edl")
        #expect(plan.markerPreviews.first?.name == "00 Árbol ñandú")
    }

    @Test("Sanitises path separators and falls back for an empty name")
    func naming() {
        #expect(ResolvePackNaming.slug("a/b:c*?", asciiSafe: true) == "a-b-c")
        #expect(ResolvePackNaming.slug("   ", asciiSafe: true) == "FrameScript")
        #expect(ResolvePackNaming.slug("...", asciiSafe: true) == "FrameScript")
        #expect(ResolvePackNaming.slug("AC EVO 0.9", asciiSafe: true) == "AC EVO 0.9")
        let names = ResolvePackNaming.names(projectName: "AC EVO 0.9", asciiSafe: true)
        #expect(names.folder == "AC EVO 0.9_resolve")
        #expect(names.fcpxml == "AC EVO 0.9.fcpxml")
        #expect(names.shotList == "AC EVO 0.9_shots.csv")
        #expect(names.editingNotes == "AC EVO 0.9_edit_notes.md")
        #expect(names.chapters == "AC EVO 0.9_chapters.txt")
        #expect(names.readme == "README.md")

        let accented = ResolvePackNaming.names(
            projectName: "AC EVO 0.9: guía completa",
            asciiSafe: true
        )
        #expect(accented.markerEDL == "AC EVO 0.9- guia completa_markers.edl")
    }

    @Test("Warns when a marker name is cut to 60 characters")
    func truncationWarnings() {
        let long = String(repeating: "Palabra ", count: 20)
        let plan = plan(scenes: [ExportScene(title: long, start: 0, duration: 20)])
        #expect(plan.warnings.contains { $0.contains("60 caracteres") && $0.contains("Palabra") })
        #expect(plan.markerPreviews.first?.name.count ?? 0 > 60)
        #expect(plan.markerPreviews.first?.edlName.count == 60)
    }

    // MARK: - Files

    @Test("Only selected files are rendered")
    func fileSelection() {
        var options = self.options()
        options.includeFCPXML = false
        options.includeShotList = false
        options.includeEditingNotes = false
        options.includeChapters = false
        let plan = plan(options: options)
        let files = ResolveDeliveryPack.files(for: plan)
        #expect(files.map(\.name) == [plan.names.markerEDL, plan.names.readme])
        #expect(plan.options.includeReadme)
        #expect(options.hasAnyFile)

        var none = self.options()
        none.includeMarkerEDL = false
        none.includeFCPXML = false
        none.includeShotList = false
        none.includeEditingNotes = false
        none.includeChapters = false
        none.includeReadme = false
        #expect(!none.hasAnyFile)
    }

    @Test("Every file renders valid content and chapters stay paste-ready")
    func fileContents() {
        let pack = plan()
        let files = ResolveDeliveryPack.files(for: pack)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })

        let edl = byName[pack.names.markerEDL]?.text
        #expect(edl?.contains("TITLE: AC EVO 0.9") == true)
        #expect(edl?.hasSuffix("\r\n") == true)

        let csv = byName[pack.names.shotList]?.text
        #expect(csv?.hasPrefix(ShotListCSV.header + "\r\n") == true)

        let notes = byName[pack.names.editingNotes]?.text
        #expect(notes?.contains("# Notas de montaje — AC EVO 0.9") == true)
        #expect(notes?.contains("## 00 — Gancho") == true)

        let chapters = byName[pack.names.chapters]?.text
        #expect(chapters?.hasSuffix("\n") == true)
        #expect(chapters?.contains("0:00 Gancho") == true)

        let xml = byName[pack.names.fcpxml]?.text
        #expect(xml?.contains("<marker") == true)
        #expect(xml?.contains("<chapter-marker") == true)
    }

    @Test("FCPXML chapter markers can be disabled independently")
    func chapterMarkersOption() {
        var options = self.options()
        options.includeChapterMarkersInFCPXML = false
        let plan = plan(options: options)
        let xml = ResolveFCPXML.make(scenes: plan.scenes, settings: plan.settings)
        #expect(!xml.contains("<chapter-marker"))
    }

    @Test("Writes the folder and removes stale files from a previous export")
    func writeFolder() throws {
        let parent = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: parent) }

        let full = plan()
        let folder = try ResolveDeliveryPack.write(full, to: parent)
        #expect(folder.lastPathComponent == "AC EVO 0.9_resolve")
        let written = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(written) == Set(full.names.all))

        var edlOnly = self.options()
        edlOnly.includeFCPXML = false
        edlOnly.includeShotList = false
        edlOnly.includeEditingNotes = false
        edlOnly.includeChapters = false
        edlOnly.includeReadme = false
        let second = plan(options: edlOnly)
        try ResolveDeliveryPack.write(second, to: parent)

        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(after == [second.names.markerEDL])
    }

    // MARK: - README

    @Test("README documents the free Resolve workflow and only included files")
    func readme() {
        let pack = plan()
        let readme = ResolvePackReadme.make(plan: pack)
        #expect(readme.contains("Pack para DaVinci Resolve — AC EVO 0.9"))
        #expect(readme.contains("Timelines > Import > Timeline Markers from EDL"))
        #expect(readme.contains("File > Import > Timeline"))
        #expect(readme.contains("Numbers"))
        #expect(readme.contains("Starting Timecode"))
        #expect(readme.contains(pack.names.markerEDL))
        #expect(readme.contains(pack.names.fcpxml))
        #expect(readme.contains(pack.names.shotList))
        #expect(readme.contains(pack.names.editingNotes))
        #expect(readme.contains(pack.names.chapters))
        #expect(readme.contains("01:00:00:00"))
        #expect(readme.contains("60 caracteres"))
        #expect(readme.contains("999 eventos"))
        #expect(readme.contains("Sand"))

        var edlOnly = self.options()
        edlOnly.includeFCPXML = false
        edlOnly.includeShotList = false
        edlOnly.includeEditingNotes = false
        edlOnly.includeChapters = false
        let minimal = ResolvePackReadme.make(plan: plan(options: edlOnly))
        #expect(minimal.contains("Timeline Markers from EDL"))
        #expect(!minimal.contains("File > Import > Timeline"))
        #expect(!minimal.contains(pack.names.fcpxml))
        #expect(!minimal.contains(pack.names.shotList))
    }

    @Test("Warns about chapters only when the chapter output is requested")
    func chapterWarnings() {
        let short = [
            ExportScene(title: "A", start: 0, duration: 20),
            ExportScene(title: "B", start: 20, duration: 20),
        ]
        let included = plan(scenes: short)
        #expect(included.warnings.contains { $0.contains("3 capítulos") })

        var options = self.options()
        options.includeChapters = false
        options.includeChapterMarkersInFCPXML = false
        let excluded = plan(scenes: short, options: options)
        #expect(!excluded.warnings.contains { $0.contains("3 capítulos") })
    }

    @Test("Drop frame is ignored for rates that cannot support it")
    func dropFrameFallback() {
        let options = ResolvePackOptions(fps: .fps25, dropFrame: true)
        #expect(!options.dropFrame)
        #expect(!options.settings(projectName: "X").effectiveDropFrame)
        #expect(options.startTimecode.frames == 90_000)
    }
}
