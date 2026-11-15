import AppKit
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

/// FU3 visual regressions (V5, V6, V7): the escaleta import sheet's primary
/// button, its clipped footer and the duration popover's buttons.
///
/// Set `TEST_RUNNER_FS_SNAPSHOTS=1` to write the PNGs to
/// `/tmp/fs-snapshots/FU3SnapshotTests`.
@MainActor
final class FU3SnapshotTests: FrameScriptTestCase {
    // MARK: - V5: the primary action is filled with the accent

    func testEscaletaImportPrimaryButtonUsesTheProminentAccentFill() throws {
        let request = makeEscaletaRequest()
        for appearance in SnapshotAppearance.allCases {
            // The neutral previous design renders identically for every accent:
            // the footer had no accent anywhere. A filled accentStrong primary
            // button changes thousands of footer pixels when the accent changes.
            let sage = try XCTUnwrap(renderOffscreen(
                EscaletaImportPreviewSheet(request: request),
                size: SnapshotSize.standard.size,
                appearance: appearance,
                appState: makeSnapshotAppState(accent: .sage)
            ), "\(appearance.rawValue): could not render the import sheet")
            addTeardownBlock { sage.release() }
            let rose = try XCTUnwrap(renderOffscreen(
                EscaletaImportPreviewSheet(request: request),
                size: SnapshotSize.standard.size,
                appearance: appearance,
                appState: makeSnapshotAppState(accent: .rose)
            ), "\(appearance.rawValue): could not render the import sheet")
            addTeardownBlock { rose.release() }

            // Footer band of the 720×700 sheet, in bitmap pixels (2× backing).
            let footerBand = CGRect(x: 0, y: (700 - 62) * 2, width: 720 * 2, height: 62 * 2)
            let differing = sage.countDifferingPixels(from: rose, in: footerBand)
            XCTAssertGreaterThan(
                differing, 2_000,
                "\(appearance.rawValue): the primary button is not filled with the accent "
                    + "(\(differing) footer pixels changed with the accent)"
            )
            XCTAssertTrue(
                sage.textFragments.contains { $0.contains("Crear proyecto") },
                "\(appearance.rawValue): the primary button label is missing"
            )
        }

        let appState = makeSnapshotAppState()
        for appearance in SnapshotAppearance.allCases {
            SnapshotRenderer.render(
                EscaletaImportPreviewSheet(request: request),
                name: "escaleta-import-primary-\(appearance.rawValue)",
                suite: "FU3SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
        }
    }

    // MARK: - V6: the warnings section is not clipped by the footer

    func testEscaletaImportWarningsSectionIsNotClippedByTheFooter() throws {
        let appState = makeSnapshotAppState()
        let request = makeEscaletaRequest()

        for appearance in SnapshotAppearance.allCases {
            let rendered = try XCTUnwrap(renderOffscreen(
                EscaletaImportPreviewSheet(request: request),
                size: SnapshotSize.standard.size,
                appearance: appearance,
                appState: appState
            ), "\(appearance.rawValue): could not render the import sheet")
            addTeardownBlock { rendered.release() }

            XCTAssertTrue(
                rendered.textFragments.contains { $0.contains("Avisos") },
                "\(appearance.rawValue): the warnings heading is missing"
            )
            let scrollView = try XCTUnwrap(
                rendered.firstScrollView,
                "\(appearance.rawValue): the sheet has no scroll view"
            )
            let documentHeight = try XCTUnwrap(scrollView.documentView).frame.height
            let viewportHeight = scrollView.contentView.bounds.height
            XCTAssertLessThanOrEqual(
                documentHeight, viewportHeight + 1,
                "\(appearance.rawValue): the preview content (\(documentHeight) pt) is taller than its viewport "
                    + "(\(viewportHeight) pt), so the last section is cut by the footer"
            )
        }

        for appearance in SnapshotAppearance.allCases {
            SnapshotRenderer.render(
                EscaletaImportPreviewSheet(request: request),
                name: "escaleta-import-warnings-\(appearance.rawValue)",
                suite: "FU3SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
        }
    }

    // MARK: - V7: real buttons and no dead reset

    func testDurationPopoverButtonsAreControlsAndResetIsHiddenWithoutALearnedPace() throws {
        let project = SampleData.demoProject(language: .spanish)
        project.targetDuration = 600
        project.scenes.sortedByOrder[0].targetDuration = 75
        let appState = makeSnapshotAppState(project: project)
        let scene = project.scenes.sortedByOrder[0]

        for appearance in SnapshotAppearance.allCases {
            let scenePopover = try XCTUnwrap(renderOffscreen(
                SceneDurationPopover(scene: scene),
                size: CGSize(width: 400, height: 320),
                appearance: appearance,
                appState: appState
            ), "\(appearance.rawValue): could not render the scene popover")
            addTeardownBlock { scenePopover.release() }

            // The target-editor row (buttons at y ≈ 225…260 pt of the popover).
            // "Fijar" and "Borrar" are drawn with the accent text colour and an
            // accent border; the old plain-text buttons had no accent pixel at
            // all in this band.
            let buttonBand = CGRect(x: 0, y: 440, width: 680, height: 100)
            let tinted = scenePopover.countTintedPixels(in: buttonBand)
            XCTAssertGreaterThan(
                tinted, 100,
                "\(appearance.rawValue): the scene duration buttons are still plain text "
                    + "(\(tinted) accent-tinted pixels in the button row)"
            )
            XCTAssertTrue(
                scenePopover.textFragments.contains { isExactLabel($0, "Fijar") },
                "\(appearance.rawValue): the set button is missing"
            )
            XCTAssertTrue(
                scenePopover.textFragments.contains { isExactLabel($0, "Borrar") },
                "\(appearance.rawValue): the clear button is missing"
            )

            let projectPopover = try XCTUnwrap(renderOffscreen(
                ProjectDurationPopover(),
                size: CGSize(width: 420, height: 420),
                appearance: appearance,
                appState: appState
            ), "\(appearance.rawValue): could not render the project popover")
            addTeardownBlock { projectPopover.release() }
            XCTAssertFalse(
                projectPopover.textFragments.contains { isExactLabel($0, "Restablecer") },
                "\(appearance.rawValue): Restablecer is shown with nothing learned"
            )

            SnapshotRenderer.render(
                SceneDurationPopover(scene: scene),
                name: "duration-scene-popover-v7-\(appearance.rawValue)",
                suite: "FU3SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
            SnapshotRenderer.render(
                ProjectDurationPopover(),
                name: "duration-project-popover-v7-nothing-learned-\(appearance.rawValue)",
                suite: "FU3SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
        }

        // With a learned pace the reset button must exist.
        project.learnedWordsPerMinuteByLanguage["en"] = 168
        for appearance in SnapshotAppearance.allCases {
            let projectPopover = try XCTUnwrap(renderOffscreen(
                ProjectDurationPopover(),
                size: CGSize(width: 420, height: 420),
                appearance: appearance,
                appState: appState
            ), "\(appearance.rawValue): could not render the project popover")
            addTeardownBlock { projectPopover.release() }
            XCTAssertTrue(
                projectPopover.textFragments.contains { isExactLabel($0, "Restablecer") },
                "\(appearance.rawValue): Restablecer is missing for a learned pace"
            )

            SnapshotRenderer.render(
                ProjectDurationPopover(),
                name: "duration-project-popover-v7-learned-\(appearance.rawValue)",
                suite: "FU3SnapshotTests",
                size: SnapshotSize.standard.size,
                appearance: appearance,
                language: .spanish,
                appState: appState
            )
        }
    }

    /// The button label is its own `Text`; the learned-pace help paragraph also
    /// mentions "Restablecer", so a substring match would be a false positive.
    private func isExactLabel(_ fragment: String, _ label: String) -> Bool {
        fragment.trimmingCharacters(in: .whitespacesAndNewlines) == label
    }

    // MARK: - Offscreen renderer

    /// Minimal copy of `SnapshotRenderer`'s window rules. The window is never
    /// ordered front, never becomes key and is released by `release()`.
    @MainActor
    private struct RenderedView {
        let window: NSWindow
        let canvas: NSView
        let hosting: NSView
        let bitmap: NSBitmapImageRep

        func release() {
            window.contentView = nil
            hosting.removeFromSuperview()
            window.close()
        }

        var textFragments: [String] {
            var fragments: [String] = []
            collectText(canvas, into: &fragments)
            fragments.append(contentsOf: displayListText(from: hosting))
            return Array(Set(fragments.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        }

        var firstScrollView: NSScrollView? {
            findScrollView(canvas)
        }

        /// Pixels that changed between two renders of the same view inside
        /// `rect` (bitmap coordinates, `(0,0)` is the top-left pixel).
        func countDifferingPixels(from other: RenderedView, in rect: CGRect) -> Int {
            guard bitmap.pixelsWide == other.bitmap.pixelsWide,
                  bitmap.pixelsHigh == other.bitmap.pixelsHigh else { return 0 }
            let maxX = min(Int(rect.maxX), bitmap.pixelsWide)
            let maxY = min(Int(rect.maxY), bitmap.pixelsHigh)
            var count = 0
            for y in max(0, Int(rect.minY))..<maxY {
                for x in max(0, Int(rect.minX))..<maxX {
                    guard let left = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let right = other.bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                        continue
                    }
                    if abs(left.redComponent - right.redComponent) > 0.02
                        || abs(left.greenComponent - right.greenComponent) > 0.02
                        || abs(left.blueComponent - right.blueComponent) > 0.02 {
                        count += 1
                    }
                }
            }
            return count
        }

        /// Green-tinted, opaque pixels: the accent text colour and its border,
        /// independent of the exact colour-space conversion of the bitmap.
        func countTintedPixels(in rect: CGRect) -> Int {
            let maxX = min(Int(rect.maxX), bitmap.pixelsWide)
            let maxY = min(Int(rect.maxY), bitmap.pixelsHigh)
            var count = 0
            for y in max(0, Int(rect.minY))..<maxY {
                for x in max(0, Int(rect.minX))..<maxX {
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if pixel.alphaComponent >= 0.99,
                       pixel.greenComponent - pixel.redComponent >= 6.0 / 255.0,
                       pixel.greenComponent - pixel.blueComponent >= 6.0 / 255.0 {
                        count += 1
                    }
                }
            }
            return count
        }

        private func collectText(_ view: NSView, into fragments: inout [String]) {
            if let field = view as? NSTextField {
                fragments.append(field.stringValue)
            }
            if let textView = view as? NSTextView {
                fragments.append(textView.string)
            }
            for subview in view.subviews {
                collectText(subview, into: &fragments)
            }
        }

        /// SwiftUI's display list contains every laid-out `Text`.
        private func displayListText(from hosting: NSView) -> [String] {
            var descriptions: [String] = []
            func scan(_ value: Any, depth: Int) {
                guard depth < 10 else { return }
                let description = String(describing: value)
                if description.contains("(text \"") || description.contains("(display-list") {
                    descriptions.append(description)
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
            for description in descriptions {
                let range = NSRange(description.startIndex..<description.endIndex, in: description)
                for match in regex.matches(in: description, range: range) {
                    guard let matchRange = Range(match.range(at: 1), in: description) else { continue }
                    let value = String(description[matchRange])
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

        private func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = findScrollView(subview) { return found }
            }
            return nil
        }
    }

    private func renderOffscreen<Content: View>(
        _ content: Content,
        size: CGSize,
        appearance: SnapshotAppearance,
        appState: AppState
    ) -> RenderedView? {
        if appState.settings.generalPreferences.language != .spanish {
            appState.settings.generalPreferences.language = .spanish
        }
        let theme = FrameTheme(colorScheme: appearance.colorScheme, accent: appState.settings.accentColor)
        let root = content
            .environment(appState)
            .environment(EscaletaImportCoordinator())
            .environment(\.frameTheme, theme)
            .preferredColorScheme(appearance.colorScheme)
            .frame(width: size.width, height: size.height, alignment: .topLeading)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]

        let canvas = SnapshotCanvas(frame: NSRect(origin: .zero, size: size))
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

        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        canvas.displayIfNeeded()

        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            XCTFail("Could not create a bitmap for the offscreen render")
            window.contentView = nil
            hosting.removeFromSuperview()
            window.close()
            return nil
        }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        return RenderedView(window: window, canvas: canvas, hosting: hosting, bitmap: bitmap)
    }

    // MARK: - Fixtures

    private func makeSnapshotAppState(
        project: FrameProject? = nil,
        accent: AccentPalette = .sage
    ) -> AppState {
        let defaults = makeDefaults()
        var settings = AppSettings.defaults
        settings.generalPreferences.language = .spanish
        settings.generalPreferences.autosaveEnabled = false
        settings.accentColor = accent
        let project = project ?? SampleData.demoProject(language: .spanish)
        let store = ProjectStore(project: project)
        store.openProject(project, fileURL: nil, wordsPerMinute: 150, markUnsaved: false)
        return AppState(
            projectStore: store,
            recentProjectStore: RecentProjectStore(userDefaults: defaults),
            settingsStore: SettingsStore(settings: settings, userDefaults: defaults, key: "settings")
        )
    }

    private func makeEscaletaRequest() -> EscaletaImportRequest {
        let markdown = Self.demoEscaleta
        let result = EscaletaParser.parse(markdown)
        let mapping = EscaletaProjectMapper.map(
            result,
            options: EscaletaMappingOptions(primaryLanguage: "es", wordsPerMinute: 150)
        )
        return EscaletaImportRequest(
            url: URL(fileURLWithPath: "/tmp/fu3-escaleta.md"),
            markdown: markdown,
            result: result,
            mapping: mapping,
            mode: .newProject
        )
    }

    /// Synthetic four-scene escaleta: enough content for the warnings section to
    /// sit at the bottom of the sheet.
    private static let demoEscaleta = """
    # Escaleta sintética de prueba

    ## Promesa del vídeo

    Una promesa sintética para la prueba visual.

    ## Tesis

    Una tesis sintética para la prueba visual.

    ## Escaleta

    1. Gancho: la promesa.
    2. Problema: el detalle.
    3. Explicación: el contexto.
    4. Cierre: el veredicto.

    ---

    # Guion

    ## 0:00 — Gancho

    [IMAGEN: montaje sintético de la prueba]

    Texto sintético del gancho con una promesa y una pregunta.

    ## 0:40 — Problema

    [IMAGEN: captura sintética del problema]

    Texto sintético del problema, sin datos reales.

    ## 1:20 — Explicación

    [IMAGEN: calendario sintético]

    Texto sintético de la explicación para la prueba visual.

    ## 2:10 — Cierre

    [IMAGEN: plano sintético de cierre]

    Texto sintético del cierre para la prueba visual.
    """
}

private final class SnapshotCanvas: NSView {
    var backgroundColor: NSColor = .windowBackgroundColor

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}
