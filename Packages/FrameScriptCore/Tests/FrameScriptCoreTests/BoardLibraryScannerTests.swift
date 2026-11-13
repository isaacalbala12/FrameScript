import Foundation
@testable import FrameScriptCore
import Testing

@Suite("Board library scanner")
struct BoardLibraryScannerTests {
    @Test func scanFindsNestedProjectsSkipsHiddenAndForeignFilesAndDeduplicatesRoots() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("Season 1", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        let first = root.appendingPathComponent("alpha.fscr")
        let second = nested.appendingPathComponent("beta.fscr")
        try writeBoardDocument(boardDocument(title: "Alpha"), to: first)
        try writeBoardDocument(boardDocument(title: "Beta"), to: second)
        try writeBoardDocument(boardDocument(title: "Hidden"), to: hidden.appendingPathComponent("hidden.fscr"))
        try Data("not a project".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let scanner = BoardLibraryScanner()
        let result = scanner.scan(
            BoardScanRequest(
                folderURLs: [root, root],
                extraFileURLs: [first, root.appendingPathComponent("missing.fscr")]
            )
        )

        #expect(result.index.summaries.count == 2)
        #expect(Set(result.index.summaries.map(\.title)) == ["Alpha", "Beta"])
        #expect(result.stats.folderCount == 2)
        #expect(result.stats.fileCount == 2)
        #expect(result.stats.decodedCount == 2)
        #expect(result.index.warnings.isEmpty)
    }

    @Test func corruptFileProducesAWarningAndDoesNotHideReadableProjects() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let good = root.appendingPathComponent("good.fscr")
        try writeBoardDocument(boardDocument(title: "Good"), to: good)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("broken.fscr"))

        let result = BoardLibraryScanner().scan(BoardScanRequest(folderURLs: [root]))

        #expect(result.index.summaries.map(\.title) == ["Good"])
        #expect(result.index.warnings.count == 1)
        #expect(result.index.warnings.first?.kind == .corruptDocument)
    }

    @Test func newerSchemaVersionIsReportedAsUnsupportedInsteadOfCorrupt() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("future.fscr")
        try writeBoardDocument(boardDocument(title: "Future"), to: url)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"fileVersion\":4", with: "\"fileVersion\":999")
        try text.write(to: url, atomically: true, encoding: .utf8)

        let result = BoardLibraryScanner().scan(BoardScanRequest(folderURLs: [root]))

        #expect(result.index.summaries.isEmpty)
        #expect(result.index.warnings.first?.kind == .unsupportedVersion)
    }

    @Test func missingFolderIsReportedWithoutFailingTheScan() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeBoardDocument(boardDocument(title: "One"), to: root.appendingPathComponent("one.fscr"))
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        let result = BoardLibraryScanner().scan(BoardScanRequest(folderURLs: [missing, root]))

        #expect(result.index.summaries.count == 1)
        #expect(result.index.warnings.contains { $0.kind == .folderMissing && $0.url == missing })
    }

    @Test func secondScanReusesUnchangedSummariesAndReDecodesEditedFile() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.fscr")
        let second = root.appendingPathComponent("second.fscr")
        try writeBoardDocument(boardDocument(title: "First"), to: first)
        try writeBoardDocument(boardDocument(title: "Second"), to: second)

        let scanner = BoardLibraryScanner()
        let initial = scanner.scan(BoardScanRequest(folderURLs: [root]))
        #expect(initial.stats.decodedCount == 2)

        let reused = scanner.scan(BoardScanRequest(folderURLs: [root], previous: initial.index))
        #expect(reused.stats.decodedCount == 0)
        #expect(reused.stats.reusedCount == 2)
        #expect(reused.index.summaries == initial.index.summaries)

        try writeBoardDocument(boardDocument(title: "First edited"), to: first)
        // Ensure the modification date changes even on a fast file system.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: first.path
        )

        let changed = scanner.scan(BoardScanRequest(folderURLs: [root], previous: reused.index))
        #expect(changed.stats.decodedCount == 1)
        #expect(changed.stats.reusedCount == 1)
        #expect(changed.index.summaries.contains { $0.title == "First edited" })
        #expect(changed.index.summaries.contains { $0.title == "Second" })
    }

    @Test func summaryCarriesClassificationPendingWorkAndRealOrEstimatedDuration() throws {
        let sceneText = "Synthetic line for the duration estimate."
        let scene = boardScene(
            order: 0,
            title: "Intro",
            text: sceneText,
            estimatedDuration: 90,
            bRollItems: [
                FrameScriptDocument.BRollItem(descriptionText: "Lapel", status: .idea),
                FrameScriptDocument.BRollItem(descriptionText: "Done shot", status: .done)
            ],
            editingItems: [
                FrameScriptDocument.EditingItem(cutStyle: "Hard cut", status: .pending)
            ],
            takes: [
                boardTake(duration: 75, rating: .good, sceneTextHash: FrameScriptDocument.TextHash.hash(sceneText))
            ]
        )
        let checklist = FrameScriptDocument.ChecklistTask(text: "Check tyre pressures", kind: .research)
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        let publish = Date(timeIntervalSince1970: 1_800_500_000)
        let document = boardDocument(
            title: "Synthetic review",
            topic: "Vantare",
            videoType: "review de mod/coche",
            status: .script,
            targetDate: target,
            publishDate: publish,
            checklistTasks: [checklist],
            scenes: [scene]
        )

        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("review.fscr")
        try writeBoardDocument(document, to: url)

        let result = BoardLibraryScanner().scan(BoardScanRequest(folderURLs: [root]))
        let summary = try #require(result.index.summaries.first)

        #expect(summary.topic == "Vantare")
        #expect(summary.videoType == "review de mod/coche")
        #expect(summary.productionStatus == .script)
        #expect(summary.targetDate == target)
        #expect(summary.publishDate == publish)
        #expect(summary.pending.count(for: .conseguirBroll) == 1)
        #expect(summary.pending.count(for: .editar) == 1)
        #expect(summary.pending.count(for: .investigar) == 1)
        #expect(summary.pending.count(for: .grabar) == 0)
        #expect(summary.duration.kind == .real)
        #expect(summary.duration.seconds == 75)
        #expect(summary.duration.estimatedSeconds == 90)
        #expect(summary.fingerprint.contentHash.count == 64)
    }

    @Test func scanIsReadOnlyAndPreservesTheFileBytes() throws {
        let root = try makeBoardTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("read-only.fscr")
        try writeBoardDocument(boardDocument(title: "Untouched"), to: url)
        let before = try Data(contentsOf: url)

        _ = BoardLibraryScanner().scan(BoardScanRequest(folderURLs: [root]))

        #expect(try Data(contentsOf: url) == before)
    }
}
