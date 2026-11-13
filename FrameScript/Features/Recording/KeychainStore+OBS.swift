import Foundation
import OSLog
import Security

/// OBS WebSocket credentials live in their own Keychain service so they never
/// mix with the AI provider keys owned by `KeychainStore`.
protocol OBSSecretStoring: Sendable {
    func readPassword() throws -> String?
    func savePassword(_ password: String) throws
}

struct KeychainOBSSecretStore: OBSSecretStoring {
    func readPassword() throws -> String? {
        try KeychainStore.readOBSWebSocketPassword()
    }

    func savePassword(_ password: String) throws {
        try KeychainStore.saveOBSWebSocketPassword(password)
    }
}

/// Update-or-add keeps the old password intact when the update fails for a
/// reason other than “not found”. The previous delete-then-add sequence could
/// erase a working credential if the add failed.
enum OBSKeychainWrite {
    static func save(update: () -> OSStatus, add: () -> OSStatus) throws {
        let updateStatus = update()
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }
        let addStatus = add()
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }
}

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
        let value = Data(password.utf8)
        do {
            try OBSKeychainWrite.save(
                update: {
                    SecItemUpdate(
                        query as CFDictionary,
                        [kSecValueData as String: value] as CFDictionary
                    )
                },
                add: {
                    var attributes = query
                    attributes[kSecValueData as String] = value
                    return SecItemAdd(attributes as CFDictionary, nil)
                }
            )
        } catch {
            obsLogger.error("OBS Keychain write failed; the existing item was left intact.")
            throw error
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
