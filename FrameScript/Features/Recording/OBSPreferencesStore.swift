import Foundation
import FrameScriptCore
import Observation

enum OBSPreferencesError: LocalizedError {
    case invalidHost
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Host required"
        case .invalidPort:
            "Port must be between 1 and 65535"
        }
    }
}

/// Host, port and auto-connect preferences for obs-websocket. The password is
/// the only value that lives in Keychain; everything else is a lightweight
/// `UserDefaults` preference so no shared settings type has to change.
@MainActor
@Observable
final class OBSPreferencesStore {
    static let defaultHost = "localhost"
    static let defaultPort = OBSConnectionConfig.defaultPort

    private enum Key {
        static let host = "recording.obs.host"
        static let port = "recording.obs.port"
        static let autoConnect = "recording.obs.autoConnect"
    }

    private let defaults: UserDefaults
    private let secretStore: any OBSSecretStoring

    var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }

    var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }

    var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: Key.autoConnect) }
    }

    /// Loaded lazily: launch never blocks on Keychain. `connect()` and the OBS
    /// settings sheet call `loadPasswordIfNeeded()`.
    private(set) var password = ""
    private(set) var hasLoadedPassword = false
    /// Set when the Keychain read failed, so the settings sheet can explain why
    /// the password field is empty.
    private(set) var keychainReadFailed = false

    init(
        defaults: UserDefaults = .standard,
        secretStore: any OBSSecretStoring = KeychainOBSSecretStore()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        host = defaults.string(forKey: Key.host) ?? Self.defaultHost
        let storedPort = defaults.integer(forKey: Key.port)
        port = storedPort > 0 ? storedPort : Self.defaultPort
        autoConnect = defaults.bool(forKey: Key.autoConnect)
    }

    /// Reads the Keychain at most once. A failed read is not retried on every
    /// keystroke; saving a new password clears the failure.
    func loadPasswordIfNeeded() {
        guard !hasLoadedPassword else { return }
        hasLoadedPassword = true
        do {
            password = try secretStore.readPassword() ?? ""
        } catch {
            password = ""
            keychainReadFailed = true
        }
    }

    var effectivePort: Int {
        port > 0 && port <= 65_535 ? port : Self.defaultPort
    }

    var connectionConfig: OBSConnectionConfig {
        OBSConnectionConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultHost
                : host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: effectivePort,
            password: password.isEmpty ? nil : password,
            connectTimeout: .seconds(8),
            requestTimeout: .seconds(3),
            keepaliveInterval: .seconds(10),
            reconnect: .disabled
        )
    }

    /// Validates and persists the form values. Throws before touching any
    /// stored value, so a failed save cannot leave half-applied settings.
    func apply(host newHost: String, portText: String, autoConnect newAutoConnect: Bool, password newPassword: String) throws {
        let trimmedHost = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { throw OBSPreferencesError.invalidHost }
        guard let parsedPort = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(parsedPort)
        else {
            throw OBSPreferencesError.invalidPort
        }

        // Compare against the real stored value, not an unloaded empty string.
        loadPasswordIfNeeded()
        if newPassword != password {
            try secretStore.savePassword(newPassword)
            password = newPassword
            keychainReadFailed = false
        }
        host = trimmedHost
        port = parsedPort
        autoConnect = newAutoConnect
    }
}
