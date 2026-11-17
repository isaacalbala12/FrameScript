import AppKit
import Foundation
import FrameScriptCore
import Observation
import SwiftUI
import XCTest
@testable import FrameScript

/// Regression and budget tests for the wave-3 performance review.
///
/// Budgets are main-thread CPU time (`CLOCK_THREAD_CPUTIME_ID`) measured in the
/// Debug test host, with roughly 4× headroom over the measured value so a
/// loaded CI machine does not flake. The observation tests are exact.
@MainActor
final class PerfBudgetTests: FrameScriptTestCase {
    // MARK: - Action bar layout rule

    func testActionBarFitRuleMatchesViewThatFits() {
        let widths: [UXActionBarLabelMode: CGFloat] = [
            .all: 900, .allButProject: 760, .insertAndProduction: 600, .insertOnly: 480, .none: 380
        ]
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 1000, idealWidths: widths), .all)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 900, idealWidths: widths), .all)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 899.5, idealWidths: widths), .allButProject)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 600, idealWidths: widths), .insertAndProduction)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 500, idealWidths: widths), .insertOnly)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 400, idealWidths: widths), .none)
        // Nothing fits: the last layout, exactly like `ViewThatFits`.
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 100, idealWidths: widths), .none)
        // Not measured yet: the widest layout, like an unconstrained `ViewThatFits`.
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: 400, idealWidths: [:]), .all)
        XCTAssertEqual(UXActionBarFit.labelMode(availableWidth: nil, idealWidths: widths), .all)
        XCTAssertEqual(UXActionBarLabelMode.fittingOrder.filter(\.usesCompactMetrics), [.insertAndProduction, .insertOnly])
    }

    /// A resize must show the right layout in the very layout pass that
    /// changes the width (no stale frame), and match the settled result.
    func testActionBarPicksItsLayoutInTheSameLayoutPassAsAResize() throws {
        let appState = PerfAppStateFactory.make(project: PerfFixture.makeProject(.typical), defaults: makeDefaults())
        let sceneID = try XCTUnwrap(appState.project.scenes.first?.id)
        // Badge counts change the bar widths; settle them before measuring.
        ProductionChecklistCenter.shared.refreshNow(project: appState.project)
        defer { ProductionChecklistCenter.shared.clear() }
        let theme = FrameTheme(colorScheme: .light, accent: appState.settings.accentColor)
        let hosting = NSHostingView(rootView: UXEditorActionBar(sceneID: sceneID)
            .environment(appState)
            .environment(\.frameTheme, theme)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        func settle() {
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                hosting.layoutSubtreeIfNeeded()
            }
        }
        func bitmap() -> Data? {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            return rep.tiffRepresentation
        }
        settle()
        for width in [1100.0, 700, 520, 420, 900] {
            window.setContentSize(NSSize(width: width, height: 60))
            hosting.layoutSubtreeIfNeeded()
            let firstPass = bitmap()
            settle()
            let settled = bitmap()
            XCTAssertNotNil(firstPass)
            XCTAssertEqual(firstPass, settled, "width \(width): the first layout pass showed a different bar")
            if firstPass != settled, ProcessInfo.processInfo.environment["FS_PERF_DEBUG"] == "1" {
                try? firstPass?.write(to: URL(fileURLWithPath: "/tmp/fs-perf/resize-\(Int(width))-first.tiff"))
                try? settled?.write(to: URL(fileURLWithPath: "/tmp/fs-perf/resize-\(Int(width))-settled.tiff"))
            }
        }
    }

    // MARK: - Observation: per-keystroke invalidation

    /// Typing in one scene must not invalidate views that read another scene's
    /// cached text hash (sidebar rows, duration controls).
    func testTypingDoesNotInvalidateTextHashReadersOfOtherScenes() throws {
        let project = PerfFixture.makeProject(.typical)
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        let scenes = project.scenes.sortedByOrder
        let edited = scenes[0]
        let other = scenes[1]
        _ = store.textHash(for: other)
        let invalidated = PerfObservationFlag()
        withObservationTracking {
            _ = store.textHash(for: other)
        } onChange: {
            invalidated.fire()
        }
        store.commitScriptText(edited.scriptText + " uno", sceneID: edited.id)
        XCTAssertFalse(invalidated.fired, "a keystroke in scene 1 invalidated scene 2's hash readers")

        let editedInvalidated = PerfObservationFlag()
        withObservationTracking {
            _ = store.textHash(for: edited)
        } onChange: {
            editedInvalidated.fire()
        }
        let before = store.textHash(for: edited)
        store.commitScriptText(edited.scriptText + " dos", sceneID: edited.id)
        XCTAssertTrue(editedInvalidated.fired, "the edited scene's readers must still refresh")
        XCTAssertNotEqual(store.textHash(for: edited), before)
        XCTAssertEqual(store.textHash(for: edited), FrameScriptDocument.TextHash.hash(edited.scriptText))
    }

    /// Invalidating a scene that has no cached analysis must not notify the
    /// sidebar badges, the editor underlines or the duration controls.
    func testRhythmInvalidationOfAnUnanalysedSceneDoesNotNotifyWarningReaders() {
        let center = RhythmReviewCenter()
        let sceneID = UUID()
        let invalidated = PerfObservationFlag()
        withObservationTracking {
            _ = center.warningCount(for: sceneID)
            _ = center.warnings(for: sceneID)
            _ = center.totalWarningCount
        } onChange: {
            invalidated.fire()
        }
        center.invalidate(sceneID: sceneID)
        center.invalidate(sceneID: sceneID)
        XCTAssertFalse(invalidated.fired)
        XCTAssertTrue(center.isPending)
    }

    // MARK: - Main window budgets

    func testSingleSceneKeystrokeStaysWithinBudget() throws {
        let appState = PerfAppStateFactory.make(project: PerfFixture.makeProject(.typical), defaults: makeDefaults())
        let host = PerfMainWindowHost(appState: appState, inspectorState: UXInspectorState(defaults: makeDefaults(), key: "perf.inspector"))
        defer { host.close() }
        host.flush()
        host.pump(0.5)
        let textView = try XCTUnwrap(host.singleSceneTextView)
        host.window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length / 2, length: 0))
        host.flush()
        var samples: [PerfSample] = []
        for index in 0..<24 {
            samples.append(host.measure {
                textView.insertText(index % 6 == 5 ? " " : "a", replacementRange: textView.selectedRange())
            })
        }
        // Before the review: ~137 ms median. After: ~12–17 ms.
        XCTAssertLessThan(samples.median(\.cpuMilliseconds), 60, "median keystroke CPU \(samples.median(\.cpuMilliseconds)) ms")
    }

    func testFullScriptKeystrokeAndHeaderRefreshStayWithinBudget() throws {
        let appState = PerfAppStateFactory.make(project: PerfFixture.makeProject(.large), defaults: makeDefaults())
        let host = PerfMainWindowHost(appState: appState, inspectorState: UXInspectorState(defaults: makeDefaults(), key: "perf.inspector"))
        defer { host.close() }
        appState.selectFullScript()
        host.flush()
        host.pump(0.6)
        let textView = try XCTUnwrap(host.fullScriptTextView)
        host.window.makeFirstResponder(textView)
        let document = textView.string as NSString
        let caret = document.range(of: " ", range: NSRange(location: document.length / 2, length: document.length / 2)).location
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        host.flush()
        var samples: [PerfSample] = []
        for index in 0..<16 {
            samples.append(host.measure {
                textView.insertText(index % 6 == 5 ? " " : "a", replacementRange: textView.selectedRange())
            })
        }
        // Before: ~96 ms median on 30 × 700 words. After: ~15 ms.
        XCTAssertLessThan(samples.median(\.cpuMilliseconds), 70, "median keystroke CPU \(samples.median(\.cpuMilliseconds)) ms")

        // The debounced duration refresh rewrites scene headers only.
        let settle = host.measureSettle(1.2)
        // Before: ~330 ms (full document rebuild + restyle). After: ~100 ms.
        XCTAssertLessThan(settle, 450, "settle CPU \(settle) ms")
    }

    func testSceneSwitchAndInspectorTabsStayWithinBudget() throws {
        let appState = PerfAppStateFactory.make(project: PerfFixture.makeProject(.typical), defaults: makeDefaults())
        let inspector = UXInspectorState(defaults: makeDefaults(), key: "perf.inspector")
        let host = PerfMainWindowHost(appState: appState, inspectorState: inspector)
        defer { host.close() }
        host.flush()
        host.pump(0.5)
        let scenes = appState.project.scenes.sortedByOrder
        var switches: [PerfSample] = []
        for index in 0..<8 {
            switches.append(host.measure { appState.selectScene(scenes[(index * 2 + 1) % scenes.count].id) })
        }
        // Before: ~147 ms median. After: ~30–55 ms.
        XCTAssertLessThan(switches.median(\.cpuMilliseconds), 150, "scene switch CPU \(switches.median(\.cpuMilliseconds)) ms")

        var tabs: [PerfSample] = []
        for tab in [UXInspectorTab.scene, .research, .production, .rhythm] {
            tabs.append(host.measure { inspector.select(tab) })
            host.pump(0.1)
        }
        // Before: ~240–380 ms each. After: ~20–60 ms.
        XCTAssertLessThan(tabs.median(\.cpuMilliseconds), 200, "inspector tab CPU \(tabs.median(\.cpuMilliseconds)) ms")
    }
}

/// Thread-safe flag for `withObservationTracking` change handlers.
final class PerfObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
