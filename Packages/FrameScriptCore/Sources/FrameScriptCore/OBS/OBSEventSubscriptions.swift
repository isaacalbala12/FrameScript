import Foundation

/// A bitmask of obs-websocket event categories.
///
/// The raw values come from `EventSubscription` in the protocol documentation.
/// `.all` is every non-high-volume category the server offers; high-volume
/// events must be requested explicitly.
public struct OBSEventSubscriptions: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let none = OBSEventSubscriptions([])
    public static let general = OBSEventSubscriptions(rawValue: 1 << 0)
    public static let config = OBSEventSubscriptions(rawValue: 1 << 1)
    public static let scenes = OBSEventSubscriptions(rawValue: 1 << 2)
    public static let inputs = OBSEventSubscriptions(rawValue: 1 << 3)
    public static let transitions = OBSEventSubscriptions(rawValue: 1 << 4)
    public static let filters = OBSEventSubscriptions(rawValue: 1 << 5)
    public static let outputs = OBSEventSubscriptions(rawValue: 1 << 6)
    public static let sceneItems = OBSEventSubscriptions(rawValue: 1 << 7)
    public static let mediaInputs = OBSEventSubscriptions(rawValue: 1 << 8)
    public static let vendors = OBSEventSubscriptions(rawValue: 1 << 9)
    public static let ui = OBSEventSubscriptions(rawValue: 1 << 10)
    public static let canvases = OBSEventSubscriptions(rawValue: 1 << 11)

    /// All non-high-volume events (`EventSubscription::All`, 4095).
    public static let all: OBSEventSubscriptions = [
        .general, .config, .scenes, .inputs, .transitions, .filters,
        .outputs, .sceneItems, .mediaInputs, .vendors, .ui, .canvases,
    ]

    /// High-volume event categories, never part of `.all`.
    public static let highVolume: OBSEventSubscriptions = [
        .inputVolumeMeters, .inputActiveStateChanged,
        .inputShowStateChanged, .sceneItemTransformChanged,
    ]

    public static let inputVolumeMeters = OBSEventSubscriptions(rawValue: 1 << 16)
    public static let inputActiveStateChanged = OBSEventSubscriptions(rawValue: 1 << 17)
    public static let inputShowStateChanged = OBSEventSubscriptions(rawValue: 1 << 18)
    public static let sceneItemTransformChanged = OBSEventSubscriptions(rawValue: 1 << 19)
}
