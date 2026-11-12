import Foundation
import Observation

/// Persists the F12 subscription settings next to the other app preferences.
///
/// They are not part of `AppSettings` because they are machine-local (paths,
/// CLI choices) and must stay out of exported projects and template defaults.
@MainActor
@Observable
final class SubscriptionAISettingsStore {
    static let shared = SubscriptionAISettingsStore()

    static let storageKey = "FrameScript.ai.subscription"

    private let userDefaults: UserDefaults
    private(set) var isPersisting = true

    var settings: SubscriptionAISettings {
        didSet {
            guard isPersisting else { return }
            save()
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(SubscriptionAISettings.self, from: data) {
            settings = decoded
        } else {
            settings = .defaults
        }
    }

    func reset() {
        settings = .defaults
    }

    func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    /// Tests can seed settings without writing to the user's defaults.
    func replace(with settings: SubscriptionAISettings, persisting: Bool = true) {
        guard !persisting else {
            self.settings = settings
            return
        }
        isPersisting = false
        self.settings = settings
        isPersisting = true
    }
}
