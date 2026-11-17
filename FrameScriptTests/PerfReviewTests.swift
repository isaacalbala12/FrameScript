import AppKit
import Foundation
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Wave-3 performance review harness.
///
/// `testPerfReport` hosts the real `AppShellView` offscreen (the window is
/// never ordered front) with a synthetic project at two sizes and prints a
/// table of main-thread costs. It only runs with `FS_PERF_REPORT=1`
/// (`TEST_RUNNER_FS_PERF_REPORT=1 xcodebuild test …`). The budget tests in
/// `PerfBudgetTests` always run and keep wide headroom for loaded CI hosts.
@MainActor
final class PerfReviewTests: FrameScriptTestCase {
    private var report: [String] = []

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameScriptPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func line(_ size: PerfFixtureSize, _ name: String, _ samples: [PerfSample]) {
        let text = String(
            format: "PERF | %@ | %@ | median wall %.2f ms | median cpu %.2f ms | p90 cpu %.2f ms | n=%d",
            size.label, name,
            samples.median(\.wallMilliseconds),
            samples.median(\.cpuMilliseconds),
            samples.percentile(0.9, \.cpuMilliseconds),
            samples.count
        )
        report.append(text)
        print(text)
    }

    private func line(_ size: PerfFixtureSize, _ name: String, value: Double, unit: String = "ms cpu") {
        let text = String(format: "PERF | %@ | %@ | %.2f %@", size.label, name, value, unit)
        report.append(text)
        print(text)
    }

    func testPerfReport() throws {
        guard ProcessInfo.processInfo.environment["FS_PERF_REPORT"] == "1" else {
            throw XCTSkip("Set FS_PERF_REPORT=1 to print the performance report.")
        }
        if ProcessInfo.processInfo.environment["FS_PERF_PRINT_CHANGES"] == "1" {
            try FileManager.default.createDirectory(atPath: "/tmp/fs-perf", withIntermediateDirectories: true)
            freopen("/tmp/fs-perf/print-changes.txt", "w", stdout)
        }
        for size in PerfFixtureSize.allCases {
            try runReport(size)
        }
        let output = URL(fileURLWithPath: "/tmp/fs-perf", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let name = ProcessInfo.processInfo.environment["FS_PERF_REPORT_NAME"] ?? "report"
        try report.joined(separator: "\n").write(
            to: output.appendingPathComponent("\(name).txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Profiling aid: repeats one operation for `FS_PERF_LOOP_SECONDS` so
    /// `sample <pid>` or Instruments can attach to the test host.
    /// `FS_PERF_LOOP` is one of `keystroke`, `fullscript`, `sceneswitch`,
    /// `inspector`, `mode`.
    func testPerfProfileLoop() throws {
        guard let loop = ProcessInfo.processInfo.environment["FS_PERF_LOOP"] else {
            throw XCTSkip("Set FS_PERF_LOOP to profile one operation.")
        }
        let seconds = Double(ProcessInfo.processInfo.environment["FS_PERF_LOOP_SECONDS"] ?? "20") ?? 20
        let size: PerfFixtureSize = ProcessInfo.processInfo.environment["FS_PERF_LOOP_SIZE"] == "large" ? .large : .typical
        let appState = PerfAppStateFactory.make(project: PerfFixture.makeProject(size), defaults: makeDefaults())
        let inspector = UXInspectorState(defaults: makeDefaults(), key: "perf.inspector")
        let host = PerfMainWindowHost(appState: appState, inspectorState: inspector)
        defer { host.close() }
        host.flush()
        host.pump(1)
        let scenes = appState.project.scenes.sortedByOrder
        if loop.hasPrefix("fullscript") {
            appState.selectFullScript()
            host.flush()
            host.pump(0.8)
        }
        let textView: NSTextView? = loop.hasPrefix("fullscript") ? host.fullScriptTextView : host.singleSceneTextView
        if let textView {
            host.window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length / 2, length: 0))
        }
        let deadline = Date().addingTimeInterval(seconds)
        var index = 0
        while Date() < deadline {
            switch loop {
            case "keystroke", "fullscript":
                textView?.insertText(index % 6 == 5 ? " " : "a", replacementRange: textView?.selectedRange() ?? NSRange())
            case "keystrokesettle", "fullscriptsettle":
                // One short word, then the pause in which debounced work runs.
                for character in ["a", "b", " "] {
                    textView?.insertText(character, replacementRange: textView?.selectedRange() ?? NSRange())
                    host.flush()
                }
                host.pump(0.7)
            case "sceneswitch":
                appState.selectScene(scenes[index % scenes.count].id)
            case "inspector":
                inspector.select(UXInspectorTab.allCases[index % UXInspectorTab.allCases.count])
            case "mode":
                appState.selectMode(index % 2 == 0 ? .bRoll : .script)
            default:
                break
            }
            host.flush()
            index += 1
        }
    }

    private func runReport(_ size: PerfFixtureSize) throws {
        let directory = try temporaryDirectory()
        let project = PerfFixture.makeProject(size)
        let url = directory.appendingPathComponent("Perf-\(size.rawValue).framescript")
        try FrameScriptFileStore.write(project: project, to: url)

        // Start from a small open project so "open" replaces a live window.
        let appState = PerfAppStateFactory.make(
            project: PerfFixture.makeProject(.typical),
            defaults: makeDefaults(),
            autosaveEnabled: true
        )
        let inspector = UXInspectorState(defaults: makeDefaults(), key: "perf.inspector")
        inspector.select(.ai)
        let host = PerfMainWindowHost(appState: appState, inspectorState: inspector)
        defer { host.close() }
        let firstRender = host.measure {}
        line(size, "first window render (welcome→shell, small project)", [firstRender])
        host.pump(0.8)

        // Open project.
        let open = host.measure {
            XCTAssertEqual(appState.openProject(at: url), .opened)
        }
        line(size, "open project (read+decode+first render)", [open])
        line(size, "open settle (1.2 s idle after open)", value: host.measureSettle(1.2))

        // Keystrokes in the single-scene editor.
        let scenes = appState.project.scenes.sortedByOrder
        appState.selectScene(scenes[min(4, scenes.count - 1)].id)
        host.flush()
        host.pump(0.8)
        guard let textView = host.singleSceneTextView else {
            XCTFail("single-scene text view not found")
            return
        }
        host.window.makeFirstResponder(textView)
        let middle = (textView.string as NSString).length / 2
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        host.flush()
        var keys: [PerfSample] = []
        for index in 0..<40 {
            if index == 39 { Self.marker("BEGIN single-scene keystroke \(size.label)") }
            keys.append(host.measure {
                textView.insertText(index % 6 == 5 ? " " : "a", replacementRange: textView.selectedRange())
            })
            if index == 39 { Self.marker("END single-scene keystroke") }
        }
        line(size, "keystroke single-scene (insert+update)", keys)
        Self.marker("BEGIN single-scene settle \(size.label)")
        line(size, "single-scene settle after 40 keys (1.5 s)", value: host.measureSettle(1.5))
        Self.marker("END single-scene settle")

        // Scene switching.
        var switches: [PerfSample] = []
        for index in 0..<12 {
            let target = scenes[(index * 3 + 1) % scenes.count].id
            if index == 11 { Self.marker("BEGIN scene switch \(size.label)") }
            switches.append(host.measure { appState.selectScene(target) })
            if index == 11 { Self.marker("END scene switch") }
        }
        line(size, "scene switch", switches)
        host.pump(0.8)

        // Mode switching.
        for mode in WorkspaceMode.allCases where mode != .script {
            let toMode = host.measure { appState.selectMode(mode) }
            host.pump(0.3)
            let back = host.measure { appState.selectMode(.script) }
            host.pump(0.3)
            line(size, "mode switch script→\(mode.rawValue) / back", [toMode, back])
        }

        // Inspector tabs.
        for tab in UXInspectorTab.allCases {
            let open = host.measure { inspector.select(tab) }
            host.pump(0.2)
            line(size, "inspector tab \(tab.rawValue)", [open])
        }
        inspector.select(.ai)
        host.pump(0.3)

        // Autosave (main-thread part of a background save + synchronous save).
        textView.insertText("b", replacementRange: textView.selectedRange())
        host.flush()
        let backgroundSave = host.measure { appState.performAutosave() }
        host.pump(0.4)
        line(size, "autosave background (main-thread part)", [backgroundSave])
        textView.insertText("c", replacementRange: textView.selectedRange())
        host.flush()
        let syncSave = host.measure { appState.performAutosave(synchronous: true) }
        line(size, "autosave synchronous", [syncSave])

        // Guion completo.
        let enterFull = host.measure { appState.selectFullScript() }
        line(size, "enter Guion completo", [enterFull])
        host.pump(0.8)
        guard let fullView = host.fullScriptTextView else {
            XCTFail("full-script text view not found")
            return
        }
        host.window.makeFirstResponder(fullView)
        // Caret in the middle of the body of the middle scene.
        let full = fullView.string as NSString
        let caret = full.length / 2
        let paragraph = full.range(of: " ", options: [], range: NSRange(location: caret, length: full.length - caret))
        fullView.setSelectedRange(NSRange(location: paragraph.location, length: 0))
        host.flush()
        var fullKeys: [PerfSample] = []
        for index in 0..<40 {
            if index == 39 { Self.marker("BEGIN full-script keystroke \(size.label)") }
            fullKeys.append(host.measure {
                fullView.insertText(index % 6 == 5 ? " " : "a", replacementRange: fullView.selectedRange())
            })
            if index == 39 { Self.marker("END full-script keystroke") }
        }
        line(size, "keystroke Guion completo (insert+update)", fullKeys)
        Self.marker("BEGIN full-script settle \(size.label)")
        line(size, "Guion completo settle after 40 keys (1.5 s)", value: host.measureSettle(1.5))
        Self.marker("END full-script settle")
        let leaveFull = host.measure { appState.selectScene(scenes[0].id) }
        line(size, "leave Guion completo", [leaveFull])
        host.pump(0.5)

        // Panels, each in its own offscreen host.
        let panels: [(String, AnyView)] = [
            ("production panel", AnyView(ProductionPanelView())),
            ("research panel", AnyView(ResearchPanelView())),
            ("publishing panel", AnyView(PublishingPanel())),
            ("assets sheet", AnyView(AssetsSheetView())),
            ("resolve pack sheet", AnyView(ResolvePackSheet(languageCode: "es")))
        ]
        for (name, view) in panels {
            let sample = measureFirstRender(view, appState: appState)
            line(size, "panel \(name) first render", [sample])
        }
        _ = appState.closeProject()
    }

    private static func marker(_ text: String) {
        print("=== \(text)")
        fflush(stdout)
    }

    private func measureFirstRender(_ view: AnyView, appState: AppState) -> PerfSample {
        let size = CGSize(width: 900, height: 700)
        let theme = FrameTheme(colorScheme: .light, accent: appState.settings.accentColor)
        let wall0 = PerfClock.wallNanoseconds()
        let cpu0 = PerfClock.threadCPUNanoseconds()
        let hosting = NSHostingView(rootView: view
            .environment(appState)
            .environment(EscaletaImportCoordinator())
            .environment(\.frameTheme, theme)
            .frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        RunLoop.current.run(until: Date())
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let cpu1 = PerfClock.threadCPUNanoseconds()
        let wall1 = PerfClock.wallNanoseconds()
        window.contentView = nil
        window.close()
        return PerfSample(
            wallMilliseconds: Double(wall1 - wall0) / 1_000_000,
            cpuMilliseconds: Double(cpu1 - cpu0) / 1_000_000
        )
    }
}
