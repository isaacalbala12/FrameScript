import Foundation
import Testing
@testable import FrameScriptCore

@Suite("Shot list CSV")
struct ShotListCSVTests {
    private func settings(
        bom: Bool = false,
        formulas: Bool = false,
        fps: FrameRate = .fps25,
        dropFrame: Bool = false
    ) -> ExportSettings {
        ExportSettings(
            projectName: "Demo",
            fps: fps,
            dropFrame: dropFrame,
            csvIncludesByteOrderMark: bom,
            csvEscapesFormulas: formulas
        )
    }

    @Test("Golden CSV with quoting, accents and CRLF")
    func golden() {
        let scenes = [
            ExportScene(
                title: "Gancho, ¿por qué?",
                start: 0,
                duration: 45,
                shots: [
                    ExportShot(
                        summary: "CAM: reacción",
                        source: .cam,
                        status: .pending,
                        notes: "plano medio"
                    ),
                    ExportShot(
                        summary: "Decir \"esto\" y girar",
                        source: .obs,
                        status: .recorded,
                        notes: "nota,\ncon salto",
                        offset: 12
                    ),
                ]
            ),
        ]

        let csv = ShotListCSV.make(scenes: scenes, settings: settings())

        #expect(csv == "Escena,Titulo,TC entrada,Plano,Fuente,Estado,Notas\r\n"
            + "00,\"Gancho, ¿por qué?\",01:00:00:00,CAM: reacción,CAM,pendiente,plano medio\r\n"
            + "00,\"Gancho, ¿por qué?\",01:00:12:00,\"Decir \"\"esto\"\" y girar\",OBS,grabado,\"nota,\ncon salto\"\r\n")
    }

    @Test("Writes no BOM by default and can add one")
    func byteOrderMark() {
        let scenes = [ExportScene(title: "A", start: 0, duration: 10)]
        let defaultData = ShotListCSV.makeData(scenes: scenes, settings: settings(bom: false))
        let withBOM = ShotListCSV.makeData(scenes: scenes, settings: settings(bom: true))

        #expect(Array(defaultData.prefix(3)) == Array("Esc".utf8))
        #expect(Array(withBOM.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(data: withBOM.dropFirst(3), encoding: .utf8)?.hasPrefix("Escena,") == true)
    }

    @Test("Formula escaping is opt-in")
    func formulaEscaping() {
        let scenes = [
            ExportScene(
                title: "A",
                start: 0,
                duration: 10,
                shots: [ExportShot(summary: "=SUM(A1:A2)")]
            ),
        ]

        let plain = ShotListCSV.make(scenes: scenes, settings: settings(formulas: false))
        let escaped = ShotListCSV.make(scenes: scenes, settings: settings(formulas: true))

        #expect(plain.contains(",=SUM(A1:A2),"))
        #expect(escaped.contains(",'=SUM(A1:A2),"))
    }

    @Test("Sanitises non-CSV controls and quotes tabs")
    func controlCharacters() {
        #expect(ShotListCSV.escape("a\tb") == "\"a\tb\"")
        #expect(ShotListCSV.escape("a\u{0001}b") == "a b")
        #expect(ShotListCSV.escape("a\u{001B}b") == "a b")
    }

    @Test("Only shots become rows")
    func onlyShotsBecomeRows() {
        let scenes = [
            ExportScene(title: "Sin planos", start: 0, duration: 10),
            ExportScene(
                title: "Con plano",
                start: 10,
                duration: 10,
                shots: [ExportShot(summary: "Uno")]
            ),
        ]

        let csv = ShotListCSV.make(scenes: scenes, settings: settings())
        let rows = csv.split(separator: "\r\n")
        #expect(rows.count == 2)
        #expect(rows[1].hasPrefix("01,Con plano,01:00:10:00,Uno,CAM,pendiente,"))
    }

    @Test("Timecode input uses the configured start and drop frame")
    func timecodes() {
        let scenes = [
            ExportScene(
                title: "Uno",
                start: 0,
                duration: 90,
                shots: [ExportShot(summary: "Plano", offset: 60)]
            ),
        ]

        let csv = ShotListCSV.make(
            scenes: scenes,
            settings: settings(fps: .fps29_97, dropFrame: true)
        )

        #expect(csv.contains(",01:00:59;28,"))
    }

    @Test("Empty input still produces a header")
    func empty() {
        let csv = ShotListCSV.make(scenes: [], settings: settings())
        #expect(csv == "Escena,Titulo,TC entrada,Plano,Fuente,Estado,Notas\r\n")
    }

    @Test("Quotes only when RFC 4180 requires it")
    func escaping() {
        #expect(ShotListCSV.escape("sin comas") == "sin comas")
        #expect(ShotListCSV.escape("a,b") == "\"a,b\"")
        #expect(ShotListCSV.escape("a\"b") == "\"a\"\"b\"")
        #expect(ShotListCSV.escape("a\nb") == "\"a\nb\"")
        #expect(ShotListCSV.escape(" a") == "\" a\"")
        #expect(ShotListCSV.escape("a ") == "\"a \"")
    }

    @Test("Source and status labels are the Spanish production tags")
    func labels() {
        #expect(ExportSourceTag.allCases.map(\.displayName) == ["CAM", "OBS", "captura", "web", "música", "gráfico"])
        #expect(ExportShotStatus.allCases.map(\.displayName) == ["pendiente", "grabado", "aprobado", "descartado"])
    }
}
