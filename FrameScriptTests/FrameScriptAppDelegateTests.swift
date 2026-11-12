import AppKit
import Foundation
@testable import FrameScript
import XCTest

@MainActor
final class FrameScriptAppDelegateTests: XCTestCase {
    func testOpeningAProjectWhileRunningUsesTheExistingOpenFlow() throws {
        let url = try projectFileURL(title: "From Finder")
        let appState = makeAppState()
        let delegate = FrameScriptAppDelegate()
        delegate.attach(appState)

        delegate.application(NSApplication.shared, open: [url])

        XCTAssertTrue(appState.hasOpenProject)
        XCTAssertEqual(appState.project.title, "From Finder")
        XCTAssertEqual(appState.projectStore.currentFileURL, url)
    }

    func testOpeningABeforeAppStateAttachesIsQueuedAndThenOpened() throws {
        let url = try projectFileURL(title: "Cold Launch")
        let appState = makeAppState()
        let delegate = FrameScriptAppDelegate()

        delegate.application(NSApplication.shared, open: [url])

        XCTAssertFalse(appState.hasOpenProject)

        delegate.attach(appState)

        XCTAssertTrue(appState.hasOpenProject)
        XCTAssertEqual(appState.project.title, "Cold Launch")
    }

    func testLegacyFramescriptExtensionIsAccepted() throws {
        let url = try projectFileURL(title: "Legacy", pathExtension: "framescript")
        let appState = makeAppState()
        let delegate = FrameScriptAppDelegate()
        delegate.attach(appState)

        delegate.application(NSApplication.shared, open: [url])

        XCTAssertEqual(appState.project.title, "Legacy")
    }

    func testOpeningAProjectWithUnsavedChangesUsesTheCloseConfirmation() throws {
        let firstURL = try projectFileURL(title: "First")
        let secondURL = try projectFileURL(title: "Second")
        var confirmations = 0
        let appState = makeAppState(autosaveEnabled: false, closeConfirmation: {
            confirmations += 1
            return .discard
        })
        let delegate = FrameScriptAppDelegate()
        delegate.attach(appState)
        appState.openProject(at: firstURL)
        appState.touchProject()
        XCTAssertTrue(appState.projectStore.needsCloseConfirmation)

        delegate.application(NSApplication.shared, open: [secondURL])

        XCTAssertEqual(confirmations, 1)
        XCTAssertEqual(appState.project.title, "Second")
        XCTAssertEqual(appState.projectStore.currentFileURL, secondURL)
    }

    func testNonProjectFilesAreIgnored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptAppDelegateTests-\(UUID().uuidString).txt")
        try Data("not a project".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let appState = makeAppState()
        let delegate = FrameScriptAppDelegate()

        delegate.application(NSApplication.shared, open: [url])
        delegate.attach(appState)

        XCTAssertFalse(appState.hasOpenProject)
    }

    func testTerminationFlushesUnsavedChangesBeforeQuitting() throws {
        let url = try projectFileURL(title: "Before Quit")
        let appState = makeAppState()
        let delegate = FrameScriptAppDelegate()
        delegate.attach(appState)
        appState.openProject(at: url)
        let scene = try XCTUnwrap(appState.project.scenes.first)
        appState.commitScriptTextChange(sceneID: scene.id, text: "saved on quit")

        let reply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(try FrameScriptFileStore.read(from: url).scenes.first?.scriptText, "saved on quit")
        XCTAssertFalse(appState.projectStore.hasUnsavedFileChanges)
    }

    private func makeAppState(
        autosaveEnabled: Bool = true,
        closeConfirmation: AppState.CloseConfirmation? = nil
    ) -> AppState {
        let suite = UserDefaults(suiteName: "FrameScriptAppDelegateTests-\(UUID().uuidString)")!
        var settings = AppSettings.defaults
        settings.generalPreferences.autosaveEnabled = autosaveEnabled
        return AppState(
            recentProjectStore: RecentProjectStore(userDefaults: suite),
            settingsStore: SettingsStore(settings: settings, userDefaults: suite, key: "settings"),
            closeConfirmation: closeConfirmation
        )
    }

    private func projectFileURL(title: String, pathExtension: String = "fscr") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptAppDelegateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("Project.\(pathExtension)")
        let project = FrameProject(
            title: title,
            scenes: [Scene(order: 0, sectionType: .hook, title: "Scene", scriptText: "Text for \(title)")]
        )
        try FrameScriptFileStore.write(project: project, to: url)
        return url
    }
}
