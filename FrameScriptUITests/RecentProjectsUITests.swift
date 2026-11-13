import XCTest

@MainActor
final class RecentProjectsUITests: XCTestCase {
    nonisolated(unsafe) private var projectDirectory: URL!
    nonisolated(unsafe) private var projectURL: URL!
    nonisolated(unsafe) private var projectName: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        projectName = "RecentUITest-\(UUID().uuidString.prefix(8))"
        // The UI test must never write into the real app container. The app
        // reads this path from --framescript-ui-test-recent-path.
        projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptRecentProjectsUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        projectURL = projectDirectory.appendingPathComponent("\(projectName!).fscr")
        try Data("FrameScript UI test".utf8).write(to: projectURL)
    }

    override func tearDownWithError() throws {
        if let projectDirectory { try? FileManager.default.removeItem(at: projectDirectory) }
    }

    func testContextMenuRemovalUpdatesWelcomeAndOpenRecentWithoutDeletingFile() throws {
        let app = launchApp()
        let row = recentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        assertOpenRecentContainsProject(in: app)

        row.rightClick()
        app.menus.firstMatch.menuItems["Remove from Recents"].click()

        XCTAssertFalse(row.waitForExistence(timeout: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        assertOpenRecentDoesNotContainProject(in: app)
    }

    func testHoverRemovalDoesNotShiftLayoutOrDeleteFile() throws {
        let app = launchApp()
        let row = recentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let frameBeforeHover = row.frame

        row.hover()
        let remove = app.descendants(matching: .any)["recent-remove-\(projectName!)"]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        XCTAssertEqual(row.frame, frameBeforeHover)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()

        XCTAssertFalse(row.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
    }

    func testDeleteKeyRemovesFocusedRecentOnly() throws {
        try verifyKeyboardRemoval(key: .delete)
    }

    func testForwardDeleteKeyRemovesFocusedRecentOnly() throws {
        try verifyKeyboardRemoval(key: .forwardDelete)
    }

    private func verifyKeyboardRemoval(key: XCUIKeyboardKey) throws {
        let app = launchApp()
        let row = recentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        focus(row, in: app)
        row.typeKey(key, modifierFlags: [])

        XCTAssertFalse(row.waitForExistence(timeout: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
    }

    private func focus(_ row: XCUIElement, in app: XCUIApplication) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<8 where !focused.evaluate(with: row) {
            app.typeKey(.tab, modifierFlags: [])
        }
        XCTAssertTrue(focused.evaluate(with: row), row.debugDescription)
    }

    func testExternalDeletionIsRemovedWhenTheBrowserReturnsWithoutGenericOpenError() throws {
        let app = launchApp()
        let row = recentRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        try FileManager.default.removeItem(at: projectURL)

        // Re-enter the project browser the way a user would. The browser runs
        // its recents validation on appear, so no activation of Finder or the
        // app is needed (which would foreground other apps on this Mac).
        app.buttons["welcome-new-blank-project"].click()
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Back to Project List"].click()

        XCTAssertFalse(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Could not open project."].exists)
        assertOpenRecentDoesNotContainProject(in: app)
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--framescript-ui-test-show-browser",
            "--framescript-ui-test-recent-path", projectURL.path,
            "--framescript-ui-test-language-english",
        ]
        app.launch()
        return app
    }

    private func recentRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons[projectName]
    }

    private func assertOpenRecentContainsProject(in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Recent"].hover()
        XCTAssertTrue(app.menuItems[projectName].waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])
    }

    private func assertOpenRecentDoesNotContainProject(in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Recent"].hover()
        XCTAssertFalse(app.menuItems[projectName].exists)
        app.typeKey(.escape, modifierFlags: [])
    }
}
