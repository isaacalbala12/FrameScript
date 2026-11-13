import Foundation
import FrameScriptCore
@testable import FrameScript
import XCTest

final class BackupRootIsolationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestBundleCleanup.register()
    }

    @MainActor
    func testAppBackupsUseATemporaryRootDuringTests() {
        let root = BackupsCenter.rootDirectory
        XCTAssertTrue(root.path.contains("FrameScriptAppTestBackups"), "Expected a test-only backup root, got \(root.path)")
        XCTAssertFalse(
            root.path.contains("/Library/Application Support/FrameScript"),
            "App tests must never use the real Application Support backup folder"
        )
    }

    /// The old test only proved that a path string contains the test prefix.
    /// This one creates a backup through the app-facing store and restores it,
    /// so a hard-coded real Application Support folder can no longer pass.
    @MainActor
    func testBackupIsWrittenUnderTheTemporaryRootAndRestoresTheProject() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRootIsolationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = FrameProject(
            title: "Isolated backup",
            scenes: [Scene(order: 0, sectionType: .hook, title: "Hook", scriptText: "Original text")]
        )
        let fileURL = directory.appendingPathComponent("Backup.fscr")
        try FrameScriptFileStore.write(project: project, to: fileURL)

        let projectID = BackupsCenter.projectID(for: project, fileURL: fileURL)
        let outcome = BackupsCenter.store.backUpIfNeeded(
            fileURL: fileURL,
            projectID: projectID,
            force: true
        )
        let entry: BackupEntry
        switch outcome {
        case .created(let created, _):
            entry = created
        case .skipped, .failed:
            XCTFail("Expected the app backup store to create a backup, got \(outcome)")
            return
        }

        let root = BackupsCenter.rootDirectory.standardizedFileURL.path
        XCTAssertTrue(
            entry.url.standardizedFileURL.path.hasPrefix(root),
            "Backup landed outside the test root: \(entry.url.path)"
        )
        XCTAssertFalse(
            entry.url.path.contains("/Library/Application Support/FrameScript"),
            "Backup reached the real Application Support folder: \(entry.url.path)"
        )

        let restored = try FrameScriptFileStore.read(from: entry.url)
        XCTAssertEqual(restored.title, project.title)
        XCTAssertEqual(restored.scenes.first?.scriptText, "Original text")

        try BackupsCenter.store.restore(data: Data(contentsOf: entry.url), over: fileURL, projectID: projectID) { data in
            _ = try FrameScriptFileStore.decoder.decode(FrameScriptFile.self, from: data).makeProject()
        }
        let reloaded = try FrameScriptFileStore.read(from: fileURL)
        XCTAssertEqual(reloaded.scenes.first?.scriptText, "Original text")

        // Keep the per-run root tidy for this test; the bundle-level atexit
        // cleanup removes the whole process root.
        try? FileManager.default.removeItem(
            at: BackupsCenter.store.projectDirectory(forProjectID: projectID)
        )
    }
}
