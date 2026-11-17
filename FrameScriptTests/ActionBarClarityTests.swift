import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// The action bar got real side padding, a gap between buttons and clear
/// space around the group separators. The performance fit rule is unchanged;
/// these tests pin the numbers and the stage picked at the real window sizes.
@MainActor
final class ActionBarClarityTests: FrameScriptTestCase {
    func testBarMetricsGiveComfortableSidePadding() {
        let regular = UXActionBarMetrics.regular
        XCTAssertGreaterThanOrEqual(regular.horizontalInset, 10)
        XCTAssertLessThanOrEqual(regular.horizontalInset, 12)
        XCTAssertGreaterThanOrEqual(regular.verticalInset, 4)
        XCTAssertGreaterThan(regular.buttonGap, 0, "buttons must not be glued together")
        XCTAssertGreaterThanOrEqual(regular.dividerInset, FrameSpacing.s, "separators need clear space on both sides")
        XCTAssertEqual(regular.barHeight, FrameControlHeight.compact + 2 * regular.verticalInset)
    }

    func testCompactTiersTightenGapsButKeepTheOuterInsets() {
        let regular = UXActionBarMetrics.regular
        let compact = UXActionBarMetrics.compact
        XCTAssertEqual(compact.horizontalInset, regular.horizontalInset)
        XCTAssertEqual(compact.verticalInset, regular.verticalInset)
        XCTAssertLessThan(compact.labelPadding, regular.labelPadding)
        XCTAssertLessThan(compact.dividerInset, regular.dividerInset)
        XCTAssertGreaterThanOrEqual(compact.dividerInset, FrameSpacing.xxs)
        XCTAssertEqual(UXActionBarMetrics.metrics(compact: false), regular)
        XCTAssertEqual(UXActionBarMetrics.metrics(compact: true), compact)
        for mode in UXActionBarLabelMode.allCases {
            XCTAssertEqual(
                UXActionBarMetrics.metrics(compact: mode.usesCompactMetrics),
                mode.usesCompactMetrics ? compact : regular
            )
        }
    }

    func testCollapseOrderIsProyectoThenIAThenProduccion() {
        let order = UXActionBarLabelMode.fittingOrder
        XCTAssertEqual(order, [.all, .allButProject, .insertAndProduction, .insertOnly, .none])
        XCTAssertFalse(UXActionBarLabelMode.allButProject.showsLabel(for: .project))
        XCTAssertTrue(UXActionBarLabelMode.allButProject.showsLabel(for: .ai))
        XCTAssertFalse(UXActionBarLabelMode.insertAndProduction.showsLabel(for: .ai))
        XCTAssertTrue(UXActionBarLabelMode.insertAndProduction.showsLabel(for: .production))
        XCTAssertFalse(UXActionBarLabelMode.insertOnly.showsLabel(for: .production))
        XCTAssertTrue(UXActionBarLabelMode.insertOnly.showsLabel(for: .insert))
    }

    /// Renders the real shell and returns the bar's width and the measured
    /// ideal widths, so the stage is the one the user sees.
    private func measure(width: CGFloat, height: CGFloat) -> (barWidth: CGFloat, ideal: [UXActionBarLabelMode: CGFloat], mode: UXActionBarLabelMode) {
        let sink = LayoutProbeSink()
        let project = DesignReviewSnapshotTests.reviewProject()
        let (appState, inspector) = DesignReviewSnapshotTests.makeAppState(project: project, defaults: makeDefaults())
        inspector.select(.ai)
        SnapshotRenderer.render(
            AppShellView(inspectorState: inspector).environment(\.layoutProbeSink, sink),
            name: "actionbar-stage-\(Int(width))",
            suite: "ActionBarClarityTests",
            size: CGSize(width: width, height: height),
            appearance: .light,
            language: .spanish,
            appState: appState
        )
        let bars = sink.frames("actionbar.bar")
        let barWidth = bars.map(\.width).max() ?? 0
        let ideal = UXActionBarFit.lastIdealWidths
        let mode = UXActionBarFit.labelMode(availableWidth: barWidth, idealWidths: ideal)
        return (barWidth, ideal, mode)
    }

    func testStagesAtTheRealWindowSizes() {
        // Same stages as before the padding change: the wider metrics must
        // not cost Insertar its labels at 1180 pt, and the user's 1512 pt
        // window keeps Insertar + Producción labeled.
        let cases: [(CGFloat, CGFloat, UXActionBarLabelMode)] = [
            (1512, 949, .insertAndProduction),
            (1180, 760, .insertOnly),
            (980, 712, .insertOnly)
        ]
        for (width, height, expected) in cases {
            let result = measure(width: width, height: height)
            let widths = UXActionBarLabelMode.fittingOrder.map { result.ideal[$0] ?? -1 }
            XCTAssertEqual(result.mode, expected, "\(Int(width)): bar \(result.barWidth), ideal widths \(widths)")
            XCTAssertEqual(widths, widths.sorted(by: >), "layouts must get narrower in collapse order")
            if expected == .insertOnly {
                XCTAssertGreaterThanOrEqual(
                    result.barWidth - (result.ideal[.insertOnly] ?? .infinity),
                    4,
                    "\(Int(width)): Insertar keeps its labels with room to spare"
                )
            }
        }
    }

    /// A bar of 760 pt still shows Insertar and Producción labeled and
    /// collapses IA and Proyecto to icons (existing UX snapshot expectation).
    func testInsertAndProductionStageFitsIn760() {
        _ = measure(width: 1512, height: 949)
        let ideal = UXActionBarFit.lastIdealWidths
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 760, idealWidths: ideal), .insertAndProduction)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 1400, idealWidths: ideal), .all)
    }
}
