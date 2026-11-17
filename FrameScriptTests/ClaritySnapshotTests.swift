import AppKit
import FrameScriptCore
import SwiftUI
import XCTest
@testable import FrameScript

/// Offscreen snapshots of the three surfaces touched by the clarity pass, for
/// the user's almost-empty project and a realistic nine-scene one, at
/// 1512×949 and 980×712 in light and dark. Never ordered front.
@MainActor
final class ClaritySnapshotTests: FrameScriptTestCase {
    private struct Size { let label: String; let size: CGSize }
    private let sizes = [
        Size(label: "1512x949", size: CGSize(width: 1512, height: 949)),
        Size(label: "980x712", size: CGSize(width: 980, height: 712))
    ]
    private enum Fixture: String, CaseIterable {
        case almostEmpty, realistic
        @MainActor var project: FrameProject {
            self == .almostEmpty ? ClarityFixtures.almostEmpty() : ClarityFixtures.realistic()
        }
    }

    private func appState(_ fixture: Fixture) -> (AppState, UXInspectorState) {
        DesignReviewSnapshotTests.makeAppState(project: fixture.project, defaults: makeDefaults())
    }

    // MARK: Action bar + inspector (script mode)

    func testActionBarAndInspectorSnapshots() {
        for fixture in Fixture.allCases {
            for size in sizes {
                for appearance in SnapshotAppearance.allCases {
                    let (appState, inspector) = appState(fixture)
                    inspector.select(.production)
                    let name = "clarity-script-\(fixture.rawValue)-\(size.label)-\(appearance.rawValue)"
                    let result = SnapshotRenderer.render(
                        AppShellView(inspectorState: inspector),
                        name: name, suite: "ClaritySnapshotTests", size: size.size,
                        appearance: appearance, language: .spanish, appState: appState
                    )
                    XCTAssertTrue(result.textFragments.contains { $0.contains("Pausa corta") }
                                  || result.textFragments.contains { $0.contains("Grabar toma") }, name)
                    if fixture == .almostEmpty, size.size.width >= 1080 {
                        XCTAssertFalse(result.textFragments.contains { $0.contains("Sin pendientes") },
                                       "\(name): the inspector must not say Sin pendientes for a scene the panel lists")
                        XCTAssertTrue(result.textFragments.contains { $0.contains("Grábala con") }, name)
                    }
                }
            }
        }
    }

    // MARK: Producción sheet

    func testProductionPanelSnapshots() {
        for fixture in Fixture.allCases {
            for size in sizes {
                for appearance in SnapshotAppearance.allCases {
                    let (appState, _) = appState(fixture)
                    let theme = FrameTheme(colorScheme: appearance.colorScheme, accent: appState.settings.accentColor)
                    let store = ProductionExplainerStore(defaults: makeDefaults())
                    let name = "clarity-production-\(fixture.rawValue)-\(size.label)-\(appearance.rawValue)"
                    let result = SnapshotRenderer.render(
                        ZStack {
                            theme.background
                            ProductionPanelView(explainerStore: store)
                        }
                        .frame(width: size.size.width, height: size.size.height),
                        name: name, suite: "ClaritySnapshotTests", size: size.size,
                        appearance: appearance, language: .spanish, appState: appState
                    )
                    let text = result.textFragments
                    XCTAssertTrue(text.contains { $0.contains("Aquí aparece lo que falta") }, "\(name): explainer")
                    XCTAssertTrue(text.contains { $0.contains("automática") }, "\(name): automatic tag")
                    XCTAssertTrue(text.contains { $0.contains("Grábala con") }, "\(name): explanation")
                    XCTAssertTrue(text.contains { $0.contains("Ir a grabar") }, "\(name): one-click action")
                }
            }
        }
    }

    func testDismissedExplainerDisappears() {
        let (appState, _) = appState(.almostEmpty)
        let store = ProductionExplainerStore(defaults: makeDefaults())
        store.dismiss()
        let result = SnapshotRenderer.render(
            ProductionPanelView(explainerStore: store),
            name: "clarity-production-dismissed", suite: "ClaritySnapshotTests",
            size: CGSize(width: 900, height: 700), appearance: .light, language: .spanish, appState: appState
        )
        XCTAssertFalse(result.textFragments.contains { $0.contains("Aquí aparece lo que falta") })
    }

    // MARK: Timeline

    func testTimelineSnapshots() {
        for fixture in Fixture.allCases {
            for size in sizes {
                for appearance in SnapshotAppearance.allCases {
                    let (appState, _) = appState(fixture)
                    let theme = FrameTheme(colorScheme: appearance.colorScheme, accent: appState.settings.accentColor)
                    let layout = TimelineLayoutBuilder.build(appState.timelineInput())
                    // The editor pane: window minus sidebar, minus the inspector when shown.
                    let paneWidth = size.size.width - 195 - (size.size.width >= 1080 ? 293 : 0)
                    let fit = TimelineZoom.fitPointsPerSecond(
                        totalDuration: layout.totalDuration,
                        availableWidth: Double(paneWidth) - Double(TimelineWorkspaceView.canvasInset)
                    )
                    let name = "clarity-timeline-\(fixture.rawValue)-\(size.label)-\(appearance.rawValue)"
                    let result = SnapshotRenderer.render(
                        TimelinePanelView(
                            layout: layout, language: .spanish, theme: theme,
                            pointsPerSecond: fit,
                            zoomFraction: .constant(TimelineZoom.fraction(forPointsPerSecond: fit)),
                            selectedBlockID: nil, selectedSceneID: layout.scenes.first?.id,
                            isPending: false,
                            onSelectBlock: { _ in }, onMoveScene: { _, _ in },
                            onZoomIn: {}, onZoomOut: {}, onZoomChange: { _ in },
                            onFit: {}, isFitted: true, onGoToScript: {}
                        )
                        .frame(width: paneWidth, height: size.size.height),
                        name: name, suite: "ClaritySnapshotTests",
                        size: CGSize(width: paneWidth, height: size.size.height),
                        appearance: appearance, language: .spanish, appState: appState
                    )
                    let text = result.textFragments
                    XCTAssertTrue(text.contains { $0.contains("Tu vídeo de izquierda a derecha") }, "\(name): explainer line")
                    if fixture == .almostEmpty {
                        XCTAssertTrue(text.contains { $0.contains("Escribe el guion para ver la línea de tiempo") }, name)
                        XCTAssertTrue(text.contains { $0.contains("Ir al guion") }, name)
                        XCTAssertFalse(text.contains { $0.contains("Narración") }, "\(name): no empty tracks")
                    } else {
                        XCTAssertTrue(text.contains { $0.contains("Ajustar") }, "\(name): fit button")
                        XCTAssertTrue(text.contains { $0.contains("por división") }, "\(name): time scale")
                        XCTAssertTrue(text.contains { $0.contains("Narración") }, name)
                        XCTAssertFalse(text.contains { $0.contains("bloques") }, "\(name): bare block count removed")
                    }
                }
            }
        }
    }
}
