import SwiftUI

/// Collects the frames of the clip panel's key sections so the offscreen
/// snapshot tests can assert that nothing is clipped or overlapping without
/// taking focus or opening a window.
struct ClipFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
final class ClipLayoutRegistry {
    static let shared = ClipLayoutRegistry()

    private var framesByToken: [String: [String: CGRect]] = [:]

    private init() {}

    func set(_ frames: [String: CGRect], token: String) {
        framesByToken[token] = frames
    }

    func frames(for token: String) -> [String: CGRect] {
        framesByToken[token] ?? [:]
    }

    func reset() {
        framesByToken.removeAll()
    }
}

extension View {
    /// Registers this view's frame under `name` in the clip panel's coordinate
    /// space. Only the snapshot tests read the registry.
    func clipLayoutFrame(_ name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ClipFramePreferenceKey.self,
                    value: [name: proxy.frame(in: .named("clips-panel"))]
                )
            }
        }
    }
}
