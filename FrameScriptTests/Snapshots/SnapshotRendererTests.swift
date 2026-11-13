import AppKit
import SwiftUI
import XCTest
@testable import FrameScript

/// Exercises both halves of `SnapshotRenderer`: a pure SwiftUI view and a
/// plain AppKit `NSView`. Neither path may steal focus or require a visible
/// window.
@MainActor
final class SnapshotRendererTests: FrameScriptTestCase {
    func testSwiftUIViewRendersOffscreenWithText() {
        let appState = AppState(
            recentProjectStore: RecentProjectStore(userDefaults: makeDefaults()),
            settingsStore: SettingsStore(settings: .defaults, userDefaults: makeDefaults(), key: "settings")
        )
        let result = SnapshotRenderer.render(
            VStack(alignment: .leading, spacing: 8) {
                Text("Hola instantánea")
                    .font(.system(size: 28, weight: .bold))
                Text("Segunda línea")
                    .font(.system(size: 14))
            }
            .padding(24),
            name: "swiftui-text",
            suite: "SnapshotRendererTests",
            size: CGSize(width: 480, height: 240),
            appearance: .light,
            language: .spanish,
            appState: appState
        )

        XCTAssertGreaterThan(result.pixelSize.width, 0)
        XCTAssertGreaterThan(result.pixelSize.height, 0)
        XCTAssertTrue(result.textFragments.contains { $0.contains("Hola instantánea") })
    }

    func testAppKitViewRendersOffscreenWithText() {
        let label = NSTextField(labelWithString: "Hola desde AppKit")
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.frame = NSRect(x: 24, y: 80, width: 360, height: 40)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        container.addSubview(label)

        let result = SnapshotRenderer.render(
            container,
            name: "appkit-text",
            suite: "SnapshotRendererTests",
            size: CGSize(width: 480, height: 240),
            appearance: .light
        )

        XCTAssertGreaterThan(result.pixelSize.width, 0)
        XCTAssertGreaterThan(result.pixelSize.height, 0)
        XCTAssertTrue(result.textFragments.contains { $0.contains("Hola desde AppKit") })
    }
}
