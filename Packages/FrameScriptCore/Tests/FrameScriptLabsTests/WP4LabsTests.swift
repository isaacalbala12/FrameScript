import Foundation
import Testing
import FrameScriptCore
@testable import FrameScriptLabs

// MARK: - WP4: dormant delivery pack regressions

@Suite("WP4 labs exports")
struct WP4LabsExportTests {
    @Test func shotListCSVQuotesFieldsWithWindowsLineEndings() {
        // "\\r\\n" is a single grapheme cluster; the quoting decision must use
        // unicode scalars or the CRLF breaks the record.
        #expect(ShotListCSV.escape("a\r\nb") == "\"a\r\nb\"")
        #expect(ShotListCSV.escape("a\nb") == "\"a\nb\"")
    }

    @Test func asciiSafeKeepsNonDecomposableLatinLetters() {
        #expect(
            ExportTextSanitizer.asciiSafe("Ørsted Ærø ß łódź Đorđe")
                == "Orsted AEro ss lodz Dorde"
        )
        #expect(ExportTextSanitizer.asciiSafe("Æ") == "AE")
        #expect(ExportTextSanitizer.asciiSafe("Đ") == "D")
    }
}
