import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Offscreen rendering for the production panel. The window is never ordered
/// front, so running the app tests cannot steal focus or bring FrameScript to
/// the foreground.
@MainActor
final class ProductionPanelSnapshotTests: ProductionTestCase {
    private static let snapshotDirectory = URL(fileURLWithPath: "/tmp/fs-snapshots/w3-e-checklist")

    func testProductionPanelRendersAtSupportedSizesInLightAndDark() throws {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        appState.settings.generalPreferences.language = .spanish
        appState.refreshProductionChecklist()

        XCTAssertEqual(appState.currentLanguage, .spanish)
        XCTAssertGreaterThan(ProductionChecklistCenter.shared.snapshot.summary.totalPending, 0)

        let sizes: [(String, CGSize)] = [
            ("1180x760", CGSize(width: 1180, height: 760)),
            ("980x712", CGSize(width: 980, height: 712))
        ]
        for (sizeName, size) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let schemeName = scheme == .light ? "light" : "dark"
                try renderAndAssert(
                    appState: appState,
                    size: size,
                    scheme: scheme,
                    name: "production-panel-\(sizeName)-\(schemeName)"
                )
            }
        }

        // The other grouping mode has different section headers and row
        // details (scene names move into each row).
        for scheme in [ColorScheme.light, .dark] {
            let schemeName = scheme == .light ? "light" : "dark"
            try renderAndAssert(
                appState: appState,
                size: CGSize(width: 980, height: 712),
                scheme: scheme,
                name: "production-panel-kind-980x712-\(schemeName)",
                grouping: .kind
            )
        }
    }

    func testProductionTaskEditorRendersAtSupportedSizesInLightAndDark() throws {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        appState.settings.generalPreferences.language = .spanish
        let task = try XCTUnwrap(appState.project.checklistTasks.first)

        XCTAssertEqual(L10n.tr("production.task.edit", language: .spanish), "Editar tarea")
        XCTAssertEqual(L10n.tr("production.task.save", language: .spanish), "Guardar")

        let sizes: [(String, CGSize)] = [
            ("1180x760", CGSize(width: 1180, height: 760)),
            ("980x712", CGSize(width: 980, height: 712))
        ]
        for (sizeName, size) in sizes {
            for scheme in [ColorScheme.light, .dark] {
                let schemeName = scheme == .light ? "light" : "dark"
                let theme = FrameTheme(colorScheme: scheme, accent: .sage)
                let root = ZStack {
                    theme.background
                    ProductionTaskEditorView(task: task)
                        .environment(appState)
                        .environment(\.frameTheme, theme)
                }
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)

                let rendered = try renderOffscreen(root, size: size, scheme: scheme)
                XCTAssertGreaterThan(distinctSampledColors(in: rendered.representation), 2)
                XCTAssertLessThanOrEqual(440, size.width)

                let elements = rendered.accessibility
                if !elements.isEmpty {
                    let labels = elements.map(\.label)
                    XCTAssertTrue(labels.contains { $0.contains("Editar tarea") }, "labels: \(labels)")
                    XCTAssertTrue(labels.contains { $0.contains("Guardar") }, "labels: \(labels)")
                }

                if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
                    try writePNG(
                        rendered.representation,
                        name: "production-task-editor-\(sizeName)-\(schemeName)"
                    )
                }
            }
        }
    }

    func testProductionSidebarAndToolbarAffordancesRenderAtMinimumSize() throws {
        let appState = makeAppState(project: makeSpanishFixtureProject())
        appState.settings.generalPreferences.language = .spanish
        appState.refreshProductionChecklist()
        let pending = appState.productionSnapshot.summary.totalPending
        XCTAssertGreaterThan(pending, 0)

        for scheme in [ColorScheme.light, .dark] {
            let schemeName = scheme == .light ? "light" : "dark"
            let theme = FrameTheme(colorScheme: scheme, accent: .sage)
            let root = HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ProductionSidebarEntry()
                        .padding(10)
                    Spacer()
                }
                .frame(width: 240)
                .background(theme.sidebarBackground)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(appState.project.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        ProductionToolbarButton()
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .background(theme.background)
                    Spacer()
                }
            }
            .frame(width: 980, height: 712)
            .environment(appState)
            .environment(\.frameTheme, theme)
            .environment(\.colorScheme, scheme)

            let rendered = try renderOffscreen(
                root,
                size: CGSize(width: 980, height: 712),
                scheme: scheme
            )
            XCTAssertGreaterThan(distinctSampledColors(in: rendered.representation), 2)

            XCTAssertEqual(
                String(
                    format: L10n.tr("production.badge.accessibility", language: .spanish),
                    pending
                ),
                "\(pending) tareas pendientes"
            )

            if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
                try writePNG(
                    rendered.representation,
                    name: "production-affordances-980x712-\(schemeName)"
                )
            }
        }
    }

    private func renderAndAssert(
        appState: AppState,
        size: CGSize,
        scheme: ColorScheme,
        name: String,
        grouping: ProductionGrouping = .scene
    ) throws {
        let theme = FrameTheme(colorScheme: scheme, accent: .sage)
        let root = ZStack {
            theme.background
            ProductionPanelView(initialGrouping: grouping)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, scheme)

        let rendered = try renderOffscreen(root, size: size, scheme: scheme)
        let representation = rendered.representation

        XCTAssertGreaterThan(representation.pixelsWide, 0)
        XCTAssertGreaterThan(representation.pixelsHigh, 0)
        XCTAssertGreaterThan(representation.pixelsWide, representation.pixelsHigh / 3)
        XCTAssertGreaterThan(representation.pixelsHigh, representation.pixelsWide / 3)

        // The panel is a fixed-size sheet: it must fit the minimum window and
        // leave a real list viewport between the fixed header/filter/footer.
        XCTAssertLessThanOrEqual(ProductionPanelMetrics.width, size.width)
        XCTAssertLessThanOrEqual(ProductionPanelMetrics.height, size.height)
        XCTAssertGreaterThan(ProductionPanelMetrics.listHeight, 200)
        XCTAssertEqual(
            ProductionPanelMetrics.headerHeight
                + ProductionPanelMetrics.filterHeight
                + ProductionPanelMetrics.footerHeight
                + ProductionPanelMetrics.listHeight
                + 3,
            ProductionPanelMetrics.height,
            accuracy: 0.001
        )

        // A blank render has only the background color. Several distinct
        // sampled colors prove the panel content actually painted.
        XCTAssertGreaterThan(distinctSampledColors(in: representation), 2)

        // The fixed header, list and footer must each paint content inside the
        // centered panel, so nothing is clipped off-canvas or overlapped away.
        let panelRect = NSRect(
            x: (size.width - ProductionPanelMetrics.width) / 2,
            y: (size.height - ProductionPanelMetrics.height) / 2,
            width: ProductionPanelMetrics.width,
            height: ProductionPanelMetrics.height
        )
        XCTAssertTrue(NSRect(origin: .zero, size: size).contains(panelRect))
        let scaleX = CGFloat(representation.pixelsWide) / size.width
        let scaleY = CGFloat(representation.pixelsHigh) / size.height
        let headerRect = NSRect(
            x: panelRect.minX,
            y: panelRect.minY,
            width: panelRect.width,
            height: ProductionPanelMetrics.headerHeight
        )
        let footerRect = NSRect(
            x: panelRect.minX,
            y: panelRect.maxY - ProductionPanelMetrics.footerHeight,
            width: panelRect.width,
            height: ProductionPanelMetrics.footerHeight
        )
        let listRect = NSRect(
            x: panelRect.minX,
            y: panelRect.minY + ProductionPanelMetrics.headerHeight,
            width: panelRect.width,
            height: ProductionPanelMetrics.listHeight
        )
        XCTAssertGreaterThan(distinctSampledColors(in: representation, rect: headerRect, scaleX: scaleX, scaleY: scaleY), 1)
        XCTAssertGreaterThan(distinctSampledColors(in: representation, rect: listRect, scaleX: scaleX, scaleY: scaleY), 2)
        XCTAssertGreaterThan(distinctSampledColors(in: representation, rect: footerRect, scaleX: scaleX, scaleY: scaleY), 1)

        // Visible text must be Spanish, not the English fallback.
        XCTAssertEqual(L10n.tr("production.title", language: .spanish), "Producción")
        XCTAssertEqual(L10n.tr("production.filter.allScenes", language: .spanish), "Todas las escenas")
        XCTAssertEqual(L10n.tr("production.reason.sceneNeedsTake", language: .spanish), "falta grabar")
        XCTAssertEqual(L10n.tr("production.reason.bRollNeedsFootage", language: .spanish), "falta grabar")
        XCTAssertTrue(
            appState.productionSnapshot.items.contains {
                L10n.tr("production.reason.\($0.reason.rawValue)", language: .spanish) == "falta grabar"
            }
        )

        // SwiftUI exposes its text through accessibility. When the tree is
        // available, assert the key Spanish labels are on-canvas and the
        // header/footer do not overlap.
        let elements = rendered.accessibility
        if !elements.isEmpty {
            let canvas = NSRect(origin: .zero, size: size)
            let labels = elements.map(\.label)
            XCTAssertTrue(labels.contains { $0.contains("Producción") }, "labels: \(labels)")
            XCTAssertTrue(labels.contains { $0.contains("falta grabar") }, "labels: \(labels)")

            for element in elements where !element.label.isEmpty {
                XCTAssertTrue(
                    canvas.insetBy(dx: -1, dy: -1).contains(element.frame),
                    "\(element.label) is off-canvas at \(element.frame)"
                )
            }

            if let header = elements.first(where: { $0.label.contains("Producción") }),
               let footer = elements.first(where: { $0.label.contains("Nueva tarea") || $0.label.contains("New task") }) {
                XCTAssertFalse(header.frame.intersects(footer.frame))
            }
        }

        if ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1" {
            try writePNG(representation, name: name)
        }
    }

    /// Renders a SwiftUI view into a never-ordered borderless window. The
    /// window is only a layout host; it is never made key or ordered front.
    private func renderOffscreen<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme
    ) throws -> (representation: NSBitmapImageRep, accessibility: [AccessibilityElement]) {
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.setContentSize(size)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Let SwiftUI run onAppear/layout without ever ordering the window.
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()

        let bounds = hostingView.bounds
        XCTAssertEqual(bounds.width, size.width, accuracy: 0.5)
        XCTAssertEqual(bounds.height, size.height, accuracy: 0.5)
        XCTAssertTrue(hostingView.subviews.allSatisfy { bounds.contains($0.frame) })

        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: bounds)
        )
        hostingView.cacheDisplay(in: bounds, to: representation)
        XCTAssertGreaterThan(representation.pixelsWide, 0)
        XCTAssertGreaterThan(representation.pixelsHigh, 0)

        let elements = accessibilityElements(in: hostingView)
        // Drop the SwiftUI tree so the test's UserDefaults suite can be
        // released before tear-down removes its cfprefsd domain.
        window.contentView = nil
        window.close()
        _ = scheme
        return (representation, elements)
    }

    private func distinctSampledColors(in representation: NSBitmapImageRep) -> Int {
        distinctSampledColors(
            in: representation,
            rect: NSRect(x: 0, y: 0, width: representation.pixelsWide, height: representation.pixelsHigh),
            scaleX: 1,
            scaleY: 1
        )
    }

    private func distinctSampledColors(
        in representation: NSBitmapImageRep,
        rect: NSRect,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> Int {
        var colors = Set<String>()
        let minX = max(0, Int(rect.minX * scaleX))
        let maxX = min(representation.pixelsWide, Int(rect.maxX * scaleX))
        let minY = max(0, Int(rect.minY * scaleY))
        let maxY = min(representation.pixelsHigh, Int(rect.maxY * scaleY))
        guard maxX > minX, maxY > minY else { return 0 }
        let stepX = max(1, (maxX - minX) / 40)
        let stepY = max(1, (maxY - minY) / 20)
        for x in stride(from: minX, to: maxX, by: stepX) {
            for y in stride(from: minY, to: maxY, by: stepY) {
                if let color = representation.colorAt(x: x, y: y) {
                    colors.insert(color.description)
                }
            }
        }
        return colors.count
    }

    private struct AccessibilityElement {
        let label: String
        let frame: NSRect
    }

    private func accessibilityElements(in view: NSView) -> [AccessibilityElement] {
        var elements: [AccessibilityElement] = []
        collectAccessibilityElements(from: view, into: &elements)
        return elements
    }

    private func collectAccessibilityElements(
        from element: Any,
        into result: inout [AccessibilityElement]
    ) {
        guard let object = element as? NSAccessibilityElement else { return }
        let label = object.accessibilityLabel() ?? ""
        if !label.isEmpty {
            result.append(AccessibilityElement(label: label, frame: object.accessibilityFrame()))
        }
        for child in object.accessibilityChildren() ?? [] {
            collectAccessibilityElements(from: child, into: &result)
        }
    }

    private func writePNG(_ representation: NSBitmapImageRep, name: String) throws {
        try FileManager.default.createDirectory(
            at: Self.snapshotDirectory,
            withIntermediateDirectories: true
        )
        let url = Self.snapshotDirectory.appendingPathComponent("\(name).png")
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: url, options: .atomic)
        print("SNAPSHOT \(url.path)")
    }
}
