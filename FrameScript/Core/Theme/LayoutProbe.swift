import SwiftUI

/// Test seam for alignment checks. Views tag the element that defines a
/// column edge with `.layoutProbe("…")`; when a test installs a sink in the
/// environment, each tagged frame is reported in window coordinates.
/// Production never sets the sink, so the modifier is a pass-through there.
@MainActor
final class LayoutProbeSink: @unchecked Sendable {
    private var latest: [String: [UUID: CGRect]] = [:]

    /// The latest frame of every live instance tagged with `id`.
    func frames(_ id: String) -> [CGRect] {
        Array(latest[id, default: [:]].values)
    }

    func record(_ id: String, instance: UUID, frame: CGRect) {
        latest[id, default: [:]][instance] = frame
    }
}

private struct LayoutProbeSinkKey: EnvironmentKey {
    static let defaultValue: LayoutProbeSink? = nil
}

extension EnvironmentValues {
    var layoutProbeSink: LayoutProbeSink? {
        get { self[LayoutProbeSinkKey.self] }
        set { self[LayoutProbeSinkKey.self] = newValue }
    }
}

private struct LayoutProbeModifier: ViewModifier {
    @Environment(\.layoutProbeSink) private var sink
    @State private var instance = UUID()
    let id: String

    func body(content: Content) -> some View {
        if let sink {
            content.background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { sink.record(id, instance: instance, frame: frame) }
                        .onChange(of: frame) { _, newFrame in
                            sink.record(id, instance: instance, frame: newFrame)
                        }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func layoutProbe(_ id: String) -> some View {
        modifier(LayoutProbeModifier(id: id))
    }
}
