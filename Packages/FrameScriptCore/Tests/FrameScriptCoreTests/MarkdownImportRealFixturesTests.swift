import Foundation
import Testing
@testable import FrameScriptCore

/// Local-only test (decision D5). It never runs in CI unless
/// `FRAMESCRIPT_REAL_FIXTURES` points at a folder with the real Markdown
/// files. Nothing from those files is copied into the repository.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FRAMESCRIPT_REAL_FIXTURES"] != nil))
func realFixturesParseAndRoundTrip() throws {
    guard let path = ProcessInfo.processInfo.environment["FRAMESCRIPT_REAL_FIXTURES"] else {
        return
    }

    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let files = try FileManager.default
        .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    #expect(!files.isEmpty, "FRAMESCRIPT_REAL_FIXTURES no contiene archivos .md")

    var escaletaCount = 0
    for url in files {
        let text = try String(contentsOf: url, encoding: .utf8)
        let result = EscaletaParser.parse(text)
        let exported = EscaletaExporter.markdown(from: result.document)
        let reparsed = EscaletaParser.parse(exported)

        #expect(
            reparsed.document == result.document,
            "Round-trip estructural falló para \(url.lastPathComponent)"
        )

        // The real folder also contains research, thumbnail and technical
        // documents. Only documents recognised as escaletas must have scenes.
        if result.document.kind == .escaleta {
            escaletaCount += 1
            #expect(
                !result.document.scenes.isEmpty,
                "Se esperaba al menos una escena en \(url.lastPathComponent)"
            )
        }

        let cueCount = result.document.scenes.reduce(0) { $0 + $1.cues.count }
        let seoFields = result.document.publishing?
            .fieldOrder
            .map(\.rawValue)
            .joined(separator: ",") ?? "-"
        let warningKinds = Dictionary(grouping: result.warnings, by: { $0.kind.rawValue })
            .map { "\($0.key)=\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        print(
            "REAL-FIXTURE\t\(url.lastPathComponent)\tkind=\(result.document.kind.rawValue)\t"
                + "scenes=\(result.document.scenes.count)\tcues=\(cueCount)\t"
                + "tables=\(result.document.comparisonTables.count)\t"
                + "verify=\(result.document.verificationItems.count)\t"
                + "sources=\(result.document.sources.count)\t"
                + "seo=[\(seoFields)]\t"
                + "warnings=\(result.warnings.count)[\(warningKinds)]"
        )
    }

    #expect(escaletaCount >= 3, "Se esperaban al menos tres escaletas en la carpeta real")
}
