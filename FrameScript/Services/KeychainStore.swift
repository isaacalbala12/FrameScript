import Foundation
import OSLog
import Security

enum KeychainStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "Keychain")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var testItems: [String: String] = [:]

    /// The test host never touches the login Keychain. Items saved by tests
    /// live in this process-local fake and disappear with the process.
    private static var apiKeyService: String {
        AppEnvironment.isRunningTests
            ? "FrameScript.Tests.\(ProcessInfo.processInfo.processIdentifier)"
            : "FrameScript"
    }

    /// API keys stay in the user's login Keychain and are never serialized into
    /// `.fscr` project files or sample data.
    static func saveAPIKey(_ key: String, account: String) throws {
        let service = apiKeyService
        guard !AppEnvironment.isRunningTests else {
            setTestSecret(key, service: service, account: account)
            return
        }
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var addAttributes = query
        addAttributes[kSecValueData as String] = data

        try write(
            update: { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) },
            add: { SecItemAdd(addAttributes as CFDictionary, nil) }
        )
    }

    /// Updates the existing item and only adds when it does not exist.
    ///
    /// The previous delete-then-add destroyed a working key when the add failed
    /// (locked Keychain, denied ACL prompt, quota). Keeping the old item also
    /// preserves its access-control attributes.
    static func write(update: () -> OSStatus, add: () -> OSStatus) throws {
        let updateStatus = update()
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let addStatus = add()
            guard addStatus == errSecSuccess else {
                logger.error("Keychain write failed. Status: \(addStatus, privacy: .private)")
                throw KeychainError.unhandledStatus(addStatus)
            }
        default:
            logger.error("Keychain update failed. Status: \(updateStatus, privacy: .private)")
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    static func readAPIKey(account: String) throws -> String? {
        let service = apiKeyService
        guard !AppEnvironment.isRunningTests else {
            return testSecret(service: service, account: account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            logger.error("Keychain read failed. Status: \(status, privacy: .private)")
            throw KeychainError.unhandledStatus(status)
        }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteAPIKey(account: String) throws {
        let service = apiKeyService
        guard !AppEnvironment.isRunningTests else {
            setTestSecret(nil, service: service, account: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Keychain delete failed. Status: \(status, privacy: .private)")
            throw KeychainError.unhandledStatus(status)
        }
    }

    // MARK: - Test-only in-memory store

    static func testSecret(service: String, account: String) -> String? {
        lock.withLock { testItems["\(service)|\(account)"] }
    }

    static func setTestSecret(_ value: String?, service: String, account: String) {
        lock.withLock {
            if let value {
                testItems["\(service)|\(account)"] = value
            } else {
                testItems.removeValue(forKey: "\(service)|\(account)")
            }
        }
    }

    static func removeAllTestSecrets() {
        lock.withLock { testItems.removeAll() }
    }
}

enum KeychainError: Error {
    case unhandledStatus(OSStatus)
}
