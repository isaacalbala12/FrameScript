import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// Regression tests for the Nov 2026 design review: one selected inspector
/// tab, and one shared leading edge per column (sidebar, editor, inspector).
@MainActor
final class DesignAlignmentTests: FrameScriptTestCase {
    // MARK: - Inspector tabs

    func testEveryTabAppearsOnceInTheTabBar() {
        let flattened = UXInspectorTabLayout.rows.flatMap { $0 }
        XCTAssertEqual(flattened.sorted { $0.rawValue < $1.rawValue }, UXInspectorTab.allCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(Set(flattened).count, flattened.count, "a tab is listed twice")
    }

    func testExactlyOneInspectorTabIsSelected() {
        let state = UXInspectorState(defaults: makeDefaults(), key: "design.alignment.tabs")
        for tab in UXInspectorTab.allCases {
            state.select(tab)
            XCTAssertEqual(UXInspectorTabLayout.selectedTabs(in: state), [tab])
        }
        // Selecting a second-row tab and coming back must not leave two.
        state.select(.research)
        state.select(.ai)
        XCTAssertEqual(UXInspectorTabLayout.selectedTabs(in: state), [.ai])
    }

    func testInspectorTabRowsShareOneWidth() {
        let sink = renderShell(size: CGSize(width: 1512, height: 949))
        let rows = sink.frames("inspector.tabRow")
        XCTAssertEqual(rows.count, UXInspectorTabLayout.rows.count)
        assertShared(rows.map(\.minX), "tab rows' leading edge")
        assertShared(rows.map(\.maxX), "tab rows' trailing edge")
    }

    // MARK: - Column edges

    func testSidebarRowsShareLeadingAndTitleEdges() {
        let sink = renderShell(size: CGSize(width: 1512, height: 949))
        let leading = sink.frames("sidebar.leading")
        let titles = sink.frames("sidebar.title")
        // Production + full script + 9 scenes + 3 actions.
        XCTAssertGreaterThanOrEqual(leading.count, 14, "missing sidebar rows: \(leading.count)")
        // Production + full script + 9 scenes.
        XCTAssertGreaterThanOrEqual(titles.count, 11, "missing sidebar titles: \(titles.count)")
        assertShared(leading.map(\.minX), "sidebar first-glyph edge")
        assertShared(titles.map(\.minX), "sidebar title edge")
        if let first = leading.first {
            XCTAssertEqual(first.minX, FrameLayout.sidebarContentLeading, accuracy: 0.5)
        }
        if let first = titles.first {
            XCTAssertEqual(first.minX, FrameLayout.sidebarTitleLeading, accuracy: 0.5)
        }
    }

    func testEditorColumnSharesOneLeadingEdge() {
        for size in [CGSize(width: 1512, height: 949), CGSize(width: 980, height: 712)] {
            let sink = renderShell(size: size)
            let column = sink.frames("editor.column")
            // Title, action bar, script text, notes disclosure.
            XCTAssertEqual(column.count, 4, "\(size): editor column elements: \(column)")
            assertShared(column.map(\.minX), "editor column edge at \(size)")
        }
    }

    func testInspectorHeaderTabsAndContentShareOneLeadingEdge() {
        let sink = renderShell(size: CGSize(width: 1512, height: 949))
        let edges = sink.frames("inspector.leading")
        // Header title, tab bar, AI empty-state card.
        XCTAssertEqual(edges.count, 3, "inspector elements: \(edges)")
        assertShared(edges.map(\.minX), "inspector edge")
    }

    func testWelcomeActionIconsShareOneSlot() {
        let sink = LayoutProbeSink()
        let (appState, _) = DesignReviewSnapshotTests.makeAppState(project: nil, defaults: makeDefaults())
        SnapshotRenderer.render(
            WelcomeView().environment(\.layoutProbeSink, sink),
            name: "design-alignment-welcome",
            suite: "DesignAlignmentTests",
            size: CGSize(width: 1180, height: 760),
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        let icons = sink.frames("welcome.actionIcon")
        XCTAssertEqual(icons.count, 5, "welcome actions: \(icons)")
        assertShared(icons.map(\.minX), "welcome icon edge")
        assertShared(icons.map(\.maxX), "welcome title edge")
    }

    // MARK: - Helpers

    private func renderShell(size: CGSize) -> LayoutProbeSink {
        let sink = LayoutProbeSink()
        let project = DesignReviewSnapshotTests.reviewProject(emptyFirstScene: true)
        let (appState, inspector) = DesignReviewSnapshotTests.makeAppState(project: project, defaults: makeDefaults())
        inspector.select(.ai)
        SnapshotRenderer.render(
            AppShellView(inspectorState: inspector).environment(\.layoutProbeSink, sink),
            name: "design-alignment-\(Int(size.width))",
            suite: "DesignAlignmentTests",
            size: size,
            appearance: .dark,
            language: .spanish,
            appState: appState
        )
        return sink
    }

    private func assertShared(
        _ values: [CGFloat],
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let first = values.first else {
            XCTFail("\(what): nothing measured", file: file, line: line)
            return
        }
        for value in values {
            XCTAssertEqual(value, first, accuracy: 0.5, "\(what) differs: \(values.sorted())", file: file, line: line)
        }
    }
}
