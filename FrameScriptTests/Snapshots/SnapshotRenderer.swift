import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// The two window sizes every main-screen snapshot must cover.
enum SnapshotSize: String, CaseIterable {
    case standard
    case minimum

    var size: CGSize {
        switch self {
        case .standard: CGSize(width: 1180, height: 760)
        case .minimum: CGSize(width: 980, height: 712)
        }
    }

    var label: String {
        "\(Int(size.width))x\(Int(size.height))"
    }
}

enum SnapshotAppearance: String, CaseIterable {
    case light
    case dark

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearanceName: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

/// Offscreen renderer for SwiftUI views and AppKit views.
///
/// The `NSWindow` is created but never ordered front, so the user's focus and
/// window stack are untouched. PNGs are only written when `FS_SNAPSHOTS=1`;
/// without it the same render still runs and its layout/text invariants are
/// asserted.
@MainActor
enum SnapshotRenderer {
    static let outputRoot = URL(fileURLWithPath: "/tmp/fs-snapshots", isDirectory: true)

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["FS_SNAPSHOTS"] == "1"
    }

    struct Result {
        var name: String
        var pngURL: URL?
        var pixelSize: CGSize
        var textFragments: [String]
        var distinctColorCount: Int
    }

    @discardableResult
    static func render<Content: View>(
        _ content: Content,
        name: String,
        suite: String,
        size: CGSize,
        appearance: SnapshotAppearance,
        language: AppLanguage,
        appState: AppState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result {
        if appState.settings.generalPreferences.language != language {
            appState.settings.generalPreferences.language = language
        }
        let theme = FrameTheme(
            colorScheme: appearance.colorScheme,
            accent: appState.settings.accentColor
        )

        let root = content
            .environment(appState)
            .environment(EscaletaImportCoordinator())
            .environment(\.frameTheme, theme)
            .preferredColorScheme(appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let canvas = SnapshotCanvasView(frame: NSRect(origin: .zero, size: size))
        canvas.backgroundColor = NSColor(theme.appBackground)
        canvas.addSubview(hosting)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance.nsAppearanceName)
        window.contentView = canvas
        window.setFrame(NSRect(origin: .zero, size: size), display: false)

        layout(window: window, canvas: canvas, hosting: hosting)

        let fittingSize = hosting.fittingSize
        XCTAssertGreaterThan(fittingSize.width, 0, "\(name): view has no width", file: file, line: line)
        XCTAssertGreaterThan(fittingSize.height, 0, "\(name): view has no height", file: file, line: line)
        XCTAssertEqual(canvas.bounds.width, size.width, accuracy: 0.5, "\(name): width changed", file: file, line: line)
        XCTAssertEqual(canvas.bounds.height, size.height, accuracy: 0.5, "\(name): height changed", file: file, line: line)

        let offCanvas = offCanvasFrames(in: canvas, rootView: canvas, insideScrollView: false)
        XCTAssertTrue(
            offCanvas.isEmpty,
            "\(name): views render outside the canvas: \(offCanvas.joined(separator: ", "))",
            file: file,
            line: line
        )

        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("\(name): could not create a bitmap for the snapshot", file: file, line: line)
            return Result(
                name: name,
                pngURL: nil,
                pixelSize: .zero,
                textFragments: [],
                distinctColorCount: 0
            )
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)

        let text = textFragments(appKitRoot: canvas, hosting: hosting)
        XCTAssertFalse(
            text.isEmpty,
            "\(name): no text was found in the rendered view hierarchy",
            file: file,
            line: line
        )

        let colors = distinctColorCount(in: bitmap)
        XCTAssertGreaterThan(
            colors,
            1,
            "\(name): the rendered bitmap is a single flat color",
            file: file,
            line: line
        )

        var pngURL: URL?
        if isEnabled {
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let directory = outputRoot.appendingPathComponent(suite, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    let url = directory.appendingPathComponent("\(name).png")
                    try data.write(to: url, options: .atomic)
                    pngURL = url
                    print("[snapshot] \(url.path)")
                } catch {
                    XCTFail("\(name): could not write the PNG: \(error)", file: file, line: line)
                }
            } else {
                XCTFail("\(name): PNG encoding failed", file: file, line: line)
            }
        }

        // Release AppKit objects without ever ordering the window front.
        window.contentView = nil
        hosting.removeFromSuperview()

        return Result(
            name: name,
            pngURL: pngURL,
            pixelSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
            textFragments: text,
            distinctColorCount: colors
        )
    }

    /// Renders a plain AppKit view with the same canvas/window rules.
    @discardableResult
    static func render<View: NSView>(
        _ view: View,
        name: String,
        suite: String,
        size: CGSize,
        appearance: SnapshotAppearance,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result {
        let canvas = SnapshotCanvasView(frame: NSRect(origin: .zero, size: size))
        canvas.backgroundColor = .windowBackgroundColor
        view.frame = NSRect(origin: .zero, size: size)
        canvas.addSubview(view)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: appearance.nsAppearanceName)
        window.contentView = canvas
        window.setFrame(NSRect(origin: .zero, size: size), display: false)

        layout(window: window, canvas: canvas, hosting: view)

        XCTAssertGreaterThan(view.frame.width, 0, "\(name): view has no width", file: file, line: line)
        XCTAssertGreaterThan(view.frame.height, 0, "\(name): view has no height", file: file, line: line)
        let offCanvas = offCanvasFrames(in: canvas, rootView: canvas, insideScrollView: false)
        XCTAssertTrue(offCanvas.isEmpty, "\(name): views render outside the canvas: \(offCanvas)", file: file, line: line)

        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("\(name): could not create a bitmap for the snapshot", file: file, line: line)
            return Result(name: name, pngURL: nil, pixelSize: .zero, textFragments: [], distinctColorCount: 0)
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)

        let text = textFragments(appKitRoot: canvas, hosting: nil)
        XCTAssertFalse(text.isEmpty, "\(name): no text was found in the rendered view hierarchy", file: file, line: line)
        let colors = distinctColorCount(in: bitmap)
        XCTAssertGreaterThan(colors, 1, "\(name): the rendered bitmap is a single flat color", file: file, line: line)

        var pngURL: URL?
        if isEnabled, let data = bitmap.representation(using: .png, properties: [:]) {
            let directory = outputRoot.appendingPathComponent(suite, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("\(name).png")
                try data.write(to: url, options: .atomic)
                pngURL = url
                print("[snapshot] \(url.path)")
            } catch {
                XCTFail("\(name): could not write the PNG: \(error)", file: file, line: line)
            }
        }

        window.contentView = nil
        view.removeFromSuperview()
        return Result(
            name: name,
            pngURL: pngURL,
            pixelSize: CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh),
            textFragments: text,
            distinctColorCount: colors
        )
    }

    private static func layout(window: NSWindow, canvas: NSView, hosting: NSView) {
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI's first layout/observation pass settle without showing
        // the window. A short run-loop turn is enough for static screens.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()
    }

    private static func offCanvasFrames(
        in view: NSView,
        rootView: NSView,
        insideScrollView: Bool
    ) -> [String] {
        var result: [String] = []
        for subview in view.subviews where !subview.isHidden && subview.frame.width > 0 && subview.frame.height > 0 {
            let isScrollView = subview is NSScrollView
            let ignoreGeometry = insideScrollView || isScrollView
            if !ignoreGeometry {
                // Frames are relative to their parent; convert to the canvas so
                // an embedded AppKit control's focus-ring overhang is not
                // mistaken for content outside the window.
                let frame = view.convert(subview.bounds, to: rootView)
                if frame.minX < -1 || frame.minY < -1
                    || frame.maxX > rootView.bounds.width + 1
                    || frame.maxY > rootView.bounds.height + 1 {
                    result.append("\(type(of: subview)) \(frame)")
                }
            }
            result.append(contentsOf: offCanvasFrames(
                in: subview,
                rootView: rootView,
                insideScrollView: ignoreGeometry
            ))
        }
        return result
    }

    private static func textFragments(appKitRoot: NSView, hosting: NSView?) -> [String] {
        var fragments: [String] = []
        collectAppKitText(appKitRoot, into: &fragments)
        if let hosting {
            fragments.append(contentsOf: swiftUIDisplayListText(from: hosting))
        }
        return Array(Set(fragments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
    }

    /// SwiftUI's display list is the rendered view hierarchy: every `Text`
    /// that actually laid out appears as `(text "…")`. Reflection keeps this
    /// readable without linking against private SwiftUI symbols.
    private static func swiftUIDisplayListText(from hosting: NSView) -> [String] {
        var displayListDescriptions: [String] = []

        func scan(_ value: Any, depth: Int) {
            guard depth < 10 else { return }
            let description = String(describing: value)
            if description.contains("(text \"") || description.contains("(display-list") {
                displayListDescriptions.append(description)
                return
            }
            for child in Mirror(reflecting: value).children {
                scan(child.value, depth: depth + 1)
            }
        }

        for child in Mirror(reflecting: hosting).children where child.label == "renderer" {
            scan(child.value, depth: 0)
        }

        guard let regex = try? NSRegularExpression(pattern: #"\(text "((?:[^"\\]|\\.)*)""#) else {
            return []
        }
        var fragments: [String] = []
        for description in displayListDescriptions {
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            for match in regex.matches(in: description, range: range) {
                guard let matchRange = Range(match.range(at: 1), in: description) else { continue }
                let raw = String(description[matchRange])
                let value = raw
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
                if value.rangeOfCharacter(from: .letters) != nil {
                    fragments.append(value)
                }
            }
        }
        return fragments
    }

    private static func collectAppKitText(_ view: NSView, into fragments: inout [String]) {
        if let textField = view as? NSTextField {
            fragments.append(textField.stringValue)
            fragments.append(textField.placeholderString ?? "")
        }
        if let textView = view as? NSTextView {
            fragments.append(textView.string)
        }
        if let button = view as? NSButton, !button.title.isEmpty {
            fragments.append(button.title)
        }
        for subview in view.subviews {
            collectAppKitText(subview, into: &fragments)
        }
    }

    private static func distinctColorCount(in bitmap: NSBitmapImageRep) -> Int {
        guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return 0 }
        let stepX = max(1, bitmap.pixelsWide / 48)
        let stepY = max(1, bitmap.pixelsHigh / 48)
        var colors: Set<String> = []
        var y = 0
        while y < bitmap.pixelsHigh {
            var x = 0
            while x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y) {
                    let rgb = color.usingColorSpace(.deviceRGB)
                    let red = Int((rgb?.redComponent ?? 0) * 255)
                    let green = Int((rgb?.greenComponent ?? 0) * 255)
                    let blue = Int((rgb?.blueComponent ?? 0) * 255)
                    let alpha = Int((rgb?.alphaComponent ?? 0) * 255)
                    colors.insert("\(red),\(green),\(blue),\(alpha)")
                }
                x += stepX
            }
            y += stepY
        }
        return colors.count
    }
}

private final class SnapshotCanvasView: NSView {
    var backgroundColor: NSColor = .windowBackgroundColor

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}
