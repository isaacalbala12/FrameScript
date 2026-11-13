import XCTest

@MainActor
final class ModeSwitcherHitAreaUITests: XCTestCase {
    private let expectedButtonWidth: CGFloat = 112
    private let expectedSwitcherWidth: CGFloat = 346
    private let expectedButtonHeight: CGFloat = 28
    private let expectedSwitcherHeight: CGFloat = 34
    private let tolerance: CGFloat = 0.5

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnglishHitAreasAndMetrics() throws {
        try verifyHitAreasAndMetrics(
            languageArgument: "--framescript-ui-test-language-english",
            expectedVisualsTitle: "Visuals"
        )
    }

    func testRussianHitAreasAndMetrics() throws {
        try verifyHitAreasAndMetrics(
            languageArgument: "--framescript-ui-test-language-russian",
            expectedVisualsTitle: "Видеоряд"
        )
    }

    func testSpanishHitAreasAndMetrics() throws {
        try verifyHitAreasAndMetrics(
            languageArgument: "--framescript-ui-test-language-spanish",
            expectedVisualsTitle: "Visuales"
        )
    }

    private func verifyHitAreasAndMetrics(languageArgument: String, expectedVisualsTitle: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--framescript-ui-test-open-demo", languageArgument]
        app.launch()

        let identifiers = ["mode-switcher-script", "mode-switcher-broll", "mode-switcher-editing"]
        let controls = identifiers.map { modeControl($0, in: app) }
        XCTAssertTrue(controls[0].waitForExistence(timeout: 5))
        XCTAssertEqual(controls[1].label, expectedVisualsTitle)
        controls.forEach { control in
            XCTAssertEqual(control.frame.width, expectedButtonWidth, accuracy: tolerance)
            XCTAssertEqual(control.frame.height, expectedButtonHeight, accuracy: tolerance)
        }

        let switcher = app.descendants(matching: .any)["mode-switcher"]
        XCTAssertTrue(switcher.exists)
        XCTAssertEqual(switcher.frame.width, expectedSwitcherWidth, accuracy: tolerance)
        XCTAssertEqual(switcher.frame.height, expectedSwitcherHeight, accuracy: tolerance)

        let insidePoints = [
            CGVector(dx: 0.05, dy: 0.5),  // empty left area
            CGVector(dx: 0.35, dy: 0.5),  // label text
            CGVector(dx: 0.72, dy: 0.5),  // shortcut keycap
            CGVector(dx: 0.95, dy: 0.5),  // empty right area
            CGVector(dx: 0.5, dy: 0.05),  // top edge
            CGVector(dx: 0.5, dy: 0.95),  // bottom edge
        ]

        for (index, identifier) in identifiers.enumerated() {
            let alternate = identifiers[(index + 1) % identifiers.count]
            for point in insidePoints {
                modeControl(alternate, in: app).click()
                controls[index].coordinate(withNormalizedOffset: point).click()
                assertSelected(identifier, in: app)
            }

            modeControl(alternate, in: app).click()
            controls[index]
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.15))
                .click()
            assertSelected(alternate, in: app)
        }
    }

    private func modeControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func assertSelected(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = modeControl(identifier, in: app)
        let predicate = NSPredicate(format: "selected == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed, element.debugDescription, file: file, line: line)
    }
}
