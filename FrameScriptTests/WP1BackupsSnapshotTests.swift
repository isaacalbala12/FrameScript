import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// WP1 visual coverage: the backups sheet must still be reachable for a file
/// that could not be opened, and its warning banner must use localized text.
@MainActor
final class WP1BackupsSnapshotTests: FrameScriptTestCase {
    func testBackupsSheetForAFailedOpenSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptWP1Snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("Proyecto roto.fscr")
        let projectUUID = UUID()
        let broken: [String: Any] = [
            "fileVersion": 4,
            "project": [
                "id": projectUUID.uuidString,
                "title": "Proyecto roto",
                "createdAt": "2024-01-01T10:00:00Z",
                "updatedAt": "2024-01-01T10:00:00Z",
                "scenes": "not-an-array"
            ]
        ]
        try JSONSerialization.data(withJSONObject: broken).write(to: fileURL)

        let appState = makeSnapshotAppState()
        appState.openProject(at: fileURL)
        XCTAssertEqual(appState.failedOpenProjectFileURL, fileURL)

        let projectID = try XCTUnwrap(appState.currentBackupProjectID)
        let backupData = try FrameScriptFileStore.encode(
            project: FrameProject(
                id: projectUUID,
                title: "Proyecto roto",
                scenes: [Scene(order: 0, sectionType: .hook, title: "Escena", scriptText: "texto")]
            )
        )
        let entry = BackupsCenter.store.backUpData(
            backupData,
            originalFileName: fileURL.lastPathComponent,
            originalPath: fileURL.path,
            projectID: projectID
        )
        guard case .created = entry else {
            return XCTFail("The snapshot needs a backup entry")
        }
        BackupHealth.shared.record(
            BackupFailure(operation: .writeMetadata, path: fileURL.path, reason: "permiso denegado"),
            projectID: projectID
        )
        defer { BackupHealth.shared.clear(projectID: projectID) }

        for appearance in SnapshotAppearance.allCases {
            let name = "backups-failed-open-760x520-\(appearance.rawValue)"
            let result = SnapshotRenderer.render(
                BackupsWindowView(),
                name: name,
                suite: "WP1BackupsSnapshotTests",
                size: CGSize(width: 760, height: 520),
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            XCTAssertGreaterThan(result.pixelSize.width, 0, "\(name) produced no pixels")
            XCTAssertTrue(
                result.textFragments.contains { $0.contains("Proyecto roto") || $0.contains("copias") || $0.contains("escritura") },
                "\(name) did not render the failed-open backups content: \(result.textFragments)"
            )
        }
    }

    private func makeSnapshotAppState() -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        let store = ProjectStore(project: SampleData.defaultProject)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings"),
            aiProviderConfigurationStore: AIProviderConfigurationStore(userDefaults: defaults)
        )
    }
}
