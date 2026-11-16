import AppKit
import Foundation
import FrameScriptCore
@testable import FrameScript
import SwiftUI
import XCTest

/// Offscreen visual checks for every surface this feature adds. No window is
/// ordered front and no app is launched. With `FS_SNAPSHOTS=1` the PNGs land in
/// `/tmp/fs-snapshots/w3-g-board`; otherwise the same renders assert layout
/// invariants and Spanish text through the accessibility tree.
@MainActor
final class BoardSnapshotTests: XCTestCase {
    private var harness: BoardTestHarness!

    private let sizes: [(name: String, size: CGSize)] = [
        ("1180x760", CGSize(width: 1180, height: 760)),
        ("980x712", CGSize(width: 980, height: 712))
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        harness = try BoardTestHarness()
        let harness = harness!
        // Snapshot renders must be deterministic: the fixture is already
        // scanned, so opening the view must not start a second scan (NEW-4).
        harness.board.scansOnAppear = false
        addTeardownBlock { harness.tearDown() }
    }

    func testBoardWindowRendersAtBothSizesAndThemes() async throws {
        try await harness.prepareSampleBoard()
        harness.board.layout = .kanban
        harness.board.selectedProjectID = harness.board.summaries.first?.id

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    BoardRootView(
                        store: harness.board,
                        catalog: harness.catalog,
                        plane: harness.plane
                    ),
                    size: variant.size,
                    appearance: appearance,
                    name: "board-kanban",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: [
                        "Tablero", "Estado", "Juego", "carpeta",
                        "Editar clasificación", "Exportar pendientes a Plane"
                    ]
                )
            }
        }

        harness.board.layout = .list
        harness.board.grouping = .topic
        harness.board.selectedProjectID = harness.board.summaries.first?.id

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    BoardRootView(
                        store: harness.board,
                        catalog: harness.catalog,
                        plane: harness.plane
                    ),
                    size: variant.size,
                    appearance: appearance,
                    name: "board-list",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: ["Título", "Estado", "Pendientes", "Duración"]
                )
            }
        }
    }

    func testClassificationSheetRendersAtBothSizesAndThemes() async throws {
        try await harness.prepareSampleBoard()
        let summary = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    BoardSheetCanvas {
                        BoardClassificationSheet(
                            summary: summary,
                            store: harness.board,
                            catalog: harness.catalog
                        )
                    },
                    size: variant.size,
                    appearance: appearance,
                    name: "board-classification",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: ["Editar clasificación", "Juego o tema", "Guardar"]
                )
            }
        }
    }

    func testPlaneExportSheetRendersAtBothSizesAndThemes() async throws {
        try await harness.prepareSampleBoard()
        harness.plane.settings.baseURL = "https://plane.example.test"
        harness.plane.settings.workspaceSlug = "mi-workspace"
        harness.plane.settings.projectID = "project-id-sintetico"
        harness.keychain.token = "token-sintetico"
        harness.plane.refreshTokenStatus()

        let summary = try XCTUnwrap(
            harness.board.summaries.first { $0.title.contains("Análisis de la actualización") }
        )

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    BoardSheetCanvas {
                        BoardPlaneExportSheet(
                            summary: summary,
                            store: harness.board,
                            plane: harness.plane,
                            ledgerStore: harness.ledger
                        )
                    },
                    size: variant.size,
                    appearance: appearance,
                    name: "board-plane-export",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: ["Exportar pendientes a Plane", "Grabar", "Exportar"]
                )
            }
        }
    }

    func testBoardSettingsRenderAtBothSizesAndThemes() async throws {
        try await harness.prepareSampleBoard()

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    BoardSettingsCanvas {
                        BoardSettingsView(
                            store: harness.board,
                            catalog: harness.catalog,
                            plane: harness.plane
                        )
                    },
                    size: variant.size,
                    appearance: appearance,
                    name: "board-settings",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: ["Biblioteca del tablero", "Carpetas", "Añadir carpeta"]
                )
            }
        }
    }

    func testProjectInfoSectionRendersAtBothSizesAndThemes() async throws {
        try await harness.prepareSampleBoard()
        harness.appState.setProjectTopic("Assetto Corsa Competizione")
        harness.appState.setProjectVideoType("análisis")
        harness.appState.setProjectProductionStatus(.script)

        for appearance in appearances {
            for variant in sizes {
                let result = try render(
                    ProjectInfoCanvas {
                        BoardProjectInfoSection(catalog: harness.catalog)
                    },
                    size: variant.size,
                    appearance: appearance,
                    name: "board-project-info",
                    inspectText: isInspectionVariant(appearance: appearance, variant: variant.name)
                )
                assertInvariants(
                    result,
                    expectedSpanish: ["Estado", "Juego o tema", "Assetto Corsa Competizione"]
                )
            }
        }
    }

    func testW3FixEGIBoardSettingsWarnAboutPlainHTTP() throws {
        harness.plane.settings.baseURL = "http://192.168.1.20:8080"
        let result = try render(
            BoardSettingsCanvas {
                BoardSettingsView(
                    store: harness.board,
                    catalog: harness.catalog,
                    plane: harness.plane
                )
            },
            size: sizes[0].size,
            appearance: .light,
            name: "board-settings-insecure"
        )
        assertInvariants(result, expectedSpanish: ["HTTP sin cifrar"])
    }

    func testW3FixEGIBoardSnapshotDoesNotStartAScanOnRender() async throws {
        try await harness.prepareSampleBoard()
        harness.board.selectedProjectID = harness.board.summaries.first?.id

        XCTAssertFalse(harness.board.isScanning)
        let result = try render(
            BoardRootView(
                store: harness.board,
                catalog: harness.catalog,
                plane: harness.plane
            ),
            size: sizes[0].size,
            appearance: .light,
            name: "board-no-rescan"
        )

        XCTAssertFalse(harness.board.isScanning)
        let joined = result.labels.joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_ES")
        )
        XCTAssertFalse(joined.contains("scanning"), "labels: \(joined)")
        XCTAssertFalse(joined.contains("analizando"), "labels: \(joined)")
        assertInvariants(result, expectedSpanish: ["Tablero", "Estado"])
    }

    // MARK: Helpers

    private var appearances: [BoardSnapshotRenderer.Appearance] {
        [.light, .dark]
    }

    /// OCR is used on one representative render per screen; the other size and
    /// theme variants still assert non-zero size, non-blank output and their
    /// snapshots. This keeps the visual checks from starving the timing
    /// sensitive editor tests that run in parallel.
    private func isInspectionVariant(
        appearance: BoardSnapshotRenderer.Appearance,
        variant: String
    ) -> Bool {
        appearance == .light && variant == "1180x760"
    }

    private func render<V: View>(
        _ view: V,
        size: CGSize,
        appearance: BoardSnapshotRenderer.Appearance,
        name: String,
        inspectText: Bool = true
    ) throws -> BoardSnapshotRenderer.Result {
        let theme = FrameTheme(
            colorScheme: appearance == .dark ? .dark : .light,
            accent: .sage
        )
        return try BoardSnapshotRenderer.render(
            view
                .environment(harness.appState)
                .environment(\.frameTheme, theme),
            size: size,
            appearance: appearance,
            name: name,
            theme: theme,
            inspectText: inspectText
        )
    }

    private func assertInvariants(
        _ result: BoardSnapshotRenderer.Result,
        expectedSpanish: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThan(result.pixelWidth, 0, file: file, line: line)
        XCTAssertGreaterThan(result.pixelHeight, 0, file: file, line: line)
        XCTAssertGreaterThan(result.pngData?.count ?? 0, 4_000, "The render looks blank", file: file, line: line)

        let width = result.containerSize.width
        let height = result.containerSize.height
        for frame in result.controlFrames {
            XCTAssertGreaterThanOrEqual(frame.minX, -2, "Control clipped on the left: \(frame)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -2, "Control clipped at the bottom: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, width + 2, "Control clipped on the right: \(frame)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, height + 2, "Control clipped at the top: \(frame)", file: file, line: line)
        }

        let significantOverlaps = overlappingControls(result.controlFrames)
        XCTAssertTrue(
            significantOverlaps.isEmpty,
            "Controls overlap: \(significantOverlaps)",
            file: file,
            line: line
        )

        guard !result.labels.isEmpty else { return }

        let joined = result.labels.joined(separator: "\n").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "es_ES")
        )
        for expected in expectedSpanish {
            let folded = expected.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "es_ES")
            )
            XCTAssertTrue(
                joined.contains(folded),
                "Missing Spanish text «\(expected)» in the rendered accessibility tree. Labels: \(joined)",
                file: file,
                line: line
            )
        }
    }

    private func overlappingControls(_ frames: [CGRect]) -> [String] {
        var overlaps: [String] = []
        for index in frames.indices {
            for other in frames.index(after: index)..<frames.endIndex {
                let intersection = frames[index].intersection(frames[other])
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let smallest = min(frames[index].width * frames[index].height, frames[other].width * frames[other].height)
                guard smallest > 0 else { continue }
                let ratio = (intersection.width * intersection.height) / smallest
                if ratio > 0.6 {
                    overlaps.append("\(frames[index]) ↔ \(frames[other])")
                }
            }
        }
        return overlaps
    }
}

// MARK: - Snapshot canvases

private struct BoardSheetCanvas<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            theme.appBackground
            content
                .environment(\.frameTheme, theme)
                .padding(28)
                .background(theme.windowBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BoardSettingsCanvas<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            content
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(theme.windowBackground)
    }
}

private struct ProjectInfoCanvas<Content: View>: View {
    @Environment(\.frameTheme) private var theme
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            theme.appBackground
            content
                .padding(14)
                .frame(width: 420)
                .background(theme.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.divider, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
