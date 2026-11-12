import XCTest
@testable import FrameScript

final class BackupRootIsolationTests: XCTestCase {
    @MainActor
    func testAppBackupsUseATemporaryRootDuringTests() {
        let root = BackupsCenter.rootDirectory
        XCTAssertTrue(root.path.contains("FrameScriptAppTestBackups"), "Expected a test-only backup root, got \(root.path)")
        XCTAssertFalse(
            root.path.contains("/Library/Application Support/FrameScript"),
            "App tests must never use the real Application Support backup folder"
        )
    }
}
