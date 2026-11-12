import Foundation
@testable import FrameScript
import XCTest

final class SandboxDataMigrationTests: XCTestCase {
    func testMigratesFrameScriptKeysWithoutOverwritingExistingValues() throws {
        let defaults = makeDefaults()
        let plistURL = try makeContainerPlist([
            "FrameScript.settings.v1": Data("old-settings".utf8),
            "FrameScript.recentProjects.v1": Data("old-recents".utf8),
            "FrameScript.ai.provider.OpenAI-compatible": ["model": "gpt-4.1-mini"],
            "UnrelatedKey": "ignore"
        ])
        defaults.set(Data("new-recents".utf8), forKey: "FrameScript.recentProjects.v1")

        let result = SandboxDataMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: plistURL
        )

        XCTAssertTrue(result.didMigrate)
        XCTAssertTrue(result.copiedSettings)
        XCTAssertEqual(result.copiedKeyCount, 2)
        XCTAssertEqual(defaults.data(forKey: "FrameScript.settings.v1"), Data("old-settings".utf8))
        XCTAssertEqual(defaults.data(forKey: "FrameScript.recentProjects.v1"), Data("new-recents".utf8))
        XCTAssertEqual(
            defaults.dictionary(forKey: "FrameScript.ai.provider.OpenAI-compatible")?["model"] as? String,
            "gpt-4.1-mini"
        )
        XCTAssertNil(defaults.object(forKey: "UnrelatedKey"))
        XCTAssertTrue(defaults.bool(forKey: SandboxDataMigration.markerKey))

        let second = SandboxDataMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: plistURL
        )
        XCTAssertTrue(second.skippedAlreadyMigrated)
        XCTAssertFalse(second.didMigrate)
    }

    func testMissingContainerMarksMigrated() {
        let defaults = makeDefaults()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).plist")

        let result = SandboxDataMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: missing
        )

        XCTAssertTrue(result.skippedMissingContainer)
        XCTAssertFalse(result.didMigrate)
        XCTAssertTrue(defaults.bool(forKey: SandboxDataMigration.markerKey))
    }

    func testUnreadableContainerDoesNotMarkMigrated() throws {
        let defaults = makeDefaults()
        let plistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-\(UUID().uuidString).plist")
        try Data("not a plist".utf8).write(to: plistURL)
        defer { try? FileManager.default.removeItem(at: plistURL) }

        let result = SandboxDataMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: plistURL
        )

        XCTAssertFalse(result.didMigrate)
        XCTAssertFalse(defaults.bool(forKey: SandboxDataMigration.markerKey))
    }

    func testAlreadyMigratedSkipsWithoutReadingContainer() throws {
        let defaults = makeDefaults()
        defaults.set(true, forKey: SandboxDataMigration.markerKey)
        let plistURL = try makeContainerPlist(["FrameScript.settings.v1": Data("old".utf8)])

        let result = SandboxDataMigration.migrateIfNeeded(
            defaults: defaults,
            containerPlistURL: plistURL
        )

        XCTAssertTrue(result.skippedAlreadyMigrated)
        XCTAssertFalse(result.didMigrate)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "SandboxDataMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeContainerPlist(_ values: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("container-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        try data.write(to: url)
        return url
    }
}
