import Foundation
import Observation
import OSLog

/// Persists the F12 subscription settings next to the other app preferences.
///
/// They are not part of `AppSettings` because they are machine-local (paths,
/// CLI choices) and must stay out of exported projects and template defaults.
@MainActor
@Observable
final class SubscriptionAISettingsStore {
    static let shared = SubscriptionAISettingsStore()

    static let storageKey = "FrameScript.ai.subscription"
    /// Prefix of the preserved copy of a blob this build could not read.
    static let unreadableBackupKeyPrefix = "FrameScript.ai.subscription.unreadable."
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "AISubscription"
    )

    private let userDefaults: UserDefaults
    private(set) var isPersisting = true
    /// Key that holds the unreadable blob, when the stored settings could not be
    /// decoded. The bytes are never deleted: the user can recover them.
    private(set) var unreadableBackupKey: String?
    /// True until the notice is dismissed. The stored blob is only replaced
    /// when the user changes a setting, which is an explicit action.
    private(set) var didRecoverFromUnreadableSettings = false

    var settings: SubscriptionAISettings {
        didSet {
            guard isPersisting else { return }
            save()
        }
    }

    init(userDefaults: UserDefaults = AppEnvironment.defaults) {
        let resolvedDefaults = AppEnvironment.isolatedDefaults(userDefaults)
        self.userDefaults = resolvedDefaults
        guard let data = resolvedDefaults.data(forKey: Self.storageKey) else {
            settings = .defaults
            return
        }
        do {
            settings = try JSONDecoder().decode(SubscriptionAISettings.self, from: data)
        } catch {
            // Never overwrite the unreadable blob blindly: keep a copy under a
            // timestamped key, log it, and tell the user in Settings.
            let backupKey = Self.unreadableBackupKeyPrefix + UUID().uuidString
            resolvedDefaults.set(data, forKey: backupKey)
            unreadableBackupKey = backupKey
            didRecoverFromUnreadableSettings = true
            Self.logger.error(
                "Subscription AI settings could not be decoded. Bytes: \(data.count, privacy: .public). Kept at: \(backupKey, privacy: .public)."
            )
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

    /// Hides the recovery notice; the preserved blob stays in defaults.
    func acknowledgeUnreadableSettings() {
        didRecoverFromUnreadableSettings = false
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
