import Foundation
import OSLog
import Security

/// OBS WebSocket credentials live in their own Keychain service so they never
/// mix with the AI provider keys owned by `KeychainStore`.
extension KeychainStore {
    static let obsWebSocketService = "FrameScript.OBS"
    private static let obsWebSocketAccount = "obs-websocket-password"

    private static let obsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "FrameScript",
        category: "OBSCredentials"
    )

    static func saveOBSWebSocketPassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: obsWebSocketService,
            kSecAttrAccount as String: obsWebSocketAccount
        ]
        // Saving is the explicit replacement action: recreate the item so a
        // stale access-control list can never keep an old password alive.
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            obsLogger.error("OBS Keychain replacement delete failed. Status: \(deleteStatus, privacy: .private)")
            throw KeychainError.unhandledStatus(deleteStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            obsLogger.error("OBS Keychain write failed. Status: \(status, privacy: .private)")
            throw KeychainError.unhandledStatus(status)
        }
    }

    static func readOBSWebSocketPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: obsWebSocketService,
            kSecAttrAccount as String: obsWebSocketAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            obsLogger.error("OBS Keychain read failed. Status: \(status, privacy: .private)")
            throw KeychainError.unhandledStatus(status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteOBSWebSocketPassword() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: obsWebSocketService,
            kSecAttrAccount as String: obsWebSocketAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            obsLogger.error("OBS Keychain delete failed. Status: \(status, privacy: .private)")
            throw KeychainError.unhandledStatus(status)
        }
    }
}
